import XCTest
@testable import Netra

final class CursorUsageEventsTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    private static func event(_ iso: String, _ model: String = "composer-2.5", input: Int = 10, cents: Double = 1) -> CursorUsageEvent {
        CursorUsageEvent(
            recordedAt: ISODate.parse(iso)!, model: model,
            inputTokens: input, costCents: cents
        )
    }

    // MARK: Contract: get-filtered-usage-events

    func testEventsPageMapsLiveShape() throws {
        let page = try XCTUnwrap(CursorUsageEvents.page(from: fixture("cursor-filtered-usage-events.json")))
        XCTAssertEqual(page.totalCount, 4)
        XCTAssertEqual(page.rawCount, 4)
        XCTAssertEqual(page.events.count, 4)

        let first = page.events[0]
        XCTAssertEqual(first.recordedAt, Date(timeIntervalSince1970: 1_790_330_400))
        XCTAssertEqual(first.model, "composer-2.5")
        XCTAssertEqual(first.conversationID, "conv-synthetic-1")
        XCTAssertEqual(first.costCents, 4.75, accuracy: 0.000_001)
        XCTAssertTrue(first.priced)
        // Cursor's input excludes cache, so all four parts add up.
        XCTAssertEqual(CursorUsageEvents.tokenParts(of: first).total, 170)

        // String counts decode; a missing cacheWriteTokens is zero.
        XCTAssertEqual(page.events[1].inputTokens, 200)
        XCTAssertEqual(page.events[1].cacheWriteTokens, 0)

        // A request-billed call has no tokenUsage: kept, but flagged unpriced.
        XCTAssertFalse(page.events[2].priced)
        XCTAssertEqual(CursorUsageEvents.tokenParts(of: page.events[2]).total, 0)
    }

    func testEmptyObjectIsAValidEmptyPageButErrorEnvelopeIsNot() {
        XCTAssertEqual(CursorUsageEvents.page(from: Data("{}".utf8))?.events.count, 0)
        XCTAssertNil(CursorUsageEvents.page(from: Data(#"{"error":"unauthorized"}"#.utf8)))
    }

    // MARK: Pagination

    func testPaginationDedupesPageBoundaryRepeats() async throws {
        let pages = [
            Data(#"{"totalUsageEventsCount":3,"usageEventsDisplay":[{"timestamp":"3000","model":"a","tokenUsage":{"inputTokens":1,"totalCents":1}},{"timestamp":"2000","model":"a","tokenUsage":{"inputTokens":1,"totalCents":1}}]}"#.utf8),
            // A new event arrived mid-scan: "2000" shifts onto page 2.
            Data(#"{"totalUsageEventsCount":4,"usageEventsDisplay":[{"timestamp":"2000","model":"a","tokenUsage":{"inputTokens":1,"totalCents":1}},{"timestamp":"1000","model":"a","tokenUsage":{"inputTokens":1,"totalCents":1}}]}"#.utf8),
        ]
        let counter = PageCounter()
        let result = try await CursorUsageEventsFetcher.fetch(since: .distantPast, until: .now, pageSize: 2) { body in
            let page = await counter.next()
            XCTAssertEqual(body["page"] as? Int, page)
            XCTAssertTrue(body["startDate"] is String, "dates are sent as ms strings")
            return pages[page - 1]
        }
        XCTAssertEqual(result.events.map(\.recordedAt.timeIntervalSince1970), [3, 2, 1])
        XCTAssertEqual(result.reportedCount, 3)
        let pagesRequested = await counter.count
        XCTAssertEqual(pagesRequested, 2)
    }

    func testShortScanThrowsInsteadOfPublishingPartialTotals() async {
        let page = Data(#"{"totalUsageEventsCount":5,"usageEventsDisplay":[{"timestamp":"3000","model":"a"}]}"#.utf8)
        do {
            _ = try await CursorUsageEventsFetcher.fetch(since: .distantPast, until: .now) { _ in page }
            XCTFail("an incomplete scan must throw")
        } catch CursorUsageEventsFetcher.SyncError.incomplete(let received, let reported) {
            XCTAssertEqual(received, 1)
            XCTAssertEqual(reported, 5)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Aggregation

    func testDailyBucketsCarryApiRateCost() throws {
        let page = try XCTUnwrap(CursorUsageEvents.page(from: fixture("cursor-filtered-usage-events.json")))
        let daily = CursorUsageEvents.agentStats(from: page.events, granularity: .day, calendar: utc)
        XCTAssertEqual(daily.map(\.period), ["2026-09-24", "2026-09-25"])
        let day = try XCTUnwrap(daily.last?.agent)
        XCTAssertEqual(day.name, "cursor")
        XCTAssertEqual(day.totalTokens, 170 + 1230)
        XCTAssertEqual(day.cost, 0.06, accuracy: 0.000_001)
        XCTAssertEqual(day.models.map(\.name), ["composer-2.5", "default"])
        XCTAssertEqual(day.models[0].cost, 0.0475, accuracy: 0.000_001)
    }

    func testSnapshotMergesCursorIntoExistingDayWithCost() throws {
        let report = CCUnifiedReport(
            daily: [CCRow(
                period: "2026-09-25", inputTokens: 10, outputTokens: 5,
                cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 15,
                totalCost: 1.5,
                agents: [CCAgentRow(
                    agent: "claude", inputTokens: 10, outputTokens: 5,
                    cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 15,
                    totalCost: 1.5, modelBreakdowns: []
                )],
                modelBreakdowns: []
            )],
            weekly: [], monthly: []
        )
        let page = try XCTUnwrap(CursorUsageEvents.page(from: fixture("cursor-filtered-usage-events.json")))
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_790_400_000),
            report: report, activeBlock: nil, codexQuota: nil, claudeQuota: nil,
            cursorEvents: page.events, calendar: utc
        )
        let day = try XCTUnwrap(snapshot.daily.first { $0.period == "2026-09-25" })
        XCTAssertEqual(Set(day.agents.map(\.name)), ["claude", "cursor"])
        XCTAssertEqual(day.totalTokens, 15 + 1400)
        XCTAssertEqual(day.cost, 1.56, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.daily.map(\.period), ["2026-09-24", "2026-09-25"])
    }

    /// ccusage keys weeks by Monday regardless of locale. A Sunday-first
    /// calendar (e.g. en_IN) must not open a separate Cursor-only week.
    func testWeeklyBucketsUseMondayWeeksLikeCcusage() throws {
        var sundayFirst = utc
        sundayFirst.firstWeekday = 1
        let events = [
            Self.event("2026-09-20T12:00:00Z", input: 10),
            Self.event("2026-09-21T12:00:00Z", input: 20),
            Self.event("2026-09-27T12:00:00Z", input: 40),
        ]
        let weekly = CursorUsageEvents.agentStats(from: events, granularity: .week, calendar: sundayFirst)
        XCTAssertEqual(weekly.map(\.period), ["2026-09-14", "2026-09-21"])
        XCTAssertEqual(weekly.map(\.agent.totalTokens), [10, 60])

        let report = CCUnifiedReport(
            daily: [],
            weekly: [CCRow(
                period: "2026-09-21", inputTokens: 5, outputTokens: 0,
                cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 5, totalCost: 1,
                agents: [CCAgentRow(
                    agent: "claude", inputTokens: 5, outputTokens: 0,
                    cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 5,
                    totalCost: 1, modelBreakdowns: []
                )],
                modelBreakdowns: []
            )],
            monthly: []
        )
        let snapshot = UsageSnapshot(
            fetchedAt: .now, report: report, activeBlock: nil, codexQuota: nil, claudeQuota: nil,
            cursorEvents: events, calendar: sundayFirst
        )
        let current = try XCTUnwrap(snapshot.weekly.last)
        XCTAssertEqual(current.period, "2026-09-21")
        XCTAssertEqual(current.totalTokens, 65)
        XCTAssertEqual(Set(current.agents.map(\.name)), ["claude", "cursor"])
    }

    func testUnpricedCursorCostRendersAsNotEstimated() {
        XCTAssertEqual(Format.providerCost("cursor", cost: 0, tokens: 1_000), "—")
        XCTAssertEqual(Format.providerCost("cursor", cost: 0, tokens: 0), "$0.00")
        XCTAssertEqual(Format.providerCost("claude", cost: 0, tokens: 1_000), "—", "any provider: tokens at $0 = no price")
        XCTAssertEqual(Format.providerCost("claude", cost: 0.42, tokens: 1_000), "$0.42")
    }

    // MARK: Incremental store

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("netra-cursor-events-\(UUID().uuidString).json")
    }

    func testStoreBackfillsThenRefetchesOnlyTheTrailingDay() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = ISODate.parse("2026-09-26T12:00:00Z")!
        let calls = RangeRecorder()

        let store = CursorEventStore(fileURL: url)
        let first = await store.refreshed(now: now) { since, until in
            await calls.record(since, until)
            return .init(events: [Self.event("2026-09-20T10:00:00Z"), Self.event("2026-09-26T10:00:00Z")], reportedCount: 2)
        }
        XCTAssertEqual(first.count, 2)
        let firstRanges = await calls.ranges
        let backfill = try XCTUnwrap(firstRanges.first)
        XCTAssertEqual(backfill.since, now.addingTimeInterval(-190 * 86400))

        // Within the minimum interval: no network, cached history.
        let cached = await store.refreshed(now: now.addingTimeInterval(60)) { _, _ in
            XCTFail("must not refetch inside the minimum interval")
            return .init(events: [], reportedCount: 0)
        }
        XCTAssertEqual(cached.count, 2)

        // Next sync refetches from syncedAt − 24h and replaces that slice.
        let later = now.addingTimeInterval(20 * 60)
        let second = await store.refreshed(now: later) { since, until in
            await calls.record(since, until)
            return .init(events: [Self.event("2026-09-26T10:00:00Z"), Self.event("2026-09-26T12:10:00Z")], reportedCount: 2)
        }
        let allRanges = await calls.ranges
        let incremental = try XCTUnwrap(allRanges.last)
        XCTAssertEqual(incremental.since, now.addingTimeInterval(-86400))
        XCTAssertEqual(second.count, 3, "the refetched slice replaces, never duplicates")

        // A fresh store instance reads the persisted history.
        let reopened = await CursorEventStore(fileURL: url).refreshed(now: later.addingTimeInterval(60)) { _, _ in
            XCTFail("persisted syncedAt must be honoured")
            return .init(events: [], reportedCount: 0)
        }
        XCTAssertEqual(reopened.count, 3)
    }

    func testStoreKeepsHistoryAndBacksOffOnAuthRejection() async {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = ISODate.parse("2026-09-26T12:00:00Z")!
        let store = CursorEventStore(fileURL: url)
        _ = await store.refreshed(now: now) { _, _ in
            .init(events: [Self.event("2026-09-26T10:00:00Z")], reportedCount: 1)
        }
        let rejected = await store.refreshed(now: now.addingTimeInterval(20 * 60)) { _, _ in
            throw CursorUsageFetcher.CursorUsageError.http(403)
        }
        XCTAssertEqual(rejected.count, 1, "a failed sync keeps the last history")
        let cooling = await store.refreshed(now: now.addingTimeInterval(3 * 3600)) { _, _ in
            XCTFail("403 must back off for six hours")
            return .init(events: [], reportedCount: 0)
        }
        XCTAssertEqual(cooling.count, 1)
    }

    // MARK: Persistence

    func testLegacyCursorQuotaCacheStillDecodes() throws {
        let legacy = CursorQuota(
            windows: [QuotaWindow(label: "included usage", usedPercent: 12.5, resetsAt: nil)],
            planType: "Pro",
            fetchedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "models")
        object.removeValue(forKey: "inputTokens")
        object.removeValue(forKey: "usageValueUSD")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CursorQuota.self, from: data)
        XCTAssertEqual(decoded.planType, "Pro")
        XCTAssertTrue(decoded.models.isEmpty)
        XCTAssertEqual(decoded.totalTokens, 0)
        XCTAssertNil(decoded.usageValueUSD)
    }
}

private actor PageCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}

private actor RangeRecorder {
    var ranges: [(since: Date, until: Date)] = []
    func record(_ since: Date, _ until: Date) { ranges.append((since, until)) }
}
