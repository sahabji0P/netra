import Foundation
import Observation

private actor UsageSnapshotCache {
    func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func save(_ snapshot: UsageSnapshot) {
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Netra", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }
}

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
    private let preferences: AppPreferences
    private let alerts: UsageAlertController
    private let cache = UsageSnapshotCache()
    private var refreshTask: Task<Void, Never>?
    private let staleAfter: TimeInterval = 60

    init(
        preferences: AppPreferences = AppPreferences(),
        alerts: UsageAlertController? = nil,
        startsAutomatically: Bool = true
    ) {
        self.preferences = preferences
        self.alerts = alerts ?? UsageAlertController()
        guard startsAutomatically else { return }
        Task { [weak self] in
            guard let self else { return }
            if let cached = await cache.load(), snapshot == nil {
                snapshot = cached
                if state != .refreshing {
                    state = .stale
                }
            }
            await refresh()
        }
        startSafetyTimer()
    }

    func refresh() async {
        guard refreshTask == nil else { return }
        state = .refreshing
        let task = Task {
            do {
                var report = try await client.fetchReport()
                // Models absent from ccusage's offline pricing table come back
                // costed $0; pull their real pricing once and rescan.
                let unpriced = PricingOverrides.unpricedModels(in: report)
                if !unpriced.isEmpty, await PricingOverrides.ensure(for: unpriced) {
                    report = try await client.fetchReport()
                }
                // Block and quota data are bonuses — their failure must not fail the refresh.
                // Keep the last observed values when a secondary reader fails;
                // a successful "no active block" result still clears that value.
                let previousSnapshot = snapshot
                let block: BlockStat?
                do {
                    block = try await client.fetchActiveBlock()
                } catch {
                    block = previousSnapshot?.activeBlock
                }
                let observedCodexQuota = await Task.detached { CodexQuotaReader.read() }.value
                let codexQuota = observedCodexQuota ?? previousSnapshot?.codexQuota
                let fresh = UsageSnapshot(fetchedAt: .now, report: report,
                                          activeBlock: block, codexQuota: codexQuota,
                                          // A companion app cannot safely read Claude Code's
                                          // Keychain item without repeated macOS authorization
                                          // prompts. Keep the persisted field empty; the UI uses
                                          // ccusage's explicitly-labelled local block estimate.
                                          claudeQuota: nil)
                snapshot = fresh
                state = .fresh
                await cache.save(fresh)
                let alertConfiguration = preferences.alertConfiguration
                Task {
                    await alerts.processFreshSnapshot(
                        fresh,
                        configuration: alertConfiguration
                    )
                }
            } catch {
                // A failed refresh never overwrites a good snapshot.
                state = snapshot == nil ? .failed(error.localizedDescription) : .stale
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
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

}
