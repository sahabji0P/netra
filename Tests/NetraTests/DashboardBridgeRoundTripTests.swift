import XCTest
@testable import Netra

/// The bridge end to end in a temporary folder: the state file appears and
/// follows changes, and command files dropped the way the dashboard drops
/// them are run (or refused) and answered in `results`. Synthetic stores and
/// fake system services only; nothing real is touched.
@MainActor
final class DashboardBridgeRoundTripTests: XCTestCase {
    private let suiteName = "NetraTests.DashboardBridgeRoundTrip"
    private var folder: URL!
    private var bridge: DashboardBridge?

    override func setUpWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("netra-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("commands"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        bridge?.stop()
        bridge = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeBridge(services: FakeDashboardServices) -> (DashboardBridge, AppPreferences) {
        let preferences = AppPreferences(defaults: UserDefaults(suiteName: suiteName)!)
        let store = UsageStore(
            preferences: preferences,
            alerts: UsageAlertController(scheduler: BridgeInertScheduler(), persistence: BridgeInertPersistence()),
            feedFile: UsageFeedFile(url: folder.appendingPathComponent("usage-feed.json")),
            ledger: UsageLedger(fileURL: folder.appendingPathComponent("usage-history.json")),
            publisher: UsagePublisher(defaults: UserDefaults(suiteName: suiteName)!, version: "test", tokenProvider: { _ in nil }),
            snapshotCacheURL: folder.appendingPathComponent("snapshot.json"),
            startsAutomatically: false
        )
        let bridge = DashboardBridge(
            directory: folder, preferences: preferences, store: store,
            accounts: AccountStore(preview: AccountRoster(), live: [:]),
            updates: UpdateChecker(), services: services
        )
        self.bridge = bridge
        return (bridge, preferences)
    }

    private func drop(_ body: String, id: String, age: TimeInterval = 0) throws {
        let commands = folder.appendingPathComponent("commands")
        let temporary = commands.appendingPathComponent("\(id).json.tmp")
        try Data(body.utf8).write(to: temporary)
        let final = commands.appendingPathComponent("\(id).json")
        try FileManager.default.moveItem(at: temporary, to: final)
        if age > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: final.path)
        }
    }

    private func command(_ id: String, _ name: String, _ args: String = "{}") -> String {
        #"{"id": "\#(id)", "command": "\#(name)", "at": "\#(DashboardJSON.string(from: .now))", "args": \#(args)}"#
    }

    /// Polls the state file until `condition` holds (or fails after 5 s).
    private func state(until condition: (DashboardState) -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws -> DashboardState {
        let url = folder.appendingPathComponent("dashboard-state.json")
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let state = try? DashboardJSON.decoder().decode(DashboardState.self, from: data),
               condition(state) {
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("state never matched", file: file, line: line)
        throw CancellationError()
    }

    func testStateAppearsAndFollowsCommands() async throws {
        // Written while Netra was not running: must not fire.
        try drop(command("old", "preference.set", #"{"key": "showsLimits", "value": false}"#), id: "old", age: 120)
        let (bridge, preferences) = makeBridge(services: FakeDashboardServices())
        bridge.start()

        let first = try await state { $0.results.contains { $0.id == "old" } }
        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(first.app.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(first.results.first { $0.id == "old" }!.ok)
        XCTAssertTrue(preferences.showsLimits, "an expired command never runs")

        try drop(command("pace", "preference.set", #"{"key": "showsPace", "value": false}"#), id: "pace")
        let afterSet = try await state { $0.results.contains { $0.id == "pace" } }
        XCTAssertEqual(afterSet.results.last?.ok, true)
        XCTAssertFalse(preferences.showsPace)
        XCTAssertEqual(afterSet.preferences.showsPace, false)

        // A change made in Swift reaches the file through observation.
        preferences.menuBarStyle = .outline
        _ = try await state { $0.preferences.menuBarStyle == "outline" }

        try drop("{ not json", id: "broken")
        try drop(command("bogus", "dashboard.bogus"), id: "bogus")
        let refused = try await state { s in ["broken", "bogus"].allSatisfy { id in s.results.contains { $0.id == id } } }
        XCTAssertTrue(refused.results.filter { ["broken", "bogus"].contains($0.id) }.allSatisfy { !$0.ok })

        bridge.navigate(to: "limits")
        let navigated = try await state { $0.navigate?.page == "limits" }
        let nonce = try XCTUnwrap(navigated.navigate?.nonce)
        bridge.navigate(to: "limits")
        _ = try await state { ($0.navigate?.nonce ?? 0) > nonce }

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("commands").path)
        XCTAssertEqual(left, [], "every command file is consumed")
    }

    func testHistoryImportAndExportCommands() async throws {
        let (bridge, _) = makeBridge(services: FakeDashboardServices())
        let incoming = folder.appendingPathComponent("incoming.json")
        let history = UsageHistory(days: [
            "2026-09-10": [AgentStat(name: "claude", cost: 4, totalTokens: 1_000, inputTokens: 1_000, outputTokens: 0,
                                     cacheReadTokens: 0, models: [])],
        ])
        try JSONEncoder().encode(history).write(to: incoming)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("netra-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        bridge.start()

        try drop(command("import", "history.import", #"{"path": "\#(incoming.path)"}"#), id: "import")
        let imported = try await state { $0.results.contains { $0.id == "import" } }
        let result = try XCTUnwrap(imported.results.first { $0.id == "import" })
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, "Added 1 day.")

        try drop(command("export", "history.export", #"{"path": "\#(outside.path)"}"#), id: "export")
        let exported = try await state { $0.results.contains { $0.id == "export" } }
        XCTAssertEqual(exported.results.first { $0.id == "export" }?.ok, true)
        let copy = try JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: outside))
        XCTAssertEqual(copy.days, history.days)

        try drop(command("inside", "history.export", #"{"path": "\#(folder.appendingPathComponent("copy.json").path)"}"#), id: "inside")
        let refused = try await state { $0.results.contains { $0.id == "inside" } }
        XCTAssertEqual(refused.results.first { $0.id == "inside" }?.ok, false)
    }

    func testPromptsAreAnsweredInSwiftAndNeverInTheFiles() async throws {
        let services = FakeDashboardServices(answer: "https://synthetic.example/api")
        let (bridge, preferences) = makeBridge(services: services)
        bridge.start()
        try drop(command("endpoint", "website.promptEndpoint"), id: "endpoint")
        let answered = try await state { $0.results.contains { $0.id == "endpoint" } }
        XCTAssertEqual(answered.results.first { $0.id == "endpoint" }?.ok, true)
        XCTAssertEqual(preferences.websiteEndpoint, "https://synthetic.example/api")
        XCTAssertEqual(services.prompts.titles, ["Website endpoint"])
    }
}

@MainActor
private final class PromptLog {
    var titles: [String] = []
}

@MainActor
private struct FakeDashboardServices: DashboardSystemServices {
    var answer: String?
    let prompts = PromptLog()

    init(answer: String? = nil) {
        self.answer = answer
    }

    var launchAtLoginAvailable: Bool { false }
    var launchAtLoginEnabled: Bool { false }
    var notificationsAvailable: Bool { false }
    func setLaunchAtLogin(_ enabled: Bool) {}
    func requestNotificationPermission() async {}
    func openNotificationSettings() {}
    func prompt(title: String, message: String, initial: String, secure: Bool, confirm: String) -> String? {
        prompts.titles.append(title)
        return answer
    }
}

private struct BridgeInertScheduler: UsageNotificationScheduling {
    func authorizationState() async -> NotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func schedule(_ candidate: UsageAlertCandidate) async throws {}
}

private actor BridgeInertPersistence: UsageAlertStatePersisting {
    func deliveredKeys() -> Set<String> { [] }
    func setDeliveredKeys(_ keys: Set<String>) {}
}
