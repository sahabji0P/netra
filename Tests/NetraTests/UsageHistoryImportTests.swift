import XCTest
@testable import Netra

/// Exporting the recorded history and merging a history file back in, under
/// a stricter rule than a reading: a day is added or grows, and is never
/// shrunk or repriced by a file.
final class UsageHistoryImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("netra-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func agent(_ name: String, tokens: Int, cost: Double) -> AgentStat {
        AgentStat(
            name: name, cost: cost, totalTokens: tokens, inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0,
            models: [ModelStat(name: "model-a", cost: cost, totalTokens: tokens, inputTokens: tokens,
                               outputTokens: 0, cacheReadTokens: 0)]
        )
    }

    private func history(_ days: [String: [AgentStat]], completeScanAt: Date? = nil, engine: String? = nil) -> UsageHistory {
        UsageHistory(days: days, engine: engine, completeScanAt: completeScanAt)
    }

    private func write(_ history: UsageHistory, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try JSONEncoder().encode(history).write(to: url)
        return url
    }

    /// A ledger whose stored file already holds `stored`.
    private func ledger(holding stored: UsageHistory) throws -> (UsageLedger, URL) {
        let url = try write(stored, "usage-history.json")
        return (UsageLedger(fileURL: url), url)
    }

    private let stored = UsageHistory(
        days: [
            "2026-09-10": [AgentStat(name: "claude", cost: 4, totalTokens: 1_000, inputTokens: 1_000, outputTokens: 0,
                                     cacheReadTokens: 0, models: [])],
            "2026-09-11": [AgentStat(name: "codex", cost: 2, totalTokens: 500, inputTokens: 500, outputTokens: 0,
                                     cacheReadTokens: 0, models: [])],
        ],
        engine: "18.0.0",
        completeScanAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    func testImportingTheSameFileTwiceChangesNothing() async throws {
        let (ledger, storedURL) = try ledger(holding: stored)
        let file = try write(stored, "copy.json")
        let before = try Data(contentsOf: storedURL)
        let first = try await ledger.importHistory(from: file, calendar: utc)
        XCTAssertEqual(first.summary, UsageHistory.ImportSummary(added: 0, updated: 0, unchanged: 2))
        XCTAssertFalse(first.summary.changedAnything)
        let second = try await ledger.importHistory(from: file, calendar: utc)
        XCTAssertEqual(second.summary, first.summary)
        XCTAssertEqual(try Data(contentsOf: storedURL), before, "nothing changed, so nothing was saved")
    }

    func testAnOlderSmallerFileChangesNothing() async throws {
        let (ledger, storedURL) = try ledger(holding: stored)
        let older = try write(history([
            "2026-09-10": [agent("claude", tokens: 400, cost: 1.6)],
            "2026-09-11": [agent("codex", tokens: 100, cost: 0.4)],
        ]), "older.json")
        let before = try Data(contentsOf: storedURL)
        let result = try await ledger.importHistory(from: older, calendar: utc)
        XCTAssertEqual(result.summary, UsageHistory.ImportSummary(added: 0, updated: 0, unchanged: 2))
        XCTAssertEqual(try Data(contentsOf: storedURL), before)
        let current = await ledger.current()
        XCTAssertEqual(current.days["2026-09-10"]?.first?.totalTokens, 1_000)
    }

    func testNewDaysAreAddedAndLargerOnesUpdated() async throws {
        let (ledger, storedURL) = try ledger(holding: stored)
        let other = try write(history([
            "2026-08-01": [agent("claude", tokens: 9_000, cost: 30)],
            "2026-09-10": [agent("claude", tokens: 1_200, cost: 5), agent("gemini", tokens: 50, cost: 0.1)],
            "2026-09-11": stored.days["2026-09-11"]!,
            "not-a-day": [agent("claude", tokens: 1, cost: 1)],
        ]), "other.json")
        let result = try await ledger.importHistory(from: other, calendar: utc)
        XCTAssertEqual(result.summary, UsageHistory.ImportSummary(added: 1, updated: 1, unchanged: 1))
        XCTAssertEqual(result.summary.message, "Added 1 day, updated 1, 1 unchanged.")
        XCTAssertEqual(result.rows.map(\.period), ["2026-08-01", "2026-09-10", "2026-09-11"])
        XCTAssertEqual(result.rows.first { $0.period == "2026-09-10" }?.agents.map(\.name), ["claude", "gemini"])

        // Saved, and a fresh ledger reads the merged history back.
        let saved = await UsageLedger(fileURL: storedURL).current()
        XCTAssertEqual(saved.days.count, 3)
        XCTAssertEqual(saved.days["2026-09-10"]?.first { $0.name == "claude" }?.totalTokens, 1_200)
    }

    func testTheFilesScanStampIsNotAdopted() async throws {
        let (ledger, _) = try ledger(holding: stored)
        let other = try write(history(
            ["2026-07-01": [agent("claude", tokens: 10, cost: 1)]],
            completeScanAt: Date(timeIntervalSince1970: 1_799_999_999), engine: "99.0.0"
        ), "stamped.json")
        _ = try await ledger.importHistory(from: other, calendar: utc)
        let current = await ledger.current()
        XCTAssertEqual(current.completeScanAt, stored.completeScanAt)
        XCTAssertEqual(current.engine, "18.0.0")
        XCTAssertEqual(current.days.count, 3)
    }

    func testAnUnparseableFileIsRefusedAndTheStoredFileIsUntouched() async throws {
        let (ledger, storedURL) = try ledger(holding: stored)
        let before = try Data(contentsOf: storedURL)
        let junk = folder.appendingPathComponent("junk.json")
        try Data(#"{"days": {"2026-09-10": "lots"}}"#.utf8).write(to: junk)
        do {
            _ = try await ledger.importHistory(from: junk, calendar: utc)
            XCTFail("an unparseable file must be refused")
        } catch {}
        do {
            _ = try await ledger.importHistory(from: folder.appendingPathComponent("missing.json"), calendar: utc)
            XCTFail("a missing file must be refused")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: storedURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("usage-history.unreadable.json").path))
    }

    func testNegativeAndNonFiniteEntriesAreSkipped() {
        var history = UsageHistory()
        let summary = history.merge(UsageHistory(days: [
            "2026-09-10": [agent("claude", tokens: -5, cost: 1), agent("codex", tokens: 5, cost: -1)],
        ]), calendar: utc)
        XCTAssertEqual(summary, UsageHistory.ImportSummary(added: 0, updated: 0, unchanged: 1))
        XCTAssertTrue(history.days.isEmpty)
    }

    /// A file with the same tokens priced differently (older prices, or
    /// none) must not replace the stored cost: for a day whose logs are gone
    /// nothing would ever put the right price back.
    func testEqualTokensWithOtherPricesLeaveTheDayAlone() {
        var history = stored
        let summary = history.merge(UsageHistory(days: [
            "2026-09-10": [agent("claude", tokens: 1_000, cost: 3)],
        ]), calendar: utc)
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(history.days["2026-09-10"]?.first?.cost, 4)
    }

    /// Upgrading from a version with no history: the last snapshot's days
    /// start it, without claiming a complete scan.
    func testAnEmptyHistoryIsSeededFromTheLastSnapshotOnce() async throws {
        let url = folder.appendingPathComponent("seeded-history.json")
        let ledger = UsageLedger(fileURL: url)
        let rows = history([
            "2026-09-10": [agent("claude", tokens: 1_000, cost: 4)],
            "2026-09-11": [agent("codex", tokens: 500, cost: 2)],
        ]).rows(calendar: utc)

        let added = await ledger.seedIfEmpty(from: rows, calendar: utc)
        XCTAssertEqual(added, 2)
        let seeded = await ledger.current()
        XCTAssertEqual(seeded.days["2026-09-10"]?.first?.totalTokens, 1_000)
        XCTAssertNil(seeded.completeScanAt, "the first scan must still read every log")
        XCTAssertEqual(UsageScan.next(engine: "1", history: seeded), .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // A history that holds anything is never seeded again.
        let bigger = history(["2026-09-10": [agent("claude", tokens: 9_000, cost: 40)]]).rows(calendar: utc)
        let again = await ledger.seedIfEmpty(from: bigger, calendar: utc)
        XCTAssertEqual(again, 0)
        let after = await ledger.current()
        XCTAssertEqual(after.days["2026-09-10"]?.first?.totalTokens, 1_000)
    }

    func testNothingIsSeededFromAnEmptySnapshot() async throws {
        let url = folder.appendingPathComponent("unseeded-history.json")
        let added = await UsageLedger(fileURL: url).seedIfEmpty(from: [], calendar: utc)
        XCTAssertEqual(added, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExportRoundTrips() async throws {
        let (ledger, _) = try ledger(holding: stored)
        let exported = folder.appendingPathComponent("export.json")
        try await ledger.export(to: exported)
        let decoded = try JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: exported))
        XCTAssertEqual(decoded, stored)

        // Importing the export into an empty history recreates every day.
        let empty = UsageLedger(fileURL: folder.appendingPathComponent("empty-history.json"))
        let result = try await empty.importHistory(from: exported, calendar: utc)
        XCTAssertEqual(result.summary, UsageHistory.ImportSummary(added: 2, updated: 0, unchanged: 0))
        let current = await empty.current()
        XCTAssertEqual(current.days, stored.days)
        XCTAssertNil(current.completeScanAt, "a complete scan of this Mac still runs")
    }

    func testRebuildingASnapshotKeepsFreshnessAndLimits() {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = ClaudeQuota(windows: [QuotaWindow(label: "5h", usedPercent: 20, resetsAt: nil)],
                                subscriptionType: "max", fetchedAt: fetchedAt)
        let original = UsageSnapshot(fetchedAt: fetchedAt, daily: [], activeBlock: nil, codexQuota: nil,
                                     claudeQuota: quota, calendar: utc)
        let rows = history(["2026-09-10": [agent("claude", tokens: 1_000, cost: 4)]]).rows(calendar: utc)
        let rebuilt = original.replacingDays(rows, calendar: utc)
        XCTAssertEqual(rebuilt.fetchedAt, fetchedAt)
        XCTAssertEqual(rebuilt.claudeQuota?.windows, quota.windows)
        XCTAssertEqual(rebuilt.daily.map(\.period), ["2026-09-10"])
        XCTAssertEqual(rebuilt.monthly.first?.cost, 4)
    }
}
