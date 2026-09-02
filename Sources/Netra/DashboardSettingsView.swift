import AppKit
import SwiftUI

struct DashboardSettingsView: View {
    @Bindable var preferences: AppPreferences
    var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                menuBarSettings
                providerSettings
                limitSettings
                alertSettings
                generalSettings
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
        .onChange(of: preferences.claudeQuotaEnabled) { _, enabled in
            // Fetch (or drop) the real quota right away so the limits UI
            // reflects the choice without waiting for the next timer tick.
            if enabled { Task { await store.refresh() } }
        }
        .onChange(of: preferences.cursorUsageEnabled) { _, enabled in
            if enabled { Task { await store.refresh() } }
        }
        .task {
            while !Task.isCancelled {
                await preferences.refreshNotificationAuthorization()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Make Netra yours")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Choose what stays glanceable and when usage needs your attention.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuBarSettings: some View {
        DashboardPanel(title: "Menu bar", detail: "Controls the compact status surface") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Menu-bar label")
                        .font(.system(size: 12, weight: .medium))
                    Picker("Menu-bar label", selection: $preferences.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Text(preferences.menuBarDisplayMode.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Divider()
                settingsToggle(
                    "Provider limits",
                    detail: "Show current capacity and reset timing when a source is available.",
                    isOn: $preferences.showsLimits
                )
                settingsToggle(
                    "Provider breakdown",
                    detail: "Show each coding agent's share of cost and processed tokens.",
                    isOn: $preferences.showsProviderBreakdown
                )
                settingsToggle(
                    "Activity chart",
                    detail: "Show the compact recent-usage chart in the popover.",
                    isOn: $preferences.showsActivityChart
                )
                settingsToggle(
                    "Keep Awake",
                    detail: "Keep the sleep control available at the bottom of the popover.",
                    isOn: $preferences.showsKeepAwake
                )
            }
        }
    }

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

    private var providerSettings: some View {
        DashboardPanel(
            title: "Providers",
            detail: "The dashboard always shows everything"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose which providers appear in the menu-bar popover. Hidden providers are removed from its totals, chart, and list — the dashboard keeps showing them.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                if knownProviders.isEmpty {
                    Text("No provider usage detected yet. Run a coding agent once and refresh.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(knownProviders, id: \.self) { provider in
                        providerVisibilityRow(provider)
                        if provider != knownProviders.last {
                            Divider().padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func providerVisibilityRow(_ provider: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(AgentPalette.color(for: provider))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentPalette.displayName(provider))
                    .font(.system(size: 12, weight: .medium))
                if provider == "other" {
                    Text("Usage ccusage couldn't attribute to a specific agent")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(providerPeriodCost(provider))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Toggle(
                "Show \(AgentPalette.displayName(provider)) in the menu popover",
                isOn: Binding(
                    get: { preferences.isProviderVisibleInMenu(provider) },
                    set: { preferences.setProvider(provider, visibleInMenu: $0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
    }

    private func providerPeriodCost(_ provider: String) -> String {
        guard let row = store.snapshot?.currentRow(for: .month) else { return "" }
        if provider == "other" {
            guard let other = row.unattributed else { return "" }
            return "\(Format.cost(other.cost)) this month"
        }
        guard let stat = row.agentStat(provider) else { return "" }
        return "\(Format.cost(stat.cost)) this month"
    }

    private var limitSettings: some View {
        DashboardPanel(title: "Subscriptions", detail: "Where the plan-usage numbers come from") {
            VStack(alignment: .leading, spacing: 12) {
                settingsToggle(
                    "Live Claude limits",
                    detail: "Netra already shows the real limits Claude Code last cached — no setup needed. Turn this on to fetch fresh numbers straight from Anthropic on every refresh, using the sign-in Claude Code already has. macOS will ask once to allow Keychain access — choose “Always Allow”. The token is only ever sent to api.anthropic.com.",
                    isOn: $preferences.claudeQuotaEnabled
                )
                Label(
                    "Claude limits come from Anthropic (live, or via Claude Code's cache). Codex limits are read from its local session logs. Only when neither is available does Claude fall back to a clearly-labelled local estimate.",
                    systemImage: "gauge.with.needle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                Divider()
                settingsToggle(
                    "Cursor usage",
                    detail: "Cursor stores no usage data locally, so Netra reads your Cursor app login and queries Cursor's own usage API for your request quota. It uses the login Cursor already saved on this Mac and sends it only to Cursor. This relies on an undocumented endpoint that can change without notice.",
                    isOn: $preferences.cursorUsageEnabled
                )
            }
        }
    }

    private var alertSettings: some View {
        DashboardPanel(title: "Alerts", detail: "Evaluated after each successful local refresh") {
            VStack(alignment: .leading, spacing: 18) {
                notificationPermissionStatus
                alertToggle(
                    title: "Daily token alert",
                    detail: "Notify when combined processed tokens for today pass this amount.",
                    isOn: $preferences.dailyTokenAlertEnabled
                ) {
                    HStack(spacing: 6) {
                        TextField(
                            "Token threshold",
                            value: $preferences.dailyTokenAlertThreshold,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        Text("tokens")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
                Divider()
                alertToggle(
                    title: "Usage indicator alert",
                    detail: "Notify when a provider-reported limit (Codex, and Claude when real limits are enabled) or Claude's local historical-peak estimate reaches this level.",
                    isOn: $preferences.providerLimitAlertEnabled
                ) {
                    HStack(spacing: 4) {
                        TextField(
                            "Percent threshold",
                            value: $preferences.providerLimitAlertThreshold,
                            format: .number.precision(.fractionLength(0))
                        )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                }
                Label(
                    "Provider-reported percentages are real limits. Claude's local estimate is percent of your own historical peak—not subscription capacity. Netra alerts once per threshold crossing.",
                    systemImage: "bell.badge"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var notificationPermissionStatus: some View {
        switch preferences.notificationAuthorizationState {
        case .checking:
            Label("Checking notification permission…", systemImage: "bell")
                .foregroundStyle(.secondary)
        case .notDetermined:
            Label(
                "Notification permission has not been requested. Netra will ask after the next successful refresh while an alert is enabled.",
                systemImage: "bell.badge"
            )
            .foregroundStyle(.secondary)
        case .denied:
            HStack(alignment: .center, spacing: 12) {
                Label(
                    "Notifications are blocked, so enabled alerts cannot appear.",
                    systemImage: "bell.slash"
                )
                .foregroundStyle(.red)
                Spacer()
                Button("Open Notification Settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                    NSWorkspace.shared.open(url)
                }
            }
        case .allowed:
            Label("Notifications are allowed for Netra.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var generalSettings: some View {
        DashboardPanel(title: "General") {
            settingsToggle(
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
    }

    private func settingsToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    private func alertToggle<Accessory: View>(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Spacer()
            accessory()
                .disabled(!isOn.wrappedValue)
        }
    }
}
