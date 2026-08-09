import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct NetraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var preferences: AppPreferences
    @State private var store: UsageStore
    @State private var awake = AwakeController()
    @State private var updates = UpdateChecker()
    @State private var dashboardNavigation = DashboardNavigation()

    init() {
        let preferences = AppPreferences()
        _preferences = State(initialValue: preferences)
        _store = State(initialValue: UsageStore(preferences: preferences))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                store: store,
                awake: awake,
                updates: updates,
                preferences: preferences,
                dashboardNavigation: dashboardNavigation
            )
        } label: {
            Image(systemName: awake.isAwake ? "eye.fill" : "eye")
            if let status = menuBarStatus {
                Text(status)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Netra", id: "dashboard") {
            DashboardView(
                store: store,
                preferences: preferences,
                navigation: dashboardNavigation
            )
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
    }

    private var menuBarStatus: String? {
        guard let snapshot = store.snapshot else { return nil }
        switch preferences.menuBarDisplayMode {
        case .iconOnly:
            return nil
        case .todayCost:
            let cost = snapshot.currentRow(for: .today).cost
            return cost > 0 ? Format.cost(cost) : nil
        case .todayTokens:
            let tokens = snapshot.currentRow(for: .today).totalTokens
            return tokens > 0 ? Format.tokens(tokens) : nil
        case .highestProviderLimit:
            let codex = snapshot.codexQuota?.activeWindows()
                .map(\.usedPercent)
                .max()
            let claudeEstimate = snapshot.activeBlock
                .flatMap { $0.end > .now ? $0.percentUsed : nil }
            let highest = [codex, claudeEstimate].compactMap { $0 }.max()
            return highest.map { "\(Int($0.rounded()))%" }
        }
    }
}
