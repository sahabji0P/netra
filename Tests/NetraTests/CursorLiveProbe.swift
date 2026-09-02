import XCTest
@testable import Netra

/// Dev-only live probe: hits Cursor's account API with your local login to
/// confirm the fetcher works and to dump the real field shape (usage numbers
/// only — never the token). Runs only when NETRA_CURSOR_LIVE is set.
final class CursorLiveProbe: XCTestCase {
    func testLiveCursorUsage() async throws {
        guard ProcessInfo.processInfo.environment["NETRA_CURSOR_LIVE"] != nil else {
            throw XCTSkip("set NETRA_CURSOR_LIVE to hit the live Cursor API")
        }
        let creds = try XCTUnwrap(CursorCredentialReader.read(), "no usable Cursor login found")
        print("CURSOR: userID len=\(creds.userID.count) plan=\(creds.membershipType ?? "?")")
        let cookie = "WorkosCursorSessionToken=\(creds.userID)%3A%3A\(creds.accessToken)"

        // 1. usage-summary (GET)
        var summary = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        summary.setValue("application/json", forHTTPHeaderField: "Accept")
        summary.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (sData, sResp) = try await URLSession.shared.data(for: summary)
        print("=== usage-summary HTTP \((sResp as? HTTPURLResponse)?.statusCode ?? -1) ===")
        dump(sData)

        // 2. get-sand-usage-status (POST {} with Origin) — the Grok Bot window
        var sand = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!)
        sand.httpMethod = "POST"
        sand.setValue("application/json", forHTTPHeaderField: "Accept")
        sand.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sand.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        sand.setValue(cookie, forHTTPHeaderField: "Cookie")
        sand.httpBody = Data("{}".utf8)
        let (gData, gResp) = try await URLSession.shared.data(for: sand)
        print("=== get-sand-usage-status HTTP \((gResp as? HTTPURLResponse)?.statusCode ?? -1) ===")
        dump(gData)
    }

    /// Prints the JSON structure with field names and values. Response bodies
    /// carry usage figures, not credentials.
    private func dump(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            print(String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8>")
            return
        }
        let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(pretty.flatMap { String(data: $0, encoding: .utf8) } ?? "<unprintable>")
    }
}
