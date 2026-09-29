import AppKit
import SwiftUI

/// The categorized settings pages. Every control writes through to
/// `AppPreferences` immediately, so the popover updates live.
struct DashboardSettingsView: View {
    var section: DashboardSection
    @Bindable var preferences: AppPreferences
    var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var websiteToken = ""

    var body: some View {
        DashboardPage {
            DashboardPageHeader(section: section)
            switch section {
            case .menuBar: menuBarPage
            case .limits: limitsPage
            case .providers: providersPage
            case .notifications: notificationsPage
            default: generalPage
            }
        }
        .navigationTitle(section.title)
        .onChange(of: preferences.claudeQuotaEnabled) { _, enabled in
            // Fetch the real quota right away so the choice shows without
            // waiting for the next timer tick; this user action is the one
            // place macOS may ask for Keychain access.
            if enabled { Task { await store.authorizeClaudeKeychain() } }
        }
        .onChange(of: preferences.cursorUsageEnabled) { _, enabled in
            if enabled { Task { await store.refresh() } }
        }
        .onChange(of: preferences.websitePublishEnabled) { _, enabled in
            Task {
                await store.websiteSettingsChanged()
                if enabled { await store.publishNow() }
            }
        }
        .onChange(of: preferences.websiteEndpoint) { _, _ in
            Task { await store.websiteSettingsChanged() }
        }
    }

    // MARK: Menu bar & popover

    private var menuBarPage: some View {
        Group {
            DashboardPanel(title: "Menu-bar label", detail: "Shown next to Netra's icon", symbol: "menubar.arrow.up.rectangle") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        menuBarModeCard(mode)
                    }
                }
                Text(preferences.menuBarDisplayMode.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            DashboardPanel(title: "Popover sections", detail: "Top to bottom", symbol: "rectangle.stack") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow("Subscription limits", detail: "Plan windows, resets, and pace for each provider.", isOn: $preferences.showsLimits)
                    Divider()
                    SettingsRow("Activity chart", detail: "Recent usage, stacked by provider. Click a bar to pin a period.", isOn: $preferences.showsActivityChart)
                    Divider()
                    SettingsRow("Provider breakdown", detail: "Cost and tokens per agent. Hover one to see its models.", isOn: $preferences.showsProviderBreakdown)
                    Divider()
                    SettingsRow("Keep Awake control", detail: "Block idle sleep for 1h, 4h, or until turned off.", isOn: $preferences.showsKeepAwake)
                    Divider()
                    SettingsRow(title: "Opens on", detail: "The usage period the popover shows first.") {
                        Picker("Opens on", selection: $preferences.defaultPeriod) {
                            ForEach(PeriodTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
            }
        }
    }

    private func menuBarModeCard(_ mode: MenuBarDisplayMode) -> some View {
        let selected = preferences.menuBarDisplayMode == mode
        return Button {
            preferences.menuBarDisplayMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    menuBarPreviewIcon(mode)
                    if let text = previewText(mode) {
                        Text(text)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                Text(mode.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func menuBarPreviewIcon(_ mode: MenuBarDisplayMode) -> some View {
        if mode == .limitBars {
            Image(nsImage: MenuBarIcon.bars(top: 0.35, bottom: 0.7, awake: false))
        } else {
            Image(systemName: "eye")
        }
    }

    private func previewText(_ mode: MenuBarDisplayMode) -> String? {
        let today = store.snapshot?.currentRow(for: .today)
        switch mode {
        case .iconOnly, .limitBars: return nil
        case .todayCost: return Format.cost(today?.cost ?? 12.5)
        case .todayTokens: return Format.tokens(today?.totalTokens ?? 4_200_000)
        case .highestProviderLimit:
            let highest = store.snapshot?
                .providerLimits(order: preferences.orderedLimitProviders)
                .compactMap(\.mostConstrained?.usedPercent).max()
            return "\(Int((highest ?? 54).rounded()))%"
        }
    }

    // MARK: Limits

    private var limitsPage: some View {
        Group {
            DashboardPanel(title: "Preview", detail: "Updates as you change options", symbol: "eye") {
                limitPreview
            }
            DashboardPanel(title: "Display", symbol: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow(title: "Bars show", detail: "Fill limit bars with what you've used, or with what's left.") {
                        Picker("Bars show", selection: $preferences.barsShowRemaining) {
                            Text("Used").tag(false)
                            Text("Remaining").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    Divider()
                    SettingsRow(title: "Reset times", detail: "A countdown, or the date and time the window resets.") {
                        Picker("Reset times", selection: $preferences.resetTimeStyle) {
                            ForEach(ResetTimeStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    Divider()
                    SettingsRow(
                        "Pace",
                        detail: "Compare each window with an even burn to its reset. A tick marks where even pace would be, and Netra warns when you'd run out early.",
                        isOn: $preferences.showsPace
                    )
                }
            }
            DashboardPanel(title: "Order", detail: "Top to bottom in the popover", symbol: "arrow.up.arrow.down") {
                VStack(spacing: 0) {
                    let order = preferences.orderedLimitProviders
                    ForEach(Array(order.enumerated()), id: \.element) { index, provider in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Circle().fill(AgentPalette.color(for: provider)).frame(width: 9, height: 9)
                            Text(AgentPalette.shortName(provider))
                                .font(.system(size: 12.5))
                            Spacer()
                            Button { preferences.moveLimitProvider(provider, by: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)
                            .help("Move up")
                            Button { preferences.moveLimitProvider(provider, by: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == order.count - 1)
                            .help("Move down")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 8)
                        if index < order.count - 1 { Divider() }
                    }
                }
            }
            DashboardPanel(title: "Claude source", detail: "Where Claude's numbers come from", symbol: "key") {
                SettingsRow(
                    "Live Claude limits",
                    detail: "Netra already shows the real limits Claude Code last cached — no setup needed. Turn this on to fetch fresh numbers from Anthropic on every refresh, using the sign-in Claude Code already has. macOS asks when you turn this on — choose \u{201C}Always Allow\u{201D}; background refreshes never prompt. The token stays in memory and is only sent to api.anthropic.com.",
                    isOn: $preferences.claudeQuotaEnabled
                )
                if preferences.claudeQuotaEnabled, store.claudeKeychainNeedsApproval {
                    HStack(spacing: 10) {
                        Label("Netra needs Keychain access to read Claude Code's sign-in.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow Keychain access") {
                            Task { await store.authorizeClaudeKeychain() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// A sample window rendered exactly as the popover will render it.
    private var limitPreview: some View {
        let sample = QuotaWindow(
            label: "weekly", usedPercent: 62,
            resetsAt: .now.addingTimeInterval(2 * 86400 + 4 * 3600),
            durationSeconds: 7 * 86400
        )
        return LimitWindowRow(
            window: sample, agent: "claude",
            showRemaining: preferences.barsShowRemaining,
            showsPace: preferences.showsPace,
            resetStyle: preferences.resetTimeStyle
        )
        .frame(maxWidth: 360)
    }

    // MARK: Providers

    /// Every provider Netra has seen usage for (plus any that are currently
    /// hidden, so they can always be re-enabled), ranked by recent cost.
    private var knownProviders: [String] {
        var ranked = store.snapshot?.agentNames.map { $0.lowercased() } ?? []
        if store.snapshot?.monthly.contains(where: { $0.unattributed != nil }) == true {
            ranked.append("other")
        }
        for hidden in preferences.hiddenMenuProviders.sorted() where !ranked.contains(hidden) {
            ranked.append(hidden)
        }
        return ranked
    }

    private var providersPage: some View {
        Group {
            DashboardPanel(title: "Account connections", detail: "Opt-in", symbol: "link") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(
                        title: "Cursor",
                        detail: "Reads the login Cursor saved on this Mac and asks Cursor's dashboard API for your limits and per-request usage history — every Cursor surface on every machine, priced at Cursor's API rates. Synced every 15 minutes into Netra's app-support folder. The login is only sent to cursor.com; the endpoints are undocumented and can change. Off means Netra reads nothing from Cursor."
                    ) {
                        HStack(spacing: 8) {
                            Circle().fill(AgentPalette.color(for: "cursor")).frame(width: 9, height: 9)
                            SettingsSwitch(title: "Cursor usage", isOn: $preferences.cursorUsageEnabled)
                        }
                    }
                    Divider()
                    Label("Claude and Codex need no setup: Netra reads Claude Code's cached limits and asks the Codex CLI for live limits.", systemImage: "checkmark.seal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            DashboardPanel(title: "Shown in the popover", detail: "The dashboard always shows everything", symbol: "eye") {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Hidden providers are removed from the popover's totals, chart, list, and limit cards, so its numbers stay consistent.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                    if knownProviders.isEmpty {
                        Text("No provider usage detected yet. Run a coding agent once and refresh.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(knownProviders.enumerated()), id: \.element) { index, provider in
                        providerVisibilityRow(provider)
                            .padding(.vertical, 8)
                        if index < knownProviders.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func providerVisibilityRow(_ provider: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(AgentPalette.color(for: provider))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentPalette.displayName(provider))
                    .font(.system(size: 12.5, weight: .medium))
                if provider == "other" {
                    Text("Usage ccusage couldn't attribute to a specific agent")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(providerMonthCost(provider))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            SettingsSwitch(
                title: "Show \(AgentPalette.displayName(provider)) in the menu popover",
                isOn: Binding(
                    get: { preferences.isProviderVisibleInMenu(provider) },
                    set: { preferences.setProvider(provider, visibleInMenu: $0) }
                )
            )
            .controlSize(.small)
        }
    }

    private func providerMonthCost(_ provider: String) -> String {
        guard let row = store.snapshot?.currentRow(for: .month) else { return "" }
        let stat = provider == "other" ? row.unattributed : row.agentStat(provider)
        guard let stat else { return "" }
        return "\(Format.providerCost(provider, cost: stat.cost, tokens: stat.totalTokens)) this month"
    }

    // MARK: Notifications

    private var notificationsPage: some View {
        Group {
            DashboardPanel(title: "Permission", symbol: "bell") {
                notificationPermissionStatus
                    .font(.system(size: 11.5))
            }
            DashboardPanel(title: "Alerts", detail: "Checked after every successful refresh", symbol: "bell.badge") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Limit alert",
                        detail: "Notify when any provider-reported window (Claude, Codex, Cursor) — or Claude's local historical-peak estimate — reaches this level. Once per crossing."
                    ) {
                        HStack(spacing: 8) {
                            TextField("Percent", value: $preferences.providerLimitAlertThreshold, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                                .disabled(!preferences.providerLimitAlertEnabled)
                            Text("%").foregroundStyle(.secondary)
                            SettingsSwitch(title: "Limit alert", isOn: $preferences.providerLimitAlertEnabled)
                        }
                    }
                    Divider()
                    SettingsRow(
                        title: "Daily token alert",
                        detail: "Notify when today's processed tokens across every provider pass this amount."
                    ) {
                        HStack(spacing: 8) {
                            TextField("Tokens", value: $preferences.dailyTokenAlertThreshold, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                                .disabled(!preferences.dailyTokenAlertEnabled)
                            Text("tokens").foregroundStyle(.secondary)
                            SettingsSwitch(title: "Daily token alert", isOn: $preferences.dailyTokenAlertEnabled)
                        }
                    }
                }
            }
        }
        .task {
            // Permission can change in System Settings while this page is open.
            while !Task.isCancelled {
                await preferences.refreshNotificationAuthorization()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var notificationPermissionStatus: some View {
        switch preferences.notificationAuthorizationState {
        case .checking:
            Label("Checking notification permission…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .notDetermined:
            Label("Netra will ask for permission after the next refresh while an alert is on.", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .denied:
            HStack(spacing: 12) {
                Label("Notifications are blocked, so alerts can't appear.", systemImage: "bell.slash")
                    .foregroundStyle(.red)
                Spacer()
                Button("Open Notification Settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        case .allowed:
            Label("Notifications are allowed for Netra.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    // MARK: General

    private var generalPage: some View {
        Group {
            DashboardPanel(title: "Startup", symbol: "power") {
                SettingsRow(
                    "Launch at login",
                    detail: LaunchAtLogin.isAvailable
                        ? "Start Netra automatically after you sign in to this Mac."
                        : "Available when Netra runs from its signed app bundle.",
                    isOn: $launchAtLogin
                )
                .disabled(!LaunchAtLogin.isAvailable)
                .onChange(of: launchAtLogin) { _, enabled in
                    LaunchAtLogin.set(enabled)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }
            DashboardPanel(title: "Celebrations", symbol: "party.popper") {
                SettingsRow(
                    "Celebrate limit resets",
                    detail: "Full-screen confetti the moment a subscription window resets and fresh capacity is back. Click-through; never steals focus.",
                    isOn: $preferences.confettiOnReset
                )
            }
            websitePanel
            DashboardPanel(title: "About your data", symbol: "lock.shield") {
                Label("Usage is calculated on this Mac from coding-agent logs by a pinned ccusage build. Limits come from each provider (Anthropic via Claude Code, OpenAI via the Codex CLI, and Cursor when connected). Transcript contents never leave this Mac.", systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Website

    private var websitePanel: some View {
        DashboardPanel(title: "Website", detail: "Opt-in", symbol: "globe") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(
                    "Publish usage to a website",
                    detail: "After refreshes, send daily token and cost totals per agent and model — never projects, paths, prompts, or accounts — at most every 5 minutes. The same feed is always saved to usage-feed.json in Netra's app-support folder.",
                    isOn: $preferences.websitePublishEnabled
                )
                Divider()
                SettingsRow(title: "Endpoint", detail: endpointHint) {
                    TextField("https://example.com/api/usage", text: $preferences.websiteEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                Divider()
                SettingsRow(
                    title: "Token",
                    detail: store.websiteTokenError ?? (store.websiteTokenSaved
                        ? "Saved in Netra's Keychain item. Enter a new one to replace it."
                        : "Stored in Netra's own Keychain item; only sent to the endpoint.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(store.websiteTokenSaved ? "••••••••" : "Token", text: $websiteToken)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit(saveWebsiteToken)
                        Button("Save", action: saveWebsiteToken)
                            .disabled(websiteToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear") { Task { await store.clearWebsiteToken() } }
                            .disabled(!store.websiteTokenSaved)
                    }
                    .controlSize(.small)
                }
                Divider()
                HStack(spacing: 10) {
                    websiteStatus
                        .font(.system(size: 11))
                    Spacer()
                    if store.isPublishing { ProgressView().controlSize(.small) }
                    Button("Publish now") { Task { await store.publishNow() } }
                        .controlSize(.small)
                        .disabled(!canPublish || store.isPublishing)
                }
            }
        }
        .task { await store.loadWebsiteStatus() }
    }

    private var endpointHint: String {
        let text = preferences.websiteEndpoint.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, preferences.websiteEndpointURL == nil {
            return "Use an https:// address (http:// only for localhost)."
        }
        return "The site's usage ingest URL."
    }

    private var canPublish: Bool {
        preferences.websitePublishEnabled && preferences.websiteEndpointURL != nil && store.websiteTokenSaved
    }

    private func saveWebsiteToken() {
        let token = websiteToken
        websiteToken = ""
        Task { await store.saveWebsiteToken(token) }
    }

    @ViewBuilder
    private var websiteStatus: some View {
        let state = store.publishState
        if !preferences.websitePublishEnabled {
            Label("Publishing is off.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        } else if let error = state?.lastError {
            Label(error, systemImage: state?.isStopped == true ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(state?.isStopped == true ? .red : .orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let last = state?.lastSuccessAt {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Label("Last published \(Format.age(since: last, now: context.date)).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label("Not published yet.", systemImage: "clock")
                .foregroundStyle(.secondary)
        }
    }
}
