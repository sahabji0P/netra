import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct NetraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore()
    @State private var awake = AwakeController()
    @State private var updates = UpdateChecker()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store, awake: awake, updates: updates)
        } label: {
            Image(systemName: awake.isAwake ? "eye.fill" : "eye")
            if let cost = store.snapshot?.currentRow(for: .today).cost, cost > 0 {
                Text(Format.cost(cost))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
