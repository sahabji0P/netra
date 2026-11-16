import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
    }

    /// The window is a separate app that can only ask Netra to act, so it
    /// closes with Netra rather than staying open and unanswered.
    func applicationWillTerminate(_ notification: Notification) {
        DashboardLauncher.shared.closeWindow()
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
    @State private var updates: UpdateChecker
    @State private var desktopConfetti = DesktopConfetti()
    @State private var accounts: AccountStore
    @State private var awake: AwakeController
    @State private var island: IslandCoordinator
    @State private var bridge: DashboardBridge

    init() {
        let preferences = AppPreferences()
        let confetti = DesktopConfetti()
        let accounts = AccountStore()
        let awake = AwakeController()
        let store = UsageStore(preferences: preferences, accounts: accounts)
        let updates = UpdateChecker()
        let island = IslandCoordinator(
            store: store, preferences: preferences, accounts: accounts,
            awake: awake
        )
        // A switch refreshes limits at once, for the account now signed in.
        accounts.onSwitch = { [weak store, weak island] provider in
            island?.accountSwitched(provider)
            await store?.accountDidSwitch(provider)
        }
        // Fire full-screen confetti the moment a reset is detected, unless the
        // user has turned it off; the island shows the reset either way.
        store.celebrationHandler = { [weak preferences, weak confetti, weak island] celebration in
            island?.resetDetected(celebration)
            guard preferences?.confettiOnReset == true else { return }
            confetti?.play(title: celebration.title)
        }
        _preferences = State(initialValue: preferences)
        _store = State(initialValue: store)
        _updates = State(initialValue: updates)
        _desktopConfetti = State(initialValue: confetti)
        _accounts = State(initialValue: accounts)
        _awake = State(initialValue: awake)
        _island = State(initialValue: island)
        let bridge = DashboardBridge(
            preferences: preferences, store: store, accounts: accounts, updates: updates
        )
        DashboardLauncher.shared.bridge = bridge
        _bridge = State(initialValue: bridge)
        // The panel needs a finished launch; the main queue runs after it.
        DispatchQueue.main.async {
            island.start()
            bridge.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                store: store,
                awake: awake,
                updates: updates,
                preferences: preferences,
                accounts: accounts
            )
        } label: {
            let label = menuBarLabel
            Image(nsImage: MenuBarLabelRenderer.image(label))
                .accessibilityLabel(label.accessibilityDescription)
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu-bar label for the current snapshot and label settings.
    private var menuBarLabel: MenuBarLabelModel {
        MenuBarLabelModel.make(
            settings: preferences.menuBarLabelSettings,
            snapshot: store.snapshot,
            awake: awake.isAwake
        )
    }
}
