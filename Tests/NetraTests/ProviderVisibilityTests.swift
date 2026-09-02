import XCTest
@testable import Netra

/// Provider opt-in behavior: hiding a provider from the menu popover rebuilds
/// row totals from the visible parts, and real Claude quota windows respect
/// reset-based freshness and take precedence over the local estimate in alerts.
final class ProviderVisibilityTests: XCTestCase {
    private func sampleRow() -> PeriodRow {
        let claude = AgentStat(
            name: "claude", cost: 10, totalTokens: 1000, inputTokens: 100,
            outputTokens: 200, cacheCreationTokens: 300, cacheReadTokens: 400,
            models: [ModelStat(name: "claude-test", cost: 10, totalTokens: 1000,
                               inputTokens: 100, outputTokens: 200,
                               cacheCreationTokens: 300, cacheReadTokens: 400)]
        )
        let codex = AgentStat(
            name: "codex", cost: 5, totalTokens: 500, inputTokens: 50,
            outputTokens: 100, cacheCreationTokens: 150, cacheReadTokens: 200,
            models: []
        )
        // Row totals exceed the agent sums by 2 cost / 100 tokens → "other".
        return PeriodRow(
            period: "2026-09-01", date: .now, cost: 17, inputTokens: 160,
            outputTokens: 320, cacheCreationTokens: 460, cacheReadTokens: 620,
            totalTokens: 1600, agents: [claude, codex], models: []
        )
    }

    func testFilteredWithNoHiddenProvidersReturnsIdenticalRow() {
        let row = sampleRow()
        let filtered = row.filtered(hidingProviders: [])
        XCTAssertEqual(filtered, row)
    }

    func testFilteredRemovesHiddenProviderAndRebuildsTotals() {
        let row = sampleRow()
        let filtered = row.filtered(hidingProviders: ["codex"])

        XCTAssertEqual(filtered.agents.map(\.name), ["claude"])
        // claude (10) + unattributed other (2); codex (5) is gone.
        XCTAssertEqual(filtered.cost, 12, accuracy: 0.000_001)
        // claude 1000 + other 100.
        XCTAssertEqual(filtered.totalTokens, 1100)
        // Residual "other" is still derivable downstream from the new totals.
        XCTAssertEqual(filtered.unattributed?.cost ?? 0, 2, accuracy: 0.000_001)
    }

    func testFilteredCanHideUnattributedUsage() {
        let row = sampleRow()
        let filtered = row.filtered(hidingProviders: ["other"])

        XCTAssertEqual(filtered.agents.map(\.name), ["claude", "codex"])
        XCTAssertEqual(filtered.cost, 15, accuracy: 0.000_001)
        XCTAssertEqual(filtered.totalTokens, 1500)
        XCTAssertNil(filtered.unattributed)
    }

    func testUnattributedIsNilWhenAgentsAccountForEverything() {
        var row = sampleRow()
        row.cost = 15
        row.totalTokens = 1500
        row.inputTokens = 150
        row.outputTokens = 300
        row.cacheCreationTokens = 450
        row.cacheReadTokens = 600
        XCTAssertNil(row.unattributed)
    }

    @MainActor
    func testHiddenProvidersPersistAcrossPreferenceInstances() {
        let suiteName = "NetraTests.ProviderVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.isProviderVisibleInMenu("codex"))
        preferences.setProvider("Codex", visibleInMenu: false)
        XCTAssertFalse(preferences.isProviderVisibleInMenu("codex"))

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.isProviderVisibleInMenu("codex"))
        XCTAssertTrue(reloaded.isProviderVisibleInMenu("claude"))
        XCTAssertFalse(reloaded.claudeQuotaEnabled, "real Claude limits must stay opt-in")
    }

    func testClaudeQuotaActiveWindowsDropExpiredAndStaleUndated() {
        let now = Date.now
        let quota = ClaudeQuota(
            windows: [
                QuotaWindow(label: "5h", usedPercent: 40, resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(label: "weekly", usedPercent: 80, resetsAt: now.addingTimeInterval(-60)),
                QuotaWindow(label: "undated", usedPercent: 10, resetsAt: nil),
            ],
            subscriptionType: "max",
            fetchedAt: now.addingTimeInterval(-2 * 3600)
        )
        XCTAssertEqual(quota.activeWindows(now: now).map(\.label), ["5h"])

        let freshFetch = ClaudeQuota(
            windows: [QuotaWindow(label: "undated", usedPercent: 10, resetsAt: nil)],
            subscriptionType: nil,
            fetchedAt: now.addingTimeInterval(-60)
        )
        XCTAssertEqual(freshFetch.activeWindows(now: now).map(\.label), ["undated"])
    }

    func testClaudeQuotaAlertsAsProviderLimitAndSuppressesLocalEstimate() throws {
        let now = Date.now
        let report = CCUnifiedReport(daily: [], weekly: [], monthly: [])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let block = CCBlock(
            startTime: iso.string(from: now.addingTimeInterval(-3600)),
            endTime: iso.string(from: now.addingTimeInterval(3600)),
            isActive: true, isGap: nil, totalTokens: 100, costUSD: 1,
            projection: nil,
            tokenLimitStatus: CCTokenLimitStatus(limit: 100, percentUsed: 99, projectedUsage: 100, status: "warning")
        )
        let quota = ClaudeQuota(
            windows: [QuotaWindow(label: "weekly", usedPercent: 91, resetsAt: now.addingTimeInterval(86_400))],
            subscriptionType: "max",
            fetchedAt: now
        )
        let activeBlock = try XCTUnwrap(BlockStat(block: block), "test block must be active")
        let snapshot = UsageSnapshot(
            fetchedAt: now, report: report,
            activeBlock: activeBlock,
            codexQuota: nil, claudeQuota: quota
        )
        let configuration = UsageAlertConfiguration(
            dailyTokenAlertEnabled: false, dailyTokenThreshold: 1,
            providerLimitAlertEnabled: true, providerLimitThreshold: 80
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            snapshot: snapshot, configuration: configuration,
            previousState: UsageAlertDedupeState(), now: now
        )

        XCTAssertEqual(evaluation.candidates.count, 1)
        let candidate = try XCTUnwrap(evaluation.candidates.first)
        XCTAssertEqual(candidate.kind, .providerLimit)
        XCTAssertTrue(candidate.key.hasPrefix("provider-limit:claude:weekly:"))
        XCTAssertFalse(
            evaluation.candidates.contains { $0.kind == .localLimitEstimate },
            "the 99% local estimate must not double-alert once real limits exist"
        )
    }
}
