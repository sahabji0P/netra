import SwiftUI

// MARK: - Model

/// The span the island's model and token tiles cover. Ranges count calendar
/// days ending today, because usage is stored per day (so "Today", not a
/// rolling 24 hours).
enum IslandStatsRange: Int, CaseIterable, Identifiable, Sendable {
    case today = 1, week = 7, month = 30, quarter = 90

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        }
    }
    /// The activity strip shows 30 days, or all 90 for the 90-day range.
    var stripDays: Int { self == .quarter ? 90 : IslandStatsModel.heatmapDays }
}

/// Everything the island's stats strip shows, derived once from a snapshot so
/// every number is testable without SwiftUI. Hidden providers are removed
/// from each daily row first (as the popover does), so all sections agree.
struct IslandStatsModel: Equatable, Sendable {
    static let heatmapDays = 30
    static let topModels = 4

    struct Today: Equatable, Sendable {
        var cost: Double
        var tokens: Int
        /// Daily averages over the 7 days before today. Days without usage
        /// count as zero (ccusage omits them), so the divisor is always 7.
        var averageCost: Double
        var averageTokens: Double
        /// nil when there is no baseline to compare against.
        var costChange: Double?
        var tokenChange: Double?
    }

    struct HeatCell: Identifiable, Equatable, Sendable {
        var period: String
        var date: Date
        var cost: Double
        var tokens: Int
        /// The day's biggest provider by cost (tokens on a tie); nil when idle.
        var provider: String?
        /// 0 = no usage, 1...4 = quartile of the busiest day in the window.
        var level: Int
        /// Inside the selected range, so the strip can dim the rest.
        var inRange = true
        var id: String { period }
    }

    struct MixSegment: Identifiable, Equatable, Sendable {
        var name: String
        /// nil for the grouped remainder.
        var provider: String?
        /// What the share is weighted by: cost, or tokens when unpriced.
        var value: Double
        var share: Double
        var cost: Double = 0
        var tokens: Int = 0
        /// Position among segments of the same provider, so several models
        /// of one provider stay distinguishable while keeping its color.
        var providerRank: Int
        var id: String { name }
    }

    struct TokenMix: Equatable, Sendable {
        var input: Int
        var output: Int
        var cacheWrite: Int
        var cacheRead: Int
        var cacheHitRate: Double
        var total: Int { input + output + cacheWrite + cacheRead }

        func share(_ part: Int) -> Double {
            total > 0 ? Double(part) / Double(total) : 0
        }
    }

    struct Block: Equatable, Sendable {
        var cost: Double
        var projectedCost: Double
        var tokens: Int
        /// Dollars per hour since the block started.
        var burnRate: Double
        var tokensPerMinute: Double
        var elapsedFraction: Double
        var remaining: TimeInterval
    }

    var today: Today
    var range: IslandStatsRange
    var heatmap: [HeatCell]
    var heatmapTotal: Double
    /// The day the model and token tiles show instead of the range; nil
    /// when nothing is selected or the day is outside the strip.
    var selectedDay: HeatCell?
    /// Cost and tokens of what the tiles show: the selected day, else the range.
    var spanCost: Double
    var spanTokens: Int
    var modelMix: [MixSegment]
    /// Whether the model mix is weighted by tokens because nothing was priced.
    var modelMixByTokens: Bool
    var tokenMix: TokenMix
    var block: Block?

    var hasUsage: Bool { heatmap.contains { $0.level > 0 } }

    init(
        snapshot: UsageSnapshot?,
        hiddenProviders: Set<String>,
        range: IslandStatsRange = .week,
        selectedDay: String? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.range = range
        let daily = (snapshot?.daily ?? []).map { $0.filtered(hidingProviders: hiddenProviders) }
        let byDay = Dictionary(daily.map { ($0.period, $0) }, uniquingKeysWith: { first, _ in first })
        let todayStart = calendar.startOfDay(for: now)

        func day(_ offset: Int) -> (key: String, date: Date) {
            let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return (PeriodKeys.day(date, calendar), date)
        }
        func rows(lastDays count: Int, skippingToday: Bool = false) -> [PeriodRow] {
            let offsets = skippingToday ? Array(1...count) : Array(0..<count)
            return offsets.compactMap { byDay[day($0).key] }
        }

        let todayRow = byDay[day(0).key] ?? .zero(period: day(0).key, date: todayStart)
        let previous = rows(lastDays: 7, skippingToday: true)
        let averageCost = previous.reduce(0) { $0 + $1.cost } / 7
        let averageTokens = Double(previous.reduce(0) { $0 + $1.totalTokens }) / 7
        today = Today(
            cost: todayRow.cost,
            tokens: todayRow.totalTokens,
            averageCost: averageCost,
            averageTokens: averageTokens,
            costChange: DashboardUsageAggregator.change(from: averageCost, to: todayRow.cost),
            tokenChange: DashboardUsageAggregator.change(from: averageTokens, to: Double(todayRow.totalTokens))
        )

        let heatDays = (0..<range.stripDays).reversed().map { day($0) }
        var cells = Self.heatCells(heatDays.map { ($0.key, $0.date, byDay[$0.key]) })
        for index in cells.indices {
            cells[index].inRange = index >= cells.count - range.days
        }
        let selected = selectedDay.flatMap { key in cells.first { $0.period == key } }
        heatmap = cells
        heatmapTotal = cells.reduce(0) { $0 + $1.cost }
        self.selectedDay = selected

        let mixRows = selected.map { cell in byDay[cell.period].map { [$0] } ?? [] }
            ?? rows(lastDays: range.days)
        let mixWindow = DashboardUsageAggregator.aggregate(mixRows, period: "island-mix", date: todayStart)
        spanCost = mixWindow.cost
        spanTokens = mixWindow.totalTokens
        (modelMix, modelMixByTokens) = Self.modelMix(mixWindow)
        tokenMix = TokenMix(
            input: mixWindow.inputTokens,
            output: mixWindow.outputTokens,
            cacheWrite: mixWindow.cacheCreationTokens,
            cacheRead: mixWindow.cacheReadTokens,
            cacheHitRate: DashboardUsageAggregator.cacheHitRate(mixWindow)
        )

        // ccusage's 5-hour blocks come from Claude Code's logs only.
        if !hiddenProviders.contains("claude"), let block = snapshot?.activeBlock {
            self.block = Self.block(block, now: now)
        } else {
            block = nil
        }
    }

    static func heatCells(_ days: [(key: String, date: Date, row: PeriodRow?)]) -> [HeatCell] {
        let maxCost = days.compactMap { $0.row?.cost }.max() ?? 0
        let maxTokens = days.compactMap { $0.row?.totalTokens }.max() ?? 0
        return days.map { key, date, row in
            let cost = row?.cost ?? 0
            let tokens = row?.totalTokens ?? 0
            let fraction = maxCost > 0
                ? cost / maxCost
                : (maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0)
            let hasUsage = cost > 0.000_001 || tokens > 0
            return HeatCell(
                period: key, date: date, cost: cost, tokens: tokens,
                provider: hasUsage ? row.flatMap(dominantProvider) : nil,
                level: hasUsage ? min(4, max(1, Int((fraction * 4).rounded(.up)))) : 0
            )
        }
    }

    static func dominantProvider(_ row: PeriodRow) -> String? {
        let parts = row.agents + [row.unattributed].compactMap { $0 }
        return parts.max {
            $0.cost == $1.cost ? $0.totalTokens < $1.totalTokens : $0.cost < $1.cost
        }?.name
    }

    /// Top models by cost (or tokens when nothing was priced), plus one
    /// "Other" segment for the rest. Models sharing a display name across
    /// providers merge into the biggest contributor's provider.
    static func modelMix(_ window: PeriodRow) -> ([MixSegment], byTokens: Bool) {
        let rows = DashboardUsageAggregator.modelRows(window)
        let byTokens = rows.reduce(0) { $0 + $1.cost } <= 0.000_001
        var merged: [String: (provider: String, value: Double, lead: Double, cost: Double, tokens: Int)] = [:]
        for row in rows {
            let value = byTokens ? Double(row.tokens) : row.cost
            guard value > 0 else { continue }
            let name = AgentPalette.modelDisplayName(row.name)
            if var existing = merged[name] {
                existing.value += value
                existing.cost += row.cost
                existing.tokens += row.tokens
                if value > existing.lead { existing.provider = row.provider; existing.lead = value }
                merged[name] = existing
            } else {
                merged[name] = (row.provider, value, value, row.cost, row.tokens)
            }
        }
        typealias Ranked = (name: String, provider: String, value: Double, cost: Double, tokens: Int)
        let unsorted: [Ranked] = merged.map { name, entry in
            (name, entry.provider, entry.value, entry.cost, entry.tokens)
        }
        let ranked = unsorted.sorted { (a: Ranked, b: Ranked) -> Bool in
            a.value == b.value ? a.name < b.name : a.value > b.value
        }
        let total = ranked.reduce(0) { $0 + $1.value }
        guard total > 0 else { return ([], byTokens) }

        // Keep the full top N only when nothing is left over; otherwise one
        // slot goes to "Other" so the bar always adds up.
        let head = ranked.count <= topModels ? ranked : Array(ranked.prefix(topModels - 1))
        var providerCounts: [String: Int] = [:]
        var segments = head.map { model in
            let rank = providerCounts[model.provider, default: 0]
            providerCounts[model.provider] = rank + 1
            return MixSegment(
                name: model.name, provider: model.provider,
                value: model.value, share: model.value / total,
                cost: model.cost, tokens: model.tokens, providerRank: rank
            )
        }
        let others = ranked.dropFirst(head.count)
        let rest = others.reduce(0) { $0 + $1.value }
        if rest > 0 {
            segments.append(MixSegment(
                name: "Other", provider: nil, value: rest, share: rest / total,
                cost: others.reduce(0) { $0 + $1.cost }, tokens: others.reduce(0) { $0 + $1.tokens },
                providerRank: 0
            ))
        }
        return (segments, byTokens)
    }

    static func block(_ block: BlockStat, now: Date) -> Block? {
        guard block.end > now else { return nil }
        let length = block.end.timeIntervalSince(block.start)
        // A minimum elapsed time keeps the first seconds of a block from
        // extrapolating to an absurd hourly rate.
        let elapsed = max(60, now.timeIntervalSince(block.start))
        return Block(
            cost: block.cost,
            projectedCost: max(block.projectedCost, block.cost),
            tokens: block.tokens,
            burnRate: block.cost / (elapsed / 3600),
            tokensPerMinute: Double(block.tokens) / (elapsed / 60),
            elapsedFraction: length > 0 ? min(1, max(0, now.timeIntervalSince(block.start) / length)) : 0,
            remaining: block.end.timeIntervalSince(now)
        )
    }

    /// "+34%" / "−12%"; nil when there is no baseline.
    static func changeText(_ change: Double?) -> String? {
        guard let change else { return nil }
        let percent = Int((abs(change) * 100).rounded())
        if percent == 0 { return "±0%" }
        return (change > 0 ? "+" : "−") + "\(percent)%"
    }
}

// MARK: - View

/// Usage stats strip inside the expanded island: today against a typical day,
/// the 5-hour block, an activity strip, and the model and token mix for the
/// chosen range, or for one day once its cell is clicked. Always drawn on the
/// island's black, whatever the appearance.
struct IslandStatsStrip: View {
    var snapshot: UsageSnapshot
    var preferences: AppPreferences
    /// Fixed time for previews; nil reads the clock on every render so the
    /// block countdown stays current.
    var now: Date? = nil
    var calendar: Calendar = .current
    /// Off where the surrounding view already headlines today's cost and
    /// tokens; the tile then shows only the comparison with the average.
    var showsTodayTotals = true

    @State var range: IslandStatsRange = .week
    /// Period key of the clicked day, or nil for the whole range.
    @State var selectedDay: String?

    private var model: IslandStatsModel {
        IslandStatsModel(
            snapshot: snapshot, hiddenProviders: preferences.hiddenMenuProviders,
            range: range, selectedDay: selectedDay,
            now: now ?? .now, calendar: calendar
        )
    }

    /// "7D", or the clicked day such as "Sat 12 Oct".
    private func spanLabel(_ model: IslandStatsModel) -> String {
        guard let day = model.selectedDay else { return range.title }
        return day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        let model = model
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                todayTile(model.today)
                if let block = model.block {
                    blockTile(block)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            heatmapTile(model)
            HStack(alignment: .top, spacing: 8) {
                modelMixTile(model)
                tokenMixTile(model)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Today

    private func todayTile(_ today: IslandStatsModel.Today) -> some View {
        tile {
            caption(showsTodayTotals ? "Today" : "Today vs 7-day average")
            if showsTodayTotals {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Format.cost(today.cost))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(Format.tokens(today.tokens)) tokens")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                .monospacedDigit()
            }
            HStack(spacing: 6) {
                changeBadge(today.costChange, unit: "cost")
                changeBadge(today.tokenChange, unit: "tokens")
                Text(baselineText(today))
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private func baselineText(_ today: IslandStatsModel.Today) -> String {
        if today.averageCost > 0 { return "vs \(Format.cost(today.averageCost))/day avg" }
        if today.averageTokens > 0 { return "vs \(Format.tokens(Int(today.averageTokens)))/day avg" }
        return "No 7-day baseline yet"
    }

    @ViewBuilder
    private func changeBadge(_ change: Double?, unit: String) -> some View {
        if let text = IslandStatsModel.changeText(change), let change {
            HStack(spacing: 3) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 8.5, weight: .bold))
                Text("\(text) \(unit)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.white.opacity(0.09)))
        }
    }

    // MARK: 5-hour block

    private func blockTile(_ block: IslandStatsModel.Block) -> some View {
        let claude = AgentPalette.color(for: "claude")
        return tile {
            HStack {
                caption("5h block")
                Spacer(minLength: 4)
                Text("\(LimitText.duration(block.remaining)) left")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Format.cost(block.burnRate))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("/h")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IslandTheme.secondaryText)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.cost(block.projectedCost))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("projected")
                        .font(.system(size: 9.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
            }
            .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(IslandTheme.track)
                    Capsule().fill(claude)
                        .frame(width: max(4, proxy.size.width * block.elapsedFraction))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text("\(Format.cost(block.cost)) so far · \(Format.tokens(Int(block.tokensPerMinute))) tok/min")
                .font(.system(size: 10.5))
                .foregroundStyle(IslandTheme.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: 228)
    }

    // MARK: Heatmap

    private func heatmapTile(_ model: IslandStatsModel) -> some View {
        let perRow = model.heatmap.count > IslandStatsModel.heatmapDays ? model.heatmap.count / 2 : model.heatmap.count
        let rows = stride(from: 0, to: model.heatmap.count, by: max(1, perRow)).map {
            Array(model.heatmap[$0..<min($0 + perRow, model.heatmap.count)])
        }
        let lastPeriod = model.heatmap.last?.period
        return tile {
            HStack(spacing: 8) {
                caption("Last \(model.heatmap.count) days")
                Spacer()
                rangePicker
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.cost(model.spanCost))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(spanLabel(model))
                        .font(.system(size: 9.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                .monospacedDigit()
                .help("\(Format.cost(model.spanCost)), \(Format.tokens(model.spanTokens)) tokens · \(spanLabel(model))")
            }
            VStack(spacing: 3) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: rows.count > 1 ? 2.5 : 3) {
                        ForEach(rows[row]) { cell in
                            heatCell(
                                cell, isToday: cell.period == lastPeriod,
                                isSelected: cell.period == model.selectedDay?.period,
                                dimmed: model.selectedDay == nil && !cell.inRange,
                                height: rows.count > 1 ? 11 : 18
                            )
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text(model.heatmap.first.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
                Spacer()
                ForEach(heatmapProviders(model), id: \.self) { provider in
                    legendDot(AgentPalette.color(for: provider), AgentPalette.shortName(provider))
                }
                Spacer()
                Text("Today")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(IslandTheme.secondaryText)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(IslandStatsRange.allCases) { option in
                let isOn = option == range && selectedDay == nil
                Button {
                    range = option
                    selectedDay = nil
                } label: {
                    Text(option.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isOn ? .white : IslandTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(isOn ? Color(white: 0.24) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option == .today ? "Today" : "The last \(option.days) days")
            }
        }
        .padding(2)
        .background(IslandTheme.track.opacity(0.7), in: Capsule())
    }

    /// One day; clicking it shows that day in the model and token tiles,
    /// clicking it again goes back to the range.
    private func heatCell(
        _ cell: IslandStatsModel.HeatCell, isToday: Bool, isSelected: Bool, dimmed: Bool, height: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: height > 12 ? 3.5 : 2.5, style: .continuous)
        return Button {
            selectedDay = isSelected ? nil : cell.period
        } label: {
            shape
                .fill(cellColor(cell))
                .opacity(dimmed ? 0.35 : 1)
                .overlay {
                    if isSelected {
                        shape.strokeBorder(.white, lineWidth: 1.5)
                    } else if isToday {
                        shape.strokeBorder(.white.opacity(0.85), lineWidth: 1)
                    }
                }
                .frame(height: height)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(cellHelp(cell))
        .accessibilityLabel(cellHelp(cell))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func cellColor(_ cell: IslandStatsModel.HeatCell) -> Color {
        guard cell.level > 0, let provider = cell.provider else { return IslandTheme.track }
        return AgentPalette.color(for: provider).opacity([0.3, 0.5, 0.75, 1][cell.level - 1])
    }

    private func cellHelp(_ cell: IslandStatsModel.HeatCell) -> String {
        let date = cell.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard cell.level > 0 else { return "\(date): no usage" }
        let provider = cell.provider.map { " · mostly \(AgentPalette.shortName($0))" } ?? ""
        return "\(date): \(Format.cost(cell.cost)), \(Format.tokens(cell.tokens)) tokens\(provider)"
    }

    /// Providers that lead at least one day, busiest first, for the legend.
    private func heatmapProviders(_ model: IslandStatsModel) -> [String] {
        var days: [String: Int] = [:]
        for cell in model.heatmap { if let p = cell.provider { days[p, default: 0] += 1 } }
        return days.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4).map(\.key)
    }

    // MARK: Model mix

    private func modelMixTile(_ model: IslandStatsModel) -> some View {
        tile {
            HStack(spacing: 6) {
                caption("Models · \(spanLabel(model))")
                if model.selectedDay != nil {
                    clearSelectionButton
                }
                Spacer()
                if model.modelMixByTokens && !model.modelMix.isEmpty {
                    Text("by tokens")
                        .font(.system(size: 9.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
            }
            if model.modelMix.isEmpty {
                emptyLine(model.selectedDay == nil ? "No model usage in this range" : "No usage on this day")
            } else {
                stackedBar(model.modelMix.map { ($0.id, $0.share, segmentColor($0)) })
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.modelMix) { segment in
                        modelRow(segment, showsCost: !model.modelMixByTokens)
                    }
                }
            }
        }
    }

    private var clearSelectionButton: some View {
        Button {
            selectedDay = nil
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                Text(range.title)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(IslandTheme.track, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Back to \(range == .today ? "today" : "the last \(range.days) days")")
    }

    /// Name, cost, tokens, and share of one model.
    private func modelRow(_ segment: IslandStatsModel.MixSegment, showsCost: Bool) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(segmentColor(segment))
                .frame(width: 7, height: 7)
            Text(segment.name)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if showsCost {
                Text(Format.cost(segment.cost))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(Format.tokens(segment.tokens))
                .foregroundStyle(IslandTheme.secondaryText)
                .frame(minWidth: 36, alignment: .trailing)
            Text("\(Int((segment.share * 100).rounded()))%")
                .foregroundStyle(IslandTheme.secondaryText)
                .frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
    }

    private func segmentColor(_ segment: IslandStatsModel.MixSegment) -> Color {
        guard let provider = segment.provider else { return Color(white: 0.32) }
        return AgentPalette.color(for: provider).opacity([1, 0.68, 0.46, 0.3][min(3, segment.providerRank)])
    }

    // MARK: Token mix

    private func tokenMixTile(_ model: IslandStatsModel) -> some View {
        let mix = model.tokenMix
        let parts: [(String, Int, Color)] = [
            ("Cache read", mix.cacheRead, Color(white: 0.86)),
            ("Cache write", mix.cacheWrite, Color(white: 0.58)),
            ("Input", mix.input, Color(white: 0.4)),
            ("Output", mix.output, Color(white: 0.26)),
        ]
        return tile {
            HStack(spacing: 4) {
                caption("Tokens · \(spanLabel(model))")
                Spacer()
                if mix.total > 0 {
                    Text("\(Int((mix.cacheHitRate * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text("cache hit")
                        .font(.system(size: 9.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
            }
            if mix.total == 0 {
                emptyLine(model.selectedDay == nil ? "No tokens in this range" : "No tokens on this day")
            } else {
                stackedBar(parts.map { ($0.0, mix.share($0.1), $0.2) })
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(parts, id: \.0) { name, value, color in
                        legendRow(color: color, name: name, value: Format.tokens(value))
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandTheme.card)
            )
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(IslandTheme.secondaryText)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(IslandTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }

    private func stackedBar(_ segments: [(id: String, share: Double, color: Color)]) -> some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let visible = segments.filter { $0.share > 0 }
            let usable = max(0, proxy.size.width - gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: gap) {
                ForEach(visible, id: \.id) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: usable * segment.share)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func legendRow(color: Color, name: String, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value)
                .foregroundStyle(IslandTheme.secondaryText)
                .monospacedDigit()
        }
        .font(.system(size: 10.5))
    }

    private func legendDot(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name)
        }
    }
}

/// The 30-day heatmap as one thin row of cells, for the island's footer.
struct IslandHeatStrip: View {
    var snapshot: UsageSnapshot
    var preferences: AppPreferences
    var now: Date = .now
    var calendar: Calendar = .current

    var body: some View {
        let model = IslandStatsModel(
            snapshot: snapshot, hiddenProviders: preferences.hiddenMenuProviders,
            now: now, calendar: calendar
        )
        HStack(spacing: 2) {
            ForEach(Array(model.heatmap.enumerated()), id: \.element.id) { index, cell in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Self.color(cell))
                    .overlay {
                        if index == model.heatmap.count - 1 {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .strokeBorder(.white.opacity(0.85), lineWidth: 0.75)
                        }
                    }
                    .frame(width: 5, height: 12)
            }
        }
        .help("Last 30 days · \(Format.cost(model.heatmapTotal))")
        .accessibilityLabel("Last 30 days: \(Format.cost(model.heatmapTotal))")
    }

    static func color(_ cell: IslandStatsModel.HeatCell) -> Color {
        guard cell.level > 0, let provider = cell.provider else { return IslandTheme.track }
        return AgentPalette.color(for: provider).opacity([0.3, 0.5, 0.75, 1][cell.level - 1])
    }
}
