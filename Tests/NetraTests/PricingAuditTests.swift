import XCTest
@testable import Netra

final class PricingAuditTests: XCTestCase {
    private func model(_ name: String, cost: Double, input: Int = 1_000_000, output: Int = 100_000,
                       cacheRead: Int = 0, cacheWrite: Int = 0) -> CCModelBreakdown {
        CCModelBreakdown(modelName: name, cost: cost, inputTokens: input, outputTokens: output,
                         cacheCreationTokens: cacheWrite, cacheReadTokens: cacheRead)
    }

    private func report(_ agents: [String: [CCModelBreakdown]], period: String = "2026-07") -> CCUnifiedReport {
        let rows = agents.map { agent, models in
            CCAgentRow(agent: agent, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0,
                       cacheReadTokens: 0, totalTokens: 0, totalCost: models.reduce(0) { $0 + $1.cost },
                       modelBreakdowns: models)
        }
        return CCUnifiedReport(daily: [], weekly: [], monthly: [CCRow(
            period: period, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
            totalTokens: 0, totalCost: 0, agents: rows, modelBreakdowns: []
        )])
    }

    private let sol = ["inputCostPerToken": 4e-6, "outputCostPerToken": 2e-5, "cacheReadInputTokenCost": 4e-7]

    func testHermesOpenAIModelsGetPrefixedOverrideKeys() {
        let keys = PricingAudit.hermesRoutingKeys(in: report([
            "hermes": [model("gpt-5.6-sol", cost: 1), model("claude-opus-5", cost: 1), model("openai/gpt-5.5", cost: 1)],
            "codex": [model("gpt-5.6-terra", cost: 1)],
        ]))
        // Only Hermes, only OpenAI-family models, never already-prefixed names.
        XCTAssertEqual(keys, ["openai/gpt-5.6-sol": "gpt-5.6-sol"])
    }

    func testFlagsCostFarBelowListPrice() throws {
        // List: 1M × $4 + 100k × $20 = $6.00; ccusage's mis-routed $1.50 is ×0.25.
        let findings = PricingAudit.findings(
            in: report(["hermes": [model("gpt-5.6-sol", cost: 1.5)]]), prices: ["gpt-5.6-sol": sol]
        )
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.agent, "hermes")
        XCTAssertEqual(finding.listCost, 6, accuracy: 0.000_1)
        XCTAssertEqual(finding.ratio, 0.25, accuracy: 0.000_1)
    }

    func testAcceptsPriorityTierAndIgnoresNoise() {
        let findings = PricingAudit.findings(in: report([
            // Fast mode bills 2× list: legitimate, not a finding.
            "codex": [model("gpt-5.6-sol", cost: 12)],
            // $0.06 at list: too small for a ratio to mean anything.
            "pi": [model("gpt-5.6-sol", cost: 0, input: 10_000, output: 1_000)],
        ]), prices: ["gpt-5.6-sol": sol])
        XCTAssertEqual(findings, [])
    }

    func testFlagsOverpricingAndPricesPiModelsByBareName() {
        let findings = PricingAudit.findings(
            in: report(["pi": [model("[pi] gpt-5.6-sol", cost: 18)]]), prices: ["gpt-5.6-sol": sol]
        )
        XCTAssertEqual(findings.map(\.model), ["[pi] gpt-5.6-sol"])
        XCTAssertEqual(PricingAudit.referenceName("[pi] gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(PricingAudit.referenceName("gpt-5.6-sol"), "gpt-5.6-sol")
    }

    func testPartialPriceNeverRaisesAlarm() {
        // Cache reads used but the reference has no cache-read rate: skip.
        let priceWithoutCache = ["inputCostPerToken": 4e-6, "outputCostPerToken": 2e-5]
        XCTAssertNil(PricingAudit.listCost(
            of: model("gpt-5.6-sol", cost: 1, cacheRead: 1_000_000), price: priceWithoutCache
        ))
        XCTAssertEqual(PricingAudit.findings(
            in: report(["hermes": [model("gpt-5.6-sol", cost: 0.01, cacheRead: 1_000_000)]]),
            prices: ["gpt-5.6-sol": priceWithoutCache]
        ), [])
    }
}
