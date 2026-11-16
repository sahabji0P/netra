import XCTest
@testable import Netra

/// Reading Claude Code's sign-in through `/usr/bin/security` first, so no
/// macOS consent dialog is needed. The reader is injected: no test touches
/// the real Keychain.
final class ClaudeKeychainReadTests: XCTestCase {
    private let payload = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-token"}}"#.utf8)

    override func tearDown() {
        // Leave the shared "tool is blocked" flag cleared for other tests.
        _ = ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: true) { _, _ in self.payload }
        super.tearDown()
    }

    func testTheToolReadsClaudeCodesOwnItem() {
        var asked: (service: String, account: String)?
        let data = ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: false) { service, account in
            asked = (service, account)
            return self.payload
        }
        XCTAssertEqual(data, payload)
        XCTAssertEqual(asked?.service.hasPrefix("Claude Code-credentials"), true)
        XCTAssertFalse(asked?.account.isEmpty ?? true)
    }

    /// A timeout is a dialog waiting for the user. Background refreshes must
    /// not bring it back every minute; a user action may try again.
    func testATimedOutToolIsNotAskedAgainInTheBackground() {
        var calls = 0
        let timesOut: (String, String) throws -> Data = { _, _ in
            calls += 1
            throw SecretStoreError.unavailable
        }
        XCTAssertNil(ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: false, read: timesOut))
        XCTAssertNil(ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: false, read: timesOut))
        XCTAssertEqual(calls, 1, "the second background read never runs the tool")

        XCTAssertNil(ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: true, read: timesOut))
        XCTAssertEqual(calls, 2, "a user action tries again")

        let data = ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: true) { _, _ in self.payload }
        XCTAssertEqual(data, payload)
        XCTAssertEqual(
            ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: false) { _, _ in self.payload }, payload,
            "a successful read clears the block"
        )
    }

    /// A missing item or any other failure falls through to the Keychain
    /// read as Netra, and does not stop later attempts.
    func testOtherFailuresFallThroughWithoutBlocking() {
        var calls = 0
        let fails: (String, String) throws -> Data = { _, _ in
            calls += 1
            throw SecretStoreError.failed(44)
        }
        XCTAssertNil(ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: false, read: fails))
        XCTAssertNil(ClaudeQuotaFetcher.readWithSecurityTool(allowingPrompt: false, read: fails))
        XCTAssertEqual(calls, 2)
    }
}
