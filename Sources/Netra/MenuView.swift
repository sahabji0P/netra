import AppKit
import Charts
import SwiftUI

enum PeriodTab: String, CaseIterable {
    case today = "Today"
    case week = "Week"
    case month = "Month"
}

enum RowsMode: String, CaseIterable {
    case agents
    case models
}

struct MenuView: View {
    @Bindable var store: UsageStore
    @Bindable var awake: AwakeController
    @State private var tab: PeriodTab = .today
    @State private var rowsMode: RowsMode = .agents
    @State private var hoveredDay: Date?

    private var stat: PeriodStat {
        guard let snapshot = store.snapshot else { return .zero }
        switch tab {
        case .today: return snapshot.today
        case .week: return snapshot.week
        case .month: return snapshot.month
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            totals
            history
            picker
            rowsToggle
            rows
            Divider().padding(.horizontal, 16)
            awakeSection
            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: 300)
        .onAppear { store.refreshIfStale() }
    }

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

    private var totals: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.cost(hoveredPoint?.cost ?? stat.cost))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: hoveredPoint?.cost ?? stat.cost)
            Text(hoveredPoint == nil
                ? "est. API-equivalent cost · \(periodCaption)"
                : "est. API-equivalent cost · \(hoveredPoint!.date.formatted(.dateTime.day().month(.abbreviated)))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(hoveredPoint == nil
                ? "\(Format.tokens(stat.inputTokens)) in · \(Format.tokens(stat.outputTokens)) out · \(Format.tokens(stat.cacheReadTokens)) cached"
                : "\(Format.tokens(hoveredPoint!.totalTokens)) tokens that day")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: History chart (last 30 days, hover for a day's numbers)

    private var hoveredPoint: DayPoint? {
        guard let hoveredDay else { return nil }
        return store.snapshot?.history.first {
            Calendar.current.isDate($0.date, inSameDayAs: hoveredDay)
        }
    }

    private var history: some View {
        let points = store.snapshot?.history ?? []
        let end = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: -29, to: end) ?? end

        return Chart(points.filter { $0.date >= start }) { point in
            BarMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Cost", point.cost)
            )
            .foregroundStyle(
                hoveredDay.map { Calendar.current.isDate($0, inSameDayAs: point.date) } ?? false
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.32)
            )
            .cornerRadius(1.5)
        }
        .chartXScale(domain: start...Calendar.current.date(byAdding: .day, value: 1, to: end)!)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let date: Date = proxy.value(atX: location.x) {
                                hoveredDay = Calendar.current.startOfDay(for: date)
                            }
                        case .ended:
                            hoveredDay = nil
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// "today" / "week of 3 Aug" / "August" — says exactly what window the number covers.
    private var periodCaption: String {
        let formatter = DateFormatter()
        switch tab {
        case .today:
            return "today"
        case .week:
            formatter.dateFormat = "yyyy-MM-dd"
            guard let start = formatter.date(from: stat.period) else { return "this week" }
            return "week of \(start.formatted(.dateTime.day().month(.abbreviated)))"
        case .month:
            formatter.dateFormat = "yyyy-MM"
            guard let start = formatter.date(from: stat.period) else { return "this month" }
            return start.formatted(.dateTime.month(.wide)).lowercased()
        }
    }

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
    }

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
        .padding(.top, 10)
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
        switch rowsMode {
        case .agents:
            all = stat.agents.map {
                RowItem(id: $0.id, dot: AgentPalette.color(for: $0.name),
                        name: AgentPalette.displayName($0.name),
                        tokens: $0.totalTokens, cost: $0.cost)
            }
        case .models:
            all = stat.models.map {
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
