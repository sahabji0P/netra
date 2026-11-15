import Foundation
import os

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
    private var cachedBinary: URL?
    private var cachedVersion: String?
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "ccusage")

    /// Usage per day and agent. A recent scan reads only the trailing days
    /// (a fraction of the time and memory of a complete one); the days it
    /// reports are whole, so it can be recorded straight into the history.
    func fetchReport(_ scan: UsageScan) async throws -> CCUnifiedReport {
        var arguments = [
            "daily",
            "--sections", "daily,weekly,monthly",
            "--by-agent",
            "--json",
            "--offline",
        ]
        if scan == .recent {
            arguments += ["--since", sinceArgument(daysBack: UsageScan.recentDaysBack)]
        }
        // A complete scan reads every log the agents still have, however
        // many years that is; give it room a recent scan never needs.
        let data = try await runJSON(arguments, timeout: scan == .complete ? 120 : 20)
        do {
            return try JSONDecoder().decode(CCUnifiedReport.self, from: data)
        } catch {
            throw CCUsageError.decoding("\(error)")
        }
    }

    /// The pinned binary's version ("20.0.51"), read once. Nil when it
    /// cannot be read; the scan itself then reports the real failure.
    func version() async -> String? {
        if let cachedVersion { return cachedVersion }
        guard let data = try? await runJSON(["--version"], timeout: 10),
              let version = String(data: data, encoding: .utf8)?
                  .split(whereSeparator: \.isWhitespace).last.map(String.init) else { return nil }
        cachedVersion = version
        return version
    }

    /// The active 5-hour billing block; 60 days of history give the
    /// "usual peak" that --token-limit max measures against. The block
    /// report loads every Claude Code log whatever window it is given;
    /// loading them on one thread gives the same result in about half the
    /// memory.
    func fetchActiveBlock() async throws -> BlockStat? {
        let data = try await runJSON([
            "blocks",
            "--json",
            "--offline",
            "--single-thread",
            "--token-limit", "max",
            "--since", sinceArgument(daysBack: 60),
        ], timeout: 20)
        do {
            let report = try JSONDecoder().decode(CCBlocksReport.self, from: data)
            return BlockStat(block: report.blocks?.first { $0.isActive == true })
        } catch {
            throw CCUsageError.decoding("\(error)")
        }
    }

    private func sinceArgument(daysBack: Int) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -daysBack, to: .now) ?? .now
        return PeriodKeys.formatter("yyyyMMdd").string(from: since)
    }

    private func runJSON(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        let binary = try resolveBinary()

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments + PricingOverrides.arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("failed to spawn \(binary.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

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

        guard process.terminationReason == .exit else {
            log.error("ccusage killed by signal (args: \(arguments.joined(separator: " "), privacy: .public))")
            throw CCUsageError.timedOut
        }
        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            log.error("ccusage exited \(process.terminationStatus): \(stderrText.prefix(500), privacy: .public)")
            throw CCUsageError.exitCode(process.terminationStatus, stderrText)
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
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ccusage-bin"))
        }
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
            log.error("ccusage binary not found; searched \(candidates.map(\.path).joined(separator: ", "), privacy: .public)")
            throw CCUsageError.binaryNotFound
        }
        // Users who bypass Gatekeeper via right-click → Open (instead of the
        // `xattr -dr` from the install caveat) approve only the app bundle;
        // the nested binary stays quarantined and macOS then refuses to spawn
        // it. Since the app itself is already approved and running, clearing
        // the child's flag ourselves is safe.
        removexattr(found.path, "com.apple.quarantine", 0)
        cachedBinary = found
        return found
    }
}
