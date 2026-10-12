import AppKit
import SwiftUI

/// The borderless, non-activating window behind the notch island. It never
/// becomes key or main, so showing it or clicking it never takes focus from
/// the app being used. The window is a fixed transparent canvas; the black
/// island is drawn inside it by `IslandRootView`.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Outside the island shape clicks must reach whatever is below; the
        // controller turns this off only while the pointer is over the shape.
        ignoresMouseEvents = true
        // Above the menu bar so the island can cover the notch row.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would push a window below the menu bar; the island belongs in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosts the SwiftUI island and reports pointer movement over the panel.
/// The first click acts immediately even though the panel is never key.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onPointerMoved: (@MainActor () -> Void)?
    private var tracking: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The panel's frame is owned by the controller, never by content size.
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved?()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerMoved?()
    }
}

/// What island content may want to know about the shell, e.g. the compact
/// view leaves `notchWidth` empty in its middle on a notched display.
struct IslandMetrics: Equatable, Sendable {
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = NotchGeometry.fallbackBarHeight
    var hasNotch = false
    var surface: IslandSurface = .resting
}

private struct IslandMetricsKey: EnvironmentKey {
    static let defaultValue = IslandMetrics()
}

extension EnvironmentValues {
    var islandMetrics: IslandMetrics {
        get { self[IslandMetricsKey.self] }
        set { self[IslandMetricsKey.self] = newValue }
    }
}

/// Black island shape with the content for the current mode, placed inside
/// the fixed panel canvas. Only the shape's frame animates.
struct IslandRootView: View {
    let controller: IslandController

    var body: some View {
        let surface = controller.mode.surface
        let rect = controller.islandRectInPanel
        let radius = Self.bottomRadius(surface)
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            style: .continuous
        )
        ZStack(alignment: .top) {
            content(for: controller.mode)
                .id(contentKey(controller.mode))
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        }
        .frame(width: rect.width, height: rect.height, alignment: .top)
        .background(IslandTheme.background)
        .clipShape(shape)
        .contentShape(shape)
        .environment(\.islandMetrics, controller.metrics)
        .environment(\.colorScheme, .dark)
        .offset(x: rect.minX, y: rect.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(IslandTheme.morph, value: rect)
        .animation(IslandTheme.morph, value: contentKey(controller.mode))
    }

    @ViewBuilder
    private func content(for mode: IslandMode) -> some View {
        switch mode {
        case .resting, .peek:
            controller.compactContent()
        case .expanded:
            controller.expandedContent()
        case .activity(let activity):
            controller.activityContent(activity)
        }
    }

    /// Resting and peek share the compact root, so hovering only grows it.
    private func contentKey(_ mode: IslandMode) -> String {
        switch mode {
        case .resting, .peek: "compact"
        case .expanded: "expanded"
        case .activity(let activity): "activity:\(activity.id)"
        }
    }

    static func bottomRadius(_ surface: IslandSurface) -> CGFloat {
        switch surface {
        case .resting, .peek: IslandTheme.compactBottomRadius
        case .activity: IslandTheme.cardRadius
        case .expanded: IslandTheme.expandedBottomRadius
        }
    }
}
