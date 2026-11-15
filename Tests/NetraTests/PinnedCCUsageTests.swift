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

    /// ccusage prices Hermes sessions billed through OpenAI under
    /// `openai/<model>` through a fuzzy lookup (20.0.26 resolved it to
    /// OpenRouter's batch rate). The override Netra writes for that exact
    /// key must pin list price
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

    /// Codex compresses rollouts older than a few days to `.jsonl.zst`, in
    /// `sessions/` and `archived_sessions/` alike. ccusage 20.0.32 skipped
    /// them, hiding almost all Codex history; they must count like plain ones.
    func testCompressedCodexRolloutsAreCounted() throws {
        let home = try codexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let report = try runReport(home: home)
        let codex = Dictionary(uniqueKeysWithValues: (report.daily ?? []).compactMap { row in
            row.agents?.first { $0.agent == "codex" }.map { (row.period, $0.totalTokens) }
        })
        XCTAssertEqual(codex, ["2026-09-10": 3_500, "2026-09-12": 3_500])
    }

    /// A refresh reads only the trailing days and records them as complete.
    /// That holds only if a `--since` report gives each day inside the window
    /// exactly what a report over everything gives it.
    func testWindowedReportMatchesTheCompleteReportForItsDays() throws {
        let home = try codexHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let arguments = ["daily", "--sections", "daily,weekly,monthly", "--by-agent", "--json", "--offline"]
        let complete = try JSONDecoder().decode(
            CCUnifiedReport.self, from: runBinary(home: home, arguments: arguments)
        )
        let windowed = try JSONDecoder().decode(
            CCUnifiedReport.self, from: runBinary(home: home, arguments: arguments + ["--since", "20260912"])
        )
        XCTAssertEqual(complete.daily?.map(\.period), ["2026-09-10", "2026-09-12"])
        XCTAssertEqual(windowed.daily?.map(\.period), ["2026-09-12"])
        let whole = try XCTUnwrap(complete.daily?.last), recent = try XCTUnwrap(windowed.daily?.last)
        XCTAssertEqual(recent.totalTokens, whole.totalTokens)
        XCTAssertEqual(recent.totalCost, whole.totalCost, accuracy: 0.000_001)
        XCTAssertEqual(recent.agents?.map(\.agent), whole.agents?.map(\.agent))
    }

    /// Codex files a rollout under the day its session started. A session
    /// started before the window and continued inside it must still be read
    /// by a windowed report, or usage in long-lived sessions would lag until
    /// the next complete scan.
    func testWindowedReportCountsASessionStartedBeforeTheWindow() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent(
            "rollout-2026-09-05T10-00-00-00000000-0000-7000-8000-000000000009.jsonl"
        )
        try FileManager.default.copyItem(
            at: XCTUnwrap(Bundle.module.url(
                forResource: "codex-rollout-resumed.jsonl", withExtension: nil, subdirectory: "Fixtures"
            )),
            to: rollout
        )
        // Last written when its final turn ran, as a real rollout would be.
        try FileManager.default.setAttributes(
            [.modificationDate: XCTUnwrap(ISODate.parse("2026-09-12T09:00:05Z"))], ofItemAtPath: rollout.path
        )

        let windowed = try JSONDecoder().decode(CCUnifiedReport.self, from: runBinary(home: home, arguments: [
            "daily", "--sections", "daily,weekly,monthly", "--by-agent", "--json", "--offline",
            "--timezone", "UTC", "--since", "20260912",
        ]))
        XCTAssertEqual(windowed.daily?.map(\.period), ["2026-09-12"])
        XCTAssertEqual(windowed.daily?.first?.agents?.first { $0.agent == "codex" }?.totalTokens, 700)
    }

    /// A Codex home with one compressed rollout (Sept 10) and one plain (Sept 12).
    private func codexHome() throws -> URL {
        let home = try temporaryHome()
        for (fixture, day) in [("codex-rollout-compressed.jsonl.zst", "10"), ("codex-rollout-plain.jsonl", "12")] {
            let directory = home.appendingPathComponent(".codex/sessions/2026/09/\(day)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = try XCTUnwrap(Bundle.module.url(
                forResource: fixture, withExtension: nil, subdirectory: "Fixtures"
            ))
            let suffix = fixture.hasSuffix(".zst") ? "jsonl.zst" : "jsonl"
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(
                "rollout-2026-09-\(day)T10-00-00-00000000-0000-7000-8000-0000000000\(day).\(suffix)"
            ))
        }
        return home
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
    /// undercounted. Each response must count once, in both reports. The
    /// placeholder ID has no `msg_` prefix: since 20.0.28 ccusage treats
    /// `msg_` IDs as real Anthropic IDs (see the content-block test below).
    func testRequestlessGatewayResponsesCountOnceInReportAndBlocks() throws {
        try assertClaudeFixture("claude-requestless-gateway.jsonl", day: "2026-09-15", countsTokens: 4_500)
    }

    /// Proxies that drop the request ID still get one line per content block
    /// (thinking, text, tool_use) with the same Anthropic `msg_` ID, usage,
    /// and session but distinct timestamps. ccusage 20.0.26 counted every
    /// line, inflating Claude totals 2–3×; the response must count once.
    func testRequestlessContentBlockLinesCountOnceInReportAndBlocks() throws {
        try assertClaudeFixture("claude-requestless-content-blocks.jsonl", day: "2026-09-16", countsTokens: 1_500)
    }

    private func assertClaudeFixture(
        _ name: String, day: String, countsTokens tokens: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures"
        ))
        try FileManager.default.copyItem(at: fixture, to: project.appendingPathComponent("session.jsonl"))

        let report = try runReport(home: home)
        XCTAssertEqual(report.daily?.first { $0.period == day }?.totalTokens, tokens, file: file, line: line)
        XCTAssertEqual(report.weekly?.reduce(0) { $0 + $1.totalTokens }, tokens, file: file, line: line)
        XCTAssertEqual(report.monthly?.first { $0.period == "2026-09" }?.totalTokens, tokens, file: file, line: line)
        let blocks = try JSONDecoder().decode(
            CCBlocksReport.self,
            from: runBinary(home: home, arguments: ["blocks", "--json", "--offline", "--since", "20260901"])
        )
        XCTAssertEqual(
            blocks.blocks?.filter { $0.isGap != true }.reduce(0) { $0 + $1.totalTokens }, tokens,
            file: file, line: line
        )
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
