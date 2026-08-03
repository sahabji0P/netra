import AppKit
import Charts
import SwiftUI

enum RowsMode: String, CaseIterable {
    case agents
    case models
}

struct MenuView: View {
    @Bindable var store: UsageStore
    @Bindable var awake: AwakeController
    @State private var tab: PeriodTab = .today
    @State private var selectedAgent: String?   // nil = Overview
    @State private var rowsMode: RowsMode = .agents
    @State private var hoveredPeriod: String?
    @State private var selectedPeriod: String?   // pinned by clicking a bar
    @State private var hoveredRowID: String?

    // MARK: Derived data

    private var currentRow: PeriodRow {
        store.snapshot?.currentRow(for: tab) ?? .zero()
    }

    /// The row driving every stat on screen: a pinned bar if one is clicked,
    /// otherwise the current day/week/month.
    private var displayedRow: PeriodRow {
        if let selectedPeriod,
           let row = store.snapshot?.rows(for: tab).first(where: { $0.period == selectedPeriod }) {
            return row
        }
        return currentRow
    }

    /// (cost, tokens, models) for the displayed row, filtered to the selected agent.
    private var agentStat: AgentStat? {
        guard let selectedAgent else { return nil }
        return displayedRow.agentStat(selectedAgent)
            ?? AgentStat(name: selectedAgent, cost: 0, totalTokens: 0,
                         inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, models: [])
    }

    private var agentNames: [String] {
        store.snapshot?.agentNames ?? []
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                tabStrip
                totals
                chart
                picker
                if selectedAgent == nil { rowsToggle }
                rows
                Divider().padding(.horizontal, 16)
                blockSection
                Divider().padding(.horizontal, 16)
                awakeSection
                Divider().padding(.horizontal, 16)
                footer
            }
            .frame(width: 316)
            if limitsPanelOpen, selectedAgent == nil {
                Divider()
                limitsPanel
            }
        }
        .animation(.snappy(duration: 0.18), value: limitsPanelOpen)
        .onAppear { store.refreshIfStale() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Netra")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            if store.state == .refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                Text(headerStatus(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func headerStatus(now: Date) -> String {
        switch store.state {
        case .refreshing: return "refreshing…"
        case .failed(let message): return message
        case .empty: return "no data yet"
        case .fresh, .stale:
            guard let at = store.snapshot?.fetchedAt else { return "" }
            let age = Format.age(since: at, now: now)
            return store.state == .stale ? "stale · \(age)" : "updated \(age)"
        }
    }

    // MARK: Agent tabs

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                tabChip("All", isSelected: selectedAgent == nil) { selectedAgent = nil }
                ForEach(agentNames, id: \.self) { name in
                    tabChip(AgentPalette.shortName(name), isSelected: selectedAgent == name) {
                        selectedAgent = name
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    private func tabChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Totals

    private var hoveredRow: RowItem? {
        guard let hoveredRowID else { return nil }
        return rowItems.shown.first { $0.id == hoveredRowID }
    }

    private var displayedCost: Double {
        if let hoveredRow { return hoveredRow.cost }
        if let hovered = hoveredChartPoint { return hovered.cost }
        return agentStat?.cost ?? displayedRow.cost
    }

    /// Denominator for the "% of period" shown when hovering a row.
    private var shareBasis: Double {
        agentStat?.cost ?? displayedRow.cost
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.cost(displayedCost))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: displayedCost)
            HStack(spacing: 8) {
                Text(captionLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if showBackToCurrent {
                    Button {
                        selectedPeriod = nil
                    } label: {
                        Text(backToCurrentTitle)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(tokensLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var showBackToCurrent: Bool {
        guard let selectedPeriod else { return false }
        return selectedPeriod != currentRow.period
    }

    private var backToCurrentTitle: String {
        switch tab {
        case .today: "← today"
        case .week: "← this week"
        case .month: "← this month"
        }
    }

    private var captionLine: String {
        let scope = selectedAgent.map { AgentPalette.displayName($0) + " · " } ?? ""
        if let hoveredRow {
            return scope + "\(hoveredRow.name) · \(periodCaption)"
        }
        if let hovered = hoveredChartPoint {
            return scope + "est. API cost · \(hovered.label)"
        }
        let pin = selectedPeriod == nil ? "" : " · pinned"
        return scope + "est. API-equivalent cost · \(periodCaption)" + pin
    }

    private var tokensLine: String {
        if let hoveredRow {
            var line = "\(Format.tokens(hoveredRow.input)) in · \(Format.tokens(hoveredRow.output)) out · \(Format.tokens(hoveredRow.cacheRead)) cached"
            if shareBasis > 0 {
                line += " · \(Int((hoveredRow.cost / shareBasis * 100).rounded()))% of period"
            }
            return line
        }
        if let hovered = hoveredChartPoint {
            return "\(Format.tokens(hovered.tokens)) tokens in this period"
        }
        if let agentStat {
            return "\(Format.tokens(agentStat.inputTokens)) in · \(Format.tokens(agentStat.outputTokens)) out · \(Format.tokens(agentStat.cacheReadTokens)) cached"
        }
        return "\(Format.tokens(displayedRow.inputTokens)) in · \(Format.tokens(displayedRow.outputTokens)) out · \(Format.tokens(displayedRow.cacheReadTokens)) cached"
    }

    private var periodCaption: String {
        let calendar = Calendar.current
        switch tab {
        case .today:
            if selectedPeriod == nil { return "today" }
            return displayedRow.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            let week = calendar.component(.weekOfYear, from: displayedRow.date)
            return "W\(week) · week of \(displayedRow.date.formatted(.dateTime.day().month(.abbreviated)))"
        case .month:
            let sameYear = calendar.isDate(displayedRow.date, equalTo: .now, toGranularity: .year)
            return sameYear
                ? displayedRow.date.formatted(.dateTime.month(.wide)).lowercased()
                : displayedRow.date.formatted(.dateTime.month(.wide).year()).lowercased()
        }
    }

    // MARK: Chart (granularity follows the period picker)

    private struct ChartPoint: Identifiable {
        var period: String
        var date: Date
        var cost: Double
        var tokens: Int
        var label: String
        var id: String { period }
    }

    private var chartPoints: [ChartPoint] {
        guard let snapshot = store.snapshot else { return [] }
        let calendar = Calendar.current
        return snapshot.rows(for: tab).compactMap { row in
            guard row.date >= chartDomain.lowerBound else { return nil }
            let cost: Double
            let tokens: Int
            if let selectedAgent {
                let agent = row.agentStat(selectedAgent)
                cost = agent?.cost ?? 0
                tokens = agent?.totalTokens ?? 0
            } else {
                cost = row.cost
                tokens = row.totalTokens
            }
            let label: String
            switch tab {
            case .today:
                label = row.date.formatted(.dateTime.day().month(.abbreviated))
            case .week:
                label = "W\(calendar.component(.weekOfYear, from: row.date)) · wk of \(row.date.formatted(.dateTime.day().month(.abbreviated)))"
            case .month:
                label = row.date.formatted(.dateTime.month(.wide).year())
            }
            return ChartPoint(period: row.period, date: row.date, cost: cost, tokens: tokens, label: label)
        }
    }

    private var chartUnit: Calendar.Component {
        switch tab {
        case .today: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private var chartDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let now = Date.now
        switch tab {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(byAdding: .day, value: -30, to: end)! ... end
        case .week:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
            return calendar.date(byAdding: .weekOfYear, value: -11, to: thisWeek.start)! ... thisWeek.end
        case .month:
            let thisMonth = calendar.dateInterval(of: .month, for: now)!
            return calendar.date(byAdding: .month, value: -5, to: thisMonth.start)! ... thisMonth.end
        }
    }

    private var hoveredChartPoint: ChartPoint? {
        guard let hoveredPeriod else { return nil }
        return chartPoints.first { $0.period == hoveredPeriod }
    }

    private var chart: some View {
        let points = chartPoints
        return Chart(points) { point in
            BarMark(
                x: .value("Period", point.date, unit: chartUnit),
                y: .value("Cost", point.cost)
            )
            .foregroundStyle(barColor(for: point.period))
            .cornerRadius(1.5)
        }
        .chartXScale(domain: chartDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            switch tab {
            case .today:
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            case .week:
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text("W\(Calendar.current.component(.weekOfYear, from: date))")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            case .month:
                AxisMarks(values: .stride(by: .month, count: 1)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated)))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .frame(height: 46)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredPeriod = period(atX: location.x, proxy: proxy, points: points)
                        case .ended:
                            hoveredPeriod = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let hit = period(atX: location.x, proxy: proxy, points: points) else {
                            selectedPeriod = nil
                            return
                        }
                        // Click a bar to pin it; click it again to unpin.
                        selectedPeriod = (selectedPeriod == hit) ? nil : hit
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func period(atX x: CGFloat, proxy: ChartProxy, points: [ChartPoint]) -> String? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return points.last {
            guard let interval = Calendar.current.dateInterval(of: chartUnit, for: $0.date) else { return false }
            return interval.contains(date)
        }?.period
    }

    private func barColor(for period: String) -> Color {
        if period == selectedPeriod { return .accentColor }
        if period == hoveredPeriod { return .accentColor.opacity(0.65) }
        return .accentColor.opacity(selectedPeriod == nil ? 0.32 : 0.18)
    }

    // MARK: Period picker

    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(PeriodTab.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .onChange(of: tab) {
            hoveredPeriod = nil
            selectedPeriod = nil
        }
    }

    // MARK: Rows (Overview: agents ⇄ models · Agent tab: that agent's models)

    private var rowsToggle: some View {
        HStack(spacing: 8) {
            ForEach(RowsMode.allCases, id: \.self) { mode in
                Button {
                    rowsMode = mode
                } label: {
                    Text("by \(mode.rawValue)")
                        .font(.system(size: 10, weight: rowsMode == mode ? .semibold : .regular))
                        .foregroundStyle(rowsMode == mode ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private struct RowItem: Identifiable {
        var id: String
        var dot: Color
        var name: String
        var tokens: Int
        var cost: Double
        var input: Int
        var output: Int
        var cacheRead: Int
    }

    /// At most this many rows; the rest collapse into one "+N more" line.
    private static let maxRows = 6

    private var rowItems: (shown: [RowItem], moreCount: Int, moreCost: Double) {
        let all: [RowItem]
        if let agentStat {
            all = agentStat.models.map {
                RowItem(id: $0.id, dot: AgentPalette.modelColor(for: $0.name),
                        name: AgentPalette.modelDisplayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost,
                        input: $0.inputTokens, output: $0.outputTokens, cacheRead: $0.cacheReadTokens)
            }
        } else if rowsMode == .agents {
            all = displayedRow.agents.map {
                RowItem(id: $0.id, dot: AgentPalette.color(for: $0.name),
                        name: AgentPalette.displayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost,
                        input: $0.inputTokens, output: $0.outputTokens, cacheRead: $0.cacheReadTokens)
            }
        } else {
            all = displayedRow.models.map {
                RowItem(id: $0.id, dot: AgentPalette.modelColor(for: $0.name),
                        name: AgentPalette.modelDisplayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost,
                        input: $0.inputTokens, output: $0.outputTokens, cacheRead: $0.cacheReadTokens)
            }
        }
        let shown = Array(all.prefix(Self.maxRows))
        let rest = all.dropFirst(Self.maxRows)
        return (shown, rest.count, rest.reduce(0) { $0 + $1.cost })
    }

    private var rows: some View {
        let items = rowItems
        return VStack(spacing: 0) {
            ForEach(items.shown) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(item.dot)
                        .frame(width: 6, height: 6)
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Text(Format.tokens(item.tokens))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(Format.cost(item.cost))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(
                    hoveredRowID == item.id ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .padding(.horizontal, 6)
                .onHover { inside in
                    hoveredRowID = inside ? item.id : (hoveredRowID == item.id ? nil : hoveredRowID)
                }
            }
            if items.moreCount > 0 {
                HStack {
                    Text("+\(items.moreCount) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(Format.cost(items.moreCost))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
            }
            if items.shown.isEmpty {
                Text(store.state == .refreshing ? "Scanning agent logs…" : "No usage in this period")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Current 5h block (local estimate from ccusage blocks)

    /// Each provider has its own limit system: Claude gets the local 5h-block
    /// estimate, Codex gets the server-reported quota from its session logs.
    /// On the All tab this collapses to one summary line; hovering it opens
    /// the side panel with the full per-provider breakdown.
    private var blockSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch selectedAgent {
            case nil:
                limitsSummaryRow
            case "claude":
                claudeBlockContent
            case "codex":
                codexQuotaContent
            case "opencode":
                placeholderRow("OpenCode limits", detail: "pay-per-token · no quota window")
            default:
                placeholderRow("\(AgentPalette.displayName(selectedAgent ?? "")) limits",
                               detail: "tracked server-side · not connected yet")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Limits summary (All tab) + hover side panel

    @State private var limitsPanelOpen = false
    @State private var panelHideTask: Task<Void, Never>?

    private func setLimitsPanel(hovering: Bool) {
        panelHideTask?.cancel()
        panelHideTask = nil
        if hovering {
            limitsPanelOpen = true
        } else {
            // Grace period so the pointer can travel from the summary row
            // into the panel without it collapsing mid-flight.
            panelHideTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                limitsPanelOpen = false
            }
        }
    }

    private var claudeWorstPercent: Double? {
        if let quota = store.snapshot?.claudeQuota,
           let worst = quota.windows.map(\.usedPercent).max() {
            return worst
        }
        if let block = store.snapshot?.activeBlock, block.end > .now {
            return block.percentUsed
        }
        return nil
    }

    private var codexWorstPercent: Double? {
        store.snapshot?.codexQuota?.windows.map(\.usedPercent).max()
    }

    private var limitsSummaryRow: some View {
        HStack(spacing: 10) {
            Text("Limits")
                .font(.system(size: 11, weight: .medium))
            providerPill(agent: "claude", percent: claudeWorstPercent)
            providerPill(agent: "codex", percent: codexWorstPercent)
            Spacer()
            Text(limitsPanelOpen ? "›" : "details ›")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onHover { setLimitsPanel(hovering: $0) }
    }

    private func providerPill(agent: String, percent: Double?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AgentPalette.color(for: agent).opacity(percent == nil ? 0.4 : 1))
                .frame(width: 6, height: 6)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(percent.map { meterColor(percent: $0, status: "ok") } ?? .secondary)
        }
    }

    private var limitsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider limits")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            claudeBlockContent
            Divider()
            codexQuotaContent
            Divider()
            placeholderRow("OpenCode", detail: "pay-per-token · no window")
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 248, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { setLimitsPanel(hovering: $0) }
    }

    @ViewBuilder
    private var claudeBlockContent: some View {
        if let quota = store.snapshot?.claudeQuota, !quota.windows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(quota.windows, id: \.self) { window in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AgentPalette.color(for: "claude"))
                            .frame(width: 6, height: 6)
                        Text("Claude · \(window.label) limit")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let resets = window.resetsAt {
                            Text("resets \(resetText(resets))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    meter(percent: window.usedPercent, status: "ok")
                }
                Text(claudeCaption(quota))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else if let block = store.snapshot?.activeBlock, block.end > .now {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AgentPalette.color(for: "claude"))
                        .frame(width: 6, height: 6)
                    Text("Claude · current 5h block")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("ends in \(remaining(until: block.end, now: context.date))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                meter(percent: block.percentUsed, status: block.limitStatus)
                Text("\(Format.cost(block.cost)) · \(Format.tokens(block.tokens)) tok · \(Int(block.percentUsed.rounded()))% of usual peak · → \(Format.cost(block.projectedCost)) projected")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            placeholderRow("Claude · 5h block", detail: "idle — no active block", dotAgent: "claude")
        }
    }

    @ViewBuilder
    private var codexQuotaContent: some View {
        if let quota = store.snapshot?.codexQuota, !quota.windows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(quota.windows, id: \.self) { window in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AgentPalette.color(for: "codex"))
                            .frame(width: 6, height: 6)
                        Text("Codex · \(window.label) limit")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let resets = window.resetsAt {
                            Text("resets \(resetText(resets))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    meter(percent: window.usedPercent, status: "ok")
                }
                Text(codexCaption(quota))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            placeholderRow("Codex limits", detail: "no session data yet — run Codex once", dotAgent: "codex")
        }
    }

    private func claudeCaption(_ quota: ClaudeQuota) -> String {
        var parts: [String] = []
        if let plan = quota.subscriptionType {
            parts.append("\(plan) plan · live from Anthropic")
        } else {
            parts.append("live from Anthropic")
        }
        if let block = store.snapshot?.activeBlock, block.end > .now {
            parts.append("this block \(Format.cost(block.cost)) → \(Format.cost(block.projectedCost)) proj")
        }
        return parts.joined(separator: " · ")
    }

    private func codexCaption(_ quota: CodexQuota) -> String {
        var parts: [String] = ["\(Int(quota.windows[0].usedPercent.rounded()))% used"]
        if let plan = quota.planType { parts.append("\(plan) plan") }
        if let observed = quota.observedAt {
            parts.append("reported by Codex \(Format.age(since: observed))")
        }
        return parts.joined(separator: " · ")
    }

    private func placeholderRow(_ title: String, detail: String, dotAgent: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let dotAgent {
                Circle()
                    .fill(AgentPalette.color(for: dotAgent).opacity(0.5))
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func meter(percent: Double, status: String) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(meterColor(percent: percent, status: status))
                    .frame(width: geo.size.width * min(percent / 100, 1))
            }
        }
        .frame(height: 4)
    }

    private func meterColor(percent: Double, status: String) -> Color {
        if status == "exceeds" || percent >= 95 { return Color(red: 0.80, green: 0.35, blue: 0.32) }
        if status == "warning" || percent >= 75 { return Color(red: 0.83, green: 0.55, blue: 0.25) }
        return .accentColor
    }

    private func resetText(_ date: Date) -> String {
        let hours = date.timeIntervalSinceNow / 3600
        if hours < 24 {
            return "at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "in \(Int((hours / 24).rounded()))d"
    }

    private func remaining(until end: Date, now: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: Awake

    private var awakeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Keep awake", systemImage: awake.isAwake ? "eye.fill" : "eye")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { awake.isAwake },
                    set: { awake.setAwake($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            HStack {
                Text(awake.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(awake.isAwake ? Color.accentColor : .init(.tertiaryLabelColor))
                Spacer()
                if !awake.isAwake {
                    HStack(spacing: 4) {
                        chip("1h") { awake.hold(for: 3600) }
                        chip("4h") { awake.hold(for: 4 * 3600) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            footerButton("arrow.clockwise", "Refresh") {
                Task { await store.refresh() }
            }
            Spacer()
            footerButton("moon.fill", "Lock & Sleep") {
                awake.lockAndSleep()
            }
            Spacer()
            footerButton("power", "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func footerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Palette

enum AgentPalette {
    static func color(for agent: String) -> Color {
        switch agent.lowercased() {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": Color(red: 0.33, green: 0.55, blue: 0.90)
        case "opencode": Color(red: 0.30, green: 0.69, blue: 0.49)
        case "hermes": Color(red: 0.62, green: 0.47, blue: 0.85)
        default: Color(.systemGray)
        }
    }

    static func displayName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    static func shortName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude"
        default: displayName(agent)
        }
    }

    static func modelColor(for model: String) -> Color {
        let m = model.lowercased()
        if m.hasPrefix("claude") { return color(for: "claude") }
        if m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") { return color(for: "codex") }
        if m.hasPrefix("gemini") { return Color(red: 0.35, green: 0.61, blue: 0.84) }
        if m.hasPrefix("kimi") || m.hasPrefix("deepseek") || m.hasPrefix("qwen") { return color(for: "opencode") }
        if m.hasPrefix("grok") { return Color(.systemGray) }
        return color(for: "hermes")
    }

    /// Trim noisy date-stamp suffixes: claude-haiku-4-5-20251001 → claude-haiku-4-5
    static func modelDisplayName(_ model: String) -> String {
        if let range = model.range(of: #"-20\d{6}$"#, options: .regularExpression) {
            return String(model[..<range.lowerBound])
        }
        return model
    }
}
