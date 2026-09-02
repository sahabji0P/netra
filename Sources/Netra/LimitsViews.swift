import SwiftUI

// MARK: - Provider limit rows (menu popover)

extension MenuView {
    /// Each provider has its own limit system: Claude gets real subscription
    /// limits when the opt-in OAuth fetch is enabled (falling back to the
    /// clearly-labelled local 5h estimate), Codex gets the server-reported
    /// quota from its session logs. Providers without a limit source render
    /// nothing — Settings explains what can be connected.
    @ViewBuilder
    func limitsContent(for agent: String) -> some View {
        switch agent {
        case "claude":
            claudeLimitContent
        case "codex":
            codexQuotaContent
        case "cursor":
            cursorQuotaContent
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var cursorQuotaContent: some View {
        if let quota = store.snapshot?.cursorQuota {
            let windows = quota.activeWindows()
            if !windows.isEmpty {
                providerLimitBlock(
                    agent: "cursor",
                    title: "Cursor",
                    badge: badgeText(plan: quota.planType, fallback: "reported"),
                    windows: windows,
                    caption: "Reported by Cursor \(Format.age(since: quota.fetchedAt))"
                )
            }
        }
    }

    @ViewBuilder
    private var claudeLimitContent: some View {
        if let quota = store.snapshot?.claudeQuota, !quota.activeWindows().isEmpty {
            providerLimitBlock(
                agent: "claude",
                title: "Claude",
                badge: badgeText(plan: quota.subscriptionType, fallback: "reported"),
                windows: quota.activeWindows(),
                caption: claudeQuotaCaption(quota)
            )
        } else if let block = store.snapshot?.activeBlock, block.end > .now {
            VStack(alignment: .leading, spacing: 5) {
                limitTitleRow(agent: "claude", title: "Claude", badge: "local estimate") {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("block ends in \(remaining(until: block.end, now: context.date))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                limitWindowRow(
                    label: "5h block vs your peak",
                    percent: block.percentUsed,
                    displayText: Format.peakPercent(block.percentUsed),
                    trailing: nil,
                    status: block.limitStatus,
                    agent: "claude"
                )
                Text("\(Format.cost(block.cost)) so far · \(Format.cost(block.projectedCost)) projected this block")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var codexQuotaContent: some View {
        if let quota = store.snapshot?.codexQuota {
            let windows = quota.activeWindows()
            if !windows.isEmpty {
                providerLimitBlock(
                    agent: "codex",
                    title: "Codex",
                    badge: badgeText(plan: quota.planType, fallback: "reported"),
                    windows: windows,
                    caption: quota.observedAt.map {
                        "Reported by Codex \(Format.age(since: $0))"
                    } ?? "From the latest Codex session"
                )
            }
        }
    }

    private func claudeQuotaCaption(_ quota: ClaudeQuota) -> String {
        let age = Format.age(since: quota.fetchedAt)
        switch quota.source {
        case .oauth: return "Reported by Anthropic \(age)"
        case .claudeCodeCache: return "Via Claude Code \(age)"
        }
    }

    private func badgeText(plan: String?, fallback: String) -> String {
        guard let plan, !plan.isEmpty else { return fallback }
        return "\(plan) plan"
    }

    private func providerLimitBlock(
        agent: String,
        title: String,
        badge: String,
        windows: [QuotaWindow],
        caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            limitTitleRow(agent: agent, title: title, badge: badge) {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            ForEach(windows, id: \.self) { window in
                limitWindowRow(
                    label: window.label,
                    percent: window.usedPercent,
                    displayText: "\(Int(window.usedPercent.rounded()))%",
                    trailing: window.resetsAt.map { "resets \(resetText($0))" },
                    status: "ok",
                    agent: agent
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func limitTitleRow(
        agent: String,
        title: String,
        badge: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AgentPalette.color(for: agent))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(badge)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.quaternary.opacity(0.7), in: Capsule())
            Spacer()
            trailing()
        }
    }

    /// One quota window: label, meter, percent, and the reset countdown.
    private func limitWindowRow(
        label: String,
        percent: Double,
        displayText: String,
        trailing: String?,
        status: String,
        agent: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayText)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            meter(percent: percent, status: status, agent: agent)
        }
        .padding(.leading, 12)
    }

    private func meter(percent: Double, status: String, agent: String) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LimitStyle.meterColor(percent: percent, status: status, agent: agent))
                    .frame(width: geo.size.width * min(percent / 100, 1))
            }
        }
        .frame(height: 4)
    }

    private func resetText(_ date: Date) -> String {
        let hours = date.timeIntervalSinceNow / 3600
        if hours < 1 {
            return "in \(max(1, Int(date.timeIntervalSinceNow / 60)))m"
        }
        if hours < 24 {
            return "at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "in \(Int(ceil(hours / 24)))d"
    }

    private func remaining(until end: Date, now: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
