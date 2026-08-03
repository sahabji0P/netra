import SwiftUI

// MARK: - Current 5h block (local estimate from ccusage blocks)

extension MenuView {
    /// Each provider has its own limit system: Claude gets the local 5h-block
    /// estimate, Codex gets the server-reported quota from its session logs.
    /// On the All tab this collapses to one summary line; hovering it opens
    /// the side panel with the full per-provider breakdown.
    var blockSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch selectedAgent {
            case nil:
                limitsSummaryRow
            case "claude":
                claudeBlockContent
            case "codex":
                codexQuotaContent
            case "opencode":
                placeholderRow("OpenCode limits", detail: "no unified quota source connected")
            default:
                placeholderRow("\(AgentPalette.displayName(selectedAgent ?? "")) limits",
                               detail: "tracked server-side · not connected yet")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Limits summary (All tab) + hover side panel

    func setLimitsPanel(hovering: Bool) {
        panelHideTask?.cancel()
        panelHideTask = nil
        if hovering {
            limitsPanelOpen = true
        } else if !limitsPanelPinned {
            // Grace period so the pointer can travel from the summary row
            // into the panel without it collapsing mid-flight.
            panelHideTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                limitsPanelOpen = false
            }
        }
    }

    private var claudeWorstPercent: Double? {
        if let quota = store.snapshot?.claudeQuota,
           let worst = quota.windows.map(\.usedPercent).max() {
            return worst
        }
        if let block = store.snapshot?.activeBlock, block.end > .now {
            return block.percentUsed
        }
        return nil
    }

    private var codexWorstPercent: Double? {
        store.snapshot?.codexQuota?.windows.map(\.usedPercent).max()
    }

    /// Hover peeks at the panel; clicking pins it open (and keyboard/VoiceOver
    /// users get the same toggle, since this is a real button).
    private var limitsSummaryRow: some View {
        Button {
            limitsPanelPinned.toggle()
            if !limitsPanelPinned { setLimitsPanel(hovering: false) }
        } label: {
            HStack(spacing: 10) {
                Text("Limits")
                    .font(.system(size: 11, weight: .medium))
                providerPill(agent: "claude", percent: claudeWorstPercent)
                providerPill(agent: "codex", percent: codexWorstPercent)
                Spacer()
                Text(limitsPanelPinned ? "✕" : (limitsPanelOpen ? "›" : "details ›"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setLimitsPanel(hovering: $0) }
        .accessibilityLabel(limitsAccessibilityLabel)
        .accessibilityHint("Shows per-provider limit details")
    }

    private var limitsAccessibilityLabel: String {
        let claude = claudeWorstPercent.map { "Claude \(Int($0.rounded())) percent used" } ?? "Claude unknown"
        let codex = codexWorstPercent.map { "Codex \(Int($0.rounded())) percent used" } ?? "Codex unknown"
        return "Provider limits. \(claude). \(codex)."
    }

    private func providerPill(agent: String, percent: Double?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AgentPalette.color(for: agent).opacity(percent == nil ? 0.4 : 1))
                .frame(width: 6, height: 6)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(percent.map { meterColor(percent: $0, status: "ok") } ?? .secondary)
        }
    }

    var limitsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider limits")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            claudeBlockContent
            Divider()
            codexQuotaContent
            Divider()
            placeholderRow("OpenCode", detail: "no unified quota source")
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 248, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { setLimitsPanel(hovering: $0) }
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
