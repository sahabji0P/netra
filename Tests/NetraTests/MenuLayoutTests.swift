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

        // The menu-bar window proposes a tall size; the popover must still
        // hug its content rather than fill the proposal with blank space.
        let host = NSHostingController(rootView: root)
        let proposed = host.sizeThatFits(in: CGSize(width: MenuView.width, height: 10_000))
        XCTAssertEqual(proposed.height, size.height, accuracy: 1)
        // A minimum-size probe must not pick the cap-height scroll fallback.
        let minimum = host.sizeThatFits(in: .zero)
        XCTAssertEqual(minimum.height, size.height, accuracy: 1)
    }

    func testHeightCapHugsShortContentAndCapsTallContent() {
        func height(content: CGFloat, proposal: CGFloat) -> CGFloat {
            let view = HeightCappedLayout(maxHeight: 400) {
                ViewThatFits(in: .vertical) {
                    Color.clear.frame(width: 100, height: content)
                    ScrollView { Color.clear.frame(width: 100, height: content) }
                        .frame(height: 400)
                }
            }
            return NSHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: 100, height: proposal)).height
        }
        for proposal: CGFloat in [0, 50, 10_000] {
            XCTAssertEqual(height(content: 150, proposal: proposal), 150, accuracy: 1)
            XCTAssertEqual(height(content: 1_200, proposal: proposal), 400, accuracy: 1)
        }
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
