import XCTest
@testable import Netra

/// Dev-only live probe: hits cursor.com with your local Cursor login to confirm
/// the fetcher works end-to-end. Runs only when NETRA_CURSOR_LIVE is set.
/// Prints no token — only the parsed usage numbers.
final class CursorLiveProbe: XCTestCase {
    func testLiveCursorUsage() async throws {
        guard ProcessInfo.processInfo.environment["NETRA_CURSOR_LIVE"] != nil else {
            throw XCTSkip("set NETRA_CURSOR_LIVE to hit the live Cursor API")
        }
        let creds = try XCTUnwrap(CursorCredentialReader.read(), "no usable Cursor login found")
        print("CURSOR: userID len=\(creds.userID.count) plan=\(creds.membershipType ?? "?")")
        let quota = try await CursorUsageFetcher.fetch()
        print("CURSOR plan=\(quota.planType ?? "?")")
        for w in quota.windows {
            let reset = w.resetsAt.map { "\($0)" } ?? "n/a"
            print("  \(w.label): \(Int(w.usedPercent))% resets \(reset)")
        }
        XCTAssertFalse(quota.windows.isEmpty)
    }
}
