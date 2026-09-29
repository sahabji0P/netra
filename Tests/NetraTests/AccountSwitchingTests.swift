import XCTest
@testable import Netra

/// Contract and state-machine tests for multi-account switching. Every
/// credential here is synthetic; nothing touches the real Keychain, the real
/// `~/.claude.json`, or a real `CODEX_HOME`.
final class AccountSwitchingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("netra-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Synthetic Claude fixtures

    private func claudeOAuth(_ tag: String, expiresIn: TimeInterval = 8 * 3600) -> [String: Any] {
        [
            "accessToken": "sk-ant-oat01-SYNTHETIC-\(tag)-access",
            "refreshToken": "sk-ant-ort01-SYNTHETIC-\(tag)-refresh",
            "expiresAt": (Date.now.timeIntervalSince1970 + expiresIn) * 1000,
            "refreshTokenExpiresAt": (Date.now.timeIntervalSince1970 + 30 * 86400) * 1000,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
        ]
    }

    private func claudeProfile(_ tag: String) -> [String: Any] {
        [
            "accountUuid": "00000000-0000-0000-0000-00000000000\(tag == "A" ? "a" : "b")",
            "organizationUuid": "org-synthetic-\(tag)",
            "emailAddress": "\(tag.lowercased())@synthetic.example",
            "displayName": "Synthetic \(tag)",
            "userRateLimitTier": tag == "A" ? "default_claude_max_20x" : "default_claude_pro",
        ]
    }

    private func claudeSession(secrets: SecretStore) throws -> ClaudeAccountSession {
        let home = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return ClaudeAccountSession(
            configFile: root.appendingPathComponent(".claude.json"), configHome: home,
            keychainService: "Claude Code-credentials", keychainAccount: "tester", secrets: secrets
        )
    }

    /// Live state: signed in as A, with MCP logins and a full config.
    private func seedClaudeLive(_ session: ClaudeAccountSession, secrets: InMemorySecretStore) throws {
        let item: [String: Any] = [
            "claudeAiOauth": claudeOAuth("A"),
            "trustedDeviceToken": "SYNTHETIC-device-A",
            "mcpOAuth": ["linear|abc": ["accessToken": "SYNTHETIC-mcp-linear"]],
            "pluginSecrets": ["x": "SYNTHETIC-plugin"],
        ]
        try secrets.write(JSONSerialization.data(withJSONObject: item), service: session.keychainService, account: session.keychainAccount)
        let config: [String: Any] = [
            "oauthAccount": claudeProfile("A"),
            "projects": ["/Users/synthetic/app": ["allowedTools": ["Bash"]]],
            "mcpServers": ["linear": ["type": "http", "url": "https://mcp.linear.example"]],
            "cachedUsageUtilization": ["accountUuid": "00000000-0000-0000-0000-00000000000a", "fetchedAtMs": 1, "utilization": [:]],
            "modelAccessCache": ["org-synthetic-A": ["opus"]],
            "userID": "synthetic-device-user",
            "numStartups": 42,
        ]
        try ClaudeAccountSession.writeJSON(config, to: session.configFile)
    }

    private func vaultEntryB() throws -> VaultEntry {
        VaultEntry(
            provider: .claude, capturedAt: .now,
            claudeCredentials: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": claudeOAuth("B")]),
            claudeProfile: try JSONSerialization.data(withJSONObject: claudeProfile("B"))
        )
    }

    private func object(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // MARK: Pure contracts

    func testMergeReplacesOnlyAccountOwnedKeys() {
        let live: [String: Any] = [
            "claudeAiOauth": ["accessToken": "A"], "trustedDeviceToken": "device-A",
            "mcpOAuth": ["server": ["accessToken": "mcp"]], "pluginSecrets": ["p": "s"],
            "coworkRemoteDevice": "cowork",
        ]
        let merged = ClaudeAccountSession.mergedCredentials(live: live, saved: ["claudeAiOauth": ["accessToken": "B"]])
        XCTAssertEqual((merged["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "B")
        XCTAssertNil(merged["trustedDeviceToken"], "A's device token must not travel to B")
        XCTAssertNotNil(merged["mcpOAuth"])
        XCTAssertNotNil(merged["pluginSecrets"])
        XCTAssertEqual(merged["coworkRemoteDevice"] as? String, "cowork")
    }

    func testConfigPatchClearsAccountCachesAndKeepsEverythingElse() {
        let config: [String: Any] = [
            "oauthAccount": ["accountUuid": "a"], "cachedUsageUtilization": [:], "modelAccessCache": [:],
            "clientDataCacheSlots": [:], "penguinModeOrgEnabled": false,
            "projects": ["p": [:]], "mcpServers": ["m": [:]], "userID": "u", "someFutureKey": 1,
        ]
        let patched = ClaudeAccountSession.patchedConfig(config, profile: ["accountUuid": "b"])
        XCTAssertEqual((patched["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "b")
        for key in ["cachedUsageUtilization", "modelAccessCache", "clientDataCacheSlots", "penguinModeOrgEnabled"] {
            XCTAssertNil(patched[key], key)
        }
        for key in ["projects", "mcpServers", "userID", "someFutureKey"] {
            XCTAssertNotNil(patched[key], key)
        }
    }

    func testKeychainServiceMatchesClaudeCodeHashing() {
        XCTAssertEqual(ClaudeAccountSession.keychainService(environment: [:]), "Claude Code-credentials")
        // Expected value from `printf %s /tmp/netra-test-config | shasum -a 256`.
        XCTAssertEqual(
            ClaudeAccountSession.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/tmp/netra-test-config"]),
            "Claude Code-credentials-41225f81"
        )
        XCTAssertEqual(
            ClaudeAccountSession.keychainService(environment: [
                "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/netra-test-config",
            ]),
            "Claude Code-credentials-41225f81"
        )
        XCTAssertEqual(ClaudeAccountSession.keychainAccount(environment: ["USER": "ada"]), "ada")
        XCTAssertEqual(ClaudeAccountSession.keychainAccount(environment: ["USER": "a d a"]), "claude-code-user")
    }

    func testClaudeIdentityKeysAccountAndOrganization() throws {
        let identity = try XCTUnwrap(ClaudeAccountSession.identity(fromProfile: claudeProfile("A")))
        XCTAssertEqual(identity.providerAccountID, "00000000-0000-0000-0000-00000000000a|org-synthetic-A")
        XCTAssertEqual(identity.email, "a@synthetic.example")
        XCTAssertEqual(identity.plan, "Max 20x")
    }

    func testCodexIdentityFromSyntheticAuth() throws {
        let data = try syntheticCodexAuth(account: "acct-1", email: "ada@synthetic.example", plan: "pro")
        let identity = try XCTUnwrap(CodexAccountSession.identity(fromAuth: data))
        XCTAssertEqual(identity.providerAccountID, "user-synthetic::acct-1")
        XCTAssertEqual(identity.email, "ada@synthetic.example")
        XCTAssertEqual(identity.plan, "Pro")
        XCTAssertEqual(CodexAccountSession.accountID(inAuth: data), "acct-1")
        XCTAssertNil(CodexAccountSession.identity(fromAuth: Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-SYNTHETIC"}"#.utf8)))
    }

    func testSecurityHexOutputIsDecoded() {
        XCTAssertEqual(SecurityCommandKeychain.decodeSecret("7b7d"), Data("{}".utf8))
        XCTAssertEqual(SecurityCommandKeychain.decodeSecret(#"{"a":1}"#), Data(#"{"a":1}"#.utf8))
    }

    func testCachedQuotaForAnotherAccountIsRejected() throws {
        let config: [String: Any] = [
            "oauthAccount": ["accountUuid": "b"],
            "cachedUsageUtilization": [
                "accountUuid": "a", "fetchedAtMs": 1_700_000_000_000,
                "utilization": ["five_hour": ["utilization": 40, "resets_at": "2099-01-01T00:00:00Z"]],
            ],
        ]
        XCTAssertNil(ClaudeCachedQuotaReader.quota(fromClaudeConfig: try JSONSerialization.data(withJSONObject: config)))
        var same = config
        same["oauthAccount"] = ["accountUuid": "a"]
        XCTAssertNotNil(ClaudeCachedQuotaReader.quota(fromClaudeConfig: try JSONSerialization.data(withJSONObject: same)))
    }

    // MARK: Locks

    func testLocksAreExclusiveAndStaleOnesAreReclaimed() throws {
        let lock = ProperLockfile(directory: root.appendingPathComponent("x.lock"), staleAfter: 60)
        let held = try ProperLockfile.acquireAll([lock])
        XCTAssertThrowsError(try ProperLockfile.acquireAll([lock], timeout: 0.3))
        held.forEach { $0.release() }
        XCTAssertNoThrow(try ProperLockfile.acquireAll([lock]).forEach { $0.release() })

        // A crashed holder's lock (mtime older than staleAfter) is reclaimed.
        try FileManager.default.createDirectory(at: lock.directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-120)], ofItemAtPath: lock.directory.path)
        XCTAssertNoThrow(try ProperLockfile.acquireAll([lock], timeout: 0.3).forEach { $0.release() })
    }

    // MARK: Claude switching

    func testClaudeSwitchSwapsOnlyTheIdentity() async throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        let (switcher, vault, targetID) = try await makeSwitcher(secrets: secrets, claude: session, parked: vaultEntryB(),
                                                                 identity: ClaudeAccountSession.identity(fromProfile: claudeProfile("B"))!)

        let (outcome, roster) = try await switcher.switchTo(targetID)
        XCTAssertEqual(outcome.provider, .claude)

        let item = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((item["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-B-access")
        XCTAssertNotNil(item["mcpOAuth"], "MCP logins are machine-wide and must survive")
        XCTAssertNotNil(item["pluginSecrets"])
        XCTAssertNil(item["trustedDeviceToken"])

        let config = object(try Data(contentsOf: session.configFile))
        XCTAssertEqual((config["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "b@synthetic.example")
        XCTAssertNotNil(config["projects"])
        XCTAssertNotNil(config["mcpServers"])
        XCTAssertEqual(config["userID"] as? String, "synthetic-device-user")
        XCTAssertNil(config["cachedUsageUtilization"])
        XCTAssertNil(config["modelAccessCache"])

        // The displaced account A was adopted and saved first, with its
        // device token, so switching back restores it exactly.
        let a = try XCTUnwrap(roster.accounts.first { $0.identity.email == "a@synthetic.example" })
        let saved = object(try vault.load(a.id).claudeCredentials)
        XCTAssertEqual((saved["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "sk-ant-ort01-SYNTHETIC-A-refresh")
        XCTAssertEqual(saved["trustedDeviceToken"] as? String, "SYNTHETIC-device-A")
        XCTAssertNil(saved["mcpOAuth"], "the vault never copies machine-wide secrets")
        XCTAssertNotNil(roster.lastSwitch(.claude))

        // And back again.
        _ = try await switcher.switchTo(a.id)
        let restored = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((restored["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-A-access")
        XCTAssertEqual(restored["trustedDeviceToken"] as? String, "SYNTHETIC-device-A")
        XCTAssertNotNil(restored["mcpOAuth"])
    }

    func testClaudeSwitchToTheLiveAccountIsRefused() async throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        let identityA = try XCTUnwrap(ClaudeAccountSession.identity(fromProfile: claudeProfile("A")))
        let (switcher, _, id) = try await makeSwitcher(secrets: secrets, claude: session, parked: vaultEntryB(), identity: identityA)
        do {
            _ = try await switcher.switchTo(id)
            XCTFail("switching to the signed-in account must be refused")
        } catch let error as AccountSwitchError {
            XCTAssertEqual(error, .alreadyActive)
        }
    }

    func testLockedKeychainLeavesEverythingAsItWas() async throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        let before = try Data(contentsOf: session.configFile)
        // The vault read succeeds, then Claude's keychain item is unavailable.
        let lockedSession = ClaudeAccountSession(
            configFile: session.configFile, configHome: session.configHome,
            keychainService: session.keychainService, keychainAccount: session.keychainAccount,
            secrets: FailingSecretStore()
        )
        let (lockedSwitcher, _, lockedID) = try await makeSwitcher(
            secrets: secrets, claude: lockedSession, parked: vaultEntryB(),
            identity: ClaudeAccountSession.identity(fromProfile: claudeProfile("B"))!
        )
        do {
            _ = try await lockedSwitcher.switchTo(lockedID)
            XCTFail("a locked keychain must stop the switch")
        } catch let error as AccountSwitchError {
            XCTAssertEqual(error, .keychainUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: session.configFile), before)
        let item = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((item["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-A-access")
    }

    func testTornConfigIsNeverOverwritten() async throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        let identityB = try XCTUnwrap(ClaudeAccountSession.identity(fromProfile: claudeProfile("B")))
        let (switcher, _, id) = try await makeSwitcher(secrets: secrets, claude: session, parked: vaultEntryB(), identity: identityB)
        try Data(#"{"oauthAccount": {"accountUuid": "00000000-0000-0000-0000-00000000000a"}, "projects": {"#.utf8)
            .write(to: session.configFile)
        do {
            _ = try await switcher.switchTo(id)
            XCTFail("a torn config must stop the switch")
        } catch {}
        let item = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((item["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-A-access")
    }

    func testSignInImportDeletesTheTemporaryKeychainItem() async throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        let rosterFile = AccountRosterFile(url: root.appendingPathComponent("accounts.json"))
        let vault = AccountVault(secrets: secrets)
        let codex = CodexAccountSession(home: root.appendingPathComponent("codex"), restartsDaemon: false)
        let switcher = AccountSwitcher(rosterFile: rosterFile, vault: vault, claude: { session },
                                       codex: { codex },
                                       scratchRoot: root.appendingPathComponent("scratch"))
        // What `claude auth login` leaves under a temporary CLAUDE_CONFIG_DIR.
        let scratch = root.appendingPathComponent("scratch/sign-in-1", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try ClaudeAccountSession.writeJSON(["oauthAccount": claudeProfile("B")], to: scratch.appendingPathComponent(".claude.json"))
        let service = ClaudeAccountSession.keychainService(environment: ["CLAUDE_CONFIG_DIR": scratch.path])
        let account = ClaudeAccountSession.keychainAccount(environment: ProcessInfo.processInfo.environment)
        try secrets.write(JSONSerialization.data(withJSONObject: ["claudeAiOauth": claudeOAuth("B")]), service: service, account: account)

        let pending = PendingSignIn(provider: .claude, scratch: scratch, startedAt: .now)
        // Until the script marks the CLI's exit, nothing is imported.
        let early = try await switcher.completeSignIn(pending)
        XCTAssertNil(early)
        FileManager.default.createFile(atPath: scratch.appendingPathComponent(AccountSwitcher.doneMarker).path, contents: nil)
        let roster = try await switcher.completeSignIn(pending)
        let added = try XCTUnwrap(roster?.accounts.first { $0.identity.email == "b@synthetic.example" })
        XCTAssertNotNil(try? vault.load(added.id))
        XCTAssertNil(secrets.value(service: service, account: account), "the temporary sign-in must not linger")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        // The live sign-in was never touched.
        let live = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((live["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-A-access")
    }

    func testUnreadableConfigIsNeverReplaced() throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        // A config path that exists but can't be read as a file.
        let blocked = root.appendingPathComponent("blocked.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let installing = ClaudeAccountSession(
            configFile: blocked, configHome: session.configHome, keychainService: session.keychainService,
            keychainAccount: session.keychainAccount, secrets: secrets
        )
        XCTAssertThrowsError(try installing.install(vaultEntryB())) {
            XCTAssertEqual($0 as? AccountSwitchError, .configUnreadable)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let item = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((item["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-A-access")
    }

    func testFailedKeychainWriteIsRolledBack() throws {
        let secrets = WriteFailingSecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets.inner)
        let configBefore = try Data(contentsOf: session.configFile)
        let itemBefore = secrets.inner.value(service: session.keychainService, account: session.keychainAccount)
        XCTAssertThrowsError(try session.install(vaultEntryB()))
        XCTAssertEqual(try Data(contentsOf: session.configFile), configBefore)
        XCTAssertEqual(secrets.inner.value(service: session.keychainService, account: session.keychainAccount), itemBefore)
    }

    func testUnidentifiableLiveSignInIsNotOverwritten() async throws {
        let secrets = InMemorySecretStore()
        let session = try claudeSession(secrets: secrets)
        try seedClaudeLive(session, secrets: secrets)
        // Tokens in the Keychain, but no profile in the config.
        try ClaudeAccountSession.writeJSON(["projects": [:]], to: session.configFile)
        let identityB = try XCTUnwrap(ClaudeAccountSession.identity(fromProfile: claudeProfile("B")))
        let (switcher, _, id) = try await makeSwitcher(secrets: secrets, claude: session, parked: vaultEntryB(), identity: identityB)
        do {
            _ = try await switcher.switchTo(id)
            XCTFail("an unidentifiable live sign-in must not be overwritten")
        } catch let error as AccountSwitchError {
            XCTAssertEqual(error, .liveSignInUnsaved)
        }
        let item = object(secrets.value(service: session.keychainService, account: session.keychainAccount))
        XCTAssertEqual((item["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, "sk-ant-oat01-SYNTHETIC-A-access")
    }

    func testCodexApiKeySignInIsNotOverwritten() async throws {
        let home = root.appendingPathComponent("codex-apikey", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let apiKey = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-SYNTHETIC-key"}"#.utf8)
        try apiKey.write(to: home.appendingPathComponent("auth.json"))
        let authB = try syntheticCodexAuth(account: "acct-B", email: "b@synthetic.example", plan: "team")
        let secrets = InMemorySecretStore()
        let (switcher, _, id) = try await makeSwitcher(
            secrets: secrets, claude: claudeSession(secrets: secrets),
            codex: CodexAccountSession(home: home, restartsDaemon: false),
            parked: VaultEntry(provider: .codex, capturedAt: .now, codexAuth: authB),
            identity: CodexAccountSession.identity(fromAuth: authB)!
        )
        do {
            _ = try await switcher.switchTo(id)
            XCTFail("an API-key sign-in must not be overwritten")
        } catch let error as AccountSwitchError {
            XCTAssertEqual(error, .liveSignInUnsaved)
        }
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), apiKey)
    }

    func testCodexKeyringConfigurationIsDetected() {
        XCTAssertTrue(CodexAccountSession.keyringConfigured(#"cli_auth_credentials_store = "keyring""#))
        XCTAssertTrue(CodexAccountSession.keyringConfigured("cli_auth_credentials_store='auto' # macOS keychain"))
        XCTAssertFalse(CodexAccountSession.keyringConfigured(#"cli_auth_credentials_store = "file""#))
        XCTAssertFalse(CodexAccountSession.keyringConfigured(#"model = "gpt-5""#))
    }

    // MARK: Codex switching

    func testCodexSwitchReplacesAuthFileAndSavesTheDisplacedAccount() async throws {
        let home = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let authA = try syntheticCodexAuth(account: "acct-A", email: "a@synthetic.example", plan: "pro")
        let authB = try syntheticCodexAuth(account: "acct-B", email: "b@synthetic.example", plan: "team")
        try authA.write(to: home.appendingPathComponent("auth.json"))
        try Data("model = \"gpt-5\"\n[mcp_servers.docs]\ncommand = \"docs\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        let codex = CodexAccountSession(home: home, restartsDaemon: false)
        let secrets = InMemorySecretStore()
        let (switcher, vault, targetID) = try await makeSwitcher(
            secrets: secrets, claude: claudeSession(secrets: secrets), codex: codex,
            parked: VaultEntry(provider: .codex, capturedAt: .now, codexAuth: authB),
            identity: CodexAccountSession.identity(fromAuth: authB)!
        )

        let (outcome, roster) = try await switcher.switchTo(targetID)
        XCTAssertEqual(outcome.provider, .codex)
        XCTAssertFalse(outcome.daemonRestarted)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), authB)
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8).contains("mcp_servers.docs"))
        let a = try XCTUnwrap(roster.accounts.first { $0.identity.email == "a@synthetic.example" })
        XCTAssertEqual(try vault.load(a.id).codexAuth, authA)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: Roster presentation

    func testLabelsDisambiguateAndParkedWindowsKnowWhenTheyReset() {
        let now = Date.now
        func account(_ email: String) -> ManagedAccount {
            ManagedAccount(id: UUID(), identity: AccountIdentity(provider: .codex, providerAccountID: email, email: email), addedAt: now)
        }
        var roster = AccountRoster()
        roster.accounts = [account("ada@work.example"), account("ada@team.example"), account("bob@work.example")]
        XCTAssertEqual(roster.label(for: roster.accounts[0]), "ada@work")
        XCTAssertEqual(roster.label(for: roster.accounts[1]), "ada@team")
        XCTAssertEqual(roster.label(for: roster.accounts[2]), "bob")

        var parked = roster.accounts[0]
        parked.lastLimits = AccountLimitsRecord(windows: [
            QuotaWindow(label: "5h", usedPercent: 90, resetsAt: now.addingTimeInterval(-60), durationSeconds: 5 * 3600),
            QuotaWindow(label: "weekly", usedPercent: 30, resetsAt: now.addingTimeInterval(86400), durationSeconds: 7 * 86400),
            QuotaWindow(label: "weekly · Fable", usedPercent: 60, resetsAt: now.addingTimeInterval(86400), durationSeconds: 7 * 86400),
        ], observedAt: now.addingTimeInterval(-3600), isLive: true)
        let windows = parked.parkedWindows(now: now)
        XCTAssertTrue(windows[0].hasResetSince)
        XCTAssertFalse(windows[1].hasResetSince)
        let glance = AccountText.glanceWindows(windows)
        XCTAssertEqual(glance.map(\.window.label), ["5h", "weekly · Fable"])
        XCTAssertEqual(AccountText.parkedStatus(parked, now: now), "Limits as of 1h ago")
    }

    func testUpsertKeepsNicknameAndFillsMissingProfileFields() {
        var roster = AccountRoster()
        let id = roster.upsert(AccountIdentity(provider: .claude, providerAccountID: "x", email: "x@example.com", plan: "Pro"))
        roster.update(id) { $0.nickname = "Work" }
        let again = roster.upsert(AccountIdentity(provider: .claude, providerAccountID: "x", email: nil, plan: "Max 5x"))
        XCTAssertEqual(again, id)
        XCTAssertEqual(roster.accounts.count, 1)
        XCTAssertEqual(roster.accounts[0].nickname, "Work")
        XCTAssertEqual(roster.accounts[0].identity.email, "x@example.com")
        XCTAssertEqual(roster.accounts[0].identity.plan, "Max 5x")
    }

    // MARK: Helpers

    private func makeSwitcher(
        secrets: SecretStore, claude: ClaudeAccountSession, codex: CodexAccountSession? = nil,
        parked: VaultEntry, identity: AccountIdentity
    ) async throws -> (AccountSwitcher, AccountVault, UUID) {
        let rosterURL = root.appendingPathComponent("accounts-\(UUID().uuidString).json")
        var roster = AccountRoster()
        let id = roster.upsert(identity)
        let rosterFile = AccountRosterFile(url: rosterURL)
        await rosterFile.save(roster)
        // Vault items live in their own store, so a locked Claude keychain
        // can be simulated without hiding the parked sign-in.
        let vault = AccountVault(secrets: secrets is FailingSecretStore ? InMemorySecretStore() : secrets)
        try vault.save(parked, for: id)
        let codexSession = codex ?? CodexAccountSession(home: root.appendingPathComponent("codex-unused"), restartsDaemon: false)
        let switcher = AccountSwitcher(
            rosterFile: rosterFile, vault: vault, claude: { claude }, codex: { codexSession },
            scratchRoot: root.appendingPathComponent("scratch")
        )
        return (switcher, vault, id)
    }

    private func syntheticCodexAuth(account: String, email: String, plan: String) throws -> Data {
        func base64URL(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = [
            "email": email, "name": "Synthetic",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": account, "chatgpt_user_id": "user-synthetic", "chatgpt_plan_type": plan,
            ],
        ]
        let jwt = "\(try base64URL(["alg": "none"])).\(try base64URL(claims)).SYNTHETIC-signature"
        let auth: [String: Any] = [
            "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": "2026-09-29T00:00:00Z",
            "tokens": [
                "id_token": jwt, "access_token": "SYNTHETIC-codex-access-\(account)",
                "refresh_token": "SYNTHETIC-codex-refresh-\(account)", "account_id": account,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
    }
}

/// A keychain that is locked: every call fails as unavailable.
private struct FailingSecretStore: SecretStore {
    func read(service: String, account: String) throws -> Data { throw SecretStoreError.unavailable }
    func write(_ data: Data, service: String, account: String) throws { throw SecretStoreError.unavailable }
    func delete(service: String, account: String) throws { throw SecretStoreError.unavailable }
}

/// Reads work; every write fails — a keychain that refuses the switch.
private final class WriteFailingSecretStore: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    func read(service: String, account: String) throws -> Data { try inner.read(service: service, account: account) }
    func write(_ data: Data, service: String, account: String) throws { throw SecretStoreError.failed(1) }
    func delete(service: String, account: String) throws { throw SecretStoreError.failed(1) }
}
