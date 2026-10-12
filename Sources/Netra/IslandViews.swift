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

    /// The single window closest to exhaustion across every card. Real
    /// provider quotas win over Claude's local estimate.
    static func tightest(_ cards: [ProviderLimits]) -> (limits: ProviderLimits, window: QuotaWindow)? {
        let candidates = cards.filter { !$0.isEstimate }.isEmpty ? cards : cards.filter { !$0.isEstimate }
        return candidates
            .compactMap { limits in limits.mostConstrained.map { (limits, $0) } }
            .max { $0.1.usedPercent < $1.1.usedPercent }
    }

    /// Windows shortest first: the ring order (outer = shortest).
    static func ringOrder(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.enumerated().sorted { lhs, rhs in
            let l = lhs.element.durationSeconds ?? .greatestFiniteMagnitude
            let r = rhs.element.durationSeconds ?? .greatestFiniteMagnitude
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
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

    /// One short word for a window inside a ring: "5h", "week", "Fable",
    /// "included".
    static func ringLabel(_ window: QuotaWindow, isEstimate: Bool) -> String {
        if isEstimate { return "5h block" }
        let label = window.label
        if label == "weekly" { return "week" }
        if label.hasPrefix("weekly · ") { return String(label.dropFirst("weekly · ".count)) }
        return label.split(separator: " ").first.map(String.init) ?? label
    }

    /// The amount beside a window row: "92%", "54% left", "1.3× of peak".
    static func rowAmount(_ window: QuotaWindow, showRemaining: Bool, isEstimate: Bool) -> String {
        if isEstimate { return Format.peakPercent(window.usedPercent) }
        let used = min(max(window.usedPercent, 0), 100)
        return showRemaining ? "\(Int((100 - used).rounded()))% left" : "\(Int(used.rounded()))%"
    }
}

// MARK: - Compact (resting)

/// The resting island: the tightest limit's provider and ring on the left of
/// the notch, today's cost on the right, nothing over the camera itself.
struct IslandCompactView: View {
    var store: UsageStore
    var preferences: AppPreferences
    var awake: AwakeController
    /// Width of the camera housing the content must stay clear of.
    var notchGap: CGFloat = IslandCompactContent.defaultNotchGap

    var body: some View {
        IslandCompactContent(
            snapshot: store.snapshot, state: store.state, preferences: preferences,
            isAwake: awake.isAwake, notchGap: notchGap
        )
    }
}

struct IslandCompactContent: View {
    var snapshot: UsageSnapshot?
    var state: UsageStore.State
    var preferences: AppPreferences
    var isAwake: Bool
    var notchGap: CGFloat = defaultNotchGap

    static let defaultNotchGap: CGFloat = 190
    static let height: CGFloat = 32

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let cards = IslandData.limitCards(snapshot, preferences: preferences, now: context.date)
            HStack(spacing: 0) {
                leading(IslandData.tightest(cards))
                Spacer(minLength: notchGap)
                trailing(now: context.date)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func leading(_ tightest: (limits: ProviderLimits, window: QuotaWindow)?) -> some View {
        HStack(spacing: 6) {
            if let tightest {
                ProviderLogo(agent: tightest.limits.agent, size: 14)
                IslandRing(
                    fraction: min(max(tightest.window.usedPercent, 0), 100) / 100,
                    color: IslandRingColor.color(agent: tightest.limits.agent, usedPercent: tightest.window.usedPercent),
                    lineWidth: 2.5
                )
                .frame(width: 15, height: 15)
                Text(tightest.limits.isEstimate
                     ? Format.peakPercent(tightest.window.usedPercent)
                     : IslandText.percent(tightest.window.usedPercent))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(tightest.window.usedPercent >= 90 ? IslandTheme.critical : .white)
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tightest.map {
            "\(AgentPalette.displayName($0.limits.agent)) \(LimitText.title($0.window.label)): \(IslandText.percent($0.window.usedPercent)) used"
        } ?? "No limits")
    }

    private func trailing(now: Date) -> some View {
        let today = IslandData.today(snapshot, preferences: preferences, now: now)
        let isWarning = IslandData.status(state, fetchedAt: snapshot?.fetchedAt, now: now).isWarning
        return HStack(spacing: 5) {
            if isAwake {
                Image(systemName: "eye.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .accessibilityLabel("Keeping awake")
            }
            Text(today.map { Format.cost($0.cost) } ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(today == nil ? IslandTheme.secondaryText : isWarning ? IslandTheme.warning : .white)
                .contentTransition(.numericText())
                .accessibilityLabel("Today \(today.map { Format.cost($0.cost) } ?? "no data")")
        }
    }
}

// MARK: - Live activity

/// The island grown for one event. Every kind shares one height so the
/// shell's morph never jumps between kinds.
struct IslandActivityView: View {
    var activity: IslandActivity

    static let height: CGFloat = 64

    var body: some View {
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
        case .accountSwitched(let label):
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
                IslandRing(fraction: 1, color: IslandTheme.fresh, lineWidth: 4.5)
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

// MARK: - Expanded

/// The island fully open: today's spend, a card per provider, banked
/// resets, every saved account, usage stats, and keep awake.
struct IslandExpandedView: View {
    var store: UsageStore
    var preferences: AppPreferences
    var accounts: AccountStore?
    var awake: AwakeController
    /// Opens a dashboard page. The integration supplies it; without one the
    /// view opens the dashboard window itself, as the popover does.
    var openDashboard: ((DashboardSection) -> Void)? = nil
    var dashboardNavigation: DashboardNavigation? = nil

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        IslandExpandedContent(
            snapshot: store.snapshot, state: store.state, preferences: preferences,
            accounts: accounts, awake: awake,
            claudeKeychainNeedsApproval: store.claudeKeychainNeedsApproval,
            openDashboard: open
        )
    }

    private func open(_ section: DashboardSection) {
        if let openDashboard { return openDashboard(section) }
        dashboardNavigation?.selection = section
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct IslandExpandedContent: View {
    var snapshot: UsageSnapshot?
    var state: UsageStore.State
    var preferences: AppPreferences
    var accounts: AccountStore?
    @Bindable var awake: AwakeController
    var claudeKeychainNeedsApproval = false
    var openDashboard: (DashboardSection) -> Void = { _ in }

    static let width: CGFloat = 620

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let cards = IslandData.limitCards(snapshot, preferences: preferences, now: context.date)
            VStack(alignment: .leading, spacing: 14) {
                header(now: context.date)
                if let accounts, let notice = accounts.notice {
                    AccountNoticeBanner(notice: notice) { accounts.dismissNotice() }
                }
                if snapshot == nil {
                    emptyState
                } else {
                    limitsSection(cards, now: context.date)
                    IslandBankedResets(cards: cards, now: context.date)
                }
                if let accounts {
                    IslandAccountsSection(
                        accounts: accounts, preferences: preferences,
                        openDashboard: { openDashboard(.accounts) }
                    )
                }
                if let snapshot {
                    IslandStatsStrip(snapshot: snapshot, preferences: preferences, showsTodayTotals: false)
                }
                if preferences.showsKeepAwake {
                    IslandKeepAwakeRow(awake: awake)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .frame(width: Self.width, alignment: .leading)
        }
        .environment(\.colorScheme, .dark)
    }

    private func header(now: Date) -> some View {
        let today = IslandData.today(snapshot, preferences: preferences, now: now)
        let status = IslandData.status(state, fetchedAt: snapshot?.fetchedAt, now: now)
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Today")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandTheme.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(today.map { Format.cost($0.cost) } ?? "No usage yet")
                        .font(.system(size: today == nil ? 15 : 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(today == nil ? IslandTheme.secondaryText : .white)
                        .contentTransition(.numericText())
                    if let today, today.totalTokens > 0 {
                        Text("\(Format.tokens(today.totalTokens)) tokens · API-equivalent")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(IslandTheme.secondaryText)
                    }
                }
            }
            Spacer(minLength: 8)
            if state == .refreshing {
                ProgressView().controlSize(.mini)
            }
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(status.isWarning ? IslandTheme.warning : IslandTheme.secondaryText)
                .lineLimit(1)
        }
        .help("Estimated at API list prices — what this usage would cost pay-as-you-go, not your subscription bill.")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func limitsSection(_ cards: [ProviderLimits], now: Date) -> some View {
        let missing = IslandData.missingClaudeReason(
            snapshot, cards: cards, preferences: preferences, keychainNeedsApproval: claudeKeychainNeedsApproval
        )
        if !cards.isEmpty || missing != nil {
            HStack(alignment: .top, spacing: 10) {
                ForEach(cards) { limits in
                    IslandProviderCard(
                        limits: limits, preferences: preferences,
                        accountLabel: accountLabel(for: limits.agent),
                        activeBlockCost: limits.isEstimate ? snapshot?.activeBlock?.cost : nil,
                        isWide: cards.count == 1 && missing == nil,
                        now: now
                    )
                }
                if let missing {
                    IslandMissingLimitsCard(agent: "claude", reason: missing, accountLabel: accountLabel(for: "claude"))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if preferences.showsLimits {
            Text("No provider limits right now. Claude Code, Codex, and Cursor limits appear here once they report them.")
                .font(.system(size: 11))
                .foregroundStyle(IslandTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accountLabel(for agent: String) -> String? {
        guard let accounts, let provider = AccountProvider(rawValue: agent) else { return nil }
        if accounts.switching == provider { return "Switching…" }
        if let active = accounts.activeAccount(for: provider) { return accounts.roster.label(for: active) }
        return accounts.liveIdentities[provider]?.email?.split(separator: "@").first.map(String.init)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            if case .failed(let message) = state {
                Text("Couldn't read agent usage")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            } else {
                Text("Scanning local agent logs…")
                    .font(.system(size: 12))
                    .foregroundStyle(IslandTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: IslandTheme.cardRadius, style: .continuous))
    }
}

/// Keep awake as a switch, with how long it holds.
struct IslandKeepAwakeRow: View {
    @Bindable var awake: AwakeController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: awake.isAwake ? "eye.fill" : "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(awake.isAwake ? .white : IslandTheme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep awake")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandTheme.secondaryText)
            }
            Spacer()
            Toggle("Keep awake", isOn: Binding(get: { awake.isAwake }, set: { awake.setAwake($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help("Blocks idle sleep so agents keep running. The display still sleeps; closing the lid still sleeps the Mac.")
    }

    private var detail: String {
        switch awake.mode {
        case .off: "Your Mac sleeps normally"
        case .indefinite: "On until turned off"
        case .until(let date): "On until \(date.formatted(date: .omitted, time: .shortened))"
        }
    }
}
