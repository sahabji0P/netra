import AppKit

/// The shape the island takes in each mode. Activity payloads do not change
/// geometry, so layout only needs the kind.
enum IslandSurface: CaseIterable, Sendable {
    case resting, peek, expanded, activity
}

/// Sizes of the island around the notch. Widths that exceed the screen are
/// clamped, so one set works on every display.
struct IslandSizes: Equatable, Sendable {
    /// Width of the single "wing" on the left of the notch in the resting
    /// state (provider mark and how much of its limit is used). The right of
    /// the notch is left clear for menu-bar items.
    var wingWidth: CGFloat = 76
    /// Extra width the wing gains while the pointer is over the island.
    var peekWingGrowth: CGFloat = 8
    /// Extra height the resting shape grows by on hover.
    var peekGrowth = CGSize(width: 24, height: 6)
    var expanded = CGSize(width: 440, height: 240)
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
    /// The display that holds the menu bar (`NSScreen.screens.first`). Not
    /// `NSScreen.main`, which follows the key window.
    var isPrimary: Bool = false

    var hasNotch: Bool {
        safeAreaTop > 0
            && (leftAuxiliaryWidth ?? 0) > 0
            && (rightAuxiliaryWidth ?? 0) > 0
            && (leftAuxiliaryWidth ?? 0) + (rightAuxiliaryWidth ?? 0) < frame.width
    }
}

extension ScreenDescriptor {
    @MainActor
    init(_ screen: NSScreen, isPrimary: Bool) {
        self.init(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            isPrimary: isPrimary
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

    /// The built-in notched display when present, else the primary screen,
    /// else the first one. Returns an index into `screens`.
    static func preferredScreenIndex(_ screens: [ScreenDescriptor]) -> Int? {
        screens.firstIndex(where: \.hasNotch)
            ?? screens.firstIndex(where: \.isPrimary)
            ?? (screens.isEmpty ? nil : 0)
    }

    /// Whether the island belongs on `screen` at all. Without a notch the pill
    /// sits in the menu bar, so it is hidden while there is no menu bar to sit
    /// in (auto-hidden), rather than covering window title bars.
    static func showsIsland(on screen: ScreenDescriptor) -> Bool {
        screen.hasNotch || screen.menuBarHeight > 0
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
            width: layout.notch.width + sizes.wingWidth,
            height: layout.notch.height
        )
        switch surface {
        case .resting:
            return resting
        case .peek:
            return CGSize(
                width: resting.width + sizes.peekWingGrowth,
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

    /// The island's frame in global coordinates, top edge on the screen's
    /// top and clamped inside the screen. At rest and on hover the shape is
    /// the notch plus its wing on the left, so its right edge is the notch's
    /// right edge; open, or showing an activity, it is centered on the notch.
    static func islandFrame(_ surface: IslandSurface, layout: NotchLayout, sizes: IslandSizes) -> CGRect {
        let size = islandSize(surface, layout: layout, sizes: sizes)
        let leftOnly = layout.hasNotch && (surface == .resting || surface == .peek)
        return topRect(size: size, layout: layout, sizes: sizes, maxX: leftOnly ? layout.notch.maxX : nil)
    }

    /// The panel's frame: one fixed canvas that holds the shape in every
    /// mode, so the window never moves and only the drawn shape morphs.
    static func panelFrame(layout: NotchLayout, sizes: IslandSizes) -> CGRect {
        IslandSurface.allCases
            .map { islandFrame($0, layout: layout, sizes: sizes) }
            .reduce(CGRect.null) { $0.union($1) }
    }

    /// Where the island reacts to the pointer and to clicks. At rest on a
    /// notched screen that is only the notch: the wing may cover a menu-bar
    /// title, and clicks there must still reach it. Once peeking or
    /// open, the whole shape reacts.
    static func hitFrame(_ surface: IslandSurface, layout: NotchLayout, sizes: IslandSizes) -> CGRect {
        if surface == .resting, layout.hasNotch { return layout.notch }
        return islandFrame(surface, layout: layout, sizes: sizes)
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

    /// A rect on the screen's top edge: centered on the notch, or with its
    /// right edge at `maxX` when given. Either way it is kept on screen.
    private static func topRect(
        size: CGSize, layout: NotchLayout, sizes: IslandSizes, maxX: CGFloat? = nil
    ) -> CGRect {
        let screen = layout.screenFrame
        let maxWidth = max(screen.width - 2 * sizes.screenMargin, 0)
        let width = min(size.width, maxWidth)
        let height = min(size.height, screen.height)
        var minX = maxX.map { $0 - width } ?? layout.notch.midX - width / 2
        // Keep the shape on screen if the notch is off-center or the island
        // is wider than the space on one side.
        minX = min(max(minX, screen.minX + sizes.screenMargin), screen.maxX - sizes.screenMargin - width)
        return CGRect(x: minX, y: screen.maxY - height, width: width, height: height)
    }
}
