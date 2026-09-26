import Foundation
import os

/// Fetches Cursor usage from Cursor's own account API: quota windows and
/// cycle totals here, per-event history in `CursorUsageEventsFetcher`. It uses the login token Cursor itself stored
/// (read-only) and sends it only to cursor.com.
///
/// Read-only "cookie" endpoints:
///  - `GET /api/usage-summary` — included-usage pool, API/Auto sub-limits,
///    billing-cycle reset, and plan.
///  - `POST /api/dashboard/get-sand-usage-status` — weekly "Grok Bot" window.
///    Best-effort; the plan windows still show if it fails.
///  - `POST /api/dashboard/get-aggregated-usage-events` — per-model tokens
///    and API-price cents for the current cycle. `totalCostCents` equals the
///    summary's `plan.breakdown.total` (included + bonus drawn), so it is
///    usage value, not an invoice. Best-effort.
///
/// No token refresh, no write-back to Cursor's store. The endpoints are
/// undocumented and may change.
enum CursorUsageFetcher {
    private static let log = Logger(subsystem: "com.sahabji0P.netra", category: "cursor")
    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let sandURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
    private static let aggregationsURL = URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!

    enum CursorUsageError: Error {
        case noCredentials
        case http(Int)
        case decoding
    }

    static func fetch(now: Date = .now) async throws -> CursorQuota {
        guard let credentials = CursorCredentialReader.read() else {
            throw CursorUsageError.noCredentials
        }
        let cookie = sessionCookie(credentials)

        let summaryData = try await get(summaryURL, cookie: cookie)
        // Secondary endpoints are best-effort: their failure must not drop
        // the plan windows from usage-summary.
        let sandData = try? await postEmpty(sandURL, cookie: cookie)
        let aggregationsData: Data?
        if let range = cycleRange(fromSummary: summaryData, now: now) {
            aggregationsData = try? await postJSON(aggregationsURL, cookie: cookie, body: [
                "teamId": -1,
                "startDate": range.startMs,
                "endDate": range.endMs,
            ])
        } else {
            aggregationsData = nil
        }

        guard let quota = quota(
            fromSummary: summaryData, sandStatus: sandData,
            aggregations: aggregationsData,
            fallbackPlan: credentials.membershipType, now: now
        ) else {
            throw CursorUsageError.decoding
        }
        return quota
    }

    // MARK: Parsing (split out for fixture tests)

    /// Builds Cursor's usage windows and cycle totals from the endpoint responses.
    static func quota(
        fromSummary summaryData: Data,
        sandStatus sandData: Data?,
        aggregations aggregationsData: Data? = nil,
        fallbackPlan: String?,
        now: Date = .now
    ) -> CursorQuota? {
        guard let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
            return nil
        }

        let cycleStart = (summary["billingCycleStart"] as? String).flatMap(ISODate.parse)
        let cycleReset = (summary["billingCycleEnd"] as? String).flatMap(ISODate.parse)
        let individual = summary["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]

        let cycleLength: Double? = {
            guard let cycleStart, let cycleReset, cycleReset > cycleStart else { return nil }
            return cycleReset.timeIntervalSince(cycleStart)
        }()
        var windows: [QuotaWindow] = []
        // The included pool and its two sub-lanes: named/API models (which
        // carry their own sub-limit) and Cursor's auto model selection.
        appendPlanWindow(&windows, plan, key: "totalPercentUsed", label: "included usage", reset: cycleReset, duration: cycleLength)
        appendPlanWindow(&windows, plan, key: "apiPercentUsed", label: "API models", reset: cycleReset, duration: cycleLength)
        appendPlanWindow(&windows, plan, key: "autoPercentUsed", label: "auto models", reset: cycleReset, duration: cycleLength)
        // On-demand spend, when the user has a finite cap.
        if let onDemand = individual?["onDemand"] as? [String: Any],
           onDemand["enabled"] as? Bool == true,
           let limit = JSONValue.number(onDemand["limit"]), limit > 0,
           let used = JSONValue.number(onDemand["used"]) {
            windows.append(QuotaWindow(
                label: "on-demand spend",
                usedPercent: clampPercent(used / limit * 100),
                resetsAt: cycleReset,
                durationSeconds: cycleLength
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
                windows.append(QuotaWindow(
                    label: "included usage", usedPercent: percent, resetsAt: cycleReset, durationSeconds: cycleLength
                ))
            }
        }
        guard !windows.isEmpty else { return nil }

        let membership = (summary["membershipType"] as? String) ?? fallbackPlan
        let billed = aggregationsData.flatMap(billedUsage(fromAggregations:))
        let onDemandCents = (individual?["onDemand"] as? [String: Any]).flatMap { JSONValue.number($0["used"]) }
        return CursorQuota(
            windows: windows,
            planType: planLabel(membership),
            fetchedAt: now,
            billingCycleStart: cycleStart,
            billingCycleEnd: cycleReset,
            models: billed?.models ?? [],
            inputTokens: billed?.inputTokens ?? 0,
            outputTokens: billed?.outputTokens ?? 0,
            cacheCreationTokens: billed?.cacheWriteTokens ?? 0,
            cacheReadTokens: billed?.cacheReadTokens ?? 0,
            usageValueUSD: billed?.costUSD,
            onDemandSpendUSD: onDemandCents.map { $0 / 100 }
        )
    }

    /// Per-model tokens and API-price cents for the requested window.
    static func billedUsage(fromAggregations data: Data) -> (
        models: [ModelStat], inputTokens: Int, outputTokens: Int,
        cacheWriteTokens: Int, cacheReadTokens: Int, costUSD: Double?
    )? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["aggregations"] as? [Any] else { return nil }

        var models: [ModelStat] = []
        for row in rows {
            guard let item = row as? [String: Any] else { continue }
            let name = JSONValue.string(item["modelIntent"]) ?? JSONValue.string(item["model"]) ?? "cursor"
            let input = JSONValue.int(item["inputTokens"]) ?? 0
            let output = JSONValue.int(item["outputTokens"]) ?? 0
            let cacheWrite = JSONValue.int(item["cacheWriteTokens"]) ?? 0
            let cacheRead = JSONValue.int(item["cacheReadTokens"]) ?? 0
            let total = input + output + cacheWrite + cacheRead
            guard total > 0 || name != "cursor" else { continue }
            let cents = JSONValue.number(item["totalCents"])
            models.append(ModelStat(
                name: name,
                cost: (cents ?? 0) / 100,
                totalTokens: total,
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheWrite,
                cacheReadTokens: cacheRead
            ))
        }
        models.sort {
            $0.cost == $1.cost ? $0.totalTokens > $1.totalTokens : $0.cost > $1.cost
        }

        let input = JSONValue.int(object["totalInputTokens"]) ?? models.reduce(0) { $0 + $1.inputTokens }
        let output = JSONValue.int(object["totalOutputTokens"]) ?? models.reduce(0) { $0 + $1.outputTokens }
        let cacheWrite = JSONValue.int(object["totalCacheWriteTokens"])
            ?? models.reduce(0) { $0 + $1.cacheCreationTokens }
        let cacheRead = JSONValue.int(object["totalCacheReadTokens"])
            ?? models.reduce(0) { $0 + $1.cacheReadTokens }
        let costUSD: Double?
        if let reported = JSONValue.number(object["totalCostCents"]) {
            costUSD = reported > 0 ? reported / 100 : nil
        } else {
            let summed = models.reduce(0) { $0 + $1.cost * 100 }
            costUSD = summed > 0 ? summed / 100 : nil
        }
        guard !models.isEmpty || input + output + cacheWrite + cacheRead > 0 else { return nil }
        return (models, input, output, cacheWrite, cacheRead, costUSD)
    }

    static func cycleRange(fromSummary data: Data, now: Date = .now) -> (startMs: Int, endMs: Int)? {
        guard let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = (summary["billingCycleStart"] as? String).flatMap(ISODate.parse)
        else { return nil }
        let end = (summary["billingCycleEnd"] as? String).flatMap(ISODate.parse) ?? now
        return (
            Int(start.timeIntervalSince1970 * 1000),
            Int(max(end, now).timeIntervalSince1970 * 1000)
        )
    }

    /// The Grok Bot weekly window. Skipped when the plan has no included Grok
    /// allowance (`hasNonZeroIncludedLimit != true`).
    static func grokWindow(fromSandStatus data: Data) -> QuotaWindow? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hasNonZeroIncludedLimit"] as? Bool == true,
              let percent = JSONValue.number(object["usagePercent"]) else { return nil }
        let reset = (object["nextResetTimestampUtc"] as? String).flatMap(ISODate.parse)
        let start = (object["currentPeriodStart"] as? String).flatMap(ISODate.parse)
        let length = reset.flatMap { reset in start.map { reset.timeIntervalSince($0) } }
        return QuotaWindow(
            label: "Grok Bot", usedPercent: clampPercent(percent), resetsAt: reset,
            durationSeconds: length.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func appendPlanWindow(
        _ windows: inout [QuotaWindow], _ plan: [String: Any]?,
        key: String, label: String, reset: Date?, duration: Double?
    ) {
        guard let percent = JSONValue.number(plan?[key]) else { return }
        windows.append(QuotaWindow(
            label: label, usedPercent: clampPercent(percent), resetsAt: reset, durationSeconds: duration
        ))
    }

    private static func ratioPercent(_ bucket: [String: Any]?) -> Double? {
        guard let bucket, let used = JSONValue.number(bucket["used"]), let limit = JSONValue.number(bucket["limit"]),
              limit > 0 else { return nil }
        return clampPercent(used / limit * 100)
    }

    /// Cursor's percent fields are already in percentage units even when
    /// fractional (0.36 means 0.36%, not 36%).
    private static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
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

    /// Cursor's dashboard session cookie, built from the login Cursor saved.
    static func sessionCookie(_ credentials: CursorCredentialReader.Credentials? = CursorCredentialReader.read()) -> String? {
        guard let credentials else { return nil }
        return sessionCookie(credentials)
    }

    static func sessionCookie(_ credentials: CursorCredentialReader.Credentials) -> String {
        "WorkosCursorSessionToken=\(credentials.userID)%3A%3A\(credentials.accessToken)"
    }

    private static func postEmpty(_ url: URL, cookie: String) async throws -> Data {
        try await postJSON(url, cookie: cookie, body: [String: Any]())
    }

    static func postJSON(_ url: URL, cookie: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The dashboard POST endpoints require a matching Origin (CSRF check).
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
