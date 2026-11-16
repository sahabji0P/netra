import XCTest
@testable import Netra

/// The customizable menu-bar label: upgrading from the single display mode,
/// and what the label shows for a snapshot.
@MainActor
final class MenuBarLabelTests: XCTestCase {
    private let suiteName = "NetraTests.MenuBarLabel"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func setUp() {
        super.setUp()
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Migration

    func testEveryOldModeKeepsWhatTheUserSaw() {
        let expected: [(MenuBarDisplayMode, MenuBarIconKind, [MenuBarItem])] = [
            (.iconOnly, .eye, []),
            (.limitBars, .bars, []),
            (.todayCost, .eye, [.todayCost]),
            (.todayTokens, .eye, [.todayTokens]),
            (.highestProviderLimit, .eye, [.limitPercent]),
        ]
        for (mode, icon, items) in expected {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(mode.rawValue, forKey: "preferences.menuBarDisplayMode")
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.menuBarIcon, icon, mode.rawValue)
            XCTAssertEqual(preferences.menuBarItems, items, mode.rawValue)
            XCTAssertEqual(preferences.menuBarStyle, .plain)
            XCTAssertEqual(preferences.menuBarTint, .mono)
            XCTAssertEqual(preferences.menuBarLimitSource, "closest")
            XCTAssertFalse(preferences.menuBarCompact)
            // Nothing is written until the user changes the label, so the
            // old key keeps deciding on the next launch too.
            XCTAssertNil(defaults.object(forKey: "preferences.menuBar.icon"))
            XCTAssertNil(defaults.object(forKey: "preferences.menuBar.items"))
        }
    }

    func testAFreshInstallShowsTodaysCost() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.menuBarIcon, .eye)
        XCTAssertEqual(preferences.menuBarItems, [.todayCost])
    }

    func testNewKeysWinOverTheOldModeOnceWritten() {
        defaults.set("limitBars", forKey: "preferences.menuBarDisplayMode")
        let first = AppPreferences(defaults: defaults)
        first.menuBarIcon = .ring
        first.menuBarItems = []
        first.menuBarStyle = .pill
        first.menuBarTint = .status
        first.menuBarLimitSource = "codex"
        first.menuBarCompact = true

        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.menuBarIcon, .ring)
        XCTAssertEqual(restored.menuBarItems, [], "an empty list is a choice, not a missing key")
        XCTAssertEqual(restored.menuBarStyle, .pill)
        XCTAssertEqual(restored.menuBarTint, .status)
        XCTAssertEqual(restored.menuBarLimitSource, "codex")
        XCTAssertTrue(restored.menuBarCompact)
    }

    func testStoredJunkFallsBackSafely() {
        defaults.set("todayTokens", forKey: "preferences.menuBarDisplayMode")
        defaults.set("star", forKey: "preferences.menuBar.icon")
        defaults.set(["todayCost", "bogus", "todayCost", "weekCost"], forKey: "preferences.menuBar.items")
        defaults.set("gemini", forKey: "preferences.menuBar.limitSource")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.menuBarIcon, .eye)
        XCTAssertEqual(preferences.menuBarItems, [.todayCost, .weekCost])
        XCTAssertEqual(preferences.menuBarLimitSource, "closest")
    }

    // MARK: Model

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func model(_ settings: MenuBarLabelSettings, snapshot: UsageSnapshot? = nil, awake: Bool = false) -> MenuBarLabelModel {
        MenuBarLabelModel.make(
            settings: settings,
            snapshot: snapshot ?? MenuBarLabelPreview.sampleSnapshot(now: now, calendar: utc),
            awake: awake, now: now
        )
    }

    func testItemsShowInOrder() {
        var settings = MenuBarLabelSettings()
        settings.items = [.limitPercent, .resetCountdown, .todayCost, .sessionPercent, .weeklyPercent, .todayTokens]
        // Codex's weekly 82% is the closest to a limit in the sample.
        let label = model(settings)
        // Codex has no session window, so that item is left out.
        XCTAssertEqual(label.texts, ["82%", "4d", "$12.48", "7d 82%", Format.tokens(4_200_000)])
        XCTAssertEqual(label.icon, .eye)
    }

    func testAChosenLimitSourceDrivesTheLimitItems() {
        var settings = MenuBarLabelSettings()
        settings.limitSource = "claude"
        settings.items = [.sessionPercent, .weeklyPercent, .limitPercent, .resetCountdown]
        XCTAssertEqual(model(settings).texts, ["5h 38%", "7d 64%", "64%", "3d"])
        settings.barsShowRemaining = true
        XCTAssertEqual(model(settings).texts, ["5h 62%", "7d 36%", "36%", "3d"])
    }

    func testIconsFollowTheLimitSource() {
        var settings = MenuBarLabelSettings()
        settings.limitSource = "claude"
        settings.icon = .bars
        XCTAssertEqual(model(settings).icon, .bars(top: 0.38, bottom: 0.64))
        settings.icon = .ring
        XCTAssertEqual(model(settings).icon, .ring(0.64))
        // No limits for the source: the eye stands in.
        settings.limitSource = "cursor"
        XCTAssertEqual(model(settings).icon, .eye)
    }

    func testTheLabelIsNeverEmpty() {
        var settings = MenuBarLabelSettings()
        settings.icon = .none
        settings.items = [.todayCost]
        let empty = UsageSnapshot(fetchedAt: now, daily: [], activeBlock: nil, codexQuota: nil, claudeQuota: nil, calendar: utc)
        let label = model(settings, snapshot: empty)
        XCTAssertEqual(label.texts, [], "a zero cost is left out, as before")
        XCTAssertEqual(label.icon, .eye)
    }

    func testTintChoosesTheColor() {
        var settings = MenuBarLabelSettings()
        XCTAssertTrue(model(settings).isTemplate)
        settings.tint = .provider
        XCTAssertEqual(model(settings).color, .agent("codex"))
        settings.tint = .status
        XCTAssertEqual(model(settings).color, .status(usedPercent: 82))
        settings.limitSource = "cursor"
        XCTAssertEqual(model(settings).color, .mono, "no limits: follow the menu bar")
    }

    func testHiddenProvidersAreNotTheClosestSource() {
        var settings = MenuBarLabelSettings()
        settings.items = [.limitPercent]
        settings.hiddenProviders = ["codex"]
        XCTAssertEqual(model(settings).texts, ["64%"])
    }

    func testRendererProducesAnImageForEveryStyle() {
        for style in MenuBarStyle.allCases {
            for tint in MenuBarTint.allCases {
                var settings = MenuBarLabelSettings()
                settings.style = style
                settings.tint = tint
                settings.items = [.limitPercent, .todayCost]
                let label = model(settings, awake: true)
                let image = MenuBarLabelRenderer.image(label)
                XCTAssertEqual(image.size.height, MenuBarLabelRenderer.height)
                XCTAssertGreaterThan(image.size.width, 40)
                XCTAssertEqual(image.isTemplate, tint == .mono)
                XCTAssertTrue(image.accessibilityDescription?.contains("Keep Awake") == true)
            }
        }
    }
}
