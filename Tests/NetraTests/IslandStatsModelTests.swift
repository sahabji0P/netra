import XCTest
@testable import Netra

final class IslandStatsModelTests: XCTestCase {
    typealias F = IslandStatsFixtures

    func testEmptySnapshotHasNoUsageButFullStrip() {
        let model = IslandStatsModel(snapshot: F.snapshot([]), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.today.cost, 0)
        XCTAssertEqual(model.today.tokens, 0)
        XCTAssertNil(model.today.costChange)
        XCTAssertNil(model.today.tokenChange)
        XCTAssertEqual(model.heatmap.count, 30)
        XCTAssertTrue(model.heatmap.allSatisfy { $0.level == 0 && $0.provider == nil })
        XCTAssertEqual(model.heatmap.last?.period, "2026-10-12")
        XCTAssertEqual(model.heatmap.first?.period, "2026-09-13")
        XCTAssertTrue(model.modelMix.isEmpty)
        XCTAssertEqual(model.tokenMix.total, 0)
        XCTAssertEqual(model.tokenMix.cacheHitRate, 0)
        XCTAssertNil(model.block)
        XCTAssertFalse(model.hasUsage)

        let none = IslandStatsModel(snapshot: nil, hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(none, model)
    }

    func testSingleDayTodayHasNoBaseline() {
        let rows = [F.day(0, [F.agent("claude", cost: 4, models: [("claude-opus-4-1-20250805", 4)])])]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.today.cost, 4, accuracy: 1e-9)
        XCTAssertNil(model.today.costChange)
        XCTAssertEqual(model.heatmap.last?.level, 4)
        XCTAssertEqual(model.heatmap.last?.provider, "claude")
        XCTAssertEqual(model.heatmap.dropLast().filter { $0.level > 0 }.count, 0)
        XCTAssertEqual(model.modelMix.map(\.name), ["claude-opus-4-1"])
        XCTAssertEqual(model.modelMix.first?.share ?? 0, 1, accuracy: 1e-9)
    }

    func testRangeSetsTheMixWindowAndStripLength() {
        let rows = [
            F.day(0, [F.agent("claude", cost: 1, models: [("claude-opus-4-1-20250805", 1)])]),
            F.day(10, [F.agent("codex", cost: 4, models: [("gpt-5", 4)])]),
            F.day(60, [F.agent("cursor", cost: 9, models: [("default", 9)])]),
        ]
        func model(_ range: IslandStatsRange) -> IslandStatsModel {
            IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], range: range, now: F.now, calendar: F.calendar)
        }
        XCTAssertEqual(model(.today).modelMix.map(\.name), ["claude-opus-4-1"])
        XCTAssertEqual(model(.week).modelMix.map(\.name), ["claude-opus-4-1"])
        XCTAssertEqual(model(.month).modelMix.map(\.name), ["gpt-5", "claude-opus-4-1"])
        XCTAssertEqual(model(.quarter).modelMix.map(\.name), ["Auto", "gpt-5", "claude-opus-4-1"])

        XCTAssertEqual(model(.week).heatmap.count, 30)
        XCTAssertEqual(model(.week).heatmap.filter(\.inRange).count, 7)
        XCTAssertEqual(model(.week).heatmapTotal, 5, accuracy: 1e-9)
        let quarter = model(.quarter)
        XCTAssertEqual(quarter.heatmap.count, 90)
        XCTAssertTrue(quarter.heatmap.allSatisfy(\.inRange))
        XCTAssertEqual(quarter.heatmapTotal, 14, accuracy: 1e-9)
        XCTAssertEqual(model(.today).spanCost, 1, accuracy: 1e-9)
        XCTAssertEqual(model(.week).spanCost, 1, accuracy: 1e-9)
        XCTAssertEqual(model(.month).spanCost, 5, accuracy: 1e-9)
        XCTAssertEqual(quarter.spanCost, 14, accuracy: 1e-9)
        // The today tile ignores the range.
        XCTAssertEqual(quarter.today, model(.today).today)
    }

    func testSelectedDayShowsOnlyThatDayWithCostAndTokens() throws {
        let rows = [
            F.day(0, [F.agent("claude", cost: 1, models: [("claude-opus-4-1-20250805", 1)])]),
            F.day(3, [
                F.agent("claude", cost: 6, tokens: 6000, models: [("claude-opus-4-1-20250805", 4), ("claude-sonnet-4-5-20250929", 2)]),
                F.agent("cursor-grok-bot", cost: 1.5, tokens: 900, models: [("grok-bot-automation", 1.5)]),
            ]),
        ]
        let key = F.day(3, []).period
        let model = IslandStatsModel(
            snapshot: F.snapshot(rows), hiddenProviders: [], range: .month, selectedDay: key,
            now: F.now, calendar: F.calendar
        )
        XCTAssertEqual(model.selectedDay?.period, key)
        XCTAssertEqual(model.modelMix.map(\.name), ["claude-opus-4-1", "claude-sonnet-4-5", "Grok Bot · automation"])
        let opus = try XCTUnwrap(model.modelMix.first)
        XCTAssertEqual(opus.cost, 4, accuracy: 1e-9)
        XCTAssertEqual(opus.tokens, 4000)
        XCTAssertEqual(opus.share, 4 / 7.5, accuracy: 1e-9)
        XCTAssertEqual(model.modelMix.last?.tokens, 900)
        XCTAssertEqual(model.tokenMix.total, 6900)
        XCTAssertEqual(model.spanCost, 7.5, accuracy: 1e-9)
        XCTAssertEqual(model.spanTokens, 6900)

        // An idle day selects but shows nothing; a key off the strip is ignored.
        let idle = IslandStatsModel(
            snapshot: F.snapshot(rows), hiddenProviders: [], selectedDay: F.day(1, []).period,
            now: F.now, calendar: F.calendar
        )
        XCTAssertNotNil(idle.selectedDay)
        XCTAssertTrue(idle.modelMix.isEmpty)
        XCTAssertEqual(idle.tokenMix.total, 0)
        let outside = IslandStatsModel(
            snapshot: F.snapshot(rows), hiddenProviders: [], selectedDay: "2020-01-01",
            now: F.now, calendar: F.calendar
        )
        XCTAssertNil(outside.selectedDay)
        XCTAssertEqual(outside.modelMix.count, 3)
    }

    func testOtherSegmentSumsCostAndTokens() throws {
        let rows = [F.day(0, [F.agent("claude", cost: 10, tokens: 10_000, models: [
            ("a", 4), ("b", 3), ("c", 2), ("d", 0.6), ("e", 0.4),
        ])])]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        let other = try XCTUnwrap(model.modelMix.last)
        XCTAssertEqual(other.name, "Other")
        XCTAssertEqual(other.cost, 1, accuracy: 1e-9)
        XCTAssertEqual(other.tokens, 1000)
    }

    func testSingleDayInPriorWeekAveragesOverSevenDays() {
        let rows = [F.day(3, [F.agent("codex", cost: 14, tokens: 700)])]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.today.averageCost, 2, accuracy: 1e-9)
        XCTAssertEqual(model.today.averageTokens, 100, accuracy: 1e-9)
        XCTAssertEqual(model.today.costChange ?? 0, -1, accuracy: 1e-9)
        XCTAssertEqual(IslandStatsModel.changeText(model.today.costChange), "−100%")
    }

    func testChangeAgainstSevenDayAverageIgnoresTodayAndOlderDays() {
        let rows = [
            F.day(0, [F.agent("claude", cost: 6, tokens: 600)]),
            F.day(1, [F.agent("claude", cost: 3, tokens: 300)]),
            F.day(7, [F.agent("claude", cost: 11, tokens: 1100)]),
            F.day(8, [F.agent("claude", cost: 1000, tokens: 1)]), // outside the baseline
        ]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.today.averageCost, 2, accuracy: 1e-9)
        XCTAssertEqual(model.today.costChange ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(IslandStatsModel.changeText(model.today.costChange), "+200%")
        XCTAssertEqual(model.today.tokenChange ?? 0, 2, accuracy: 1e-9)
    }

    func testHeatmapLevelsAndDominantProvider() {
        let rows = [
            F.day(0, [F.agent("claude", cost: 1), F.agent("codex", cost: 3)]),
            F.day(1, [F.agent("cursor", cost: 8)]),
            F.day(29, [F.agent("claude", cost: 2)]),
            F.day(30, [F.agent("claude", cost: 99)]), // outside the 30-day strip
        ]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.heatmap.last?.provider, "codex")
        XCTAssertEqual(model.heatmap.last?.level, 2)  // 4 of 8
        XCTAssertEqual(model.heatmap[28].level, 4)
        XCTAssertEqual(model.heatmap.first?.level, 1) // 2 of 8
        XCTAssertEqual(model.heatmapTotal, 14, accuracy: 1e-9)
    }

    func testUnpricedUsageFallsBackToTokens() {
        let rows = [
            F.day(0, [F.agent("gemini", cost: 0, tokens: 400, models: [("gemini-2.5-pro", 0)])]),
            F.day(2, [F.agent("gemini", cost: 0, tokens: 100, models: [("gemini-2.5-flash", 0)])]),
        ]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.heatmap.last?.level, 4)
        XCTAssertEqual(model.heatmap[27].level, 1)
        XCTAssertTrue(model.modelMixByTokens)
        XCTAssertEqual(model.modelMix.map(\.name), ["gemini-2.5-pro", "gemini-2.5-flash"])
        XCTAssertEqual(model.modelMix.map(\.providerRank), [0, 1])
    }

    func testModelMixKeepsTopModelsAndGroupsTheRest() {
        let models: [(String, Double)] = [("a", 5), ("b", 4), ("c", 3), ("d", 2), ("e", 1)]
        let rows = [F.day(0, [F.agent("claude", cost: 15, models: models)])]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.modelMix.map(\.name), ["a", "b", "c", "Other"])
        XCTAssertEqual(model.modelMix.last?.value ?? 0, 3, accuracy: 1e-9)
        XCTAssertNil(model.modelMix.last?.provider)
        XCTAssertEqual(model.modelMix.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)

        let four = [F.day(0, [F.agent("claude", cost: 14, models: Array(models.prefix(4)))])]
        let exact = IslandStatsModel(snapshot: F.snapshot(four), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(exact.modelMix.map(\.name), ["a", "b", "c", "d"])
    }

    func testModelMixUsesOnlyTheLastSevenDays() {
        let rows = [
            F.day(0, [F.agent("claude", cost: 1, models: [("claude-sonnet-4-5", 1)])]),
            F.day(7, [F.agent("codex", cost: 50, models: [("gpt-5", 50)])]),
        ]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.modelMix.map(\.name), ["claude-sonnet-4-5"])
    }

    func testTokenMixAndCacheHitRate() {
        let rows = [F.day(1, [F.agent("claude", cost: 1, input: 100, output: 50, cacheWrite: 150, cacheRead: 750)])]
        let model = IslandStatsModel(snapshot: F.snapshot(rows), hiddenProviders: [], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.tokenMix.total, 1050)
        XCTAssertEqual(model.tokenMix.cacheHitRate, 0.75, accuracy: 1e-9)
        XCTAssertEqual(model.tokenMix.share(model.tokenMix.cacheRead), 750.0 / 1050, accuracy: 1e-9)
    }

    func testHiddenProvidersDropOutEverywhere() {
        let rows = [
            F.day(0, [F.agent("claude", cost: 5, models: [("claude-opus-4-1", 5)]),
                      F.agent("codex", cost: 1, models: [("gpt-5", 1)])]),
            F.day(1, [F.agent("claude", cost: 9)]),
        ]
        let snapshot = F.snapshot(rows, block: F.block(startedMinutesAgo: 60, cost: 3))
        let model = IslandStatsModel(snapshot: snapshot, hiddenProviders: ["claude"], now: F.now, calendar: F.calendar)
        XCTAssertEqual(model.today.cost, 1, accuracy: 1e-9)
        XCTAssertEqual(model.heatmap.last?.provider, "codex")
        XCTAssertEqual(model.heatmap[28].level, 0)
        XCTAssertEqual(model.modelMix.map(\.name), ["gpt-5"])
        XCTAssertNil(model.block, "ccusage blocks are Claude-only")

        let visible = IslandStatsModel(snapshot: snapshot, hiddenProviders: ["codex"], now: F.now, calendar: F.calendar)
        XCTAssertNotNil(visible.block)
        XCTAssertEqual(visible.today.cost, 5, accuracy: 1e-9)
    }

    func testActiveBlockBurnRateAndProjection() throws {
        let snapshot = F.snapshot([], block: F.block(startedMinutesAgo: 120, cost: 6, projected: 15, tokens: 1_200_000))
        let block = try XCTUnwrap(
            IslandStatsModel(snapshot: snapshot, hiddenProviders: [], now: F.now, calendar: F.calendar).block
        )
        XCTAssertEqual(block.burnRate, 3, accuracy: 1e-9)
        XCTAssertEqual(block.projectedCost, 15, accuracy: 1e-9)
        XCTAssertEqual(block.tokensPerMinute, 10_000, accuracy: 1e-6)
        XCTAssertEqual(block.elapsedFraction, 0.4, accuracy: 1e-9)
        XCTAssertEqual(block.remaining, 3 * 3600, accuracy: 1e-6)
    }

    func testFreshOrEndedBlockIsSafe() throws {
        let fresh = F.snapshot([], block: F.block(startedMinutesAgo: 0, cost: 0.5))
        let block = try XCTUnwrap(
            IslandStatsModel(snapshot: fresh, hiddenProviders: [], now: F.now, calendar: F.calendar).block
        )
        XCTAssertEqual(block.burnRate, 30, accuracy: 1e-9) // clamped to one minute elapsed
        XCTAssertTrue(block.burnRate.isFinite)

        let ended = F.snapshot([], block: F.block(startedMinutesAgo: 301, cost: 2))
        XCTAssertNil(IslandStatsModel(snapshot: ended, hiddenProviders: [], now: F.now, calendar: F.calendar).block)
    }
}

/// Synthetic usage for the island stats tests and render preview.
enum IslandStatsFixtures {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()
    /// 2026-10-12 15:30 in Kolkata.
    static let now = ISODate.parse("2026-10-12T10:00:00Z")!

    static func agent(
        _ name: String, cost: Double, tokens: Int? = nil,
        input: Int? = nil, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
        models: [(String, Double)] = []
    ) -> AgentStat {
        let input = input ?? tokens ?? Int(cost * 1000)
        let total = input + output + cacheWrite + cacheRead
        let modelCost = models.reduce(0) { $0 + $1.1 }
        return AgentStat(
            name: name, cost: cost, totalTokens: total, inputTokens: input, outputTokens: output,
            cacheCreationTokens: cacheWrite, cacheReadTokens: cacheRead,
            models: models.map { model, cost in
                // Split tokens by cost share, or evenly when unpriced.
                let share = modelCost > 0 ? cost / modelCost : 1 / Double(models.count)
                let tokens = Int(Double(total) * share)
                return ModelStat(name: model, cost: cost, totalTokens: tokens, inputTokens: tokens,
                                 outputTokens: 0, cacheReadTokens: 0)
            }
        )
    }

    static func day(_ daysAgo: Int, _ agents: [AgentStat]) -> PeriodRow {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        return PeriodRow(
            period: PeriodKeys.day(date, calendar), date: date,
            cost: agents.reduce(0) { $0 + $1.cost },
            inputTokens: agents.reduce(0) { $0 + $1.inputTokens },
            outputTokens: agents.reduce(0) { $0 + $1.outputTokens },
            cacheCreationTokens: agents.reduce(0) { $0 + $1.cacheCreationTokens },
            cacheReadTokens: agents.reduce(0) { $0 + $1.cacheReadTokens },
            totalTokens: agents.reduce(0) { $0 + $1.totalTokens },
            agents: agents.sorted { $0.cost > $1.cost },
            models: agents.flatMap(\.models).combinedByName()
        )
    }

    static func block(
        startedMinutesAgo minutes: Double, cost: Double, projected: Double? = nil, tokens: Int = 100_000
    ) -> BlockStat? {
        let start = now.addingTimeInterval(-minutes * 60)
        let iso = ISO8601DateFormatter()
        return BlockStat(block: CCBlock(
            startTime: iso.string(from: start),
            endTime: iso.string(from: start.addingTimeInterval(5 * 3600)),
            isActive: true, isGap: false, totalTokens: tokens, costUSD: cost,
            projection: CCBlockProjection(totalCost: projected ?? cost),
            tokenLimitStatus: nil
        ))
    }

    static func snapshot(_ daily: [PeriodRow], block: BlockStat? = nil) -> UsageSnapshot {
        var snapshot = UsageSnapshot(
            fetchedAt: now, report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
            activeBlock: block, codexQuota: nil, claudeQuota: nil, calendar: calendar
        )
        snapshot.daily = daily
        return snapshot
    }
}
