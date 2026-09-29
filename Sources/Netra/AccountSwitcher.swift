import AppKit
import Foundation

enum AccountSwitchError: LocalizedError, Equatable {
    case alreadyActive
    case unknownAccount
    case savedSignInUnreadable
    case configUnreadable
    case configUnwritable
    case verificationFailed
    case keychainUnavailable
    case locksBusy
    case codexKeyring
    case cliMissing(AccountProvider)
    case signInIncomplete
    /// The live sign-in exists but Netra can't tell whose it is, so it can't
    /// be saved — switching would lose it.
    case liveSignInUnsaved
    /// The Keychain and the profile describe different accounts right now.
    case signInMismatch

    var errorDescription: String? {
        switch self {
        case .alreadyActive: "That account is already signed in."
        case .unknownAccount: "That account is no longer in Netra's list."
        case .savedSignInUnreadable: "Netra's saved sign-in for that account can't be read. Sign in to it again."
        case .configUnreadable: "~/.claude.json is being written right now. Try again in a moment."
        case .configUnwritable: "Couldn't update ~/.claude.json, so nothing was changed."
        case .verificationFailed: "Codex rewrote its sign-in during the switch. Try again."
        case .keychainUnavailable: "The login keychain is locked or busy, so nothing was changed. Try again in a moment."
        case .locksBusy: "Claude Code is refreshing its sign-in right now. Try again in a few seconds."
        case .codexKeyring: "Codex keeps its sign-in in the system keyring (cli_auth_credentials_store), which Netra can't switch."
        case .cliMissing(let provider): "Couldn't find the \(AgentPalette.displayName(provider.agent)) command-line tool."
        case .signInIncomplete: "The sign-in didn't finish, so no account was added."
        case .liveSignInUnsaved: "Netra can't tell which account is signed in right now, so it can't save that sign-in first. Nothing was changed."
        case .signInMismatch: "The sign-in is changing right now (another sign-in or switch is in progress). Try again in a moment."
        }
    }
}

/// What a switch did, in words the popover can show as is.
struct AccountSwitchOutcome: Sendable, Equatable {
    var provider: AccountProvider
    var accountTitle: String
    /// Other CLI processes still holding the previous account in memory.
    var runningSessions: Int
    var daemonRestarted = false
}

/// A new account signing in under a private temporary home.
struct PendingSignIn: Sendable, Equatable {
    var provider: AccountProvider
    var scratch: URL
    var startedAt: Date
}

/// Serializes every change to Netra's roster, vault, and the CLIs' live
/// sign-ins. Captures and switches run without suspending, so one can never
/// interleave with another.
actor AccountSwitcher {
    private let rosterFile: AccountRosterFile
    private let vault: AccountVault
    private let claude: @Sendable () -> ClaudeAccountSession
    private let codex: @Sendable () -> CodexAccountSession
    private let scratchRoot: URL
    private var roster: AccountRoster
    private var loaded = false
    /// Digest of the last sign-in written to the vault per account, so an
    /// unchanged live sign-in is not rewritten on every refresh.
    private var lastCaptured: [UUID: Int] = [:]
    /// Digest of each account's saved tokens alone, so the same tokens are
    /// never filed under a second account (a half-finished switch elsewhere
    /// can pair one account's profile with another's tokens).
    private var tokenDigests: [UUID: Int] = [:]
    private var parkedReadAt: [UUID: Date] = [:]

    init(
        rosterFile: AccountRosterFile = AccountRosterFile(),
        vault: AccountVault = AccountVault(),
        claude: @escaping @Sendable () -> ClaudeAccountSession = { ClaudeAccountSession.current() },
        codex: @escaping @Sendable () -> CodexAccountSession = { CodexAccountSession.current() },
        scratchRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Netra/Scratch", isDirectory: true)
    ) {
        self.rosterFile = rosterFile
        self.vault = vault
        self.claude = claude
        self.codex = codex
        self.scratchRoot = scratchRoot
        roster = AccountRoster()
    }

    // MARK: Roster

    func currentRoster() async -> AccountRoster {
        await loadIfNeeded()
        return roster
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        roster = await rosterFile.load()
        loaded = true
    }

    private func persist() async {
        await rosterFile.save(roster)
    }

    func liveIdentities() -> [AccountProvider: AccountIdentity] {
        var identities: [AccountProvider: AccountIdentity] = [:]
        identities[.claude] = claude().liveIdentity()
        identities[.codex] = codex().liveIdentity()
        return identities
    }

    func codexUsesKeyring() -> Bool {
        codex().usesKeyringStorage
    }

    // MARK: Capturing the live sign-in

    /// Keeps the vault copy of each live, managed account current, and adopts
    /// a live account the user signed in to outside Netra (its sign-in exists
    /// nowhere else). Providers the user never started managing are untouched.
    func syncLive() async -> AccountRoster {
        await loadIfNeeded()
        for provider in AccountProvider.allCases where !roster.accounts(for: provider).isEmpty {
            // No locks here: Claude Code writes ~/.claude.json often and its
            // locks don't retry. `captureLive` re-checks the profile after
            // the Keychain read instead, so a torn pair is never saved.
            _ = try? captureLive(provider, adopt: true)
        }
        await persist()
        return roster
    }

    /// Starts managing `provider` by saving whoever is signed in now.
    func startManaging(_ provider: AccountProvider) async throws -> AccountRoster {
        await loadIfNeeded()
        _ = try captureLive(provider, adopt: true)
        await persist()
        return roster
    }

    /// Saves the live sign-in into the vault. Returns the account it belongs
    /// to, or nil when nobody is signed in. Throws when the sign-in exists
    /// but cannot be read — callers must then leave the live sign-in alone.
    @discardableResult
    private func captureLive(_ provider: AccountProvider, adopt: Bool) throws -> UUID? {
        let captured: (identity: AccountIdentity, entry: VaultEntry, expires: Date?)?
        switch provider {
        case .claude:
            do {
                captured = try claude().captureLive().map { ($0.identity, $0.entry, $0.signInExpiresAt) }
            } catch SecretStoreError.unavailable {
                throw AccountSwitchError.keychainUnavailable
            }
        case .codex:
            captured = codex().captureLive().map { ($0.identity, $0.entry, nil) }
        }
        guard let captured else { return nil }
        guard adopt || roster.account(matching: captured.identity) != nil else { return nil }
        let tokens = Self.tokenDigest(captured.entry)
        if let owner = roster.account(matching: captured.identity)?.id,
           tokenDigests.contains(where: { $0.key != owner && $0.value == tokens }) {
            throw AccountSwitchError.signInMismatch
        }
        let id = roster.upsert(captured.identity)
        let digest = Self.digest(captured.entry)
        if lastCaptured[id] != digest {
            try vault.save(captured.entry, for: id)
            lastCaptured[id] = digest
        }
        tokenDigests[id] = tokens
        roster.update(id) { account in
            account.lastActiveAt = .now
            account.attention = nil
            if let expires = captured.expires { account.signInExpiresAt = expires }
        }
        return id
    }

    private static func tokenDigest(_ entry: VaultEntry) -> Int {
        var hasher = Hasher()
        if let data = entry.claudeCredentials,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = object["claudeAiOauth"] as? [String: Any] {
            hasher.combine(oauth["refreshToken"] as? String)
            hasher.combine(oauth["accessToken"] as? String)
        }
        if let data = entry.codexAuth,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = object["tokens"] as? [String: Any] {
            hasher.combine(tokens["refresh_token"] as? String)
        }
        return hasher.finalize()
    }

    private static func digest(_ entry: VaultEntry) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.claudeCredentials)
        hasher.combine(entry.claudeProfile)
        hasher.combine(entry.codexAuth)
        return hasher.finalize()
    }

    // MARK: Switching

    /// Makes a parked account the live one. The displaced sign-in is captured
    /// first (its tokens may have rotated since the last sync), and nothing
    /// live changes unless every earlier step succeeded.
    func switchTo(_ id: UUID) async throws -> (AccountSwitchOutcome, AccountRoster) {
        await loadIfNeeded()
        guard let target = roster.account(id: id) else { throw AccountSwitchError.unknownAccount }
        let entry: VaultEntry
        do {
            entry = try vault.load(id)
        } catch SecretStoreError.unavailable {
            throw AccountSwitchError.keychainUnavailable
        } catch {
            throw AccountSwitchError.savedSignInUnreadable
        }
        let outcome: AccountSwitchOutcome
        do {
            outcome = try performSwitch(to: target, entry: entry)
        } catch let error as SecretStoreError {
            throw error == .notFound ? AccountSwitchError.liveSignInUnsaved : AccountSwitchError.keychainUnavailable
        }
        lastCaptured[id] = Self.digest(entry)
        tokenDigests[id] = Self.tokenDigest(entry)
        roster.update(id) { account in
            account.lastActiveAt = .now
            account.attention = nil
        }
        roster.recordSwitch(target.provider)
        await persist()
        return (outcome, roster)
    }

    /// The synchronous part of a switch: nothing here may suspend, so no
    /// other roster or vault change can interleave with it.
    private func performSwitch(to target: ManagedAccount, entry: VaultEntry) throws -> AccountSwitchOutcome {
        let outcome: AccountSwitchOutcome
        switch target.provider {
        case .claude:
            let session = claude()
            if let live = session.liveIdentity(), live.isSameAccount(as: target.identity) {
                throw AccountSwitchError.alreadyActive
            }
            do {
                try session.withLocks { keepAlive in
                    // Save the displaced sign-in first. One Netra can't
                    // identify must not be overwritten: it exists nowhere else.
                    if try captureLive(.claude, adopt: true) == nil {
                        let live = try? session.liveCredentials()
                        if live?["claudeAiOauth"] != nil { throw AccountSwitchError.liveSignInUnsaved }
                    }
                    keepAlive()
                    try session.install(entry, keepAlive: keepAlive)
                }
            } catch is ProperLockfile.Failure {
                throw AccountSwitchError.locksBusy
            }
            ClaudeQuotaFetcher.invalidateCachedCredentials()
            outcome = AccountSwitchOutcome(
                provider: .claude, accountTitle: target.title,
                runningSessions: RunningAgents.count(named: "claude")
            )
        case .codex:
            let session = codex()
            guard !session.usesKeyringStorage else { throw AccountSwitchError.codexKeyring }
            if let live = session.liveIdentity(), live.isSameAccount(as: target.identity) {
                throw AccountSwitchError.alreadyActive
            }
            if try captureLive(.codex, adopt: true) == nil, session.liveAuth() != nil {
                throw AccountSwitchError.liveSignInUnsaved
            }
            try session.install(entry) { landed in
                // A running Codex process just rotated the displaced
                // account's tokens; keep them rather than lose them.
                guard let identity = CodexAccountSession.identity(fromAuth: landed),
                      let owner = roster.account(matching: identity) else { return }
                try? vault.save(VaultEntry(provider: .codex, capturedAt: .now, codexAuth: landed), for: owner.id)
                lastCaptured[owner.id] = nil
            }
            let restarted = session.restartDaemonIfRunning()
            outcome = AccountSwitchOutcome(
                provider: .codex, accountTitle: target.title,
                runningSessions: RunningAgents.count(named: "codex"),
                daemonRestarted: restarted
            )
        }
        return outcome
    }

    // MARK: Adding accounts

    /// Opens Terminal to sign a new account in under a private temporary
    /// home, so the live sign-in is never logged out or revoked.
    func beginSignIn(_ provider: AccountProvider) throws -> PendingSignIn {
        let scratch = scratchRoot.appendingPathComponent("sign-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let script: String
        switch provider {
        case .claude:
            guard let binary = Self.claudeBinary() else { throw AccountSwitchError.cliMissing(.claude) }
            script = """
            #!/bin/zsh
            export CLAUDE_CONFIG_DIR=\(Self.shellQuoted(scratch.path))
            clear
            print -P "%BSign in to another Claude account for Netra%b"
            print "Your current Claude Code sign-in stays as it is."
            print
            \(Self.shellQuoted(binary)) auth login --claudeai
            touch \(Self.shellQuoted(scratch.appendingPathComponent(Self.doneMarker).path))
            print
            print -P "%BDone.%b Return to Netra — you can close this window."
            """
        case .codex:
            guard let binary = CodexLiveQuota.resolveBinary()?.path else { throw AccountSwitchError.cliMissing(.codex) }
            script = """
            #!/bin/zsh
            export CODEX_HOME=\(Self.shellQuoted(scratch.path))
            clear
            print -P "%BSign in to another ChatGPT account for Netra%b"
            print "Your current Codex sign-in stays as it is."
            print
            \(Self.shellQuoted(binary)) login
            touch \(Self.shellQuoted(scratch.appendingPathComponent(Self.doneMarker).path))
            print
            print -P "%BDone.%b Return to Netra — you can close this window."
            """
        }
        let command = scratchRoot.appendingPathComponent("\(provider.rawValue)-sign-in.command")
        try Data(script.utf8).write(to: command, options: .atomic)
        chmod(command.path, 0o700)
        let opened = try ProcessRunner.run("/usr/bin/open", ["-a", "Terminal", command.path], timeout: 10)
        guard opened.status == 0 else { throw AccountSwitchError.signInIncomplete }
        return PendingSignIn(provider: provider, scratch: scratch, startedAt: .now)
    }

    /// Imports the account once its temporary sign-in exists, then deletes
    /// the temporary copy so only the vault holds it. Nil while waiting.
    func completeSignIn(_ pending: PendingSignIn) async throws -> AccountRoster? {
        await loadIfNeeded()
        // The script marks the CLI's exit, so a sign-in still being written
        // is never imported half-done.
        guard FileManager.default.fileExists(atPath: pending.scratch.appendingPathComponent(Self.doneMarker).path)
        else { return nil }
        let imported: (identity: AccountIdentity, entry: VaultEntry, expires: Date?)?
        let temporary: ClaudeAccountSession?
        switch pending.provider {
        case .claude:
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = pending.scratch.path
            environment.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
            let session = ClaudeAccountSession.current(environment: environment, secrets: vault.secrets)
            temporary = session
            imported = try Self.importClaude(session)
        case .codex:
            temporary = nil
            imported = CodexAccountSession(home: pending.scratch).captureLive().map { ($0.identity, $0.entry, nil) }
        }
        guard let imported else {
            // The CLI exited without a sign-in (cancelled or failed).
            cancelSignIn(pending)
            throw AccountSwitchError.signInIncomplete
        }
        let id = roster.upsert(imported.identity)
        try vault.save(imported.entry, for: id)
        lastCaptured[id] = Self.digest(imported.entry)
        roster.update(id) { account in
            account.attention = nil
            if let expires = imported.expires { account.signInExpiresAt = expires }
        }
        await persist()
        if let temporary {
            try? vault.secrets.delete(service: temporary.keychainService, account: temporary.keychainAccount)
        }
        cancelSignIn(pending)
        return roster
    }

    /// A temporary Claude sign-in: the hashed Keychain item, or the plaintext
    /// `.credentials.json` Claude Code falls back to.
    private static func importClaude(_ session: ClaudeAccountSession) throws -> (AccountIdentity, VaultEntry, Date?)? {
        if let captured = try? session.captureLive() {
            return (captured.identity, captured.entry, captured.signInExpiresAt)
        }
        let file = session.configHome.appendingPathComponent(".credentials.json")
        guard let configData = try? Data(contentsOf: session.configFile),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let profile = config["oauthAccount"] as? [String: Any],
              let data = try? Data(contentsOf: file),
              let credentials = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let identity = ClaudeAccountSession.identity(
                  fromProfile: profile, subscriptionType: oauth["subscriptionType"] as? String
              )
        else { return nil }
        let owned = credentials.filter { ClaudeAccountSession.accountOwnedCredentialKeys.contains($0.key) }
        let entry = VaultEntry(
            provider: .claude, capturedAt: .now,
            claudeCredentials: try JSONSerialization.data(withJSONObject: owned),
            claudeProfile: try JSONSerialization.data(withJSONObject: profile)
        )
        return (identity, entry, ClaudeAccountSession.signInExpiry(owned))
    }

    func cancelSignIn(_ pending: PendingSignIn) {
        if pending.provider == .claude {
            // A sign-in finished but not imported (cancelled, or failed to
            // parse) must not leave a token under a service nobody manages.
            // A local delete; nothing is revoked.
            let service = ClaudeAccountSession.keychainService(environment: ["CLAUDE_CONFIG_DIR": pending.scratch.path])
            let account = ClaudeAccountSession.keychainAccount(environment: ProcessInfo.processInfo.environment)
            try? vault.secrets.delete(service: service, account: account)
        }
        try? FileManager.default.removeItem(at: pending.scratch)
        try? FileManager.default.removeItem(
            at: scratchRoot.appendingPathComponent("\(pending.provider.rawValue)-sign-in.command")
        )
    }

    // MARK: Editing

    func remove(_ id: UUID) async -> AccountRoster {
        await loadIfNeeded()
        vault.remove(id)
        lastCaptured[id] = nil
        tokenDigests[id] = nil
        roster.accounts.removeAll { $0.id == id }
        await persist()
        return roster
    }

    func rename(_ id: UUID, to nickname: String?) async -> AccountRoster {
        await loadIfNeeded()
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        roster.update(id) { $0.nickname = trimmed?.isEmpty == false ? trimmed : nil }
        await persist()
        return roster
    }

    // MARK: Limits

    /// Stores the live account's latest limits so they stay visible once the
    /// account is parked.
    func record(_ windows: [QuotaWindow], observedAt: Date, isLive: Bool, for identity: AccountIdentity) async -> AccountRoster {
        await loadIfNeeded()
        guard let account = roster.account(matching: identity), !windows.isEmpty else { return roster }
        if let previous = account.lastLimits, previous.observedAt > observedAt { return roster }
        roster.update(account.id) { $0.lastLimits = AccountLimitsRecord(windows: windows, observedAt: observedAt, isLive: isLive) }
        await persist()
        return roster
    }

    /// Reads limits for parked accounts, spaced per account. Claude uses a
    /// still-valid saved access token only (never a refresh); Codex runs the
    /// CLI against a private copy and keeps any token it rotates.
    func refreshParked() async -> AccountRoster {
        await loadIfNeeded()
        for account in roster.accounts {
            // Re-read who is live for every account: an earlier await in this
            // loop may have let a switch make this account the live one, and
            // reading it here would spend the live sign-in's refresh token.
            let current = account.provider == .claude ? claude().liveIdentity() : codex().liveIdentity()
            if let current, current.isSameAccount(as: account.identity) { continue }
            let spacing: TimeInterval = account.provider == .claude ? 5 * 60 : 15 * 60
            if let last = parkedReadAt[account.id], Date.now.timeIntervalSince(last) < spacing { continue }
            parkedReadAt[account.id] = .now
            guard let entry = try? vault.load(account.id) else { continue }
            switch account.provider {
            case .claude:
                guard let token = ClaudeAccountSession.unexpiredAccessToken(in: entry),
                      let quota = try? await ClaudeQuotaFetcher.fetchUsage(accessToken: token, subscriptionType: nil)
                else { continue }
                roster.update(account.id) {
                    $0.lastLimits = AccountLimitsRecord(windows: quota.windows, observedAt: quota.fetchedAt, isLive: true)
                }
            case .codex:
                let result = CodexAccountSession.readParkedLimits(entry, scratchRoot: scratchRoot)
                if let rotated = result.rotatedAuth {
                    var updated = entry
                    updated.codexAuth = rotated
                    updated.capturedAt = .now
                    // The previous refresh token is spent; losing this copy
                    // would leave the account needing a new sign-in.
                    if (try? vault.save(updated, for: account.id)) == nil {
                        try? vault.save(updated, for: account.id)
                    }
                }
                guard let quota = result.quota else { continue }
                roster.update(account.id) {
                    $0.lastLimits = AccountLimitsRecord(
                        windows: quota.windows, observedAt: quota.observedAt ?? .now, isLive: true
                    )
                    if let plan = quota.planType { $0.identity.plan = plan.prefix(1).uppercased() + plan.dropFirst() }
                }
            }
        }
        await persist()
        return roster
    }

    // MARK: Helpers

    static let doneMarker = ".netra-sign-in-finished"

    static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension AccountRoster {
    /// When Netra last switched `provider`'s account. A limit reading older
    /// than this may belong to the previous account.
    func lastSwitch(_ provider: AccountProvider) -> Date? {
        switchedAt?[provider.rawValue]
    }

    mutating func recordSwitch(_ provider: AccountProvider, at date: Date = .now) {
        var map = switchedAt ?? [:]
        map[provider.rawValue] = date
        switchedAt = map
    }
}
