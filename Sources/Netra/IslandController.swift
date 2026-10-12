import AppKit
import Observation
import SwiftUI

/// What the island is showing right now.
enum IslandMode: Equatable, Sendable {
    /// The small summary beside the notch.
    case resting
    /// The pointer is over the island: the compact content, slightly larger.
    case peek
    /// Clicked, or the hover was held: the full panel.
    case expanded
    /// A live activity shown for a few seconds before returning to rest.
    case activity(IslandActivity)

    var surface: IslandSurface {
        switch self {
        case .resting: .resting
        case .peek: .peek
        case .expanded: .expanded
        case .activity: .activity
        }
    }
}

/// The island's mode rules as a pure state machine; the controller only
/// feeds it events and runs the timers it implies.
///
/// - The pointer always wins: entering the island (even mid-activity) peeks,
///   and leaving collapses.
/// - An activity presented while the user is peeking or expanded waits, and
///   shows after the collapse if its time has not run out. A newer one
///   replaces it; ordering and dedupe belong to the activity queue.
struct IslandModeMachine: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case pointerEntered
        case pointerExited
        case hoverHeld
        case clicked
        case expand
        case collapse
        case present(IslandActivity, until: Date)
        case activityEnded(id: String)
    }

    private(set) var mode: IslandMode = .resting
    private(set) var pending: IslandActivity?
    /// When the shown or pending activity should end.
    private(set) var activityDeadline: Date?

    mutating func handle(_ event: Event, now: Date) {
        switch event {
        case .pointerEntered:
            if case .resting = mode { mode = .peek }
            if case .activity = mode { endActivity(); mode = .peek }
        case .hoverHeld:
            if mode == .peek { mode = .expanded }
        case .clicked, .expand:
            if case .activity = mode { endActivity() }
            mode = .expanded
        case .pointerExited, .collapse:
            switch mode {
            case .peek, .expanded:
                if let pending, let deadline = activityDeadline, deadline > now {
                    mode = .activity(pending)
                    self.pending = nil
                } else {
                    endActivity()
                    mode = .resting
                }
            case .activity where event == .collapse:
                endActivity()
                mode = .resting
            case .resting, .activity:
                break
            }
        case .present(let activity, let until):
            guard until > now else { return }
            switch mode {
            case .resting, .activity:
                mode = .activity(activity)
                pending = nil
            case .peek, .expanded:
                pending = activity
            }
            activityDeadline = until
        case .activityEnded(let id):
            if case .activity(let shown) = mode, shown.id == id {
                endActivity()
                mode = .resting
            } else if pending?.id == id {
                endActivity()
            }
        }
    }

    private mutating func endActivity() {
        pending = nil
        activityDeadline = nil
    }
}

/// Owns the notch island window: picks the screen, follows display changes,
/// tracks the pointer, and morphs between resting, peek, expanded, and
/// activity. Content is supplied as three SwiftUI roots; the shell has no
/// knowledge of usage data.
///
/// The panel is a fixed transparent canvas over the top of the screen. It
/// ignores mouse events except while the pointer is over the island's current
/// shape, so everything around the island stays clickable. Call `hide()`
/// before releasing the controller: it removes the event monitors and the
/// panel, which retains the controller through its content.
@MainActor
@Observable
final class IslandController {
    private(set) var machine = IslandModeMachine()
    private(set) var layout: NotchLayout
    var sizes: IslandSizes {
        didSet { if sizes != oldValue { relayout() } }
    }
    private(set) var isVisible = false

    /// How long the pointer rests on the island before peek becomes expanded.
    @ObservationIgnored var hoverHoldDelay: Duration = .milliseconds(650)
    /// Grace after the pointer leaves, so brushing the edge does not collapse.
    @ObservationIgnored var leaveGrace: Duration = .milliseconds(220)
    @ObservationIgnored var defaultActivityDuration: Duration = .seconds(4)

    @ObservationIgnored let compactContent: () -> AnyView
    @ObservationIgnored let expandedContent: () -> AnyView
    @ObservationIgnored let activityContent: (IslandActivity) -> AnyView

    @ObservationIgnored private var panel: IslandPanel?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var pointerInside = false
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?

    init<Compact: View, Expanded: View, Activity: View>(
        sizes: IslandSizes = .standard,
        @ViewBuilder compact: @escaping () -> Compact,
        @ViewBuilder expanded: @escaping () -> Expanded,
        @ViewBuilder activity: @escaping (IslandActivity) -> Activity
    ) {
        self.sizes = sizes
        self.compactContent = { AnyView(compact()) }
        self.expandedContent = { AnyView(expanded()) }
        self.activityContent = { AnyView(activity($0)) }
        self.layout = Self.currentScreen().map(NotchGeometry.layout(for:))
            ?? NotchGeometry.layout(for: ScreenDescriptor(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                safeAreaTop: 0, menuBarHeight: NotchGeometry.fallbackBarHeight
            ))
    }

    var mode: IslandMode { machine.mode }

    var metrics: IslandMetrics {
        IslandMetrics(
            notchWidth: layout.notch.width,
            notchHeight: layout.notch.height,
            hasNotch: layout.hasNotch,
            surface: mode.surface
        )
    }

    /// The island's current frame in global screen coordinates.
    var islandFrame: CGRect {
        NotchGeometry.islandFrame(mode.surface, layout: layout, sizes: sizes)
    }

    var panelFrame: CGRect {
        NotchGeometry.panelFrame(layout: layout, sizes: sizes)
    }

    var islandRectInPanel: CGRect {
        NotchGeometry.islandRectInPanel(islandFrame, panel: panelFrame)
    }

    // MARK: Public controls

    func show() {
        guard !isVisible else { return }
        isVisible = true
        let panel = makePanel()
        self.panel = panel
        relayout()
        installMonitors()
        panel.orderFrontRegardless()
        updatePointer()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        hoverTask?.cancel()
        leaveTask?.cancel()
        activityTask?.cancel()
        pointerInside = false
        machine = IslandModeMachine()
        panel?.orderOut(nil)
        // The hosting view holds the controller; dropping the panel breaks
        // that cycle. `show()` builds a fresh one.
        panel?.contentView = nil
        panel = nil
    }

    /// Grows the island to show `activity`, then returns to rest. While the
    /// user is peeking or expanded it waits for the collapse instead.
    func present(_ activity: IslandActivity, for duration: Duration? = nil) {
        let length = duration ?? defaultActivityDuration
        let until = Date.now.addingTimeInterval(length.timeInterval)
        send(.present(activity, until: until))
    }

    func expand() { send(.expand) }
    func collapse() { send(.collapse) }

    // MARK: Events

    /// Feeds one event to the mode machine with the shared morph. Internal so
    /// previews and tests can drive modes the pointer would normally reach.
    func send(_ event: IslandModeMachine.Event) {
        let before = machine
        withAnimation(IslandTheme.morph) {
            machine.handle(event, now: .now)
        }
        guard machine != before else { return }
        scheduleActivityEnd()
        if machine.mode.surface != before.mode.surface { updatePointer() }
    }

    private func scheduleActivityEnd() {
        activityTask?.cancel()
        guard case .activity(let activity) = machine.mode, let deadline = machine.activityDeadline else {
            return
        }
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            self?.send(.activityEnded(id: activity.id))
        }
    }

    /// Hit-tests the pointer against the island's current shape and turns
    /// mouse handling on only while it is inside.
    private func updatePointer() {
        guard isVisible, let panel else { return }
        let inside = islandFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            leaveTask?.cancel()
            send(.pointerEntered)
            hoverTask?.cancel()
            hoverTask = Task { [weak self, hoverHoldDelay] in
                try? await Task.sleep(for: hoverHoldDelay)
                guard !Task.isCancelled else { return }
                self?.send(.hoverHeld)
            }
        } else {
            hoverTask?.cancel()
            leaveTask?.cancel()
            leaveTask = Task { [weak self, leaveGrace] in
                try? await Task.sleep(for: leaveGrace)
                guard !Task.isCancelled else { return }
                self?.send(.pointerExited)
            }
        }
    }

    // MARK: Window and screens

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel()
        let host = IslandHostingView(rootView: IslandRootView(controller: self))
        host.onPointerMoved = { [weak self] in self?.updatePointer() }
        panel.contentView = host
        return panel
    }

    private func relayout() {
        if let screen = Self.currentScreen() {
            layout = NotchGeometry.layout(for: screen)
        }
        panel?.setFrame(panelFrame, display: isVisible)
        updatePointer()
    }

    private static func currentScreen() -> ScreenDescriptor? {
        let main = NSScreen.main
        let screens = NSScreen.screens.map { ScreenDescriptor($0, isMain: $0 == main) }
        return NotchGeometry.preferredScreenIndex(screens).map { screens[$0] }
    }

    private func installMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Fires while another app is frontmost, which is nearly always.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moved.union(.leftMouseDown), handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown {
                    if event.window === self.panel, self.mode != .expanded { self.send(.clicked) }
                } else {
                    self.updatePointer()
                }
            }
            return event
        }) {
            monitors.append(local)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

#if DEBUG
extension IslandController {
    /// Dev-only shell with placeholder content, for seeing the window layer
    /// without data wiring. Not used by the app; see `IslandShellLiveProbe`.
    static func placeholder() -> IslandController {
        IslandController {
            IslandPlaceholderCompact()
        } expanded: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Expanded island").font(.headline)
                ForEach(["Claude Code", "Codex", "Cursor"], id: \.self) { name in
                    RoundedRectangle(cornerRadius: IslandTheme.cardRadius, style: .continuous)
                        .fill(IslandTheme.card)
                        .frame(height: 96)
                        .overlay(alignment: .leading) {
                            Text(name).padding(.horizontal, 16)
                        }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 40)
        } activity: { activity in
            HStack {
                Circle().fill(IslandTheme.warning).frame(width: 10, height: 10)
                Text(activity.id).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 22)
        }
    }
}

private struct IslandPlaceholderCompact: View {
    @Environment(\.islandMetrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(IslandTheme.fresh).frame(width: 12, height: 12)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: metrics.notchWidth)
            Text("$4.20").font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(height: metrics.notchHeight)
    }
}
#endif
