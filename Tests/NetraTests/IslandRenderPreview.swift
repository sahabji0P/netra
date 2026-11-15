import AppKit
import SwiftUI
import XCTest
@testable import Netra

/// Dev-only visual QA for the notch island, with a synthetic snapshot and
/// synthetic accounts (no ccusage run, no live sign-ins). Runs only when
/// NETRA_RENDER_DIR is set, e.g.
/// NETRA_RENDER_DIR=/tmp/netra-previews swift test --filter IslandRenderPreview
@MainActor
final class IslandRenderPreview: XCTestCase {
    func testRenderIslandPreviews() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render UI previews")
        }
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let suiteName = "NetraTests.IslandRender"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let now = Date.now
        let snapshot = Self.snapshot(now: now)

        // Resting.
        render(
            IslandCompactContent(snapshot: snapshot, preferences: preferences).fixedSize(),
            name: "island-compact", radius: IslandTheme.compactBottomRadius, outputDir: outputDir
        )
        render(
            IslandCompactContent(snapshot: nil, preferences: preferences).fixedSize(),
            name: "island-compact-empty", radius: IslandTheme.compactBottomRadius, outputDir: outputDir
        )

        // Every live activity kind.
        let activities: [(String, IslandActivity)] = [
            ("hot", IslandActivity(id: "hot", agent: "claude", kind: .runningHot(
                windowLabel: "5h", usedPercent: 86, resetsAt: now.addingTimeInterval(72 * 60)))),
            ("limit", IslandActivity(id: "limit", agent: "codex", kind: .limitReached(
                windowLabel: "5h", resetsAt: now.addingTimeInterval(1 * 3600 + 4 * 60 + 9), alternative: "Claude Code"))),
            ("limit-unknown", IslandActivity(id: "limit2", agent: "cursor", kind: .limitReached(
                windowLabel: "included usage", resetsAt: nil, alternative: nil))),
            ("reset", IslandActivity(id: "reset", agent: "codex", kind: .windowReset(title: "Codex is fresh again"))),
            ("switched", IslandActivity(id: "switch", agent: "claude", kind: .accountSwitched(accountLabel: "Personal"))),
            ("awake-on", IslandActivity(id: "awake", agent: nil, kind: .keepAwake(isOn: true, until: now.addingTimeInterval(4 * 3600)))),
            ("awake-off", IslandActivity(id: "awake-off", agent: nil, kind: .keepAwake(isOn: false, until: nil))),
        ]
        for (name, activity) in activities {
            render(
                IslandActivityView(activity: activity).frame(width: 420),
                name: "island-activity-\(name)", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
            )
        }

        // Expanded: full, two providers, estimate-only and stale, a missing
        // Claude card after a failed refresh, and empty.
        render(
            IslandExpandedContent(snapshot: snapshot, state: .fresh, preferences: preferences),
            name: "island-expanded", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        let twoProviders = AppPreferences(defaults: defaults)
        twoProviders.setProvider("cursor", visibleInMenu: false)
        twoProviders.setProvider("cursor-grok-bot", visibleInMenu: false)
        render(
            IslandExpandedContent(snapshot: snapshot, state: .fresh, preferences: twoProviders),
            name: "island-expanded-two", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        twoProviders.setProvider("cursor", visibleInMenu: true)
        twoProviders.setProvider("cursor-grok-bot", visibleInMenu: true)
        render(
            IslandExpandedContent(
                snapshot: Self.snapshot(now: now, estimateOnly: true, fetchedAt: now.addingTimeInterval(-3 * 3600)),
                state: .stale, preferences: preferences
            ),
            name: "island-expanded-estimate-stale", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        render(
            IslandExpandedContent(
                snapshot: Self.snapshot(now: now, claudeUsedWithoutLimits: true),
                state: .failed("ccusage timed out"), preferences: preferences,
                claudeKeychainNeedsApproval: true
            ),
            name: "island-expanded-missing-claude", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        render(
            IslandExpandedContent(snapshot: nil, state: .empty, preferences: preferences),
            name: "island-expanded-empty", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
    }

    // MARK: Synthetic data

    static func snapshot(
        now: Date, estimateOnly: Bool = false, claudeUsedWithoutLimits: Bool = false, fetchedAt: Date? = nil
    ) -> UsageSnapshot {
        func agent(_ name: String, cost: Double, tokens: Int) -> CCAgentRow {
            CCAgentRow(
                agent: name, inputTokens: tokens / 10, outputTokens: tokens / 20,
                cacheCreationTokens: 0, cacheReadTokens: tokens - tokens / 10 - tokens / 20,
                totalTokens: tokens, totalCost: cost, modelBreakdowns: []
            )
        }
        func row(_ period: String, _ agents: [CCAgentRow]) -> CCRow {
            CCRow(
                period: period, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
                totalTokens: agents.map(\.totalTokens).reduce(0, +),
                totalCost: agents.map(\.totalCost).reduce(0, +), agents: agents, modelBreakdowns: []
            )
        }
        let agents = [agent("claude", cost: 38.42, tokens: 41_200_000), agent("codex", cost: 9.17, tokens: 12_800_000)]
        // Two quieter weeks before today, so the cost tile has bars and a trend.
        let earlier = (1...20).map { offset -> CCRow in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now
            let cost = 8 + Double((offset * 37) % 29)
            return row(PeriodKeys.day(day), [agent("claude", cost: cost, tokens: Int(cost * 900_000))])
        }
        let report = CCUnifiedReport(
            daily: earlier + [row(PeriodKeys.day(now), agents)],
            weekly: [],
            monthly: []
        )
        func window(_ label: String, used: Double, duration: TimeInterval, elapsed: Double) -> QuotaWindow {
            QuotaWindow(
                label: label, usedPercent: used,
                resetsAt: now.addingTimeInterval(duration * (1 - elapsed)), durationSeconds: duration
            )
        }
        if estimateOnly {
            let block = BlockStat(block: CCBlock(
                startTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 3600)),
                endTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600)),
                isActive: true, isGap: false, totalTokens: 64_000_000, costUSD: 21.4,
                projection: CCBlockProjection(totalCost: 48), tokenLimitStatus: CCTokenLimitStatus(limit: 50_000_000)
            ))
            return UsageSnapshot(
                fetchedAt: fetchedAt ?? now, report: report, activeBlock: block,
                codexQuota: nil, claudeQuota: nil
            )
        }
        let claude = claudeUsedWithoutLimits ? nil : ClaudeQuota(
            windows: [
                window("5h", used: 46, duration: 5 * 3600, elapsed: 0.62),
                window("weekly", used: 71, duration: 7 * 86400, elapsed: 0.55),
                window("weekly · Fable", used: 38, duration: 7 * 86400, elapsed: 0.55),
            ],
            subscriptionType: "Max 20x", fetchedAt: now.addingTimeInterval(-40), source: .oauth
        )
        let codex = CodexQuota(
            windows: [
                window("5h", used: 92, duration: 5 * 3600, elapsed: 0.48),
                window("weekly", used: 40, duration: 7 * 86400, elapsed: 0.3),
            ],
            planType: "pro", observedAt: now.addingTimeInterval(-90), source: .live,
            resetCreditsAvailable: 3,
            resetCredits: [
                LimitResetCredit(title: "Full reset (Weekly + 5 hr)", grantedAt: now.addingTimeInterval(-86400),
                                 expiresAt: now.addingTimeInterval(12 * 86400)),
                LimitResetCredit(title: "Full reset (Weekly + 5 hr)", grantedAt: now.addingTimeInterval(-86400),
                                 expiresAt: now.addingTimeInterval(20 * 86400)),
            ]
        )
        let cursor = CursorQuota(
            windows: [
                window("included usage", used: 27, duration: 30 * 86400, elapsed: 0.4),
                window(CursorUsageFetcher.grokWindowLabel, used: 9, duration: 7 * 86400, elapsed: 0.3),
            ],
            planType: "pro", fetchedAt: now.addingTimeInterval(-120)
        )
        return UsageSnapshot(
            fetchedAt: fetchedAt ?? now, report: report, activeBlock: nil,
            codexQuota: codex, claudeQuota: claude, cursorQuota: cursor
        )
    }

    // MARK: Rendering

    /// Draws the view on the island's black shape, in both appearances: the
    /// island ignores the system appearance, so the pair should match.
    private func render(_ view: some View, name: String, radius: CGFloat, outputDir: String) {
        let shaped = view
            .background(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous
                ).fill(IslandTheme.background)
            )
            .padding(24)
            .background(Color(white: 0.5))
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let hosting = NSHostingView(rootView: shaped)
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = hosting.appearance
            window.contentView = hosting
            window.layoutIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

/// The island's data rules, independent of rendering.
@MainActor
final class IslandDataTests: XCTestCase {
    func testCountdownFormatsHoursMinutesAndPast() {
        XCTAssertEqual(IslandText.countdown(3600 + 4 * 60 + 9), "1:04:09")
        XCTAssertEqual(IslandText.countdown(59), "0:59")
        XCTAssertEqual(IslandText.countdown(0), "now")
        XCTAssertEqual(IslandText.countdown(-30), "now")
        XCTAssertEqual(IslandText.countdown(2 * 86400 + 4 * 3600), "2d 4h")
    }

    func testRestingIslandShowsTheProviderClosestToItsHeadlineLimit() {
        let cursor = ProviderLimits(
            agent: "cursor", source: "Reported by Cursor", observedAt: nil,
            windows: [
                QuotaWindow(label: "included usage", usedPercent: 34),
                QuotaWindow(label: "API models", usedPercent: 100),
            ]
        )
        let claude = ProviderLimits(
            agent: "claude", source: "Via Claude Code", observedAt: nil,
            windows: [QuotaWindow(label: "5h", usedPercent: 62), QuotaWindow(label: "weekly", usedPercent: 2)]
        )
        // A side pool at 100% must not stand for the provider.
        XCTAssertEqual(IslandData.primaryWindow(cursor)?.label, "included usage")
        XCTAssertEqual(IslandData.hottest([cursor, claude])?.agent, "claude")
        XCTAssertEqual(IslandData.hottest([claude, cursor])?.agent, "claude")
        XCTAssertNil(IslandData.hottest([]))
    }

    // MARK: Cost tile

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Daily costs keyed by days before `now` (0 = today).
    private func snapshot(costs: [Int: Double], now: Date, agent: String = "claude") -> UsageSnapshot {
        let rows = costs.map { offset, cost -> CCRow in
            let day = utc.date(byAdding: .day, value: -offset, to: now)!
            let tokens = Int(cost * 1_000)
            let stat = CCAgentRow(agent: agent, inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
                                  cacheReadTokens: 0, totalTokens: tokens, totalCost: cost, modelBreakdowns: [])
            return CCRow(period: PeriodKeys.day(day, utc), inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
                         cacheReadTokens: 0, totalTokens: tokens, totalCost: cost, agents: [stat], modelBreakdowns: [])
        }
        return UsageSnapshot(
            fetchedAt: now, report: CCUnifiedReport(daily: rows, weekly: [], monthly: []),
            activeBlock: nil, codexQuota: nil, claudeQuota: nil, calendar: utc
        )
    }

    func testCostTileShowsTwoWeeksWithTodayInFocusAndItsTrend() {
        let now = ISODate.parse("2026-09-26T12:00:00Z")!
        // Today $30; the seven days before average $10; one day is missing.
        let snapshot = snapshot(costs: [0: 30, 1: 10, 2: 10, 3: 10, 4: 10, 5: 10, 6: 10, 7: 10, 9: 4], now: now)
        let model = IslandCostModel(snapshot: snapshot, hiddenProviders: [], now: now, calendar: utc)

        XCTAssertEqual(model.days.count, IslandCostModel.dayCount)
        XCTAssertEqual(model.days.first?.id, "2026-09-13")
        XCTAssertEqual(model.days.last?.id, "2026-09-26")
        XCTAssertEqual(model.days.first { $0.id == "2026-09-18" }?.cost, 0, "a day without usage is a zero bar")
        XCTAssertTrue(model.focusIsToday)
        XCTAssertEqual(model.focus.cost, 30)
        XCTAssertEqual(model.focus.tokens, 30_000)
        XCTAssertEqual(try XCTUnwrap(model.trend), 2.0, accuracy: 0.000_1, "three times the average is +200%")
    }

    func testClickingABarFocusesThatDayAndComparesItWithItsOwnPriorWeek() {
        let now = ISODate.parse("2026-09-26T12:00:00Z")!
        // Sept 23 (3 days back) cost $5; its prior seven days cost $10 each.
        var costs: [Int: Double] = [0: 30, 3: 5]
        for offset in 4...10 { costs[offset] = 10 }
        let model = IslandCostModel(
            snapshot: snapshot(costs: costs, now: now), hiddenProviders: [],
            selectedDay: "2026-09-23", now: now, calendar: utc
        )
        XCTAssertFalse(model.focusIsToday)
        XCTAssertEqual(model.focus.id, "2026-09-23")
        XCTAssertEqual(model.focus.cost, 5)
        XCTAssertEqual(try XCTUnwrap(model.trend), -0.5, accuracy: 0.000_1)

        // A day outside the two weeks shown falls back to today.
        let stale = IslandCostModel(
            snapshot: snapshot(costs: costs, now: now), hiddenProviders: [],
            selectedDay: "2026-08-01", now: now, calendar: utc
        )
        XCTAssertTrue(stale.focusIsToday)
    }

    func testCostTileLeavesOutHiddenProvidersAndHasNoTrendWithoutHistory() {
        let now = ISODate.parse("2026-09-26T12:00:00Z")!
        let hidden = IslandCostModel(
            snapshot: snapshot(costs: [0: 30, 1: 10], now: now, agent: "codex"),
            hiddenProviders: ["codex"], now: now, calendar: utc
        )
        XCTAssertEqual(hidden.focus.cost, 0)
        XCTAssertNil(hidden.trend)

        let firstDay = IslandCostModel(snapshot: snapshot(costs: [0: 30], now: now), hiddenProviders: [], now: now, calendar: utc)
        XCTAssertNil(firstDay.trend, "nothing to compare a first day with")
        XCTAssertEqual(IslandCostModel(snapshot: nil, hiddenProviders: [], now: now, calendar: utc).focus.cost, 0)
    }

    func testLimitCardsRespectVisibilityAndTodayHidesHiddenProviders() {
        let suiteName = "NetraTests.IslandData"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let now = Date.now
        let snapshot = IslandRenderPreview.snapshot(now: now)
        XCTAssertEqual(IslandData.limitCards(snapshot, preferences: preferences, now: now).map(\.agent),
                       ["claude", "codex", "cursor", "cursor-grok-bot"])
        XCTAssertEqual(IslandData.today(snapshot, preferences: preferences, now: now)?.cost ?? 0, 47.59, accuracy: 0.001)

        preferences.setProvider("codex", visibleInMenu: false)
        preferences.setProvider("cursor-grok-bot", visibleInMenu: false)
        XCTAssertEqual(IslandData.limitCards(snapshot, preferences: preferences, now: now).map(\.agent),
                       ["claude", "cursor"])
        XCTAssertEqual(IslandData.today(snapshot, preferences: preferences, now: now)?.cost ?? 0, 38.42, accuracy: 0.001)

        preferences.showsLimits = false
        XCTAssertTrue(IslandData.limitCards(snapshot, preferences: preferences, now: now).isEmpty)
    }

    func testMissingClaudeReasonOnlyWhenUsedWithoutCard() {
        let suiteName = "NetraTests.IslandMissing"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let now = Date.now
        let withCard = IslandRenderPreview.snapshot(now: now)
        XCTAssertNil(IslandData.missingClaudeReason(
            withCard, cards: IslandData.limitCards(withCard, preferences: preferences, now: now),
            preferences: preferences, keychainNeedsApproval: false
        ))
        let without = IslandRenderPreview.snapshot(now: now, claudeUsedWithoutLimits: true)
        XCTAssertNotNil(IslandData.missingClaudeReason(
            without, cards: IslandData.limitCards(without, preferences: preferences, now: now),
            preferences: preferences, keychainNeedsApproval: false
        ))
    }
}
