import AppKit
import SwiftUI

// MARK: - Cost tile model

/// The span the island's cost tile totals.
enum IslandCostRange: Int, CaseIterable, Identifiable, Sendable {
    case today = 1, week = 7, month = 30

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: "1D"
        case .week: "7D"
        case .month: "30D"
        }
    }

    /// Bars drawn for the range. Today alone would be one bar, so it shows
    /// the last two weeks for context.
    var barCount: Int { self == .today ? 14 : rawValue }
}

/// What the island's cost tile shows: cost and tokens for a range (today,
/// the last 7 days, or the last 30) or for one day whose bar was clicked,
/// how that compares with the period before it, and the days as bars.
/// Pure, so every number on the tile is testable.
struct IslandCostModel: Equatable {
    struct Day: Identifiable, Equatable {
        /// The day key (`yyyy-MM-dd`).
        var id: String
        var date: Date
        var cost: Double
        var tokens: Int
    }

    /// A single day is compared with the average of this many days before it.
    static let trendDays = 7

    var range: IslandCostRange
    /// The range's days, oldest first; days without usage are zeros.
    var days: [Day]
    /// The day the headline is about, when it is one day: today on the 1D
    /// range, or the day whose bar was clicked. Nil for a 7- or 30-day total.
    var focusDay: Day?
    var focusIsToday: Bool
    var cost: Double
    var tokens: Int
    /// The headline against its baseline: for one day, the average of the
    /// `trendDays` days before it; for a range, the equal span before it.
    /// Nil when the baseline had no usage.
    var trend: Double?
    var trendCaption: String

    init(
        snapshot: UsageSnapshot?, hiddenProviders: Set<String>, range: IslandCostRange = .today,
        selectedDay: String? = nil, now: Date = .now, calendar: Calendar = .current
    ) {
        self.range = range
        let keys = PeriodKeys.keyer(calendar)
        // Enough history for the bars plus the baseline of the oldest one.
        let depth = range.barCount + max(Self.trendDays, range.rawValue)
        let byDay = Dictionary(
            (snapshot?.daily ?? []).suffix(depth + 1).map { ($0.period, $0.filtered(hidingProviders: hiddenProviders)) },
            uniquingKeysWith: { first, _ in first }
        )
        let today = keys.startOfDay(now)
        // Offsets back from today: 0 is today.
        let history = (0..<depth).map { offset -> Day in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = keys.day(date)
            return Day(id: key, date: date, cost: byDay[key]?.cost ?? 0, tokens: byDay[key]?.totalTokens ?? 0)
        }
        days = Array(history.prefix(range.barCount).reversed())

        let clicked = selectedDay.flatMap { key in history.prefix(range.barCount).firstIndex { $0.id == key } }
        if let offset = clicked ?? (range == .today ? 0 : nil) {
            let day = history[offset]
            focusDay = day
            focusIsToday = offset == 0
            cost = day.cost
            tokens = day.tokens
            let before = history[(offset + 1)...].prefix(Self.trendDays)
            let average = before.isEmpty ? 0 : before.reduce(0) { $0 + $1.cost } / Double(before.count)
            trend = DashboardUsageAggregator.change(from: average, to: day.cost)
            trendCaption = "vs \(Self.trendDays)-day avg"
        } else {
            let span = history.prefix(range.rawValue)
            let previous = history.dropFirst(range.rawValue).prefix(range.rawValue)
            focusDay = nil
            focusIsToday = false
            cost = span.reduce(0) { $0 + $1.cost }
            tokens = span.reduce(0) { $0 + $1.tokens }
            trend = DashboardUsageAggregator.change(from: previous.reduce(0) { $0 + $1.cost }, to: cost)
            trendCaption = "vs previous \(range.rawValue) days"
        }
    }
}

// MARK: - Expanded island

/// The island fully open: a bento grid with one large tile for cost and
/// tokens and one small tile per provider limit.
struct IslandExpandedView: View {
    var store: UsageStore
    var preferences: AppPreferences
    /// Opens a page of the main window. The integration supplies it;
    /// without one the view asks the launcher itself, as the popover does.
    var openDashboard: ((DashboardSection) -> Void)? = nil

    var body: some View {
        IslandExpandedContent(
            snapshot: store.snapshot, state: store.state, preferences: preferences,
            claudeKeychainNeedsApproval: store.claudeKeychainNeedsApproval,
            openDashboard: open
        )
    }

    private func open(_ section: DashboardSection) {
        if let openDashboard { return openDashboard(section) }
        DashboardLauncher.shared.open(section)
    }
}

struct IslandExpandedContent: View {
    var snapshot: UsageSnapshot?
    var state: UsageStore.State
    var preferences: AppPreferences
    var claudeKeychainNeedsApproval = false
    var openDashboard: (DashboardSection) -> Void = { _ in }

    @State private var range = IslandCostRange.today
    /// The bar that was clicked; nil shows the range's own total.
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
            range: range, selectedDay: selectedDay, now: now
        )
        return HStack(alignment: .top, spacing: Self.gap) {
            IslandCostTile(model: model, range: $range, selectedDay: $selectedDay) { openDashboard(.usage) }
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

/// Cost and tokens for today, the last 7 days, or the last 30, with the
/// trend against the period before and the days as bars. Clicking a bar
/// shows that day; clicking it again returns to the range's total.
struct IslandCostTile: View {
    var model: IslandCostModel
    @Binding var range: IslandCostRange
    @Binding var selectedDay: String?
    var openUsage: () -> Void

    private static let barHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                rangePicker
                Spacer(minLength: 0)
                // Only a clicked day needs naming; the picker names the rest.
                if let day = model.focusDay, !model.focusIsToday {
                    Text(day.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Button(action: openUsage) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        figure(Format.cost(model.cost), label: "cost")
                        figure(Format.tokens(model.tokens), label: "tokens")
                    }
                    trend
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .help("Cost is estimated at API list prices, not your subscription bill. Click to open Usage.")
            Spacer(minLength: 10)
            bars
        }
        .padding(12)
        .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: IslandTheme.tileRadius, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: model.focusDay?.id)
        .animation(.easeOut(duration: 0.15), value: model.range)
    }

    /// Cost and tokens carry equal weight: one number each, with its name
    /// underneath.
    private func figure(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(IslandTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private var rangePicker: some View {
        HStack(spacing: 1) {
            ForEach(IslandCostRange.allCases) { option in
                let isOn = option == model.range
                Button {
                    range = option
                    selectedDay = nil
                } label: {
                    Text(option.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isOn ? .black : IslandTheme.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(isOn ? Color.white : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option == .today ? "Today" : "Last \(option.rawValue) days")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(1.5)
        .background(IslandTheme.track, in: Capsule())
        // The date title gives way before a range label is cut short.
        .fixedSize()
    }

    @ViewBuilder
    private var trend: some View {
        if let change = model.trend {
            let up = change >= 0
            let amount = abs(change).formatted(.percent.precision(.fractionLength(0)))
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                Text("\(amount) cost \(model.trendCaption)")
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(up ? IslandTheme.warning : IslandTheme.fresh)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(up ? "Up" : "Down") \(amount) \(model.trendCaption)")
        }
    }

    private var bars: some View {
        let peak = max(model.days.map(\.cost).max() ?? 0, 0.01)
        return HStack(alignment: .bottom, spacing: model.days.count > 14 ? 2 : 3) {
            ForEach(model.days) { day in
                let isFocus = day.id == model.focusDay?.id
                Button {
                    // On 1D today is the resting state, so its bar clears the
                    // selection too; elsewhere only the focused bar does.
                    let clears = isFocus || (model.range == .today && day.id == model.days.last?.id)
                    selectedDay = clears ? nil : day.id
                } label: {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isFocus ? Color.white : Color(white: 0.24))
                        .frame(height: max(2, Self.barHeight * day.cost / peak))
                        .frame(maxWidth: .infinity, maxHeight: Self.barHeight, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(Format.cost(day.cost))")
                .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(Format.cost(day.cost))")
            }
        }
        .frame(height: Self.barHeight)
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
