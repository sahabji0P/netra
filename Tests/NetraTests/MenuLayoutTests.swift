import AppKit
import SwiftUI
import XCTest
@testable import Netra

@MainActor
final class MenuLayoutTests: XCTestCase {
    func testPopoverRootHasUsableIntrinsicSize() {
        let suiteName = "NetraTests.MenuLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        let alerts = UsageAlertController(
            scheduler: InertNotificationScheduler(),
            persistence: InertAlertStatePersistence()
        )
        let root = MenuView(
            store: UsageStore(
                preferences: preferences,
                alerts: alerts,
                startsAutomatically: false
            ),
            awake: AwakeController(),
            updates: UpdateChecker(),
            preferences: preferences,
            dashboardNavigation: DashboardNavigation()
        )
        let hostingView = NSHostingView(rootView: root)
        let size = hostingView.fittingSize

        XCTAssertEqual(size.width, MenuView.width, accuracy: 1)
        // The popover takes its content's natural height (no forced minimum,
        // which left blank space below short content); it must not collapse.
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThanOrEqual(size.height, NSScreen.main?.visibleFrame.height ?? 900)
    }
}

private struct InertNotificationScheduler: UsageNotificationScheduling {
    func authorizationState() async -> NotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func schedule(_ candidate: UsageAlertCandidate) async throws {}
}

private actor InertAlertStatePersistence: UsageAlertStatePersisting {
    func deliveredKeys() -> Set<String> { [] }
    func setDeliveredKeys(_ keys: Set<String>) {}
}
