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

        let summaryObject = try JSONSerialization.jsonObject(with: sData) as? [String: Any]
        let start = (summaryObject?["billingCycleStart"] as? String).flatMap(ISODate.parse)
            ?? Date.now.addingTimeInterval(-30 * 24 * 3600)
        var aggregations = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!)
        aggregations.httpMethod = "POST"
        aggregations.setValue("application/json", forHTTPHeaderField: "Accept")
        aggregations.setValue("application/json", forHTTPHeaderField: "Content-Type")
        aggregations.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        aggregations.setValue(cookie, forHTTPHeaderField: "Cookie")
        aggregations.httpBody = try JSONSerialization.data(withJSONObject: [
            "teamId": -1,
            "startDate": Int(start.timeIntervalSince1970 * 1000),
            "endDate": Int(Date.now.timeIntervalSince1970 * 1000),
        ])
        let (aData, aResp) = try await URLSession.shared.data(for: aggregations)
        print("=== get-aggregated-usage-events HTTP \((aResp as? HTTPURLResponse)?.statusCode ?? -1) ===")
        dump(aData)

        // 4. get-filtered-usage-events — history depth and pagination check.
        func eventsPage(from: Date, page: Int, size: Int) async throws -> [String: Any] {
            var events = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!)
            events.httpMethod = "POST"
            events.setValue("application/json", forHTTPHeaderField: "Accept")
            events.setValue("application/json", forHTTPHeaderField: "Content-Type")
            events.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            events.setValue(cookie, forHTTPHeaderField: "Cookie")
            events.httpBody = try JSONSerialization.data(withJSONObject: [
                "page": page, "pageSize": size,
                "startDate": String(Int(from.timeIntervalSince1970 * 1000)),
                "endDate": String(Int(Date.now.timeIntervalSince1970 * 1000)),
            ])
            let (data, _) = try await URLSession.shared.data(for: events)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let deep = try await eventsPage(from: .now.addingTimeInterval(-190 * 86400), page: 1, size: 1)
        print("=== events since 190d: count \(deep["totalUsageEventsCount"] ?? "nil")")
        let rows = (deep["usageEventsDisplay"] as? [[String: Any]]) ?? []
        print("keys:", rows.first.map { $0.keys.sorted() } ?? [])

        // Pull the whole cycle via the production fetcher and compare with
        // the aggregated endpoint's own total for the same window.
        let synced = try await CursorUsageEventsFetcher.fetch(cookie: cookie, since: start, until: .now)
        let cents = synced.events.reduce(0) { $0 + $1.costCents }
        let tokens = synced.events.reduce(0) { $0 + CursorUsageEvents.tokenParts(of: $1).total }
        print("=== cycle events \(synced.events.count) of reported \(synced.reportedCount.map(String.init) ?? "nil"), unpriced \(synced.events.filter { !$0.priced }.count), cents \(cents), tokens \(tokens)")
        if let agg = try? JSONSerialization.jsonObject(with: aData) as? [String: Any] {
            print("=== aggregated totalCostCents \(agg["totalCostCents"] ?? "nil")")
            for row in (agg["aggregations"] as? [[String: Any]]) ?? [] {
                print("AGG", row["modelIntent"] ?? "?", row["totalCents"] ?? 0)
            }
        }
        var byModelKind: [String: (Int, Double)] = [:]
        for e in synced.events {
            let key = "\(e.model) | \(e.kind ?? "-")"
            let cur = byModelKind[key] ?? (0, 0)
            byModelKind[key] = (cur.0 + 1, cur.1 + e.costCents)
        }
        for (k, v) in byModelKind.sorted(by: { $0.value.1 > $1.value.1 }) { print("EVT", k, v.0, v.1) }
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
