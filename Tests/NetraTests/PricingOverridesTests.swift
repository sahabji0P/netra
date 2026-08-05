import XCTest
@testable import Netra

final class PricingOverridesTests: XCTestCase {
    private let table: [String: Any] = [
        "anthropic.claude-opus-5": [
            "input_cost_per_token": 5e-6,
            "output_cost_per_token": 2.5e-5,
            "cache_creation_input_token_cost": 6.25e-6,
            "cache_read_input_token_cost": 5e-7,
        ],
        "us.anthropic.claude-opus-5": [
            "input_cost_per_token": 5.5e-6,
            "output_cost_per_token": 2.75e-5,
        ],
        "gpt-5.6-sol": [
            "input_cost_per_token": 1.25e-6,
            "output_cost_per_token": 1e-5,
        ],
        "openrouter/foo/bar-2": ["input_cost_per_token": 1e-6],  // no output cost → unusable
    ]

    func testExactMatch() throws {
        let priced = try XCTUnwrap(PricingOverrides.pricing(for: "gpt-5.6-sol", in: table))
        XCTAssertEqual(priced["inputCostPerToken"], 1.25e-6)
        XCTAssertEqual(priced["outputCostPerToken"], 1e-5)
    }

    func testVendorPrefixedMatchPrefersCanonicalOverRegional() throws {
        let priced = try XCTUnwrap(PricingOverrides.pricing(for: "claude-opus-5", in: table))
        XCTAssertEqual(priced["inputCostPerToken"], 5e-6, "must pick anthropic.…, not us.anthropic.…")
        XCTAssertEqual(priced["cacheReadInputTokenCost"], 5e-7)
    }

    func testEntryWithoutOutputCostIsSkipped() {
        XCTAssertNil(PricingOverrides.pricing(for: "bar-2", in: table))
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(PricingOverrides.pricing(for: "totally-unknown", in: table))
    }

    func testUnpricedModelsFindsZeroCostWithTokens() throws {
        let json = """
        {"daily": [{"period": "2026-08-03", "inputTokens": 10, "outputTokens": 5,
          "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 15, "totalCost": 1.0,
          "modelBreakdowns": [
            {"modelName": "claude-opus-5", "cost": 0, "inputTokens": 10, "outputTokens": 5,
             "cacheCreationTokens": 0, "cacheReadTokens": 0},
            {"modelName": "claude-fable-5", "cost": 1.0, "inputTokens": 0, "outputTokens": 0,
             "cacheCreationTokens": 0, "cacheReadTokens": 0},
            {"modelName": "idle-model", "cost": 0, "inputTokens": 0, "outputTokens": 0,
             "cacheCreationTokens": 0, "cacheReadTokens": 0}
          ]}]}
        """
        let report = try JSONDecoder().decode(CCUnifiedReport.self, from: Data(json.utf8))
        XCTAssertEqual(PricingOverrides.unpricedModels(in: report), ["claude-opus-5"])
    }
}
