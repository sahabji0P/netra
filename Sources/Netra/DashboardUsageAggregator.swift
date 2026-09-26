import Foundation

enum DashboardUsageRange: String, CaseIterable, Sendable {
    case today = "Today"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"

    var dayCount: Int {
        switch self {
        case .today: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        }
    }

    var caption: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        }
    }

    /// How the previous equal-length window is named in comparisons.
    var previousCaption: String {
        switch self {
        case .today: "yesterday"
        case .sevenDays: "previous 7 days"
        case .thirtyDays: "previous 30 days"
        case .ninetyDays: "previous 90 days"
        }
    }
}

struct DashboardUsageSelection: Sendable {
    var rows: [PeriodRow]
    var total: PeriodRow
}

/// One model line in the breakdown, attributed to the agent that ran it.
struct DashboardModelRow: Identifiable, Equatable, Sendable {
    var provider: String
    var name: String
    var cost: Double
    var tokens: Int
    var id: String { "\(provider)-\(name)" }
}

/// Pure aggregation behind the Usage page, kept out of the view so every
/// number on it is testable.
enum DashboardUsageAggregator {
    /// Daily rows inside the range ending today, `periodsBack` whole ranges
    /// ago (1 = the equal-length window just before), plus their total.
    static func selection(
        from snapshot: UsageSnapshot?,
        range: DashboardUsageRange,
        periodsBack: Int = 0,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DashboardUsageSelection {
        let today = calendar.startOfDay(for: now)
        let endDay = calendar.date(byAdding: .day, value: -range.dayCount * periodsBack, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: endDay) ?? endDay
        let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? now
        let rows = (snapshot?.daily ?? [])
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.date < $1.date }
        return DashboardUsageSelection(
            rows: rows,
            total: aggregate(rows, period: range.rawValue, date: start)
        )
    }

    static func aggregate(_ rows: [PeriodRow], period: String, date: Date) -> PeriodRow {
        var agentsByName: [String: AgentStat] = [:]
        for agent in rows.flatMap(\.agents) {
            if var total = agentsByName[agent.name] {
                total.cost += agent.cost
                total.totalTokens += agent.totalTokens
                total.inputTokens += agent.inputTokens
                total.outputTokens += agent.outputTokens
                total.cacheCreationTokens += agent.cacheCreationTokens
                total.cacheReadTokens += agent.cacheReadTokens
                total.models = (total.models + agent.models).combinedByName()
                agentsByName[agent.name] = total
            } else {
                agentsByName[agent.name] = agent
            }
        }

        return PeriodRow(
            period: period,
            date: date,
            cost: rows.reduce(0) { $0 + $1.cost },
            inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
            outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
            cacheCreationTokens: rows.reduce(0) { $0 + $1.cacheCreationTokens },
            cacheReadTokens: rows.reduce(0) { $0 + $1.cacheReadTokens },
            totalTokens: rows.reduce(0) { $0 + $1.totalTokens },
            agents: agentsByName.values.sorted { $0.cost > $1.cost },
            models: rows.flatMap(\.models).combinedByName()
        )
    }

    /// Models attributed to their agent. Row-level model usage the agents
    /// don't account for is kept as an "other" line so totals still add up.
    static func modelRows(_ row: PeriodRow) -> [DashboardModelRow] {
        let agentModels = row.agents.flatMap { agent in
            agent.models.map {
                DashboardModelRow(provider: agent.name, name: $0.name, cost: $0.cost, tokens: $0.totalTokens)
            }
        }
        var rows = agentModels
        for model in row.models {
            let attributed = agentModels.filter { $0.name == model.name }
            let residualCost = max(0, model.cost - attributed.reduce(0) { $0 + $1.cost })
            let residualTokens = max(0, model.totalTokens - attributed.reduce(0) { $0 + $1.tokens })
            if residualCost > 0.000_001 || residualTokens > 0 {
                rows.append(DashboardModelRow(
                    provider: agentModels.isEmpty
                        ? (AgentPalette.provider(forModel: model.name) ?? "other")
                        : "other",
                    name: model.name, cost: residualCost, tokens: residualTokens
                ))
            }
        }
        var combined: [String: DashboardModelRow] = [:]
        for row in rows {
            if var existing = combined[row.id] {
                existing.cost += row.cost
                existing.tokens += row.tokens
                combined[row.id] = existing
            } else {
                combined[row.id] = row
            }
        }
        return combined.values.sorted { $0.cost == $1.cost ? $0.tokens > $1.tokens : $0.cost > $1.cost }
    }

    /// Share of all input tokens (uncached + cache writes + cache reads)
    /// that was served from cache.
    static func cacheHitRate(_ row: PeriodRow) -> Double {
        let input = row.inputTokens + row.cacheCreationTokens + row.cacheReadTokens
        guard input > 0 else { return 0 }
        return Double(row.cacheReadTokens) / Double(input)
    }

    /// Relative change from `previous` to `current`; nil when there is no
    /// baseline to compare against.
    static func change(from previous: Double, to current: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}
