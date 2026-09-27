import Foundation
import os

/// One Cursor usage event as reported by Cursor's dashboard API
/// (`get-filtered-usage-events`). The server sees every entry point — IDE,
/// CLI, ACP, background agents — on every machine, so this is the
/// authoritative per-event history. No prompt text is ever stored.
struct CursorUsageEvent: Codable, Equatable, Sendable {
    var recordedAt: Date
    var model: String
    var kind: String?
    var conversationID: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    /// `tokenUsage.totalCents`: the event priced at API rates — the same
    /// basis as ccusage's estimates for other agents, not an invoice.
    var costCents: Double
    /// False when Cursor reported no token usage or no price for the event
    /// (e.g. request-billed calls). Such events carry nothing to add to token
    /// or cost totals; they are kept in history for diagnostics.
    var priced: Bool

    init(
        recordedAt: Date, model: String, kind: String? = nil, conversationID: String? = nil,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0, costCents: Double = 0, priced: Bool = true
    ) {
        self.recordedAt = recordedAt
        self.model = model
        self.kind = kind
        self.conversationID = conversationID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costCents = costCents
        self.priced = priced
    }

    /// Events carry no ID; this combination is unique in practice and
    /// collapses rows repeated across page boundaries.
    var dedupKey: String {
        let ms = Int((recordedAt.timeIntervalSince1970 * 1000).rounded())
        return "\(ms)|\(model)|\(conversationID ?? "")|\(inputTokens)|\(outputTokens)|\(cacheReadTokens)|\(cacheWriteTokens)"
    }
}

/// Parses and aggregates Cursor usage events into Netra's period rows.
enum CursorUsageEvents {
    struct Page {
        var events: [CursorUsageEvent]
        /// Rows received on this page, including ones that failed to parse.
        var rawCount: Int
        var totalCount: Int?
    }

    /// One `get-filtered-usage-events` page. An empty `{}` is a valid empty
    /// result; anything else without `usageEventsDisplay` is not.
    static func page(from data: Data) -> Page? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object.isEmpty { return Page(events: [], rawCount: 0, totalCount: 0) }
        let total = JSONValue.int(object["totalUsageEventsCount"])
        guard let rows = object["usageEventsDisplay"] as? [Any] else {
            return total == nil ? nil : Page(events: [], rawCount: 0, totalCount: total)
        }
        return Page(
            events: rows.compactMap { ($0 as? [String: Any]).flatMap(event(from:)) },
            rawCount: rows.count,
            totalCount: total
        )
    }

    static func event(from row: [String: Any]) -> CursorUsageEvent? {
        guard let ms = JSONValue.number(row["timestamp"]) else { return nil }
        let model = JSONValue.string(row["model"]) ?? "cursor"
        let usage = row["tokenUsage"] as? [String: Any]
        let cents = JSONValue.number(usage?["totalCents"])
        return CursorUsageEvent(
            recordedAt: Date(timeIntervalSince1970: ms / 1000),
            model: model,
            kind: JSONValue.string(row["kind"]),
            conversationID: JSONValue.string(row["conversationId"]),
            inputTokens: max(0, JSONValue.int(usage?["inputTokens"]) ?? 0),
            outputTokens: max(0, JSONValue.int(usage?["outputTokens"]) ?? 0),
            cacheReadTokens: max(0, JSONValue.int(usage?["cacheReadTokens"]) ?? 0),
            cacheWriteTokens: max(0, JSONValue.int(usage?["cacheWriteTokens"]) ?? 0),
            costCents: max(0, cents ?? 0),
            priced: usage != nil && cents != nil
        )
    }

    /// Cursor's `inputTokens` is exclusive of cache read/write: its billing
    /// API satisfies `input + output + cacheWrite + cacheRead == total`, with
    /// cache reads routinely far above input. Same convention as ccusage.
    static func tokenParts(of event: CursorUsageEvent) -> (
        input: Int, output: Int, cacheWrite: Int, cacheRead: Int, total: Int
    ) {
        let input = event.inputTokens, output = event.outputTokens
        let cacheWrite = event.cacheWriteTokens, cacheRead = event.cacheReadTokens
        return (input, output, cacheWrite, cacheRead, input + output + cacheWrite + cacheRead)
    }

    static func deduplicated(_ events: [CursorUsageEvent]) -> [CursorUsageEvent] {
        var seen = Set<String>()
        return events.filter { seen.insert($0.dedupKey).inserted }
    }

    /// Grok Bot runs on its own weekly allowance and Cursor's dashboard
    /// totals leave it out, so it gets its own provider line: the Cursor row
    /// then matches Cursor's reported cycle while Grok Bot stays visible.
    static let grokBotAgent = "cursor-grok-bot"

    static func agentName(forModel model: String) -> String {
        model.hasPrefix("grok-bot") ? grokBotAgent : "cursor"
    }

    /// Cursor `AgentStat`s per period key (day `yyyy-MM-dd`, week start
    /// `yyyy-MM-dd`, or month `yyyy-MM`) — one for regular usage and one for
    /// Grok Bot where present — ready to merge into a snapshot.
    static func agentStats(
        from events: [CursorUsageEvent],
        granularity: PeriodGranularity,
        calendar: Calendar = .current
    ) -> [(period: String, date: Date, agent: AgentStat)] {
        struct BucketKey: Hashable, Comparable {
            var period: String
            var agent: String
            static func < (lhs: Self, rhs: Self) -> Bool {
                (lhs.period, lhs.agent) < (rhs.period, rhs.agent)
            }
        }
        var buckets: [BucketKey: (date: Date, events: [CursorUsageEvent])] = [:]
        let gregorian = PeriodKeys.gregorian(calendar)
        for event in deduplicated(events) {
            let day = gregorian.startOfDay(for: event.recordedAt)
            let (period, date): (String, Date)
            switch granularity {
            case .day:
                (period, date) = (PeriodKeys.day(day, calendar), day)
            case .week:
                // Monday-keyed like ccusage, whatever the locale's first weekday.
                (period, date) = PeriodKeys.weekStart(day, calendar)
            case .month:
                period = PeriodKeys.month(day, calendar)
                date = gregorian.dateInterval(of: .month, for: day)?.start ?? day
            }
            let key = BucketKey(period: period, agent: agentName(forModel: event.model))
            var bucket = buckets[key] ?? (date, [])
            bucket.events.append(event)
            buckets[key] = bucket
        }

        return buckets.keys.sorted().compactMap { key in
            guard let bucket = buckets[key],
                  let agent = agentStat(bucket.events, name: key.agent) else { return nil }
            return (key.period, bucket.date, agent)
        }
    }

    private static func agentStat(_ events: [CursorUsageEvent], name: String) -> AgentStat? {
        var modelsByName: [String: ModelStat] = [:]
        var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, total = 0
        var cost = 0.0
        for event in events {
            let parts = tokenParts(of: event)
            let eventCost = event.costCents / 100
            guard parts.total > 0 || eventCost > 0 else { continue }
            input += parts.input
            output += parts.output
            cacheWrite += parts.cacheWrite
            cacheRead += parts.cacheRead
            total += parts.total
            cost += eventCost
            var model = modelsByName[event.model] ?? ModelStat(
                name: event.model, cost: 0, totalTokens: 0,
                inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0
            )
            model.cost += eventCost
            model.inputTokens += parts.input
            model.outputTokens += parts.output
            model.cacheCreationTokens += parts.cacheWrite
            model.cacheReadTokens += parts.cacheRead
            model.totalTokens += parts.total
            modelsByName[event.model] = model
        }
        guard total > 0 || cost > 0 else { return nil }
        return AgentStat(
            name: name, cost: cost, totalTokens: total,
            inputTokens: input, outputTokens: output,
            cacheCreationTokens: cacheWrite, cacheReadTokens: cacheRead,
            models: modelsByName.values.sorted {
                $0.cost == $1.cost ? $0.totalTokens > $1.totalTokens : $0.cost > $1.cost
            }
        )
    }

}

enum PeriodGranularity: Sendable {
    case day, week, month
}

/// Pages through `get-filtered-usage-events` for a time window. Pages are
/// newest-first, so events arriving mid-scan only shift rows later (seen
/// twice, deduplicated) — never skipped. A scan that ends short of the
/// reported count throws rather than publishing a partial total.
enum CursorUsageEventsFetcher {
    static let url = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    static let pageSize = 1000
    static let maxPages = 200

    struct Result: Sendable {
        var events: [CursorUsageEvent]
        var reportedCount: Int?
    }

    enum SyncError: Error {
        case incomplete(received: Int, reported: Int)
        case decoding
    }

    static func fetch(cookie: String, since: Date, until: Date) async throws -> Result {
        try await fetch(since: since, until: until) { body in
            try await CursorUsageFetcher.postJSON(url, cookie: cookie, body: body)
        }
    }

    /// Transport-injected core, so pagination is testable with fixtures.
    static func fetch(
        since: Date, until: Date, pageSize: Int = pageSize,
        post: ([String: Any]) async throws -> Data
    ) async throws -> Result {
        var events: [CursorUsageEvent] = []
        var reported: Int?
        var received = 0
        for page in 1...maxPages {
            let data = try await post([
                "page": page,
                "pageSize": pageSize,
                // The endpoint expects millisecond timestamps as strings.
                "startDate": String(Int(since.timeIntervalSince1970 * 1000)),
                "endDate": String(Int(until.timeIntervalSince1970 * 1000)),
            ])
            guard let parsed = CursorUsageEvents.page(from: data) else { throw SyncError.decoding }
            if reported == nil { reported = parsed.totalCount }
            received += parsed.rawCount
            events += parsed.events
            if parsed.rawCount < pageSize { break }
            if let reported, received >= reported { break }
        }
        if let reported, received < reported {
            throw SyncError.incomplete(received: received, reported: reported)
        }
        return Result(events: CursorUsageEvents.deduplicated(events), reportedCount: reported)
    }
}

/// Persisted, incrementally synced copy of the Cursor event history. The
/// first sync backfills the whole history window; later syncs refetch only
/// the trailing day (Cursor can post events late) and replace that slice.
actor CursorEventStore {
    struct State: Codable, Sendable {
        var events: [CursorUsageEvent] = []
        /// Everything at or after this instant has been fetched.
        var coveredSince: Date?
        var syncedAt: Date?
        var cooldownUntil: Date?
    }

    /// Matches the ccusage report window so every tab covers the same span.
    static let historyDays = 190
    static let minimumInterval: TimeInterval = 15 * 60
    static let overlap: TimeInterval = 24 * 3600
    static let authCooldown: TimeInterval = 6 * 3600

    private let fileURL: URL
    private var state: State?
    /// In-memory only: spaces out retries after a failed sync.
    private var attemptedAt: Date?
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "cursor-events")

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Netra", isDirectory: true)
        .appendingPathComponent("cursor-events.json")) {
        self.fileURL = fileURL
    }

    /// Returns the best-known history, syncing first when due. Failures keep
    /// the previous history; auth rejections back off for six hours.
    func refreshed(
        now: Date = .now,
        fetch: @Sendable (_ since: Date, _ until: Date) async throws -> CursorUsageEventsFetcher.Result
    ) async -> [CursorUsageEvent] {
        var current = loadState()
        if let until = current.cooldownUntil, until > now { return current.events }
        if let synced = current.syncedAt, now.timeIntervalSince(synced) < Self.minimumInterval {
            return current.events
        }
        if let attempted = attemptedAt, now.timeIntervalSince(attempted) < Self.minimumInterval / 3 {
            return current.events
        }
        attemptedAt = now

        let horizon = now.addingTimeInterval(-Double(Self.historyDays) * 86400)
        let since: Date
        if let covered = current.coveredSince, covered <= horizon.addingTimeInterval(86400) {
            since = max(horizon, (current.syncedAt ?? covered).addingTimeInterval(-Self.overlap))
        } else {
            since = horizon
        }

        do {
            let result = try await fetch(since, now)
            let kept = current.events.filter { $0.recordedAt < since && $0.recordedAt >= horizon }
            current.events = (kept + result.events).sorted { $0.recordedAt < $1.recordedAt }
            current.coveredSince = min(current.coveredSince ?? since, since)
            current.syncedAt = now
            current.cooldownUntil = nil
        } catch CursorUsageFetcher.CursorUsageError.http(let status) where status == 401 || status == 403 {
            log.error("cursor events rejected (HTTP \(status)); backing off")
            current.cooldownUntil = now.addingTimeInterval(Self.authCooldown)
        } catch {
            log.error("cursor events sync failed: \(String(describing: error), privacy: .public)")
        }
        save(current)
        return current.events
    }

    private func loadState() -> State {
        if let state { return state }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(State.self, from: $0) }
        state = loaded ?? State()
        return state!
    }

    private func save(_ newState: State) {
        state = newState
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(newState) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
