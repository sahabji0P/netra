import XCTest
@testable import Netra

/// The Swift side of the GPUI dashboard bridge: what `dashboard-state.json`
/// carries (and never carries), and how command files are read and refused.
@MainActor
final class DashboardBridgeTests: XCTestCase {
    private let suiteName = "NetraTests.DashboardBridge"
    private let dataDirectory = URL(fileURLWithPath: "/tmp/netra-tests-data", isDirectory: true)

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: State

    private static let secretID = "synthetic-provider-account-7f3a|org-synthetic-99"

    private func sampleState() -> DashboardState {
        let identity = AccountIdentity(
            provider: .claude, providerAccountID: Self.secretID, email: "ada@example.test",
            displayName: "Ada", organizationName: "Synthetic Org", plan: "max"
        )
        let parked = AccountIdentity(
            provider: .claude, providerAccountID: "synthetic-parked-id-0001", email: "grace@example.test",
            displayName: nil, organizationName: nil, plan: "pro"
        )
        var roster = AccountRoster()
        let activeID = roster.upsert(identity, now: Date(timeIntervalSince1970: 1_800_000_000))
        let parkedID = roster.upsert(parked, now: Date(timeIntervalSince1970: 1_800_000_000))
        roster.update(parkedID) {
            $0.nickname = "Side"
            $0.attention = .signInAgain
            $0.lastLimits = AccountLimitsRecord(
                windows: [QuotaWindow(label: "5h", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_800_003_600),
                                      durationSeconds: 18_000)],
                observedAt: Date(timeIntervalSince1970: 1_800_000_000.25), isLive: true
            )
        }
        _ = activeID
        let preferences = AppPreferences(defaults: UserDefaults(suiteName: suiteName)!)
        return DashboardState(
            writtenAt: Date(timeIntervalSince1970: 1_800_000_000.5),
            app: DashboardState.App(
                version: "1.5.0", pid: 4242, refreshing: false, lastError: nil, launchAtLogin: false,
                launchAtLoginAvailable: true, notifications: "allowed", claudeKeychainNeedsApproval: false,
                updateAvailable: nil,
                website: DashboardState.Website(tokenSaved: false, publishing: false, status: "Publishing is off.", tokenError: nil)
            ),
            preferences: DashboardState.Preferences(preferences),
            periods: DashboardState.periodList,
            accounts: DashboardState.accounts(
                roster: roster, live: [.claude: identity], switching: nil, pendingSignIn: .codex,
                codexUsesKeyring: true,
                notice: AccountNotice(provider: .claude, title: "Switched to Ada", detail: "New sessions use it.")
            ),
            navigate: DashboardState.Navigate(page: "subscriptions", nonce: 3),
            results: []
        )
    }

    func testStateNeverCarriesAProviderAccountID() throws {
        let data = try DashboardJSON.encoder().encode(sampleState())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("synthetic-provider-account"), json)
        XCTAssertFalse(json.contains("synthetic-parked-id"), json)
        XCTAssertFalse(json.contains("providerAccountID"))
        XCTAssertFalse(json.contains("accountKey"))
    }

    func testStateUsesTheDocumentedKeysAndDates() throws {
        let data = try DashboardJSON.encoder().encode(sampleState())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["writtenAt"] as? String, "2027-01-15T08:00:00.500Z")

        let preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["menuBarIcon"] as? String, "eye")
        XCTAssertEqual(preferences["menuBarItems"] as? [String], ["todayCost"])
        XCTAssertEqual(preferences["menuBarStyle"] as? String, "plain")
        XCTAssertEqual(preferences["menuBarTint"] as? String, "mono")
        XCTAssertEqual(preferences["menuBarLimitSource"] as? String, "closest")
        XCTAssertEqual(preferences["defaultPeriod"] as? String, "today")
        XCTAssertEqual(preferences["limitProviderOrder"] as? [String], ["claude", "codex", "cursor", "cursor-grok-bot"])
        XCTAssertEqual(preferences["dailyTokenAlertThreshold"] as? Int, 1_000_000)
        XCTAssertEqual(preferences["resetTimeStyle"] as? String, "countdown")
        XCTAssertEqual(preferences.count, 26, "every documented preference key")

        let periods = try XCTUnwrap(object["periods"] as? [[String: String]])
        XCTAssertEqual(periods.map { $0["id"] }, ["today", "week", "month"])
        XCTAssertEqual(periods.first?["title"], "Today")

        let navigate = try XCTUnwrap(object["navigate"] as? [String: Any])
        XCTAssertEqual(navigate["page"] as? String, "subscriptions")
        XCTAssertEqual(navigate["nonce"] as? Int, 3)
    }

    func testAccountsSectionShowsPresentationFieldsOnly() throws {
        let accounts = sampleState().accounts
        let claude = try XCTUnwrap(accounts.providers.first { $0.provider == "claude" })
        XCTAssertTrue(claude.managing)
        XCTAssertTrue(claude.liveIsSaved)
        XCTAssertEqual(claude.live?.email, "ada@example.test")
        XCTAssertEqual(claude.live?.organization, "Synthetic Org")
        XCTAssertEqual(claude.accounts.count, 2)
        let active = try XCTUnwrap(claude.accounts.first { $0.active })
        XCTAssertEqual(active.title, "ada@example.test")
        XCTAssertNotNil(UUID(uuidString: active.id), "the roster id is Netra's own UUID")
        let parked = try XCTUnwrap(claude.accounts.first { !$0.active })
        XCTAssertEqual(parked.title, "Side", "a nickname is the title, so a rename shows")
        XCTAssertEqual(parked.attention, "signInAgain")
        XCTAssertEqual(parked.limits?.windows.first?.label, "5h")
        XCTAssertEqual(parked.limits?.isLive, true)

        let codex = try XCTUnwrap(accounts.providers.first { $0.provider == "codex" })
        XCTAssertFalse(codex.managing)
        XCTAssertNil(codex.live)
        XCTAssertTrue(codex.pendingSignIn)
        XCTAssertNotNil(codex.note, "the keyring warning")
        XCTAssertEqual(accounts.notice?.title, "Switched to Ada")
    }

    func testStateRoundTripsThroughTheBridgeDecoder() throws {
        let state = sampleState()
        let decoded = try DashboardJSON.decoder().decode(DashboardState.self, from: DashboardJSON.encoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testResultsKeepTheLastTwenty() {
        var results: [DashboardState.CommandResult] = []
        for index in 0..<25 {
            results = DashboardState.appending(
                DashboardState.CommandResult(id: "\(index)", command: "refresh", ok: true, message: "", at: .now),
                to: results
            )
        }
        XCTAssertEqual(results.count, 20)
        XCTAssertEqual(results.first?.id, "5")
        XCTAssertEqual(results.last?.id, "24")
    }

    func testPageIDsMatchTheDocument() {
        XCTAssertEqual(DashboardSection.allCases.map(\.bridgePageID),
                       ["usage", "subscriptions", "menubar", "limits", "providers", "accounts", "notifications", "general"])
        XCTAssertEqual(DashboardSection(bridgePageID: "menubar"), .menuBar)
        XCTAssertNil(DashboardSection(bridgePageID: "menuBar"))
    }

    func testLauncherFindsTheNestedAppOrTheEnvironmentBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("netra-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("Netra.app")
        XCTAssertNil(DashboardLauncher.locate(environment: [:], mainBundle: main))

        let nested = main.appendingPathComponent("Contents/Helpers/Netra Dashboard.app")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: nested.appendingPathComponent("Contents/Info.plist"))
        guard case .bundle(let found) = DashboardLauncher.locate(environment: [:], mainBundle: main) else {
            return XCTFail("the nested app should be found")
        }
        XCTAssertEqual(found.standardizedFileURL.path, nested.standardizedFileURL.path)

        let binary = root.appendingPathComponent("netra-dashboard")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(DashboardLauncher.locate(environment: ["NETRA_DASHBOARD_BIN": binary.path], mainBundle: main),
                       .binary(binary))
    }

    // MARK: Commands

    private func parse(_ command: String, _ args: String? = nil, id: String = "cmd-1") -> DashboardCommand.Request {
        let argsJSON = args.map { #", "args": \#($0)"# } ?? ""
        let json = #"{ "id": "\#(id)", "command": "\#(command)", "at": "2026-11-16T05:40:00.000Z"\#(argsJSON) }"#
        return DashboardCommand.parse(Data(json.utf8), fallbackID: "file-id", dataDirectory: dataDirectory)
    }

    private func command(_ name: String, _ args: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> DashboardCommand? {
        let request = parse(name, args)
        XCTAssertEqual(request.id, "cmd-1", file: file, line: line)
        XCTAssertEqual(request.name, name, file: file, line: line)
        switch request.command {
        case .success(let command): return command
        case .failure(let failure):
            XCTFail("\(name) refused: \(failure.message)", file: file, line: line)
            return nil
        }
    }

    private func refusal(_ name: String, _ args: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch parse(name, args).command {
        case .success(let command):
            XCTFail("\(name) \(args ?? "") should be refused, got \(command)", file: file, line: line)
            return nil
        case .failure(let failure): return failure.message
        }
    }

    func testEveryDocumentedCommandDecodes() {
        let id = "8E2B5D6A-0000-4000-8000-000000000001"
        let uuid = UUID(uuidString: id)!
        XCTAssertEqual(command("preference.set", #"{"key": "showsPace", "value": false}"#), .preferenceSet(.showsPace(false)))
        XCTAssertEqual(command("limits.move", #"{"provider": "codex", "offset": -1}"#), .limitsMove(provider: "codex", offset: -1))
        XCTAssertEqual(command("provider.setVisible", #"{"provider": "Gemini", "visible": false}"#),
                       .providerSetVisible(provider: "gemini", visible: false))
        XCTAssertEqual(command("refresh"), .refresh)
        XCTAssertEqual(command("claude.authorizeKeychain"), .claudeAuthorizeKeychain)
        XCTAssertEqual(command("launchAtLogin.set", #"{"enabled": true}"#), .launchAtLoginSet(true))
        XCTAssertEqual(command("notifications.request"), .notificationsRequest)
        XCTAssertEqual(command("notifications.openSettings"), .notificationsOpenSettings)
        XCTAssertEqual(command("account.startManaging", #"{"provider": "claude"}"#), .accountStartManaging(.claude))
        XCTAssertEqual(command("account.switch", #"{"id": "\#(id)"}"#), .accountSwitch(uuid))
        XCTAssertEqual(command("account.beginSignIn", #"{"provider": "codex"}"#), .accountBeginSignIn(.codex))
        XCTAssertEqual(command("account.cancelSignIn"), .accountCancelSignIn)
        XCTAssertEqual(command("account.remove", #"{"id": "\#(id)"}"#), .accountRemove(uuid))
        XCTAssertEqual(command("account.rename", #"{"id": "\#(id)"}"#), .accountRename(uuid))
        XCTAssertEqual(command("account.dismissNotice"), .accountDismissNotice)
        XCTAssertEqual(command("history.export", #"{"path": "/Users/test/Desktop/history.json"}"#),
                       .historyExport(URL(fileURLWithPath: "/Users/test/Desktop/history.json")))
        XCTAssertEqual(command("history.import", #"{"path": "/Users/test/Desktop/history.json"}"#),
                       .historyImport(URL(fileURLWithPath: "/Users/test/Desktop/history.json")))
        XCTAssertEqual(command("website.promptToken"), .websitePromptToken)
        XCTAssertEqual(command("website.promptEndpoint"), .websitePromptEndpoint)
        XCTAssertEqual(command("website.clearToken"), .websiteClearToken)
        XCTAssertEqual(command("website.publishNow"), .websitePublishNow)
    }

    func testEveryPreferenceKeyDecodes() {
        func set(_ key: String, _ value: String) -> DashboardPreferenceChange? {
            guard case .preferenceSet(let change) = command("preference.set", #"{"key": "\#(key)", "value": \#(value)}"#) else { return nil }
            return change
        }
        XCTAssertEqual(set("menuBarIcon", #""ring""#), .menuBarIcon(.ring))
        XCTAssertEqual(set("menuBarItems", #"["limitPercent", "resetCountdown"]"#), .menuBarItems([.limitPercent, .resetCountdown]))
        XCTAssertEqual(set("menuBarItems", "[]"), .menuBarItems([]))
        XCTAssertEqual(set("menuBarStyle", #""pill""#), .menuBarStyle(.pill))
        XCTAssertEqual(set("menuBarTint", #""status""#), .menuBarTint(.status))
        XCTAssertEqual(set("menuBarLimitSource", #""cursor-grok-bot""#), .menuBarLimitSource("cursor-grok-bot"))
        XCTAssertEqual(set("menuBarLimitSource", #""closest""#), .menuBarLimitSource("closest"))
        XCTAssertEqual(set("menuBarCompact", "true"), .menuBarCompact(true))
        XCTAssertEqual(set("showsLimits", "false"), .showsLimits(false))
        XCTAssertEqual(set("showsProviderBreakdown", "false"), .showsProviderBreakdown(false))
        XCTAssertEqual(set("showsActivityChart", "false"), .showsActivityChart(false))
        XCTAssertEqual(set("showsKeepAwake", "false"), .showsKeepAwake(false))
        XCTAssertEqual(set("hiddenMenuProviders", #"["Gemini", "other"]"#), .hiddenMenuProviders(["gemini", "other"]))
        XCTAssertEqual(set("defaultPeriod", #""week""#), .defaultPeriod(.week))
        XCTAssertEqual(set("defaultPeriod", #""Month""#), .defaultPeriod(.month), "the raw value is accepted too")
        XCTAssertEqual(set("barsShowRemaining", "true"), .barsShowRemaining(true))
        XCTAssertEqual(set("resetTimeStyle", #""clock""#), .resetTimeStyle(.clock))
        XCTAssertEqual(set("showsPace", "true"), .showsPace(true))
        XCTAssertEqual(set("limitProviderOrder", #"["codex", "claude"]"#), .limitProviderOrder(["codex", "claude"]))
        XCTAssertEqual(set("claudeQuotaEnabled", "true"), .claudeQuotaEnabled(true))
        XCTAssertEqual(set("cursorUsageEnabled", "true"), .cursorUsageEnabled(true))
        XCTAssertEqual(set("confettiOnReset", "false"), .confettiOnReset(false))
        XCTAssertEqual(set("notchIslandEnabled", "false"), .notchIslandEnabled(false))
        XCTAssertEqual(set("dailyTokenAlertEnabled", "true"), .dailyTokenAlertEnabled(true))
        XCTAssertEqual(set("dailyTokenAlertThreshold", "2500000"), .dailyTokenAlertThreshold(2_500_000))
        XCTAssertEqual(set("providerLimitAlertEnabled", "true"), .providerLimitAlertEnabled(true))
        XCTAssertEqual(set("providerLimitAlertThreshold", "85.5"), .providerLimitAlertThreshold(85.5))
        XCTAssertEqual(set("websitePublishEnabled", "true"), .websitePublishEnabled(true))
        XCTAssertEqual(set("websiteEndpoint", #"" https://example.test/api ""#), .websiteEndpoint("https://example.test/api"))
    }

    func testBadArgumentsAreRefusedWithAReason() {
        // Types are strict: a number is not a flag and a flag is not a number.
        XCTAssertNotNil(refusal("preference.set", #"{"key": "showsPace", "value": 1}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "providerLimitAlertThreshold", "value": true}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "showsPace"}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"value": true}"#))
        // Ranges and choices.
        XCTAssertNotNil(refusal("preference.set", #"{"key": "providerLimitAlertThreshold", "value": 150}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "providerLimitAlertThreshold", "value": 0}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "dailyTokenAlertThreshold", "value": 0}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "dailyTokenAlertThreshold", "value": 10.5}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "menuBarIcon", "value": "star"}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "menuBarItems", "value": ["todayCost", "todayCost"]}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "menuBarItems", "value": ["yesterdayCost"]}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "menuBarItems", "value": "todayCost"}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "menuBarLimitSource", "value": "gemini"}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "defaultPeriod", "value": "year"}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "limitProviderOrder", "value": ["claude", "claude"]}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "limitProviderOrder", "value": ["gemini"]}"#))
        XCTAssertNotNil(refusal("preference.set", #"{"key": "websiteEndpoint", "value": "https://a.test/\nb"}"#))
        XCTAssertEqual(refusal("preference.set", #"{"key": "menuBarDisplayMode", "value": "iconOnly"}"#),
                       #"Unknown preference "menuBarDisplayMode"."#)
        // Other commands.
        XCTAssertNotNil(refusal("limits.move", #"{"provider": "codex", "offset": 2}"#))
        XCTAssertNotNil(refusal("limits.move", #"{"provider": "gemini", "offset": 1}"#))
        XCTAssertNotNil(refusal("provider.setVisible", #"{"provider": "codex", "visible": "no"}"#))
        XCTAssertNotNil(refusal("launchAtLogin.set", "{}"))
        XCTAssertNotNil(refusal("account.startManaging", #"{"provider": "cursor"}"#))
        XCTAssertNotNil(refusal("account.switch", #"{"id": "not-a-uuid"}"#))
        XCTAssertNotNil(refusal("history.import", #"{"path": "relative/history.json"}"#))
        XCTAssertNotNil(refusal("history.export", #"{"path": "/tmp/netra-tests-data/usage-history.json"}"#),
                        "an export must not land on Netra's own files")
        XCTAssertNotNil(refusal("history.export", #"{"path": "/tmp/netra-tests-data/commands/x.json"}"#))
        XCTAssertNotNil(refusal("popover.open"), "reserved, not supported yet")
        XCTAssertEqual(refusal("dashboard.selfDestruct"), #"Unknown command "dashboard.selfDestruct"."#)
    }

    func testAnUnparseableFileIsReportedUnderItsFileName() {
        for bytes in ["not json", #"{"command": "refresh"}"#, #"{"id": "x", "command": "refresh", "at": "yesterday"}"#, ""] {
            let request = DashboardCommand.parse(Data(bytes.utf8), fallbackID: "file-id", dataDirectory: dataDirectory)
            XCTAssertEqual(request.id, "file-id", bytes)
            guard case .failure = request.command else { return XCTFail("\(bytes) should fail") }
        }
    }

    // MARK: Inbox

    func testInboxRunsOldestFirstAndDropsExpiredOnes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = URL(fileURLWithPath: "/tmp/commands")
        func entry(_ name: String, age: TimeInterval) -> DashboardInbox.Entry {
            DashboardInbox.Entry(url: folder.appendingPathComponent(name), modified: now.addingTimeInterval(-age))
        }
        let plan = DashboardInbox.plan([
            entry("b.json", age: 5), entry("a.json", age: 30), entry("old.json", age: 61),
            entry("c.json.tmp", age: 1), entry("future.json", age: -2),
        ], now: now)
        XCTAssertEqual(plan.run.map { $0.url.lastPathComponent }, ["a.json", "b.json", "future.json"])
        XCTAssertEqual(plan.expired.map(\.fallbackID), ["old"])
    }

    func testDrainDeletesEveryCommandFileButLeavesPartialWrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netra-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func write(_ name: String, _ body: String, age: TimeInterval) throws {
            let url = folder.appendingPathComponent(name)
            try Data(body.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("stale.json", #"{"id": "stale", "command": "refresh", "at": "2026-11-16T05:40:00.000Z"}"#, age: 120)
        try write("broken.json", "{ not json", age: 10)
        try write("good.json", #"{"id": "good", "command": "refresh", "at": "2026-11-16T05:40:00.000Z"}"#, age: 5)
        try write("pending.json.tmp", "{", age: 1)

        let drained = DashboardInbox.drain(directory: folder, dataDirectory: dataDirectory, now: now)
        XCTAssertEqual(drained.expired, ["stale"])
        XCTAssertEqual(drained.requests.map(\.id), ["broken", "good"])
        guard case .failure = drained.requests[0].command else { return XCTFail("broken file should fail") }
        XCTAssertEqual(drained.requests[1].command, .success(.refresh))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, ["pending.json.tmp"], "a command file is deleted before it runs")
    }
}
