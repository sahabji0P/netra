import Foundation

/// The coding agents whose sign-in Netra can switch. Everything account
/// related is keyed by this, so Cursor (one login, no switch) never appears.
enum AccountProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: Self { self }

    /// The `AgentPalette` key for colors and names.
    var agent: String { rawValue }
}

/// Who a CLI is signed in as, read from the CLI's own files. Never contains a
/// secret, so it may be persisted and shown freely.
struct AccountIdentity: Codable, Hashable, Sendable {
    var provider: AccountProvider
    /// Stable account key: Claude's `accountUuid` + `organizationUuid`
    /// (one person in two organizations is two accounts), Codex's
    /// `chatgpt_user_id` + `account_id` (one person in two workspaces).
    var providerAccountID: String
    var email: String?
    var displayName: String?
    var organizationName: String?
    /// e.g. "max", "pro", "plus", "team".
    var plan: String?

    var key: String { "\(provider.rawValue):\(providerAccountID)" }

    /// Same account, regardless of profile fields that drift (plan, org name).
    func isSameAccount(as other: AccountIdentity) -> Bool {
        provider == other.provider && providerAccountID == other.providerAccountID
    }
}

/// The last limits Netra saw for an account, kept so a parked account still
/// shows something honest ("as of 3h ago", "reset since").
struct AccountLimitsRecord: Codable, Hashable, Sendable {
    var windows: [QuotaWindow]
    var observedAt: Date
    /// Asked of the provider for this account (vs. copied from the CLI cache).
    var isLive: Bool
}

/// Why a managed account cannot currently be switched to or read.
enum AccountAttention: String, Codable, Hashable, Sendable {
    /// The saved refresh token was rejected; sign in to this account again.
    case signInAgain
    /// The provider says the account itself is deactivated.
    case deactivated
}

/// An account the user chose to manage. Its sign-in lives in `AccountVault`;
/// this record holds only presentation and freshness data.
struct ManagedAccount: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var identity: AccountIdentity
    var nickname: String?
    var addedAt: Date
    /// When this account last became (or was last seen as) the live one.
    var lastActiveAt: Date?
    var lastLimits: AccountLimitsRecord?
    /// Claude's `refreshTokenExpiresAt`: after this, the parked sign-in is dead.
    var signInExpiresAt: Date?
    var attention: AccountAttention?

    var provider: AccountProvider { identity.provider }

    /// Short label for tight spaces: nickname, else the email's local part.
    var shortLabel: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let email = identity.email, let local = email.split(separator: "@").first { return String(local) }
        return identity.displayName ?? "Account"
    }

    /// Full label: the email when known.
    var title: String {
        identity.email ?? identity.displayName ?? shortLabel
    }

    /// Two-letter monogram for the account tile.
    var initials: String {
        let source = nickname.flatMap { $0.isEmpty ? nil : $0 } ?? identity.displayName ?? identity.email ?? "?"
        let words = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
        let letters = words.count >= 2 ? words.compactMap(\.first) : Array(source.filter(\.isLetter).prefix(1))
        return String(letters).uppercased()
    }

    /// Limit windows still worth showing for a parked account, and whether
    /// each one has reset since it was observed.
    func parkedWindows(now: Date = .now) -> [ParkedWindow] {
        guard let record = lastLimits else { return [] }
        return record.windows.map { window in
            ParkedWindow(window: window, hasResetSince: window.resetsAt.map { $0 <= now } ?? false)
        }
    }
}

/// A limit window as last observed for a parked account.
struct ParkedWindow: Hashable, Sendable {
    var window: QuotaWindow
    /// The window rolled over after it was observed. The percentage is no
    /// longer this account's usage, and must not be shown as if it were.
    var hasResetSince: Bool
}

/// Every managed account, persisted as `accounts.json` beside the snapshot.
struct AccountRoster: Codable, Sendable, Equatable {
    var version = 1
    var accounts: [ManagedAccount] = []
    /// Provider raw value → when Netra last switched its account.
    var switchedAt: [String: Date]?

    func accounts(for provider: AccountProvider) -> [ManagedAccount] {
        accounts.filter { $0.provider == provider }
    }

    func account(matching identity: AccountIdentity) -> ManagedAccount? {
        accounts.first { $0.identity.isSameAccount(as: identity) }
    }

    func account(id: UUID) -> ManagedAccount? {
        accounts.first { $0.id == id }
    }

    /// `shortLabel`, made unambiguous: two accounts named "ada" become
    /// "ada@work" and "ada@team".
    func label(for account: ManagedAccount) -> String {
        let base = account.shortLabel
        guard account.nickname?.isEmpty ?? true else { return base }
        let clashes = accounts(for: account.provider).contains {
            $0.id != account.id && $0.shortLabel.caseInsensitiveCompare(base) == .orderedSame
        }
        guard clashes, let email = account.identity.email, let at = email.firstIndex(of: "@"),
              let domain = email[email.index(after: at)...].split(separator: ".").first
        else { return base }
        return "\(base)@\(domain)"
    }

    /// Inserts or updates the record for `identity`, keeping the user's
    /// nickname and history. Returns the record's id.
    @discardableResult
    mutating func upsert(_ identity: AccountIdentity, now: Date = .now) -> UUID {
        if let index = accounts.firstIndex(where: { $0.identity.isSameAccount(as: identity) }) {
            var merged = identity
            // A profile read can lack fields an earlier one had; keep them.
            merged.email = identity.email ?? accounts[index].identity.email
            merged.displayName = identity.displayName ?? accounts[index].identity.displayName
            merged.organizationName = identity.organizationName ?? accounts[index].identity.organizationName
            merged.plan = identity.plan ?? accounts[index].identity.plan
            accounts[index].identity = merged
            return accounts[index].id
        }
        let account = ManagedAccount(id: UUID(), identity: identity, addedAt: now)
        accounts.append(account)
        return account.id
    }

    mutating func update(_ id: UUID, _ change: (inout ManagedAccount) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
    }
}

/// Reads and writes `accounts.json`. Contains no secrets.
actor AccountRosterFile {
    private let url: URL

    init(url: URL = AccountRosterFile.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Netra", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    func load() -> AccountRoster {
        guard let data = try? Data(contentsOf: url),
              let roster = try? JSONDecoder().decode(AccountRoster.self, from: data)
        else { return AccountRoster() }
        return roster
    }

    func save(_ roster: AccountRoster) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(roster) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
