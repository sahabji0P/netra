import AppKit
import SwiftUI

enum PeriodTab: String, CaseIterable {
    case today = "Today"
    case week = "Week"
    case month = "Month"
}

struct MenuView: View {
    @Bindable var store: UsageStore
    @Bindable var awake: AwakeController
    @State private var tab: PeriodTab = .today

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
            picker
            agents
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
            Text(Format.cost(stat.cost))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: stat.cost)
            Text("est. API-equivalent cost · \(periodCaption)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(Format.tokens(stat.inputTokens)) in · \(Format.tokens(stat.outputTokens)) out · \(Format.tokens(stat.cacheReadTokens)) cached")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
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

    private var agents: some View {
        VStack(spacing: 0) {
            ForEach(stat.agents) { agent in
                HStack(spacing: 8) {
                    Circle()
                        .fill(AgentPalette.color(for: agent.name))
                        .frame(width: 6, height: 6)
                    Text(AgentPalette.displayName(agent.name))
                        .font(.system(size: 12))
                    Spacer()
                    Text(Format.tokens(agent.totalTokens))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(Format.cost(agent.cost))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            if stat.agents.isEmpty {
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
}
