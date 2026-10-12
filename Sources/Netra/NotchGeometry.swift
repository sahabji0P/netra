import AppKit

/// The shape the island takes in each mode. Activity payloads do not change
/// geometry, so layout only needs the kind.
enum IslandSurface: CaseIterable, Sendable {
    case resting, peek, expanded, activity
}

/// Sizes of the island around the notch. Widths that exceed the screen are
/// clamped, so one set works on every display.
struct IslandSizes: Equatable, Sendable {
    /// Width of each "wing" beside the notch in the resting state (provider
    /// mark + ring on the left, today's cost on the right).
    /// Narrow enough to stay clear of the first status icon on a typical
    /// MacBook menu bar; the content stacks on two lines to fit.
    var wingWidth: CGFloat = 76
    /// Extra width each wing gains while the pointer is over the island.
    var peekWingGrowth: CGFloat = 8
    /// Extra width and height the resting shape grows by on hover.
    var peekGrowth = CGSize(width: 24, height: 6)
    var expanded = CGSize(width: 640, height: 480)
    /// Activity height is measured below the notch, so the notch stays clear.
    var activity = CGSize(width: 380, height: 72)
    /// Space left free at each side of the screen when clamping.
    var screenMargin: CGFloat = 8

    static let standard = IslandSizes()
}

/// The facts about one display that the island needs, in AppKit global
/// coordinates (origin bottom-left, y up). Built from `NSScreen` in the app
/// and from literals in tests.
struct ScreenDescriptor: Equatable, Sendable {
    var frame: CGRect
    /// `safeAreaInsets.top`: the notch height on a notched display, else 0.
    var safeAreaTop: CGFloat
    /// Widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Only the
    /// widths are used, which sidesteps which coordinate space AppKit reports
    /// those rects in.
    var leftAuxiliaryWidth: CGFloat?
    var rightAuxiliaryWidth: CGFloat?
    /// `frame.maxY - visibleFrame.maxY`; 0 when the menu bar auto-hides.
    var menuBarHeight: CGFloat
    var isMain: Bool = false

    var hasNotch: Bool {
        safeAreaTop > 0
            && (leftAuxiliaryWidth ?? 0) > 0
            && (rightAuxiliaryWidth ?? 0) > 0
            && (leftAuxiliaryWidth ?? 0) + (rightAuxiliaryWidth ?? 0) < frame.width
    }
}

extension ScreenDescriptor {
    @MainActor
    init(_ screen: NSScreen, isMain: Bool) {
        self.init(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            isMain: isMain
        )
    }
}

/// Where the notch is on the chosen screen. Without a notch this is a
/// zero-width "virtual notch" centered at the top, so the same layout code
/// produces the pill fallback.
struct NotchLayout: Equatable, Sendable {
    var screenFrame: CGRect
    var notch: CGRect
    var hasNotch: Bool
}

/// Pure geometry for the notch island. Every function is deterministic and
/// unit-tested with synthetic screens.
enum NotchGeometry {
    /// Height used when a screen reports no menu bar (auto-hidden).
    static let fallbackBarHeight: CGFloat = 24

    /// The built-in notched display when present, else the main screen, else
    /// the first one. Returns an index into `screens`.
    static func preferredScreenIndex(_ screens: [ScreenDescriptor]) -> Int? {
        screens.firstIndex(where: \.hasNotch)
            ?? screens.firstIndex(where: \.isMain)
            ?? (screens.isEmpty ? nil : 0)
    }

    static func layout(for screen: ScreenDescriptor) -> NotchLayout {
        let frame = screen.frame
        if screen.hasNotch, let left = screen.leftAuxiliaryWidth, let right = screen.rightAuxiliaryWidth {
            let height = screen.safeAreaTop
            let notch = CGRect(
                x: frame.minX + left,
                y: frame.maxY - height,
                width: frame.width - left - right,
                height: height
            )
            return NotchLayout(screenFrame: frame, notch: notch, hasNotch: true)
        }
        let height = screen.menuBarHeight > 0 ? screen.menuBarHeight : fallbackBarHeight
        let notch = CGRect(x: frame.midX, y: frame.maxY - height, width: 0, height: height)
        return NotchLayout(screenFrame: frame, notch: notch, hasNotch: false)
    }

    /// The island's size in a mode, before clamping to the screen.
    static func islandSize(_ surface: IslandSurface, layout: NotchLayout, sizes: IslandSizes) -> CGSize {
        let resting = CGSize(
            width: layout.notch.width + 2 * sizes.wingWidth,
            height: layout.notch.height
        )
        switch surface {
        case .resting:
            return resting
        case .peek:
            return CGSize(
                width: resting.width + 2 * sizes.peekWingGrowth,
                height: layout.notch.height + sizes.peekGrowth.height
            )
        case .expanded:
            return CGSize(
                width: max(sizes.expanded.width, resting.width),
                height: max(sizes.expanded.height, resting.height)
            )
        case .activity:
            return CGSize(
                width: max(sizes.activity.width, resting.width),
                height: layout.notch.height + sizes.activity.height
            )
        }
    }

    /// The island's frame in global coordinates: top edge on the screen's
    /// top, centered on the notch, clamped inside the screen.
    static func islandFrame(_ surface: IslandSurface, layout: NotchLayout, sizes: IslandSizes) -> CGRect {
        let size = islandSize(surface, layout: layout, sizes: sizes)
        return topCenteredRect(size: size, layout: layout, sizes: sizes)
    }

    /// The panel's frame: one fixed canvas large enough for every mode, so the
    /// window never moves and only the drawn shape morphs.
    static func panelFrame(layout: NotchLayout, sizes: IslandSizes) -> CGRect {
        let union = IslandSurface.allCases.reduce(CGSize.zero) { size, surface in
            let next = islandSize(surface, layout: layout, sizes: sizes)
            return CGSize(width: max(size.width, next.width), height: max(size.height, next.height))
        }
        return topCenteredRect(size: union, layout: layout, sizes: sizes)
    }

    /// Converts a global island frame into the panel content's top-left
    /// coordinate space (SwiftUI's), for placing the shape.
    static func islandRectInPanel(_ island: CGRect, panel: CGRect) -> CGRect {
        CGRect(
            x: island.minX - panel.minX,
            y: panel.maxY - island.maxY,
            width: island.width,
            height: island.height
        )
    }

    private static func topCenteredRect(size: CGSize, layout: NotchLayout, sizes: IslandSizes) -> CGRect {
        let screen = layout.screenFrame
        let maxWidth = max(screen.width - 2 * sizes.screenMargin, 0)
        let width = min(size.width, maxWidth)
        let height = min(size.height, screen.height)
        var minX = layout.notch.midX - width / 2
        // Keep the shape on screen if the notch is off-center or the island
        // is wider than the space on one side.
        minX = min(max(minX, screen.minX + sizes.screenMargin), screen.maxX - sizes.screenMargin - width)
        return CGRect(x: minX, y: screen.maxY - height, width: width, height: height)
    }
}
