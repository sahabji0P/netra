import AppKit
import SwiftUI

// MARK: - Shared island data rules

/// What the island shows, derived from the snapshot with the popover's
/// rules (hidden providers, limit order, stale labels), kept out of the views
/// so they are testable.
@MainActor
enum IslandData {
    /// Today's cost with hidden providers removed, matching the popover's
    /// headline number.
    static func today(_ snapshot: UsageSnapshot?, preferences: AppPreferences, now: Date = .now) -> PeriodRow? {
        snapshot?.currentRow(for: .today, now: now).filtered(hidingProviders: preferences.hiddenMenuProviders)
    }

    /// Limit cards in the user's order, minus hidden providers. Empty when
    /// the user turned limits off for the popover.
    static func limitCards(_ snapshot: UsageSnapshot?, preferences: AppPreferences, now: Date = .now) -> [ProviderLimits] {
        guard preferences.showsLimits else { return [] }
        return (snapshot?.providerLimits(order: preferences.orderedLimitProviders, now: now) ?? [])
            .filter { preferences.isProviderVisibleInMenu($0.agent) }
    }

    /// The provider's headline window: each adapter lists it first (Claude
    /// and Codex the 5-hour session, Cursor its included usage), so a side
    /// pool such as Cursor's API-models lane never stands for the provider.
    static func primaryWindow(_ limits: ProviderLimits) -> QuotaWindow? {
        limits.windows.first
    }

    /// The provider closest to its limit: the one the resting island shows.
    static func hottest(_ cards: [ProviderLimits]) -> ProviderLimits? {
        cards.max { lhs, rhs in
            (primaryWindow(lhs)?.usedPercent ?? -1) < (primaryWindow(rhs)?.usedPercent ?? -1)
        }
    }

    /// Mirrors the popover header: "Updated 2m ago", "Saved data · 3h ago".
    static func status(_ state: UsageStore.State, fetchedAt: Date?, now: Date) -> (text: String, isWarning: Bool) {
        switch state {
        case .refreshing: return ("Refreshing…", false)
        case .failed: return (fetchedAt == nil ? "Refresh failed" : "Couldn't refresh · showing saved", true)
        case .empty: return ("No data yet", false)
        case .fresh, .stale:
            guard let fetchedAt else { return ("", false) }
            let age = Format.age(since: fetchedAt, now: now)
            return state == .stale ? ("Saved data · \(age)", true) : ("Updated \(age)", false)
        }
    }

    /// Why Claude has no card although it was used this week; nil when a
    /// card shows (or Claude is idle or hidden). The popover keeps the long
    /// explanation and the Keychain button; the island only says so.
    static func missingClaudeReason(
        _ snapshot: UsageSnapshot?, cards: [ProviderLimits], preferences: AppPreferences,
        keychainNeedsApproval: Bool
    ) -> String? {
        guard let snapshot, preferences.showsLimits,
              preferences.isProviderVisibleInMenu("claude"),
              !cards.contains(where: { $0.agent == "claude" }),
              (snapshot.currentRow(for: .week).agentStat("claude")?.totalTokens ?? 0) > 0
        else { return nil }
        if preferences.claudeQuotaEnabled, keychainNeedsApproval {
            return "Netra needs Keychain access to read Claude Code's sign-in. Open the menu to allow it."
        }
        if preferences.claudeQuotaEnabled {
            return "Couldn't get live limits from Anthropic. Check that Claude Code is signed in."
        }
        return "Claude Code hasn't cached fresh limits on this Mac yet."
    }
}

enum IslandText {
    /// "1:04:09" under a day, "2d 4h" beyond; "now" once it has passed.
    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "now" }
        let total = Int(seconds.rounded(.up))
        guard total < 86400 else { return LimitText.duration(seconds) }
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "1h 12m", or "now" once the reset time has passed.
    static func resetsIn(_ date: Date, now: Date) -> String {
        let left = date.timeIntervalSince(now)
        return left <= 0 ? "now" : LimitText.duration(left)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }
}

// MARK: - Compact (resting and peek)

/// The always-visible island: one wing on the left of the notch showing the
/// provider closest to its limit. The right of the notch is left to the
/// menu-bar items, where Netra's own item already shows today's cost.
struct IslandCompactView: View {
    var store: UsageStore
    var preferences: AppPreferences
    /// Width of the camera housing the content must stay clear of.
    var notchGap: CGFloat = IslandCompactContent.defaultNotchGap

    @Environment(\.islandMetrics) private var metrics

    var body: some View {
        IslandCompactContent(
            snapshot: store.snapshot, preferences: preferences, notchGap: notchGap,
            barHeight: metrics.hasNotch ? metrics.notchHeight : NotchGeometry.fallbackBarHeight
        )
    }
}

struct IslandCompactContent: View {
    var snapshot: UsageSnapshot?
    var preferences: AppPreferences
    var notchGap: CGFloat = defaultNotchGap
    /// Height of the menu-bar band the content is centered in.
    var barHeight: CGFloat = height

    static let defaultNotchGap: CGFloat = 190
    static let height: CGFloat = 32

    var body: some View {
        // Limits move slowly; a slow tick keeps the always-visible window
        // from waking often.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let cards = IslandData.limitCards(snapshot, preferences: preferences, now: context.date)
            HStack(spacing: 0) {
                leading(IslandData.hottest(cards))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notchGap)
            }
            .padding(.leading, 12)
            .frame(height: barHeight)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func leading(_ limits: ProviderLimits?) -> some View {
        HStack(spacing: 6) {
            if let limits, let window = IslandData.primaryWindow(limits) {
                let remaining = preferences.barsShowRemaining && !limits.isEstimate
                ProviderLogo(agent: limits.agent, size: 14)
                VStack(alignment: .leading, spacing: -1) {
                    Text(limits.isEstimate
                         ? Format.peakPercent(window.usedPercent)
                         : IslandText.percent(remaining ? 100 - window.usedPercent : window.usedPercent))
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(window.usedPercent >= 90 ? IslandTheme.critical : .white)
                        .contentTransition(.numericText())
                    Text(limits.isEstimate ? "of peak" : remaining ? "left" : "used")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limits.flatMap { limits in
            IslandData.primaryWindow(limits).map {
                "\(AgentPalette.displayName(limits.agent)) \(LimitText.title($0.label)): \(IslandText.percent($0.usedPercent)) used"
            }
        } ?? "No limits")
    }
}

// MARK: - Live activity

/// An account switch, drawn as a hand-over rather than as an alert: the
/// account that was in use fades to the left, the new one stands in its
/// provider's color with its name, and the room it has is on the right.
struct IslandAccountSwitchView: View {
    var label: String
    var account: ManagedAccount
    var previous: ManagedAccount?
    var showRemaining: Bool

    var body: some View {
        let agent = account.provider.agent
        let color = AgentPalette.color(for: agent)
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                if let previous {
                    AccountAvatar(account: previous, size: 20)
                        .saturation(0)
                        .opacity(0.45)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                AccountAvatar(account: account, size: 32)
                    .padding(3)
                    .overlay { Circle().strokeBorder(color, lineWidth: 1.5) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    ProviderLogo(agent: agent, size: 10)
                    Text(([AgentPalette.shortName(agent), "now in use"] + [account.identity.plan].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                ForEach(AccountText.glanceWindows(account.parkedWindows(now: .now)), id: \.self) { parked in
                    AccountMiniMeter(parked: parked, agent: agent, showRemaining: showRemaining, width: 52)
                }
            }
        }
        .padding(.horizontal, 16)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Switched \(AgentPalette.shortName(agent)) to \(label)")
    }
}

/// The island grown for one event. Every kind shares one height so the
/// shell's morph never jumps between kinds.
struct IslandActivityView: View {
    var activity: IslandActivity
    /// Whether meters count what is left, like the bars everywhere else.
    var showRemaining = false

    static let height: CGFloat = 64

    var body: some View {
        if case .accountSwitched(let label, let account?, let previous) = activity.kind {
            IslandAccountSwitchView(label: label, account: account, previous: previous, showRemaining: showRemaining)
                .frame(height: Self.height)
        } else {
            standard
        }
    }

    private var standard: some View {
        HStack(spacing: 12) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var agentName: String {
        activity.agent.map(AgentPalette.displayName) ?? "Netra"
    }

    @ViewBuilder
    private var mark: some View {
        switch activity.kind {
        case .keepAwake(let isOn, _):
            Image(systemName: isOn ? "eye.fill" : "eye.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn ? .white : IslandTheme.secondaryText)
                .frame(width: 28, height: 28)
        default:
            if let agent = activity.agent {
                ProviderLogo(agent: agent, size: 26)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
        }
    }

    private var title: String {
        switch activity.kind {
        case .runningHot: "\(agentName) is running hot"
        case .limitReached: "\(activity.agent.map(AgentPalette.shortName) ?? "A") limit reached"
        case .windowReset(let title): title
        case .accountSwitched: "Switched \(activity.agent.map(AgentPalette.shortName).map { "\($0) account" } ?? "account")"
        case .keepAwake(let isOn, _): isOn ? "Keeping your Mac awake" : "Keep awake is off"
        }
    }

    private var subtitle: String? {
        switch activity.kind {
        case .runningHot(let label, _, let resetsAt):
            let window = LimitText.title(label)
            return resetsAt.map { "\(window) · resets in \(IslandText.resetsIn($0, now: .now))" } ?? window
        case .limitReached(let label, _, let alternative):
            // Information only: Netra never switches on its own.
            let window = LimitText.title(label)
            return alternative.map { "\(window) · \($0) has room left" } ?? window
        case .windowReset:
            return "A new window started with your full limit"
        case .accountSwitched(let label, _, _):
            return "Now signed in as \(label)"
        case .keepAwake(let isOn, let until):
            guard isOn else { return "Your Mac can sleep normally" }
            return until.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until turned off"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity.kind {
        case .runningHot(_, let used, _):
            Text(IslandText.percent(used))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(used >= 90 ? IslandTheme.critical : IslandTheme.warning)
        case .limitReached(_, let resetsAt, _):
            if let resetsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("resets in")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(IslandTheme.secondaryText)
                        Text(IslandText.countdown(resetsAt.timeIntervalSince(context.date)))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(IslandTheme.critical)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
            } else {
                Text("100%")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(IslandTheme.critical)
            }
        case .windowReset:
            ZStack {
                Circle().strokeBorder(IslandTheme.fresh, lineWidth: 4.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(IslandTheme.fresh)
            }
            .frame(width: 38, height: 38)
        case .accountSwitched:
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(activity.agent.map(AgentPalette.color(for:)) ?? .white)
        case .keepAwake(let isOn, _):
            Text(isOn ? "On" : "Off")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isOn ? Color.white : IslandTheme.track, in: Capsule())
        }
    }
}
