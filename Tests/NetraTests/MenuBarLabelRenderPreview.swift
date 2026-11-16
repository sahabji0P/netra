import AppKit
import SwiftUI
import XCTest
@testable import Netra

/// Dev-only visual QA for the menu-bar label: draws a representative set of
/// configurations on light and dark menu-bar backgrounds, at 1x and 2x, with
/// synthetic numbers. Runs only when NETRA_RENDER_DIR is set, e.g.
/// NETRA_RENDER_DIR=/tmp/netra-previews swift test --filter MenuBarLabelRenderPreview
@MainActor
final class MenuBarLabelRenderPreview: XCTestCase {
    func testRenderMenuBarLabels() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render UI previews")
        }
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let snapshot = MenuBarLabelPreview.sampleSnapshot()

        func settings(
            _ icon: MenuBarIconKind, _ items: [MenuBarItem], _ style: MenuBarStyle = .plain,
            _ tint: MenuBarTint = .mono, source: String = "closest", compact: Bool = false
        ) -> MenuBarLabelSettings {
            MenuBarLabelSettings(icon: icon, items: items, style: style, tint: tint, limitSource: source, compact: compact)
        }
        let rows: [(String, MenuBarLabelSettings, Bool)] = [
            ("eye only (iconOnly)", settings(.eye, []), false),
            ("eye awake", settings(.eye, []), true),
            ("today's cost (default)", settings(.eye, [.todayCost]), false),
            ("bars (limitBars)", settings(.bars, [], source: "claude"), false),
            ("bars awake", settings(.bars, [], source: "claude"), true),
            ("ring + limit + reset", settings(.ring, [.limitPercent, .resetCountdown], source: "claude"), false),
            ("session + weekly", settings(.none, [.sessionPercent, .weeklyPercent], source: "claude"), false),
            ("none, awake", settings(.none, [.todayCost], source: "claude"), true),
            ("pill mono", settings(.eye, [.todayCost, .limitPercent], .pill), false),
            ("pill provider", settings(.ring, [.limitPercent], .pill, .provider, source: "claude"), false),
            ("pill status 82%", settings(.none, [.limitPercent, .resetCountdown], .pill, .status), false),
            ("outline mono", settings(.bars, [.todayCost], .outline, source: "claude"), false),
            ("outline provider codex", settings(.eye, [.weeklyPercent], .outline, .provider, source: "codex"), false),
            ("plain status", settings(.ring, [.limitPercent], .plain, .status), false),
            ("compact pill", settings(.eye, [.todayCost, .todayTokens], .pill, compact: true), false),
            ("compact plain", settings(.bars, [.todayCost, .limitPercent], compact: true), false),
        ]

        for scale in [1, 2] {
            for dark in [false, true] {
                let image = sheet(rows.map { title, settings, awake in
                    (title, MenuBarLabelModel.make(settings: settings, snapshot: snapshot, awake: awake))
                }, dark: dark, scale: CGFloat(scale))
                let url = URL(fileURLWithPath: outputDir)
                    .appendingPathComponent("menubar-label-\(dark ? "dark" : "light")@\(scale)x.png")
                try image.write(to: url)
            }
        }
    }

    /// Draws each label on a strip of menu bar, captioned, into a PNG.
    private func sheet(_ rows: [(String, MenuBarLabelModel)], dark: Bool, scale: CGFloat) -> Data {
        let rowHeight: CGFloat = 24, width: CGFloat = 420
        let size = NSSize(width: width, height: rowHeight * CGFloat(rows.count))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let menuBar = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let ink = dark ? NSColor.white : NSColor.black

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            menuBar.setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, (title, model)) in rows.enumerated() {
                // Rows top to bottom in an unflipped context.
                let y = size.height - rowHeight * CGFloat(index + 1)
                let image = MenuBarLabelRenderer.image(model)
                let rect = NSRect(x: 12, y: y + (rowHeight - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height)
                if image.isTemplate {
                    // The menu bar tints template images; do the same.
                    let tinted = NSImage(size: image.size, flipped: false) { bounds in
                        image.draw(in: bounds)
                        ink.setFill()
                        bounds.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: rect)
                } else {
                    image.draw(in: rect)
                }
                (title as NSString).draw(
                    at: NSPoint(x: 200, y: y + 5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink.withAlphaComponent(0.55)]
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

private struct LabelInertScheduler: UsageNotificationScheduling {
    func authorizationState() async -> NotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func schedule(_ candidate: UsageAlertCandidate) async throws {}
}

private actor LabelInertPersistence: UsageAlertStatePersisting {
    func deliveredKeys() -> Set<String> { [] }
    func setDeliveredKeys(_ keys: Set<String>) {}
}
