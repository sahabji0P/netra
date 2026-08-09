import AppKit
import SwiftUI

struct DashboardSettingsView: View {
    @Bindable var preferences: AppPreferences
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                menuBarSettings
                alertSettings
                generalSettings
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
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
                    detail: "Notify when Codex's provider-reported usage or Claude's local historical-peak estimate reaches this level.",
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
                    "Codex percentages are provider-reported limits. Claude is percent of your local historical peak—not subscription capacity. Netra alerts once per threshold crossing.",
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
