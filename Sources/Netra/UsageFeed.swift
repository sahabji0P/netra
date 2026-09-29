import CryptoKit
import Foundation

/// The public usage feed (`netra.usage-feed/1`) the owner's website shows:
/// daily token and cost aggregates per agent and model, nothing else. The
/// contract lives with the site (portfolio-v2 `docs/usage-feed.md`); this is
/// a transport DTO kept separate from the persisted `UsageSnapshot`.
struct UsageFeed: Codable, Equatable, Sendable {
    static let schemaID = "netra.usage-feed/1"

    /// Token and cost figures; `tokens` is always the sum of the four parts.
    struct Figures: Codable, Equatable, Sendable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var tokens: Int
        var cost: Double

        static let zero = Figures(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, tokens: 0, cost: 0)

        init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, tokens: Int? = nil, cost: Double) {
            self.input = max(0, input)
            self.output = max(0, output)
            self.cacheRead = max(0, cacheRead)
            self.cacheWrite = max(0, cacheWrite)
            self.tokens = tokens ?? (self.input + self.output + self.cacheRead + self.cacheWrite)
            self.cost = max(0, cost)
        }

        var hasUsage: Bool { tokens > 0 || cost > UsageFeed.costEpsilon }

        static func + (lhs: Figures, rhs: Figures) -> Figures {
            Figures(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    cost: lhs.cost + rhs.cost)
        }
    }

    struct Agent: Codable, Equatable, Sendable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var tokens: Int
        var cost: Double
        var models: [String: Figures]

        init(_ figures: Figures, models: [String: Figures]) {
            input = figures.input
            output = figures.output
            cacheRead = figures.cacheRead
            cacheWrite = figures.cacheWrite
            tokens = figures.tokens
            cost = figures.cost
            self.models = models
        }

        var figures: Figures {
            Figures(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                    tokens: tokens, cost: cost)
        }
    }

    struct Day: Codable, Equatable, Sendable {
        var date: String
        var agents: [String: Agent]
    }

    var schema: String
    var generatedAt: String
    var source: String
    var timeZone: String
    var daily: [Day]

    /// Model name for token parts an agent reports without a model breakdown.
    static let remainderModel = "unknown"
    /// Agent id for row totals ccusage could not attribute (Netra's "other").
    static let remainderAgent = "other"
    /// Costs are estimates; sub-micro-dollar float noise is not a remainder.
    static let costEpsilon = 0.000_001
}

// MARK: - Building

extension UsageFeed {
    /// Maps a successful snapshot to the feed. Pure: the caller supplies the
    /// app version and the calendar Netra bucketed the snapshot's days in.
    ///
    /// Invariants enforced here rather than trusted from ccusage:
    /// - `tokens` is recomputed from the four parts (ccusage's `totalTokens`
    ///   can include extra categories, e.g. reasoning tokens for OpenCode).
    /// - An agent's models sum to the agent: parts no model accounts for go to
    ///   a model named `unknown`; if models over-count a part, the agent is
    ///   raised to the model sum so no tokens disappear.
    /// - Row totals not attributed to any agent become agent `other`.
    static func build(from snapshot: UsageSnapshot, version: String, calendar: Calendar = .current) -> UsageFeed {
        var days: [String: [String: Agent]] = [:]
        for row in snapshot.daily {
            let date = dayKey(for: row, calendar: calendar)
            var agents = days[date] ?? [:]
            for stat in row.agents {
                let id = stat.name.lowercased()
                let built = agent(from: stat)
                agents[id] = agents[id].map { merge($0, built) } ?? built
            }
            if let other = row.unattributed {
                let built = agent(from: other)
                agents[remainderAgent] = agents[remainderAgent].map { merge($0, built) } ?? built
            }
            agents = agents.filter { $0.value.figures.hasUsage || !$0.value.models.isEmpty }
            if !agents.isEmpty { days[date] = agents }
        }
        return UsageFeed(
            schema: schemaID,
            generatedAt: timestamp(snapshot.fetchedAt),
            source: "netra \(version)",
            timeZone: calendar.timeZone.identifier,
            daily: days.keys.sorted().map { Day(date: $0, agents: days[$0] ?? [:]) }
        )
    }

    /// ccusage's daily `period` is already the local day it bucketed with;
    /// reformatting `date` could shift it if the Mac's time zone changed
    /// since the snapshot was cached. Fall back only for unexpected keys.
    private static func dayKey(for row: PeriodRow, calendar: Calendar) -> String {
        let period = row.period
        if period.count == 10, PeriodKeys.formatter("yyyy-MM-dd", calendar).date(from: period) != nil {
            return period
        }
        return PeriodKeys.day(row.date, calendar)
    }

    private static func agent(from stat: AgentStat) -> Agent {
        var models: [String: Figures] = [:]
        for model in stat.models {
            let figures = Figures(
                input: model.inputTokens, output: model.outputTokens,
                cacheRead: model.cacheReadTokens, cacheWrite: model.cacheCreationTokens,
                cost: model.cost
            )
            models[model.name] = models[model.name].map { $0 + figures } ?? figures
        }
        let reported = Figures(
            input: stat.inputTokens, output: stat.outputTokens,
            cacheRead: stat.cacheReadTokens, cacheWrite: stat.cacheCreationTokens,
            cost: stat.cost
        )
        return reconciled(reported, models: models)
    }

    /// Makes the models sum exactly to the agent (tokens) and to within float
    /// noise (cost), never dropping tokens from either side.
    private static func reconciled(_ reported: Figures, models: [String: Figures]) -> Agent {
        let modelSum = models.values.reduce(Figures.zero, +)
        let remainder = Figures(
            input: reported.input - modelSum.input,
            output: reported.output - modelSum.output,
            cacheRead: reported.cacheRead - modelSum.cacheRead,
            cacheWrite: reported.cacheWrite - modelSum.cacheWrite,
            cost: reported.cost - modelSum.cost > costEpsilon ? reported.cost - modelSum.cost : 0
        )
        var models = models
        if remainder.hasUsage {
            models[remainderModel] = models[remainderModel].map { $0 + remainder } ?? remainder
        }
        let agent = models.values.reduce(Figures.zero, +)
        return Agent(agent, models: models)
    }

    private static func merge(_ lhs: Agent, _ rhs: Agent) -> Agent {
        var models = lhs.models
        for (name, figures) in rhs.models {
            models[name] = models[name].map { $0 + figures } ?? figures
        }
        return reconciled(lhs.figures + rhs.figures, models: models)
    }

    /// ISO-8601 UTC with whole seconds, e.g. `2026-09-29T05:14:27Z`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Encoding

extension UsageFeed {
    /// Deterministic bytes: sorted keys, unescaped slashes (the schema id).
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// SHA-256 of the feed with `generatedAt` blanked: equal hashes mean the
    /// site would receive the same figures, so a POST can be skipped.
    func contentHash() -> String {
        var copy = self
        copy.generatedAt = ""
        let data = (try? copy.encoded()) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var totalTokens: Int {
        daily.reduce(0) { total, day in total + day.agents.values.reduce(0) { $0 + $1.tokens } }
    }
}
