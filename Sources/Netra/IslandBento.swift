import AppKit
import SwiftUI

// MARK: - Cost tile model

/// What the island's cost tile shows: the last two weeks as bars, one day in
/// focus (today unless a bar was clicked), and how that day compares with the
/// week before it. Pure, so every number on the tile is testable.
struct IslandCostModel: Equatable {
    struct Day: Identifiable, Equatable {
        /// The day key (`yyyy-MM-dd`).
        var id: String
        var date: Date
        var cost: Double
        var tokens: Int
    }

    static let dayCount = 14
    static let trendDays = 7

    /// The last `dayCount` days, oldest first; days without usage are zeros.
    var days: [Day]
    /// The day in focus.
    var focus: Day
    var focusIsToday: Bool
    /// The focused day's cost against the average of the `trendDays` days
    /// before it; nil when those days had no usage to compare with.
    var trend: Double?

    init(
        snapshot: UsageSnapshot?, hiddenProviders: Set<String>, selectedDay: String? = nil,
        now: Date = .now, calendar: Calendar = .current
    ) {
        let keys = PeriodKeys.keyer(calendar)
        let rows = (snapshot?.daily ?? []).suffix(Self.dayCount + Self.trendDays + 1)
        let byDay = Dictionary(
            rows.map { ($0.period, $0.filtered(hidingProviders: hiddenProviders)) },
            uniquingKeysWith: { first, _ in first }
        )
        let today = keys.startOfDay(now)
        func day(_ offset: Int) -> Day {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = keys.day(date)
            return Day(id: key, date: date, cost: byDay[key]?.cost ?? 0, tokens: byDay[key]?.totalTokens ?? 0)
        }
        // Offsets back from today: 0 is today.
        let history = (0..<(Self.dayCount + Self.trendDays)).map(day)
        days = Array(history.prefix(Self.dayCount).reversed())

        let focusOffset = selectedDay.flatMap { key in history.prefix(Self.dayCount).firstIndex { $0.id == key } } ?? 0
        focus = history[focusOffset]
        focusIsToday = focusOffset == 0
        let before = history[(focusOffset + 1)...].prefix(Self.trendDays)
        let average = before.isEmpty ? 0 : before.reduce(0) { $0 + $1.cost } / Double(before.count)
        trend = DashboardUsageAggregator.change(from: average, to: focus.cost)
    }
}

// MARK: - Expanded island

/// The island fully open: a bento grid with one large tile for cost and
/// tokens and one small tile per provider limit.
struct IslandExpandedView: View {
    var store: UsageStore
    var preferences: AppPreferences
    /// Opens a dashboard page. The integration supplies it; without one the
    /// view opens the dashboard window itself, as the popover does.
    var openDashboard: ((DashboardSection) -> Void)? = nil
    var dashboardNavigation: DashboardNavigation? = nil

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        IslandExpandedContent(
            snapshot: store.snapshot, state: store.state, preferences: preferences,
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
    var claudeKeychainNeedsApproval = false
    var openDashboard: (DashboardSection) -> Void = { _ in }

    /// The bar the pointer last clicked; nil shows today.
    @State private var selectedDay: String?

    static let width: CGFloat = 440
    private static let gap: CGFloat = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let cards = IslandData.limitCards(snapshot, preferences: preferences, now: context.date)
            let status = IslandData.status(state, fetchedAt: snapshot?.fetchedAt, now: context.date)
            VStack(alignment: .leading, spacing: Self.gap) {
                if snapshot == nil {
                    emptyState
                } else {
                    grid(cards, now: context.date)
                }
                if let missing = IslandData.missingClaudeReason(
                    snapshot, cards: cards, preferences: preferences, keychainNeedsApproval: claudeKeychainNeedsApproval
                ) {
                    note(missing, color: IslandTheme.secondaryText)
                }
                if status.isWarning {
                    note(status.text, color: IslandTheme.warning)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(width: Self.width, alignment: .leading)
        }
        .environment(\.colorScheme, .dark)
    }

    /// The cost tile on the left, as tall as the provider tiles beside it.
    /// Without any limits to show, the cost tile takes the whole width.
    private func grid(_ cards: [ProviderLimits], now: Date) -> some View {
        let model = IslandCostModel(
            snapshot: snapshot, hiddenProviders: preferences.hiddenMenuProviders,
            selectedDay: selectedDay, now: now
        )
        return HStack(alignment: .top, spacing: Self.gap) {
            IslandCostTile(model: model, selectedDay: $selectedDay) { openDashboard(.usage) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !cards.isEmpty {
                LazyVGrid(
                    columns: Array(
                        // One or two limits stack in a column beside the
                        // cost tile; more form a two-column grid.
                        repeating: GridItem(.flexible(), spacing: Self.gap), count: cards.count <= 2 ? 1 : 2
                    ),
                    spacing: Self.gap
                ) {
                    ForEach(cards) { limits in
                        IslandLimitTile(limits: limits, showsRemaining: preferences.barsShowRemaining, now: now) {
                            openDashboard(.subscriptions)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
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
        .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: IslandTheme.tileRadius, style: .continuous))
    }
}

// MARK: - Tiles

/// Cost and tokens for one day, the trend against the week before it, and
/// the last two weeks as bars. Clicking a bar puts that day in focus;
/// clicking it again returns to today.
struct IslandCostTile: View {
    var model: IslandCostModel
    @Binding var selectedDay: String?
    var openUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openUsage) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                    Text(Format.cost(model.focus.cost))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(Format.tokens(model.focus.tokens)) tokens")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(IslandTheme.secondaryText)
                    trend
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Estimated at API list prices, not your subscription bill. Click to open Usage.")
            Spacer(minLength: 10)
            bars
        }
        .padding(12)
        .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: IslandTheme.tileRadius, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: model.focus.id)
    }

    private var title: String {
        model.focusIsToday
            ? "TODAY"
            : model.focus.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
    }

    @ViewBuilder
    private var trend: some View {
        if let change = model.trend {
            let up = change >= 0
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                Text("\(abs(change).formatted(.percent.precision(.fractionLength(0)))) vs 7-day avg")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(up ? IslandTheme.warning : IslandTheme.fresh)
            .padding(.top, 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(up ? "Up" : "Down") \(abs(change).formatted(.percent.precision(.fractionLength(0)))) against the 7-day average")
        }
    }

    private var bars: some View {
        let peak = max(model.days.map(\.cost).max() ?? 0, 0.01)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(model.days) { day in
                let isFocus = day.id == model.focus.id
                Button {
                    // Clicking today, or the focused bar again, returns to today.
                    selectedDay = isFocus || day.id == model.days.last?.id ? nil : day.id
                } label: {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isFocus ? Color.white : Color(white: 0.24))
                        .frame(height: max(2, 34 * day.cost / peak))
                        .frame(maxWidth: .infinity, maxHeight: 34, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(Format.cost(day.cost))")
                .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(Format.cost(day.cost))")
            }
        }
        .frame(height: 34)
    }
}

/// One provider's headline limit: how much is used, a thin bar, and when it
/// resets. Opens Subscriptions, where every window and account lives.
struct IslandLimitTile: View {
    var limits: ProviderLimits
    var showsRemaining: Bool
    var now: Date
    var open: () -> Void

    var body: some View {
        let window = IslandData.primaryWindow(limits)
        let used = min(max(window?.usedPercent ?? 0, 0), 100)
        let isHot = used >= 90
        let tint = isHot ? IslandTheme.critical : AgentPalette.color(for: limits.agent)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    ProviderLogo(agent: limits.agent, size: 11)
                    Text(AgentPalette.shortName(limits.agent))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
                Text(amount(window))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isHot ? IslandTheme.critical : .white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 5)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(IslandTheme.track)
                        Capsule().fill(tint).frame(width: max(3, proxy.size.width * used / 100))
                    }
                }
                .frame(height: 3)
                .padding(.top, 8)
                Text(detail(window))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(IslandTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: IslandTheme.tileRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: IslandTheme.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help(window))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help(window))
    }

    private func amount(_ window: QuotaWindow?) -> String {
        guard let window else { return "—" }
        if limits.isEstimate { return Format.peakPercent(window.usedPercent) }
        return IslandText.percent(showsRemaining ? 100 - window.usedPercent : window.usedPercent)
    }

    /// "1h 53m" until the reset; the window's name when no reset is known.
    private func detail(_ window: QuotaWindow?) -> String {
        guard let window else { return "no limit reported" }
        if let resetsAt = window.resetsAt { return IslandText.resetsIn(resetsAt, now: now) }
        return limits.isEstimate ? "of your peak" : LimitText.title(window.label)
    }

    private func help(_ window: QuotaWindow?) -> String {
        guard let window else { return "\(AgentPalette.displayName(limits.agent)): no limit reported" }
        let name = AgentPalette.displayName(limits.agent)
        if limits.isEstimate {
            return "\(name): local estimate, \(Format.peakPercent(window.usedPercent)) of your heaviest 5-hour block"
        }
        let reset = window.resetsAt.map { ", resets in \(IslandText.resetsIn($0, now: now))" } ?? ""
        return "\(name) \(LimitText.title(window.label)): \(IslandText.percent(window.usedPercent)) used\(reset)"
    }
}
