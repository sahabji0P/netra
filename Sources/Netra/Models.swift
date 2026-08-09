import Foundation

// MARK: - ccusage JSON DTOs (schema pinned to ccusage 20.0.19 unified report)

struct CCUnifiedReport: Decodable {
    var daily: [CCRow]?
    var weekly: [CCRow]?
    var monthly: [CCRow]?
}

struct CCRow: Decodable {
    var period: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int
    var totalCost: Double
    var agents: [CCAgentRow]?
    var modelBreakdowns: [CCModelBreakdown]?
}

struct CCAgentRow: Decodable {
    var agent: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int
    var totalCost: Double
    var modelBreakdowns: [CCModelBreakdown]?
}

struct CCModelBreakdown: Decodable {
    var modelName: String
    var cost: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
}

// DTOs for `ccusage blocks` (5-hour billing windows)

struct CCBlocksReport: Decodable {
    var blocks: [CCBlock]?
}

struct CCBlock: Decodable {
    var startTime: String
    var endTime: String
    var isActive: Bool?
    var isGap: Bool?
    var totalTokens: Int
    var costUSD: Double
    var projection: CCBlockProjection?
    var tokenLimitStatus: CCTokenLimitStatus?
}

struct CCBlockProjection: Decodable {
    var remainingMinutes: Int
    var totalCost: Double
    var totalTokens: Int
}

struct CCTokenLimitStatus: Decodable {
    var limit: Int
    var percentUsed: Double
    var projectedUsage: Int
    var status: String
}

// MARK: - Domain model (what the UI consumes; persisted as the last-success cache)

enum PeriodTab: String, CaseIterable, Sendable {
    case today = "Day"
    case week = "Week"
    case month = "Month"
}

struct ModelStat: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var cost: Double
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var id: String { name }

    init(name: String, cost: Double, totalTokens: Int, inputTokens: Int, outputTokens: Int,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int) {
        self.name = name
        self.cost = cost
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    private enum CodingKeys: String, CodingKey {
        case name, cost, totalTokens, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        cost = try values.decode(Double.self, forKey: .cost)
        totalTokens = try values.decode(Int.self, forKey: .totalTokens)
        inputTokens = try values.decode(Int.self, forKey: .inputTokens)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try values.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try values.decode(Int.self, forKey: .cacheReadTokens)
    }
}

struct AgentStat: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var cost: Double
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var models: [ModelStat]
    var id: String { name }

    init(name: String, cost: Double, totalTokens: Int, inputTokens: Int, outputTokens: Int,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int, models: [ModelStat]) {
        self.name = name
        self.cost = cost
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case name, cost, totalTokens, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, models
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        cost = try values.decode(Double.self, forKey: .cost)
        totalTokens = try values.decode(Int.self, forKey: .totalTokens)
        inputTokens = try values.decode(Int.self, forKey: .inputTokens)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try values.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try values.decode(Int.self, forKey: .cacheReadTokens)
        models = try values.decode([ModelStat].self, forKey: .models)
    }
}

/// One aggregated period (a day, a week, or a month) with full bifurcation.
struct PeriodRow: Codable, Hashable, Identifiable, Sendable {
    var period: String
    var date: Date
    var cost: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int
    var agents: [AgentStat]
    var models: [ModelStat]
    var id: String { period }

    init(period: String, date: Date, cost: Double, inputTokens: Int, outputTokens: Int,
         cacheCreationTokens: Int = 0, cacheReadTokens: Int, totalTokens: Int,
         agents: [AgentStat], models: [ModelStat]) {
        self.period = period
        self.date = date
        self.cost = cost
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.agents = agents
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case period, date, cost, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens
        case totalTokens, agents, models
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        period = try values.decode(String.self, forKey: .period)
        date = try values.decode(Date.self, forKey: .date)
        cost = try values.decode(Double.self, forKey: .cost)
        inputTokens = try values.decode(Int.self, forKey: .inputTokens)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try values.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try values.decode(Int.self, forKey: .cacheReadTokens)
        totalTokens = try values.decode(Int.self, forKey: .totalTokens)
        agents = try values.decode([AgentStat].self, forKey: .agents)
        models = try values.decode([ModelStat].self, forKey: .models)
    }

    static func zero(period: String = "", date: Date = .now) -> PeriodRow {
        PeriodRow(period: period, date: date, cost: 0, inputTokens: 0, outputTokens: 0,
                  cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 0, agents: [], models: [])
    }

    func agentStat(_ name: String) -> AgentStat? {
        agents.first { $0.name == name }
    }
}

/// One provider-reported quota window (e.g. Codex 5h / weekly / monthly).
struct QuotaWindow: Codable, Hashable, Sendable {
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
}

/// Real server-side limits as last reported to the Codex CLI. Read from local
/// session rollouts — freshness depends on when Codex last talked to OpenAI.
struct CodexQuota: Codable, Sendable {
    var windows: [QuotaWindow]
    var planType: String?
    var observedAt: Date?

    /// Windows with a known reset remain usable until that reset. Older Codex
    /// events sometimes omit the reset timestamp; keep those briefly only when
    /// their observation itself is recent enough to be meaningful.
    func activeWindows(now: Date = .now) -> [QuotaWindow] {
        let undatedWindowFreshness: TimeInterval = 60 * 60
        return windows.filter { window in
            if let resetsAt = window.resetsAt {
                return resetsAt > now
            }
            guard let observedAt, observedAt <= now else { return false }
            return now.timeIntervalSince(observedAt) <= undatedWindowFreshness
        }
    }
}

/// The active 5-hour billing block, estimated locally by ccusage from agent
/// logs. "Limit" is the user's own historical peak block, not a provider quota.
struct BlockStat: Codable, Sendable {
    var start: Date
    var end: Date
    var tokens: Int
    var cost: Double
    var projectedCost: Double
    var percentUsed: Double
    var limitStatus: String

    init?(block: CCBlock?) {
        guard let block, block.isActive == true, block.isGap != true else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let start = iso.date(from: block.startTime),
              let end = iso.date(from: block.endTime) else { return nil }
        self.start = start
        self.end = end
        tokens = block.totalTokens
        cost = block.costUSD
        projectedCost = block.projection?.totalCost ?? block.costUSD
        percentUsed = block.tokenLimitStatus?.percentUsed ?? 0
        limitStatus = block.tokenLimitStatus?.status ?? "ok"
    }
}

struct UsageSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var daily: [PeriodRow]
    var weekly: [PeriodRow]
    var monthly: [PeriodRow]
    var activeBlock: BlockStat?
    var codexQuota: CodexQuota?
    var claudeQuota: ClaudeQuota?

    init(fetchedAt: Date, report: CCUnifiedReport, activeBlock: BlockStat?,
         codexQuota: CodexQuota?, claudeQuota: ClaudeQuota?, calendar: Calendar = .current) {
        self.fetchedAt = fetchedAt
        self.activeBlock = activeBlock
        self.codexQuota = codexQuota
        self.claudeQuota = claudeQuota

        func rows(_ source: [CCRow]?, dateFormat: String) -> [PeriodRow] {
            let formatter = DateFormatter()
            formatter.dateFormat = dateFormat
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            return (source ?? []).compactMap { row in
                guard let date = formatter.date(from: row.period) else { return nil }
                let agents = (row.agents ?? [])
                    .map { agent in
                        AgentStat(
                            name: agent.agent, cost: agent.totalCost, totalTokens: agent.totalTokens,
                            inputTokens: agent.inputTokens, outputTokens: agent.outputTokens,
                            cacheCreationTokens: agent.cacheCreationTokens,
                            cacheReadTokens: agent.cacheReadTokens,
                            models: modelStats(agent.modelBreakdowns)
                        )
                    }
                    .sorted { $0.cost > $1.cost }
                return PeriodRow(
                    period: row.period, date: date, cost: row.totalCost,
                    inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                    cacheCreationTokens: row.cacheCreationTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    totalTokens: row.totalTokens, agents: agents,
                    models: modelStats(row.modelBreakdowns)
                )
            }
        }

        func modelStats(_ breakdowns: [CCModelBreakdown]?) -> [ModelStat] {
            (breakdowns ?? [])
                .map {
                    ModelStat(
                        name: $0.modelName, cost: $0.cost,
                        totalTokens: $0.inputTokens + $0.outputTokens
                            + $0.cacheCreationTokens + $0.cacheReadTokens,
                        inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                        cacheCreationTokens: $0.cacheCreationTokens,
                        cacheReadTokens: $0.cacheReadTokens
                    )
                }
                .sorted { $0.cost > $1.cost }
        }

        daily = rows(report.daily, dateFormat: "yyyy-MM-dd")
        weekly = rows(report.weekly, dateFormat: "yyyy-MM-dd")
        monthly = rows(report.monthly, dateFormat: "yyyy-MM")
    }

    /// The row for "now" in the given granularity; zero row when nothing was used yet.
    func currentRow(for tab: PeriodTab, calendar: Calendar = .current) -> PeriodRow {
        let now = Date.now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch tab {
        case .today:
            formatter.dateFormat = "yyyy-MM-dd"
            let key = formatter.string(from: now)
            return daily.first { $0.period == key } ?? .zero(period: key, date: calendar.startOfDay(for: now))
        case .week:
            // ccusage's last weekly row is the week containing today.
            return weekly.last ?? .zero(date: now)
        case .month:
            formatter.dateFormat = "yyyy-MM"
            let key = formatter.string(from: now)
            return monthly.first { $0.period == key } ?? .zero(period: key, date: now)
        }
    }

    func rows(for tab: PeriodTab) -> [PeriodRow] {
        switch tab {
        case .today: daily
        case .week: weekly
        case .month: monthly
        }
    }

    /// Agents ranked by total cost across the loaded window (for tab ordering).
    var agentNames: [String] {
        var totals: [String: Double] = [:]
        for row in monthly {
            for agent in row.agents { totals[agent.name, default: 0] += agent.cost }
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }
}

// MARK: - Formatting helpers

enum Format {
    static func cost(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.0fK", v / 1_000)
        default: return "\(value)"
        }
    }

    static func age(since date: Date, now: Date = .now) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<5: return "just now"
        case ..<60: return "\(s)s ago"
        case ..<3600: return "\(s / 60)m ago"
        default: return "\(s / 3600)h ago"
        }
    }
}
