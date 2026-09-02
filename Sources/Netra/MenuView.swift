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
    /// hero number, chart, and provider list all agree with each other.
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
           let row = visibleRows(for: tab).first(where: { $0.period == hoveredPeriod }) {
            return row
        }
        return displayedRow
    }

    private var hasUsageData: Bool {
        guard let snapshot = store.snapshot else { return false }
        return (snapshot.daily + snapshot.weekly + snapshot.monthly).contains(where: rowHasUsage)
    }

    private var hasVisibleLimits: Bool {
        !limitProviders.isEmpty
    }

    /// Providers with a live limit to show. Only Claude (real quota or local
    /// estimate) and Codex (session-reported) have limit sources today; idle
    /// providers and providers hidden from the menu render nothing.
    var limitProviders: [String] {
        var providers: [String] = []
        if preferences.isProviderVisibleInMenu("claude"), hasClaudeLimitData {
            providers.append("claude")
        }
        if preferences.isProviderVisibleInMenu("codex"), hasCodexLimitData {
            providers.append("codex")
        }
        if preferences.isProviderVisibleInMenu("cursor"), hasCursorLimitData {
            providers.append("cursor")
        }
        return providers
    }

    private var hasCursorLimitData: Bool {
        store.snapshot?.cursorQuota?.activeWindows().isEmpty == false
    }

    private var hasClaudeLimitData: Bool {
        if store.snapshot?.claudeQuota?.activeWindows().isEmpty == false { return true }
        return store.snapshot?.activeBlock.map { $0.end > .now } == true
    }

    private var hasCodexLimitData: Bool {
        store.snapshot?.codexQuota?.activeWindows().isEmpty == false
    }

    var providerSummaries: [ProviderSummary] {
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
        if let other = displayedRow.unattributed {
            summaries.append(ProviderSummary(
                name: other.name,
                cost: other.cost,
                totalTokens: other.totalTokens,
                inputTokens: other.inputTokens,
                outputTokens: other.outputTokens,
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

    private var activityProviderNames: String {
        let rows = visibleRows(for: tab)
        var names = Set(rows.flatMap { $0.agents.map(\.name) })
        if rows.contains(where: { $0.unattributed != nil }) {
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
        ScrollView(.vertical) {
            menuContent
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340, height: preferredPopoverHeight)
        .onAppear { store.refreshIfStale() }
    }

    private var preferredPopoverHeight: CGFloat {
        // Header + period picker + hero summary + dashboard actions + footer.
        var height: CGFloat = 230
        if !hasUsageData {
            height += 70
        } else {
            if preferences.showsLimits && hasVisibleLimits { height += limitsSectionHeight }
            if preferences.showsActivityChart { height += 90 }
            if preferences.showsProviderBreakdown {
                height += 28 + CGFloat(min(providerSummaries.count, 4)) * 33
                if hiddenProviderCount > 0 || providerSummaries.count > 4 { height += 16 }
            }
        }
        if preferences.showsKeepAwake { height += 38 }
        if updates.availableVersion != nil { height += 22 }
        return min(max(height, 340), maximumPopoverHeight)
    }

    /// Mirrors the limits layout: a provider heading plus one meter row per
    /// window, and a caption line under the local-estimate block.
    private var limitsSectionHeight: CGFloat {
        var height: CGFloat = 36 // section header + vertical padding
        for provider in limitProviders {
            switch provider {
            case "claude":
                if let windows = store.snapshot?.claudeQuota?.activeWindows(), !windows.isEmpty {
                    height += 24 + CGFloat(windows.count) * 28
                } else {
                    height += 24 + 28 + 14 // estimate block includes a caption line
                }
            case "codex":
                let windows = store.snapshot?.codexQuota?.activeWindows().count ?? 1
                height += 24 + CGFloat(max(windows, 1)) * 28
            case "cursor":
                let windows = store.snapshot?.cursorQuota?.activeWindows().count ?? 1
                height += 24 + CGFloat(max(windows, 1)) * 28
            default:
                height += 52
            }
        }
        return height
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

    var periodCaption: String {
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
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Limits", detail: limitsSectionDetail)
            ForEach(limitProviders, id: \.self) { agent in
                limitsContent(for: agent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var limitsSectionDetail: String {
        store.snapshot?.claudeQuota == nil && limitProviders.contains("claude")
            ? "Estimates are labelled" : "Provider reported"
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
                Text(hiddenProviderCount > 0
                     ? "All providers with usage are hidden — adjust in Settings"
                     : "No provider usage in this period")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 3)
            } else {
                providerSectionFootnote(overflow: providerSummaries.count - providers.count)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func providerSectionFootnote(overflow: Int) -> some View {
        HStack(spacing: 6) {
            if overflow > 0 {
                Button("View \(overflow) more in Usage") {
                    showDashboard(.usage)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if hiddenProviderCount > 0 {
                Button("\(hiddenProviderCount) hidden") {
                    showDashboard(.settings)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .help("Some providers are hidden from this menu. Manage them in Settings.")
            }
        }
        .padding(.top, 2)
    }

    private func providerRow(_ provider: ProviderSummary) -> some View {
        let share = displayedRow.cost > 0 ? provider.cost / displayedRow.cost : 0
        return VStack(spacing: 3) {
            ViewThatFits(in: .horizontal) {
                providerMetrics(provider, share: share)
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
                            .fill(AgentPalette.color(for: provider.name).opacity(0.8))
                            .frame(width: geometry.size.width * max(0, min(share, 1)))
                    }
            }
            .frame(height: 3)
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

    private func providerMetrics(_ provider: ProviderSummary, share: Double) -> some View {
        HStack(spacing: 7) {
            providerIdentity(provider)
            Spacer()
            Text((share).formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
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

    func sectionHeader(_ title: String, detail: String) -> some View {
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
                Text("Run a coding agent (Claude Code, Codex, Gemini CLI, …) once, then refresh.")
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
        HStack(spacing: 8) {
            Label {
                Text("Keep awake")
                    .font(.system(size: 11.5, weight: .medium))
            } icon: {
                Image(systemName: awake.isAwake ? "eye.fill" : "eye")
                    .font(.system(size: 11))
            }
            .help("Blocks idle sleep so agents keep running. The display still sleeps; closing the lid still sleeps the Mac.")
            Spacer()
            if awake.isAwake {
                Text(awakeStatusShort)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.accentColor)
            } else {
                HStack(spacing: 4) {
                    durationButton("1h") { awake.hold(for: 3600) }
                    durationButton("4h") { awake.hold(for: 4 * 3600) }
                }
            }
            Toggle("Keep awake", isOn: Binding(
                get: { awake.isAwake },
                set: { awake.setAwake($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var awakeStatusShort: String {
        switch awake.mode {
        case .off: ""
        case .indefinite: "until turned off"
        case .until(let date): "until \(date.formatted(date: .omitted, time: .shortened))"
        }
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
