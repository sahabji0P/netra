import XCTest
@testable import Netra

final class LimitSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_400_000)

    private func window(used: Double, elapsedFraction: Double, duration: Double = 7 * 86400, label: String = "weekly") -> QuotaWindow {
        QuotaWindow(
            label: label, usedPercent: used,
            resetsAt: now.addingTimeInterval((1 - elapsedFraction) * duration),
            durationSeconds: duration
        )
    }

    func testTitlesReadAsSentenceCase() {
        XCTAssertEqual(LimitText.title("5h"), "Session · 5h")
        XCTAssertEqual(LimitText.title("weekly"), "Weekly")
        XCTAssertEqual(LimitText.title("weekly · Fable"), "Weekly · Fable")
        XCTAssertEqual(LimitText.title("auto models"), "Auto models")
        XCTAssertEqual(LimitText.title("2h"), "2-hour")
        XCTAssertEqual(LimitText.title("Grok Bot"), "Grok Bot")
    }

    func testAmountHonoursUsedOrRemainingAndClamps() {
        let w = window(used: 54.4, elapsedFraction: 0.5)
        XCTAssertEqual(LimitText.amount(w, showRemaining: false, isEstimate: false), "54% used")
        XCTAssertEqual(LimitText.amount(w, showRemaining: true, isEstimate: false), "46% left")
        let over = window(used: 130, elapsedFraction: 0.5)
        XCTAssertEqual(LimitText.amount(over, showRemaining: true, isEstimate: false), "0% left")
        XCTAssertEqual(LimitText.amount(over, showRemaining: false, isEstimate: true), "1.3× of peak")
    }

    func testCountdownAndClockResets() {
        XCTAssertEqual(LimitText.reset(now.addingTimeInterval(2 * 86400 + 4 * 3600), style: .countdown, now: now), "Resets in 2d 4h")
        XCTAssertEqual(LimitText.reset(now.addingTimeInterval(3 * 3600 + 12 * 60), style: .countdown, now: now), "Resets in 3h 12m")
        XCTAssertEqual(LimitText.reset(now.addingTimeInterval(20), style: .countdown, now: now), "Resets in 1m")
        XCTAssertTrue(LimitText.reset(now.addingTimeInterval(2 * 86400), style: .clock, now: now).hasPrefix("Resets "))
    }

    func testPaceComparesUsageWithEvenBurn() {
        XCTAssertEqual(LimitText.pace(window(used: 50, elapsedFraction: 0.52), now: now), .onPace)
        XCTAssertEqual(LimitText.pace(window(used: 100, elapsedFraction: 0.4), now: now), .exhausted)
        XCTAssertEqual(LimitText.pace(window(used: 20, elapsedFraction: 0.5), now: now), .behind(points: 30))
        // 60% used halfway through a week: at this rate the rest lasts
        // 40 / (60 / 3.5d) ≈ 2.33d, before the 3.5d reset.
        guard case .ahead(let points, let runsOut)? = LimitText.pace(window(used: 60, elapsedFraction: 0.5), now: now) else {
            return XCTFail("expected ahead of pace")
        }
        XCTAssertEqual(points, 10)
        XCTAssertEqual(try XCTUnwrap(runsOut), 2.333 * 86400, accuracy: 3600)
        // Linear burn: being ahead always means running out before the reset.
        guard case .ahead(_, let early)? = LimitText.pace(window(used: 30, elapsedFraction: 0.2), now: now) else {
            return XCTFail("expected ahead of pace")
        }
        XCTAssertEqual(try XCTUnwrap(early), (70.0 / 30.0) * 0.2 * 7 * 86400, accuracy: 60)
        // Unknown length or too early: no judgement.
        XCTAssertNil(LimitText.pace(QuotaWindow(label: "weekly", usedPercent: 50, resetsAt: now), now: now))
        XCTAssertNil(LimitText.pace(window(used: 5, elapsedFraction: 0.01), now: now))
        XCTAssertNil(LimitText.pace(window(used: 0, elapsedFraction: 0.4), now: now), "no usage, no pace")
    }

    func testProviderLimitsFollowOrderAndPickIconWindows() {
        let snapshot = UsageSnapshot(
            fetchedAt: now, report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
            activeBlock: nil,
            codexQuota: CodexQuota(windows: [window(used: 52, elapsedFraction: 0.5)], planType: "team", observedAt: now),
            claudeQuota: ClaudeQuota(
                windows: [
                    window(used: 1, elapsedFraction: 0.5, duration: 5 * 3600, label: "5h"),
                    window(used: 54, elapsedFraction: 0.5),
                    window(used: 70, elapsedFraction: 0.5, label: "weekly · Fable"),
                ],
                subscriptionType: "Max 5x", fetchedAt: now, source: .claudeCodeCache
            )
        )
        let limits = snapshot.providerLimits(order: ["codex", "claude", "cursor"], now: now)
        XCTAssertEqual(limits.map(\.agent), ["codex", "claude"])
        let claude = limits[1]
        XCTAssertEqual(claude.mostConstrained?.label, "weekly · Fable")
        XCTAssertEqual(claude.iconWindows?.top.label, "5h")
        XCTAssertEqual(claude.iconWindows?.bottom?.label, "weekly · Fable")
    }

    @MainActor
    func testPersonalizationPreferencesPersist() {
        let suite = "NetraTests.LimitPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.orderedLimitProviders, ["claude", "codex", "cursor"])
        preferences.barsShowRemaining = true
        preferences.resetTimeStyle = .clock
        preferences.showsPace = false
        preferences.defaultPeriod = .week
        preferences.moveLimitProvider("cursor", by: -1)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.barsShowRemaining)
        XCTAssertEqual(reloaded.resetTimeStyle, .clock)
        XCTAssertFalse(reloaded.showsPace)
        XCTAssertEqual(reloaded.defaultPeriod, .week)
        XCTAssertEqual(reloaded.orderedLimitProviders, ["claude", "cursor", "codex"])
    }
}
