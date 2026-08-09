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
}

struct DashboardUsageSelection: Sendable {
    var rows: [PeriodRow]
    var total: PeriodRow
}

enum DashboardUsageAggregator {
    static func selection(
        from snapshot: UsageSnapshot?,
        range: DashboardUsageRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DashboardUsageSelection {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
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
                total.models = aggregateModels(total.models + agent.models)
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
            models: aggregateModels(rows.flatMap(\.models))
        )
    }

    private static func aggregateModels(_ models: [ModelStat]) -> [ModelStat] {
        var byName: [String: ModelStat] = [:]
        for model in models {
            if var total = byName[model.name] {
                total.cost += model.cost
                total.totalTokens += model.totalTokens
                total.inputTokens += model.inputTokens
                total.outputTokens += model.outputTokens
                total.cacheCreationTokens += model.cacheCreationTokens
                total.cacheReadTokens += model.cacheReadTokens
                byName[model.name] = total
            } else {
                byName[model.name] = model
            }
        }
        return byName.values.sorted { $0.cost > $1.cost }
    }
}

struct DashboardUsageView: View {
    @Bindable var store: UsageStore
    @State private var range: DashboardUsageRange = .sevenDays
    @State private var metric: DashboardMetric = .cost
    @State private var breakdown: DashboardBreakdown = .models

    private var selection: DashboardUsageSelection {
        DashboardUsageAggregator.selection(from: store.snapshot, range: range)
    }

    private var currentRow: PeriodRow {
        selection.total
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                freshnessNotice
                limitsStrip
                summary
                activity
                HStack(alignment: .top, spacing: 18) {
                    providerDistribution
                    tokenComposition
                }
                breakdownPanel
                provenance
            }
            .padding(24)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Usage")
        .onAppear { store.refreshIfStale() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage overview")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Local coding-agent activity and estimated API-equivalent cost")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(DashboardUsageRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
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
    }

    @ViewBuilder
    private var freshnessNotice: some View {
        switch store.state {
        case .stale:
            let age = store.snapshot.map { Format.age(since: $0.fetchedAt) } ?? "an earlier scan"
            statusBanner(
                "Showing saved usage from \(age). Refresh to check for newer data.",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                color: .orange
            )
        case let .failed(message):
            statusBanner(
                "Usage could not be loaded: \(message)",
                systemImage: "exclamationmark.triangle",
                color: .red
            )
        default:
            EmptyView()
        }
    }

    private func statusBanner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var limitsStrip: some View {
        DashboardPanel(title: "Usage indicators now", detail: "Provider limits and labelled local estimates") {
            HStack(alignment: .top, spacing: 12) {
                codexLimits
                Divider()
                claudeLocalLimit
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var codexLimits: some View {
        if let quota = store.snapshot?.codexQuota, !activeCodexWindows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                limitHeading(agent: "codex", title: "Codex", source: "Provider reported")
                ForEach(activeCodexWindows, id: \.self) { window in
                    limitRow(label: window.label, percent: window.usedPercent, eventAt: window.resetsAt)
                }
                if let observedAt = quota.observedAt {
                    Text("Observed in a Codex session \(Format.age(since: observedAt))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            emptyLimit(agent: "codex", title: "Codex", detail: "Run Codex once to capture its reported limits")
        }
    }

    @ViewBuilder
    private var claudeLocalLimit: some View {
        if let block = store.snapshot?.activeBlock, block.end > .now {
            VStack(alignment: .leading, spacing: 10) {
                limitHeading(agent: "claude", title: "Claude", source: "Local estimate")
                limitRow(
                    label: "Current 5h block",
                    percent: block.percentUsed,
                    eventAt: block.end,
                    eventVerb: "ends"
                )
                Text("\(Int(block.percentUsed.rounded()))% of your usual historical peak · \(Format.tokens(block.tokens)) processed · \(Format.cost(block.projectedCost)) projected")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            emptyLimit(agent: "claude", title: "Claude · Local estimate", detail: "No active five-hour block")
        }
    }

    private func limitHeading(agent: String, title: String, source: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AgentPalette.color(for: agent))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(source)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    private func limitRow(
        label: String,
        percent: Double,
        eventAt: Date?,
        eventVerb: String = "resets"
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if let eventAt {
                    Text("· \(eventVerb) \(resetText(eventAt))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(limitColor(percent))
                        .frame(width: geometry.size.width * min(max(percent / 100, 0), 1))
                }
            }
            .frame(height: 5)
        }
    }

    private func emptyLimit(agent: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            limitHeading(agent: agent, title: title, source: "Unavailable")
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        HStack(spacing: 0) {
            summaryValue(
                label: "Equivalent API cost",
                value: Format.cost(currentRow.cost),
                detail: "Estimate, not subscription spend"
            )
            Divider().padding(.vertical, 6)
            summaryValue(
                label: "Processed tokens",
                value: Format.tokens(currentRow.totalTokens),
                detail: periodCaption
            )
            Divider().padding(.vertical, 6)
            summaryValue(
                label: "Cache hit rate",
                value: cacheRate.formatted(.percent.precision(.fractionLength(0))),
                detail: "Share of observed input served from cache"
            )
        }
        .padding(.vertical, 4)
    }

    private func summaryValue(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.7)
            Text(value)
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private var activity: some View {
        DashboardPanel(title: "Provider activity", detail: activityDetail) {
            HStack {
                providerLegend
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(DashboardMetric.allCases, id: \.self) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            if activityPoints.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "chart.xyaxis.line", description: Text("Usage will appear after Netra finds local agent transcripts."))
                    .frame(height: 190)
            } else {
                Chart(activityPoints) { point in
                    AreaMark(
                        x: .value("Period", point.date),
                        yStart: .value("Baseline", 0),
                        yEnd: .value(metric.rawValue, point.value(for: metric)),
                        series: .value("Provider", point.provider)
                    )
                    .foregroundStyle(AgentPalette.color(for: point.provider).opacity(0.10))
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value("Period", point.date),
                        y: .value(metric.rawValue, point.value(for: metric)),
                        series: .value("Provider", point.provider)
                    )
                    .foregroundStyle(AgentPalette.color(for: point.provider))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                    if range == .today {
                        PointMark(
                            x: .value("Period", point.date),
                            y: .value(metric.rawValue, point.value(for: metric))
                        )
                        .foregroundStyle(AgentPalette.color(for: point.provider))
                        .symbolSize(48)
                    }
                }
                .chartLegend(.hidden)
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
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel(format: axisDateFormat)
                    }
                }
                .frame(height: 210)
            }
        }
    }

    private var providerLegend: some View {
        HStack(spacing: 14) {
            ForEach(providerNames, id: \.self) { provider in
                HStack(spacing: 5) {
                    Circle()
                        .fill(AgentPalette.color(for: provider))
                        .frame(width: 7, height: 7)
                    Text(AgentPalette.shortName(provider))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var providerDistribution: some View {
        DashboardPanel(title: "Provider distribution", detail: periodCaption) {
            VStack(spacing: 13) {
                ForEach(providerRows) { agent in
                    VStack(spacing: 6) {
                        HStack {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(AgentPalette.color(for: agent.name))
                                    .frame(width: 8, height: 8)
                                Text(AgentPalette.displayName(agent.name))
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            Spacer()
                            Text(Format.cost(agent.cost))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text(Format.tokens(agent.totalTokens))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill(AgentPalette.color(for: agent.name))
                                    .frame(width: geometry.size.width * providerShare(agent))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                if providerRows.isEmpty {
                    Text("No provider activity in this period")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 74)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tokenComposition: some View {
        DashboardPanel(title: "Token composition", detail: "Processed input and output") {
            VStack(spacing: 12) {
                tokenRow("Uncached input", value: currentRow.inputTokens, color: .secondary)
                tokenRow("Cached input", value: currentRow.cacheReadTokens, color: .accentColor)
                tokenRow("Cache writes", value: currentRow.cacheCreationTokens, color: .orange)
                tokenRow("Output", value: currentRow.outputTokens, color: .primary)
                Divider()
                HStack {
                    Text("Cache hit rate")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(cacheRate.formatted(.percent.precision(.fractionLength(1))))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tokenRow(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.tokens(value))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
        }
    }

    private var breakdownPanel: some View {
        DashboardPanel(title: "Breakdown", detail: "Ranked by estimated API-equivalent cost") {
            Picker("Breakdown", selection: $breakdown) {
                ForEach(DashboardBreakdown.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            if breakdown == .models {
                modelBreakdown
            } else {
                periodBreakdown
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(spacing: 0) {
            breakdownHeader(first: "Model")
            ForEach(modelRows.prefix(10)) { model in
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(AgentPalette.color(for: model.provider))
                            .frame(width: 7, height: 7)
                        Text(AgentPalette.modelDisplayName(model.name))
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(AgentPalette.shortName(model.provider))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(Format.cost(model.cost))
                        .monospacedDigit()
                        .frame(width: 86, alignment: .trailing)
                    Text(modelShare(model).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(Format.tokens(model.tokens))
                        .monospacedDigit()
                        .frame(width: 86, alignment: .trailing)
                }
                .font(.system(size: 11))
                .padding(.vertical, 9)
                Divider()
            }
            if modelRows.isEmpty {
                Text("No model details in this period")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            }
        }
    }

    private var periodBreakdown: some View {
        VStack(spacing: 0) {
            breakdownHeader(first: "Day")
            ForEach(chartRows.reversed()) { row in
                HStack(spacing: 12) {
                    Text(row.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    providerDots(row)
                        .frame(width: 92, alignment: .leading)
                    Text(Format.cost(row.cost))
                        .monospacedDigit()
                        .frame(width: 86, alignment: .trailing)
                    Text(row.costShare(of: chartRows).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(Format.tokens(row.totalTokens))
                        .monospacedDigit()
                        .frame(width: 86, alignment: .trailing)
                }
                .font(.system(size: 11))
                .padding(.vertical, 9)
                Divider()
            }
        }
    }

    private func breakdownHeader(first: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(first).frame(maxWidth: .infinity, alignment: .leading)
                Text("Provider").frame(width: 92, alignment: .leading)
                Text("Cost").frame(width: 86, alignment: .trailing)
                Text("Share").frame(width: 64, alignment: .trailing)
                Text("Tokens").frame(width: 86, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.vertical, 7)
            Divider()
        }
    }

    private func providerDots(_ row: PeriodRow) -> some View {
        var providers = row.agents.prefix(5).map(\.name)
        if unattributedAgent(for: row) != nil, !providers.contains("other") {
            providers.append("other")
        }
        return HStack(spacing: 4) {
            ForEach(providers, id: \.self) { provider in
                Circle()
                    .fill(AgentPalette.color(for: provider))
                    .frame(width: 7, height: 7)
                    .help(AgentPalette.displayName(provider))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            providers.isEmpty
                ? "No provider details"
                : "Providers: \(providers.map(AgentPalette.displayName).joined(separator: ", "))"
        )
    }

    private var provenance: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text("Calculated locally from coding-agent transcripts. Transcript contents stay on this Mac.")
            Spacer()
            if let fetchedAt = store.snapshot?.fetchedAt {
                Text("Updated \(Format.age(since: fetchedAt))")
            } else {
                Text("Waiting for first scan")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private var chartRows: [PeriodRow] {
        selection.rows
    }

    private var activityPoints: [ProviderActivityPoint] {
        chartRows.flatMap { row in
            var points = row.agents.map { agent in
                ProviderActivityPoint(
                    period: row.period,
                    date: row.date,
                    provider: agent.name,
                    cost: agent.cost,
                    tokens: agent.totalTokens
                )
            }
            if let other = unattributedAgent(for: row) {
                points.append(ProviderActivityPoint(
                    period: row.period,
                    date: row.date,
                    provider: other.name,
                    cost: other.cost,
                    tokens: other.totalTokens
                ))
            }
            return points
        }
    }

    private var providerRows: [AgentStat] {
        var rows = currentRow.agents
        if let other = unattributedAgent(for: currentRow) {
            rows.append(other)
        }
        return rows
    }

    private func unattributedAgent(for row: PeriodRow) -> AgentStat? {
        let attributedCost = row.agents.reduce(0) { $0 + $1.cost }
        let attributedTotal = row.agents.reduce(0) { $0 + $1.totalTokens }
        let attributedInput = row.agents.reduce(0) { $0 + $1.inputTokens }
        let attributedOutput = row.agents.reduce(0) { $0 + $1.outputTokens }
        let attributedCacheCreation = row.agents.reduce(0) { $0 + $1.cacheCreationTokens }
        let attributedCacheRead = row.agents.reduce(0) { $0 + $1.cacheReadTokens }
        let other = AgentStat(
            name: "other",
            cost: max(0, row.cost - attributedCost),
            totalTokens: max(0, row.totalTokens - attributedTotal),
            inputTokens: max(0, row.inputTokens - attributedInput),
            outputTokens: max(0, row.outputTokens - attributedOutput),
            cacheCreationTokens: max(0, row.cacheCreationTokens - attributedCacheCreation),
            cacheReadTokens: max(0, row.cacheReadTokens - attributedCacheRead),
            models: row.agents.isEmpty ? row.models : []
        )
        let hasUsage = other.cost > 0.000_001 || other.totalTokens > 0 || other.inputTokens > 0 ||
            other.outputTokens > 0 || other.cacheCreationTokens > 0 || other.cacheReadTokens > 0
        return hasUsage ? other : nil
    }

    private var activeCodexWindows: [QuotaWindow] {
        store.snapshot?.codexQuota?.activeWindows() ?? []
    }

    private var providerNames: [String] {
        var seen = Set<String>()
        return activityPoints.compactMap { point in
            seen.insert(point.provider).inserted ? point.provider : nil
        }
    }

    private var activityDetail: String {
        range.caption
    }

    private var axisDateFormat: Date.FormatStyle {
        .dateTime.month(.abbreviated).day()
    }

    private var periodCaption: String {
        range.caption
    }

    private var cacheRate: Double {
        let observedInput = currentRow.inputTokens
            + currentRow.cacheCreationTokens
            + currentRow.cacheReadTokens
        guard observedInput > 0 else { return 0 }
        return Double(currentRow.cacheReadTokens) / Double(observedInput)
    }

    private func providerShare(_ agent: AgentStat) -> Double {
        guard currentRow.cost > 0 else {
            return currentRow.totalTokens > 0 ? Double(agent.totalTokens) / Double(currentRow.totalTokens) : 0
        }
        return min(max(agent.cost / currentRow.cost, 0), 1)
    }

    private var modelRows: [DashboardModelRow] {
        let agentModels = currentRow.agents.flatMap { agent in
            agent.models.map { model in
                DashboardModelRow(
                    provider: agent.name,
                    name: model.name,
                    cost: model.cost,
                    tokens: model.totalTokens
                )
            }
        }
        var rows = agentModels
        for model in currentRow.models {
            let attributed = agentModels.filter { $0.name == model.name }
            let residualCost = max(0, model.cost - attributed.reduce(0) { $0 + $1.cost })
            let residualTokens = max(0, model.totalTokens - attributed.reduce(0) { $0 + $1.tokens })
            if residualCost > 0.000_001 || residualTokens > 0 {
                rows.append(DashboardModelRow(
                    provider: agentModels.isEmpty ? provider(for: model.name) : "other",
                    name: model.name,
                    cost: residualCost,
                    tokens: residualTokens
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
        return combined.values.sorted { $0.cost > $1.cost }
    }

    private func modelShare(_ model: DashboardModelRow) -> Double {
        let total = modelRows.reduce(0) { $0 + $1.cost }
        guard total > 0 else { return 0 }
        return model.cost / total
    }

    private func provider(for model: String) -> String {
        let name = model.lowercased()
        if name.hasPrefix("claude") { return "claude" }
        if name.hasPrefix("gpt") || name.hasPrefix("o1") || name.hasPrefix("o3") { return "codex" }
        return "other"
    }

    private func limitColor(_ percent: Double) -> Color {
        if percent >= 95 { return Color(red: 0.80, green: 0.35, blue: 0.32) }
        if percent >= 75 { return Color(red: 0.83, green: 0.55, blue: 0.25) }
        return .accentColor
    }

    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        let hours = Int(seconds / 3600)
        if hours < 24 {
            let minutes = Int(seconds / 60) % 60
            return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
        }
        return "in \(Int(ceil(seconds / 86_400)))d"
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

private struct DashboardModelRow: Identifiable {
    var provider: String
    var name: String
    var cost: Double
    var tokens: Int
    var id: String { "\(provider)-\(name)" }
}

private extension PeriodRow {
    func costShare(of rows: [PeriodRow]) -> Double {
        let total = rows.reduce(0) { $0 + $1.cost }
        guard total > 0 else { return 0 }
        return cost / total
    }
}
