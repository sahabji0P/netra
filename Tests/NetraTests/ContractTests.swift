import XCTest
@testable import Netra

/// Fixture tests for the external contracts Netra depends on, all of
/// which can drift without notice: ccusage's JSON output (pinned 20.0.19),
/// the Codex CLI rollout format, Anthropic's OAuth usage endpoint, and
/// Cursor's undocumented dashboard usage API.
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

    // MARK: Claude Code cached usage (~/.claude.json)

    func testClaudeCachedUsageParsesLimitsIncludingModelScopedWindow() throws {
        let quota = try XCTUnwrap(
            ClaudeCachedQuotaReader.quota(fromClaudeConfig: fixture("claude-config-cached-usage.json"))
        )
        XCTAssertEqual(quota.source, .claudeCodeCache)
        XCTAssertEqual(quota.subscriptionType, "Max 5x")
        XCTAssertEqual(
            quota.fetchedAt.timeIntervalSince1970, 1_788_291_226.489, accuracy: 0.001
        )
        // limits[] is preferred over the fixed window keys because it carries
        // the model-scoped weekly bucket the fixed keys report as null.
        XCTAssertEqual(quota.windows.map(\.label), ["5h", "weekly", "weekly · Fable"])
        XCTAssertEqual(quota.windows.map(\.usedPercent), [20, 3, 2])
        for window in quota.windows {
            XCTAssertNotNil(window.resetsAt, "microsecond ISO timestamps must parse")
        }
    }

    func testClaudeCachedUsageFallsBackToFixedWindowsWithoutLimitsArray() throws {
        let json = #"""
        {"cachedUsageUtilization":{"fetchedAtMs":1788291226489,"utilization":{
          "five_hour":{"utilization":41,"resets_at":"2026-09-02T00:10:00.222493+00:00"},
          "seven_day":{"utilization":7,"resets_at":null}}}}
        """#
        let quota = try XCTUnwrap(
            ClaudeCachedQuotaReader.quota(fromClaudeConfig: Data(json.utf8))
        )
        XCTAssertEqual(quota.windows.map(\.label), ["5h", "weekly"])
        XCTAssertEqual(quota.windows[0].usedPercent, 41, accuracy: 0.001)
        XCTAssertNil(quota.subscriptionType)
    }

    func testClaudeCachedUsageRejectsConfigWithoutUtilization() {
        XCTAssertNil(ClaudeCachedQuotaReader.quota(fromClaudeConfig: Data("{}".utf8)))
        XCTAssertNil(ClaudeCachedQuotaReader.quota(
            fromClaudeConfig: Data(#"{"cachedUsageUtilization":{"utilization":{}}}"#.utf8)
        ))
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

    func testCodexLegacyResetsInSecondsParsesRelativeToTimestamp() throws {
        // CLI ≤ v0.47 wrote `resets_in_seconds`; v0.48+ writes epoch `resets_at`.
        let line = #"{"timestamp":"2026-08-30T12:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":600},"plan_type":"plus"}}}"#
        let quota = try XCTUnwrap(CodexQuotaReader.quota(fromLine: line))
        let observedAt = try XCTUnwrap(quota.observedAt)
        let resetsAt = try XCTUnwrap(quota.windows.first?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince(observedAt), 600, accuracy: 0.001)
        XCTAssertEqual(quota.windows.first?.label, "5h")
    }

    // MARK: Cursor usage-summary

    func testCursorUsageBuildsIncludedApiAutoAndGrokWindows() throws {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let quota = try XCTUnwrap(
            CursorUsageFetcher.quota(
                fromSummary: fixture("cursor-usage-summary.json"),
                sandStatus: fixture("cursor-sand-usage.json"),
                fallbackPlan: nil, now: now
            )
        )
        XCTAssertEqual(quota.planType, "Pro")
        XCTAssertEqual(quota.fetchedAt, now)
        // Cursor's four distinct windows, in presentation order.
        XCTAssertEqual(quota.windows.map(\.label),
                       ["included usage", "API models", "auto models", "Grok Bot"])
        func percent(_ label: String) throws -> Double {
            try XCTUnwrap(quota.windows.first { $0.label == label }).usedPercent
        }
        XCTAssertEqual(try percent("included usage"), 12.92, accuracy: 0.001)
        XCTAssertEqual(try percent("API models"), 80.56, accuracy: 0.001)
        XCTAssertEqual(try percent("auto models"), 6.15, accuracy: 0.001)
        XCTAssertEqual(try percent("Grok Bot"), 1.866406, accuracy: 0.001)
        // The plan windows reset on the billing cycle; Grok Bot resets weekly.
        let included = try XCTUnwrap(quota.windows.first { $0.label == "included usage" })
        let grok = try XCTUnwrap(quota.windows.first { $0.label == "Grok Bot" })
        XCTAssertNotNil(included.resetsAt)
        XCTAssertNotNil(grok.resetsAt)
        XCTAssertNotEqual(included.resetsAt, grok.resetsAt)
    }

    func testCursorGrokWindowSkippedWhenNoIncludedLimit() {
        let json = #"{"hasNonZeroIncludedLimit":false,"usagePercent":5.0}"#
        XCTAssertNil(CursorUsageFetcher.grokWindow(fromSandStatus: Data(json.utf8)))
    }

    func testCursorUsageWithoutSandStatusStillShowsPlanWindows() throws {
        let quota = try XCTUnwrap(
            CursorUsageFetcher.quota(
                fromSummary: fixture("cursor-usage-summary.json"),
                sandStatus: nil, fallbackPlan: nil
            )
        )
        XCTAssertEqual(quota.windows.map(\.label), ["included usage", "API models", "auto models"])
        XCTAssertTrue(quota.models.isEmpty)
        XCTAssertEqual(quota.totalTokens, 0)
        XCTAssertNil(quota.usageValueUSD)
    }

    func testCursorAggregatedUsageMapsTokensCostAndModels() throws {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let quota = try XCTUnwrap(
            CursorUsageFetcher.quota(
                fromSummary: fixture("cursor-usage-summary.json"),
                sandStatus: fixture("cursor-sand-usage.json"),
                aggregations: fixture("cursor-aggregated-usage.json"),
                fallbackPlan: nil, now: now
            )
        )
        // totalCostCents is API-rate value drawn from the plan, not an invoice;
        // actual extra billing is summary.onDemand.used (0 cents here).
        XCTAssertEqual(try XCTUnwrap(quota.usageValueUSD), 13.30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(quota.onDemandSpendUSD), 0, accuracy: 0.000_001)
        XCTAssertEqual(quota.inputTokens, 170_000)
        XCTAssertEqual(quota.outputTokens, 12_000)
        XCTAssertEqual(quota.cacheCreationTokens, 15_000)
        XCTAssertEqual(quota.cacheReadTokens, 110_000)
        XCTAssertEqual(quota.totalTokens, 307_000)
        XCTAssertEqual(quota.models.map(\.name), ["composer-2.5", "default"])
        XCTAssertEqual(AgentPalette.modelDisplayName(quota.models[1].name), "Auto")
        XCTAssertEqual(quota.models[0].cost, 12.504375, accuracy: 0.000_001)
        // Live rows mostly omit cacheWriteTokens; missing means zero.
        XCTAssertEqual(quota.models[0].cacheCreationTokens, 0)
        XCTAssertEqual(quota.models[0].totalTokens, 218_000)
        XCTAssertEqual(quota.models[1].totalTokens, 89_000)
        XCTAssertEqual(quota.billingCycleStart, ISODate.parse("2026-08-13T10:05:25.000Z"))
        XCTAssertTrue(quota.hasDisplayableData(now: now))
    }

    func testCursorAggregatedUsageTreatsZeroCentsAsUnreportedCost() throws {
        let billed = try XCTUnwrap(
            CursorUsageFetcher.billedUsage(fromAggregations: fixture("cursor-aggregated-usage-zero-cost.json"))
        )
        XCTAssertNil(billed.costUSD)
        XCTAssertEqual(billed.models.count, 1)
        XCTAssertEqual(billed.models[0].totalTokens, 2000)
        XCTAssertEqual(billed.models[0].cost, 0, accuracy: 0.000_001)
    }

    func testCursorCycleRangeUsesBillingWindow() throws {
        let range = try XCTUnwrap(
            CursorUsageFetcher.cycleRange(fromSummary: fixture("cursor-usage-summary.json"))
        )
        XCTAssertGreaterThan(range.endMs, range.startMs)
        XCTAssertEqual(range.startMs, 1_786_615_525_000)
    }

    func testCursorUsageSummaryFallsBackToPlanRatioWithoutPercentFields() throws {
        let json = #"""
        {"billingCycleEnd":"2026-09-13T10:05:25.000Z","membershipType":"team",
         "individualUsage":{"plan":{"enabled":true,"used":600,"limit":2000}}}
        """#
        let quota = try XCTUnwrap(
            CursorUsageFetcher.quota(fromSummary: Data(json.utf8), sandStatus: nil, fallbackPlan: "pro")
        )
        XCTAssertEqual(quota.planType, "Team", "usage-summary membership wins over fallback")
        XCTAssertEqual(quota.windows.map(\.label), ["included usage"])
        XCTAssertEqual(quota.windows.first?.usedPercent ?? 0, 30.0, accuracy: 0.001)
    }

    func testCursorUsageSummaryRejectsEmpty() {
        XCTAssertNil(CursorUsageFetcher.quota(fromSummary: Data("{}".utf8), sandStatus: nil, fallbackPlan: "pro"))
    }

    func testCursorUserIDExtractionAndExpiryGate() {
        // Synthetic JWT: header.payload.sig, payload = {"sub":"google-oauth2|abc.123","exp":...}
        func jwt(sub: String, exp: Double) -> String {
            func seg(_ obj: [String: Any]) -> String {
                let data = try! JSONSerialization.data(withJSONObject: obj)
                return data.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            return "\(seg(["alg": "HS256"])).\(seg(["sub": sub, "exp": exp])).sig"
        }
        let future = Date.now.timeIntervalSince1970 + 3600
        let token = jwt(sub: "google-oauth2|abc.123_ID", exp: future)
        XCTAssertEqual(CursorCredentialReader.userID(fromToken: token), "abc.123_ID")
        XCTAssertTrue(CursorCredentialReader.tokenIsUsable(token))

        let expired = jwt(sub: "auth0|x", exp: Date.now.timeIntervalSince1970 - 10)
        XCTAssertFalse(CursorCredentialReader.tokenIsUsable(expired))
        // A sub with a cookie-unsafe character is rejected (injection guard).
        let unsafe = jwt(sub: "auth0|bad;value", exp: future)
        XCTAssertNil(CursorCredentialReader.userID(fromToken: unsafe))
    }

    func testCodexRolloutIgnoresIrrelevantLines() {
        XCTAssertNil(CodexQuotaReader.quota(fromLine: #"{"type":"other"}"#))
        XCTAssertNil(CodexQuotaReader.quota(fromLine: "not json"))
    }

    // MARK: Codex app-server (live limits)

    func testCodexAppServerRateLimitsMapWindowsPlanAndResetCredits() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("codex-app-server-rate-limits.json")) as? [String: Any]
        )
        let now = Date(timeIntervalSince1970: 1_790_410_000)
        let quota = try XCTUnwrap(CodexLiveQuota.quota(fromRateLimits: object, now: now))
        XCTAssertEqual(quota.source, .live)
        XCTAssertEqual(quota.observedAt, now)
        XCTAssertEqual(quota.planType, "team")
        XCTAssertEqual(quota.resetCreditsAvailable, 3)
        XCTAssertEqual(quota.windows.map(\.label), ["5h", "weekly"])
        XCTAssertEqual(quota.windows.map(\.usedPercent), [12, 3])
        XCTAssertEqual(quota.windows[1].durationSeconds, 10080 * 60)
        XCTAssertEqual(quota.windows[1].resetsAt, Date(timeIntervalSince1970: 1_791_010_859))
    }

    func testCodexRolloutIgnoresOtherLimitBuckets() {
        let premium = #"{"timestamp":"2026-09-05T11:59:05.150Z","payload":{"rate_limits":{"limit_id":"premium","primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1790275862},"plan_type":"team","rate_limit_reached_type":"workspace_member_credits_depleted"}}}"#
        XCTAssertNil(CodexQuotaReader.quota(fromLine: premium))
        let codex = premium.replacingOccurrences(of: #""limit_id":"premium""#, with: #""limit_id":"codex""#)
        let quota = CodexQuotaReader.quota(fromLine: codex)
        XCTAssertEqual(quota?.source, .sessionLog)
        XCTAssertEqual(quota?.limitReachedType, "workspace_member_credits_depleted")
    }

    // MARK: Claude live response with limits[] and extra usage

    func testClaudeLiveUsageKeepsModelScopedWeeklyWindow() throws {
        let quota = try ClaudeQuotaFetcher.quota(fromResponse: fixture("claude-usage-limits.json"), subscriptionType: "Max 5x")
        XCTAssertEqual(quota.windows.map(\.label), ["5h", "weekly", "weekly · Fable"])
        XCTAssertEqual(quota.windows.map(\.usedPercent), [36, 58, 71])
        XCTAssertEqual(quota.windows[2].durationSeconds, 7 * 86400)
        XCTAssertEqual(quota.extraUsage?.isEnabled, false)
        XCTAssertEqual(quota.extraUsage?.summary, "Extra usage credits used up")
    }

    func testClaudeExtraUsageEnabledReadsMinorUnits() {
        let usage = ClaudeExtraUsage.parse([
            "is_enabled": true, "used_credits": 1250, "monthly_limit": 5000, "decimal_places": 2,
        ])
        XCTAssertEqual(usage?.usedUSD, 12.5)
        XCTAssertEqual(usage?.monthlyLimitUSD, 50)
        XCTAssertEqual(usage?.summary, "Extra usage on · $12.50 of $50.00 this month")
        XCTAssertNil(ClaudeExtraUsage.parse(["is_enabled": false, "credits_ever_enabled": false])?.summary)
    }

    // MARK: Codex banked resets

    func testCodexBankedResetsListAvailableCreditsSoonestFirst() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture("codex-app-server-rate-limits.json")) as? [String: Any]
        )
        object["rateLimitResetCredits"] = [
            "availableCount": 3,
            "credits": [
                ["id": "a", "status": "available", "grantedAt": 1_788_559_817, "expiresAt": 1_791_151_817, "title": "Full reset (Weekly + 5 hr)"],
                ["id": "b", "status": "available", "grantedAt": 1_788_488_880, "expiresAt": 1_791_080_880, "title": "Full reset (Weekly + 5 hr)"],
                ["id": "c", "status": "redeemed", "grantedAt": 1_788_000_000, "expiresAt": 1_791_000_000],
                ["id": "d", "status": "available", "grantedAt": 1_788_000_000, "expiresAt": 1_790_000_000],
            ],
        ]
        let now = Date(timeIntervalSince1970: 1_790_410_000)
        let quota = try XCTUnwrap(CodexLiveQuota.quota(fromRateLimits: object, now: now))
        XCTAssertEqual(quota.resetCredits?.count, 3, "redeemed credits are spent")
        let snapshot = UsageSnapshot(fetchedAt: now, report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
                                     activeBlock: nil, codexQuota: quota, claudeQuota: nil)
        let codex = try XCTUnwrap(snapshot.providerLimits(order: ["codex"], now: now).first)
        // The expired credit ("d") drops out; soonest remaining expiry first.
        XCTAssertEqual(codex.resetCredits.map(\.expiresAt), [
            Date(timeIntervalSince1970: 1_791_080_880), Date(timeIntervalSince1970: 1_791_151_817),
        ])
        XCTAssertEqual(codex.bankedResetCount, 3, "the server count wins when the list is shorter")
        XCTAssertEqual(LimitText.bankedResets(codex, now: now), "3 banked resets · next expires in 7d 18h")
    }

    func testClaudeCachedReaderPicksFreshestConfigLocation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("netra-claude-\(UUID().uuidString)")
        let configDir = home.appendingPathComponent("custom-config")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        func config(fetchedAtMs: Int, percent: Int) -> Data {
            Data(#"{"cachedUsageUtilization":{"fetchedAtMs":\#(fetchedAtMs),"utilization":{"limits":[{"kind":"weekly_all","percent":\#(percent),"resets_at":"2099-01-01T00:00:00Z"}]}}}"#.utf8)
        }
        try config(fetchedAtMs: 1_000, percent: 10).write(to: home.appendingPathComponent(".claude.json"))
        try config(fetchedAtMs: 2_000, percent: 42).write(to: configDir.appendingPathComponent(".claude.json"))

        let quota = try XCTUnwrap(ClaudeCachedQuotaReader.read(
            homeDirectory: home, environment: ["CLAUDE_CONFIG_DIR": configDir.path]
        ))
        XCTAssertEqual(quota.windows.first?.usedPercent, 42, "the newer cache wins")
        XCTAssertEqual(ClaudeCachedQuotaReader.read(homeDirectory: home, environment: [:])?.windows.first?.usedPercent, 10)
    }
}
