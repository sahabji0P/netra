import Foundation

/// The Codex CLI's live sign-in, and how to swap it.
///
/// Contract, verified against codex-rs `rust-v0.158.0`:
/// - With the default `cli_auth_credentials_store = "file"`, `auth.json` in
///   `CODEX_HOME` (default `~/.codex`) is the whole account identity.
///   `config.toml`, MCP servers, skills, sessions, and history are shared.
/// - Running Codex processes hold auth in memory and do not watch the file.
///   Before persisting a refresh they re-read `auth.json` and bail out when
///   `account_id` changed, so a swap makes them fail loudly, not clobber.
/// - Codex writes `auth.json` by truncating in place; Netra writes a temp
///   file and renames it, so a reader never sees it empty.
/// - `codex login` revokes the previous tokens of its `CODEX_HOME`, so new
///   accounts sign in under a private temporary home instead.
struct CodexAccountSession: Sendable {
    var home: URL
    /// Off in tests, which must never touch a real Codex daemon.
    var restartsDaemon = true

    init(home: URL, restartsDaemon: Bool = true) {
        self.home = home
        self.restartsDaemon = restartsDaemon
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexAccountSession {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? userHome.appendingPathComponent(".codex", isDirectory: true)
        return CodexAccountSession(home: home)
    }

    var authFile: URL { home.appendingPathComponent("auth.json") }

    /// Credentials kept in the OS keyring instead of `auth.json` cannot be
    /// swapped by moving a file. `auto` uses the keyring whenever one exists,
    /// which is always true on macOS, so a leftover `auth.json` is ignored.
    var usesKeyringStorage: Bool {
        guard let config = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        else { return false }
        return Self.keyringConfigured(config)
    }

    static func keyringConfigured(_ config: String) -> Bool {
        config.split(separator: "\n").contains { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store" else { return false }
            let value = parts[1].split(separator: "#", maxSplits: 1).first ?? ""
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            return trimmed == "keyring" || trimmed == "auto"
        }
    }

    // MARK: Reading

    func liveAuth() -> Data? {
        try? Data(contentsOf: authFile)
    }

    func liveIdentity() -> AccountIdentity? {
        liveAuth().flatMap(Self.identity(fromAuth:))
    }

    /// Identity from an `auth.json` payload: `tokens.account_id` plus the
    /// `id_token` claims (email, name, plan, user id). API-key sign-ins have
    /// no account and return nil.
    static func identity(fromAuth data: Data) -> AccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any]
        else { return nil }
        let claims = (tokens["id_token"] as? String).flatMap(jwtClaims) ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let accountID = JSONValue.string(tokens["account_id"]) ?? JSONValue.string(auth["chatgpt_account_id"])
        else { return nil }
        let userID = JSONValue.string(auth["chatgpt_user_id"]) ?? JSONValue.string(auth["user_id"])
        let organization = (auth["organizations"] as? [[String: Any]])?
            .first { ($0["is_default"] as? Bool) == true }
            .flatMap { JSONValue.string($0["title"]) }
        return AccountIdentity(
            provider: .codex,
            providerAccountID: userID.map { "\($0)::\(accountID)" } ?? accountID,
            email: JSONValue.string(claims["email"]),
            displayName: JSONValue.string(claims["name"]),
            organizationName: organization,
            plan: JSONValue.string(auth["chatgpt_plan_type"]).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        )
    }

    /// `tokens.account_id`, the field Codex itself compares before writing.
    static func accountID(inAuth data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any] else { return nil }
        return JSONValue.string(tokens["account_id"])
    }

    /// The unverified payload of a JWT. Only used to label an account; the
    /// token itself is never trusted for anything here.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func captureLive() -> (identity: AccountIdentity, entry: VaultEntry)? {
        guard let data = liveAuth(), let identity = Self.identity(fromAuth: data) else { return nil }
        return (identity, VaultEntry(provider: .codex, capturedAt: .now, codexAuth: data))
    }

    // MARK: Swapping

    /// Writes `entry`'s `auth.json` into place and verifies it landed.
    /// A running Codex process finishing a refresh at this exact moment can
    /// write its (freshly rotated) tokens over ours; those are handed to
    /// `rescue` so they are not lost, then ours are written once more.
    func install(_ entry: VaultEntry, rescue: (Data) -> Void = { _ in }) throws {
        guard let auth = entry.codexAuth, let expected = Self.accountID(inAuth: auth) else {
            throw AccountSwitchError.savedSignInUnreadable
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for _ in 0..<2 {
            try ClaudeAccountSession.writeData(auth, to: authFile)
            guard let landed = liveAuth() else { continue }
            if landed == auth { return }
            if Self.accountID(inAuth: landed) != expected { rescue(landed) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw AccountSwitchError.verificationFailed
    }

    /// Restarts the shared `codex app-server daemon` so it loads the new
    /// sign-in — only when it is running, because `restart` otherwise starts
    /// one. Returns whether a restart happened.
    @discardableResult
    func restartDaemonIfRunning() -> Bool {
        guard restartsDaemon, let binary = CodexLiveQuota.resolveBinary() else { return false }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        guard let version = try? ProcessRunner.run(
            binary.path, ["app-server", "daemon", "version"], environment: environment,
            capturesOutput: false, timeout: 6
        ), version.status == 0 else { return false }
        let restart = try? ProcessRunner.run(
            binary.path, ["app-server", "daemon", "restart"], environment: environment,
            capturesOutput: false, timeout: 20
        )
        return restart?.status == 0
    }

    // MARK: Parked accounts

    /// Reads a parked account's live limits by running the Codex CLI in a
    /// private, temporary `CODEX_HOME` that holds only its `auth.json`.
    /// Codex may refresh the token while doing so; the rotated `auth.json`
    /// is returned so it can go straight back into the vault.
    static func readParkedLimits(_ entry: VaultEntry, scratchRoot: URL) -> (quota: CodexQuota?, rotatedAuth: Data?) {
        guard let auth = entry.codexAuth, let expected = accountID(inAuth: auth) else { return (nil, nil) }
        let scratch = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try ClaudeAccountSession.writeData(auth, to: scratch.appendingPathComponent("auth.json"))
        } catch {
            return (nil, nil)
        }
        let quota = CodexLiveQuota.fetch(codexHome: scratch)
        let after = try? Data(contentsOf: scratch.appendingPathComponent("auth.json"))
        let rotated = after.flatMap { data in
            data != auth && accountID(inAuth: data) == expected ? data : nil
        }
        return (quota, rotated)
    }
}

/// Counts running CLI processes, so a switch can say how many sessions keep
/// the previous account until they restart.
enum RunningAgents {
    static func count(named name: String, excluding excluded: Set<Int32> = []) -> Int {
        guard let result = try? ProcessRunner.run("/bin/ps", ["-axo", "pid=,comm="], timeout: 5) else { return 0 }
        let own = ProcessInfo.processInfo.processIdentifier
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .filter { line in
                let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard fields.count == 2, let pid = Int32(fields[0]), pid != own, !excluded.contains(pid) else { return false }
                return (String(fields[1]) as NSString).lastPathComponent == name
            }
            .count
    }
}
