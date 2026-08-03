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
    private let staleAfter: TimeInterval = 300

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

    func refresh() async {
        guard refreshTask == nil else { return }
        state = .refreshing
        let task = Task {
            do {
                let report = try await client.fetchReport()
                let fresh = UsageSnapshot(fetchedAt: .now, report: report)
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
                try? await Task.sleep(for: .seconds(300))
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
