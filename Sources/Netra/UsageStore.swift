import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    enum State: Equatable {
        case empty
        case refreshing
        case fresh
        case stale
        case failed(String)
    }

    private(set) var snapshot: UsageSnapshot?
    private(set) var state: State = .empty

    private let client = CCUsageClient()
    private var refreshTask: Task<Void, Never>?
    private let staleAfter: TimeInterval = 60
    /// The Anthropic usage endpoint is unofficial — poll it gently, not every
    /// local refresh. Quota barely moves in five minutes anyway.
    private let claudeQuotaTTL: TimeInterval = 300

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Netra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            snapshot = cached
            state = .stale
        }
        Task { await self.refresh() }
        startSafetyTimer()
    }

    func refresh(forceQuota: Bool = false) async {
        guard refreshTask == nil else { return }
        state = .refreshing
        let task = Task {
            do {
                let report = try await client.fetchReport()
                // Block and quota data are bonuses — their failure must not fail the refresh.
                let block = try? await client.fetchActiveBlock()
                let codexQuota = await Task.detached { CodexQuotaReader.read() }.value
                let claudeQuota = await refreshedClaudeQuota(force: forceQuota)
                let fresh = UsageSnapshot(fetchedAt: .now, report: report,
                                          activeBlock: block ?? nil, codexQuota: codexQuota,
                                          claudeQuota: claudeQuota)
                snapshot = fresh
                state = .fresh
                persist(fresh)
            } catch {
                // A failed refresh never overwrites a good snapshot.
                state = snapshot == nil ? .failed(error.localizedDescription) : .stale
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Within the TTL the cached quota is reused; past it we refetch, and on
    /// failure keep the old value — its fetchedAt lets the UI label it stale.
    private func refreshedClaudeQuota(force: Bool) async -> ClaudeQuota? {
        if !force, let existing = snapshot?.claudeQuota,
           Date.now.timeIntervalSince(existing.fetchedAt) < claudeQuotaTTL {
            return existing
        }
        return (try? await ClaudeQuotaFetcher.fetch()) ?? snapshot?.claudeQuota
    }

    /// Called when the popover opens: refresh only if the data has gone stale.
    func refreshIfStale() {
        guard let snapshot else {
            Task { await refresh() }
            return
        }
        if Date.now.timeIntervalSince(snapshot.fetchedAt) > staleAfter {
            Task { await refresh() }
        }
    }

    private func startSafetyTimer() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refresh()
            }
        }
    }

    private func persist(_ snapshot: UsageSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
