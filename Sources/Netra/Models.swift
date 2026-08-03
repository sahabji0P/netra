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

struct CCModelBreakdown: Decodable {
    var modelName: String
    var cost: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
}

struct CCAgentRow: Decodable {
    var agent: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int
    var totalCost: Double
}

// MARK: - Domain model (what the UI consumes; persisted as the last-success cache)

struct AgentStat: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var cost: Double
    var totalTokens: Int
    var id: String { name }
}

struct ModelStat: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var cost: Double
    var totalTokens: Int
    var id: String { name }
}

struct DayPoint: Codable, Hashable, Identifiable, Sendable {
    var date: Date
    var cost: Double
    var totalTokens: Int
    var id: Date { date }
}

struct PeriodStat: Codable, Hashable, Sendable {
    var period: String
    var cost: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var totalTokens: Int
    var agents: [AgentStat]
    var models: [ModelStat]

    static let zero = PeriodStat(
        period: "", cost: 0, inputTokens: 0, outputTokens: 0,
        cacheReadTokens: 0, cacheCreationTokens: 0, totalTokens: 0, agents: [], models: []
    )
}

struct UsageSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var today: PeriodStat
    var week: PeriodStat
    var month: PeriodStat
    var history: [DayPoint]

    init(fetchedAt: Date, report: CCUnifiedReport, now: Date = .now, calendar: Calendar = .current) {
        self.fetchedAt = fetchedAt

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.calendar = calendar
        let todayKey = dayFormatter.string(from: now)

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"
        monthFormatter.calendar = calendar
        let monthKey = monthFormatter.string(from: now)

        func stat(_ row: CCRow?) -> PeriodStat {
            guard let row else { return .zero }
            let agents = (row.agents ?? [])
                .map { AgentStat(name: $0.agent, cost: $0.totalCost, totalTokens: $0.totalTokens) }
                .sorted { $0.cost > $1.cost }
            let models = (row.modelBreakdowns ?? [])
                .map {
                    ModelStat(
                        name: $0.modelName, cost: $0.cost,
                        totalTokens: $0.inputTokens + $0.outputTokens
                            + $0.cacheCreationTokens + $0.cacheReadTokens
                    )
                }
                .sorted { $0.cost > $1.cost }
            return PeriodStat(
                period: row.period, cost: row.totalCost,
                inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens, cacheCreationTokens: row.cacheCreationTokens,
                totalTokens: row.totalTokens, agents: agents, models: models
            )
        }

        // Daily rows are keyed by date; the current week is the last weekly row
        // (its period is the most recent week-start on or before today).
        today = stat(report.daily?.first { $0.period == todayKey })
        week = stat(report.weekly?.last)
        month = stat(report.monthly?.first { $0.period == monthKey })

        history = (report.daily ?? []).compactMap { row in
            guard let date = dayFormatter.date(from: row.period) else { return nil }
            return DayPoint(date: date, cost: row.totalCost, totalTokens: row.totalTokens)
        }
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
