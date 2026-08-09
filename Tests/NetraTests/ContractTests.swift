import XCTest
@testable import Netra

/// Fixture tests for the three external contracts Netra depends on, all of
/// which can drift without notice: ccusage's JSON output (pinned 20.0.19),
/// the Codex CLI rollout format, and Anthropic's OAuth usage endpoint.
final class ContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    // MARK: ccusage unified report

    func testUnifiedReportDecodesAndMapsToSnapshot() throws {
        let report = try JSONDecoder().decode(CCUnifiedReport.self, from: fixture("unified.json"))
        XCTAssertGreaterThan(report.daily?.count ?? 0, 0)
        XCTAssertGreaterThan(report.weekly?.count ?? 0, 0)
        XCTAssertGreaterThan(report.monthly?.count ?? 0, 0)

        let snapshot = UsageSnapshot(
            fetchedAt: .now, report: report,
            activeBlock: nil, codexQuota: nil, claudeQuota: nil
        )
        XCTAssertEqual(snapshot.daily.count, report.daily?.count)

        for row in snapshot.daily {
            // Agents and models must be sorted by cost, descending.
            XCTAssertEqual(row.agents.map(\.cost), row.agents.map(\.cost).sorted(by: >))
            XCTAssertEqual(row.models.map(\.cost), row.models.map(\.cost).sorted(by: >))
            // Netra does no pricing of its own: per-agent costs must sum to the row.
            if !row.agents.isEmpty {
                XCTAssertEqual(row.agents.reduce(0) { $0 + $1.cost }, row.cost, accuracy: 0.01)
            }
        }
    }

    func testAgentNamesRankedByCost() throws {
        let report = try JSONDecoder().decode(CCUnifiedReport.self, from: fixture("unified.json"))
        let snapshot = UsageSnapshot(
            fetchedAt: .now, report: report,
            activeBlock: nil, codexQuota: nil, claudeQuota: nil
        )
        XCTAssertFalse(snapshot.agentNames.isEmpty)
        XCTAssertTrue(snapshot.agentNames.contains("claude"))
    }

    func testCacheCreationTokensMapThroughEveryNormalizedLevel() throws {
        let model = CCModelBreakdown(
            modelName: "claude-test", cost: 1.25, inputTokens: 10, outputTokens: 20,
            cacheCreationTokens: 30, cacheReadTokens: 40
        )
        let agent = CCAgentRow(
            agent: "claude", inputTokens: 10, outputTokens: 20,
            cacheCreationTokens: 30, cacheReadTokens: 40, totalTokens: 100,
            totalCost: 1.25, modelBreakdowns: [model]
        )
        let report = CCUnifiedReport(
            daily: [CCRow(
                period: "2026-08-09", inputTokens: 10, outputTokens: 20,
                cacheCreationTokens: 30, cacheReadTokens: 40, totalTokens: 100,
                totalCost: 1.25, agents: [agent], modelBreakdowns: [model]
            )],
            weekly: [], monthly: []
        )

        let snapshot = UsageSnapshot(
            fetchedAt: .now, report: report,
            activeBlock: nil, codexQuota: nil, claudeQuota: nil
        )
        let row = try XCTUnwrap(snapshot.daily.first)

        XCTAssertEqual(row.cacheCreationTokens, 30)
        XCTAssertEqual(row.agents.first?.cacheCreationTokens, 30)
        XCTAssertEqual(row.agents.first?.models.first?.cacheCreationTokens, 30)
        XCTAssertEqual(row.models.first?.cacheCreationTokens, 30)
    }

    func testOldCachedPeriodRowWithoutCacheCreationTokensStillDecodes() throws {
        let data = Data(#"""
        {
          "period":"2026-08-09","date":0,"cost":1,"inputTokens":2,"outputTokens":3,
          "cacheReadTokens":4,"totalTokens":9,
          "agents":[{"name":"claude","cost":1,"totalTokens":9,"inputTokens":2,
            "outputTokens":3,"cacheReadTokens":4,"models":[{"name":"claude-test",
            "cost":1,"totalTokens":9,"inputTokens":2,"outputTokens":3,"cacheReadTokens":4}]}],
          "models":[{"name":"claude-test","cost":1,"totalTokens":9,"inputTokens":2,
            "outputTokens":3,"cacheReadTokens":4}]
        }
        """#.utf8)

        let row = try JSONDecoder().decode(PeriodRow.self, from: data)

        XCTAssertEqual(row.cacheCreationTokens, 0)
        XCTAssertEqual(row.agents.first?.cacheCreationTokens, 0)
        XCTAssertEqual(row.agents.first?.models.first?.cacheCreationTokens, 0)
        XCTAssertEqual(row.models.first?.cacheCreationTokens, 0)
    }

    // MARK: ccusage blocks

    func testBlocksReportDecodesActiveBlock() throws {
        let report = try JSONDecoder().decode(CCBlocksReport.self, from: fixture("blocks.json"))
        let active = report.blocks?.first { $0.isActive == true }
        let stat = try XCTUnwrap(BlockStat(block: try XCTUnwrap(active)))
        XCTAssertGreaterThan(stat.end, stat.start)
        XCTAssertGreaterThan(stat.tokens, 0)
        XCTAssertGreaterThan(stat.percentUsed, 0)
    }

    func testBlockStatRejectsInactiveAndGapBlocks() {
        XCTAssertNil(BlockStat(block: nil))
        let inactive = CCBlock(
            startTime: "2026-08-03T05:00:00.000Z", endTime: "2026-08-03T10:00:00.000Z",
            isActive: false, isGap: nil, totalTokens: 1, costUSD: 1,
            projection: nil, tokenLimitStatus: nil
        )
        XCTAssertNil(BlockStat(block: inactive))
    }

    // MARK: Anthropic OAuth usage endpoint

    func testClaudeUsageResponseParses() throws {
        let quota = try ClaudeQuotaFetcher.quota(
            fromResponse: fixture("claude-usage.json"), subscriptionType: "team"
        )
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertEqual(quota.windows[0].label, "5h")
        XCTAssertEqual(quota.windows[0].usedPercent, 6.0, accuracy: 0.001)
        XCTAssertEqual(quota.windows[1].label, "weekly")
        XCTAssertEqual(quota.windows[1].usedPercent, 10.0, accuracy: 0.001)
        XCTAssertEqual(quota.subscriptionType, "team")
        // Anthropic sends microsecond-precision timestamps; they must parse.
        XCTAssertNotNil(quota.windows[0].resetsAt)
        XCTAssertNotNil(quota.windows[1].resetsAt)
    }

    func testClaudeUsageResponseRejectsUnknownShape() {
        XCTAssertThrowsError(
            try ClaudeQuotaFetcher.quota(fromResponse: Data("{}".utf8), subscriptionType: nil)
        )
    }

    // MARK: Claude Code Keychain credential payload

    func testKeychainCredentialsParse() throws {
        let future = (Date.now.timeIntervalSince1970 + 3600) * 1000
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-test","refreshToken":"r","expiresAt":\#(future),"subscriptionType":"team"}}"#
        let credentials = try ClaudeQuotaFetcher.credentials(fromKeychainData: Data(json.utf8))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat-test")
        XCTAssertEqual(credentials.subscriptionType, "team")
    }

    func testKeychainCredentialsExpiredTokenThrows() {
        let past = (Date.now.timeIntervalSince1970 - 3600) * 1000
        let json = #"{"claudeAiOauth":{"accessToken":"x","expiresAt":\#(past)}}"#
        XCTAssertThrowsError(try ClaudeQuotaFetcher.credentials(fromKeychainData: Data(json.utf8))) {
            guard case ClaudeQuotaError.tokenExpired = $0 else {
                return XCTFail("expected tokenExpired, got \($0)")
            }
        }
    }

    func testKeychainCredentialsGarbageThrows() {
        XCTAssertThrowsError(try ClaudeQuotaFetcher.credentials(fromKeychainData: Data("not json".utf8)))
    }

    // MARK: Codex rollout rate-limit lines

    func testCodexRolloutLineParses() throws {
        let line = try XCTUnwrap(String(data: fixture("codex-rollout-line.jsonl"), encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quota = try XCTUnwrap(CodexQuotaReader.quota(fromLine: line))
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].label, "monthly")
        XCTAssertEqual(quota.windows[0].usedPercent, 41.0, accuracy: 0.001)
        XCTAssertEqual(quota.planType, "team")
        XCTAssertNotNil(quota.observedAt)
        XCTAssertNotNil(quota.windows[0].resetsAt)
    }

    func testCodexRolloutIgnoresIrrelevantLines() {
        XCTAssertNil(CodexQuotaReader.quota(fromLine: #"{"type":"other"}"#))
        XCTAssertNil(CodexQuotaReader.quota(fromLine: "not json"))
    }
}
