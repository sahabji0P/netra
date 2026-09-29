import SwiftUI

// MARK: - Shared account components

/// A round monogram in the provider's color — the account's face everywhere.
struct AccountAvatar: View {
    var account: ManagedAccount
    var size: CGFloat = 20
    var isActive = false

    var body: some View {
        let color = AgentPalette.color(for: account.provider.agent)
        Text(account.initials)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .overlay {
                if isActive {
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A tiny labelled meter for one parked window: "5h 34%", or "reset" once
/// the window has rolled over since it was seen.
struct AccountMiniMeter: View {
    var parked: ParkedWindow
    var agent: String
    var showRemaining: Bool
    var width: CGFloat = 54

    var body: some View {
        let used = min(max(parked.window.usedPercent, 0), 100)
        let fraction = parked.hasResetSince ? (showRemaining ? 1 : 0) : (showRemaining ? 100 - used : used) / 100
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(AccountText.windowShortLabel(parked.window.label))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(amount(used))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(parked.hasResetSince ? Color.secondary : LimitStyle.amountColor(usedPercent: used))
            }
            .font(.system(size: 9.5))
            .lineLimit(1)
            LimitBar(fraction: fraction, color: AgentPalette.color(for: agent).opacity(parked.hasResetSince ? 0.35 : 1), marker: nil)
                .frame(height: 3.5)
                .clipShape(Capsule())
        }
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LimitText.title(parked.window.label))
        .accessibilityValue(parked.hasResetSince ? "reset since last seen" : amount(used))
    }

    private func amount(_ used: Double) -> String {
        if parked.hasResetSince { return "reset" }
        return showRemaining ? "\(Int((100 - used).rounded()))%" : "\(Int(used.rounded()))%"
    }
}

/// Text rules for account surfaces, kept out of views so they are testable.
enum AccountText {
    /// "5h", "Wk", "Fable" — the shortest honest name for a window.
    static func windowShortLabel(_ label: String) -> String {
        if label == "weekly" { return "Wk" }
        if label.hasPrefix("weekly · ") { return String(label.dropFirst("weekly · ".count)) }
        return label
    }

    /// The two windows worth a glance: the short session window and the
    /// most-used longer one.
    static func glanceWindows(_ windows: [ParkedWindow]) -> [ParkedWindow] {
        guard let short = windows.min(by: {
            ($0.window.durationSeconds ?? .greatestFiniteMagnitude) < ($1.window.durationSeconds ?? .greatestFiniteMagnitude)
        }) else { return [] }
        let rest = windows.filter { $0 != short }
        guard let long = rest.max(by: { $0.window.usedPercent < $1.window.usedPercent }) else { return [short] }
        return [short, long]
    }

    /// "Limits as of 3h ago", "Sign in again", "Sign-in expires in 2d".
    static func parkedStatus(_ account: ManagedAccount, now: Date = .now) -> String {
        switch account.attention {
        case .signInAgain: return "Sign in again to use this account"
        case .deactivated: return "Account deactivated"
        case nil: break
        }
        if let expires = account.signInExpiresAt {
            let left = expires.timeIntervalSince(now)
            if left <= 0 { return "Saved sign-in expired · sign in again" }
            if left < 3 * 86400 { return "Sign-in expires in \(LimitText.duration(left))" }
        }
        guard let record = account.lastLimits else { return "No limits seen yet" }
        let age = Format.age(since: record.observedAt, now: now)
        return age == "just now" ? "Limits just now" : "Limits as of \(age)"
    }

    static func planLine(_ account: ManagedAccount) -> String {
        [account.identity.plan, account.identity.organizationName.flatMap(meaningfulOrganization)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Personal organizations are named after the person; say nothing then.
    private static func meaningfulOrganization(_ name: String) -> String? {
        let lowered = name.lowercased()
        return lowered.hasSuffix("'s organization") || lowered.hasSuffix("’s organization")
            || lowered == "personal" ? nil : name
    }
}

/// A switch result or error, shown briefly at the top of the popover and on
/// the Accounts page.
struct AccountNoticeBanner: View {
    var notice: AccountNotice
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(notice.isError ? Color.orange : AgentPalette.color(for: notice.provider.agent))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(
            (notice.isError ? Color.orange : AgentPalette.color(for: notice.provider.agent)).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder((notice.isError ? Color.orange : AgentPalette.color(for: notice.provider.agent)).opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Popover

extension MenuView {
    /// The provider behind a limit card, when its account can be switched.
    func accountProvider(for agent: String) -> AccountProvider? {
        guard accounts != nil else { return nil }
        return AccountProvider(rawValue: agent)
    }

    /// The account chip beside a card's plan badge: who is signed in, and a
    /// menu to switch, add, or manage accounts.
    @ViewBuilder
    func accountChip(for agent: String) -> some View {
        if let accounts, let provider = accountProvider(for: agent),
           let live = accounts.liveIdentities[provider] {
            let active = accounts.activeAccount(for: provider)
            Menu {
                accountMenuItems(accounts, provider: provider)
            } label: {
                let name = active.map(accounts.roster.label(for:))
                    ?? live.email.flatMap { $0.split(separator: "@").first.map(String.init) } ?? "Account"
                // One Text, so the borderless menu keeps the chevron after the name.
                Text("\(accounts.switching == provider ? "Switching…" : name) \(Image(systemName: "chevron.down"))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Signed in as \(live.email ?? "this account"). Click to switch accounts.")
            .accessibilityLabel("\(AgentPalette.shortName(agent)) account: \(live.email ?? "unknown")")
        }
    }

    @ViewBuilder
    private func accountMenuItems(_ accounts: AccountStore, provider: AccountProvider) -> some View {
        let managed = accounts.accounts(for: provider)
        let active = accounts.activeAccount(for: provider)
        if managed.count > 1 || (managed.count == 1 && active == nil) {
            Section("Switch \(AgentPalette.displayName(provider.agent)) to") {
                ForEach(managed) { account in
                    Button {
                        Task { await accounts.switchTo(account) }
                    } label: {
                        if account.id == active?.id {
                            Label(menuTitle(account), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(account))
                        }
                    }
                    .disabled(account.id == active?.id || accounts.switching != nil)
                }
            }
        } else if let live = accounts.liveIdentities[provider] {
            Section("Signed in") {
                Text(live.email ?? "This account")
            }
        }
        Divider()
        Button("Add \(AgentPalette.shortName(provider.agent)) account…") {
            Task { await accounts.beginSignIn(provider) }
        }
        Button("Manage Accounts…") { showDashboard(.accounts) }
    }

    private func menuTitle(_ account: ManagedAccount) -> String {
        var parts = [account.nickname.flatMap { $0.isEmpty ? nil : "\($0) — \(account.title)" } ?? account.title]
        if let plan = account.identity.plan { parts.append(plan) }
        if account.id != accounts?.activeAccount(for: account.provider)?.id,
           let glance = AccountText.glanceWindows(account.parkedWindows()).last {
            parts.append(glance.hasResetSince
                ? "\(AccountText.windowShortLabel(glance.window.label)) reset"
                : "\(AccountText.windowShortLabel(glance.window.label)) \(Int(glance.window.usedPercent.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// Parked accounts under the live account's limits: a glance at how much
    /// room each has, and a one-click switch.
    @ViewBuilder
    func parkedAccountsStrip(for agent: String) -> some View {
        if let accounts, let provider = accountProvider(for: agent) {
            let parked = accounts.parkedAccounts(for: provider)
            if !parked.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(.separator.opacity(0.6))
                        .frame(height: 0.5)
                        .padding(.bottom, 1)
                    ForEach(parked.prefix(3)) { account in
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
                    if parked.count > 3 {
                        Button("\(parked.count - 3) more in Accounts") { showDashboard(.accounts) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    /// A switch result, pinned under the header until it expires.
    @ViewBuilder
    var accountNoticeBanner: some View {
        if let accounts, let notice = accounts.notice {
            AccountNoticeBanner(notice: notice) { accounts.dismissNotice() }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// One parked account in the popover: face, name, freshness, two meters, and
/// the switch button.
struct ParkedAccountRow: View {
    var account: ManagedAccount
    var label: String
    var showRemaining: Bool
    var isSwitching = false
    var switchDisabled = false
    var onSwitch: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(account: account, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(AccountText.parkedStatus(account, now: context.date))
                        .font(.system(size: 9.5))
                        .foregroundStyle(account.attention == nil ? .secondary : Color.orange)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 8) {
                    ForEach(AccountText.glanceWindows(account.parkedWindows(now: context.date)), id: \.self) { parked in
                        AccountMiniMeter(parked: parked, agent: account.provider.agent, showRemaining: showRemaining, width: 50)
                    }
                }
            }
            Button(action: onSwitch) {
                Group {
                    if isSwitching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                }
                .frame(width: 22, height: 22)
                .foregroundStyle(hovering ? Color.white : AgentPalette.color(for: account.provider.agent))
                .background(
                    Circle().fill(hovering
                        ? AgentPalette.color(for: account.provider.agent)
                        : AgentPalette.color(for: account.provider.agent).opacity(0.12))
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(switchDisabled || account.attention != nil)
            .onHover { hovering = $0 }
            .help("Switch \(AgentPalette.displayName(account.provider.agent)) to \(account.title)")
            .accessibilityLabel("Switch to \(account.title)")
        }
        .accessibilityElement(children: .contain)
    }
}
