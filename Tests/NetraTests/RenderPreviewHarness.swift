import AppKit
import SwiftUI
import XCTest
@testable import Netra

/// Dev-only visual QA: renders the popover and dashboard with live local data
/// into PNGs. Runs only when NETRA_RENDER_DIR is set, e.g.
/// NETRA_RENDER_DIR=/tmp/netra-previews swift test --filter RenderPreviewHarness
@MainActor
final class RenderPreviewHarness: XCTestCase {
    func testRenderPreviews() async throws {
        guard let outputDir = ProcessInfo.processInfo.environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render UI previews")
        }
        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true
        )

        let suiteName = "NetraTests.RenderPreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        // Exercise the opt-in provider surfaces in the render.
        preferences.cursorUsageEnabled =
            ProcessInfo.processInfo.environment["NETRA_CURSOR_LIVE"] != nil
        let store = UsageStore(
            preferences: preferences,
            alerts: UsageAlertController(
                scheduler: RenderInertScheduler(),
                persistence: RenderInertPersistence()
            ),
            startsAutomatically: false
        )
        await store.refresh()
        XCTAssertNotNil(store.snapshot, "live ccusage scan should produce a snapshot")

        let menu = MenuView(
            store: store,
            awake: AwakeController(),
            updates: UpdateChecker(),
            preferences: preferences,
            dashboardNavigation: DashboardNavigation()
        )
        render(menu, name: "menu", outputDir: outputDir)

        let dashboard = DashboardUsageView(store: store)
            .frame(width: 1100, height: 1500)
        render(dashboard, name: "dashboard-usage", outputDir: outputDir)

        // A representative full-screen confetti + banner frame, to eyeball the
        // celebration look without waiting for a real reset.
        let celebration = ZStack {
            Color.black.opacity(0.15)
            ConfettiOverlay(trigger: 1, pieceCount: 220, previewElapsed: 0.9)
            VStack(spacing: 6) {
                Text("🎉").font(.system(size: 44))
                Text("Claude Code limit reset").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("fresh capacity").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(width: 900, height: 600)
        render(celebration, name: "desktop-confetti", outputDir: outputDir)
        // DashboardSettingsView is not rendered here: its notification-status
        // polling calls UNUserNotificationCenter, which throws outside a real
        // app bundle. Verify Settings in the running app instead.
    }

    private func render(_ view: some View, name: String, outputDir: String) {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let hosting = NSHostingView(
                rootView: view.background(Color(nsColor: .windowBackgroundColor))
            )
            hosting.appearance = NSAppearance(named: appearance)
            let size = hosting.fittingSize
            hosting.frame = CGRect(origin: .zero, size: size)

            // Give the view a window so materials and dynamic colors resolve.
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = hosting.appearance
            window.contentView = hosting
            window.layoutIfNeeded()

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                XCTFail("no bitmap rep for \(name)")
                continue
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                XCTFail("no png for \(name)")
                continue
            }
            let url = URL(fileURLWithPath: outputDir)
                .appendingPathComponent("\(name)-\(suffix).png")
            try? data.write(to: url)
        }
    }
}

private struct RenderInertScheduler: UsageNotificationScheduling {
    func authorizationState() async -> NotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func schedule(_ candidate: UsageAlertCandidate) async throws {}
}

private actor RenderInertPersistence: UsageAlertStatePersisting {
    func deliveredKeys() -> Set<String> { [] }
    func setDeliveredKeys(_ keys: Set<String>) {}
}
