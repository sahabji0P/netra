import XCTest
@testable import Netra

/// Contract tests for `netra.usage-feed/1` (portfolio-v2 `docs/usage-feed.md`).
/// All figures are synthetic.
final class UsageFeedTests: XCTestCase {
    private func model(_ name: String, input: Int, output: Int, read: Int, write: Int, cost: Double) -> ModelStat {
        ModelStat(name: name, cost: cost, totalTokens: input + output + read + write,
                  inputTokens: input, outputTokens: output, cacheCreationTokens: write, cacheReadTokens: read)
    }

    private func agent(_ name: String, input: Int, output: Int, read: Int, write: Int,
                       total: Int? = nil, cost: Double, models: [ModelStat]) -> AgentStat {
        AgentStat(name: name, cost: cost, totalTokens: total ?? (input + output + read + write),
                  inputTokens: input, outputTokens: output, cacheCreationTokens: write,
                  cacheReadTokens: read, models: models)
    }

    private func row(_ period: String, _ agents: [AgentStat], extra: (tokens: Int, cost: Double) = (0, 0)) -> PeriodRow {
        let date = PeriodKeys.formatter("yyyy-MM-dd", utc).date(from: period)!
        return PeriodRow(
            period: period, date: date,
            cost: agents.reduce(0) { $0 + $1.cost } + extra.cost,
            inputTokens: agents.reduce(0) { $0 + $1.inputTokens } + extra.tokens,
            outputTokens: agents.reduce(0) { $0 + $1.outputTokens },
            cacheCreationTokens: agents.reduce(0) { $0 + $1.cacheCreationTokens },
            cacheReadTokens: agents.reduce(0) { $0 + $1.cacheReadTokens },
            totalTokens: agents.reduce(0) { $0 + $1.totalTokens } + extra.tokens,
            agents: agents, models: agents.flatMap(\.models)
        )
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let fetchedAt = Date(timeIntervalSince1970: 1_790_140_467) // 2026-09-23T05:14:27Z

    private func snapshot(_ daily: [PeriodRow]) -> UsageSnapshot {
        var snapshot = UsageSnapshot(
            fetchedAt: fetchedAt, report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
            activeBlock: nil, codexQuota: nil, claudeQuota: nil
        )
        snapshot.daily = daily
        return snapshot
    }

    private func assertInvariants(_ feed: UsageFeed, file: StaticString = #filePath, line: UInt = #line) {
        for day in feed.daily {
            for (id, agent) in day.agents {
                XCTAssertEqual(agent.tokens, agent.input + agent.output + agent.cacheRead + agent.cacheWrite,
                               "\(day.date) \(id) tokens", file: file, line: line)
                let models = agent.models.values
                XCTAssertEqual(models.reduce(0) { $0 + $1.input }, agent.input, "\(id) input", file: file, line: line)
                XCTAssertEqual(models.reduce(0) { $0 + $1.output }, agent.output, "\(id) output", file: file, line: line)
                XCTAssertEqual(models.reduce(0) { $0 + $1.cacheRead }, agent.cacheRead, file: file, line: line)
                XCTAssertEqual(models.reduce(0) { $0 + $1.cacheWrite }, agent.cacheWrite, file: file, line: line)
                XCTAssertEqual(models.reduce(0) { $0 + $1.tokens }, agent.tokens, file: file, line: line)
                XCTAssertEqual(models.reduce(0) { $0 + $1.cost }, agent.cost, accuracy: 1e-9, file: file, line: line)
                for (name, figures) in agent.models {
                    XCTAssertEqual(figures.tokens, figures.input + figures.output + figures.cacheRead + figures.cacheWrite,
                                   "\(id)/\(name) tokens", file: file, line: line)
                    XCTAssertGreaterThanOrEqual(figures.cost, 0, file: file, line: line)
                }
            }
        }
    }

    func testMapsSnapshotToContractShape() throws {
        let claude = agent("claude", input: 8, output: 5316, read: 244_611, write: 67_140, cost: 0.69, models: [
            model("claude-test-model", input: 8, output: 5316, read: 244_611, write: 67_140, cost: 0.69),
        ])
        let feed = UsageFeed.build(from: snapshot([row("2026-09-22", [claude])]), version: "9.9.9", calendar: utc)

        XCTAssertEqual(feed.schema, "netra.usage-feed/1")
        XCTAssertEqual(feed.generatedAt, "2026-09-23T05:14:27Z")
        XCTAssertEqual(feed.source, "netra 9.9.9")
        XCTAssertEqual(feed.timeZone, utc.timeZone.identifier) // Foundation names UTC "GMT"
        XCTAssertNotNil(TimeZone(identifier: feed.timeZone))
        XCTAssertEqual(feed.daily.map(\.date), ["2026-09-22"])
        let entry = try XCTUnwrap(feed.daily.first?.agents["claude"])
        XCTAssertEqual(entry.input, 8)
        XCTAssertEqual(entry.output, 5316)
        XCTAssertEqual(entry.cacheRead, 244_611)
        XCTAssertEqual(entry.cacheWrite, 67_140)
        XCTAssertEqual(entry.tokens, 317_075)
        XCTAssertEqual(entry.cost, 0.69, accuracy: 1e-9)
        XCTAssertEqual(entry.models["claude-test-model"]?.tokens, 317_075)
        assertInvariants(feed)

        // Wire format: the contract's key names, nothing else.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: feed.encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "generatedAt", "source", "timeZone", "daily"])
        let day = try XCTUnwrap((object["daily"] as? [[String: Any]])?.first)
        let wireAgent = try XCTUnwrap((day["agents"] as? [String: Any])?["claude"] as? [String: Any])
        XCTAssertEqual(Set(wireAgent.keys), ["input", "output", "cacheRead", "cacheWrite", "tokens", "cost", "models"])
        XCTAssertTrue(String(decoding: try feed.encoded(), as: UTF8.self).contains("\"netra.usage-feed/1\""))
    }

    func testTokensAreRecomputedFromPartsWhenTotalDisagrees() throws {
        // ccusage can report a totalTokens above the four parts (e.g. reasoning).
        let opencode = agent("opencode", input: 100, output: 50, read: 1000, write: 0, total: 1_200, cost: 0.1, models: [
            model("test-model", input: 100, output: 50, read: 1000, write: 0, cost: 0.1),
        ])
        let feed = UsageFeed.build(from: snapshot([row("2026-09-22", [opencode])]), version: "t", calendar: utc)
        XCTAssertEqual(feed.daily.first?.agents["opencode"]?.tokens, 1_150)
        assertInvariants(feed)
    }

    func testUnaccountedAgentPartsGoToUnknownModel() throws {
        let codex = agent("codex", input: 500, output: 200, read: 3000, write: 10, cost: 2.0, models: [
            model("test-model-a", input: 300, output: 150, read: 2000, write: 0, cost: 1.2),
        ])
        let bare = agent("pi", input: 40, output: 4, read: 0, write: 0, cost: 0.01, models: [])
        let feed = UsageFeed.build(from: snapshot([row("2026-09-22", [codex, bare])]), version: "t", calendar: utc)

        let day = try XCTUnwrap(feed.daily.first)
        let unknown = try XCTUnwrap(day.agents["codex"]?.models["unknown"])
        XCTAssertEqual(unknown.input, 200)
        XCTAssertEqual(unknown.output, 50)
        XCTAssertEqual(unknown.cacheRead, 1000)
        XCTAssertEqual(unknown.cacheWrite, 10)
        XCTAssertEqual(unknown.cost, 0.8, accuracy: 1e-9)
        XCTAssertEqual(day.agents["codex"]?.tokens, 3710)
        XCTAssertEqual(day.agents["pi"]?.models.keys.sorted(), ["unknown"])
        XCTAssertEqual(day.agents["pi"]?.tokens, 44)
        assertInvariants(feed)
    }

    func testModelsThatOvercountRaiseTheAgentInsteadOfDroppingTokens() throws {
        let cursor = agent("cursor", input: 10, output: 10, read: 0, write: 0, cost: 0.5, models: [
            model("test-model", input: 15, output: 10, read: 0, write: 0, cost: 0.5),
        ])
        let feed = UsageFeed.build(from: snapshot([row("2026-09-22", [cursor])]), version: "t", calendar: utc)
        XCTAssertEqual(feed.daily.first?.agents["cursor"]?.input, 15)
        XCTAssertNil(feed.daily.first?.agents["cursor"]?.models["unknown"])
        assertInvariants(feed)
    }

    func testUnattributedRowTotalsBecomeOtherAgent() throws {
        let claude = agent("claude", input: 1, output: 1, read: 0, write: 0, cost: 0.01, models: [
            model("test-model", input: 1, output: 1, read: 0, write: 0, cost: 0.01),
        ])
        let feed = UsageFeed.build(
            from: snapshot([row("2026-09-22", [claude], extra: (tokens: 70, cost: 0.02))]),
            version: "t", calendar: utc
        )
        let other = try XCTUnwrap(feed.daily.first?.agents["other"])
        XCTAssertEqual(other.input, 70)
        XCTAssertEqual(other.tokens, 70)
        XCTAssertEqual(other.cost, 0.02, accuracy: 1e-9)
        XCTAssertEqual(feed.totalTokens, 72)
        assertInvariants(feed)
    }

    func testDaysAreLocalCalendarDaysInTheBucketingTimeZone() throws {
        // A snapshot built the way UsageStore builds it, bucketed in Kolkata.
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let model = CCModelBreakdown(modelName: "test-model", cost: 0.3, inputTokens: 1, outputTokens: 2,
                                     cacheCreationTokens: 3, cacheReadTokens: 4)
        func ccRow(_ period: String) -> CCRow {
            CCRow(period: period, inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4,
                  totalTokens: 10, totalCost: 0.3,
                  agents: [CCAgentRow(agent: "claude", inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3,
                                      cacheReadTokens: 4, totalTokens: 10, totalCost: 0.3, modelBreakdowns: [model])],
                  modelBreakdowns: [model])
        }
        let report = CCUnifiedReport(daily: [ccRow("2026-09-29"), ccRow("2026-09-28")], weekly: [], monthly: [])
        // 00:30 on the 29th in Kolkata is still the 28th in UTC.
        let fetched = ISODate.parse("2026-09-28T19:00:00Z")!
        let snapshot = UsageSnapshot(fetchedAt: fetched, report: report, activeBlock: nil,
                                     codexQuota: nil, claudeQuota: nil, calendar: kolkata)

        let feed = UsageFeed.build(from: snapshot, version: "t", calendar: kolkata)
        XCTAssertEqual(feed.timeZone, "Asia/Kolkata")
        XCTAssertEqual(feed.daily.map(\.date), ["2026-09-28", "2026-09-29"], "oldest first, local days")
        XCTAssertEqual(feed.generatedAt, "2026-09-28T19:00:00Z", "generatedAt is UTC")
        assertInvariants(feed)
    }

    func testEncodingIsDeterministicRegardlessOfSourceOrder() throws {
        let a = agent("claude", input: 1, output: 2, read: 3, write: 4, cost: 0.1, models: [
            model("test-model-a", input: 1, output: 1, read: 3, write: 4, cost: 0.05),
            model("test-model-b", input: 0, output: 1, read: 0, write: 0, cost: 0.05),
        ])
        let b = agent("codex", input: 5, output: 6, read: 7, write: 0, cost: 0.2, models: [
            model("test-model-c", input: 5, output: 6, read: 7, write: 0, cost: 0.2),
        ])
        var reversedA = a
        reversedA.models.reverse()
        let first = UsageFeed.build(
            from: snapshot([row("2026-09-21", [a, b]), row("2026-09-22", [b])]), version: "t", calendar: utc)
        let second = UsageFeed.build(
            from: snapshot([row("2026-09-22", [b]), row("2026-09-21", [b, reversedA])]), version: "t", calendar: utc)
        XCTAssertEqual(try first.encoded(), try second.encoded())
        XCTAssertEqual(first.daily.map(\.date), ["2026-09-21", "2026-09-22"])
        XCTAssertEqual(first.contentHash(), second.contentHash())
    }

    func testCostSumsDoNotDependOnModelOrder() throws {
        // Enough models that dictionary iteration order differs from input
        // order; float sums must still be byte-identical.
        let models = (1...40).map {
            model("test-model-\($0)", input: $0, output: 0, read: 0, write: 0, cost: 0.1 * Double($0) + 0.000_3)
        }
        let cost = models.reduce(0) { $0 + $1.cost } + 0.7
        let forward = agent("claude", input: 900, output: 0, read: 0, write: 0, cost: cost, models: models)
        var backward = forward
        backward.models.reverse()
        let a = UsageFeed.build(from: snapshot([row("2026-09-22", [forward])]), version: "t", calendar: utc)
        let b = UsageFeed.build(from: snapshot([row("2026-09-22", [backward])]), version: "t", calendar: utc)
        XCTAssertEqual(try a.encoded(), try b.encoded())
        assertInvariants(a)
    }

    func testContentHashIgnoresGeneratedAtOnly() throws {
        let a = agent("claude", input: 1, output: 2, read: 3, write: 4, cost: 0.1, models: [
            model("test-model", input: 1, output: 2, read: 3, write: 4, cost: 0.1),
        ])
        let feed = UsageFeed.build(from: snapshot([row("2026-09-22", [a])]), version: "t", calendar: utc)
        var later = feed
        later.generatedAt = "2030-01-01T00:00:00Z"
        XCTAssertEqual(feed.contentHash(), later.contentHash())
        var changed = feed
        changed.daily[0].agents["claude"]?.output += 1
        XCTAssertNotEqual(feed.contentHash(), changed.contentHash())
    }

    func testEmptySnapshotProducesEmptyDaily() {
        let feed = UsageFeed.build(from: snapshot([]), version: "t", calendar: utc)
        XCTAssertEqual(feed.daily, [])
        XCTAssertEqual(feed.totalTokens, 0)
    }
}

final class UsageFeedFileTests: XCTestCase {
    func testWritesDeterministicFeedAtomicallyToTheGivenURL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetraTests.UsageFeedFile.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/usage-feed.json")
        let snapshot = UsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 0), report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
            activeBlock: nil, codexQuota: nil, claudeQuota: nil
        )

        let feed = await UsageFeedFile(url: url).write(snapshot, version: "t")
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, try feed.encoded())
        XCTAssertEqual(try JSONDecoder().decode(UsageFeed.self, from: written), feed)
        XCTAssertEqual(feed.generatedAt, "1970-01-01T00:00:00Z")
    }
}
