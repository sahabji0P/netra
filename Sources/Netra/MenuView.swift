import AppKit
import SwiftUI

/// The menu-bar popover. Reading order follows what a subscription user
/// checks first: limits and resets, then what the period cost, then actions.
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
    /// The side panel currently shown beside the popover, if any.
    // Internal so the limit cards (LimitsViews.swift) can drive the panel.
    @State var panelTarget: UsagePanelTarget?
    @State var panelHoverTask: Task<Void, Never>?
    @State private var appliedDefaultPeriod = false

    static let width: CGFloat = 360
    /// Offscreen renders take one layout pass, so the measured height never
    /// settles; the preview harness draws the content at full height instead.
    var rendersFullHeight = false

    struct ProviderSummary: Identifiable {
        var name: String
        var cost: Double
        var totalTokens: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var id: String { name }
    }

    /// Providers the user has hidden from the popover (dashboard is unaffected).
    var hiddenProviders: Set<String> {
        preferences.hiddenMenuProviders
    }

    /// Rows for the current tab with hidden providers already removed, so the
    /// summary number, chart, and provider list all agree with each other.
    func visibleRows(for tab: PeriodTab) -> [PeriodRow] {
        (store.snapshot?.rows(for: tab) ?? []).map { $0.filtered(hidingProviders: hiddenProviders) }
    }

    private var currentRow: PeriodRow {
        (store.snapshot?.currentRow(for: tab) ?? .zero()).filtered(hidingProviders: hiddenProviders)
    }

    var displayedRow: PeriodRow {
        if let selectedPeriod,
           let row = visibleRows(for: tab).first(where: { $0.period == selectedPeriod }) {
            return row
        }
        return currentRow
    }


    private var displayedCost: Double {
        hoveredChartPoint?.cost ?? displayedRow.cost
    }

    private var displayedTokens: Int {
        hoveredChartPoint?.tokens ?? displayedRow.totalTokens
    }

    private var hasUsageData: Bool {
        guard let snapshot = store.snapshot else { return false }
        return (snapshot.daily + snapshot.weekly + snapshot.monthly).contains(where: rowHasUsage)
    }

    private var showsLimitCards: Bool {
        preferences.showsLimits && (!limitCards.isEmpty || missingClaudeLimitsReason != nil)
    }

    /// The row the provider list describes: a hovered chart bar wins over
    /// the pinned or current period, matching the headline number.
    private var listedRow: PeriodRow {
        if let hoveredPeriod,
           let row = visibleRows(for: tab).first(where: { $0.period == hoveredPeriod }) {
            return row
        }
        return displayedRow
    }

    var providerSummaries: [ProviderSummary] {
        let displayedRow = listedRow
        var summaries = displayedRow.agents.map {
            ProviderSummary(
                name: $0.name, cost: $0.cost, totalTokens: $0.totalTokens,
                inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                cacheReadTokens: $0.cacheReadTokens
            )
        }
        if let other = displayedRow.unattributed {
            summaries.append(ProviderSummary(
                name: other.name, cost: other.cost, totalTokens: other.totalTokens,
                inputTokens: other.inputTokens, outputTokens: other.outputTokens,
                cacheReadTokens: other.cacheReadTokens
            ))
        }
        return summaries
    }

    /// How many providers this period's unfiltered data contains that the
    /// user has hidden — surfaced so hiding never looks like missing data.
    private var hiddenProviderCount: Int {
        guard !hiddenProviders.isEmpty,
              let row = store.snapshot?.currentRow(for: tab) else { return 0 }
        var names = Set(row.agents.map { $0.name.lowercased() })
        if row.unattributed != nil { names.insert("other") }
        return names.intersection(hiddenProviders).count
    }

    private var activityAccessibilityValue: String {
        var value = "Providers: " + Set(visibleRows(for: tab).flatMap { $0.agents.map(\.name) })
            .map(AgentPalette.displayName).sorted().joined(separator: ", ")
        if selectedPeriod != nil {
            value += ". Pinned \(periodCaption), \(Format.cost(displayedRow.cost)), " +
                "\(displayedRow.totalTokens.formatted(.number)) processed tokens"
        }
        return value
    }

    private func rowHasUsage(_ row: PeriodRow) -> Bool {
        row.cost > 0 || row.totalTokens > 0 || !row.agents.isEmpty || !row.models.isEmpty
    }

    // MARK: Layout

    var body: some View {
        if rendersFullHeight {
            menuContent
        } else {
            scrollingBody
        }
    }

    /// Static sizing: the popover takes its content's natural height when
    /// that fits the screen, and only scrolls when it does not. (Measuring
    /// the content and feeding the height back into the frame left the
    /// window stuck at its initial height on some Macs.)
    private var scrollingBody: some View {
        ViewThatFits(in: .vertical) {
            menuContent
            ScrollView(.vertical) {
                menuContent
            }
            .scrollIndicators(.hidden)
            .frame(height: maximumPopoverHeight)
        }
        .frame(width: Self.width)
        .frame(maxHeight: maximumPopoverHeight)
        .onAppear {
            // Netra is a menu-bar-only app, so it is not active when the
            // popover opens, and SwiftUI does not deliver hover to an
            // inactive app's window. Activate so hover works immediately.
            NSApp.activate()
            if !appliedDefaultPeriod {
                tab = preferences.defaultPeriod
                appliedDefaultPeriod = true
            }
            store.refreshIfStale()
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsLimitCards {
                limitsSection
                sectionDivider
            }
            if hasUsageData {
                usageSection
            } else {
                emptyState
            }
            if updates.availableVersion != nil {
                sectionDivider
                updateBanner
            }
            sectionDivider
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var maximumPopoverHeight: CGFloat {
        let visibleHeight = NSApp.keyWindow?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 800
        return max(360, min(760, visibleHeight - 48))
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 16)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Netra")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            if store.state == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                Text(headerStatus(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(headerStatusColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, showsLimitCards ? 0 : 8)
    }

    private var headerStatusColor: Color {
        switch store.state {
        case .failed, .stale: .orange
        default: .secondary
        }
    }

    private func headerStatus(now: Date) -> String {
        switch store.state {
        case .refreshing: return "Refreshing…"
        case .failed: return store.snapshot == nil ? "Refresh failed" : "Couldn't refresh · showing saved"
        case .empty: return "No data yet"
        case .fresh, .stale:
            guard let at = store.snapshot?.fetchedAt else { return "" }
            let age = Format.age(since: at, now: now)
            return store.state == .stale ? "Saved data · \(age)" : "Updated \(age)"
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                periodPicker
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            usageSummary
            if preferences.showsActivityChart {
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
            if preferences.showsProviderBreakdown && (!providerSummaries.isEmpty || hiddenProviderCount > 0) {
                providerList
            }
        }
        .padding(.bottom, 6)
    }

    private var periodPicker: some View {
        Picker("Period", selection: $tab) {
            ForEach(PeriodTab.allCases, id: \.self) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .onChange(of: tab) {
            hoveredPeriod = nil
            selectedPeriod = nil
            panelTarget = nil
        }
    }

    private var usageSummary: some View {
        Button {
            showDashboard(.usage)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.cost(displayedCost))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(Format.tokens(displayedTokens)) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .help("Estimated at API list prices — what this usage would cost pay-as-you-go, not your subscription bill. Click for the full dashboard.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage for \(periodCaption)")
        .accessibilityValue(
            "\(Format.cost(displayedCost)) equivalent API cost, " +
            "\(displayedTokens.formatted(.number)) processed tokens"
        )
        .accessibilityHint("Opens the detailed usage dashboard")
    }

    private var summaryCaption: String {
        if let hoveredChartPoint {
            return "API-equivalent · \(hoveredChartPoint.label)"
        }
        return selectedPeriod == nil
            ? "API-equivalent · \(periodCaption)"
            : "API-equivalent · \(periodCaption) · pinned"
    }

    var periodCaption: String {
        switch tab {
        case .today:
            if selectedPeriod == nil { return "today" }
            return displayedRow.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            if selectedPeriod == nil { return "this week" }
            return "week \(PeriodKeys.weeks().component(.weekOfYear, from: displayedRow.date))"
        case .month:
            return displayedRow.date.formatted(.dateTime.month(.wide))
        }
    }

    private var providerList: some View {
        let providers = Array(providerSummaries.prefix(5))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(providers) { provider in
                providerRow(provider)
            }
            if providerSummaries.isEmpty {
                Text("All providers with usage are hidden — adjust in Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            let overflow = providerSummaries.count - providers.count
            if overflow > 0 || hiddenProviderCount > 0 {
                HStack {
                    if overflow > 0 {
                        Button("\(overflow) more in Usage") { showDashboard(.usage) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if hiddenProviderCount > 0 {
                        Button("\(hiddenProviderCount) hidden") { showDashboard(.providers) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Some providers are hidden from this menu. Manage them in Settings.")
                    }
                }
                .font(.system(size: 10.5))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: Side panel

    /// Opens the side panel after a short hover (so passing the mouse over
    /// the list does not flash panels) and closes it shortly after leaving.
    func panelHover(_ target: UsagePanelTarget, inside: Bool) {
        panelHoverTask?.cancel()
        panelHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(inside ? 250 : 180))
            guard !Task.isCancelled else { return }
            if inside {
                panelTarget = target
            } else if panelTarget == target {
                panelTarget = nil
            }
        }
    }

    func panelBinding(_ target: UsagePanelTarget) -> Binding<Bool> {
        Binding(
            get: { panelTarget == target },
            set: { shown in if !shown, panelTarget == target { panelTarget = nil } }
        )
    }

    func detailPanel(for target: UsagePanelTarget) -> UsageDetailPanel {
        let row = listedRow
        switch target {
        case .provider(let name):
            let agent = name == "other" ? row.unattributed : row.agentStat(name)
            return UsageDetailPanel(
                title: AgentPalette.displayName(name), accent: AgentPalette.color(for: name),
                periodCaption: periodCaption,
                cost: agent?.cost ?? 0, totalTokens: agent?.totalTokens ?? 0,
                inputTokens: agent?.inputTokens ?? 0, outputTokens: agent?.outputTokens ?? 0,
                cacheCreationTokens: agent?.cacheCreationTokens ?? 0, cacheReadTokens: agent?.cacheReadTokens ?? 0,
                models: (agent?.models ?? []).map { (nil, $0) },
                periods: PeriodTab.allCases.map { period in
                    let stat = store.snapshot?.currentRow(for: period).agentStat(name)
                    return (period.caption, stat?.cost ?? 0, stat?.totalTokens ?? 0)
                }
            )
        }
    }

    private func providerRow(_ provider: ProviderSummary) -> some View {
        let row = listedRow
        let share = row.cost > 0 ? provider.cost / row.cost : 0
        let cost = Format.providerCost(provider.name, cost: provider.cost, tokens: provider.totalTokens)
        return HStack(spacing: 8) {
            Circle()
                .fill(AgentPalette.color(for: provider.name))
                .frame(width: 7, height: 7)
            Text(AgentPalette.displayName(provider.name))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(Format.tokens(provider.totalTokens))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(cost)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentPalette.displayName(provider.name))
        .accessibilityValue(
            (Format.isUnpriced(provider.name, cost: provider.cost, tokens: provider.totalTokens)
                ? "cost not estimated, " : "\(Format.cost(provider.cost)), ") +
            "\(provider.totalTokens.formatted(.number)) processed tokens, " +
            "\(Int((share * 100).rounded())) percent of this period"
        )
    }

    // MARK: Empty and failure states

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if case .failed(let message) = store.state {
                Text("Couldn't read agent usage")
                    .font(.system(size: 12, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry") { Task { await store.refresh() } }
                    .controlSize(.small)
            } else if store.state == .refreshing || store.state == .empty {
                Text("Scanning local agent logs…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("No agent usage found")
                    .font(.system(size: 12, weight: .medium))
                Text("Run a coding agent (Claude Code, Codex, Gemini CLI, …) once, then refresh.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Footer

    private var updateBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.circle")
            Text("v\(updates.availableVersion ?? "") available · brew upgrade netra")
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if preferences.showsKeepAwake {
                keepAwakeControl
            }
            Spacer(minLength: 4)
            footerIcon("chart.xyaxis.line", help: "Usage dashboard") { showDashboard(.usage) }
            footerIcon("gearshape", help: "Settings") { showDashboard(.menuBar) }
            footerIcon("arrow.clockwise", help: "Refresh now") { Task { await store.refresh() } }
            footerIcon("moon", help: "Lock & Sleep") { awake.lockAndSleep() }
            footerIcon("power", help: "Quit Netra") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var keepAwakeControl: some View {
        Menu {
            if awake.isAwake {
                Button("Turn off") { awake.setAwake(false) }
                Divider()
            }
            Button("For 1 hour") { awake.hold(for: 3600) }
            Button("For 4 hours") { awake.hold(for: 4 * 3600) }
            Button("Until turned off") { awake.setAwake(true) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: awake.isAwake ? "eye.fill" : "eye")
                Text(awake.isAwake ? "Awake \(awakeStatusShort)" : "Keep awake")
            }
            .font(.system(size: 11.5, weight: awake.isAwake ? .semibold : .regular))
            .foregroundStyle(awake.isAwake ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Blocks idle sleep so agents keep running. The display still sleeps; closing the lid still sleeps the Mac.")
    }

    private var awakeStatusShort: String {
        switch awake.mode {
        case .off: ""
        case .indefinite: "· on"
        case .until(let date): "· until \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func footerIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func showDashboard(_ section: DashboardSection) {
        dashboardNavigation.selection = section
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func adjustPinnedPeriod(_ direction: AccessibilityAdjustmentDirection) {
        let visiblePeriodCount: Int
        switch tab {
        case .today: visiblePeriodCount = 31
        case .week: visiblePeriodCount = 12
        case .month: visiblePeriodCount = 6
        }
        let periods = visibleRows(for: tab)
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
}
