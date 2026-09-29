import Foundation
import XCTest
@testable import Netra

/// Runs the pinned `ccusage-bin` against synthetic agent logs in a throwaway
/// home directory (never the real one), then decodes its output with Netra's
/// DTOs. Guards regressions that only a binary upgrade or downgrade can cause.
final class PinnedCCUsageTests: XCTestCase {
    private var binary: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ccusage-bin")
    }

    /// ccusage 20.0.26 prices Hermes sessions billed through OpenAI under
    /// `openai/<model>`, which resolves to OpenRouter's batch rate. The
    /// override Netra writes for that exact key must restore list price
    /// ($4 in / $20 out / $0.40 cache read per 1M for gpt-5.6-sol).
    func testHermesOpenAIRoutingOverrideRestoresListPrice() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hermes = home.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        let sql = try XCTUnwrap(Bundle.module.url(
            forResource: "hermes-openai-routing.sql", withExtension: nil, subdirectory: "Fixtures"
        ))
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [hermes.appendingPathComponent("state.db").path]
        sqlite.standardInput = try FileHandle(forReadingFrom: sql)
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        let config = home.appendingPathComponent("ccusage-config.json")
        let override = ["inputCostPerToken": 4e-6, "outputCostPerToken": 2e-5, "cacheReadInputTokenCost": 4e-7]
        try JSONSerialization.data(withJSONObject: [
            "defaults": ["pricingOverrides": ["openai/gpt-5.6-sol": override]],
        ]).write(to: config)

        let report = try runReport(home: home, extraArguments: ["--config", config.path])
        let costs = (report.daily ?? []).compactMap { $0.agents?.first { $0.agent == "hermes" }?.totalCost }
        XCTAssertEqual(costs.count, 2)
        for cost in costs { XCTAssertEqual(cost, 0.64, accuracy: 0.001) }
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("netra-ccusage-\(UUID().uuidString)", isDirectory: true)
        // ccusage exits with an error when CLAUDE_CONFIG_DIR has no projects/.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects", isDirectory: true), withIntermediateDirectories: true
        )
        return home
    }

    private func runReport(home: URL, extraArguments: [String] = []) throws -> CCUnifiedReport {
        let data = try runBinary(home: home, arguments: [
            "daily", "--sections", "daily,weekly,monthly", "--by-agent",
            "--json", "--offline", "--since", "20260901", "--until", "20260930",
        ] + extraArguments)
        return try JSONDecoder().decode(CCUnifiedReport.self, from: data)
    }

    private func runBinary(home: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = [
            "HOME": home.path,
            "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
            "PATH": "/usr/bin:/bin",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    /// Gateways that answer every response with one message ID and no
    /// request ID: ccusage 20.0.24 counted each response in the unified
    /// report but collapsed them in `blocks`, so the 5h block estimate
    /// undercounted. Each response must count once, in both reports.
    func testRequestlessGatewayResponsesCountOnceInReportAndBlocks() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "claude-requestless-gateway.jsonl", withExtension: nil, subdirectory: "Fixtures"
        ))
        try FileManager.default.copyItem(at: fixture, to: project.appendingPathComponent("session.jsonl"))

        let report = try runReport(home: home)
        XCTAssertEqual(report.daily?.first { $0.period == "2026-09-15" }?.totalTokens, 4_500)
        XCTAssertEqual(report.weekly?.reduce(0) { $0 + $1.totalTokens }, 4_500)
        XCTAssertEqual(report.monthly?.first { $0.period == "2026-09" }?.totalTokens, 4_500)
        let blocks = try JSONDecoder().decode(
            CCBlocksReport.self,
            from: runBinary(home: home, arguments: ["blocks", "--json", "--offline", "--since", "20260901"])
        )
        XCTAssertEqual(blocks.blocks?.filter { $0.isGap != true }.reduce(0) { $0 + $1.totalTokens }, 4_500)
    }

    /// Claude Code 2.1.266–2.1.278 wrote `usage.iterations[].model: null`;
    /// ccusage 20.0.19 dropped every such line, silently losing usage.
    func testClaudeLineWithNullIterationModelIsCounted() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "claude-null-iteration-model.jsonl", withExtension: nil, subdirectory: "Fixtures"
        ))
        try FileManager.default.copyItem(at: fixture, to: project.appendingPathComponent("session.jsonl"))

        let report = try runReport(home: home)
        let day = try XCTUnwrap(report.daily?.first { $0.period == "2026-09-15" }, "the line was dropped")
        let claude = try XCTUnwrap(day.agents?.first { $0.agent == "claude" })
        XCTAssertEqual(claude.inputTokens, 1_000)
        XCTAssertEqual(claude.outputTokens, 500)
        XCTAssertGreaterThan(claude.totalCost, 0)
        XCTAssertEqual(report.monthly?.first { $0.period == "2026-09" }?.totalTokens, 1_500)
    }
}
