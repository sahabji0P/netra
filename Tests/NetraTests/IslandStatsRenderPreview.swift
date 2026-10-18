import AppKit
import SwiftUI
import XCTest
@testable import Netra

/// Dev-only visual QA for the island stats strip, on synthetic usage only.
/// Runs only when NETRA_RENDER_DIR is set, e.g.
/// NETRA_RENDER_DIR=/tmp/netra-previews swift test --filter IslandStatsRenderPreview
@MainActor
final class IslandStatsRenderPreview: XCTestCase {
    typealias F = IslandStatsFixtures

    func testRenderIslandStats() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render UI previews")
        }
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let suiteName = "NetraTests.IslandStatsRender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        let busy = F.snapshot(Self.busyMonth(), block: F.block(
            startedMinutesAgo: 134, cost: 7.42, projected: 16.10, tokens: 18_400_000
        ))
        render(busy, preferences, name: "island-stats", outputDir: outputDir)
        render(F.snapshot(Self.busyMonth()), preferences, name: "island-stats-no-block", outputDir: outputDir)
        render(F.snapshot([]), preferences, name: "island-stats-empty", outputDir: outputDir)
        render(busy, preferences, range: .quarter, name: "island-stats-90d", outputDir: outputDir)
        render(busy, preferences, range: .month, selectedDay: F.day(3, []).period,
               name: "island-stats-selected-day", outputDir: outputDir)
        render(
            F.snapshot([F.day(0, [F.agent("claude", cost: 3.2, input: 40_000, output: 22_000, cacheWrite: 90_000,
                                          cacheRead: 1_100_000, models: [("claude-sonnet-4-5-20250929", 3.2)])])]),
            preferences, name: "island-stats-single-day", outputDir: outputDir
        )
    }

    /// A plausible month: Claude most days, Codex bursts, some Cursor, idle weekends.
    static func busyMonth() -> [PeriodRow] {
        (0..<30).compactMap { daysAgo -> PeriodRow? in
            if [5, 6, 12, 13, 20, 26, 27].contains(daysAgo) { return nil }
            let wave = 0.5 + 0.5 * sin(Double(daysAgo) * 0.9)
            let claude = 4 + 22 * wave + (daysAgo == 0 ? 9 : 0)
            let codex = daysAgo % 4 == 1 ? 30 * (1 - wave) + 6 : 2 * wave
            let cursor = daysAgo % 7 == 3 ? 5.5 : 0
            var agents = [
                F.agent("claude", cost: claude, input: Int(claude * 9_000), output: Int(claude * 4_000),
                        cacheWrite: Int(claude * 30_000), cacheRead: Int(claude * 420_000),
                        models: [("claude-opus-4-1-20250805", claude * 0.62), ("claude-sonnet-4-5-20250929", claude * 0.3),
                                 ("claude-haiku-4-5-20251001", claude * 0.08)]),
                F.agent("codex", cost: codex, input: Int(codex * 20_000), output: Int(codex * 5_000),
                        cacheRead: Int(codex * 160_000),
                        models: [("gpt-5-codex", codex * 0.8), ("gpt-5", codex * 0.2)]),
            ]
            if cursor > 0 {
                agents.append(F.agent("cursor", cost: cursor, input: 60_000, output: 12_000, cacheRead: 300_000,
                                      models: [("default", cursor)]))
            }
            return F.day(daysAgo, agents.filter { $0.cost > 0 })
        }
    }

    private func render(
        _ snapshot: UsageSnapshot, _ preferences: AppPreferences,
        range: IslandStatsRange = .week, selectedDay: String? = nil, name: String, outputDir: String
    ) {
        let view = IslandStatsStrip(
            snapshot: snapshot, preferences: preferences, now: F.now, calendar: F.calendar,
            range: range, selectedDay: selectedDay
        )
            .padding(16)
            .frame(width: 620)
            .background(IslandTheme.background)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = hosting.appearance
            window.contentView = hosting
            window.layoutIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
