import SwiftUI

// MARK: - Provider limit cards (menu popover)

extension MenuView {
    /// Providers with live limits, in the user's order, minus hidden ones.
    var limitCards: [ProviderLimits] {
        (store.snapshot?.providerLimits(order: preferences.orderedLimitProviders) ?? [])
            .filter { preferences.isProviderVisibleInMenu($0.agent) }
    }

    var limitsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(limitCards) { limits in
                limitCard(limits)
            }
            if let reason = missingClaudeLimitsReason {
                missingClaudeCard(reason)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    /// Why Claude has no limit card even though it was used this week, or nil
    /// when a card is showing (or Claude is idle or hidden). Never let the
    /// provider silently vanish.
    var missingClaudeLimitsReason: String? {
        guard let snapshot = store.snapshot,
              preferences.isProviderVisibleInMenu("claude"),
              !limitCards.contains(where: { $0.agent == "claude" }),
              (snapshot.currentRow(for: .week).agentStat("claude")?.totalTokens ?? 0) > 0
        else { return nil }
        if preferences.claudeQuotaEnabled, store.claudeKeychainNeedsApproval {
            return "Netra needs your permission to read Claude Code's sign-in from the Keychain. Choose \u{201C}Always Allow\u{201D} so macOS doesn't ask again."
        }
        if preferences.claudeQuotaEnabled {
            return "Couldn't get live limits from Anthropic. Make sure Claude Code is signed in with your Claude account."
        }
        if snapshot.claudeQuota != nil {
            return "Claude Code's cached limits are out of date. They refresh the next time Claude Code checks your usage."
        }
        return "Claude Code hasn't cached your limits on this Mac — older versions and API-key sign-ins don't."
    }

    private func missingClaudeCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AgentPalette.color(for: "claude"))
                    .frame(width: 8, height: 8)
                Text(AgentPalette.shortName("claude"))
                    .font(.system(size: 13, weight: .semibold))
                Text("Limits unavailable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !preferences.claudeQuotaEnabled || store.claudeKeychainNeedsApproval {
                Button(preferences.claudeQuotaEnabled ? "Allow Keychain access" : "Use live limits from Anthropic") {
                    preferences.claudeQuotaEnabled = true
                    Task { await store.authorizeClaudeKeychain() }
                }
                .controlSize(.small)
                .help("Reads the sign-in Claude Code keeps in your Keychain and fetches your limits from api.anthropic.com. Choose \u{201C}Always Allow\u{201D} when macOS asks.")
            }
        }
    }

    private func limitCard(_ limits: ProviderLimits) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(AgentPalette.color(for: limits.agent))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(AgentPalette.shortName(limits.agent))
                    .font(.system(size: 13, weight: .semibold))
                if let badge = limits.isEstimate ? "estimate" : limits.plan.map(planBadge) {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(freshness(limits, now: context.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ForEach(limits.windows, id: \.self) { window in
                limitWindow(window, agent: limits.agent, isEstimate: limits.isEstimate)
            }
            if let banked = LimitText.bankedResets(limits) {
                Label(banked, systemImage: "arrow.counterclockwise.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AgentPalette.color(for: limits.agent))
                    .help(bankedResetsHelp(limits))
            }
            if let note = limits.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if limits.isEstimate, let block = store.snapshot?.activeBlock {
                Text("Local estimate vs your heaviest 5h block · \(Format.cost(block.cost)) so far")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(panelTarget == .provider(limits.agent) ? Color.primary.opacity(0.05) : .clear)
        )
        .padding(-8)
        .contentShape(Rectangle())
        // Hover a provider's card to slide out its usage breakdown beside
        // the popover; click toggles it where hover is unreliable.
        .onHover { panelHover(.provider(limits.agent), inside: $0) }
        .onTapGesture {
            panelTarget = panelTarget == .provider(limits.agent) ? nil : .provider(limits.agent)
        }
        .popover(isPresented: panelBinding(.provider(limits.agent)), arrowEdge: .leading) {
            detailPanel(for: .provider(limits.agent))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this provider's usage by model")
    }

    /// Sources report plans as "team", "pro", "Max 5x"; show them uniformly.
    private func planBadge(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }

    private func bankedResetsHelp(_ limits: ProviderLimits) -> String {
        let lines = limits.resetCredits.map { credit in
            let title = credit.title ?? "Limit reset"
            return credit.expiresAt.map { "\(title) — expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? title
        }
        return (["Redeem in \(AgentPalette.shortName(limits.agent)) to reset your limits early."] + lines)
            .joined(separator: "\n")
    }

    private func freshness(_ limits: ProviderLimits, now: Date) -> String {
        guard let observed = limits.observedAt else { return limits.source }
        let age = Format.age(since: observed, now: now)
        return age == "just now" ? "\(limits.source) just now" : "\(limits.source) · \(age)"
    }

    private func limitWindow(_ window: QuotaWindow, agent: String, isEstimate: Bool) -> some View {
        LimitWindowRow(
            window: window, agent: agent, isEstimate: isEstimate,
            showRemaining: preferences.barsShowRemaining,
            showsPace: preferences.showsPace,
            resetStyle: preferences.resetTimeStyle
        )
    }
}

/// One limit window — title, amount, bar with pace tick, pace and reset —
/// rendered identically in the popover, the Subscriptions page, and the
/// settings preview.
struct LimitWindowRow: View {
    var window: QuotaWindow
    var agent: String
    var isEstimate = false
    var showRemaining: Bool
    var showsPace: Bool
    var resetStyle: ResetTimeStyle
    var titleSize: CGFloat = 12

    var body: some View {
        let remaining = showRemaining && !isEstimate
        let used = min(max(window.usedPercent, 0), 100)
        let pace = showsPace && !isEstimate ? LimitText.pace(window) : nil
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(LimitText.title(window.label))
                    .font(.system(size: titleSize, weight: .medium))
                Spacer()
                Text(LimitText.amount(window, showRemaining: remaining, isEstimate: isEstimate))
                    .font(.system(size: titleSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LimitStyle.amountColor(usedPercent: window.usedPercent))
            }
            LimitBar(
                fraction: (remaining ? 100 - used : used) / 100,
                color: AgentPalette.color(for: agent),
                marker: pace == nil ? nil : window.elapsedFraction().map { remaining ? 1 - $0 : $0 }
            )
            HStack(spacing: 8) {
                if let pace {
                    Text(LimitText.paceText(pace))
                        .foregroundStyle(Self.paceColor(pace))
                }
                Spacer(minLength: 4)
                if let resetsAt = window.resetsAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(LimitText.reset(resetsAt, style: resetStyle, now: context.date))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: titleSize - 1.5))
            .lineLimit(1)
        }
    }

    static func paceColor(_ pace: LimitText.Pace) -> Color {
        switch pace {
        case .exhausted: LimitStyle.amountColor(usedPercent: 100)
        case .ahead(_, let runsOut) where runsOut != nil: .orange
        default: .secondary
        }
    }
}

/// A thick capsule meter in the provider's color. The optional marker shows
/// where an even pace would be right now.
struct LimitBar: View {
    var fraction: Double
    var color: Color
    var marker: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: max(fraction > 0 ? 6 : 0, width * min(max(fraction, 0), 1)))
                if let marker {
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: 10)
                        .offset(x: min(max(width * marker - 0.75, 0), width - 1.5))
                }
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}
