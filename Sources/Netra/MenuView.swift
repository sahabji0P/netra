import AppKit
import SwiftUI

enum RowsMode: String, CaseIterable {
    case agents
    case models
}

struct MenuView: View {
    @Bindable var store: UsageStore
    @Bindable var awake: AwakeController
    var updates: UpdateChecker
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    // Internal, not private: `private` members aren't visible to the chart and
    // limits extensions in the sibling files.
    @State var tab: PeriodTab = .today
    @State var selectedAgent: String?   // nil = Overview
    @State private var rowsMode: RowsMode = .agents
    @State var hoveredPeriod: String?
    @State var selectedPeriod: String?   // pinned by clicking a bar
    @State private var hoveredRowID: String?
    @State var limitsPanelOpen = false
    @State var limitsPanelPinned = false
    @State var panelHideTask: Task<Void, Never>?

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
            if limitsPanelOpen || limitsPanelPinned, selectedAgent == nil {
                Divider()
                limitsPanel
            }
        }
        .animation(.snappy(duration: 0.18), value: limitsPanelOpen || limitsPanelPinned)
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
        VStack(spacing: 8) {
            if let version = updates.availableVersion {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                    Text("v\(version) available · brew upgrade netra")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Color.accentColor)
            }
            if LaunchAtLogin.isAvailable {
                HStack {
                    Text("Launch at login")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { on in
                            LaunchAtLogin.set(on)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
            }
            HStack {
                footerButton("arrow.clockwise", "Refresh") {
                    Task { await store.refresh(forceQuota: true) }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
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
