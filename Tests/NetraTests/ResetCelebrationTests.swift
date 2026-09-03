import XCTest
@testable import Netra

/// The reset-celebration detector must fire exactly once per genuine cycle
/// rollover, never on first sighting, and never for short 5-hour windows.
final class ResetCelebrationTests: XCTestCase {
    private func window(_ key: String, _ provider: String, resetsAt: Date?) -> ResetWindow {
        ResetWindow(key: key, provider: provider, resetsAt: resetsAt)
    }

    func testFirstSightingSeedsWithoutCelebrating() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let (celebration, acknowledged) = ResetCelebrationDetector.evaluate(
            windows: [window("claude:weekly", "claude", resetsAt: reset)],
            acknowledged: [:]
        )
        XCTAssertNil(celebration, "a window must never celebrate the first time it is seen")
        XCTAssertEqual(acknowledged["claude:weekly"], reset)
    }

    func testRolloverCelebratesOnceThenStaysQuiet() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldReset = now.addingTimeInterval(-60)      // already passed
        let newReset = now.addingTimeInterval(7 * 86_400)

        // Cycle rolled: acknowledged boundary passed and a new one is set.
        let (first, ack1) = ResetCelebrationDetector.evaluate(
            windows: [window("claude:weekly", "claude", resetsAt: newReset)],
            acknowledged: ["claude:weekly": oldReset],
            now: now
        )
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.title, "Claude Code limit reset")
        XCTAssertEqual(ack1["claude:weekly"], newReset)

        // Same boundary observed again → no repeat celebration.
        let (second, _) = ResetCelebrationDetector.evaluate(
            windows: [window("claude:weekly", "claude", resetsAt: newReset)],
            acknowledged: ack1,
            now: now
        )
        XCTAssertNil(second)
    }

    func testScheduleChangeBeforeBoundaryDoesNotCelebrate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(3 * 86_400)   // not yet passed
        let movedFurther = now.addingTimeInterval(5 * 86_400)
        let (celebration, ack) = ResetCelebrationDetector.evaluate(
            windows: [window("cursor:included usage", "cursor", resetsAt: movedFurther)],
            acknowledged: ["cursor:included usage": future],
            now: now
        )
        XCTAssertNil(celebration, "a boundary that has not passed is a reschedule, not a reset")
        XCTAssertEqual(ack["cursor:included usage"], movedFurther)
    }

    func testMultipleProvidersProduceOneCombinedCelebration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-60)
        let new = now.addingTimeInterval(7 * 86_400)
        let (celebration, _) = ResetCelebrationDetector.evaluate(
            windows: [
                window("claude:weekly", "claude", resetsAt: new),
                window("codex:weekly", "codex", resetsAt: new),
            ],
            acknowledged: ["claude:weekly": old, "codex:weekly": old],
            now: now
        )
        XCTAssertEqual(celebration?.title, "Your limits reset")
    }

    func testFiveHourWindowsAreCelebratedToo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-60)
        let new = now.addingTimeInterval(5 * 3600)
        let (celebration, _) = ResetCelebrationDetector.evaluate(
            windows: [window("claude:5h", "claude", resetsAt: new)],
            acknowledged: ["claude:5h": old],
            now: now
        )
        XCTAssertNotNil(celebration, "5-hour resets are now celebrated as well")
        XCTAssertEqual(celebration?.title, "Claude Code limit reset")
    }

    func testSnapshotIncludesEveryQuotaWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let claude = ClaudeQuota(
            windows: [
                QuotaWindow(label: "5h", usedPercent: 20, resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(label: "weekly", usedPercent: 3, resetsAt: now.addingTimeInterval(86_400)),
            ],
            subscriptionType: "Max 5x", fetchedAt: now, source: .claudeCodeCache
        )
        let snapshot = UsageSnapshot(
            fetchedAt: now, report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
            activeBlock: nil, codexQuota: nil, claudeQuota: claude
        )
        XCTAssertEqual(snapshot.celebratableWindows().map(\.key).sorted(),
                       ["claude:5h", "claude:weekly"])
    }

    func testStorePersistsAcknowledgedBoundaries() {
        let suite = "NetraTests.Celebration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ResetCelebrationStore(defaults: defaults).acknowledged().isEmpty)
        let reset = Date(timeIntervalSince1970: 2_000_000)
        ResetCelebrationStore(defaults: defaults).setAcknowledged(["cursor:Grok Bot": reset])
        XCTAssertEqual(
            ResetCelebrationStore(defaults: defaults).acknowledged()["cursor:Grok Bot"],
            reset
        )
    }
}
