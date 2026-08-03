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

    func fetchReport() async throws -> CCUnifiedReport {
        let data = try await runJSON([
            "daily",
            "--sections", "daily,weekly,monthly",
            "--by-agent",
            "--json",
            "--offline",
            "--since", sinceArgument(daysBack: 190),
        ])
        do {
            return try JSONDecoder().decode(CCUnifiedReport.self, from: data)
        } catch {
            throw CCUsageError.decoding("\(error)")
        }
    }

    /// The active 5-hour billing block; 60 days of history give the
    /// "usual peak" that --token-limit max measures against.
    func fetchActiveBlock() async throws -> BlockStat? {
        let data = try await runJSON([
            "blocks",
            "--json",
            "--offline",
            "--token-limit", "max",
            "--since", sinceArgument(daysBack: 60),
        ])
        do {
            let report = try JSONDecoder().decode(CCBlocksReport.self, from: data)
            return BlockStat(block: report.blocks?.first { $0.isActive == true })
        } catch {
            throw CCUsageError.decoding("\(error)")
        }
    }

    private func sinceArgument(daysBack: Int) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -daysBack, to: .now) ?? .now
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: since)
    }

    private func runJSON(_ arguments: [String]) async throws -> Data {
        let binary = try resolveBinary()

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain both pipes concurrently off the actor: if either drain ran on
        // this actor (or sequentially), a full pipe buffer could deadlock a
        // hung or stderr-noisy child. FileHandle is Sendable; Process is not,
        // so the process itself stays actor-isolated below.
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        let outTask = Task.detached { try outHandle.readToEnd() ?? Data() }
        let errTask = Task.detached { try errHandle.readToEnd() ?? Data() }

        // Await exit by polling with suspension points, so the timeout keeps
        // executing even though it lives on this actor. (Awaits make the actor
        // reentrant; callers are already serialized by UsageStore.)
        let deadline = ContinuousClock.now + .seconds(timeout)
        while process.isRunning {
            if ContinuousClock.now > deadline {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(300))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CCUsageError.timedOut
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let outData = (try? await outTask.value) ?? Data()
        let errData = (try? await errTask.value) ?? Data()

        guard process.terminationReason == .exit else { throw CCUsageError.timedOut }
        guard process.terminationStatus == 0 else {
            throw CCUsageError.exitCode(
                process.terminationStatus,
                String(data: errData, encoding: .utf8) ?? ""
            )
        }

        return outData
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
