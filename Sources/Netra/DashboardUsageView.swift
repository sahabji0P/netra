import Charts
import SwiftUI

private enum DashboardMetric: String, CaseIterable {
    case cost = "Cost"
    case tokens = "Tokens"
}

private enum DashboardBreakdown: String, CaseIterable {
    case models = "Models"
    case periods = "Days"
}

/// The Usage page: headline numbers with period-over-period change, the
/// activity chart, provider and token composition, and a filterable table.
struct DashboardUsageView: View {
    @Bindable var store: UsageStore
    @State private var range: DashboardUsageRange = .sevenDays
    @State private var metric: DashboardMetric = .cost
    @State private var breakdown: DashboardBreakdown = .models
    @State private var providerFilter: String?
    @State private var hoveredDate: Date?
    @State private var hoveredProvider: String?

    private var selection: DashboardUsageSelection {
        DashboardUsageAggregator.selection(from: store.snapshot, range: range)
    }

    private var previous: DashboardUsageSelection {
        DashboardUsageAggregator.selection(from: store.snapshot, range: range, periodsBack: 1)
    }

    private var total: PeriodRow { selection.total }

    var body: some View {
        DashboardPage(maxWidth: 1180) {
            DashboardPageHeader(section: .usage) {
                Picker("Range", selection: $range) {
                    ForEach(DashboardUsageRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.state == .refreshing)
            }
            freshnessNotice
            kpis
            activity
            HStack(alignment: .top, spacing: 16) {
                providerShare
                tokenComposition
            }
            breakdownPanel
            provenance
        }
        .navigationTitle("Usage")
        .onAppear { store.refreshIfStale() }
        .onChange(of: range) { providerFilter = nil }
    }

    // MARK: Status

    @ViewBuilder
    private var freshnessNotice: some View {
        switch store.state {
        case .stale:
            let age = store.snapshot.map { Format.age(since: $0.fetchedAt) } ?? "an earlier scan"
            statusBanner("Showing saved usage from \(age). Refresh to check for newer data.",
                         systemImage: "exclamationmark.arrow.triangle.2.circlepath", color: .orange)
        case let .failed(message):
            statusBanner("Usage could not be loaded: \(message)", systemImage: "exclamationmark.triangle", color: .red)
        default:
            EmptyView()
        }
    }

    private func statusBanner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: KPIs

    private var kpis: some View {
        let rows = selection.rows
        let days = Double(range.dayCount)
        let busiest = rows.max { $0.cost < $1.cost }
        return HStack(spacing: 12) {
            KPITile(
                title: "API-equivalent cost", symbol: "dollarsign.circle", tint: .green,
                value: Format.cost(total.cost),
                change: DashboardUsageAggregator.change(from: previous.total.cost, to: total.cost),
                comparison: range.previousCaption,
                spark: rows.map(\.cost)
            )
            .help("What this usage would cost at API list prices — not your subscription bill.")
            KPITile(
                title: "Tokens processed", symbol: "number.circle", tint: .blue,
                value: Format.tokens(total.totalTokens),
                change: DashboardUsageAggregator.change(
                    from: Double(previous.total.totalTokens), to: Double(total.totalTokens)
                ),
                comparison: range.previousCaption,
                spark: rows.map { Double($0.totalTokens) }
            )
            KPITile(
                title: "Cache hit rate", symbol: "memorychip", tint: .purple,
                value: DashboardUsageAggregator.cacheHitRate(total).formatted(.percent.precision(.fractionLength(0))),
                caption: "of input served from cache"
            )
            KPITile(
                title: range == .today ? "Top provider" : "Daily average", symbol: "calendar", tint: .orange,
                value: range == .today
                    ? (total.agents.first.map { AgentPalette.shortName($0.name) } ?? "—")
                    : Format.cost(total.cost / days),
                caption: range == .today
                    ? (total.agents.first.map { Format.cost($0.cost) } ?? "No usage yet")
                    : busiest.map { "Busiest: \($0.date.formatted(.dateTime.month(.abbreviated).day())) · \(Format.cost($0.cost))" } ?? "No usage yet"
            )
        }
    }

    // MARK: Activity

    private var activityPoints: [ProviderActivityPoint] {
        selection.rows.flatMap { row in
            (row.agents + [row.unattributed].compactMap { $0 }).map {
                ProviderActivityPoint(period: row.period, date: row.date, provider: $0.name,
                                      cost: $0.cost, tokens: $0.totalTokens)
            }
        }
    }

    private var hoveredRow: PeriodRow? {
        guard let hoveredDate else { return nil }
        return selection.rows.first { Calendar.current.isDate($0.date, inSameDayAs: hoveredDate) }
    }

    private var activity: some View {
        DashboardPanel(title: "Activity", detail: range.caption, symbol: "chart.bar.xaxis") {
            HStack {
                legend
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(DashboardMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            if activityPoints.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Usage appears after Netra finds local agent logs."))
                    .frame(height: 210)
            } else {
                activityChart
            }
        }
    }

    private var activityChart: some View {
        Chart(activityPoints) { point in
            BarMark(
                x: .value("Day", point.date, unit: .day),
                y: .value(metric.rawValue, point.value(for: metric))
            )
            .foregroundStyle(AgentPalette.color(for: point.provider)
                .opacity(hoveredRow.map { Calendar.current.isDate($0.date, inSameDayAs: point.date) ? 1 : 0.35 } ?? 1))
            .cornerRadius(3)
            if let hoveredRow {
                RuleMark(x: .value("Day", hoveredRow.date, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        activityTooltip(hoveredRow)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // Hover reports chart coordinates; the proxy wants
                            // plot-area ones, which start after the cost axis.
                            let plotX = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0
                            hoveredDate = proxy.value(atX: location.x - plotX)
                        case .ended: hoveredDate = nil
                        }
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.45))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .cost ? Format.cost(number) : Format.tokens(Int(number)))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 230)
    }

    private func activityTooltip(_ row: PeriodRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 10.5, weight: .semibold))
            ForEach(row.agents + [row.unattributed].compactMap { $0 }, id: \.name) { agent in
                HStack(spacing: 6) {
                    Circle().fill(AgentPalette.color(for: agent.name)).frame(width: 6, height: 6)
                    Text(AgentPalette.shortName(agent.name)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(metric == .cost
                         ? Format.providerCost(agent.name, cost: agent.cost, tokens: agent.totalTokens)
                         : Format.tokens(agent.totalTokens))
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }
            Divider()
            HStack {
                Text("Total").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(metric == .cost ? Format.cost(row.cost) : Format.tokens(row.totalTokens))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10.5))
        .padding(9)
        .frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator.opacity(0.6), lineWidth: 0.5) }
    }

    private var legend: some View {
        var seen = Set<String>()
        let providers = activityPoints.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
        return HStack(spacing: 14) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 5) {
                    Circle().fill(AgentPalette.color(for: provider)).frame(width: 8, height: 8)
                    Text(AgentPalette.shortName(provider))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Provider share

    private var providers: [AgentStat] {
        total.agents + [total.unattributed].compactMap { $0 }
    }

    private func share(_ agent: AgentStat) -> Double {
        let value = metric == .cost ? agent.cost : Double(agent.totalTokens)
        let whole = metric == .cost ? total.cost : Double(total.totalTokens)
        return whole > 0 ? value / whole : 0
    }

    private var providerShare: some View {
        DashboardPanel(title: "Providers", detail: "By \(metric.rawValue.lowercased()) · hover for models", symbol: "chart.pie") {
            if providers.isEmpty {
                Text("No provider activity in this period")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    Chart(providers, id: \.name) { agent in
                        SectorMark(
                            angle: .value("Share", max(share(agent), 0.0001)),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .cornerRadius(3)
                        .foregroundStyle(AgentPalette.color(for: agent.name)
                            .opacity(hoveredProvider == nil || hoveredProvider == agent.name ? 1 : 0.35))
                    }
                    .chartLegend(.hidden)
                    .frame(width: 128, height: 128)
                    .overlay {
                        VStack(spacing: 1) {
                            Text(metric == .cost ? Format.cost(focusValue.cost) : Format.tokens(focusValue.tokens))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(hoveredProvider.map(AgentPalette.shortName) ?? "Total")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(providers, id: \.name) { agent in
                            providerLine(agent)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var focusValue: (cost: Double, tokens: Int) {
        if let hoveredProvider, let agent = providers.first(where: { $0.name == hoveredProvider }) {
            return (agent.cost, agent.totalTokens)
        }
        return (total.cost, total.totalTokens)
    }

    private func providerLine(_ agent: AgentStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(AgentPalette.color(for: agent.name)).frame(width: 8, height: 8)
                Text(AgentPalette.displayName(agent.name))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(share(agent).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Format.providerCost(agent.name, cost: agent.cost, tokens: agent.totalTokens))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
                Text(Format.tokens(agent.totalTokens))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
            }
            if hoveredProvider == agent.name {
                VStack(alignment: .leading, spacing: 3) {
                    let models = agent.models.sorted { $0.cost == $1.cost ? $0.totalTokens > $1.totalTokens : $0.cost > $1.cost }
                    if models.isEmpty {
                        Text("No per-model detail").foregroundStyle(.secondary)
                    }
                    ForEach(models.prefix(6)) { model in
                        HStack {
                            Text(AgentPalette.modelDisplayName(model.name)).lineLimit(1)
                            Spacer()
                            Text(Format.tokens(model.totalTokens)).foregroundStyle(.secondary).monospacedDigit()
                            Text(Format.providerCost(agent.name, cost: model.cost, tokens: model.totalTokens))
                                .monospacedDigit()
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                    if models.count > 6 {
                        Text("+\(models.count - 6) more below").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .padding(.leading, 15)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AgentPalette.color(for: agent.name).opacity(0.5)).frame(width: 2).padding(.leading, 3)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredProvider = inside ? agent.name : (hoveredProvider == agent.name ? nil : hoveredProvider)
            }
        }
    }

    // MARK: Token composition

    private var tokenParts: [(label: String, value: Int, color: Color)] {
        var parts: [(String, Int, Color)] = [
            ("Cache reads", total.cacheReadTokens, Color(red: 0.22, green: 0.53, blue: 0.90)),
            ("Uncached input", total.inputTokens, Color(nsColor: .systemGray)),
            ("Cache writes", total.cacheCreationTokens, Color(red: 0.93, green: 0.63, blue: 0)),
            ("Output", total.outputTokens, Color(red: 0.2, green: 0.7, blue: 0.45)),
        ]
        // Some agents (e.g. reasoning tokens in OpenCode) report totals above
        // the four standard parts; show the gap so the rows add up.
        let other = total.totalTokens - parts.reduce(0) { $0 + $1.1 }
        if other > 0 { parts.append(("Other (e.g. reasoning)", other, Color(nsColor: .systemPurple))) }
        return parts
    }

    private var tokenComposition: some View {
        DashboardPanel(title: "Token composition", detail: Format.tokens(total.totalTokens), symbol: "square.stack.3d.down.right") {
            let parts = tokenParts
            let whole = max(parts.reduce(0) { $0 + $1.value }, 1)
            let gaps = 1.5 * Double(max(parts.filter { $0.value > 0 }.count - 1, 0))
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geometry in
                    // Segments share the width left after the gaps, so the
                    // bar ends at the panel edge instead of overflowing it.
                    let available = max(geometry.size.width - gaps, 0)
                    HStack(spacing: 1.5) {
                        ForEach(parts, id: \.label) { part in
                            if part.value > 0 {
                                Rectangle()
                                    .fill(part.color)
                                    .frame(width: max(2, available * Double(part.value) / Double(whole)))
                            }
                        }
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .frame(height: 14)
                ForEach(parts, id: \.label) { part in
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 9, height: 9)
                        Text(part.label).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text((Double(part.value) / Double(whole)).formatted(.percent.precision(.fractionLength(1))))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Format.tokens(part.value))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                Divider()
                HStack {
                    Text("Cache hit rate").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(DashboardUsageAggregator.cacheHitRate(total).formatted(.percent.precision(.fractionLength(1))))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Breakdown table

    private var modelRows: [DashboardModelRow] {
        DashboardUsageAggregator.modelRows(total).filter { providerFilter == nil || $0.provider == providerFilter }
    }

    private var breakdownPanel: some View {
        DashboardPanel(title: "Breakdown", detail: "Ranked by API-equivalent cost", symbol: "tablecells") {
            HStack {
                Picker("Breakdown", selection: $breakdown) {
                    ForEach(DashboardBreakdown.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                if breakdown == .models {
                    Picker("Provider", selection: $providerFilter) {
                        Text("All providers").tag(String?.none)
                        ForEach(providers.map(\.name), id: \.self) { name in
                            Text(AgentPalette.displayName(name)).tag(Optional(name))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            if breakdown == .models { modelTable } else { dayTable }
        }
    }

    private var modelTable: some View {
        let rows = modelRows
        let whole = max(rows.reduce(0) { $0 + $1.cost }, 0.000_001)
        return VStack(spacing: 0) {
            tableHeader(first: "Model", second: "Provider")
            ForEach(rows.prefix(15)) { model in
                tableRow(
                    leading: {
                        HStack(spacing: 8) {
                            Circle().fill(AgentPalette.color(for: model.provider)).frame(width: 8, height: 8)
                            Text(AgentPalette.modelDisplayName(model.name))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    },
                    second: AgentPalette.shortName(model.provider),
                    cost: Format.providerCost(model.provider, cost: model.cost, tokens: model.tokens),
                    share: model.cost / whole,
                    color: AgentPalette.color(for: model.provider),
                    tokens: model.tokens
                )
            }
            if rows.isEmpty {
                Text("No model details in this period")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            } else if rows.count > 15 {
                Text("\(rows.count - 15) smaller models not shown")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private var dayTable: some View {
        let rows = Array(selection.rows.reversed())
        let whole = max(rows.reduce(0) { $0 + $1.cost }, 0.000_001)
        return VStack(spacing: 0) {
            tableHeader(first: "Day", second: "Providers")
            ForEach(rows) { row in
                tableRow(
                    leading: {
                        Text(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.system(size: 12, weight: .medium))
                    },
                    secondView: providerDots(row),
                    cost: Format.cost(row.cost),
                    share: row.cost / whole,
                    color: .accentColor,
                    tokens: row.totalTokens
                )
            }
        }
    }

    private func tableHeader(first: String, second: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(first).frame(maxWidth: .infinity, alignment: .leading)
                Text(second).frame(width: 96, alignment: .leading)
                Text("Share").frame(width: 130, alignment: .leading)
                Text("Cost").frame(width: 80, alignment: .trailing)
                Text("Tokens").frame(width: 76, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.vertical, 7)
            Divider()
        }
    }

    private func tableRow<Leading: View>(
        @ViewBuilder leading: () -> Leading,
        second: String? = nil,
        secondView: AnyView? = nil,
        cost: String,
        share: Double,
        color: Color,
        tokens: Int
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                leading().frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let secondView { secondView } else { Text(second ?? "").foregroundStyle(.secondary) }
                }
                .frame(width: 96, alignment: .leading)
                HStack(spacing: 6) {
                    LimitBar(fraction: share, color: color.opacity(0.75), marker: nil)
                        .frame(width: 84, height: 5)
                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(width: 130, alignment: .leading)
                Text(cost).monospacedDigit().frame(width: 80, alignment: .trailing)
                Text(Format.tokens(tokens)).monospacedDigit().foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
            }
            .font(.system(size: 12))
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func providerDots(_ row: PeriodRow) -> AnyView {
        let names = (row.agents + [row.unattributed].compactMap { $0 }).prefix(6).map(\.name)
        return AnyView(
            HStack(spacing: 4) {
                ForEach(names, id: \.self) { name in
                    Circle().fill(AgentPalette.color(for: name)).frame(width: 8, height: 8)
                        .help(AgentPalette.displayName(name))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Providers: \(names.map(AgentPalette.displayName).joined(separator: ", "))")
        )
    }

    // MARK: Provenance

    private var provenance: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text(store.snapshot?.cursorQuota == nil
                 ? "Calculated on this Mac from coding-agent logs. Transcript contents stay on this Mac."
                 : "Calculated on this Mac from coding-agent logs, plus Cursor's own usage history from cursor.com. Transcript contents stay on this Mac.")
            Spacer()
            Text(store.snapshot.map { "Updated \(Format.age(since: $0.fetchedAt))" } ?? "Waiting for first scan")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// A headline number with an icon, optional change vs the previous period,
/// and an optional sparkline of the period's daily values.
private struct KPITile: View {
    var title: String
    var symbol: String
    var tint: Color
    var value: String
    var change: Double? = nil
    var comparison: String? = nil
    var caption: String? = nil
    var spark: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconTile(symbol: symbol, tint: tint, size: 22)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                if spark.count > 1 {
                    Chart(Array(spark.enumerated()), id: \.offset) { point in
                        AreaMark(x: .value("i", point.offset), y: .value("v", point.element))
                            .foregroundStyle(tint.opacity(0.18))
                        LineMark(x: .value("i", point.offset), y: .value("v", point.element))
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(width: 70, height: 28)
                }
            }
            Group {
                if let change, let comparison {
                    HStack(spacing: 3) {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        Text("\(abs(change).formatted(.percent.precision(.fractionLength(0)))) vs \(comparison)")
                    }
                    .foregroundStyle(.secondary)
                } else if let caption {
                    Text(caption).foregroundStyle(.secondary)
                } else if let comparison {
                    Text("No usage \(comparison) to compare").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.55), lineWidth: 0.5) }
    }
}

private struct ProviderActivityPoint: Identifiable {
    var period: String
    var date: Date
    var provider: String
    var cost: Double
    var tokens: Int
    var id: String { "\(period)-\(provider)" }

    func value(for metric: DashboardMetric) -> Double {
        switch metric {
        case .cost: cost
        case .tokens: Double(tokens)
        }
    }
}
