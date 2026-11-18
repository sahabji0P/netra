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
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                // The number is the point; a long window name yields first.
                Text(amount(used))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(parked.hasResetSince ? Color.secondary : LimitStyle.amountColor(usedPercent: used))
                    .fixedSize()
                    .layoutPriority(1)
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

    /// Green for something that worked, orange for something that did not.
    /// Not the provider's color: Claude's orange reads as a warning.
    private var tint: Color { notice.isError ? .orange : .green }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(tint)
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
            tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
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

    /// Who is signed in, at the right of a card's header.
    @ViewBuilder
    func accountSwitcher(for agent: String) -> some View {
        if let accounts, let provider = accountProvider(for: agent), accounts.liveIdentities[provider] != nil {
            ActiveAccountLabel(accounts: accounts, provider: provider) { showDashboard(.accounts) }
        }
    }

    /// The provider's parked accounts under its limits, each with its own
    /// switch button: open the popover, click once.
    @ViewBuilder
    func parkedAccounts(for agent: String) -> some View {
        if let accounts, let provider = accountProvider(for: agent),
           !accounts.parkedAccounts(for: provider).isEmpty {
            ParkedAccountsList(accounts: accounts, provider: provider, showRemaining: preferences.barsShowRemaining)
                .padding(.top, 2)
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

/// Who is signed in to a provider: a face and a name at the right of its
/// card header. Switching is done on the parked rows below the limits;
/// clicking this opens the Accounts page, where accounts are added and
/// managed.
struct ActiveAccountLabel: View {
    var accounts: AccountStore
    var provider: AccountProvider
    var manage: () -> Void

    var body: some View {
        let active = accounts.activeAccount(for: provider)
        Button(action: manage) {
            HStack(spacing: 5) {
                if let active { AccountAvatar(account: active, size: 16, isActive: true) }
                Text(accounts.switching == provider ? "Switching…" : name(active))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Signed in as \(accounts.liveIdentities[provider]?.email ?? "this account"). Click to add or manage accounts.")
        .accessibilityLabel("\(AgentPalette.shortName(provider.agent)) account: \(name(active)). Manage accounts")
    }

    private func name(_ active: ManagedAccount?) -> String {
        active.map(accounts.roster.label(for:))
            ?? accounts.liveIdentities[provider]?.email.flatMap { $0.split(separator: "@").first.map(String.init) }
            ?? "Account"
    }
}

/// A provider's parked accounts as one-click rows, shared by the popover's
/// limit cards and the expanded island. Each switch is its own button; the
/// rows themselves do nothing.
struct ParkedAccountsList: View {
    var accounts: AccountStore
    var provider: AccountProvider
    var showRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(accounts.parkedAccounts(for: provider)) { account in
                ParkedAccountRow(
                    account: account,
                    label: accounts.roster.label(for: account),
                    showRemaining: showRemaining,
                    isSwitching: accounts.switchingTo == account.id,
                    switchDisabled: accounts.switching != nil
                ) {
                    Task { await accounts.switchTo(account) }
                }
            }
        }
    }
}

/// One parked account: face, name, freshness, two meters, and the switch
/// button.
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
                        AccountMiniMeter(parked: parked, agent: account.provider.agent, showRemaining: showRemaining, width: 58)
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
