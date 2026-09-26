import XCTest
@testable import Netra

@MainActor
final class AppPreferencesTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NetraTests.AppPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testDefaultsAreGlanceableAndAlertsAreOptIn() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.menuBarDisplayMode, .todayCost)
        XCTAssertTrue(preferences.showsLimits)
        XCTAssertTrue(preferences.showsProviderBreakdown)
        XCTAssertTrue(preferences.showsActivityChart)
        XCTAssertTrue(preferences.showsKeepAwake)
        XCTAssertFalse(preferences.dailyTokenAlertEnabled)
        XCTAssertEqual(preferences.dailyTokenAlertThreshold, 1_000_000)
        XCTAssertFalse(preferences.providerLimitAlertEnabled)
        XCTAssertEqual(preferences.providerLimitAlertThreshold, 80)
        XCTAssertEqual(MenuBarDisplayMode.highestProviderLimit.title, "Highest usage indicator")
        XCTAssertEqual(MenuBarDisplayMode.highestProviderLimit.detail, "Percent used of the provider closest to its limit")
    }

    func testChangesPersistAcrossInstances() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences: AppPreferences? = AppPreferences(defaults: defaults)
        preferences?.menuBarDisplayMode = .highestProviderLimit
        preferences?.showsLimits = false
        preferences?.showsProviderBreakdown = false
        preferences?.showsActivityChart = false
        preferences?.showsKeepAwake = false
        preferences?.dailyTokenAlertEnabled = true
        preferences?.dailyTokenAlertThreshold = 2_500_000
        preferences?.providerLimitAlertEnabled = true
        preferences?.providerLimitAlertThreshold = 92
        preferences = nil

        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.menuBarDisplayMode, .highestProviderLimit)
        XCTAssertFalse(restored.showsLimits)
        XCTAssertFalse(restored.showsProviderBreakdown)
        XCTAssertFalse(restored.showsActivityChart)
        XCTAssertFalse(restored.showsKeepAwake)
        XCTAssertTrue(restored.dailyTokenAlertEnabled)
        XCTAssertEqual(restored.dailyTokenAlertThreshold, 2_500_000)
        XCTAssertTrue(restored.providerLimitAlertEnabled)
        XCTAssertEqual(restored.providerLimitAlertThreshold, 92)
    }

    func testThresholdsAreClampedBeforePersisting() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.dailyTokenAlertThreshold = 0
        preferences.providerLimitAlertThreshold = 150

        XCTAssertEqual(preferences.dailyTokenAlertThreshold, 1)
        XCTAssertEqual(preferences.providerLimitAlertThreshold, 100)
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.dailyTokenAlertThreshold, 1)
        XCTAssertEqual(restored.providerLimitAlertThreshold, 100)
    }
}

final class UsageAlertEvaluatorTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testCrossingDailyThresholdAlertsOnlyOnceUntilUsageDrops() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: true,
            dailyTokenThreshold: 1_000,
            providerLimitAlertEnabled: false,
            providerLimitThreshold: 80
        )
        let above = snapshot(now: now, dailyTokens: 1_200)

        let first = UsageAlertEvaluator.evaluate(
            snapshot: above, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now, calendar: calendar
        )
        XCTAssertEqual(first.candidates.map(\.kind), [.dailyTokens])

        let repeated = UsageAlertEvaluator.evaluate(
            snapshot: above, configuration: configuration,
            previousState: first.state, now: now, calendar: calendar
        )
        XCTAssertTrue(repeated.candidates.isEmpty)

        let below = UsageAlertEvaluator.evaluate(
            snapshot: snapshot(now: now, dailyTokens: 500), configuration: configuration,
            previousState: repeated.state, now: now, calendar: calendar
        )
        XCTAssertTrue(below.candidates.isEmpty)

        let crossedAgain = UsageAlertEvaluator.evaluate(
            snapshot: above, configuration: configuration,
            previousState: below.state, now: now, calendar: calendar
        )
        XCTAssertEqual(crossedAgain.candidates.map(\.kind), [.dailyTokens])
    }

    func testNewDayCanAlertAtSameTokenValue() throws {
        let dayOne = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let dayTwo = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z"))
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: true, dailyTokenThreshold: 1_000,
            providerLimitAlertEnabled: false, providerLimitThreshold: 80
        )
        let first = UsageAlertEvaluator.evaluate(
            snapshot: snapshot(now: dayOne, dailyTokens: 2_000), configuration: configuration,
            previousState: UsageAlertDedupeState(), now: dayOne, calendar: calendar
        )
        let nextDay = UsageAlertEvaluator.evaluate(
            snapshot: snapshot(now: dayTwo, dailyTokens: 2_000), configuration: configuration,
            previousState: first.state, now: dayTwo, calendar: calendar
        )

        XCTAssertEqual(nextDay.candidates.map(\.kind), [.dailyTokens])
    }

    func testProviderQuotaAndClaudeLocalEstimatePreserveProvenance() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let reset = now.addingTimeInterval(3_600)
        let snapshot = snapshot(
            now: now,
            dailyTokens: 0,
            block: BlockStat(block: CCBlock(
                startTime: isoString(now.addingTimeInterval(-600)),
                endTime: isoString(reset), isActive: true, isGap: false,
                totalTokens: 10_000, costUSD: 1,
                projection: CCBlockProjection(totalCost: 3),
                tokenLimitStatus: CCTokenLimitStatus(limit: 11_111)
            )),
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "5h", usedPercent: 85, resetsAt: reset)],
                planType: "test", observedAt: now
            )
        )
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: false, dailyTokenThreshold: 1,
            providerLimitAlertEnabled: true, providerLimitThreshold: 80
        )

        let result = UsageAlertEvaluator.evaluate(
            snapshot: snapshot, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now, calendar: calendar
        )

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.candidates.contains { $0.kind == .providerLimit })
        XCTAssertTrue(result.candidates.contains { $0.kind == .localLimitEstimate })
        XCTAssertTrue(result.candidates.contains { $0.title == "Codex limit alert" })
        XCTAssertTrue(result.candidates.contains {
            $0.title == "Claude local usage alert" && $0.body.contains("local 5h estimate")
        })
    }

    func testChangedResetCycleCanAlertAgain() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: false, dailyTokenThreshold: 1,
            providerLimitAlertEnabled: true, providerLimitThreshold: 80
        )
        let firstSnapshot = snapshot(
            now: now, dailyTokens: 0,
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "5h", usedPercent: 90, resetsAt: now.addingTimeInterval(60))],
                planType: nil, observedAt: now
            )
        )
        let first = UsageAlertEvaluator.evaluate(
            snapshot: firstSnapshot, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now, calendar: calendar
        )
        let resetSnapshot = snapshot(
            now: now, dailyTokens: 0,
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "5h", usedPercent: 90, resetsAt: now.addingTimeInterval(7_200))],
                planType: nil, observedAt: now
            )
        )
        let afterReset = UsageAlertEvaluator.evaluate(
            snapshot: resetSnapshot, configuration: configuration,
            previousState: first.state, now: now, calendar: calendar
        )

        XCTAssertEqual(afterReset.candidates.map(\.kind), [.providerLimit])
    }

    func testExpiredCodexWindowDoesNotAlert() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let expired = snapshot(
            now: now, dailyTokens: 0,
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "5h", usedPercent: 95, resetsAt: now.addingTimeInterval(-1))],
                planType: nil, observedAt: now
            )
        )
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: false, dailyTokenThreshold: 1,
            providerLimitAlertEnabled: true, providerLimitThreshold: 80
        )

        let result = UsageAlertEvaluator.evaluate(
            snapshot: expired, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now, calendar: calendar
        )

        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testCodexActiveWindowsRequireFutureResetOrRecentObservation() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let futureReset = QuotaWindow(label: "future", usedPercent: 1, resetsAt: now.addingTimeInterval(1))
        let expiredReset = QuotaWindow(label: "expired", usedPercent: 2, resetsAt: now)
        let recentUndated = QuotaWindow(label: "recent-undated", usedPercent: 3, resetsAt: nil)

        let recent = CodexQuota(
            windows: [futureReset, expiredReset, recentUndated],
            planType: nil,
            observedAt: now.addingTimeInterval(-3_600)
        )
        XCTAssertEqual(recent.activeWindows(now: now).map(\.label), ["future", "recent-undated"])

        let stale = CodexQuota(
            windows: [recentUndated],
            planType: nil,
            observedAt: now.addingTimeInterval(-3_601)
        )
        XCTAssertTrue(stale.activeWindows(now: now).isEmpty)

        let unobserved = CodexQuota(windows: [recentUndated], planType: nil, observedAt: nil)
        XCTAssertTrue(unobserved.activeWindows(now: now).isEmpty)
    }

    func testStaleUndatedCodexWindowDoesNotAlert() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let stale = snapshot(
            now: now, dailyTokens: 0,
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "limit", usedPercent: 95, resetsAt: nil)],
                planType: nil,
                observedAt: now.addingTimeInterval(-3_601)
            )
        )
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: false, dailyTokenThreshold: 1,
            providerLimitAlertEnabled: true, providerLimitThreshold: 80
        )

        let result = UsageAlertEvaluator.evaluate(
            snapshot: stale, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now, calendar: calendar
        )

        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testRecentUndatedCodexWindowStaysVisibleButDoesNotAlertWithoutCycle() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let undated = snapshot(
            now: now, dailyTokens: 0,
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "limit", usedPercent: 95, resetsAt: nil)],
                planType: nil,
                observedAt: now
            )
        )
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: false, dailyTokenThreshold: 1,
            providerLimitAlertEnabled: true, providerLimitThreshold: 80
        )

        XCTAssertEqual(undated.codexQuota?.activeWindows(now: now).count, 1)
        let result = UsageAlertEvaluator.evaluate(
            snapshot: undated, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now, calendar: calendar
        )
        XCTAssertTrue(result.candidates.isEmpty)
    }

    private func snapshot(
        now: Date,
        dailyTokens: Int,
        block: BlockStat? = nil,
        codexQuota: CodexQuota? = nil
    ) -> UsageSnapshot {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let period = formatter.string(from: now)
        let report = CCUnifiedReport(
            daily: [CCRow(
                period: period, inputTokens: dailyTokens, outputTokens: 0,
                cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: dailyTokens,
                totalCost: 0, agents: [], modelBreakdowns: []
            )],
            weekly: [], monthly: []
        )
        return UsageSnapshot(
            fetchedAt: now, report: report, activeBlock: block,
            codexQuota: codexQuota, claudeQuota: nil, calendar: calendar
        )
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private actor NotificationSchedulerSpy: UsageNotificationScheduling {
    var authorization: NotificationAuthorizationState
    var grantsRequest: Bool
    var schedulingError: Bool
    private(set) var scheduled: [UsageAlertCandidate] = []

    init(
        authorization: NotificationAuthorizationState,
        grantsRequest: Bool = false,
        schedulingError: Bool = false
    ) {
        self.authorization = authorization
        self.grantsRequest = grantsRequest
        self.schedulingError = schedulingError
    }

    func authorizationState() -> NotificationAuthorizationState { authorization }

    func requestAuthorization() -> Bool {
        authorization = grantsRequest ? .allowed : .denied
        return grantsRequest
    }

    func schedule(_ candidate: UsageAlertCandidate) throws {
        if schedulingError { throw SchedulingError.rejected }
        scheduled.append(candidate)
    }

    func setAuthorization(_ authorization: NotificationAuthorizationState) {
        self.authorization = authorization
    }

    func setSchedulingError(_ schedulingError: Bool) {
        self.schedulingError = schedulingError
    }

    enum SchedulingError: Error { case rejected }
}

final class UsageAlertControllerTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testDeniedAndFailedNotificationsRetryUntilSuccessfullyScheduled() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let scheduler = NotificationSchedulerSpy(authorization: .denied)
        let persistence = UsageAlertDefaultsStore(suiteName: suiteName)
        let controller = UsageAlertController(scheduler: scheduler, persistence: persistence)
        let configuration = configuration()
        let usage = snapshot(now: now, dailyTokens: 1_200)

        await controller.processFreshSnapshot(usage, configuration: configuration, now: now, calendar: calendar)
        var scheduled = await scheduler.scheduled
        XCTAssertTrue(scheduled.isEmpty)

        await scheduler.setAuthorization(.allowed)
        await scheduler.setSchedulingError(true)
        await controller.processFreshSnapshot(usage, configuration: configuration, now: now, calendar: calendar)
        scheduled = await scheduler.scheduled
        XCTAssertTrue(scheduled.isEmpty)

        await scheduler.setSchedulingError(false)
        await controller.processFreshSnapshot(usage, configuration: configuration, now: now, calendar: calendar)
        scheduled = await scheduler.scheduled
        XCTAssertEqual(scheduled.count, 1)
    }

    func testNotDeterminedPermissionIsRequestedAndRereadBeforeScheduling() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let scheduler = NotificationSchedulerSpy(authorization: .notDetermined, grantsRequest: true)
        let controller = UsageAlertController(
            scheduler: scheduler,
            persistence: UsageAlertDefaultsStore(suiteName: suiteName)
        )

        await controller.processFreshSnapshot(
            snapshot(now: now, dailyTokens: 1_200),
            configuration: configuration(),
            now: now,
            calendar: calendar
        )

        let scheduled = await scheduler.scheduled
        let authorization = await scheduler.authorizationState()
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(authorization, .allowed)
    }

    func testDeliveredKeyPersistsAcrossControllerRelaunchAndRearmsBelowThreshold() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let configuration = configuration()
        let above = snapshot(now: now, dailyTokens: 1_200)
        let below = snapshot(now: now, dailyTokens: 200)
        let persistence = UsageAlertDefaultsStore(suiteName: suiteName)

        let firstScheduler = NotificationSchedulerSpy(authorization: .allowed)
        let first = UsageAlertController(scheduler: firstScheduler, persistence: persistence)
        await first.processFreshSnapshot(above, configuration: configuration, now: now, calendar: calendar)
        let initiallyScheduled = await firstScheduler.scheduled
        XCTAssertEqual(initiallyScheduled.count, 1)

        let relaunchedScheduler = NotificationSchedulerSpy(authorization: .allowed)
        let relaunched = UsageAlertController(scheduler: relaunchedScheduler, persistence: persistence)
        await relaunched.processFreshSnapshot(above, configuration: configuration, now: now, calendar: calendar)
        let scheduledAfterRelaunch = await relaunchedScheduler.scheduled
        XCTAssertTrue(scheduledAfterRelaunch.isEmpty)

        await relaunched.processFreshSnapshot(below, configuration: configuration, now: now, calendar: calendar)
        let rearmedScheduler = NotificationSchedulerSpy(authorization: .allowed)
        let rearmed = UsageAlertController(scheduler: rearmedScheduler, persistence: persistence)
        await rearmed.processFreshSnapshot(above, configuration: configuration, now: now, calendar: calendar)
        let scheduledAfterRearm = await rearmedScheduler.scheduled
        XCTAssertEqual(scheduledAfterRearm.count, 1)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NetraTests.UsageAlerts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func configuration() -> UsageAlertConfiguration {
        UsageAlertConfiguration(
            dailyTokenAlertEnabled: true, dailyTokenThreshold: 1_000,
            providerLimitAlertEnabled: false, providerLimitThreshold: 80
        )
    }

    private func snapshot(now: Date, dailyTokens: Int) -> UsageSnapshot {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let report = CCUnifiedReport(
            daily: [CCRow(
                period: formatter.string(from: now), inputTokens: dailyTokens, outputTokens: 0,
                cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: dailyTokens,
                totalCost: 0, agents: [], modelBreakdowns: []
            )],
            weekly: [], monthly: []
        )
        return UsageSnapshot(
            fetchedAt: now, report: report, activeBlock: nil,
            codexQuota: nil, claudeQuota: nil, calendar: calendar
        )
    }
}

final class DashboardUsageAggregatorTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func testExplicitRangesUseDailyRowsAndIncludeToday() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let snapshot = makeSnapshot(now: now, dayCount: 100)

        XCTAssertEqual(selection(snapshot, .today, now).rows.count, 1)
        XCTAssertEqual(selection(snapshot, .sevenDays, now).rows.count, 7)
        XCTAssertEqual(selection(snapshot, .thirtyDays, now).rows.count, 30)
        XCTAssertEqual(selection(snapshot, .ninetyDays, now).rows.count, 90)
    }

    func testRangeTotalAggregatesProviderModelAndCacheComposition() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-09T12:00:00Z"))
        let result = selection(makeSnapshot(now: now, dayCount: 8), .sevenDays, now)

        XCTAssertEqual(result.total.cost, 7, accuracy: 0.001)
        XCTAssertEqual(result.total.inputTokens, 70)
        XCTAssertEqual(result.total.outputTokens, 140)
        XCTAssertEqual(result.total.cacheCreationTokens, 210)
        XCTAssertEqual(result.total.cacheReadTokens, 280)
        XCTAssertEqual(result.total.totalTokens, 700)
        XCTAssertEqual(result.total.agents.count, 1)
        XCTAssertEqual(result.total.agents.first?.cacheCreationTokens, 210)
        XCTAssertEqual(result.total.agents.first?.models.first?.cacheCreationTokens, 210)
        XCTAssertEqual(result.total.models.first?.cacheCreationTokens, 210)
    }

    private func selection(
        _ snapshot: UsageSnapshot,
        _ range: DashboardUsageRange,
        _ now: Date
    ) -> DashboardUsageSelection {
        DashboardUsageAggregator.selection(
            from: snapshot, range: range, now: now, calendar: calendar
        )
    }

    private func makeSnapshot(now: Date, dayCount: Int) -> UsageSnapshot {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let model = CCModelBreakdown(
            modelName: "claude-test", cost: 1, inputTokens: 10, outputTokens: 20,
            cacheCreationTokens: 30, cacheReadTokens: 40
        )
        let agent = CCAgentRow(
            agent: "claude", inputTokens: 10, outputTokens: 20,
            cacheCreationTokens: 30, cacheReadTokens: 40, totalTokens: 100,
            totalCost: 1, modelBreakdowns: [model]
        )
        let rows = (0..<dayCount).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            return CCRow(
                period: formatter.string(from: date), inputTokens: 10, outputTokens: 20,
                cacheCreationTokens: 30, cacheReadTokens: 40, totalTokens: 100,
                totalCost: 1, agents: [agent], modelBreakdowns: [model]
            )
        }
        return UsageSnapshot(
            fetchedAt: now,
            report: CCUnifiedReport(daily: rows, weekly: [], monthly: []),
            activeBlock: nil, codexQuota: nil, claudeQuota: nil, calendar: calendar
        )
    }
}
