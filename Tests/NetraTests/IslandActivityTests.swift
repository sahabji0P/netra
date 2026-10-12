import XCTest
@testable import Netra

/// The island's limit detector must fire once per crossing per cycle, never
/// on first sight, never for the local Claude estimate, and never across an
/// account switch. Adapters map existing app events without re-detecting.
final class IslandActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var reset: Date { now.addingTimeInterval(3 * 3600) }

    private func state(
        _ agent: String, _ used: Double, label: String = "5h", resetsAt: Date? = nil,
        account: String? = nil, reached: Bool = false
    ) -> IslandLimitState {
        IslandLimitState(
            agent: agent, accountKey: account,
            windows: [QuotaWindow(label: label, usedPercent: used, resetsAt: resetsAt ?? reset)],
            providerReportsLimitReached: reached
        )
    }

    private func detect(_ previous: [IslandLimitState]?, _ current: [IslandLimitState], threshold: Double = 80) -> [IslandActivity] {
        IslandActivityDetector.activities(previous: previous, current: current, threshold: threshold, now: now)
    }

    private func snapshot(
        claude: ClaudeQuota? = nil, codex: CodexQuota? = nil, block: BlockStat? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            fetchedAt: now, report: CCUnifiedReport(daily: [], weekly: [], monthly: []),
            activeBlock: block, codexQuota: codex, claudeQuota: claude
        )
    }

    // MARK: First sight

    func testFirstObservationOnlySeeds() {
        XCTAssertEqual(detect(nil, [state("claude", 95)]), [])
        var watcher = IslandLimitWatcher()
        let snap = snapshot(codex: CodexQuota(
            windows: [QuotaWindow(label: "5h", usedPercent: 100, resetsAt: reset)],
            planType: nil, observedAt: now, source: .live, limitReachedType: "rate_limit"
        ))
        XCTAssertEqual(watcher.observe(snap, threshold: 80, now: now), [], "launch must not replay a hot limit")
        XCTAssertNotNil(watcher.previous)
    }

    func testProviderSeenForTheFirstTimeDoesNotFire() {
        XCTAssertEqual(detect([state("codex", 10)], [state("codex", 10), state("claude", 95)]), [])
    }

    func testWindowSeenForTheFirstTimeDoesNotFire() {
        let before = [state("cursor", 10, label: "included usage")]
        var after = before
        after[0].windows.append(QuotaWindow(label: "on-demand spend", usedPercent: 90, resetsAt: reset))
        XCTAssertEqual(detect(before, after), [])
    }

    // MARK: Running hot

    func testThresholdCrossingFiresOncePerCycle() {
        let first = detect([state("claude", 70)], [state("claude", 82)])
        XCTAssertEqual(first.map(\.id), ["hot:claude:5h:\(UsageAlertEvaluator.cycleIdentifier(reset))"])
        XCTAssertEqual(first.first?.agent, "claude")
        XCTAssertEqual(first.first?.kind, .runningHot(windowLabel: "5h", usedPercent: 82, resetsAt: reset))

        XCTAssertEqual(detect([state("claude", 82)], [state("claude", 90)]), [], "already above: no repeat")
    }

    func testResetJitterIsTheSameCycle() {
        let jittered = reset.addingTimeInterval(1.4)
        XCTAssertEqual(detect([state("claude", 85)], [state("claude", 86, resetsAt: jittered)]), [])
    }

    func testNewCycleCanFireAgain() {
        let nextReset = reset.addingTimeInterval(5 * 3600)
        let fired = detect([state("claude", 85)], [state("claude", 81, resetsAt: nextReset)])
        XCTAssertEqual(fired.map(\.id), ["hot:claude:5h:\(UsageAlertEvaluator.cycleIdentifier(nextReset))"])
        XCTAssertNotEqual(fired.first?.id, "hot:claude:5h:\(UsageAlertEvaluator.cycleIdentifier(reset))")
    }

    func testWindowWithoutResetNeverFires() {
        let previous = [IslandLimitState(agent: "cursor", windows: [QuotaWindow(label: "included usage", usedPercent: 10)])]
        let current = [IslandLimitState(agent: "cursor", windows: [QuotaWindow(label: "included usage", usedPercent: 100)])]
        XCTAssertEqual(detect(previous, current), [])
    }

    func testAccountSwitchIsFirstSightNotACrossing() {
        XCTAssertEqual(detect([state("claude", 50, account: "a")], [state("claude", 95, account: "b")]), [])
    }

    func testEstimateOnlyClaudeBlockNeverFires() throws {
        func block(percentOf limit: Int) throws -> BlockStat {
            try XCTUnwrap(BlockStat(block: CCBlock(
                startTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)),
                endTime: ISO8601DateFormatter().string(from: reset), isActive: true, isGap: false,
                totalTokens: 10_000, costUSD: 1,
                projection: CCBlockProjection(totalCost: 3),
                tokenLimitStatus: CCTokenLimitStatus(limit: limit)
            )))
        }
        let cool = snapshot(block: try block(percentOf: 100_000))
        let hot = snapshot(block: try block(percentOf: 9_000))
        XCTAssertGreaterThan(hot.activeBlock?.percentUsed ?? 0, 100)
        XCTAssertEqual(hot.islandLimitStates(now: now), [], "the local estimate is not a limit")
        XCTAssertEqual(IslandActivityDetector.activities(previous: cool, current: hot, threshold: 80, now: now), [])
    }

    func testLastSeenRecordsAreNotObservations() {
        let lastSeen = ClaudeQuota(
            windows: [QuotaWindow(label: "5h", usedPercent: 95, resetsAt: reset)],
            subscriptionType: nil, fetchedAt: now, source: .lastSeen, accountKey: "a"
        )
        XCTAssertEqual(snapshot(claude: lastSeen).islandLimitStates(now: now), [])
    }

    func testHiddenProvidersProduceNothing() {
        let before = snapshot(codex: CodexQuota(
            windows: [QuotaWindow(label: "5h", usedPercent: 10, resetsAt: reset)], planType: nil, observedAt: now
        ))
        let after = snapshot(codex: CodexQuota(
            windows: [QuotaWindow(label: "5h", usedPercent: 90, resetsAt: reset)], planType: nil, observedAt: now
        ))
        XCTAssertEqual(IslandActivityDetector.activities(
            previous: before, current: after, threshold: 80, isVisible: { $0 != "codex" }, now: now
        ), [])
        XCTAssertEqual(IslandActivityDetector.activities(
            previous: before, current: after, threshold: 80, now: now
        ).count, 1)
    }

    // MARK: Limit reached

    func testJumpToFullFiresOnlyLimitReachedWithAlternative() {
        let fired = detect(
            [state("claude", 50), state("codex", 20)],
            [state("claude", 100), state("codex", 20)]
        )
        XCTAssertEqual(fired.map(\.id), ["limit:claude:5h:\(UsageAlertEvaluator.cycleIdentifier(reset))"])
        XCTAssertEqual(fired.first?.kind, .limitReached(windowLabel: "5h", resetsAt: reset, alternative: "Codex"))
    }

    func testAlternativeSkipsProvidersWithoutRoom() {
        let fired = detect(
            [state("claude", 50), state("codex", 85), state("cursor", 10, reached: true)],
            [state("claude", 100), state("codex", 85), state("cursor", 10, reached: true)]
        )
        XCTAssertEqual(fired.first?.kind, .limitReached(windowLabel: "5h", resetsAt: reset, alternative: nil))
        let parked = IslandActivityDetector.activities(
            previous: [state("claude", 50)], current: [state("claude", 100)], threshold: 80,
            parkedAlternative: { _ in "Claude · work" }, now: now
        )
        XCTAssertEqual(parked.first?.kind, .limitReached(windowLabel: "5h", resetsAt: reset, alternative: "Claude · work"))
    }

    func testProviderReportedLimitSharesTheCrossingId() {
        let fired = detect([state("codex", 70)], [state("codex", 85, reached: true)])
        XCTAssertEqual(fired.map(\.id), ["limit:codex:5h:\(UsageAlertEvaluator.cycleIdentifier(reset))"],
                       "the reported flag replaces running hot for the same window")
        XCTAssertEqual(detect([state("codex", 85, reached: true)], [state("codex", 86, reached: true)]), [])
    }

    func testThresholdOfHundredFiresOnlyLimitReached() {
        let fired = detect([state("claude", 90)], [state("claude", 100)], threshold: 100)
        XCTAssertEqual(fired.map(\.id), ["limit:claude:5h:\(UsageAlertEvaluator.cycleIdentifier(reset))"])
    }

    // MARK: Adapters

    func testWindowResetMapsCelebrationAndInfersSingleProvider() {
        let single = ResetCelebration(id: UUID(), title: "Codex limit reset")
        let activity = IslandActivity.windowReset(from: single, at: now)
        XCTAssertEqual(activity.id, "reset:\(single.id.uuidString)")
        XCTAssertEqual(activity.agent, "codex")
        XCTAssertEqual(activity.kind, .windowReset(title: "Codex limit reset"))
        XCTAssertEqual(IslandActivity.windowReset(from: ResetCelebration(id: UUID(), title: "Claude Code limit reset")).agent, "claude")
        XCTAssertNil(IslandActivity.windowReset(from: ResetCelebration(id: UUID(), title: "Your limits reset")).agent)
    }

    func testAccountSwitchIdsAreUniquePerSwitch() {
        let first = IslandActivity.accountSwitched(provider: .codex, accountLabel: "work", at: now)
        let again = IslandActivity.accountSwitched(provider: .codex, accountLabel: "work", at: now.addingTimeInterval(60))
        XCTAssertEqual(first.agent, "codex")
        XCTAssertEqual(first.kind, .accountSwitched(accountLabel: "work"))
        XCTAssertNotEqual(first.id, again.id)
    }

    @MainActor
    func testAccountSwitchReadsActiveLabelFromStore() {
        let identity = AccountIdentity(
            provider: .codex, providerAccountID: "synthetic-user:synthetic-acct", email: "ada@example.invalid"
        )
        var roster = AccountRoster()
        roster.accounts = [ManagedAccount(id: UUID(), identity: identity, addedAt: now)]
        let store = AccountStore(preview: roster, live: [.codex: identity])
        let activity = IslandActivity.accountSwitched(provider: .codex, in: store, at: now)
        XCTAssertEqual(activity?.kind, .accountSwitched(accountLabel: store.roster.label(for: roster.accounts[0])))
        XCTAssertNil(IslandActivity.accountSwitched(provider: .claude, in: store, at: now))
    }

    func testKeepAwakeMapsModeChanges() {
        let until = now.addingTimeInterval(3600)
        XCTAssertNil(IslandActivity.keepAwake(from: .off, to: .off, at: now))
        XCTAssertEqual(IslandActivity.keepAwake(from: .off, to: .until(until), at: now)?.kind,
                       .keepAwake(isOn: true, until: until))
        XCTAssertEqual(IslandActivity.keepAwake(from: .indefinite, to: .off, at: now)?.kind,
                       .keepAwake(isOn: false, until: nil))
        XCTAssertNil(IslandActivity.keepAwake(from: .off, to: .off, at: now)?.agent)
    }
}

/// A sleeper the test advances by hand. Honours cancellation so a dismissed
/// item never leaves a continuation hanging.
@MainActor
private final class ManualSleeper {
    private struct Sleep {
        let token: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    struct QueueNeverSlept: Error {}
    private var sleeps: [Sleep] = []
    private var nextToken = 0
    private(set) var requested: [Duration] = []

    var sleeper: IslandActivityQueue.Sleeper {
        { [self] duration in try await self.sleep(duration) }
    }

    private func sleep(_ duration: Duration) async throws {
        let token = nextToken
        nextToken += 1
        requested.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeps.append(Sleep(token: token, duration: duration, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(token) }
        }
    }

    private func cancel(_ token: Int) {
        guard let index = sleeps.firstIndex(where: { $0.token == token }) else { return }
        sleeps.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Ends the oldest pending sleep, then lets the queue run to its next one.
    func fire() async throws {
        try await waitForSleep()
        sleeps.removeFirst().continuation.resume()
        await settle()
    }

    func waitForSleep() async throws {
        for _ in 0..<1_000 where sleeps.isEmpty { await Task.yield() }
        if sleeps.isEmpty { throw QueueNeverSlept() }
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

@MainActor
final class IslandActivityQueueTests: XCTestCase {
    private func activity(_ id: String, _ kind: IslandActivity.Kind, agent: String? = nil) -> IslandActivity {
        IslandActivity(id: id, agent: agent, kind: kind, createdAt: Date(timeIntervalSince1970: 0))
    }

    private var limit: IslandActivity { activity("limit", .limitReached(windowLabel: "5h", resetsAt: nil, alternative: nil)) }
    private var hot: IslandActivity { activity("hot", .runningHot(windowLabel: "5h", usedPercent: 85, resetsAt: nil)) }
    private var reset: IslandActivity { activity("reset", .windowReset(title: "Codex limit reset")) }
    private var account: IslandActivity { activity("account", .accountSwitched(accountLabel: "work"), agent: "codex") }
    private var awake: IslandActivity { activity("awake", .keepAwake(isOn: true, until: nil)) }

    func testBurstShowsInPriorityOrderWithDurations() async throws {
        let clock = ManualSleeper()
        let queue = IslandActivityQueue(sleep: clock.sleeper)
        queue.enqueue([awake, account, reset])
        queue.enqueue([hot, limit])
        XCTAssertNil(queue.current, "a burst coalesces before anything shows")

        var shown: [String] = []
        try await clock.fire() // coalescing delay
        while let current = queue.current {
            shown.append(current.id)
            try await clock.fire()
        }
        XCTAssertEqual(shown, ["limit", "hot", "reset", "account", "awake"])
        XCTAssertEqual(clock.requested, [.milliseconds(400), .seconds(8), .seconds(4), .seconds(4), .seconds(4), .seconds(4)])
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testArrivalDuringDisplayWaitsAndIsNotPreempting() async throws {
        let clock = ManualSleeper()
        let queue = IslandActivityQueue(sleep: clock.sleeper)
        queue.enqueue(awake)
        try await clock.fire()
        XCTAssertEqual(queue.current?.id, "awake")
        queue.enqueue([reset, limit])
        XCTAssertEqual(queue.current?.id, "awake")
        try await clock.fire()
        XCTAssertEqual(queue.current?.id, "limit")
        try await clock.fire()
        XCTAssertEqual(queue.current?.id, "reset")
        try await clock.fire()
        XCTAssertNil(queue.current)
    }

    func testShownIdsAreNeverShownAgainThisSession() async throws {
        let clock = ManualSleeper()
        let queue = IslandActivityQueue(sleep: clock.sleeper)
        queue.enqueue([hot, hot])
        XCTAssertEqual(queue.pending.count, 1, "a duplicate in one burst is dropped")
        try await clock.fire()
        XCTAssertEqual(queue.current?.id, "hot")
        queue.enqueue(hot)
        XCTAssertTrue(queue.pending.isEmpty, "the item on screen is not queued again")
        try await clock.fire()
        XCTAssertNil(queue.current)

        queue.enqueue(hot)
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testDipAndRecrossWithinCycleShowsOnce() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(3600)
        func codex(_ used: Double) -> [IslandLimitState] {
            [IslandLimitState(agent: "codex", windows: [QuotaWindow(label: "5h", usedPercent: used, resetsAt: reset)])]
        }
        let clock = ManualSleeper()
        let queue = IslandActivityQueue(sleep: clock.sleeper)
        let crossings = [(70.0, 85.0), (85, 79), (79, 85)].flatMap {
            IslandActivityDetector.activities(previous: codex($0.0), current: codex($0.1), threshold: 80, now: now)
        }
        XCTAssertEqual(crossings.count, 2, "the pure detector re-emits after a dip")

        queue.enqueue(crossings[0])
        try await clock.fire()
        try await clock.fire()
        queue.enqueue(crossings[1])
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertNil(queue.current)
    }

    func testDismissMovesToTheNextItem() async throws {
        let clock = ManualSleeper()
        let queue = IslandActivityQueue(sleep: clock.sleeper)
        queue.enqueue([limit, reset])
        try await clock.fire()
        XCTAssertEqual(queue.current?.id, "limit")
        queue.dismissCurrent()
        XCTAssertNil(queue.current)
        await clock.settle()
        try await clock.fire() // coalescing delay of the restarted runner
        XCTAssertEqual(queue.current?.id, "reset")
        try await clock.fire()
        XCTAssertNil(queue.current)
    }

    func testNewerKeepAwakeAndAccountChangesReplaceWaitingOnes() {
        let queue = IslandActivityQueue(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        queue.enqueue([
            activity("awake-on", .keepAwake(isOn: true, until: nil)),
            activity("acct-1", .accountSwitched(accountLabel: "a"), agent: "codex"),
            activity("acct-2", .accountSwitched(accountLabel: "b"), agent: "claude"),
        ])
        queue.enqueue([
            activity("awake-off", .keepAwake(isOn: false, until: nil)),
            activity("acct-3", .accountSwitched(accountLabel: "c"), agent: "codex"),
        ])
        XCTAssertEqual(queue.pending.map(\.id), ["acct-2", "awake-off", "acct-3"])
        queue.clear()
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testPendingIsCappedDroppingLowestPriority() {
        let queue = IslandActivityQueue(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        queue.maxPending = 2
        queue.enqueue([awake, hot, limit])
        XCTAssertEqual(queue.pending.map(\.id), ["hot", "limit"])
        queue.clear()
    }
}
