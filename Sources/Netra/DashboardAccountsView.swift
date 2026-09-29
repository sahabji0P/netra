import AppKit
import SwiftUI

/// Settings → Accounts: every managed Claude Code and Codex account, who is
/// signed in, and one-click switching. The shared setup stays put; only the
/// sign-in changes.
struct DashboardAccountsView: View {
    var accounts: AccountStore
    var store: UsageStore
    var preferences: AppPreferences

    @State private var renaming: ManagedAccount?
    @State private var nickname = ""
    @State private var removing: ManagedAccount?

    var body: some View {
        DashboardPage {
            DashboardPageHeader(section: .accounts)
            if let notice = accounts.notice {
                AccountNoticeBanner(notice: notice) { accounts.dismissNotice() }
                    .transition(.opacity)
            }
            sharedSetupPanel
            ForEach(AccountProvider.allCases) { provider in
                providerPanel(provider)
            }
            howItWorksPanel
        }
        .navigationTitle(DashboardSection.accounts.title)
        .animation(.easeOut(duration: 0.2), value: accounts.notice)
        .task { await accounts.reload() }
        .alert("Rename account", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Nickname", text: $nickname)
            Button("Save") {
                if let account = renaming { Task { await accounts.rename(account, to: nickname) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("A short name for \(renaming?.title ?? "this account") in the menu bar. Leave empty to use the email.")
        }
        .confirmationDialog(
            "Remove \(removing?.title ?? "account") from Netra?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let account = removing { Task { await accounts.remove(account) } }
                removing = nil
            }
        } message: {
            Text(removeMessage)
        }
    }

    private var removeMessage: String {
        guard let account = removing else { return "" }
        let isActive = accounts.activeAccount(for: account.provider)?.id == account.id
        return isActive
            ? "Netra forgets its saved copy. You stay signed in to \(AgentPalette.displayName(account.provider.agent)) as this account."
            : "Netra deletes its saved sign-in for this account. To use it again, add it again."
    }

    // MARK: Shared vs switched

    private var sharedSetupPanel: some View {
        DashboardPanel(title: "One setup, every account", symbol: "square.stack.3d.up") {
            HStack(alignment: .top, spacing: 12) {
                explainerColumn(
                    title: "Stays the same", symbol: "lock.fill", tint: .secondary,
                    items: [
                        ("server.rack", "MCP servers and their logins"),
                        ("slider.horizontal.3", "Settings, plugins, skills, and hooks"),
                        ("folder", "Projects, history, and memory"),
                    ]
                )
                explainerColumn(
                    title: "Switches", symbol: "arrow.left.arrow.right", tint: .green,
                    items: [
                        ("person.crop.circle", "Who you're signed in as"),
                        ("gauge.with.dots.needle.50percent", "Plan and limits"),
                        ("bolt.fill", "New sessions, right away"),
                    ]
                )
            }
        }
    }

    private func explainerColumn(title: String, symbol: String, tint: Color, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            ForEach(items, id: \.1) { item in
                Label {
                    Text(item.1).font(.system(size: 12))
                } icon: {
                    Image(systemName: item.0)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Provider panels

    private func providerPanel(_ provider: AccountProvider) -> some View {
        let managed = orderedAccounts(provider)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AgentPalette.color(for: provider.agent))
                    .frame(width: 4, height: 18)
                Text(AgentPalette.displayName(provider.agent))
                    .font(.system(size: 15, weight: .semibold))
                if !managed.isEmpty {
                    Text(managed.count == 1 ? "1 account" : "\(managed.count) accounts")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if accounts.isManaging(provider) {
                    addButton(provider)
                }
            }
            if provider == .codex, accounts.codexUsesKeyring {
                Label(AccountSwitchError.codexKeyring.errorDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            if managed.isEmpty {
                emptyState(provider)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(managed.enumerated()), id: \.element.id) { index, account in
                        accountRow(account)
                            .padding(.vertical, 11)
                        if index < managed.count - 1 { Divider().padding(.leading, 48) }
                    }
                }
            }
            if let pending = accounts.pendingSignIn, pending.provider == provider {
                pendingSignInRow(provider)
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    /// Signed-in account first, then parked ones, most recently used first.
    private func orderedAccounts(_ provider: AccountProvider) -> [ManagedAccount] {
        (accounts.activeAccount(for: provider).map { [$0] } ?? []) + accounts.parkedAccounts(for: provider)
    }

    private func addButton(_ provider: AccountProvider) -> some View {
        Button {
            Task { await accounts.beginSignIn(provider) }
        } label: {
            Label("Add Account…", systemImage: "plus")
        }
        .controlSize(.small)
        .disabled(accounts.pendingSignIn != nil)
        .help("Opens Terminal to sign in to another \(AgentPalette.shortName(provider.agent)) account. Your current sign-in is not touched.")
    }

    private func emptyState(_ provider: AccountProvider) -> some View {
        let live = accounts.liveIdentities[provider]
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AgentPalette.color(for: provider.agent))
                .frame(width: 44, height: 44)
                .background(AgentPalette.color(for: provider.agent).opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(live.map { "Signed in as \($0.email ?? "an account")" } ?? "Not signed in")
                    .font(.system(size: 12.5, weight: .medium))
                Text(live == nil
                     ? "Sign in to \(AgentPalette.displayName(provider.agent)) first, or add an account here."
                     : "Save this account, then add your others. Each one stays a click away in the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if live != nil {
                Button("Save Current Account") {
                    Task { await accounts.startManaging(provider) }
                }
                .controlSize(.small)
            }
            Button {
                Task { await accounts.beginSignIn(provider) }
            } label: {
                Label("Add Account…", systemImage: "plus")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(accounts.pendingSignIn != nil)
        }
    }

    private func accountRow(_ account: ManagedAccount) -> some View {
        let isActive = accounts.activeAccount(for: account.provider)?.id == account.id
        return HStack(alignment: .center, spacing: 12) {
            AccountAvatar(account: account, size: 34, isActive: isActive)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.nickname.flatMap { $0.isEmpty ? nil : $0 } ?? account.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isActive {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(subtitle(account, isActive: isActive, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(account.attention == nil ? .secondary : Color.orange)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 12) {
                    ForEach(AccountText.glanceWindows(account.parkedWindows(now: context.date)), id: \.self) { parked in
                        AccountMiniMeter(
                            parked: parked, agent: account.provider.agent,
                            showRemaining: preferences.barsShowRemaining, width: 72
                        )
                    }
                }
            }
            Group {
                if isActive {
                    Text("Active")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 70)
                } else {
                    Button {
                        Task { await accounts.switchTo(account) }
                    } label: {
                        if accounts.switching == account.provider {
                            ProgressView().controlSize(.small).frame(width: 52)
                        } else {
                            Text("Switch").frame(width: 52)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AgentPalette.color(for: account.provider.agent))
                    .controlSize(.small)
                    .disabled(accounts.switching != nil || account.attention != nil)
                    .frame(width: 70)
                }
            }
            Menu {
                Button("Rename…") {
                    nickname = account.nickname ?? ""
                    renaming = account
                }
                if account.attention != nil || isExpiringSoon(account) {
                    Button("Sign In Again…") { Task { await accounts.beginSignIn(account.provider) } }
                }
                Divider()
                Button("Remove from Netra…", role: .destructive) { removing = account }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }

    private func subtitle(_ account: ManagedAccount, isActive: Bool, now: Date) -> String {
        let plan = AccountText.planLine(account)
        let email = account.nickname?.isEmpty == false ? account.title : nil
        let status = isActive ? "In use now" : AccountText.parkedStatus(account, now: now)
        return [email, plan.isEmpty ? nil : plan, status].compactMap { $0 }.joined(separator: " · ")
    }

    private func isExpiringSoon(_ account: ManagedAccount) -> Bool {
        guard let expires = account.signInExpiresAt else { return false }
        return expires.timeIntervalSinceNow < 3 * 86400
    }

    private func pendingSignInRow(_ provider: AccountProvider) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for you to sign in…")
                    .font(.system(size: 12, weight: .medium))
                Text("Finish signing in in the Terminal window that just opened. Netra adds the account as soon as it's done.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { accounts.cancelSignIn() }
                .controlSize(.small)
        }
        .padding(12)
        .background(AgentPalette.color(for: provider.agent).opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: How it works

    private var howItWorksPanel: some View {
        DashboardPanel(title: "Good to know", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                note("clock.arrow.circlepath", "A switch applies to new sessions at once. Sessions already running keep the previous account until they restart or their sign-in renews.")
                note("person.badge.key", "Adding an account signs in inside a private, temporary folder, so you are never signed out of the account you're using.")
                note("key.horizontal", "Saved sign-ins live only in your login keychain, under \u{201C}Netra Account Vault\u{201D}. Netra never signs you out, and never renews a Claude sign-in itself — switch to a parked Claude account at least every few weeks to keep it fresh.")
                note("gauge.with.dots.needle.33percent", "Parked accounts show the limits Netra last saw, and \u{201C}reset\u{201D} once a window has rolled over. Codex accounts are re-read through the Codex CLI every 15 minutes.")
            }
        }
    }

    private func note(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18)
        }
    }
}
