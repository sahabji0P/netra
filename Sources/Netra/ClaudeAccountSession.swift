import CryptoKit
import Foundation

/// Claude Code's live sign-in on this Mac, and the one safe way to swap it.
///
/// Contract, verified against Claude Code 2.1.284's bundled source:
/// - The sign-in is split across the Keychain item `Claude Code-credentials`
///   (suffixed `-<sha256(dir)[0..8]>` when `CLAUDE_CONFIG_DIR` or
///   `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set) and `oauthAccount` in
///   `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` when set).
/// - The Keychain item also holds machine-wide secrets — every MCP server's
///   OAuth login (`mcpOAuth`), plugin secrets — that must survive a switch.
/// - Claude Code serializes token refreshes with proper-lockfile directories
///   and re-reads before writing, so holding the same locks makes a switch
///   and a refresh unable to interleave.
/// - Running sessions keep their in-memory token until a 401 or its expiry,
///   then pick up whatever the Keychain holds. New sessions see it at once.
struct ClaudeAccountSession: Sendable {
    /// Keychain keys that belong to the signed-in account (Claude Code's own
    /// re-login clears exactly these). Everything else in the item stays.
    static let accountOwnedCredentialKeys = ["claudeAiOauth", "organizationUuid", "trustedDeviceToken", "designOauth"]

    /// `~/.claude.json` keys Claude Code's logout clears: the profile plus
    /// caches scoped to the account or its organization. Left in place they
    /// would show the previous account's models, org defaults, and limits.
    static let accountScopedConfigKeys = [
        "oauthAccount", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster",
        "artifactRosterDenied", "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots",
        "autoCompactWindowsCache", "cachedUsageUtilization", "metricsStatusCache",
        "metricsStatusCacheByPrincipal", "githubWebConnectionStatusCache", "startupPrefetchedAt",
        // Organization-level and not keyed by org; clearing is harmless.
        "penguinModeOrgEnabled",
    ]

    var configFile: URL
    var configHome: URL
    var keychainService: String
    var keychainAccount: String
    var secrets: SecretStore

    init(configFile: URL, configHome: URL, keychainService: String, keychainAccount: String, secrets: SecretStore) {
        self.configFile = configFile
        self.configHome = configHome
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.secrets = secrets
    }

    /// The live session for this process's environment.
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        secrets: SecretStore = SecurityCommandKeychain()
    ) -> ClaudeAccountSession {
        let configDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let configHome = configDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        let configFile = configDir == nil
            ? home.appendingPathComponent(".claude.json")
            : configHome.appendingPathComponent(".claude.json")
        return ClaudeAccountSession(
            configFile: configFile,
            configHome: configHome,
            keychainService: keychainService(environment: environment),
            keychainAccount: keychainAccount(environment: environment),
            secrets: secrets
        )
    }

    /// `Claude Code-credentials`, plus Claude Code's per-config-dir suffix:
    /// the first 8 hex digits of SHA-256 over the NFC-normalized, unresolved
    /// directory string.
    static func keychainService(environment: [String: String]) -> String {
        let secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        guard let dir = secure ?? environment["CLAUDE_CONFIG_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            return "Claude Code-credentials"
        }
        return "Claude Code-credentials-" + hashSuffix(dir)
    }

    static func hashSuffix(_ dir: String) -> String {
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// Claude Code files its item under `$USER` when that is a plain name.
    static func keychainAccount(environment: [String: String]) -> String {
        let user = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        let plain = user.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } && user.allSatisfy(\.isASCII)
        return plain ? user : "claude-code-user"
    }

    // MARK: Reading

    /// Who Claude Code is signed in as, from `~/.claude.json` alone — no
    /// Keychain access, so it is safe to call on every refresh.
    func liveIdentity() -> AccountIdentity? {
        guard let data = try? Data(contentsOf: configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return Self.identity(fromProfile: profile)
    }

    static func identity(fromProfile profile: [String: Any], subscriptionType: String? = nil) -> AccountIdentity? {
        guard let accountUuid = JSONValue.string(profile["accountUuid"]) else { return nil }
        let organization = JSONValue.string(profile["organizationUuid"])
        return AccountIdentity(
            provider: .claude,
            providerAccountID: organization.map { "\(accountUuid)|\($0)" } ?? accountUuid,
            email: JSONValue.string(profile["emailAddress"]),
            displayName: JSONValue.string(profile["displayName"]) ?? JSONValue.string(profile["fullName"]),
            organizationName: JSONValue.string(profile["organizationName"]),
            plan: ClaudeCachedQuotaReader.planLabel(fromAccount: profile)
                ?? subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        )
    }

    /// The live Keychain item as a JSON object; nil when there is none.
    /// Throws when the item exists but cannot be read right now.
    func liveCredentials() throws -> [String: Any]? {
        do {
            let data = try secrets.read(service: keychainService, account: keychainAccount)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SecretStoreError.unreadable
            }
            return object
        } catch SecretStoreError.notFound {
            return nil
        } catch is DecodingError, is CocoaError {
            throw SecretStoreError.unreadable
        }
    }

    /// Everything needed to put the live account back later, or nil when
    /// nobody is signed in with a Claude account (API keys, signed out).
    func captureLive() throws -> (identity: AccountIdentity, entry: VaultEntry, signInExpiresAt: Date?)? {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = config["oauthAccount"] as? [String: Any]
        else { return nil }
        // A Keychain item without `claudeAiOauth` (e.g. only MCP logins) is
        // not a sign-in; saving it would overwrite a good copy with nothing.
        let profileBefore = JSONValue.string(profile["accountUuid"])
        guard let credentials = try liveCredentials(),
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              oauth["refreshToken"] != nil || oauth["accessToken"] != nil
        else { return nil }
        guard let identity = Self.identity(fromProfile: profile, subscriptionType: oauth["subscriptionType"] as? String)
        else { return nil }
        // A sign-in that changed between the two reads is a torn pair.
        if let recheck = try? Data(contentsOf: configFile),
           let object = try? JSONSerialization.jsonObject(with: recheck) as? [String: Any],
           JSONValue.string((object["oauthAccount"] as? [String: Any])?["accountUuid"]) != profileBefore {
            throw AccountSwitchError.signInMismatch
        }
        // Both halves are written at sign-in; if they name different
        // organizations one was read mid-change. Never save such a pair.
        if let tokenOrg = JSONValue.string(credentials["organizationUuid"]),
           let profileOrg = JSONValue.string(profile["organizationUuid"]), tokenOrg != profileOrg {
            throw AccountSwitchError.signInMismatch
        }
        let owned = credentials.filter { Self.accountOwnedCredentialKeys.contains($0.key) }
        let entry = VaultEntry(
            provider: .claude,
            capturedAt: .now,
            claudeCredentials: try JSONSerialization.data(withJSONObject: owned),
            claudeProfile: try JSONSerialization.data(withJSONObject: profile)
        )
        return (identity, entry, Self.signInExpiry(owned))
    }

    /// `refreshTokenExpiresAt` (epoch ms): when a parked sign-in dies.
    static func signInExpiry(_ credentials: [String: Any]) -> Date? {
        let oauth = credentials["claudeAiOauth"] as? [String: Any]
        return JSONValue.number(oauth?["refreshTokenExpiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// The saved access token, when it has not expired yet. Used only to read
    /// a parked account's limits; Netra never refreshes Claude tokens.
    static func unexpiredAccessToken(in entry: VaultEntry, now: Date = .now) -> String? {
        guard let data = entry.claudeCredentials,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = JSONValue.string(oauth["accessToken"]),
              let expires = JSONValue.number(oauth["expiresAt"]).map({ Date(timeIntervalSince1970: $0 / 1000) }),
              expires.timeIntervalSince(now) > 5 * 60
        else { return nil }
        return token
    }

    // MARK: Swapping

    /// The live Keychain item with only the account-owned keys replaced.
    static func mergedCredentials(live: [String: Any], saved: [String: Any]) -> [String: Any] {
        var merged = live.filter { !accountOwnedCredentialKeys.contains($0.key) }
        for key in accountOwnedCredentialKeys {
            if let value = saved[key] { merged[key] = value }
        }
        return merged
    }

    /// `~/.claude.json` with the new profile and no account-scoped caches;
    /// every other key (projects, MCP servers, settings, history) untouched.
    static func patchedConfig(_ config: [String: Any], profile: [String: Any]) -> [String: Any] {
        var patched = config
        for key in accountScopedConfigKeys { patched.removeValue(forKey: key) }
        patched["oauthAccount"] = profile
        return patched
    }

    /// Claude Code's lock directories, in the order Claude Code takes them.
    var locks: [ProperLockfile] {
        [
            ProperLockfile(directory: configHome.appendingPathComponent(".oauth_refresh.lock"), staleAfter: 60),
            ProperLockfile(directory: URL(fileURLWithPath: configHome.path + ".lock"), staleAfter: 60),
            ProperLockfile(directory: URL(fileURLWithPath: configFile.path + ".lock"), staleAfter: 10),
        ]
    }

    /// Runs `body` while holding every Claude Code lock. `body` gets a
    /// keep-alive that refreshes the locks' mtimes, as proper-lockfile
    /// holders do, so a slow keychain never makes them look stale.
    func withLocks<T>(_ body: (_ keepAlive: () -> Void) throws -> T) throws -> T {
        let held = try ProperLockfile.acquireAll(locks)
        defer { held.forEach { $0.release() } }
        return try body { held.forEach { $0.touch() } }
    }

    /// Makes `entry` the live sign-in. Call inside `withLocks`, after the
    /// displaced sign-in has been captured. If the config write fails, the
    /// previous Keychain item is put back: half of one account and half of
    /// another is worse than no change.
    func install(_ entry: VaultEntry, keepAlive: () -> Void = {}) throws {
        guard let savedData = entry.claudeCredentials, let profileData = entry.claudeProfile,
              let saved = try JSONSerialization.jsonObject(with: savedData) as? [String: Any],
              let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              saved["claudeAiOauth"] != nil
        else { throw AccountSwitchError.savedSignInUnreadable }

        // A config that does not parse is torn or mid-write; writing a
        // rebuilt one would drop the user's projects and MCP servers.
        // Only a file that does not exist counts as empty; any other read
        // error must stop the switch rather than replace the whole config.
        let config: [String: Any]
        if FileManager.default.fileExists(atPath: configFile.path) {
            guard let data = try? Data(contentsOf: configFile),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AccountSwitchError.configUnreadable
            }
            config = parsed
        } else {
            config = [:]
        }

        let previous: Data?
        do {
            previous = try secrets.read(service: keychainService, account: keychainAccount)
        } catch SecretStoreError.notFound {
            previous = nil
        } catch SecretStoreError.unavailable {
            throw AccountSwitchError.keychainUnavailable
        } catch {
            throw AccountSwitchError.keychainUnavailable
        }
        let live = previous.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if previous != nil, live.isEmpty { throw AccountSwitchError.keychainUnavailable }
        let merged = try JSONSerialization.data(withJSONObject: Self.mergedCredentials(live: live, saved: saved))

        // Everything from the first write on is undone as a unit.
        do {
            try secrets.write(merged, service: keychainService, account: keychainAccount)
            keepAlive()
            let patched = Self.patchedConfig(config, profile: profile)
            try Self.writeJSON(patched, to: configFile)
        } catch {
            if let previous {
                try? secrets.write(previous, service: keychainService, account: keychainAccount)
            } else {
                try? secrets.delete(service: keychainService, account: keychainAccount)
            }
            throw error is AccountSwitchError ? error : AccountSwitchError.configUnwritable
        }

        // Claude Code watches this file's mtime to notice a changed sign-in,
        // and falls back to it when the Keychain read fails. Keep it in step
        // when it exists; never create one.
        // Only the keys it already holds: never add MCP logins or other
        // secrets to a plaintext file that did not have them.
        let shadow = configHome.appendingPathComponent(".credentials.json")
        if let existing = try? Data(contentsOf: shadow),
           let keys = (try? JSONSerialization.jsonObject(with: existing) as? [String: Any])?.keys {
            let mergedObject = Self.mergedCredentials(live: live, saved: saved)
            let kept = mergedObject.filter { keys.contains($0.key) || Self.accountOwnedCredentialKeys.contains($0.key) }
                .filter { $0.key != "mcpOAuth" && $0.key != "pluginSecrets" }
            if let data = try? JSONSerialization.data(withJSONObject: kept) { try? Self.writeData(data, to: shadow) }
        }
    }

    /// Pretty-printed like Claude Code writes it, via temp file + rename so a
    /// reader never sees a half-written file.
    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        try writeData(data, to: url)
    }

    static func writeData(_ data: Data, to target: URL) throws {
        // Write through a dotfile manager's symlink rather than replacing it.
        let url = target.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).netra-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - proper-lockfile compatible locks

/// A lock compatible with npm's `proper-lockfile`, which Claude Code uses: the
/// lock is a directory that exists only while held; one whose mtime is older
/// than `staleAfter` belongs to a crashed holder and may be removed.
struct ProperLockfile: Sendable {
    var directory: URL
    var staleAfter: TimeInterval

    enum Failure: Error, Equatable { case busy(String) }

    /// Takes `locks` in order, giving up (and releasing what it took) after
    /// `timeout`. A lock whose parent directory does not exist guards nothing.
    static func acquireAll(_ locks: [ProperLockfile], timeout: TimeInterval = 10) throws -> [ProperLockfile] {
        var held: [ProperLockfile] = []
        let deadline = Date.now.addingTimeInterval(timeout)
        for lock in locks {
            let parent = lock.directory.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: parent) else { continue }
            while true {
                if mkdir(lock.directory.path, 0o755) == 0 {
                    held.append(lock)
                    break
                }
                let failure = errno
                if failure == EEXIST, lock.isStale() {
                    rmdir(lock.directory.path)
                    continue
                }
                if Date.now >= deadline || failure != EEXIST {
                    held.reversed().forEach { $0.release() }
                    throw Failure.busy(lock.directory.lastPathComponent)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return held
    }

    func isStale(now: Date = .now) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              let modified = attributes[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) > staleAfter
    }

    func release() {
        rmdir(directory.path)
    }

    /// Marks a held lock as alive (proper-lockfile's periodic update).
    func touch() {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: directory.path)
    }
}
