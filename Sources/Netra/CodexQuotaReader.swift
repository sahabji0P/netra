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

        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = rateLimits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double else { continue }
            let minutes = window["window_minutes"] as? Int
            let resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(
                label: label(forMinutes: minutes), usedPercent: used, resetsAt: resets
            ))
        }
        guard !windows.isEmpty else { return nil }

        var observedAt: Date?
        if let timestamp = object["timestamp"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            observedAt = iso.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        }
        return CodexQuota(
            windows: windows,
            planType: rateLimits["plan_type"] as? String,
            observedAt: observedAt
        )
    }

    private static func label(forMinutes minutes: Int?) -> String {
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
