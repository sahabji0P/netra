import XCTest
@testable import Netra

/// Opt-in checks against this Mac's real tools, never its real sign-ins:
/// a `security` round-trip on a throwaway item, identity reads (no secrets),
/// and the Codex daemon no-op. NETRA_ACCOUNTS_LIVE=1 swift test --filter AccountsLiveProbe
final class AccountsLiveProbe: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["NETRA_ACCOUNTS_LIVE"] != nil else {
            throw XCTSkip("set NETRA_ACCOUNTS_LIVE=1 to probe the real keychain tool and CLIs")
        }
    }

    func testSecurityToolRoundTripOnThrowawayItem() throws {
        let keychain = SecurityCommandKeychain()
        let service = "Netra Test \(UUID().uuidString)"
        defer { try? keychain.delete(service: service, account: "probe") }
        XCTAssertThrowsError(try keychain.read(service: service, account: "probe")) {
            XCTAssertEqual($0 as? SecretStoreError, .notFound)
        }
        let small = Data(#"{"claudeAiOauth":{"accessToken":"SYNTHETIC"}}"#.utf8)
        try keychain.write(small, service: service, account: "probe")
        XCTAssertEqual(try keychain.read(service: service, account: "probe"), small)
        // Larger than a `security -i` line: exercises the argv path.
        let large = Data(("{\"blob\":\"" + String(repeating: "S", count: 6000) + "\"}").utf8)
        try keychain.write(large, service: service, account: "probe")
        XCTAssertEqual(try keychain.read(service: service, account: "probe"), large)
        try keychain.delete(service: service, account: "probe")
        XCTAssertThrowsError(try keychain.read(service: service, account: "probe"))
    }

    func testLiveIdentitiesAreReadable() {
        let claude = ClaudeAccountSession.current().liveIdentity()
        let codex = CodexAccountSession.current().liveIdentity()
        print("claude identity:", claude.map { "plan=\($0.plan ?? "-") hasEmail=\($0.email != nil)" } ?? "none")
        print("codex identity:", codex.map { "plan=\($0.plan ?? "-") hasEmail=\($0.email != nil)" } ?? "none")
        print("claude keychain service:", ClaudeAccountSession.current().keychainService)
    }

    /// Reads (never writes) the live sign-ins the way a switch would, and
    /// prints only key names.
    func testLiveCaptureReadsWithoutPrompting() throws {
        if let claude = try ClaudeAccountSession.current().captureLive() {
            let owned = (try JSONSerialization.jsonObject(with: claude.entry.claudeCredentials ?? Data()) as? [String: Any])?.keys.sorted()
            print("claude captured keys:", owned ?? [], "expires:", claude.signInExpiresAt != nil)
            XCTAssertEqual(owned?.contains("mcpOAuth"), false)
        } else {
            print("claude: not signed in")
        }
        print("codex captured:", CodexAccountSession.current().captureLive() != nil)
    }

    func testDaemonRestartIsANoOpWhenNotRunning() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("netra-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertFalse(CodexAccountSession(home: home).restartDaemonIfRunning())
    }
}
