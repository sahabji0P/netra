import Charts
import SwiftUI

// MARK: - Chart (granularity follows the period picker)

extension MenuView {
    struct ChartPoint: Identifiable {
        var period: String
        var date: Date
        var cost: Double
        var tokens: Int
        var label: String
        var id: String { period }
    }

    private var chartPoints: [ChartPoint] {
        guard let snapshot = store.snapshot else { return [] }
        let calendar = Calendar.current
        return snapshot.rows(for: tab).compactMap { row in
            guard row.date >= chartDomain.lowerBound else { return nil }
            let cost: Double
            let tokens: Int
            if let selectedAgent {
                let agent = row.agentStat(selectedAgent)
                cost = agent?.cost ?? 0
                tokens = agent?.totalTokens ?? 0
            } else {
                cost = row.cost
                tokens = row.totalTokens
            }
            let label: String
            switch tab {
            case .today:
                label = row.date.formatted(.dateTime.day().month(.abbreviated))
            case .week:
                label = "W\(calendar.component(.weekOfYear, from: row.date)) · wk of \(row.date.formatted(.dateTime.day().month(.abbreviated)))"
            case .month:
                label = row.date.formatted(.dateTime.month(.wide).year())
            }
            return ChartPoint(period: row.period, date: row.date, cost: cost, tokens: tokens, label: label)
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
        let calendar = Calendar.current
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
        let points = chartPoints
        return Chart(points) { point in
            BarMark(
                x: .value("Period", point.date, unit: chartUnit),
                y: .value("Cost", point.cost)
            )
            .foregroundStyle(barColor(for: point.period))
            .cornerRadius(1.5)
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
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            case .week:
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text("W\(Calendar.current.component(.weekOfYear, from: date))")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            case .month:
                AxisMarks(values: .stride(by: .month, count: 1)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated)))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .frame(height: 46)
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredPeriod = period(atX: location.x, proxy: proxy, points: points)
                        case .ended:
                            hoveredPeriod = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let hit = period(atX: location.x, proxy: proxy, points: points) else {
                            selectedPeriod = nil
                            return
                        }
                        // Click a bar to pin it; click it again to unpin.
                        selectedPeriod = (selectedPeriod == hit) ? nil : hit
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func period(atX x: CGFloat, proxy: ChartProxy, points: [ChartPoint]) -> String? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return points.last {
            guard let interval = Calendar.current.dateInterval(of: chartUnit, for: $0.date) else { return false }
            return interval.contains(date)
        }?.period
    }

    private func barColor(for period: String) -> Color {
        if period == selectedPeriod { return .accentColor }
        if period == hoveredPeriod { return .accentColor.opacity(0.65) }
        return .accentColor.opacity(selectedPeriod == nil ? 0.32 : 0.18)
    }
}
