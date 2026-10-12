import SwiftUI

/// Every saved Claude Code and Codex account, grouped by provider: who is
/// live, how much room each parked account had when last seen, and a
/// one-click switch. Switching happens only when the user clicks; the
/// island never picks an account by itself.
struct IslandAccountsSection: View {
    var accounts: AccountStore
    var preferences: AppPreferences
    var openDashboard: () -> Void

    var body: some View {
        let providers = AccountProvider.allCases.filter {
            preferences.isProviderVisibleInMenu($0.agent)
                && (accounts.isManaging($0) || accounts.liveIdentities[$0] != nil)
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Accounts")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Manage accounts…", action: openDashboard)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .help("Add, rename, or remove accounts in Netra's Accounts page")
            }
            if providers.isEmpty {
                Text("Save your Claude Code or Codex sign-ins in Accounts to switch between them here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(providers) { provider in
                providerGroup(provider)
            }
        }
        .padding(12)
        .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func providerGroup(_ provider: AccountProvider) -> some View {
        let active = accounts.activeAccount(for: provider)
        let parked = accounts.parkedAccounts(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderLogo(agent: provider.agent, size: 12)
                Text(AgentPalette.displayName(provider.agent))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .textCase(.uppercase)
                if accounts.switching == provider {
                    ProgressView().controlSize(.mini)
                    Text("Switching…")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                Spacer()
            }
            if let active {
                IslandActiveAccountRow(
                    account: active, label: accounts.roster.label(for: active),
                    lastLimits: accounts.lastKnownLimits(for: active.identity),
                    showRemaining: preferences.barsShowRemaining
                )
            } else if let live = accounts.liveIdentities[provider] {
                // Signed in, but not one of the saved accounts yet.
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(AgentPalette.color(for: provider.agent))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(live.email ?? "Signed in")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Signed in now · not saved in Netra")
                            .font(.system(size: 9.5))
                            .foregroundStyle(IslandTheme.secondaryText)
                    }
                    Spacer()
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

/// The live account: face, name, plan, and the limits Netra last recorded
/// for it. No switch button — it is already in use.
struct IslandActiveAccountRow: View {
    var account: ManagedAccount
    var label: String
    var lastLimits: AccountLimitsRecord?
    var showRemaining: Bool

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(account: account, size: 20, isActive: true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("In use")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AgentPalette.color(for: account.provider.agent))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AgentPalette.color(for: account.provider.agent).opacity(0.16), in: Capsule())
                }
                let plan = AccountText.planLine(account)
                Text(plan.isEmpty ? account.title : plan)
                    .font(.system(size: 9.5))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let lastLimits {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let windows = lastLimits.windows.map {
                        ParkedWindow(window: $0, hasResetSince: $0.resetsAt.map { $0 <= context.date } ?? false)
                    }
                    HStack(spacing: 8) {
                        ForEach(AccountText.glanceWindows(windows), id: \.self) { parked in
                            AccountMiniMeter(parked: parked, agent: account.provider.agent, showRemaining: showRemaining, width: 50)
                        }
                    }
                }
            }
            // Keeps the meters aligned with the parked rows' switch buttons.
            Color.clear.frame(width: 22, height: 22)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), in use")
    }
}
