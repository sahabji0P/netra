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

        var windows = limitWindows(utilization["limits"] as? [[String: Any]] ?? [])
        if windows.isEmpty {
            // Older Claude Code versions may lack `limits[]`; fall back to the
            // top-level window objects.
            func addWindow(key: String, label: String) {
                guard let window = utilization[key] as? [String: Any],
                      let percent = window["utilization"] as? NSNumber else { return }
                let resets = (window["resets_at"] as? String)
                    .flatMap(ClaudeQuotaFetcher.parseDate)
                windows.append(QuotaWindow(
                    label: label, usedPercent: percent.doubleValue, resetsAt: resets
                ))
            }
            addWindow(key: "five_hour", label: "5h")
            addWindow(key: "seven_day", label: "weekly")
            addWindow(key: "seven_day_opus", label: "weekly · Opus")
            addWindow(key: "seven_day_sonnet", label: "weekly · Sonnet")
        }
        guard !windows.isEmpty else { return nil }

        return ClaudeQuota(
            windows: windows,
            subscriptionType: planLabel(from: object),
            fetchedAt: fetchedAt,
            source: .claudeCodeCache
        )
    }

    /// `limits[]` is richer than the fixed window keys: it carries the live
    /// model-scoped weekly bucket (which the fixed keys report as null).
    private static func limitWindows(_ limits: [[String: Any]]) -> [QuotaWindow] {
        limits.compactMap { limit in
            guard let percent = limit["percent"] as? NSNumber,
                  let kind = limit["kind"] as? String else { return nil }
            let label: String
            switch kind {
            case "session": label = "5h"
            case "weekly_all": label = "weekly"
            case "weekly_scoped":
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = model?["display_name"] as? String
                label = name.map { "weekly · \($0)" } ?? "weekly · model"
            default: label = kind.replacingOccurrences(of: "_", with: " ")
            }
            let resets = (limit["resets_at"] as? String)
                .flatMap(ClaudeQuotaFetcher.parseDate)
            return QuotaWindow(label: label, usedPercent: percent.doubleValue, resetsAt: resets)
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
