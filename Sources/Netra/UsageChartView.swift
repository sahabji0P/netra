import Charts
import SwiftUI

// MARK: - Compact provider activity chart

extension MenuView {
    struct ChartPoint: Identifiable {
        var period: String
        var date: Date
        var cost: Double
        var tokens: Int
        var label: String
        var id: String { period }
    }

    private struct ProviderBarPoint: Identifiable {
        var period: String
        var date: Date
        var provider: String
        var cost: Double
        var id: String { "\(period)-\(provider)" }
    }

    /// Monday-first like ccusage's weekly rows, so bars sit on their week.
    private var chartCalendar: Calendar { PeriodKeys.weeks() }

    private var chartPoints: [ChartPoint] {
        let calendar = chartCalendar
        return visibleRows(for: tab).compactMap { row in
            guard row.date >= chartDomain.lowerBound else { return nil }
            let label: String
            switch tab {
            case .today:
                label = row.date.formatted(.dateTime.day().month(.abbreviated))
            case .week:
                label = "W\(calendar.component(.weekOfYear, from: row.date)) · week of \(row.date.formatted(.dateTime.day().month(.abbreviated)))"
            case .month:
                label = row.date.formatted(.dateTime.month(.wide).year())
            }
            return ChartPoint(
                period: row.period,
                date: row.date,
                cost: row.cost,
                tokens: row.totalTokens,
                label: label
            )
        }
    }

    private var providerBarPoints: [ProviderBarPoint] {
        visibleRows(for: tab).flatMap { row -> [ProviderBarPoint] in
            guard row.date >= chartDomain.lowerBound else { return [] }
            var points = row.agents.map {
                ProviderBarPoint(period: row.period, date: row.date, provider: $0.name, cost: $0.cost)
            }
            if let other = row.unattributed, other.cost > 0.000_001 || other.totalTokens > 0 {
                points.append(ProviderBarPoint(
                    period: row.period,
                    date: row.date,
                    provider: "other",
                    cost: other.cost
                ))
            }
            return points
        }
    }

    private var chartUnit: Calendar.Component {
        switch tab {
        case .today: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private var chartDomain: ClosedRange<Date> {
        let calendar = chartCalendar
        let now = Date.now
        switch tab {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(byAdding: .day, value: -30, to: end)! ... end
        case .week:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
            return calendar.date(byAdding: .weekOfYear, value: -11, to: thisWeek.start)! ... thisWeek.end
        case .month:
            let thisMonth = calendar.dateInterval(of: .month, for: now)!
            return calendar.date(byAdding: .month, value: -5, to: thisMonth.start)! ... thisMonth.end
        }
    }

    var hoveredChartPoint: ChartPoint? {
        guard let hoveredPeriod else { return nil }
        return chartPoints.first { $0.period == hoveredPeriod }
    }

    var chart: some View {
        let totals = chartPoints
        let bars = providerBarPoints
        return Chart(bars) { point in
            BarMark(
                x: .value("Period", point.date, unit: chartUnit),
                y: .value("Equivalent API cost", point.cost)
            )
            .foregroundStyle(barColor(for: point.provider, period: point.period))
            .cornerRadius(2)
        }
        .chartXScale(domain: chartDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            switch tab {
            case .today:
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .week:
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text("W\(chartCalendar.component(.weekOfYear, from: date))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .month:
                AxisMarks(values: .stride(by: .month, count: 1)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated)))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(height: 52)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredPeriod = period(atX: location.x, proxy: proxy, points: totals)
                        case .ended:
                            hoveredPeriod = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let hit = period(atX: location.x, proxy: proxy, points: totals) else {
                            selectedPeriod = nil
                            return
                        }
                        selectedPeriod = selectedPeriod == hit ? nil : hit
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 5)
        .padding(.bottom, 9)
    }

    private func period(atX x: CGFloat, proxy: ChartProxy, points: [ChartPoint]) -> String? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return points.last {
            guard let interval = chartCalendar.dateInterval(of: chartUnit, for: $0.date) else {
                return false
            }
            return interval.contains(date)
        }?.period
    }

    private func barColor(for provider: String, period: String) -> Color {
        let opacity: Double
        if period == selectedPeriod || period == hoveredPeriod {
            opacity = 1
        } else if selectedPeriod == nil && hoveredPeriod == nil {
            opacity = 0.85
        } else {
            opacity = 0.35
        }
        return AgentPalette.color(for: provider).opacity(opacity)
    }
}
