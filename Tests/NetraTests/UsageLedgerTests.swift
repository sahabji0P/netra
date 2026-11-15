import XCTest
@testable import Netra

/// The recorded usage history: what survives when an agent's session logs
/// are deleted or compressed, and how much of the logs each refresh reads.
final class UsageLedgerTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func agent(_ name: String, tokens: Int, cost: Double, model: String = "model-a") -> AgentStat {
        AgentStat(
            name: name, cost: cost, totalTokens: tokens, inputTokens: tokens, outputTokens: 0,
            cacheReadTokens: 0,
            models: [ModelStat(name: model, cost: cost, totalTokens: tokens, inputTokens: tokens,
                               outputTokens: 0, cacheReadTokens: 0)]
        )
    }

    private func report(_ days: [String: [(agent: String, tokens: Int, cost: Double)]]) -> CCUnifiedReport {
        CCUnifiedReport(
            daily: days.keys.sorted().map { day in
                let agents = (days[day] ?? []).map {
                    CCAgentRow(agent: $0.agent, inputTokens: $0.tokens, outputTokens: 0, cacheCreationTokens: 0,
                               cacheReadTokens: 0, totalTokens: $0.tokens, totalCost: $0.cost, modelBreakdowns: [])
                }
                return CCRow(
                    period: day, inputTokens: agents.reduce(0) { $0 + $1.inputTokens }, outputTokens: 0,
                    cacheCreationTokens: 0, cacheReadTokens: 0,
                    totalTokens: agents.reduce(0) { $0 + $1.totalTokens },
                    totalCost: agents.reduce(0) { $0 + $1.totalCost }, agents: agents, modelBreakdowns: []
                )
            },
            weekly: [], monthly: []
        )
    }

    // MARK: What a reading may change

    func testADayWhoseLogsWereDeletedKeepsItsRecordedUsage() {
        var history = UsageHistory()
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 1_000, cost: 4)])
        // The transcripts are gone: the day is missing, then partly present.
        history.record(day: "2026-09-11", agents: [agent("claude", tokens: 50, cost: 0.2)])
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 300, cost: 1.2)])
        XCTAssertEqual(history.days["2026-09-10"]?.first?.totalTokens, 1_000)
        XCTAssertEqual(history.days["2026-09-10"]?.first?.cost, 4)
        XCTAssertEqual(history.days["2026-09-11"]?.first?.totalTokens, 50)
    }

    func testGrowthAndRepricingReplaceTheRecordedEntry() {
        var history = UsageHistory()
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 1_000, cost: 0)])
        // Same tokens, now priced: the model was missing from the price table.
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 1_000, cost: 4)])
        XCTAssertEqual(history.days["2026-09-10"]?.first?.cost, 4)
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 1_500, cost: 6)])
        XCTAssertEqual(history.days["2026-09-10"]?.first?.totalTokens, 1_500)
        XCTAssertEqual(history.days["2026-09-10"]?.first?.cost, 6)
    }

    func testAnAgentMissingFromAReadingIsKeptBesideTheOthers() {
        var history = UsageHistory()
        history.record(day: "2026-09-10", agents: [
            agent("claude", tokens: 1_000, cost: 4), agent("codex", tokens: 700, cost: 2),
        ])
        // Codex archived its rollouts; Claude kept working.
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 1_200, cost: 5)])
        let day = Dictionary(uniqueKeysWithValues: (history.days["2026-09-10"] ?? []).map { ($0.name, $0.totalTokens) })
        XCTAssertEqual(day, ["claude": 1_200, "codex": 700])
    }

    func testReadingsWithoutUsageRecordNothing() {
        var history = UsageHistory()
        history.record(day: "2026-09-10", agents: [agent("claude", tokens: 0, cost: 0)])
        XCTAssertTrue(history.days.isEmpty)
    }

    // MARK: Rebuilding rows

    func testRecentScanLeavesOlderDaysInTheSnapshot() throws {
        var history = UsageHistory()
        history.record(report([
            "2026-08-30": [("claude", 100, 1)],
            "2026-09-01": [("claude", 200, 2), ("codex", 50, 0.5)],
            "2026-09-10": [("claude", 300, 3)],
        ]), calendar: utc)
        // A later refresh reads only the trailing days.
        history.record(report(["2026-09-10": [("claude", 400, 4)], "2026-09-11": [("claude", 10, 0.1)]]), calendar: utc)

        let snapshot = UsageSnapshot(
            fetchedAt: .now, daily: history.rows(calendar: utc), activeBlock: nil,
            codexQuota: nil, claudeQuota: nil, calendar: utc
        )
        XCTAssertEqual(snapshot.daily.map(\.period), ["2026-08-30", "2026-09-01", "2026-09-10", "2026-09-11"])
        XCTAssertEqual(snapshot.monthly.map(\.period), ["2026-08", "2026-09"])
        let september = try XCTUnwrap(snapshot.monthly.last)
        XCTAssertEqual(september.totalTokens, 200 + 50 + 400 + 10)
        XCTAssertEqual(september.cost, 2 + 0.5 + 4 + 0.1, accuracy: 0.000_001)
        XCTAssertEqual(september.agentStat("codex")?.totalTokens, 50)
        // Aug 30 is a Sunday and Sept 1 a Tuesday: two Monday-keyed weeks.
        XCTAssertEqual(snapshot.weekly.map(\.period), ["2026-08-24", "2026-08-31", "2026-09-07"])
        XCTAssertEqual(snapshot.weekly.map(\.totalTokens), [100, 250, 410])
    }

    func testUnattributedUsageSurvivesRecording() throws {
        // A row whose totals exceed its agents': the remainder is "other".
        let claude = CCAgentRow(agent: "claude", inputTokens: 60, outputTokens: 0, cacheCreationTokens: 0,
                                cacheReadTokens: 0, totalTokens: 60, totalCost: 1, modelBreakdowns: [])
        let row = CCRow(period: "2026-09-10", inputTokens: 100, outputTokens: 0, cacheCreationTokens: 0,
                        cacheReadTokens: 0, totalTokens: 100, totalCost: 1.5, agents: [claude], modelBreakdowns: [])
        var history = UsageHistory()
        history.record(CCUnifiedReport(daily: [row], weekly: [], monthly: []), calendar: utc)

        let rebuilt = try XCTUnwrap(history.rows(calendar: utc).first)
        XCTAssertEqual(rebuilt.totalTokens, 100)
        XCTAssertEqual(rebuilt.cost, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(rebuilt.agents.map(\.name), ["claude"])
        XCTAssertEqual(rebuilt.unattributed?.totalTokens, 40)
        XCTAssertEqual(try XCTUnwrap(rebuilt.unattributed).cost, 0.5, accuracy: 0.000_001)
    }

    func testCursorDaysOutliveCursorsEventWindow() {
        let old = ISODate.parse("2026-03-01T10:00:00Z")!, recent = ISODate.parse("2026-09-10T10:00:00Z")!
        var history = UsageHistory()
        history.record(
            CCUnifiedReport(daily: [], weekly: [], monthly: []),
            cursorEvents: [
                CursorUsageEvent(recordedAt: old, model: "composer-2.5", inputTokens: 500, costCents: 20),
                CursorUsageEvent(recordedAt: recent, model: "composer-2.5", inputTokens: 100, costCents: 5),
            ],
            calendar: utc
        )
        // The event store has trimmed the March event from its rolling window.
        history.record(
            CCUnifiedReport(daily: [], weekly: [], monthly: []),
            cursorEvents: [CursorUsageEvent(recordedAt: recent, model: "composer-2.5", inputTokens: 100, costCents: 5)],
            calendar: utc
        )
        XCTAssertEqual(history.days["2026-03-01"]?.first?.totalTokens, 500)
        XCTAssertEqual(history.days["2026-09-10"]?.first?.name, "cursor")
    }

    // MARK: Which scan runs

    func testCompleteScanSeedsFollowsUpgradesAndRepeatsDaily() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var history = UsageHistory()
        XCTAssertEqual(UsageScan.next(engine: "20.0.51", history: history, now: now), .complete)

        history.engine = "20.0.51"
        history.completeScanAt = now
        XCTAssertEqual(UsageScan.next(engine: "20.0.51", history: history, now: now.addingTimeInterval(60)), .recent)
        XCTAssertEqual(UsageScan.next(engine: "20.0.52", history: history, now: now.addingTimeInterval(60)), .complete)
        XCTAssertEqual(
            UsageScan.next(engine: "20.0.51", history: history, now: now.addingTimeInterval(UsageScan.completeInterval)),
            .complete
        )
        // The version could not be read: keep to the daily schedule.
        XCTAssertEqual(UsageScan.next(engine: nil, history: history, now: now.addingTimeInterval(60)), .recent)
        // The clock moved back: do not wait a day past the stale stamp.
        XCTAssertEqual(UsageScan.next(engine: "20.0.51", history: history, now: now.addingTimeInterval(-3600)), .complete)
    }

    // MARK: Persistence

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("netra-ledger-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }

    func testHistoryPersistsAcrossLaunchesAndMarksCompleteScans() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = UsageLedger(fileURL: file)
        _ = await first.record(
            report(["2026-09-01": [("claude", 200, 2)]]), cursorEvents: [],
            complete: true, engine: "20.0.51", now: now, calendar: utc
        )

        // Next launch: the logs for Sept 1 are gone and only today is read.
        let second = UsageLedger(fileURL: file)
        let rows = await second.record(
            report(["2026-09-10": [("claude", 300, 3)]]), cursorEvents: [],
            complete: false, engine: "20.0.51", now: now.addingTimeInterval(60), calendar: utc
        )
        XCTAssertEqual(rows.map(\.period), ["2026-09-01", "2026-09-10"])
        let history = await second.current()
        XCTAssertEqual(history.engine, "20.0.51")
        XCTAssertEqual(history.completeScanAt, now)
    }

    func testUnchangedHistoryIsNotRewritten() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ledger = UsageLedger(fileURL: file)
        let reading = report(["2026-09-01": [("claude", 200, 2)]])
        _ = await ledger.record(reading, cursorEvents: [], complete: false, engine: nil, calendar: utc)
        try FileManager.default.removeItem(at: file)
        _ = await ledger.record(reading, cursorEvents: [], complete: false, engine: nil, calendar: utc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnreadableHistoryIsSetAsideNotOverwritten() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: file)

        let ledger = UsageLedger(fileURL: file)
        let rows = await ledger.record(
            report(["2026-09-10": [("claude", 300, 3)]]), cursorEvents: [],
            complete: false, engine: nil, calendar: utc
        )
        XCTAssertEqual(rows.map(\.period), ["2026-09-10"])
        let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        XCTAssertNoThrow(try JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: file)))
    }
}
