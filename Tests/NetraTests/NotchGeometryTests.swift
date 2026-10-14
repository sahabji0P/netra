import XCTest
@testable import Netra

final class NotchGeometryTests: XCTestCase {
    /// A 14" MacBook Pro at its default scaled resolution.
    private let notched = ScreenDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTop: 32,
        leftAuxiliaryWidth: 662,
        rightAuxiliaryWidth: 662,
        menuBarHeight: 32,
        isPrimary: false
    )
    private let external = ScreenDescriptor(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        safeAreaTop: 0,
        menuBarHeight: 24,
        isPrimary: true
    )
    private let sizes = IslandSizes.standard

    func testNotchRectComesFromAuxiliaryWidths() {
        let layout = NotchGeometry.layout(for: notched)
        XCTAssertTrue(layout.hasNotch)
        XCTAssertEqual(layout.notch, CGRect(x: 662, y: 950, width: 188, height: 32))
    }

    func testScreenWithoutNotchFallsBackToCenteredPill() {
        let layout = NotchGeometry.layout(for: external)
        XCTAssertFalse(layout.hasNotch)
        XCTAssertEqual(layout.notch, CGRect(x: -960, y: 1056, width: 0, height: 24))
        let resting = NotchGeometry.islandFrame(.resting, layout: layout, sizes: sizes)
        XCTAssertEqual(resting.midX, -960)
        XCTAssertEqual(resting.maxY, 1080)
        XCTAssertEqual(resting.size, CGSize(width: 2 * sizes.wingWidth, height: 24))
    }

    func testAutoHiddenMenuBarUsesFallbackHeight() {
        var screen = external
        screen.menuBarHeight = 0
        XCTAssertEqual(NotchGeometry.layout(for: screen).notch.height, NotchGeometry.fallbackBarHeight)
    }

    func testAuxiliaryAreasWithoutSafeAreaAreNotANotch() {
        var screen = notched
        screen.safeAreaTop = 0
        XCTAssertFalse(screen.hasNotch)
        screen = notched
        screen.rightAuxiliaryWidth = nil
        XCTAssertFalse(screen.hasNotch)
    }

    func testPreferredScreenIsNotchedThenMainThenFirst() {
        XCTAssertEqual(NotchGeometry.preferredScreenIndex([external, notched]), 1)
        var plain = external
        plain.isPrimary = false
        XCTAssertEqual(NotchGeometry.preferredScreenIndex([plain, external]), 1)
        XCTAssertEqual(NotchGeometry.preferredScreenIndex([plain]), 0)
        XCTAssertNil(NotchGeometry.preferredScreenIndex([]))
    }

    func testModeFramesShareTopAndCenterAndNest() {
        for screen in [notched, external] {
            let layout = NotchGeometry.layout(for: screen)
            let panel = NotchGeometry.panelFrame(layout: layout, sizes: sizes)
            let frames = IslandSurface.allCases.map {
                NotchGeometry.islandFrame($0, layout: layout, sizes: sizes)
            }
            for frame in frames {
                XCTAssertEqual(frame.maxY, screen.frame.maxY)
                XCTAssertEqual(frame.midX, layout.notch.midX, accuracy: 0.001)
                XCTAssertTrue(panel.contains(frame), "\(frame) outside panel \(panel)")
                XCTAssertTrue(frame.contains(layout.notch) || layout.notch.width == 0)
            }
            XCTAssertTrue(screen.frame.contains(panel))
            let resting = frames[0], peek = frames[1], expanded = frames[2], activity = frames[3]
            XCTAssertTrue(peek.contains(resting))
            XCTAssertTrue(expanded.contains(peek))
            XCTAssertTrue(activity.contains(resting))
            XCTAssertEqual(activity.height, layout.notch.height + sizes.activity.height)
        }
    }

    func testRestingWingsSitBesideTheNotch() {
        let layout = NotchGeometry.layout(for: notched)
        let resting = NotchGeometry.islandFrame(.resting, layout: layout, sizes: sizes)
        XCTAssertEqual(resting, CGRect(x: 662 - sizes.wingWidth, y: 950, width: 188 + 2 * sizes.wingWidth, height: 32))
    }

    func testPeekGrowsTheWingsSlightly() {
        let layout = NotchGeometry.layout(for: notched)
        let peek = NotchGeometry.islandFrame(.peek, layout: layout, sizes: sizes)
        XCTAssertEqual(peek.width, 188 + 2 * (sizes.wingWidth + sizes.peekWingGrowth))
        XCTAssertEqual(peek.midX, layout.notch.midX, accuracy: 0.001)
    }

    func testNarrowScreenClampsInsideMargins() {
        let narrow = ScreenDescriptor(
            frame: CGRect(x: 100, y: 0, width: 500, height: 400),
            safeAreaTop: 0,
            menuBarHeight: 24
        )
        let layout = NotchGeometry.layout(for: narrow)
        let expanded = NotchGeometry.islandFrame(.expanded, layout: layout, sizes: sizes)
        XCTAssertEqual(expanded, CGRect(x: 108, y: 0, width: 484, height: 400))
        XCTAssertEqual(NotchGeometry.panelFrame(layout: layout, sizes: sizes), expanded)
    }

    func testOffCenterNotchIsKeptOnScreen() {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            safeAreaTop: 30,
            leftAuxiliaryWidth: 60,
            rightAuxiliaryWidth: 640,
            menuBarHeight: 30
        )
        let layout = NotchGeometry.layout(for: screen)
        let expanded = NotchGeometry.islandFrame(.expanded, layout: layout, sizes: sizes)
        XCTAssertEqual(expanded.minX, 8)
        XCTAssertTrue(NotchGeometry.panelFrame(layout: layout, sizes: sizes).contains(expanded))
    }

    func testIslandRectInPanelUsesTopLeftOrigin() {
        let layout = NotchGeometry.layout(for: notched)
        let panel = NotchGeometry.panelFrame(layout: layout, sizes: sizes)
        let resting = NotchGeometry.islandFrame(.resting, layout: layout, sizes: sizes)
        let local = NotchGeometry.islandRectInPanel(resting, panel: panel)
        XCTAssertEqual(local.minY, 0)
        XCTAssertEqual(local.midX, panel.width / 2, accuracy: 0.001)
        XCTAssertEqual(local.size, resting.size)
    }

    // MARK: Pointer and screen rules

    func testActivityGrowingUnderStillPointerDoesNotEnter() {
        var tracker = IslandPointerTracker()
        XCTAssertEqual(tracker.update(isInside: true, source: .frameChange), .none)
        XCTAssertTrue(tracker.isInside)
        // Small moves inside the grown island stay quiet...
        XCTAssertEqual(tracker.update(isInside: true, source: .movement), .none)
        // ...leaving still counts, and coming back is a real entry.
        XCTAssertEqual(tracker.update(isInside: false, source: .movement), .exited)
        XCTAssertEqual(tracker.update(isInside: true, source: .movement), .entered)
    }

    func testIslandMovingAwayFromPointerStillExits() {
        var tracker = IslandPointerTracker()
        XCTAssertEqual(tracker.update(isInside: true, source: .movement), .entered)
        XCTAssertEqual(tracker.update(isInside: false, source: .frameChange), .exited)
    }

    func testRestingNotchedIslandOnlyTakesTheNotch() {
        let layout = NotchGeometry.layout(for: notched)
        XCTAssertEqual(NotchGeometry.hitFrame(.resting, layout: layout, sizes: sizes), layout.notch)
        for surface in [IslandSurface.peek, .expanded, .activity] {
            XCTAssertEqual(
                NotchGeometry.hitFrame(surface, layout: layout, sizes: sizes),
                NotchGeometry.islandFrame(surface, layout: layout, sizes: sizes)
            )
        }
        let pill = NotchGeometry.layout(for: external)
        XCTAssertEqual(
            NotchGeometry.hitFrame(.resting, layout: pill, sizes: sizes),
            NotchGeometry.islandFrame(.resting, layout: pill, sizes: sizes)
        )
    }

    func testPillHidesWithoutAMenuBarButNotchDoesNot() {
        XCTAssertTrue(NotchGeometry.showsIsland(on: external))
        var hidden = external
        hidden.menuBarHeight = 0
        XCTAssertFalse(NotchGeometry.showsIsland(on: hidden))
        var notchedHidden = notched
        notchedHidden.menuBarHeight = 0
        XCTAssertTrue(NotchGeometry.showsIsland(on: notchedHidden))
    }
}

final class IslandModeMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func activity(_ id: String) -> IslandActivity {
        IslandActivity(id: id, agent: "codex", kind: .windowReset(title: "Codex"), createdAt: now)
    }

    func testHoverPeeksThenExpandsAndLeavingCollapses() {
        var machine = IslandModeMachine()
        machine.handle(.hoverHeld, now: now)
        XCTAssertEqual(machine.mode, .resting)
        machine.handle(.pointerEntered, now: now)
        XCTAssertEqual(machine.mode, .peek)
        machine.handle(.hoverHeld, now: now)
        XCTAssertEqual(machine.mode, .expanded)
        machine.handle(.pointerExited, now: now)
        XCTAssertEqual(machine.mode, .resting)
    }

    func testClickExpandsFromPeekAndActivity() {
        var machine = IslandModeMachine()
        machine.handle(.pointerEntered, now: now)
        machine.handle(.clicked, now: now)
        XCTAssertEqual(machine.mode, .expanded)

        machine = IslandModeMachine()
        machine.handle(.present(activity("a"), until: now + 4), now: now)
        machine.handle(.clicked, now: now)
        XCTAssertEqual(machine.mode, .expanded)
        machine.handle(.pointerExited, now: now)
        XCTAssertEqual(machine.mode, .resting, "an activity cut short by the user does not come back")
    }

    func testActivityShowsThenEnds() {
        var machine = IslandModeMachine()
        machine.handle(.present(activity("a"), until: now + 4), now: now)
        XCTAssertEqual(machine.mode, .activity(activity("a")))
        machine.handle(.present(activity("b"), until: now + 4), now: now)
        XCTAssertEqual(machine.mode, .activity(activity("b")))
        machine.handle(.activityEnded(id: "a"), now: now + 4)
        XCTAssertEqual(machine.mode, .activity(activity("b")), "a stale timer must not end a newer activity")
        machine.handle(.activityEnded(id: "b"), now: now + 4)
        XCTAssertEqual(machine.mode, .resting)
        XCTAssertNil(machine.activityDeadline)
    }

    func testExpiredActivityIsIgnored() {
        var machine = IslandModeMachine()
        machine.handle(.present(activity("a"), until: now), now: now)
        XCTAssertEqual(machine.mode, .resting)
    }

    func testPointerEnteringDuringActivityPeeks() {
        var machine = IslandModeMachine()
        machine.handle(.present(activity("a"), until: now + 4), now: now)
        machine.handle(.pointerEntered, now: now)
        XCTAssertEqual(machine.mode, .peek)
    }

    func testActivityWhileExpandedWaitsForCollapse() {
        var machine = IslandModeMachine()
        machine.handle(.expand, now: now)
        machine.handle(.present(activity("a"), until: now + 4), now: now)
        XCTAssertEqual(machine.mode, .expanded)
        XCTAssertEqual(machine.pending, activity("a"))
        machine.handle(.pointerExited, now: now + 1)
        XCTAssertEqual(machine.mode, .activity(activity("a")))
        XCTAssertNil(machine.pending)
    }

    func testPendingActivityThatExpiredIsDropped() {
        var machine = IslandModeMachine()
        machine.handle(.pointerEntered, now: now)
        machine.handle(.present(activity("a"), until: now + 4), now: now)
        machine.handle(.pointerExited, now: now + 5)
        XCTAssertEqual(machine.mode, .resting)
        XCTAssertNil(machine.pending)
    }

    func testCollapseEndsActivityButExitDoesNot() {
        var machine = IslandModeMachine()
        machine.handle(.present(activity("a"), until: now + 4), now: now)
        machine.handle(.pointerExited, now: now)
        XCTAssertEqual(machine.mode, .activity(activity("a")))
        machine.handle(.collapse, now: now)
        XCTAssertEqual(machine.mode, .resting)
    }
}
