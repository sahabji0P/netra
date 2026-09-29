import SwiftUI

/// Every provider's plan limits, larger than the popover, with the
/// provider-specific detail that does not fit there.
struct DashboardSubscriptionsView: View {
    @Bindable var store: UsageStore
    var preferences: AppPreferences
    var navigation: DashboardNavigation
    var accounts: AccountStore? = nil

    private var limits: [ProviderLimits] {
        store.snapshot?.providerLimits(order: preferences.orderedLimitProviders) ?? []
    }

    private var missing: [String] {
        preferences.orderedLimitProviders.filter { agent in !limits.contains { $0.agent == agent } }
    }

    var body: some View {
        DashboardPage(maxWidth: 1180) {
            DashboardPageHeader(section: .subscriptions) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.state == .refreshing)
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(limits) { providerCard($0) }
                ForEach(missing, id: \.self) { unavailableCard($0) }
            }
            Label("Bars use each provider's color; the number turns red at 90%. The tick marks where an even burn to the reset would be.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Subscriptions")
        .onAppear { store.refreshIfStale() }
    }

    private func providerCard(_ limits: ProviderLimits) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(agent: limits.agent, badge: limits.isEstimate ? "Estimate" : limits.plan.map(capitalized)) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(freshness(limits, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(limits.windows, id: \.self) { window in
                LimitWindowRow(
                    window: window, agent: limits.agent, isEstimate: limits.isEstimate,
                    showRemaining: preferences.barsShowRemaining,
                    showsPace: preferences.showsPace,
                    resetStyle: preferences.resetTimeStyle,
                    titleSize: 13
                )
            }
            if limits.bankedResetCount > 0 {
                bankedResets(limits)
            }
            if let note = limits.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if limits.agent == "claude", limits.isEstimate {
                claudeEstimateDetail
            }
            if limits.agent == "cursor", let quota = store.snapshot?.cursorQuota {
                cursorCycle(quota)
            }
            otherAccounts(limits.agent)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    /// Parked accounts for this provider, each a click away.
    @ViewBuilder
    private func otherAccounts(_ agent: String) -> some View {
        if let accounts, let provider = AccountProvider(rawValue: agent) {
            let parked = accounts.parkedAccounts(for: provider)
            if !parked.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Divider()
                    HStack {
                        Text("Other accounts")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        if let active = accounts.activeAccount(for: provider) {
                            Text("Signed in as \(active.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(parked) { account in
                        ParkedAccountRow(
                            account: account,
                            label: accounts.roster.label(for: account),
                            showRemaining: preferences.barsShowRemaining,
                            isSwitching: accounts.switching == provider,
                            switchDisabled: accounts.switching != nil
                        ) {
                            Task { await accounts.switchTo(account) }
                        }
                    }
                }
            }
        }
    }

    private func bankedResets(_ limits: ProviderLimits) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack {
                Label("Banked resets", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AgentPalette.color(for: limits.agent))
                Spacer()
                Text("\(limits.bankedResetCount) available")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            ForEach(Array(limits.resetCredits.enumerated()), id: \.offset) { _, credit in
                HStack {
                    Text(credit.title ?? "Limit reset")
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer()
                    Text(credit.expiresAt.map { expiry in
                        "Expires \(expiry.formatted(.dateTime.month(.abbreviated).day())) · in \(LimitText.duration(expiry.timeIntervalSinceNow))"
                    } ?? "No expiry")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            Text("Redeem one in \(AgentPalette.shortName(limits.agent)) to reset your limits early. Unused resets expire.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func cardHeader<Trailing: View>(
        agent: String, badge: String?, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(AgentPalette.color(for: agent))
                .frame(width: 4, height: 18)
            Text(AgentPalette.shortName(agent))
                .font(.system(size: 15, weight: .semibold))
            if let badge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            }
            Spacer()
            trailing()
        }
    }

    private func freshness(_ limits: ProviderLimits, now: Date) -> String {
        guard let observed = limits.observedAt else { return limits.source }
        return "\(limits.source) · \(Format.age(since: observed, now: now))"
    }

    private func capitalized(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }

    @ViewBuilder
    private var claudeEstimateDetail: some View {
        if let block = store.snapshot?.activeBlock {
            Text("Compared with your heaviest 5h block of the last 60 days — not an Anthropic quota. \(Format.tokens(block.tokens)) processed · \(Format.cost(block.cost)) so far · \(Format.cost(block.projectedCost)) projected.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Run Claude Code once, or turn on Live Claude limits in Settings → Limits, to see your real subscription limits.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func cursorCycle(_ quota: CursorQuota) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("This billing cycle")
                    .font(.system(size: 12.5, weight: .medium))
                if let start = quota.billingCycleStart, let end = quota.billingCycleEnd {
                    let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
                    Text("\(start.formatted(format)) – \(end.formatted(format))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let value = quota.usageValueUSD {
                    Text(Format.cost(value))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .help("Usage priced at Cursor's API rates, covered by your plan's included and bonus usage — not your bill.")
                }
                Text(Format.tokens(quota.totalTokens))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            let total = max(quota.models.reduce(0) { $0 + $1.cost }, 0.000_001)
            ForEach(quota.models.prefix(6)) { model in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(AgentPalette.modelDisplayName(model.name))
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer()
                        Text(Format.tokens(model.totalTokens))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(model.cost > 0 ? Format.cost(model.cost) : "—")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                    LimitBar(fraction: model.cost / total, color: AgentPalette.color(for: "cursor").opacity(0.55), marker: nil)
                        .frame(height: 4)
                }
            }
            Text(cursorValueCaption(quota))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cursorValueCaption(_ quota: CursorQuota) -> String {
        guard quota.usageValueUSD != nil else {
            return "Cursor isn't reporting API-rate value on this plan — tokens and models still are."
        }
        let billed = quota.onDemandSpendUSD.map { "\(Format.cost($0)) billed as on-demand" } ?? "on-demand spend not reported"
        return "Value at API rates, drawn from your plan's included + bonus usage · \(billed). Excludes Grok Bot, which has its own weekly allowance."
    }

    private func unavailableCard(_ agent: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(agent: agent, badge: "Not available") { EmptyView() }
            Text(unavailableReason(agent))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agent == "cursor", !preferences.cursorUsageEnabled {
                Button("Connect Cursor in Providers…") { navigation.selection = .providers }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                .foregroundStyle(.separator)
        }
    }

    private func unavailableReason(_ agent: String) -> String {
        switch agent {
        case "claude": "No Claude limits yet. Run Claude Code once so it caches your limits, or turn on Live Claude limits."
        case "codex": "No Codex limits yet. Install and sign in to the Codex CLI; Netra asks it for your live limits."
        case "cursor": preferences.cursorUsageEnabled
            ? "Cursor is connected but hasn't reported limits yet. Make sure you're signed in to the Cursor app."
            : "Cursor isn't connected. Turn it on to read your limits and per-request usage from Cursor's own API."
        default: "No limit source."
        }
    }
}
