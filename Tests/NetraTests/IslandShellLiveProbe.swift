import AppKit
import SwiftUI
import XCTest
@testable import Netra

/// Dev-only look at the notch island shell with placeholder content.
///
/// NETRA_RENDER_DIR=/tmp/netra-island swift test --filter IslandShellLiveProbe
///   writes one PNG per mode (island over a grey "menu bar" backdrop).
/// NETRA_ISLAND_LIVE=1 swift test --filter IslandShellLiveProbe
///   shows the real panel on screen for NETRA_ISLAND_SECONDS (default 30):
///   hover, click, and move the pointer away to try the modes; an activity is
///   presented after 3 seconds.
@MainActor
final class IslandShellLiveProbe: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    func testRenderModes() throws {
        guard let outputDir = environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render the island shell")
        }
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = IslandController.placeholder()
        let activity = IslandActivity(id: "hot:claude:5h", agent: "claude", kind: .windowReset(title: "Claude Code"))
        let steps: [(String, IslandModeMachine.Event)] = [
            ("resting", .collapse),
            ("peek", .pointerEntered),
            ("expanded", .expand),
            ("activity", .present(activity, until: .distantFuture)),
        ]
        for (name, event) in steps {
            controller.send(.collapse)
            controller.send(event)
            let size = controller.panelFrame.size
            let view = NSHostingView(rootView:
                IslandRootView(controller: controller)
                    .frame(width: size.width, height: size.height)
                    .background(alignment: .top) {
                        Color(white: 0.5).frame(height: controller.layout.notch.height)
                    }
                    .background(Color(white: 0.85))
            )
            view.frame = CGRect(origin: .zero, size: size)
            pump(seconds: 0.8)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent("island-\(name).png"))
        }
    }

    func testShowLivePanel() throws {
        guard environment["NETRA_ISLAND_LIVE"] != nil else {
            throw XCTSkip("set NETRA_ISLAND_LIVE=1 to show the island shell on screen")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = IslandController.placeholder()
        controller.show()
        defer { controller.hide() }
        print("island layout: \(controller.layout) panel: \(controller.panelFrame)")
        pump(seconds: 3)
        controller.present(IslandActivity(
            id: "reset:codex:5h", agent: "codex", kind: .windowReset(title: "Codex is fresh again")
        ))
        pump(seconds: TimeInterval(environment["NETRA_ISLAND_SECONDS"] ?? "") ?? 30)
    }

    /// Runs the AppKit event loop, which xctest does not do on its own.
    private func pump(seconds: TimeInterval) {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date.now.addingTimeInterval(0.05), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
    }
}
