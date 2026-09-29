import Foundation
import Observation

/// A short message about the last account action, shown in the popover and
/// on the Accounts page until it expires.
struct AccountNotice: Identifiable, Equatable, Sendable {
    var id = UUID()
    var provider: AccountProvider
    var title: String
    var detail: String?
    var isError = false
    var at = Date.now
}

/// The UI's view of managed accounts: which accounts exist, who is live, and
/// the one-click actions. All real work happens in `AccountSwitcher`, off the
/// main actor; this type only publishes results.
@MainActor
@Observable
final class AccountStore {
    private(set) var roster = AccountRoster()
    /// Who each CLI is signed in as right now (from its own files).
    private(set) var liveIdentities: [AccountProvider: AccountIdentity] = [:]
    /// The provider whose switch is in progress.
    private(set) var switching: AccountProvider?
    private(set) var notice: AccountNotice?
    private(set) var pendingSignIn: PendingSignIn?
    private(set) var codexUsesKeyring = false
    /// Called after a successful switch so usage and limits refresh at once.
    @ObservationIgnored var onSwitch: ((AccountProvider) async -> Void)?

    @ObservationIgnored private let switcher: AccountSwitcher
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Preview stores show fixed contents and never touch the real roster.
    @ObservationIgnored private var isPreview = false

    init(switcher: AccountSwitcher = AccountSwitcher(), loadsAutomatically: Bool = true) {
        self.switcher = switcher
        guard loadsAutomatically else { return }
        Task { await reload() }
    }

    /// A store with fixed contents, for previews and tests.
    init(preview roster: AccountRoster, live: [AccountProvider: AccountIdentity], notice: AccountNotice? = nil) {
        switcher = AccountSwitcher(rosterFile: AccountRosterFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("netra-preview-\(UUID().uuidString).json")),
            vault: AccountVault(secrets: InMemorySecretStore()))
        self.roster = roster
        liveIdentities = live
        self.notice = notice
        isPreview = true
    }

    // MARK: Reading

    func accounts(for provider: AccountProvider) -> [ManagedAccount] {
        roster.accounts(for: provider)
    }

    func isManaging(_ provider: AccountProvider) -> Bool {
        !roster.accounts(for: provider).isEmpty
    }

    /// The managed account that is signed in right now, if it is managed.
    func activeAccount(for provider: AccountProvider) -> ManagedAccount? {
        guard let live = liveIdentities[provider] else { return nil }
        return roster.account(matching: live)
    }

    /// Managed accounts that are not signed in, most recently used first.
    func parkedAccounts(for provider: AccountProvider) -> [ManagedAccount] {
        let active = activeAccount(for: provider)?.id
        return roster.accounts(for: provider)
            .filter { $0.id != active }
            .sorted { ($0.lastActiveAt ?? $0.addedAt) > ($1.lastActiveAt ?? $1.addedAt) }
    }

    /// The last limits Netra recorded for whoever is live, used when the CLI
    /// has not reported limits for this account yet (e.g. just switched).
    func lastKnownLimits(for identity: AccountIdentity?) -> AccountLimitsRecord? {
        identity.flatMap { roster.account(matching: $0)?.lastLimits }
    }

    // MARK: Refresh integration

    /// Re-reads the roster and who is signed in.
    func reload() async {
        guard !isPreview else { return }
        roster = await switcher.currentRoster()
        liveIdentities = await switcher.liveIdentities()
        codexUsesKeyring = await switcher.codexUsesKeyring()
    }

    /// After a successful usage refresh: remember the live accounts' limits,
    /// keep their vault copies current, and read parked accounts' limits.
    /// Secondary work — failures leave the previous state.
    func didRefresh(_ snapshot: UsageSnapshot) async {
        guard !isPreview else { return }
        liveIdentities = await switcher.liveIdentities()
        if let identity = liveIdentities[.claude], let quota = snapshot.claudeQuota,
           quota.accountKey == identity.key, quota.source != .lastSeen {
            roster = await switcher.record(
                quota.windows, observedAt: quota.fetchedAt, isLive: quota.source == .oauth, for: identity
            )
        }
        if let identity = liveIdentities[.codex], let quota = snapshot.codexQuota,
           quota.accountKey == identity.key, quota.source != .lastSeen {
            roster = await switcher.record(
                quota.windows, observedAt: quota.observedAt ?? snapshot.fetchedAt,
                isLive: quota.source == .live, for: identity
            )
        }
        roster = await switcher.syncLive()
        roster = await switcher.refreshParked()
    }

    // MARK: Actions

    /// Starts managing a provider by saving its current sign-in.
    func startManaging(_ provider: AccountProvider) async {
        do {
            roster = try await switcher.startManaging(provider)
            liveIdentities = await switcher.liveIdentities()
            if !isManaging(provider) {
                show(AccountNotice(
                    provider: provider, title: "No \(AgentPalette.shortName(provider.agent)) account is signed in",
                    detail: "Sign in to \(AgentPalette.displayName(provider.agent)) first, or add an account.",
                    isError: true
                ))
            }
        } catch {
            show(AccountNotice(provider: provider, title: "Couldn't save the current account",
                               detail: error.localizedDescription, isError: true))
        }
    }

    /// One click: sign the CLI in as `account`.
    func switchTo(_ account: ManagedAccount) async {
        guard switching == nil else { return }
        switching = account.provider
        defer { switching = nil }
        do {
            let (outcome, roster) = try await switcher.switchTo(account.id)
            self.roster = roster
            liveIdentities = await switcher.liveIdentities()
            show(AccountNotice(
                provider: outcome.provider,
                title: "Switched \(AgentPalette.shortName(outcome.provider.agent)) to \(roster.label(for: account))",
                detail: Self.switchDetail(outcome)
            ))
            await onSwitch?(account.provider)
        } catch AccountSwitchError.alreadyActive {
            liveIdentities = await switcher.liveIdentities()
        } catch {
            show(AccountNotice(provider: account.provider, title: "Couldn't switch accounts",
                               detail: error.localizedDescription, isError: true))
        }
    }

    static func switchDetail(_ outcome: AccountSwitchOutcome) -> String {
        let noun = outcome.provider == .claude ? "Claude Code" : "Codex"
        switch outcome.runningSessions {
        case 0:
            return "New \(noun) sessions use it right away."
        case 1:
            return "New sessions use it now; 1 running \(noun) process keeps the previous account until it restarts."
        default:
            return "New sessions use it now; \(outcome.runningSessions) running \(noun) processes keep the previous account until they restart."
        }
    }

    /// Opens Terminal to sign another account in, then imports it as soon as
    /// the sign-in lands. The current sign-in is saved first so it stays one
    /// click away.
    func beginSignIn(_ provider: AccountProvider) async {
        cancelSignIn()
        if !isManaging(provider) { await startManaging(provider) }
        do {
            let pending = try await switcher.beginSignIn(provider)
            pendingSignIn = pending
            signInTask = Task { [weak self] in await self?.waitForSignIn(pending) }
        } catch {
            show(AccountNotice(provider: provider, title: "Couldn't start the sign-in",
                               detail: error.localizedDescription, isError: true))
        }
    }

    private func waitForSignIn(_ pending: PendingSignIn) async {
        let deadline = pending.startedAt.addingTimeInterval(15 * 60)
        while !Task.isCancelled, Date.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            do {
                if let roster = try await switcher.completeSignIn(pending) {
                    self.roster = roster
                    pendingSignIn = nil
                    let added = roster.accounts(for: pending.provider)
                        .max { ($0.addedAt) < ($1.addedAt) }
                    show(AccountNotice(
                        provider: pending.provider,
                        title: "Added \(added?.title ?? "account")",
                        detail: "It's parked and ready — switch to it any time."
                    ))
                    return
                }
            } catch {
                pendingSignIn = nil
                await switcher.cancelSignIn(pending)
                show(AccountNotice(provider: pending.provider, title: "Couldn't add the account",
                                   detail: error.localizedDescription, isError: true))
                return
            }
        }
        if pendingSignIn == pending {
            pendingSignIn = nil
            await switcher.cancelSignIn(pending)
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if let pending = pendingSignIn {
            pendingSignIn = nil
            Task { await switcher.cancelSignIn(pending) }
        }
    }

    func remove(_ account: ManagedAccount) async {
        roster = await switcher.remove(account.id)
    }

    func rename(_ account: ManagedAccount, to nickname: String) async {
        roster = await switcher.rename(account.id, to: nickname)
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private func show(_ notice: AccountNotice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice.isError ? 12 : 8))
            guard !Task.isCancelled, self?.notice?.id == notice.id else { return }
            self?.notice = nil
        }
    }
}
