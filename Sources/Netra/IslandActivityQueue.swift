import Foundation
import Observation

extension IslandActivity.Kind {
    /// Higher shows first: limit reached > running hot > window reset >
    /// account switched > keep awake.
    var islandPriority: Int {
        switch self {
        case .limitReached: 4
        case .runningHot: 3
        case .windowReset: 2
        case .accountSwitched: 1
        case .keepAwake: 0
        }
    }
}

/// Shows island activities one at a time. Each id is shown at most once per
/// session; a burst arriving together is collected for a short coalescing
/// delay, then shown highest priority first (oldest first within a priority).
/// The item on screen is never preempted. Time is injected so tests run fast.
@MainActor
@Observable
final class IslandActivityQueue {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// What the island shows right now; nil when resting.
    private(set) var current: IslandActivity?
    /// Waiting, in arrival order.
    private(set) var pending: [IslandActivity] = []

    @ObservationIgnored var displayDuration: Duration
    @ObservationIgnored var limitReachedDuration: Duration
    @ObservationIgnored var coalesceDelay: Duration
    /// Oldest lowest-priority items are dropped past this many waiting.
    @ObservationIgnored var maxPending = 8

    @ObservationIgnored private let sleep: Sleeper
    @ObservationIgnored private var shownIDs: Set<String> = []
    @ObservationIgnored private var runner: Task<Void, Never>?

    init(
        displayDuration: Duration = .seconds(4),
        limitReachedDuration: Duration = .seconds(8),
        coalesceDelay: Duration = .milliseconds(400),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.displayDuration = displayDuration
        self.limitReachedDuration = limitReachedDuration
        self.coalesceDelay = coalesceDelay
        self.sleep = sleep
    }

    func enqueue(_ activity: IslandActivity) {
        enqueue([activity])
    }

    func enqueue(_ activities: [IslandActivity]) {
        for activity in activities {
            guard !shownIDs.contains(activity.id), current?.id != activity.id,
                  !pending.contains(where: { $0.id == activity.id }) else { continue }
            // A newer keep-awake or account change replaces a waiting one for
            // the same thing; only the latest state is worth showing.
            pending.removeAll { Self.supersedes(activity, $0) }
            pending.append(activity)
        }
        while pending.count > maxPending, let drop = lowestPriorityIndex() {
            pending.remove(at: drop)
        }
        startIfNeeded()
    }

    /// Hides the current item now (e.g. the user clicked it away) and moves
    /// on to the next one.
    func dismissCurrent() {
        guard current != nil else { return }
        runner?.cancel()
        runner = nil
        current = nil
        startIfNeeded()
    }

    /// Drops everything waiting and hides the current item. Shown ids are
    /// kept, so nothing already seen comes back.
    func clear() {
        runner?.cancel()
        runner = nil
        pending = []
        current = nil
    }

    func duration(for activity: IslandActivity) -> Duration {
        if case .limitReached = activity.kind { return limitReachedDuration }
        return displayDuration
    }

    // MARK: Running

    private func startIfNeeded() {
        guard runner == nil, !pending.isEmpty else { return }
        runner = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        // Let the rest of a burst arrive so the most important item leads.
        try? await sleep(coalesceDelay)
        while !Task.isCancelled, let next = takeNext() {
            shownIDs.insert(next.id)
            current = next
            try? await sleep(duration(for: next))
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        current = nil
        runner = nil
    }

    private func takeNext() -> IslandActivity? {
        guard let index = pending.indices.max(by: { lhs, rhs in
            let l = pending[lhs].kind.islandPriority, r = pending[rhs].kind.islandPriority
            // Equal priority: the earlier arrival wins.
            return l != r ? l < r : lhs > rhs
        }) else { return nil }
        return pending.remove(at: index)
    }

    private func lowestPriorityIndex() -> Int? {
        pending.indices.min { pending[$0].kind.islandPriority < pending[$1].kind.islandPriority }
    }

    private static func supersedes(_ new: IslandActivity, _ old: IslandActivity) -> Bool {
        switch (new.kind, old.kind) {
        case (.keepAwake, .keepAwake): true
        case (.accountSwitched, .accountSwitched): new.agent == old.agent
        default: false
        }
    }
}
