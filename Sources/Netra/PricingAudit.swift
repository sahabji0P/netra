import Foundation
import os

/// Cross-checks ccusage's costs against public list prices, and patches the
/// one mispricing pattern we know how to correct. ccusage's pricing has
/// shifted silently between releases (Codex repriced, Hermes routed to the
/// wrong table entry), so a total that drifts far from tokens × list price is
/// flagged instead of trusted blindly.
enum PricingAudit {
    private static let log = Logger(subsystem: "com.sahabji0P.netra", category: "pricing")

    // MARK: Hermes routing fix

    /// ccusage 20.0.24 prices Hermes sessions billed through OpenAI under
    /// `openai/<model>`, which its fuzzy LiteLLM lookup resolves to a
    /// different model's rate (gpt-5.6-sol → OpenRouter's batch price, a
    /// quarter of list). An override on that exact key restores list price;
    /// other agents price the bare model name and are unaffected.
    /// Returns override key → canonical model to price it as.
    static func hermesRoutingKeys(in report: CCUnifiedReport) -> [String: String] {
        var keys: [String: String] = [:]
        for row in report.monthly ?? [] {
            for agent in row.agents ?? [] where agent.agent == "hermes" {
                for model in agent.modelBreakdowns ?? []
                where !model.modelName.contains("/")
                    && AgentPalette.provider(forModel: model.modelName) == "codex" {
                    keys["openai/\(model.modelName)"] = model.modelName
                }
            }
        }
        return keys
    }

    // MARK: List-price cross-check

    struct Finding: Hashable, Sendable {
        var period: String
        var agent: String
        var model: String
        var reportedCost: Double
        var listCost: Double
        var ratio: Double { reportedCost / listCost }
    }

    /// Fast/priority tiers bill up to 2× and 1-hour cache writes 1.6× the
    /// 5-minute rate, so only a gap well beyond those counts as a mispricing.
    static let acceptedRatio: ClosedRange<Double> = 0.75...2.5
    /// Below this, rounding and free tiers make the ratio meaningless.
    static let minimumListCost = 1.0

    /// Model-months whose reported cost is far from tokens × list price.
    /// `prices` uses the ccusage override field names (per-token USD).
    static func findings(in report: CCUnifiedReport, prices: [String: [String: Double]]) -> [Finding] {
        var findings: [Finding] = []
        for row in report.monthly ?? [] {
            for agent in row.agents ?? [] {
                for model in agent.modelBreakdowns ?? [] {
                    guard let price = prices[referenceName(model.modelName)],
                          let list = listCost(of: model, price: price),
                          list >= minimumListCost else { continue }
                    let finding = Finding(
                        period: row.period, agent: agent.agent, model: model.modelName,
                        reportedCost: model.cost, listCost: list
                    )
                    if !acceptedRatio.contains(finding.ratio) { findings.append(finding) }
                }
            }
        }
        return findings
    }

    /// The list-price name for a report model: Pi labels its models
    /// "[pi] gpt-5.6-sol", which no price table knows.
    static func referenceName(_ model: String) -> String {
        guard model.hasPrefix("["), let close = model.firstIndex(of: "]") else { return model }
        return model[model.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    /// Standard-tier cost; nil when the price lacks a rate the tokens need,
    /// so a partial price never raises a false alarm.
    static func listCost(of model: CCModelBreakdown, price: [String: Double]) -> Double? {
        guard let input = price["inputCostPerToken"], let output = price["outputCostPerToken"] else { return nil }
        var cost = Double(model.inputTokens) * input + Double(model.outputTokens) * output
        if model.cacheReadTokens > 0 {
            guard let cacheRead = price["cacheReadInputTokenCost"] else { return nil }
            cost += Double(model.cacheReadTokens) * cacheRead
        }
        if model.cacheCreationTokens > 0 {
            cost += Double(model.cacheCreationTokens) * (price["cacheCreationInputTokenCost"] ?? input * 1.25)
        }
        return cost
    }

    // MARK: Reference prices

    private struct ReferenceFile: Codable {
        var fetchedAt: Date
        var prices: [String: [String: Double]]
    }

    private static let referenceMaxAge: TimeInterval = 7 * 86400
    private static let referenceRetry: TimeInterval = 6 * 3600
    /// In-process retry spacing, so an offline Mac doesn't re-download every refresh.
    private static let lastAttempt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    private static var referenceURL: URL {
        PricingOverrides.configURL.deletingLastPathComponent().appendingPathComponent("reference-prices.json")
    }

    /// List prices for every model in the report, from a weekly-refreshed
    /// LiteLLM snapshot. Returns whatever is cached when a refresh fails.
    static func referencePrices(for report: CCUnifiedReport) async -> [String: [String: Double]] {
        let models = Set((report.monthly ?? []).flatMap { ($0.agents ?? []).flatMap { ($0.modelBreakdowns ?? []).map { referenceName($0.modelName) } } })
        let cached = (try? Data(contentsOf: referenceURL)).flatMap { try? JSONDecoder().decode(ReferenceFile.self, from: $0) }
        let stale = cached.map { Date.now.timeIntervalSince($0.fetchedAt) > referenceMaxAge } ?? true
        let missing = !models.isSubset(of: cached.map { Set($0.prices.keys) } ?? [])
        let due = lastAttempt.withLock { last in
            guard stale || missing, last.map({ Date.now.timeIntervalSince($0) > referenceRetry }) ?? true else { return false }
            last = .now
            return true
        }
        guard due, let table = await PricingOverrides.fetchLiteLLM() else { return cached?.prices ?? [:] }
        var prices: [String: [String: Double]] = [:]
        for model in models {
            if let priced = PricingOverrides.pricing(for: model, in: table) { prices[model] = priced }
        }
        if let data = try? JSONEncoder().encode(ReferenceFile(fetchedAt: .now, prices: prices)) {
            try? data.write(to: referenceURL, options: .atomic)
        }
        return prices
    }

    /// Logs each finding; the caller dedupes across refreshes.
    static func log(_ findings: [Finding]) {
        for finding in findings {
            log.error("""
                \(finding.agent, privacy: .public) \(finding.model, privacy: .public) \
                \(finding.period, privacy: .public): ccusage $\(finding.reportedCost, format: .fixed(precision: 2)) \
                vs list $\(finding.listCost, format: .fixed(precision: 2)) (×\(finding.ratio, format: .fixed(precision: 2)))
                """)
        }
    }
}
