import Foundation
import os

/// Netra's own record of usage: one entry per local day and agent, holding
/// tokens and estimated cost per model and nothing else.
///
/// Agents do not keep their session logs. Claude Code deletes transcripts
/// after its retention period, Codex compresses and archives rollouts, and a
/// user may clear them to free space. A report rebuilt from the logs alone
/// therefore shrinks over time; this history does not. It is also what lets
/// a refresh read only the last few days of logs instead of all of them.
struct UsageHistory: Codable, Equatable, Sendable {
    /// Local day (`yyyy-MM-dd`) to that day's usage per agent. Usage a report
    /// could not attribute to any agent is kept under `other`.
    var days: [String: [AgentStat]] = [:]
    /// The ccusage version behind the last complete scan, and when it ran.
    var engine: String?
    var completeScanAt: Date?

    /// Folds one reading of a day into the history.
    ///
    /// A reading replaces what is stored for an agent, so growth, repricing
    /// and parser fixes all flow in, unless it carries fewer tokens. Usage
    /// never falls while its logs exist, so fewer tokens means some of that
    /// day's logs are gone and the stored entry is the better record. An
    /// agent missing from the reading keeps what was stored for the same
    /// reason.
    mutating func record(day: String, agents: [AgentStat]) {
        var stored = Dictionary((days[day] ?? []).map { ($0.name, $0) }) { first, _ in first }
        for agent in agents where agent.totalTokens > 0 || agent.cost > 0 {
            if let existing = stored[agent.name], agent.totalTokens < existing.totalTokens { continue }
            stored[agent.name] = agent
        }
        guard !stored.isEmpty else { return }
        days[day] = stored.values.sorted { $0.name < $1.name }
    }

    /// Folds a ccusage report and Cursor's event history into the recorded days.
    mutating func record(
        _ report: CCUnifiedReport, cursorEvents: [CursorUsageEvent] = [], calendar: Calendar = .current
    ) {
        for row in UsageSnapshot.dayRows(from: report, calendar: calendar) {
            record(day: row.period, agents: row.parts)
        }
        for (day, agents) in CursorUsageEvents.dailyStats(from: cursorEvents, calendar: calendar) {
            record(day: day, agents: agents)
        }
    }

    /// Every recorded day, oldest first.
    func rows(calendar: Calendar = .current) -> [PeriodRow] {
        let keys = PeriodKeys.keyer(calendar)
        return days
            .compactMap { day, agents in
                keys.date(fromDay: day).map { PeriodRow(period: day, date: $0, parts: agents) }
            }
            .sorted { $0.date < $1.date }
    }
}

/// How much of the agents' logs a refresh reads.
enum UsageScan: Equatable, Sendable {
    /// Every log each agent still has.
    case complete
    /// Only the trailing days, where new usage lands.
    case recent

    /// Days before today a recent scan still reads. Usage is keyed by the
    /// time it happened, so new usage only ever lands on today; the margin
    /// covers midnight and a time-zone change.
    static let recentDaysBack = 2
    /// A complete scan repeats this often to reconcile the history with logs
    /// that changed outside the recent window (restored or copied in).
    static let completeInterval: TimeInterval = 24 * 3600

    /// A complete scan seeds the history, follows every ccusage upgrade (a
    /// parser fix must reach the days whose logs still exist), and otherwise
    /// runs once a day. Everything in between reads recent days only.
    static func next(engine: String?, history: UsageHistory, now: Date = .now) -> UsageScan {
        guard let last = history.completeScanAt else { return .complete }
        if let engine, engine != history.engine { return .complete }
        // A clock set backwards must not postpone the next complete scan.
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= completeInterval || elapsed < 0 ? .complete : .recent
    }
}

/// Owns the persisted `UsageHistory`. Every read of the logs passes through
/// `record`, off the main actor, and comes back as the full daily history.
actor UsageLedger {
    private let fileURL: URL
    private var history: UsageHistory?
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "ledger")

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Netra", isDirectory: true)
        .appendingPathComponent("usage-history.json")) {
        self.fileURL = fileURL
    }

    func current() -> UsageHistory {
        loaded()
    }

    /// Records a refresh's readings, saves when anything changed, and returns
    /// every recorded day. `complete` marks the report as a complete scan by
    /// ccusage `engine` (nil when the version could not be read).
    func record(
        _ report: CCUnifiedReport,
        cursorEvents: [CursorUsageEvent],
        complete: Bool,
        engine: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [PeriodRow] {
        let before = loaded()
        var updated = before
        updated.record(report, cursorEvents: cursorEvents, calendar: calendar)
        if complete {
            updated.engine = engine
            updated.completeScanAt = now
        }
        if updated != before { save(updated) }
        history = updated
        return updated.rows(calendar: calendar)
    }

    private func loaded() -> UsageHistory {
        if let history { return history }
        var loaded = UsageHistory()
        if let data = try? Data(contentsOf: fileURL) {
            do {
                loaded = try JSONDecoder().decode(UsageHistory.self, from: data)
            } catch {
                // The history cannot be rebuilt once logs are gone, so an
                // unreadable file is set aside rather than overwritten.
                let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                log.error("usage history unreadable, set aside as \(aside.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        history = loaded
        return loaded
    }

    private func save(_ history: UsageHistory) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(history).write(to: fileURL, options: .atomic)
        } catch {
            log.error("usage history not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
