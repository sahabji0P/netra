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

    /// The line under a parked account in the switcher: the room it had when
    /// last seen, or that its windows have rolled over since.
    static func switcherDetail(_ account: ManagedAccount, showRemaining: Bool, now: Date = .now) -> String {
        if account.attention != nil { return parkedStatus(account, now: now) }
        let status = parkedStatus(account, now: now)
        let glance = glanceWindows(account.parkedWindows(now: now))
        guard !glance.isEmpty else { return status }
        if glance.allSatisfy(\.hasResetSince) { return "\(status) · limits have reset since" }
        let amounts = glance.map { parked -> String in
            let label = windowShortLabel(parked.window.label)
            if parked.hasResetSince { return "\(label) reset" }
            let used = min(max(parked.window.usedPercent, 0), 100)
            return showRemaining ? "\(label) \(Int((100 - used).rounded()))% left" : "\(label) \(Int(used.rounded()))% used"
        }
        return "\(amounts.joined(separator: " · ")) · \(status.prefix(1).lowercased() + status.dropFirst())"
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

    /// The account control in a card's header: who is signed in, with the
    /// parked accounts beside it, opening the switcher.
    @ViewBuilder
    func accountSwitcher(for agent: String) -> some View {
        if let accounts, let provider = accountProvider(for: agent), accounts.liveIdentities[provider] != nil {
            AccountSwitcherButton(
                accounts: accounts, provider: provider,
                showRemaining: preferences.barsShowRemaining
            ) { showDashboard(.accounts) }
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

/// Who is signed in to a provider, as a face and a name, with the parked
/// accounts as dimmed faces beside it. Clicking opens a list with one Switch
/// button per parked account, so a switch is always a deliberate second click.
struct AccountSwitcherButton: View {
    var accounts: AccountStore
    var provider: AccountProvider
    var showRemaining: Bool
    var manage: () -> Void

    @State private var isOpen = false

    var body: some View {
        let active = accounts.activeAccount(for: provider)
        let parked = accounts.parkedAccounts(for: provider)
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                HStack(spacing: -5) {
                    if let active { AccountAvatar(account: active, size: 16, isActive: true) }
                    ForEach(parked.prefix(2)) { account in
                        AccountAvatar(account: account, size: 16).opacity(0.45)
                    }
                }
                Text(accounts.switching == provider ? "Switching…" : name(active))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Signed in as \(accounts.liveIdentities[provider]?.email ?? "this account"). Click to switch accounts.")
        .accessibilityLabel("\(AgentPalette.shortName(provider.agent)) account: \(name(active)). Switch accounts")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            AccountSwitcherList(
                accounts: accounts, provider: provider, showRemaining: showRemaining,
                manage: manage, dismiss: { isOpen = false }
            )
        }
    }

    private func name(_ active: ManagedAccount?) -> String {
        active.map(accounts.roster.label(for:))
            ?? accounts.liveIdentities[provider]?.email.flatMap { $0.split(separator: "@").first.map(String.init) }
            ?? "Account"
    }
}

/// The switcher's list: the account in use, each parked account with the
/// room it had when last seen and its own Switch button, then add and manage.
struct AccountSwitcherList: View {
    var accounts: AccountStore
    var provider: AccountProvider
    var showRemaining: Bool
    var manage: () -> Void
    var dismiss: () -> Void = {}

    var body: some View {
        let active = accounts.activeAccount(for: provider)
        VStack(alignment: .leading, spacing: 2) {
            if let active {
                row(active, detail: ["In use", active.identity.plan].compactMap { $0 }.joined(separator: " · ")) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if let email = accounts.liveIdentities[provider]?.email {
                Text("Signed in as \(email)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(accounts.parkedAccounts(for: provider)) { account in
                        row(account, detail: AccountText.switcherDetail(account, showRemaining: showRemaining, now: context.date)) {
                            Button("Switch") {
                                dismiss()
                                Task { await accounts.switchTo(account) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(AgentPalette.color(for: provider.agent))
                            .disabled(accounts.switching != nil || account.attention != nil)
                            .accessibilityLabel("Switch to \(account.title)")
                        }
                    }
                }
            }
            Divider().padding(.vertical, 4)
            action("Add \(AgentPalette.shortName(provider.agent)) account…") {
                Task { await accounts.beginSignIn(provider) }
            }
            action("Manage accounts…", manage)
        }
        .padding(8)
        .frame(width: 290, alignment: .leading)
    }

    private func row(_ account: ManagedAccount, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 9) {
            AccountAvatar(account: account, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(accounts.roster.label(for: account))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(account.attention == nil ? Color.secondary : .orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            run()
        } label: {
            Text(title)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One parked account on the Subscriptions page: face, name, freshness, two
/// meters, and the switch button.
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
