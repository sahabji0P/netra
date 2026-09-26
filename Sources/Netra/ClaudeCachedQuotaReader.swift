import Foundation

/// Real Claude subscription limits without Keychain or network: Claude Code
/// caches the server's own quota response in `~/.claude.json` under
/// `cachedUsageUtilization`. Freshness depends on when Claude Code last
/// talked to Anthropic; `fetchedAtMs` records exactly that, so the UI can
/// say how old the numbers are.
enum ClaudeCachedQuotaReader {
    static func read(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeQuota? {
        let url = homeDirectory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return quota(fromClaudeConfig: data)
    }

    /// Parses the (unofficial, schema-unstable) Claude Code config payload.
    /// Split out so the contract can be locked down with fixture tests.
    static func quota(fromClaudeConfig data: Data) -> ClaudeQuota? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = object["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any] else { return nil }

        let fetchedAt = (cached["fetchedAtMs"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? .now

        let windows = windows(from: utilization)
        guard !windows.isEmpty else { return nil }

        return ClaudeQuota(
            windows: windows,
            subscriptionType: planLabel(from: object),
            fetchedAt: fetchedAt,
            source: .claudeCodeCache,
            extraUsage: ClaudeExtraUsage.parse(utilization["extra_usage"])
        )
    }

    /// `limits[]` is richer than the fixed window keys: it carries the live
    /// model-scoped weekly bucket (which the fixed keys report as null).
    /// Windows from an Anthropic usage payload — Claude Code's cached copy
    /// and the live OAuth response share this shape. `limits[]` carries
    /// model-scoped weekly windows (e.g. "weekly · Fable") the fixed keys
    /// report as null, but it can also be partial (captured responses list
    /// only the session). Merge: limits first, then fixed keys it lacks.
    static func windows(from payload: [String: Any]) -> [QuotaWindow] {
        var windows = limitWindows(payload["limits"] as? [[String: Any]] ?? [])
        let fixed: [(key: String, label: String, duration: Double)] = [
            ("five_hour", "5h", 5 * 3600),
            ("seven_day", "weekly", 7 * 86400),
            ("seven_day_opus", "weekly · Opus", 7 * 86400),
            ("seven_day_sonnet", "weekly · Sonnet", 7 * 86400),
        ]
        for window in fixed where !windows.contains(where: { $0.label == window.label }) {
            guard let object = payload[window.key] as? [String: Any],
                  let percent = JSONValue.number(object["utilization"]) else { continue }
            windows.append(QuotaWindow(
                label: window.label, usedPercent: percent,
                resetsAt: (object["resets_at"] as? String).flatMap(ISODate.parse),
                durationSeconds: window.duration
            ))
        }
        return windows
    }

    private static func limitWindows(_ limits: [[String: Any]]) -> [QuotaWindow] {
        limits.compactMap { limit in
            guard let percent = limit["percent"] as? NSNumber,
                  let kind = limit["kind"] as? String else { return nil }
            let label: String
            var duration: Double?
            switch kind {
            case "session": label = "5h"; duration = 5 * 3600
            case "weekly_all": label = "weekly"; duration = 7 * 86400
            case "weekly_scoped":
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = model?["display_name"] as? String
                label = name.map { "weekly · \($0)" } ?? "weekly · model"
                duration = 7 * 86400
            default: label = kind.replacingOccurrences(of: "_", with: " ")
            }
            let resets = (limit["resets_at"] as? String)
                .flatMap(ISODate.parse)
            return QuotaWindow(
                label: label, usedPercent: percent.doubleValue, resetsAt: resets, durationSeconds: duration
            )
        }
    }

    /// `oauthAccount.userRateLimitTier` names the actual plan
    /// (e.g. "default_claude_max_5x") more reliably than subscriptionType.
    private static func planLabel(from object: [String: Any]) -> String? {
        guard let account = object["oauthAccount"] as? [String: Any] else { return nil }
        guard let tier = account["userRateLimitTier"] as? String else { return nil }
        let known: [(needle: String, label: String)] = [
            ("max_20x", "Max 20x"), ("max_5x", "Max 5x"),
            ("team", "Team"), ("enterprise", "Enterprise"),
            ("pro", "Pro"), ("free", "Free"),
        ]
        return known.first { tier.contains($0.needle) }?.label ?? tier
    }
}
