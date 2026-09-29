import SwiftUI

/// Every provider's plan limits, larger than the popover, with the
/// provider-specific detail that does not fit there.
struct DashboardSubscriptionsView: View {
    @Bindable var store: UsageStore
    var preferences: AppPreferences
    var navigation: DashboardNavigation
    var accounts: AccountStore? = nil
    /// The sub-navigation: `nil` shows every provider, otherwise one
    /// provider with each of its accounts.
    @State private var focus: String?

    init(
        store: UsageStore, preferences: AppPreferences, navigation: DashboardNavigation,
        accounts: AccountStore? = nil, focus: String? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.navigation = navigation
        self.accounts = accounts
        _focus = State(initialValue: focus)
    }

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
            providerTabs
            if let focus, preferences.orderedLimitProviders.contains(focus) {
                providerPage(focus)
            } else {
                cardGrid {
                    ForEach(limits) { providerCard($0) }
                    ForEach(missing, id: \.self) { unavailableCard($0) }
                }
            }
            Label("Bars use each provider's color; the number turns red at 90%. The tick marks where an even burn to the reset would be.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Subscriptions")
        .onAppear { store.refreshIfStale() }
    }

    private func cardGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 16
        ) {
            content()
        }
    }

    // MARK: Sub-navigation

    private var providerTabs: some View {
        HStack(spacing: 6) {
            tab(title: "All", agent: nil, count: nil)
            ForEach(preferences.orderedLimitProviders, id: \.self) { agent in
                tab(title: AgentPalette.shortName(agent), agent: agent, count: accountCount(agent))
            }
            Spacer()
        }
    }

    private func tab(title: String, agent: String?, count: Int?) -> some View {
        let selected = focus == agent
        let tint = agent.map(AgentPalette.color(for:)) ?? Color.secondary
        return Button {
            focus = agent
        } label: {
            HStack(spacing: 6) {
                if let agent {
                    Circle()
                        .fill(AgentPalette.color(for: agent))
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.8), in: Capsule())
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? tint.opacity(0.18) : Color.clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(selected ? tint.opacity(0.45) : Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Managed accounts for a provider, shown on its tab once there is more
    /// than one.
    private func accountCount(_ agent: String) -> Int? {
        guard let accounts, let provider = AccountProvider(rawValue: agent) else { return nil }
        let count = accounts.roster.accounts(for: provider).count
        return count > 1 ? count : nil
    }

    // MARK: One provider

    /// The signed-in account's limits first, then every parked account at
    /// the same size.
    @ViewBuilder
    private func providerPage(_ agent: String) -> some View {
        let parked = AccountProvider(rawValue: agent).flatMap { accounts?.parkedAccounts(for: $0) } ?? []
        cardGrid {
            if let limits = limits.first(where: { $0.agent == agent }) {
                providerCard(limits, focused: true)
            } else {
                unavailableCard(agent)
            }
            ForEach(parked) { parkedAccountCard($0) }
        }
        if let provider = AccountProvider(rawValue: agent), accounts != nil, parked.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                Text("Use more than one \(AgentPalette.shortName(provider.agent)) account? Add it to switch between them here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Button("Manage accounts…") { navigation.selection = .accounts }
                    .controlSize(.small)
            }
        }
    }

    /// The live account's face, above its limits on a provider tab.
    @ViewBuilder
    private func activeAccountRow(_ agent: String) -> some View {
        if let accounts, let provider = AccountProvider(rawValue: agent),
           let active = accounts.activeAccount(for: provider) {
            HStack(spacing: 9) {
                AccountAvatar(account: active, size: 26, isActive: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(accounts.roster.label(for: active))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(active.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentPalette.color(for: agent))
            }
        }
    }

    /// A parked account at full size: every window it was last seen with,
    /// and the switch.
    private func parkedAccountCard(_ account: ManagedAccount) -> some View {
        let agent = account.provider.agent
        let label = accounts?.roster.label(for: account) ?? account.shortLabel
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                AccountAvatar(account: account, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let plan = account.identity.plan {
                            badge(capitalized(plan))
                        }
                    }
                    Text(account.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(AccountText.parkedStatus(account, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(account.attention == nil ? .secondary : Color.orange)
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let windows = account.parkedWindows(now: context.date)
                VStack(alignment: .leading, spacing: 14) {
                    if windows.isEmpty {
                        Text("Netra hasn't seen this account's limits yet. Switch to it once to read them.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(windows, id: \.self) { parked in
                        if parked.hasResetSince {
                            resetWindowRow(parked.window, agent: agent)
                        } else {
                            LimitWindowRow(
                                window: parked.window, agent: agent,
                                showRemaining: preferences.barsShowRemaining,
                                showsPace: preferences.showsPace,
                                resetStyle: preferences.resetTimeStyle,
                                titleSize: 13
                            )
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Parked · \(account.lastLimits?.isLive == true ? "reported by \(AgentPalette.shortName(agent))" : "last seen in the CLI")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await accounts?.switchTo(account) }
                } label: {
                    if accounts?.switching == account.provider {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Switch to \(label)", systemImage: "arrow.left.arrow.right")
                    }
                }
                .tint(AgentPalette.color(for: agent))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(accounts?.switching != nil || account.attention != nil)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    /// A window that rolled over after Netra last saw it: its old percentage
    /// is no longer this account's usage, so none is shown.
    private func resetWindowRow(_ window: QuotaWindow, agent: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(LimitText.title(window.label))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Reset")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentPalette.color(for: agent))
            }
            LimitBar(fraction: preferences.barsShowRemaining ? 1 : 0, color: AgentPalette.color(for: agent).opacity(0.35), marker: nil)
            Text("Rolled over since Netra last saw it — switch in to read fresh limits")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Cards

    private func providerCard(_ limits: ProviderLimits, focused: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(agent: limits.agent, badge: limits.isEstimate ? "Estimate" : limits.plan.map(capitalized)) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(freshness(limits, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if focused {
                activeAccountRow(limits.agent)
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
            if !focused {
                otherAccounts(limits.agent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
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
                self.badge(badge)
            }
            Spacer()
            trailing()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.7), in: Capsule())
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

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}
