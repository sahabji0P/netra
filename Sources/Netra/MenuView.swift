import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(\.openWindow) private var openWindow

    @Bindable var store: UsageStore
    @Bindable var awake: AwakeController
    var updates: UpdateChecker
    var preferences: AppPreferences
    var dashboardNavigation: DashboardNavigation

    // Internal so the focused chart extension can share the selected period.
    @State var tab: PeriodTab = .today
    @State var hoveredPeriod: String?
    @State var selectedPeriod: String?
    @State private var hoveredProvider: String?

    private struct ProviderSummary: Identifiable {
        var name: String
        var cost: Double
        var totalTokens: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var id: String { name }
    }

    private var currentRow: PeriodRow {
        store.snapshot?.currentRow(for: tab) ?? .zero()
    }

    var displayedRow: PeriodRow {
        if let selectedPeriod,
           let row = store.snapshot?.rows(for: tab).first(where: { $0.period == selectedPeriod }) {
            return row
        }
        return currentRow
    }

    private var displayedCost: Double {
        if let hoveredProvider,
           let provider = providerSummaries.first(where: { $0.name == hoveredProvider }) {
            return provider.cost
        }
        return hoveredChartPoint?.cost ?? displayedRow.cost
    }

    private var displayedTokens: Int {
        if let hoveredProvider,
           let provider = providerSummaries.first(where: { $0.name == hoveredProvider }) {
            return provider.totalTokens
        }
        return hoveredChartPoint?.tokens ?? displayedRow.totalTokens
    }

    private var summaryRow: PeriodRow {
        if let hoveredPeriod,
           let row = store.snapshot?.rows(for: tab).first(where: { $0.period == hoveredPeriod }) {
            return row
        }
        return displayedRow
    }

    private var hasUsageData: Bool {
        guard let snapshot = store.snapshot else { return false }
        return (snapshot.daily + snapshot.weekly + snapshot.monthly).contains(where: rowHasUsage)
    }

    private var hasVisibleLimits: Bool {
        let snapshot = store.snapshot
        let hasClaudeBlock = snapshot?.activeBlock.map { $0.end > .now } == true
        let hasCodexQuota = snapshot?.codexQuota?.activeWindows().isEmpty == false
        return hasClaudeBlock || hasCodexQuota
    }

    private var providerSummaries: [ProviderSummary] {
        var summaries = displayedRow.agents.map {
            ProviderSummary(
                name: $0.name,
                cost: $0.cost,
                totalTokens: $0.totalTokens,
                inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens,
                cacheReadTokens: $0.cacheReadTokens
            )
        }

        let attributedCost = summaries.reduce(0) { $0 + $1.cost }
        let attributedTokens = summaries.reduce(0) { $0 + $1.totalTokens }
        let attributedInput = summaries.reduce(0) { $0 + $1.inputTokens }
        let attributedOutput = summaries.reduce(0) { $0 + $1.outputTokens }
        let attributedCache = summaries.reduce(0) { $0 + $1.cacheReadTokens }
        let other = ProviderSummary(
            name: "other",
            cost: max(0, displayedRow.cost - attributedCost),
            totalTokens: max(0, displayedRow.totalTokens - attributedTokens),
            inputTokens: max(0, displayedRow.inputTokens - attributedInput),
            outputTokens: max(0, displayedRow.outputTokens - attributedOutput),
            cacheReadTokens: max(0, displayedRow.cacheReadTokens - attributedCache)
        )
        if other.cost > 0.000_001 || other.totalTokens > 0 ||
            other.inputTokens > 0 || other.outputTokens > 0 || other.cacheReadTokens > 0 {
            summaries.append(other)
        }
        return summaries
    }

    private var activityProviderNames: String {
        guard let snapshot = store.snapshot else { return "No providers" }
        let rows = snapshot.rows(for: tab)
        var names = Set(rows.flatMap { $0.agents.map(\.name) })
        if rows.contains(where: hasUnattributedUsage) {
            names.insert("other")
        }
        let displayNames = names
            .map(AgentPalette.displayName)
            .sorted()
        return displayNames.isEmpty ? "No providers" : displayNames.joined(separator: ", ")
    }

    private var activityAccessibilityValue: String {
        var value = "Providers: \(activityProviderNames)"
        if selectedPeriod != nil {
            value += ". Pinned \(periodCaption), \(Format.cost(displayedRow.cost)), " +
                "\(displayedRow.totalTokens.formatted(.number)) processed tokens"
        }
        return value
    }

    private func rowHasUsage(_ row: PeriodRow) -> Bool {
        row.cost > 0 || row.totalTokens > 0 || row.inputTokens > 0 ||
            row.outputTokens > 0 || row.cacheReadTokens > 0 ||
            !row.agents.isEmpty || !row.models.isEmpty
    }

    private func hasUnattributedUsage(_ row: PeriodRow) -> Bool {
        let attributedCost = row.agents.reduce(0) { $0 + $1.cost }
        let attributedTokens = row.agents.reduce(0) { $0 + $1.totalTokens }
        return row.cost - attributedCost > 0.000_001 || row.totalTokens > attributedTokens
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            periodPicker
            usageSummary

            if !hasUsageData {
                emptyState
            } else {
                if preferences.showsLimits && hasVisibleLimits {
                    sectionDivider
                    limitsSection
                }
                if preferences.showsActivityChart {
                    sectionDivider
                    activitySection
                }
                if preferences.showsProviderBreakdown {
                    sectionDivider
                    providerSection
                }
            }

            sectionDivider
            dashboardActions

            if preferences.showsKeepAwake {
                sectionDivider
                awakeSection
            }

            sectionDivider
            footer
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            menuContent
            ScrollView(.vertical) {
                menuContent
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 340)
        .frame(maxHeight: maximumPopoverHeight)
        .onAppear { store.refreshIfStale() }
    }

    private var maximumPopoverHeight: CGFloat {
        let visibleHeight = NSApp.keyWindow?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 800
        return max(360, min(720, visibleHeight - 48))
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 16)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Netra")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text("v\(updates.currentVersion ?? "dev")")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
            Spacer()
            if store.state == .refreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                Text(headerStatus(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(headerStatusColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
    }

    private var headerStatusColor: Color {
        switch store.state {
        case .failed: .orange
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func headerStatus(now: Date) -> String {
        switch store.state {
        case .refreshing: return "refreshing…"
        case .failed: return store.snapshot == nil ? "refresh failed" : "showing saved data"
        case .empty: return "no data yet"
        case .fresh, .stale:
            guard let at = store.snapshot?.fetchedAt else { return "" }
            let age = Format.age(since: at, now: now)
            return store.state == .stale ? "stale · \(age)" : "updated \(age)"
        }
    }

    // MARK: Summary

    private var periodPicker: some View {
        Picker("Period", selection: $tab) {
            ForEach(PeriodTab.allCases, id: \.self) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .onChange(of: tab) {
            hoveredPeriod = nil
            selectedPeriod = nil
            hoveredProvider = nil
        }
    }

    private var usageSummary: some View {
        Button {
            showDashboard(.usage)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.cost(displayedCost))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(summaryCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                summaryMetadata
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage for \(periodCaption)")
        .accessibilityValue(
            "\(Format.cost(displayedCost)) equivalent API cost, " +
            "\(displayedTokens.formatted(.number)) processed tokens"
        )
        .accessibilityHint("Opens the detailed usage dashboard")
    }

    private var summaryMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                summaryMetadataContent
                Spacer()
                pinnedPeriodLabel
            }
            VStack(alignment: .leading, spacing: 2) {
                summaryMetadataContent
                pinnedPeriodLabel
            }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
    }

    private var summaryMetadataContent: some View {
        HStack(spacing: 5) {
            Text("\(Format.tokens(displayedTokens)) processed")
            Text("·")
            Text(tokenComposition)
        }
    }

    @ViewBuilder
    private var pinnedPeriodLabel: some View {
        if selectedPeriod != nil {
            Text("Pinned")
                .foregroundStyle(Color.accentColor)
        }
    }

    private var summaryCaption: String {
        if let provider = hoveredProvider {
            return "\(AgentPalette.displayName(provider)) · equivalent API cost · \(periodCaption)"
        }
        if let hoveredChartPoint {
            return "Equivalent API cost · \(hoveredChartPoint.label)"
        }
        return "Equivalent API cost, not subscription spend · \(periodCaption)"
    }

    private var tokenComposition: String {
        let row: (input: Int, output: Int, cached: Int)
        if let hoveredProvider,
           let provider = providerSummaries.first(where: { $0.name == hoveredProvider }) {
            row = (provider.inputTokens, provider.outputTokens, provider.cacheReadTokens)
        } else {
            row = (summaryRow.inputTokens, summaryRow.outputTokens, summaryRow.cacheReadTokens)
        }
        return "\(Format.tokens(row.output)) out · \(Format.tokens(row.cached)) cached"
    }

    private var periodCaption: String {
        let calendar = Calendar.current
        switch tab {
        case .today:
            if selectedPeriod == nil { return "today" }
            return displayedRow.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            let week = calendar.component(.weekOfYear, from: displayedRow.date)
            return "week \(week)"
        case .month:
            return displayedRow.date.formatted(.dateTime.month(.wide).year())
        }
    }

    // MARK: Compact sections

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("Limits now", detail: "Provider reported or local estimate")
            if store.snapshot?.activeBlock.map({ $0.end > .now }) == true {
                limitsContent(for: "claude")
            }
            if store.snapshot?.codexQuota?.activeWindows().isEmpty == false {
                limitsContent(for: "codex")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Activity", detail: selectedPeriod == nil ? "Click a bar to pin" : "Pinned · click again to clear")
                .padding(.horizontal, 16)
                .padding(.top, 9)
            chart
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Provider activity for \(tab.rawValue.lowercased())")
                .accessibilityValue(activityAccessibilityValue)
                .accessibilityHint("Swipe up or down to pin a period. Open Usage for detailed values.")
                .accessibilityAdjustableAction { direction in
                    adjustPinnedPeriod(direction)
                }
                .accessibilityAction(named: "Clear pinned period") {
                    selectedPeriod = nil
                }
        }
    }

    private var providerSection: some View {
        let providers = Array(providerSummaries.prefix(4))
        return VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Providers", detail: periodCaption.capitalized)
            ForEach(providers) { provider in
                providerRow(provider)
                    .onHover { inside in
                        hoveredProvider = inside
                            ? provider.name
                            : (hoveredProvider == provider.name ? nil : hoveredProvider)
                    }
            }
            if providerSummaries.isEmpty {
                Text("No provider usage in this period")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 3)
            } else if providerSummaries.count > providers.count {
                Button("View \(providerSummaries.count - providers.count) more in Usage") {
                    showDashboard(.usage)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func providerRow(_ provider: ProviderSummary) -> some View {
        let share = displayedRow.cost > 0 ? provider.cost / displayedRow.cost : 0
        return VStack(spacing: 3) {
            ViewThatFits(in: .horizontal) {
                providerMetrics(provider)
                VStack(alignment: .leading, spacing: 2) {
                    providerIdentity(provider)
                    HStack {
                        Text("\(Format.tokens(provider.totalTokens)) processed")
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(Format.cost(provider.cost))
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.system(size: 10))
                }
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(AgentPalette.color(for: provider.name).opacity(0.72))
                            .frame(width: geometry.size.width * max(0, min(share, 1)))
                    }
            }
            .frame(height: 2)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentPalette.displayName(provider.name))
        .accessibilityValue(
            "\(Format.cost(provider.cost)), " +
            "\(provider.totalTokens.formatted(.number)) processed tokens, " +
            "\(Int((share * 100).rounded())) percent of this period"
        )
    }

    private func providerMetrics(_ provider: ProviderSummary) -> some View {
        HStack(spacing: 7) {
            providerIdentity(provider)
            Spacer()
            Text(Format.tokens(provider.totalTokens))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(Format.cost(provider.cost))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private func providerIdentity(_ provider: ProviderSummary) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AgentPalette.color(for: provider.name))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(AgentPalette.displayName(provider.name))
                .font(.system(size: 11))
                .lineLimit(2)
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
        }
    }

    // MARK: Empty and failure states

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 5) {
            if case .failed(let message) = store.state {
                Text("Couldn't read agent usage")
                    .font(.system(size: 11, weight: .medium))
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry") { Task { await store.refresh() } }
                    .controlSize(.small)
            } else if store.state == .refreshing {
                Text("Scanning local agent logs…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("No agent usage found")
                    .font(.system(size: 11, weight: .medium))
                Text("Run Claude Code, Codex, or OpenCode once, then refresh.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Dashboard actions

    private var dashboardActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                dashboardButton("Open Usage", symbol: "chart.xyaxis.line", section: .usage)
                dashboardButton("Settings", symbol: "gearshape", section: .settings)
            }
            VStack(spacing: 6) {
                dashboardButton("Open Usage", symbol: "chart.xyaxis.line", section: .usage)
                dashboardButton("Settings", symbol: "gearshape", section: .settings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func dashboardButton(
        _ title: String,
        symbol: String,
        section: DashboardSection
    ) -> some View {
        Button {
            showDashboard(section)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func showDashboard(_ section: DashboardSection) {
        dashboardNavigation.selection = section
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Awake

    private var awakeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Keep awake", systemImage: awake.isAwake ? "eye.fill" : "eye")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("Keep awake", isOn: Binding(
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
                    .foregroundStyle(awake.isAwake ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                Spacer()
                if !awake.isAwake {
                    HStack(spacing: 4) {
                        durationButton("1h") { awake.hold(for: 3600) }
                        durationButton("4h") { awake.hold(for: 4 * 3600) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func adjustPinnedPeriod(_ direction: AccessibilityAdjustmentDirection) {
        let visiblePeriodCount: Int
        switch tab {
        case .today: visiblePeriodCount = 31
        case .week: visiblePeriodCount = 12
        case .month: visiblePeriodCount = 6
        }
        let periods = (store.snapshot?.rows(for: tab) ?? [])
            .sorted { $0.date < $1.date }
            .suffix(visiblePeriodCount)
            .map(\.period)
        guard !periods.isEmpty else { return }
        guard let selectedPeriod,
              let currentIndex = periods.firstIndex(of: selectedPeriod) else {
            self.selectedPeriod = periods.last
            return
        }
        switch direction {
        case .increment:
            self.selectedPeriod = periods[min(currentIndex + 1, periods.count - 1)]
        case .decrement:
            self.selectedPeriod = periods[max(currentIndex - 1, 0)]
        @unknown default:
            break
        }
    }

    private func durationButton(_ title: String, action: @escaping () -> Void) -> some View {
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
                    Text("v\(version) available · brew upgrade netra")
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    refreshButton
                    Spacer()
                    lockAndSleepButton
                    Spacer()
                    quitButton
                }
                VStack(alignment: .leading, spacing: 7) {
                    refreshButton
                    lockAndSleepButton
                    quitButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var refreshButton: some View {
        footerButton("arrow.clockwise", "Refresh") {
            Task { await store.refresh() }
        }
    }

    private var lockAndSleepButton: some View {
        footerButton("moon.fill", "Lock & Sleep") {
            awake.lockAndSleep()
        }
    }

    private var quitButton: some View {
        footerButton("power", "Quit") {
            NSApplication.shared.terminate(nil)
        }
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
