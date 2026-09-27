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

    /// Claude Code 2.1.266–2.1.278 wrote `usage.iterations[].model: null`;
    /// ccusage 20.0.19 dropped every such line, silently losing usage.
    func testClaudeLineWithNullIterationModelIsCounted() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("netra-ccusage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/-synthetic", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "claude-null-iteration-model.jsonl", withExtension: nil, subdirectory: "Fixtures"
        ))
        try FileManager.default.copyItem(at: fixture, to: project.appendingPathComponent("session.jsonl"))

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "daily", "--sections", "daily,weekly,monthly", "--by-agent",
            "--json", "--offline", "--since", "20260901", "--until", "20260930",
        ]
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

        let report = try JSONDecoder().decode(CCUnifiedReport.self, from: data)
        let day = try XCTUnwrap(report.daily?.first { $0.period == "2026-09-15" }, "the line was dropped")
        let claude = try XCTUnwrap(day.agents?.first { $0.agent == "claude" })
        XCTAssertEqual(claude.inputTokens, 1_000)
        XCTAssertEqual(claude.outputTokens, 500)
        XCTAssertGreaterThan(claude.totalCost, 0)
        XCTAssertEqual(report.monthly?.first { $0.period == "2026-09" }?.totalTokens, 1_500)
    }
}
