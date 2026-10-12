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

        let suiteName = "NetraTests.IslandRender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let now = Date.now
        let snapshot = Self.snapshot(now: now)
        let accounts = AccountsRenderPreview.previewAccounts(withNotice: false)
        let awake = AwakeController()

        // Resting.
        render(
            IslandCompactContent(snapshot: snapshot, state: .fresh, preferences: preferences, isAwake: true)
                .fixedSize(),
            name: "island-compact", radius: IslandTheme.compactBottomRadius, outputDir: outputDir
        )
        render(
            IslandCompactContent(snapshot: nil, state: .empty, preferences: preferences, isAwake: false)
                .fixedSize(),
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

        // Expanded: full, with a notice, estimate-only, stale, and empty.
        render(
            IslandExpandedContent(snapshot: snapshot, state: .fresh, preferences: preferences, accounts: accounts, awake: awake),
            name: "island-expanded", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        render(
            IslandExpandedContent(
                snapshot: snapshot, state: .fresh, preferences: preferences,
                accounts: AccountsRenderPreview.previewAccounts(withNotice: true), awake: awake
            ),
            name: "island-expanded-notice", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        render(
            IslandExpandedContent(
                snapshot: Self.snapshot(now: now, estimateOnly: true, fetchedAt: now.addingTimeInterval(-3 * 3600)),
                state: .stale, preferences: preferences, accounts: nil, awake: awake
            ),
            name: "island-expanded-estimate-stale", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        render(
            IslandExpandedContent(
                snapshot: Self.snapshot(now: now, claudeUsedWithoutLimits: true),
                state: .failed("ccusage timed out"), preferences: preferences, accounts: accounts, awake: awake,
                claudeKeychainNeedsApproval: true
            ),
            name: "island-expanded-missing-claude", radius: IslandTheme.expandedBottomRadius, outputDir: outputDir
        )
        render(
            IslandExpandedContent(
                snapshot: nil, state: .empty, preferences: preferences,
                accounts: AccountStore(preview: AccountRoster(), live: [:]), awake: awake
            ),
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
        let report = CCUnifiedReport(
            daily: [row(PeriodKeys.day(now), agents)],
            weekly: [row(PeriodKeys.weekStart(now).key, agents)],
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
            windows: [window("included usage", used: 27, duration: 30 * 86400, elapsed: 0.4)],
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

    func testRingOrderPutsShortestWindowOutsideAndKeepsUnknownLast() {
        let windows = [
            QuotaWindow(label: "weekly", usedPercent: 10, durationSeconds: 7 * 86400),
            QuotaWindow(label: "monthly", usedPercent: 10),
            QuotaWindow(label: "5h", usedPercent: 10, durationSeconds: 5 * 3600),
        ]
        XCTAssertEqual(IslandData.ringOrder(windows).map(\.label), ["5h", "weekly", "monthly"])
    }

    func testPeekRotatesThroughEveryProviderUsingItsHeadlineWindow() {
        let cursor = ProviderLimits(
            agent: "cursor", source: "Reported by Cursor", observedAt: nil,
            windows: [
                QuotaWindow(label: "included usage", usedPercent: 34),
                QuotaWindow(label: "API models", usedPercent: 100),
            ]
        )
        let claude = ProviderLimits(
            agent: "claude", source: "Via Claude Code", observedAt: nil,
            windows: [QuotaWindow(label: "5h", usedPercent: 13), QuotaWindow(label: "weekly", usedPercent: 2)]
        )
        // A side pool at 100% must not stand for the provider.
        XCTAssertEqual(IslandData.primaryWindow(cursor)?.label, "included usage")

        let start = Date(timeIntervalSinceReferenceDate: 0)
        let shown = (0..<4).map { step in
            IslandData.rotating([claude, cursor], now: start.addingTimeInterval(Double(step) * IslandData.rotationInterval))?.agent
        }
        XCTAssertEqual(shown, ["claude", "cursor", "claude", "cursor"])
        XCTAssertEqual(
            IslandData.rotating([claude, cursor], now: start.addingTimeInterval(IslandData.rotationInterval - 0.5))?.agent,
            "claude"
        )
        XCTAssertNil(IslandData.rotating([], now: start))
    }

    func testPeekShowsCountdownThenSpendWithinEachTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let half = IslandData.rotationInterval / 2
        XCTAssertFalse(IslandData.peekShowsSpend(now: start))
        XCTAssertFalse(IslandData.peekShowsSpend(now: start.addingTimeInterval(half - 0.1)))
        XCTAssertTrue(IslandData.peekShowsSpend(now: start.addingTimeInterval(half)))
        XCTAssertFalse(IslandData.peekShowsSpend(now: start.addingTimeInterval(IslandData.rotationInterval)))
    }

    func testIslandSectionsDefaultToTheTrimmedSetAndPersist() {
        let suite = "NetraTests.IslandSections.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.islandSections, IslandSection.defaults)
        XCTAssertTrue(preferences.showsIslandSection(.providerSpend))
        XCTAssertTrue(preferences.showsIslandSection(.bankedResets))
        XCTAssertTrue(preferences.showsIslandSection(.secondWindow))
        XCTAssertFalse(preferences.showsIslandSection(.accounts))
        preferences.setIslandSection(.accounts, true)
        preferences.setIslandSection(.usageFooter, false)
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.showsIslandSection(.accounts))
        XCTAssertFalse(reloaded.showsIslandSection(.usageFooter))
    }

    func testLimitCardsRespectVisibilityAndTodayHidesHiddenProviders() {
        let suiteName = "NetraTests.IslandData.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let now = Date.now
        let snapshot = IslandRenderPreview.snapshot(now: now)
        XCTAssertEqual(IslandData.limitCards(snapshot, preferences: preferences, now: now).map(\.agent),
                       ["claude", "codex", "cursor"])
        XCTAssertEqual(IslandData.today(snapshot, preferences: preferences, now: now)?.cost ?? 0, 47.59, accuracy: 0.001)

        preferences.setProvider("codex", visibleInMenu: false)
        XCTAssertEqual(IslandData.limitCards(snapshot, preferences: preferences, now: now).map(\.agent),
                       ["claude", "cursor"])
        XCTAssertEqual(IslandData.today(snapshot, preferences: preferences, now: now)?.cost ?? 0, 38.42, accuracy: 0.001)

        preferences.showsLimits = false
        XCTAssertTrue(IslandData.limitCards(snapshot, preferences: preferences, now: now).isEmpty)
    }

    func testMissingClaudeReasonOnlyWhenUsedWithoutCard() {
        let suiteName = "NetraTests.IslandMissing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
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
