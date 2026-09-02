import Foundation
import os

/// Fetches Cursor usage from Cursor's own account API. Cursor keeps no usage
/// data on local disk, so this is the only source; it uses the login token
/// Cursor itself stored (read-only) and sends it only to cursor.com.
///
/// Two read-only "cookie" endpoints (as used by CodexBar):
///  - `GET /api/usage-summary` — the included-usage pool and its API/Auto
///    sub-limits, plus the billing-cycle reset and the plan.
///  - `POST /api/dashboard/get-sand-usage-status` — the weekly "Grok Bot"
///    window. Best-effort; the plan windows still show if it fails.
///
/// No token refresh, no write-back to Cursor's store. The endpoints are
/// undocumented and may change.
enum CursorUsageFetcher {
    private static let log = Logger(subsystem: "com.sahabji0P.netra", category: "cursor")
    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let sandURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!

    enum CursorUsageError: Error {
        case noCredentials
        case http(Int)
        case decoding
    }

    static func fetch(now: Date = .now) async throws -> CursorQuota {
        guard let credentials = CursorCredentialReader.read() else {
            throw CursorUsageError.noCredentials
        }
        let cookie = "WorkosCursorSessionToken=\(credentials.userID)%3A%3A\(credentials.accessToken)"

        let summaryData = try await get(summaryURL, cookie: cookie)
        // The Grok Bot window lives behind a second, POST endpoint; its failure
        // must not drop the plan windows.
        let sandData = try? await postEmpty(sandURL, cookie: cookie)

        guard let quota = quota(
            fromSummary: summaryData, sandStatus: sandData,
            fallbackPlan: credentials.membershipType, now: now
        ) else {
            throw CursorUsageError.decoding
        }
        return quota
    }

    // MARK: Parsing (split out for fixture tests)

    /// Builds Cursor's usage windows from the two endpoint responses.
    static func quota(
        fromSummary summaryData: Data,
        sandStatus sandData: Data?,
        fallbackPlan: String?,
        now: Date = .now
    ) -> CursorQuota? {
        guard let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
            return nil
        }

        let cycleReset = (summary["billingCycleEnd"] as? String).flatMap(ClaudeQuotaFetcher.parseDate)
        let individual = summary["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]

        var windows: [QuotaWindow] = []
        // The included pool and its two sub-lanes: named/API models (which
        // carry their own sub-limit) and Cursor's auto model selection.
        appendPlanWindow(&windows, plan, key: "totalPercentUsed", label: "included usage", reset: cycleReset)
        appendPlanWindow(&windows, plan, key: "apiPercentUsed", label: "API models", reset: cycleReset)
        appendPlanWindow(&windows, plan, key: "autoPercentUsed", label: "auto models", reset: cycleReset)
        // On-demand spend, when the user has a finite cap.
        if let onDemand = individual?["onDemand"] as? [String: Any],
           onDemand["enabled"] as? Bool == true,
           let limit = number(onDemand["limit"]), limit > 0,
           let used = number(onDemand["used"]) {
            windows.append(QuotaWindow(
                label: "on-demand spend",
                usedPercent: clampPercent(used / limit * 100),
                resetsAt: cycleReset
            ))
        }
        // Weekly Grok Bot window from the second endpoint.
        if let sandData, let grok = grokWindow(fromSandStatus: sandData) {
            windows.append(grok)
        }

        if windows.isEmpty {
            // Enterprise/legacy shapes can omit the plan block; fall back to the
            // plan's own used/limit ratio so the row is not silently dropped.
            if let percent = ratioPercent(plan) {
                windows.append(QuotaWindow(label: "included usage", usedPercent: percent, resetsAt: cycleReset))
            }
        }
        guard !windows.isEmpty else { return nil }

        let membership = (summary["membershipType"] as? String) ?? fallbackPlan
        return CursorQuota(windows: windows, planType: planLabel(membership), fetchedAt: now)
    }

    /// The Grok Bot weekly window. Skipped when the plan has no included Grok
    /// allowance (`hasNonZeroIncludedLimit != true`).
    static func grokWindow(fromSandStatus data: Data) -> QuotaWindow? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hasNonZeroIncludedLimit"] as? Bool == true,
              let percent = number(object["usagePercent"]) else { return nil }
        let reset = (object["nextResetTimestampUtc"] as? String).flatMap(ClaudeQuotaFetcher.parseDate)
        return QuotaWindow(label: "Grok Bot", usedPercent: clampPercent(percent), resetsAt: reset)
    }

    private static func appendPlanWindow(
        _ windows: inout [QuotaWindow], _ plan: [String: Any]?,
        key: String, label: String, reset: Date?
    ) {
        guard let percent = number(plan?[key]) else { return }
        windows.append(QuotaWindow(label: label, usedPercent: clampPercent(percent), resetsAt: reset))
    }

    private static func ratioPercent(_ bucket: [String: Any]?) -> Double? {
        guard let bucket, let used = number(bucket["used"]), let limit = number(bucket["limit"]),
              limit > 0 else { return nil }
        return clampPercent(used / limit * 100)
    }

    /// Cursor's percent fields are already in percentage units even when
    /// fractional (0.36 means 0.36%, not 36%).
    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func planLabel(_ membership: String?) -> String? {
        guard let membership, !membership.isEmpty else { return nil }
        switch membership {
        case "pro": return "Pro"
        case "pro_plus": return "Pro+"
        case "ultra": return "Ultra"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "free_trial": return "Free trial"
        case "pro_student": return "Student"
        case "hobby": return "Hobby"
        default: return membership.prefix(1).uppercased() + membership.dropFirst()
        }
    }

    // MARK: Requests

    private static func get(_ url: URL, cookie: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 12
        return try await send(request)
    }

    private static func postEmpty(_ url: URL, cookie: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The dashboard POST endpoints require a matching Origin (CSRF check).
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CursorUsageError.http(-1) }
        guard http.statusCode == 200 else {
            log.error("cursor \(request.url?.lastPathComponent ?? "?", privacy: .public) HTTP \(http.statusCode)")
            throw CursorUsageError.http(http.statusCode)
        }
        return data
    }
}
