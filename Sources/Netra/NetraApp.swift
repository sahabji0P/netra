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
    @State private var desktopConfetti = DesktopConfetti()
    @State private var accounts: AccountStore

    init() {
        let preferences = AppPreferences()
        let confetti = DesktopConfetti()
        let accounts = AccountStore()
        let store = UsageStore(preferences: preferences, accounts: accounts)
        // A switch refreshes limits at once, for the account now signed in.
        accounts.onSwitch = { [weak store] provider in
            await store?.accountDidSwitch(provider)
        }
        // Fire full-screen confetti the moment a reset is detected, unless the
        // user has turned it off.
        store.celebrationHandler = { [weak preferences, weak confetti] celebration in
            guard preferences?.confettiOnReset == true else { return }
            confetti?.play(title: celebration.title)
        }
        _preferences = State(initialValue: preferences)
        _store = State(initialValue: store)
        _desktopConfetti = State(initialValue: confetti)
        _accounts = State(initialValue: accounts)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                store: store,
                awake: awake,
                updates: updates,
                preferences: preferences,
                dashboardNavigation: dashboardNavigation,
                accounts: accounts
            )
        } label: {
            if preferences.menuBarDisplayMode == .limitBars, let bars = menuBarLimitBars {
                Image(nsImage: MenuBarIcon.bars(
                    top: bars.top, bottom: bars.bottom, awake: awake.isAwake
                ))
            } else {
                Image(systemName: awake.isAwake ? "eye.fill" : "eye")
            }
            if let status = menuBarStatus {
                Text(status)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Netra", id: "dashboard") {
            DashboardView(
                store: store,
                preferences: preferences,
                navigation: dashboardNavigation,
                accounts: accounts
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
            let cost = snapshot.currentRow(for: .today)
                .filtered(hidingProviders: preferences.hiddenMenuProviders).cost
            return cost > 0 ? Format.cost(cost) : nil
        case .todayTokens:
            let tokens = snapshot.currentRow(for: .today)
                .filtered(hidingProviders: preferences.hiddenMenuProviders).totalTokens
            return tokens > 0 ? Format.tokens(tokens) : nil
        case .highestProviderLimit:
            let highest = limitsForMenuBar(snapshot).compactMap(\.mostConstrained?.usedPercent).max()
            return highest.map { "\(Int(min($0, 999).rounded()))%" }
        case .limitBars:
            return nil
        }
    }

    /// Provider limits the menu bar may summarize; the Claude local estimate
    /// only stands in when no real quota exists anywhere.
    private func limitsForMenuBar(_ snapshot: UsageSnapshot) -> [ProviderLimits] {
        let all = snapshot.providerLimits(order: preferences.orderedLimitProviders)
            .filter { preferences.isProviderVisibleInMenu($0.agent) }
        let real = all.filter { !$0.isEstimate }
        return real.isEmpty ? all : real
    }

    /// Fill fractions (0...1) for the provider closest to a limit, honouring
    /// the used/remaining preference.
    private var menuBarLimitBars: (top: Double, bottom: Double?)? {
        guard let snapshot = store.snapshot,
              let limits = limitsForMenuBar(snapshot).max(by: {
                  ($0.mostConstrained?.usedPercent ?? 0) < ($1.mostConstrained?.usedPercent ?? 0)
              }),
              let windows = limits.iconWindows else { return nil }
        func fill(_ window: QuotaWindow) -> Double {
            let used = min(max(window.usedPercent, 0), 100) / 100
            return preferences.barsShowRemaining ? 1 - used : used
        }
        return (fill(windows.top), windows.bottom.map(fill))
    }
}

/// Template images for the menu-bar label, drawn so they invert correctly
/// in light and dark menu bars.
enum MenuBarIcon {
    static func bars(top: Double, bottom: Double?, awake: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let trackWidth: CGFloat = awake ? 14 : 18
            let x: CGFloat = 1
            func bar(y: CGFloat, height: CGFloat, fraction: Double) {
                let track = NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: trackWidth, height: height),
                    xRadius: height / 2, yRadius: height / 2
                )
                NSColor.black.withAlphaComponent(0.3).setFill()
                track.fill()
                let width = max(fraction > 0 ? height : 0, trackWidth * CGFloat(min(max(fraction, 0), 1)))
                let fill = NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: width, height: height),
                    xRadius: height / 2, yRadius: height / 2
                )
                NSColor.black.setFill()
                fill.fill()
            }
            if let bottom {
                bar(y: 3, height: 4.5, fraction: top)
                bar(y: 9.5, height: 3.5, fraction: bottom)
            } else {
                bar(y: 5.5, height: 5, fraction: top)
            }
            if awake {
                // A small dot marks Keep Awake without a second icon.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16.5, y: 6, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage limits"
        return image
    }
}
