import Foundation
import os

/// Fetches Cursor usage from Cursor's own account API. Cursor keeps no usage
/// data on local disk, so this is the only source; it uses the login token
/// Cursor itself stored (read-only) and sends it only to cursor.com.
///
/// Read-only "cookie" path (as used by CodexBar): one GET to
/// `cursor.com/api/usage-summary` returns the percent, the billing-cycle
/// reset, and the plan in a single response, with no token refresh and no
/// write-back to Cursor's store. The endpoint is undocumented and may change.
enum CursorUsageFetcher {
    private static let log = Logger(subsystem: "com.sahabji0P.netra", category: "cursor")
    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    enum CursorUsageError: Error {
        case noCredentials
        case http(Int)
        case decoding
    }

    static func fetch(now: Date = .now) async throws -> CursorQuota {
        guard let credentials = CursorCredentialReader.read() else {
            throw CursorUsageError.noCredentials
        }

        var request = URLRequest(url: summaryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "WorkosCursorSessionToken=\(credentials.userID)%3A%3A\(credentials.accessToken)",
            forHTTPHeaderField: "Cookie"
        )
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CursorUsageError.http(-1) }
        guard http.statusCode == 200 else {
            log.error("cursor usage-summary HTTP \(http.statusCode)")
            throw CursorUsageError.http(http.statusCode)
        }

        guard let quota = quota(fromSummary: data, fallbackPlan: credentials.membershipType, now: now) else {
            throw CursorUsageError.decoding
        }
        return quota
    }

    /// Parses the `usage-summary` response. Split out so the (undocumented,
    /// schema-unstable) contract can be locked down with fixture tests.
    static func quota(fromSummary data: Data, fallbackPlan: String?, now: Date = .now) -> CursorQuota? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let reset = (object["billingCycleEnd"] as? String).flatMap(ClaudeQuotaFetcher.parseDate)
        let individual = object["individualUsage"] as? [String: Any]
        let team = object["teamUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]

        var windows: [QuotaWindow] = []
        if let percent = includedPercent(plan: plan, individual: individual, team: team) {
            windows.append(QuotaWindow(label: "included usage", usedPercent: percent, resetsAt: reset))
        }
        // On-demand spend, when the user has a finite cap, as a second meter.
        if let onDemand = individual?["onDemand"] as? [String: Any],
           onDemand["enabled"] as? Bool == true,
           let limit = cents(onDemand["limit"]), limit > 0,
           let used = cents(onDemand["used"]) {
            windows.append(QuotaWindow(
                label: "on-demand spend",
                usedPercent: min(used / limit * 100, 100),
                resetsAt: reset
            ))
        }
        guard !windows.isEmpty else { return nil }

        let membership = (object["membershipType"] as? String) ?? fallbackPlan
        return CursorQuota(windows: windows, planType: planLabel(membership), fetchedAt: now)
    }

    /// CodexBar's headline-percent precedence: the plan's total percent, then
    /// the mean of the auto/api lanes, then either lane, then used/limit for
    /// the plan, the personal overall cap, and finally the team pool.
    private static func includedPercent(
        plan: [String: Any]?, individual: [String: Any]?, team: [String: Any]?
    ) -> Double? {
        if let total = plan?["totalPercentUsed"] as? Double { return clampPercent(total) }
        let auto = plan?["autoPercentUsed"] as? Double
        let api = plan?["apiPercentUsed"] as? Double
        if let auto, let api { return clampPercent((auto + api) / 2) }
        if let api { return clampPercent(api) }
        if let auto { return clampPercent(auto) }
        if let percent = ratioPercent(plan) { return percent }
        if let percent = ratioPercent(individual?["overall"] as? [String: Any]) { return percent }
        if let percent = ratioPercent(team?["pooled"] as? [String: Any]) { return percent }
        return nil
    }

    private static func ratioPercent(_ bucket: [String: Any]?) -> Double? {
        guard let bucket, let used = cents(bucket["used"]), let limit = cents(bucket["limit"]),
              limit > 0 else { return nil }
        return clampPercent(used / limit * 100)
    }

    /// Cursor's percent fields are already in percentage units even when
    /// fractional (0.36 means 0.36%, not 36%).
    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func cents(_ value: Any?) -> Double? {
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
}
