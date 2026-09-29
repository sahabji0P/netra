import Foundation

/// Extracts the last server-reported rate limits from Codex CLI session
/// rollouts (~/.codex/sessions/**/*.jsonl). The CLI writes a `rate_limits`
/// snapshot with every token-count event, so the newest one is the real quota
/// as OpenAI last stated it — no network, no credentials.
enum CodexQuotaReader {
    static func read() -> CodexQuota? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }

        // The newest session that has a rate-limit snapshot wins.
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(5) {
            if let quota = latestRateLimits(in: file.url) { return quota }
        }
        return nil
    }

    private static func latestRateLimits(in url: URL) -> CodexQuota? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        for line in content.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let quota = quota(fromLine: String(line)) { return quota }
        }
        return nil
    }

    /// Parses one rollout line. Split out so the (unstable) Codex CLI log
    /// contract can be locked down with fixture tests.
    static func quota(fromLine line: String) -> CodexQuota? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = findKey("rate_limits", in: object) as? [String: Any]
        else { return nil }
        // Rollouts interleave snapshots for other limit buckets (e.g.
        // "premium" credits); only the main "codex" bucket is the plan quota.
        if let limitID = rateLimits["limit_id"] as? String, limitID != "codex" { return nil }

        let observedAt = (object["timestamp"] as? String).flatMap(ISODate.parse)

        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = rateLimits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double else { continue }
            let minutes = window["window_minutes"] as? Int
            // Codex ≥ v0.48 writes `resets_at` (epoch seconds); older CLIs
            // wrote `resets_in_seconds` relative to the line's timestamp.
            var resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            if resets == nil, let observedAt,
               let inSeconds = window["resets_in_seconds"] as? Double {
                resets = observedAt.addingTimeInterval(inSeconds)
            }
            windows.append(QuotaWindow(
                label: label(forMinutes: minutes), usedPercent: used, resetsAt: resets,
                durationSeconds: minutes.map { Double($0) * 60 }
            ))
        }
        guard !windows.isEmpty else { return nil }

        return CodexQuota(
            windows: windows,
            planType: rateLimits["plan_type"] as? String,
            observedAt: observedAt,
            source: .sessionLog,
            limitReachedType: rateLimits["rate_limit_reached_type"] as? String
        )
    }

    static func label(forMinutes minutes: Int?) -> String {
        guard let minutes else { return "limit" }
        switch minutes {
        case ..<1500: return "\(Int((Double(minutes) / 60).rounded()))h"
        case ..<20000: return "weekly"
        default: return "monthly"
        }
    }

    private static func findKey(_ key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values {
                if let found = findKey(key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findKey(key, in: value) { return found }
            }
        }
        return nil
    }
}

/// Live Codex limits from the Codex CLI's own app server
/// (`codex app-server`, JSON-RPC over stdio, `account/rateLimits/read`). The
/// CLI handles its login and asks OpenAI directly, so this is current even
/// when no Codex session ran recently — session logs only reflect the last
/// turn, and go stale across resets (including redeemed reset credits).
enum CodexLiveQuota {
    static let timeout: TimeInterval = 12

    /// Blocking; call off the main actor. Nil when Codex is not installed,
    /// not logged in, or the server does not answer in time.
    /// `codexHome` points the CLI at another `CODEX_HOME` (a parked
    /// account's private copy); nil uses the live sign-in.
    static func fetch(now: Date = .now, codexHome: URL? = nil) -> CodexQuota? {
        guard let binary = resolveBinary() else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                               environment["PATH"] ?? ""].joined(separator: ":")
        if let codexHome { environment["CODEX_HOME"] = codexHome.path }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let reader = LineCollector()
        let answered = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                answered.signal()
            } else if reader.append(chunk, untilResponseID: 2) {
                answered.signal()
            }
        }
        do { try process.run() } catch { return nil }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "netra", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
        ]
        for request in requests {
            guard var line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            line.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: line)
        }
        guard answered.wait(timeout: .now() + timeout) == .success,
              let result = reader.response(id: 2)?["result"] as? [String: Any]
        else { return nil }
        return quota(fromRateLimits: result, now: now)
    }

    /// Maps an `account/rateLimits/read` result. Split out for fixtures.
    static func quota(fromRateLimits result: [String: Any], now: Date = .now) -> CodexQuota? {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        else { return nil }
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            windows.append(QuotaWindow(
                label: CodexQuotaReader.label(forMinutes: minutes),
                usedPercent: used,
                resetsAt: (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                durationSeconds: minutes.map { Double($0) * 60 }
            ))
        }
        guard !windows.isEmpty else { return nil }
        let credits = result["rateLimitResetCredits"] as? [String: Any]
        let banked = (credits?["credits"] as? [[String: Any]])?.compactMap { credit -> LimitResetCredit? in
            // Only redeemable credits count; redeemed/redeeming ones are spent.
            if let status = credit["status"] as? String, status != "available" { return nil }
            return LimitResetCredit(
                title: JSONValue.string(credit["title"]),
                grantedAt: JSONValue.number(credit["grantedAt"]).map { Date(timeIntervalSince1970: $0) },
                expiresAt: JSONValue.number(credit["expiresAt"]).map { Date(timeIntervalSince1970: $0) }
            )
        }
        return CodexQuota(
            windows: windows,
            planType: limits["planType"] as? String,
            observedAt: now,
            source: .live,
            limitReachedType: limits["rateLimitReachedType"] as? String,
            resetCreditsAvailable: (credits?["availableCount"] as? NSNumber)?.intValue,
            resetCredits: banked
        )
    }

    static func resolveBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["NETRA_CODEX"],
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            // ChatGPT.app bundles the Codex CLI.
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Accumulates newline-delimited JSON-RPC output from the app server.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]

    /// Returns true once the response with `id` has arrived.
    func append(_ chunk: Data, untilResponseID id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let responseID = (object["id"] as? NSNumber)?.intValue {
                responses[responseID] = object
            }
        }
        return responses[id] != nil
    }

    func response(id: Int) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return responses[id]
    }
}
