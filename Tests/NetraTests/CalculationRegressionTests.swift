import XCTest
@testable import Netra

/// Regressions for the calculation audit: period keys, the current week,
/// alert/celebration jitter, and dashboard aggregation.
final class CalculationRegressionTests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier, _ tz: String = "Asia/Kolkata") -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar
    }

    private func row(_ period: String, _ date: Date, cost: Double, tokens: Int, agent: String = "claude") -> CCRow {
        CCRow(period: period, inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
              cacheReadTokens: 0, totalTokens: tokens, totalCost: cost,
              agents: [CCAgentRow(agent: agent, inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
                                  cacheReadTokens: 0, totalTokens: tokens, totalCost: cost, modelBreakdowns: [])],
              modelBreakdowns: [])
    }

    func testPeriodKeysIgnoreNonGregorianCalendarsAndLocales() {
        let date = ISODate.parse("2026-09-26T06:00:00Z")!
        for identifier in [Calendar.Identifier.japanese, .buddhist, .gregorian] {
            XCTAssertEqual(PeriodKeys.day(date, calendar(identifier)), "2026-09-26")
            XCTAssertEqual(PeriodKeys.month(date, calendar(identifier)), "2026-09")
            XCTAssertEqual(PeriodKeys.weekStart(date, calendar(identifier)).key, "2026-09-21")
        }
        let parsed = PeriodKeys.formatter("yyyy-MM-dd", calendar(.japanese)).date(from: "2026-09-26")
        XCTAssertEqual(parsed.map { PeriodKeys.day($0, calendar(.gregorian)) }, "2026-09-26")
    }

    func testSnapshotRowsSurviveJapaneseCalendar() {
        let japanese = calendar(.japanese)
        let report = CCUnifiedReport(daily: [row("2026-09-26", .now, cost: 2, tokens: 10)], weekly: [], monthly: [])
        let snapshot = UsageSnapshot(fetchedAt: .now, report: report, activeBlock: nil,
                                     codexQuota: nil, claudeQuota: nil, calendar: japanese)
        XCTAssertEqual(snapshot.daily.count, 1)
        let now = ISODate.parse("2026-09-26T06:00:00Z")!
        XCTAssertEqual(snapshot.currentRow(for: .today, now: now, calendar: japanese).cost, 2)
    }

    /// ccusage only emits a week once it has usage; on a quiet Monday the
    /// last weekly row is last week and must not read as "this week".
    func testCurrentWeekMatchesThisMondayNotTheLastRow() {
        let report = CCUnifiedReport(
            daily: [], weekly: [row("2026-09-14", .now, cost: 5, tokens: 50)], monthly: []
        )
        let cal = calendar(.gregorian)
        let snapshot = UsageSnapshot(fetchedAt: .now, report: report, activeBlock: nil,
                                     codexQuota: nil, claudeQuota: nil, calendar: cal)
        let monday = ISODate.parse("2026-09-21T04:00:00Z")!
        let week = snapshot.currentRow(for: .week, now: monday, calendar: cal)
        XCTAssertEqual(week.period, "2026-09-21")
        XCTAssertEqual(week.cost, 0)
        let lastWeek = snapshot.currentRow(for: .week, now: ISODate.parse("2026-09-18T04:00:00Z")!, calendar: cal)
        XCTAssertEqual(lastWeek.cost, 5)
    }

    func testAlertCycleKeyAbsorbsResetJitter() {
        let a = Date(timeIntervalSince1970: 1_790_416_200.381)
        let b = Date(timeIntervalSince1970: 1_790_416_200.538)
        let c = Date(timeIntervalSince1970: 1_790_414_073)
        let d = Date(timeIntervalSince1970: 1_790_414_074)
        XCTAssertEqual(UsageAlertEvaluator.cycleIdentifier(a), UsageAlertEvaluator.cycleIdentifier(b))
        XCTAssertEqual(UsageAlertEvaluator.cycleIdentifier(c), UsageAlertEvaluator.cycleIdentifier(d))
        XCTAssertNotEqual(UsageAlertEvaluator.cycleIdentifier(a),
                          UsageAlertEvaluator.cycleIdentifier(a.addingTimeInterval(5 * 3600)))
    }

    func testCelebrationIgnoresJitterButCatchesRealRollover() {
        let prior = Date(timeIntervalSince1970: 1_790_416_200.381)
        let now = prior.addingTimeInterval(30)
        let jittered = [ResetWindow(key: "claude:5h", provider: "claude", resetsAt: prior.addingTimeInterval(0.4))]
        let first = ResetCelebrationDetector.evaluate(windows: jittered, acknowledged: ["claude:5h": prior], now: now)
        XCTAssertNil(first.celebration, "a stale read of the same window with jitter is not a reset")
        let next = [ResetWindow(key: "claude:5h", provider: "claude", resetsAt: prior.addingTimeInterval(5 * 3600))]
        let second = ResetCelebrationDetector.evaluate(windows: next, acknowledged: first.acknowledged, now: now)
        XCTAssertNotNil(second.celebration)
    }

    func testDashboardPreviousPeriodIsTheEqualWindowBefore() {
        let cal = calendar(.gregorian)
        let now = ISODate.parse("2026-09-26T06:00:00Z")!
        let formatter = PeriodKeys.formatter("yyyy-MM-dd", cal)
        let days = (0..<14).map { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: now))! }
        let report = CCUnifiedReport(
            daily: days.enumerated().map { index, day in
                row(formatter.string(from: day), day, cost: Double(index + 1), tokens: 10)
            },
            weekly: [], monthly: []
        )
        let snapshot = UsageSnapshot(fetchedAt: now, report: report, activeBlock: nil,
                                     codexQuota: nil, claudeQuota: nil, calendar: cal)
        let current = DashboardUsageAggregator.selection(from: snapshot, range: .sevenDays, now: now, calendar: cal)
        let previous = DashboardUsageAggregator.selection(from: snapshot, range: .sevenDays, periodsBack: 1, now: now, calendar: cal)
        XCTAssertEqual(current.rows.count, 7)
        XCTAssertEqual(previous.rows.count, 7)
        XCTAssertEqual(current.total.cost, (1...7).reduce(0, +).double)
        XCTAssertEqual(previous.total.cost, (8...14).reduce(0, +).double)
        XCTAssertEqual(try XCTUnwrap(DashboardUsageAggregator.change(from: 77, to: 28)), -0.636, accuracy: 0.001)
        XCTAssertNil(DashboardUsageAggregator.change(from: 0, to: 5))
    }

    func testTokenFormattingRollsOverCleanly() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(999_499), "999K")
        XCTAssertEqual(Format.tokens(999_999), "1.0M")
        XCTAssertEqual(Format.tokens(1_234_567), "1.2M")
        XCTAssertEqual(Format.tokens(999_999_999), "1.0B")
    }

    func testHiddenProviderFilterCombinesModelsAcrossAgents() {
        let model = { (cost: Double) in
            ModelStat(name: "gpt-5", cost: cost, totalTokens: 10, inputTokens: 10, outputTokens: 0, cacheReadTokens: 0)
        }
        let row = PeriodRow(
            period: "2026-09-26", date: .now, cost: 3, inputTokens: 30, outputTokens: 0,
            cacheReadTokens: 0, totalTokens: 30,
            agents: [
                AgentStat(name: "codex", cost: 1, totalTokens: 10, inputTokens: 10, outputTokens: 0,
                          cacheCreationTokens: 0, cacheReadTokens: 0, models: [model(1)]),
                AgentStat(name: "opencode", cost: 1, totalTokens: 10, inputTokens: 10, outputTokens: 0,
                          cacheCreationTokens: 0, cacheReadTokens: 0, models: [model(1)]),
                AgentStat(name: "claude", cost: 1, totalTokens: 10, inputTokens: 10, outputTokens: 0,
                          cacheCreationTokens: 0, cacheReadTokens: 0, models: []),
            ],
            models: [model(2)]
        )
        let filtered = row.filtered(hidingProviders: ["claude"])
        XCTAssertEqual(filtered.cost, 2)
        XCTAssertEqual(filtered.models.map(\.name), ["gpt-5"])
        XCTAssertEqual(filtered.models.first?.cost, 2)
    }
}

private extension Int {
    var double: Double { Double(self) }
}
