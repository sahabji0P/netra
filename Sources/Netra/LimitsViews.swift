import SwiftUI

// MARK: - Current 5h block (local estimate from ccusage blocks)

extension MenuView {
    /// Each provider has its own limit system: Claude gets the local 5h-block
    /// estimate, Codex gets the server-reported quota from its session logs.
    /// Shown inline under each agent row on the overview, or below the chart
    /// when that agent's tab is selected — limits have no section of their own.
    @ViewBuilder
    func limitsContent(for agent: String) -> some View {
        switch agent {
        case "claude":
            claudeBlockContent
        case "codex":
            codexQuotaContent
        case "opencode":
            placeholderRow("OpenCode limits", detail: "no unified quota source connected")
        default:
            placeholderRow("\(AgentPalette.displayName(agent)) limits",
                           detail: "tracked server-side · not connected yet")
        }
    }

    @ViewBuilder
    private var claudeBlockContent: some View {
        if let quota = store.snapshot?.claudeQuota, !quota.windows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(quota.windows, id: \.self) { window in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AgentPalette.color(for: "claude"))
                            .frame(width: 6, height: 6)
                        Text("Claude · \(window.label) limit")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let resets = window.resetsAt {
                            Text("resets \(resetText(resets))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    meter(percent: window.usedPercent, status: "ok")
                }
                Text(claudeCaption(quota))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else if let block = store.snapshot?.activeBlock, block.end > .now {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AgentPalette.color(for: "claude"))
                        .frame(width: 6, height: 6)
                    Text("Claude · current 5h block")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("ends in \(remaining(until: block.end, now: context.date))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                meter(percent: block.percentUsed, status: block.limitStatus)
                Text("\(Format.cost(block.cost)) · \(Format.tokens(block.tokens)) tok · \(Int(block.percentUsed.rounded()))% of usual peak · → \(Format.cost(block.projectedCost)) projected")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            placeholderRow("Claude · 5h block", detail: "idle — no active block", dotAgent: "claude")
        }
    }

    @ViewBuilder
    private var codexQuotaContent: some View {
        if let quota = store.snapshot?.codexQuota, !quota.windows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(quota.windows, id: \.self) { window in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AgentPalette.color(for: "codex"))
                            .frame(width: 6, height: 6)
                        Text("Codex · \(window.label) limit")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let resets = window.resetsAt {
                            Text("resets \(resetText(resets))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    meter(percent: window.usedPercent, status: "ok")
                }
                Text(codexCaption(quota))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        } else {
            placeholderRow("Codex limits", detail: "no session data yet — run Codex once", dotAgent: "codex")
        }
    }

    private func claudeCaption(_ quota: ClaudeQuota) -> String {
        var parts: [String] = []
        if let plan = quota.subscriptionType { parts.append("\(plan) plan") }
        // Say how old the number actually is; flag it once it stops being
        // plausibly current (TTL is 5 min, so >15 min means fetches are failing).
        let age = Format.age(since: quota.fetchedAt)
        let isStale = Date.now.timeIntervalSince(quota.fetchedAt) > 900
        parts.append(isStale ? "⚠ stale · Anthropic · \(age)" : "Anthropic · \(age)")
        if let block = store.snapshot?.activeBlock, block.end > .now {
            parts.append("this block \(Format.cost(block.cost)) → \(Format.cost(block.projectedCost)) proj")
        }
        return parts.joined(separator: " · ")
    }

    private func codexCaption(_ quota: CodexQuota) -> String {
        var parts: [String] = ["\(Int(quota.windows[0].usedPercent.rounded()))% used"]
        if let plan = quota.planType { parts.append("\(plan) plan") }
        if let observed = quota.observedAt {
            parts.append("reported by Codex \(Format.age(since: observed))")
        }
        return parts.joined(separator: " · ")
    }

    private func placeholderRow(_ title: String, detail: String, dotAgent: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let dotAgent {
                Circle()
                    .fill(AgentPalette.color(for: dotAgent).opacity(0.5))
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func meter(percent: Double, status: String) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(meterColor(percent: percent, status: status))
                    .frame(width: geo.size.width * min(percent / 100, 1))
            }
        }
        .frame(height: 4)
    }

    private func meterColor(percent: Double, status: String) -> Color {
        if status == "exceeds" || percent >= 95 { return Color(red: 0.80, green: 0.35, blue: 0.32) }
        if status == "warning" || percent >= 75 { return Color(red: 0.83, green: 0.55, blue: 0.25) }
        return .accentColor
    }

    private func resetText(_ date: Date) -> String {
        let hours = date.timeIntervalSinceNow / 3600
        if hours < 24 {
            return "at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "in \(Int((hours / 24).rounded()))d"
    }

    private func remaining(until end: Date, now: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
