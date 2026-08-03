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
    var burnRate: CCBlockBurnRate?
    var tokenLimitStatus: CCTokenLimitStatus?
}

struct CCBlockProjection: Decodable {
    var remainingMinutes: Int
    var totalCost: Double
    var totalTokens: Int
}

struct CCBlockBurnRate: Decodable {
    var costPerHour: Double
    var tokensPerMinute: Double
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
    var cacheReadTokens: Int
    var id: String { name }
}

struct AgentStat: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var cost: Double
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var models: [ModelStat]
    var id: String { name }
}

/// One aggregated period (a day, a week, or a month) with full bifurcation.
struct PeriodRow: Codable, Hashable, Identifiable, Sendable {
    var period: String
    var date: Date
    var cost: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var totalTokens: Int
    var agents: [AgentStat]
    var models: [ModelStat]
    var id: String { period }

    static func zero(period: String = "", date: Date = .now) -> PeriodRow {
        PeriodRow(period: period, date: date, cost: 0, inputTokens: 0, outputTokens: 0,
                  cacheReadTokens: 0, cacheCreationTokens: 0, totalTokens: 0, agents: [], models: [])
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
    var windowMinutes: Int?
}

/// Real server-side limits as last reported to the Codex CLI. Read from local
/// session rollouts — freshness depends on when Codex last talked to OpenAI.
struct CodexQuota: Codable, Sendable {
    var windows: [QuotaWindow]
    var planType: String?
    var observedAt: Date?
}

/// The active 5-hour billing block, estimated locally by ccusage from agent
/// logs. "Limit" is the user's own historical peak block, not a provider quota.
struct BlockStat: Codable, Sendable {
    var start: Date
    var end: Date
    var tokens: Int
    var cost: Double
    var costPerHour: Double
    var projectedCost: Double
    var limitTokens: Int
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
        costPerHour = block.burnRate?.costPerHour ?? 0
        projectedCost = block.projection?.totalCost ?? block.costUSD
        limitTokens = block.tokenLimitStatus?.limit ?? 0
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

    init(fetchedAt: Date, report: CCUnifiedReport, activeBlock: BlockStat?,
         codexQuota: CodexQuota?, calendar: Calendar = .current) {
        self.fetchedAt = fetchedAt
        self.activeBlock = activeBlock
        self.codexQuota = codexQuota

        func rows(_ source: [CCRow]?, dateFormat: String) -> [PeriodRow] {
            let formatter = DateFormatter()
            formatter.dateFormat = dateFormat
            formatter.calendar = calendar
            return (source ?? []).compactMap { row in
                guard let date = formatter.date(from: row.period) else { return nil }
                let agents = (row.agents ?? [])
                    .map { agent in
                        AgentStat(
                            name: agent.agent, cost: agent.totalCost, totalTokens: agent.totalTokens,
                            inputTokens: agent.inputTokens, outputTokens: agent.outputTokens,
                            cacheReadTokens: agent.cacheReadTokens,
                            models: modelStats(agent.modelBreakdowns)
                        )
                    }
                    .sorted { $0.cost > $1.cost }
                return PeriodRow(
                    period: row.period, date: date, cost: row.totalCost,
                    inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                    cacheReadTokens: row.cacheReadTokens, cacheCreationTokens: row.cacheCreationTokens,
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
