import Foundation

enum CCUsageError: LocalizedError {
    case binaryNotFound
    case timedOut
    case exitCode(Int32, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: "ccusage binary not found"
        case .timedOut: "ccusage timed out"
        case .exitCode(let code, let stderr): "ccusage exited \(code): \(stderr.prefix(120))"
        case .decoding(let detail): "unexpected ccusage output: \(detail.prefix(120))"
        }
    }
}

/// Runs the pinned native ccusage binary. Actor: at most one scan at a time.
actor CCUsageClient {
    private let timeout: TimeInterval = 20
    private var cachedBinary: URL?

    func fetchReport(sinceDaysBack: Int = 35) async throws -> CCUnifiedReport {
        let binary = try resolveBinary()

        let since = Calendar.current.date(byAdding: .day, value: -sinceDaysBack, to: .now) ?? .now
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "daily",
            "--sections", "daily,weekly,monthly",
            "--by-agent",
            "--json",
            "--offline",
            "--since", formatter.string(from: since),
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        // Drain stdout before waiting so a large report can't deadlock the pipe.
        let outData = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let errData = try stderr.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard process.terminationReason == .exit else { throw CCUsageError.timedOut }
        guard process.terminationStatus == 0 else {
            throw CCUsageError.exitCode(
                process.terminationStatus,
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        do {
            return try JSONDecoder().decode(CCUnifiedReport.self, from: outData)
        } catch {
            throw CCUsageError.decoding("\(error)")
        }
    }

    private func resolveBinary() throws -> URL {
        if let cachedBinary, FileManager.default.isExecutableFile(atPath: cachedBinary.path) {
            return cachedBinary
        }

        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["NETRA_CCUSAGE"] {
            candidates.append(URL(fileURLWithPath: env))
        }

        // Next to the executable (bundled), and at the SwiftPM package root
        // (…/​.build/debug/Netra → three levels up) for `swift run` during development.
        if let exe = Bundle.main.executableURL {
            let exeDir = exe.deletingLastPathComponent()
            candidates.append(exeDir.appendingPathComponent("ccusage-bin"))
            candidates.append(
                exeDir.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("ccusage-bin")
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(
            ".local/lib/node_modules/ccusage/node_modules/@ccusage/ccusage-darwin-arm64/bin/ccusage"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ccusage"))

        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CCUsageError.binaryNotFound
        }
        cachedBinary = found
        return found
    }
}
