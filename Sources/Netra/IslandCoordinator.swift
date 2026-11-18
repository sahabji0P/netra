import AppKit
import Observation
import SwiftUI

/// Wires the notch island into the app: keeps one island on every connected
/// display (the notch on a notched one, a pill in the menu bar elsewhere),
/// builds each with the real content views, feeds them live activities, and
/// follows the user's preference. The menu-bar icon is unaffected.
@MainActor
final class IslandCoordinator {
    private let store: UsageStore
    private let preferences: AppPreferences
    private let accounts: AccountStore
    private let awake: AwakeController
    private let queue = IslandActivityQueue()
    private var watcher = IslandLimitWatcher()
    /// One island per connected display while the island is enabled.
    private var controllers: [CGDirectDisplayID: IslandController] = [:]
    private var isEnabled = false
    private var screenObserver: NSObjectProtocol?
    private var lastAwakeMode: AwakeController.Mode

    init(
        store: UsageStore,
        preferences: AppPreferences,
        accounts: AccountStore,
        awake: AwakeController
    ) {
        self.store = store
        self.preferences = preferences
        self.accounts = accounts
        self.awake = awake
        self.lastAwakeMode = awake.mode
    }

    /// Call once the app has finished launching.
    func start() {
        applyPreference()
        trackPreference()
        trackSnapshot()
        trackKeepAwake()
        trackQueue()
    }

    // MARK: Events from existing hooks

    func resetDetected(_ celebration: ResetCelebration) {
        guard isEnabled else { return }
        queue.enqueue(.windowReset(from: celebration))
    }

    func accountSwitched(_ provider: AccountProvider) {
        if isEnabled, let activity = IslandActivity.accountSwitched(provider: provider, in: accounts) {
            queue.enqueue(activity)
        }
    }

    // MARK: Island lifetime

    private func applyPreference() {
        isEnabled = preferences.notchIslandEnabled
        if isEnabled {
            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcileScreens() }
                }
            }
            reconcileScreens()
        } else {
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            controllers.values.forEach { $0.hide() }
            controllers = [:]
            queue.clear()
            // Re-enabling starts comparing afresh, so nothing that changed
            // while the island was off is announced late.
            watcher = IslandLimitWatcher()
        }
    }

    /// Gives every connected display its island and removes the islands of
    /// displays that are gone. Each controller hides itself while its own
    /// display has no place for it (no notch and no menu bar).
    private func reconcileScreens() {
        guard isEnabled else { return }
        let connected = Set(NSScreen.screens.compactMap(\.displayID))
        for id in controllers.keys where !connected.contains(id) {
            controllers.removeValue(forKey: id)?.hide()
        }
        for id in connected where controllers[id] == nil {
            let controller = makeController(displayID: id)
            controllers[id] = controller
            controller.show()
        }
    }

    private func makeController(displayID: CGDirectDisplayID) -> IslandController {
        let store = store, preferences = preferences, accounts = accounts
        let controller = IslandController(displayID: displayID) {
            IslandCompactHost(store: store, preferences: preferences)
        } expanded: { [weak self] in
            IslandExpandedHost(
                content: IslandExpandedView(
                    store: store,
                    preferences: preferences,
                    accounts: accounts,
                    openDashboard: { self?.openDashboard($0) }
                ),
                onHeight: { self?.expandedContentHeight($0, displayID: displayID) }
            )
        } activity: { activity in
            IslandActivityView(activity: activity, showRemaining: preferences.barsShowRemaining)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        controller.sizes.expanded.width = IslandExpandedContent.width
        controller.onActivityDismissed = { [weak self] id in
            guard let self else { return }
            // Dismissed on one display, it goes from the others too.
            for (other, controller) in controllers where other != displayID {
                controller.endActivity(id: id)
            }
            if queue.current?.id == id { queue.dismissCurrent() }
        }
        return controller
    }

    /// Sizes the expanded island to its content, capped so it never runs off
    /// a short screen; taller content scrolls.
    private func expandedContentHeight(_ height: CGFloat, displayID: CGDirectDisplayID) {
        guard let controller = controllers[displayID] else { return }
        // The island's own screen, below its menu bar or notch.
        let screenHeight = controller.layout.screenFrame.height - controller.layout.notch.height
        let target = min(height, screenHeight * 0.85).rounded(.up)
        var sizes = controller.sizes
        guard abs(sizes.expanded.height - target) > 1 else { return }
        sizes.expanded.height = target
        controller.sizes = sizes
    }

    private func openDashboard(_ section: DashboardSection) {
        controllers.values.forEach { $0.collapse() }
        DashboardLauncher.shared.open(section)
    }

    // MARK: Observation

    private func trackPreference() {
        withObservationTracking {
            _ = preferences.notchIslandEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyPreference()
                self?.trackPreference()
            }
        }
    }

    /// Compares each fresh snapshot with the one before it. The first one
    /// only seeds, so nothing fires for state that predates launch.
    private func trackSnapshot() {
        let snapshot = withObservationTracking {
            store.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackSnapshot() }
        }
        guard let snapshot, isEnabled else { return }
        let activities = watcher.observe(
            snapshot,
            threshold: preferences.providerLimitAlertThreshold,
            order: preferences.orderedLimitProviders,
            isVisible: preferences.isProviderVisibleInMenu
        )
        queue.enqueue(activities)
    }

    private func trackKeepAwake() {
        let mode = withObservationTracking {
            awake.mode
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackKeepAwake() }
        }
        defer { lastAwakeMode = mode }
        if isEnabled, let activity = IslandActivity.keepAwake(from: lastAwakeMode, to: mode) {
            queue.enqueue(activity)
        }
    }

    private func trackQueue() {
        let current = withObservationTracking {
            queue.current
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackQueue() }
        }
        if let current {
            let duration = queue.duration(for: current)
            controllers.values.forEach { $0.present(current, for: duration) }
        }
    }
}

/// The resting view with the real notch width as its center gap.
private struct IslandCompactHost: View {
    var store: UsageStore
    var preferences: AppPreferences
    @Environment(\.islandMetrics) private var metrics

    var body: some View {
        IslandCompactView(
            store: store, preferences: preferences,
            notchGap: metrics.hasNotch ? metrics.notchWidth : 16
        )
    }
}

/// Keeps the expanded content clear of the notch, scrolls when it is taller
/// than the island allows, and reports its natural height.
private struct IslandExpandedHost<Content: View>: View {
    var content: Content
    var onHeight: (CGFloat) -> Void
    @Environment(\.islandMetrics) private var metrics

    private var topInset: CGFloat { max(metrics.notchHeight, 24) + 4 }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: IslandContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .padding(.top, topInset)
        .onPreferenceChange(IslandContentHeightKey.self) { height in
            onHeight(height + topInset)
        }
    }
}

private struct IslandContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
