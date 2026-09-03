import Foundation

/// A cycle rollover worth celebrating: one or more meaningful subscription
/// windows crossed their reset boundary since Netra last looked.
struct ResetCelebration: Codable, Equatable, Sendable {
    var id: UUID
    /// e.g. "Claude limit reset" or "Your limits reset".
    var title: String
}

/// One subscription window as the detector sees it: a stable key, the provider
/// it belongs to, and when it next resets.
struct ResetWindow: Equatable {
    var key: String
    var provider: String
    var resetsAt: Date?
}

/// Detects when a subscription window rolls into a new cycle, exactly once per
/// rollover. State is a map of the reset boundary already acknowledged per
/// window; seeding on first sight means Netra never celebrates a window it has
/// only just started watching. Every real quota window counts — including the
/// 5-hour ones — but never the labelled local block estimate, which is not a
/// provider-reported reset (it is `activeBlock`, not a `QuotaWindow`).
struct ResetCelebrationDetector {
    /// Given the windows now observed and the boundaries previously
    /// acknowledged, returns the celebration (if any) plus the boundaries to
    /// persist. A window celebrates when its acknowledged boundary both differs
    /// from the current one and has already passed — a genuine rollover, not a
    /// first sighting or a schedule change.
    static func evaluate(
        windows: [ResetWindow],
        acknowledged: [String: Date],
        now: Date = .now,
        displayName: (String) -> String = AgentPalette.displayName
    ) -> (celebration: ResetCelebration?, acknowledged: [String: Date]) {
        var updated: [String: Date] = [:]
        var resetProviders: Set<String> = []

        for window in windows {
            guard let resetsAt = window.resetsAt else {
                // No reset time: carry any prior value, can't detect a rollover.
                if let prior = acknowledged[window.key] { updated[window.key] = prior }
                continue
            }
            updated[window.key] = resetsAt
            guard let prior = acknowledged[window.key] else { continue } // first sight
            if prior != resetsAt && now >= prior {
                resetProviders.insert(window.provider)
            }
        }

        guard !resetProviders.isEmpty else {
            return (nil, updated)
        }
        let names = resetProviders.map(displayName).sorted()
        let title = names.count == 1 ? "\(names[0]) limit reset" : "Your limits reset"
        return (ResetCelebration(id: UUID(), title: title), updated)
    }
}

/// Persists the detector's acknowledged reset boundaries, so a reset is
/// celebrated once and not re-fired across refreshes or relaunches.
struct ResetCelebrationStore {
    private enum Key {
        static let acknowledged = "celebrate.acknowledgedResets"
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func acknowledged() -> [String: Date] {
        guard let data = defaults.data(forKey: Key.acknowledged),
              let raw = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return raw
    }

    func setAcknowledged(_ value: [String: Date]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Key.acknowledged)
    }
}

extension UsageSnapshot {
    /// The meaningful subscription windows across every provider, tagged for
    /// reset detection. Excludes short-cadence windows (the Claude 5h block).
    func celebratableWindows() -> [ResetWindow] {
        var windows: [ResetWindow] = []
        // Raw windows, not activeWindows(): a window must stay observable
        // while its old reset boundary passes, so the rollover to the new
        // boundary can be detected rather than the key disappearing.
        func add(_ provider: String, _ quotaWindows: [QuotaWindow]) {
            for window in quotaWindows {
                windows.append(ResetWindow(
                    key: "\(provider):\(window.label)",
                    provider: provider,
                    resetsAt: window.resetsAt
                ))
            }
        }
        if let claude = claudeQuota { add("claude", claude.windows) }
        if let codex = codexQuota { add("codex", codex.windows) }
        if let cursor = cursorQuota { add("cursor", cursor.windows) }
        return windows
    }
}
