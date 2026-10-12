import Foundation

/// One provider's real limit windows as the island detector sees them: the
/// account they belong to, and whether the provider itself says a limit was
/// hit. Built from the snapshot because `ProviderLimits` drops both the
/// account and the `.lastSeen` provenance.
struct IslandLimitState: Equatable, Sendable {
    var agent: String
    /// `AccountIdentity.key` when known. Windows of different accounts are
    /// never compared, so a switch is a first sighting, not a crossing.
    var accountKey: String?
    var windows: [QuotaWindow]
    /// The provider flagged an exhausted limit (Codex `rate_limit_reached_type`).
    var providerReportsLimitReached = false
}

extension UsageSnapshot {
    /// Provider-reported limit windows for the island, in `order`, skipping
    /// hidden providers. The local Claude block estimate is not a quota and
    /// Netra's own `.lastSeen` records are old readings, so neither appears.
    func islandLimitStates(
        order: [String] = AppPreferences.limitProviders,
        isVisible: (String) -> Bool = { _ in true },
        now: Date = .now
    ) -> [IslandLimitState] {
        providerLimits(order: order, now: now)
            .filter { !$0.isEstimate && isVisible($0.agent) }
            .compactMap { limits in
                switch limits.agent {
                case "claude":
                    guard let quota = claudeQuota, quota.source != .lastSeen else { return nil }
                    return IslandLimitState(agent: "claude", accountKey: quota.accountKey, windows: limits.windows)
                case "codex":
                    guard let quota = codexQuota, quota.source != .lastSeen else { return nil }
                    return IslandLimitState(
                        agent: "codex", accountKey: quota.accountKey, windows: limits.windows,
                        providerReportsLimitReached: quota.limitReachedType != nil
                    )
                default:
                    return IslandLimitState(agent: limits.agent, accountKey: nil, windows: limits.windows)
                }
            }
    }
}

/// Pure rules turning two limit observations into island activities.
///
/// - `runningHot`: a window moved from below the alert threshold to at or
///   above it within one reset cycle, or a new cycle opened already above it.
/// - `limitReached`: the same, at 100%, or the provider newly reports a
///   reached limit. Replaces `runningHot` for that window in one evaluation.
///
/// Nothing fires on first sight (no previous observation, or a provider,
/// account, or window not seen before), and windows without a reset have no cycle to key
/// on, so they never fire. Ids are per provider, window, and cycle; the pure
/// detector re-emits after a dip below the threshold, and the queue's shown-id
/// set keeps that to once per cycle. Resets are not detected here: they come
/// from `ResetCelebrationDetector` via `IslandActivity.windowReset(from:)`.
enum IslandActivityDetector {
    static func activities(
        previous: [IslandLimitState]?,
        current: [IslandLimitState],
        threshold: Double,
        parkedAlternative: (String) -> String? = { _ in nil },
        now: Date = .now
    ) -> [IslandActivity] {
        guard let previous else { return [] }
        let threshold = min(max(threshold, 1), 100)
        var activities: [IslandActivity] = []

        for state in current {
            guard let before = previous.first(where: {
                $0.agent == state.agent && $0.accountKey == state.accountKey
            }) else { continue }

            var reachedWindows: Set<String> = []
            for window in state.windows {
                // A window not seen before only seeds, like a new provider.
                guard let resetsAt = window.resetsAt,
                      before.windows.contains(where: { $0.label == window.label }) else { continue }
                // Same label, different reset: a new cycle, so it starts from 0.
                let baseline = before.windows.first {
                    $0.label == window.label && $0.resetsAt.map {
                        abs($0.timeIntervalSince(resetsAt)) < ResetCelebrationDetector.sameWindowTolerance
                    } == true
                }?.usedPercent ?? 0

                if baseline < 100, window.usedPercent >= 100 {
                    reachedWindows.insert(window.label)
                    activities.append(limitReached(state, window, current: current, threshold: threshold,
                                                   parkedAlternative: parkedAlternative, now: now))
                } else if baseline < threshold, window.usedPercent >= threshold {
                    activities.append(IslandActivity(
                        id: id("hot", state.agent, window),
                        agent: state.agent,
                        kind: .runningHot(windowLabel: window.label, usedPercent: window.usedPercent,
                                          resetsAt: resetsAt),
                        createdAt: now
                    ))
                }
            }

            // The provider's own flag: pin it to the fullest dated window, so
            // it shares an id with that window's 100% crossing.
            if state.providerReportsLimitReached, !before.providerReportsLimitReached,
               let window = state.windows.filter({ $0.resetsAt != nil }).max(by: { $0.usedPercent < $1.usedPercent }),
               !reachedWindows.contains(window.label) {
                activities.removeAll { $0.id == id("hot", state.agent, window) }
                activities.append(limitReached(state, window, current: current, threshold: threshold,
                                               parkedAlternative: parkedAlternative, now: now))
            }
        }
        return activities
    }

    /// Convenience over two snapshots. `previous == nil` seeds silently.
    static func activities(
        previous: UsageSnapshot?,
        current: UsageSnapshot,
        threshold: Double,
        order: [String] = AppPreferences.limitProviders,
        isVisible: (String) -> Bool = { _ in true },
        parkedAlternative: (String) -> String? = { _ in nil },
        now: Date = .now
    ) -> [IslandActivity] {
        activities(
            previous: previous?.islandLimitStates(order: order, isVisible: isVisible, now: now),
            current: current.islandLimitStates(order: order, isVisible: isVisible, now: now),
            threshold: threshold,
            parkedAlternative: parkedAlternative,
            now: now
        )
    }

    /// "limit:codex:5h:<cycle>"; window labels are lowercased like the
    /// notification keys.
    static func id(_ prefix: String, _ agent: String, _ window: QuotaWindow) -> String {
        "\(prefix):\(agent):\(window.label.lowercased()):\(UsageAlertEvaluator.cycleIdentifier(window.resetsAt))"
    }

    private static func limitReached(
        _ state: IslandLimitState,
        _ window: QuotaWindow,
        current: [IslandLimitState],
        threshold: Double,
        parkedAlternative: (String) -> String?,
        now: Date
    ) -> IslandActivity {
        IslandActivity(
            id: id("limit", state.agent, window),
            agent: state.agent,
            kind: .limitReached(
                windowLabel: window.label,
                resetsAt: window.resetsAt,
                alternative: alternative(to: state.agent, in: current, threshold: threshold)
                    ?? parkedAlternative(state.agent)
            ),
            createdAt: now
        )
    }

    /// The first other visible provider, in the caller's order, with every
    /// window below the threshold. Information only: nothing acts on it.
    static func alternative(to agent: String, in states: [IslandLimitState], threshold: Double) -> String? {
        states.first { state in
            state.agent != agent && !state.providerReportsLimitReached && !state.windows.isEmpty
                && state.windows.allSatisfy { $0.usedPercent < threshold }
        }.map { AgentPalette.shortName($0.agent) }
    }
}

/// Stateful wrapper for the integration point: remembers the last observation
/// so each fresh snapshot is compared with the one before it. The first
/// observation after launch only seeds.
struct IslandLimitWatcher {
    private(set) var previous: [IslandLimitState]?

    mutating func observe(
        _ snapshot: UsageSnapshot,
        threshold: Double,
        order: [String] = AppPreferences.limitProviders,
        isVisible: (String) -> Bool = { _ in true },
        parkedAlternative: (String) -> String? = { _ in nil },
        now: Date = .now
    ) -> [IslandActivity] {
        let states = snapshot.islandLimitStates(order: order, isVisible: isVisible, now: now)
        defer { previous = states }
        return IslandActivityDetector.activities(
            previous: previous, current: states, threshold: threshold,
            parkedAlternative: parkedAlternative, now: now
        )
    }
}

// MARK: - Adapters for existing app events

extension IslandActivity {
    /// A reset already detected by `ResetCelebrationDetector`. The agent is
    /// recovered from a single-provider title; the combined title has none.
    static func windowReset(from celebration: ResetCelebration, at now: Date = .now) -> IslandActivity {
        let agent = AppPreferences.limitProviders.first {
            celebration.title == "\(AgentPalette.displayName($0)) limit reset"
        }
        return IslandActivity(
            id: "reset:\(celebration.id.uuidString)",
            agent: agent,
            kind: .windowReset(title: celebration.title),
            createdAt: now
        )
    }

    /// A completed switch (`AccountStore.onSwitch`). Time-stamped, because the
    /// same account can be switched back to more than once a session.
    static func accountSwitched(provider: AccountProvider, accountLabel: String, at now: Date = .now) -> IslandActivity {
        IslandActivity(
            id: "account:\(provider.rawValue):\(accountLabel.lowercased()):\(Int(now.timeIntervalSince1970 * 1000))",
            agent: provider.agent,
            kind: .accountSwitched(accountLabel: accountLabel),
            createdAt: now
        )
    }

    /// Reads the now-active account's label from the store; nil when the
    /// account is not managed.
    @MainActor
    static func accountSwitched(provider: AccountProvider, in store: AccountStore, at now: Date = .now) -> IslandActivity? {
        guard let account = store.activeAccount(for: provider) else { return nil }
        return accountSwitched(provider: provider, accountLabel: store.roster.label(for: account), at: now)
    }

    /// A keep-awake change; nil when the mode did not change.
    static func keepAwake(from old: AwakeController.Mode, to new: AwakeController.Mode, at now: Date = .now) -> IslandActivity? {
        guard old != new else { return nil }
        let until: Date? = if case .until(let date) = new { date } else { nil }
        let isOn = new != .off
        return IslandActivity(
            id: "awake:\(isOn ? "on" : "off"):\(Int(now.timeIntervalSince1970 * 1000))",
            agent: nil,
            kind: .keepAwake(isOn: isOn, until: until),
            createdAt: now
        )
    }
}
