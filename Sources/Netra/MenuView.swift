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

    // MARK: Derived data

    private var currentRow: PeriodRow {
        store.snapshot?.currentRow(for: tab) ?? .zero()
    }

    /// (cost, tokens, models) for the current tab, filtered to the selected agent.
    private var agentStat: AgentStat? {
        guard let selectedAgent else { return nil }
        return currentRow.agentStat(selectedAgent)
            ?? AgentStat(name: selectedAgent, cost: 0, totalTokens: 0, models: [])
    }

    private var agentNames: [String] {
        store.snapshot?.agentNames ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabStrip
            totals
            chart
            picker
            if selectedAgent == nil { rowsToggle }
            rows
            Divider().padding(.horizontal, 16)
            awakeSection
            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: 316)
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
        HStack(spacing: 4) {
            tabChip("Overview", isSelected: selectedAgent == nil) { selectedAgent = nil }
            ForEach(agentNames, id: \.self) { name in
                tabChip(AgentPalette.shortName(name), isSelected: selectedAgent == name) {
                    selectedAgent = name
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func tabChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Totals

    private var displayedCost: Double {
        if let hovered = hoveredChartPoint { return hovered.cost }
        return agentStat?.cost ?? currentRow.cost
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.cost(displayedCost))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: displayedCost)
            Text(captionLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tokensLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var captionLine: String {
        let scope = selectedAgent.map { AgentPalette.displayName($0) + " · " } ?? ""
        if let hovered = hoveredChartPoint {
            return scope + "est. API cost · \(hovered.label)"
        }
        return scope + "est. API-equivalent cost · \(periodCaption)"
    }

    private var tokensLine: String {
        if let hovered = hoveredChartPoint {
            return "\(Format.tokens(hovered.tokens)) tokens in this period"
        }
        if let agentStat {
            return "\(Format.tokens(agentStat.totalTokens)) tokens"
        }
        return "\(Format.tokens(currentRow.inputTokens)) in · \(Format.tokens(currentRow.outputTokens)) out · \(Format.tokens(currentRow.cacheReadTokens)) cached"
    }

    private var periodCaption: String {
        let calendar = Calendar.current
        switch tab {
        case .today:
            return "today"
        case .week:
            let week = calendar.component(.weekOfYear, from: currentRow.date)
            return "W\(week) · week of \(currentRow.date.formatted(.dateTime.day().month(.abbreviated)))"
        case .month:
            return currentRow.date.formatted(.dateTime.month(.wide)).lowercased()
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
            .foregroundStyle(
                point.period == hoveredPeriod
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.32)
            )
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
                            if let date: Date = proxy.value(atX: location.x) {
                                hoveredPeriod = points.last {
                                    guard let interval = Calendar.current.dateInterval(of: chartUnit, for: $0.date) else { return false }
                                    return interval.contains(date)
                                }?.period
                            }
                        case .ended:
                            hoveredPeriod = nil
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
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
        .onChange(of: tab) { hoveredPeriod = nil }
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
    }

    /// At most this many rows; the rest collapse into one "+N more" line.
    private static let maxRows = 6

    private var rowItems: (shown: [RowItem], moreCount: Int, moreCost: Double) {
        let all: [RowItem]
        if let agentStat {
            all = agentStat.models.map {
                RowItem(id: $0.id, dot: AgentPalette.modelColor(for: $0.name),
                        name: AgentPalette.modelDisplayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost)
            }
        } else if rowsMode == .agents {
            all = currentRow.agents.map {
                RowItem(id: $0.id, dot: AgentPalette.color(for: $0.name),
                        name: AgentPalette.displayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost)
            }
        } else {
            all = currentRow.models.map {
                RowItem(id: $0.id, dot: AgentPalette.modelColor(for: $0.name),
                        name: AgentPalette.modelDisplayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
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
