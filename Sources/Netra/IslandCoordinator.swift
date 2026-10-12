import AppKit
import Observation
import SwiftUI

/// Wires the notch island into the app: builds the controller with the real
/// content views, feeds it live activities, and follows the user's
/// preference. The menu-bar icon is unaffected.
@MainActor
final class IslandCoordinator {
    private let store: UsageStore
    private let preferences: AppPreferences
    private let accounts: AccountStore
    private let awake: AwakeController
    private let dashboardNavigation: DashboardNavigation
    private let queue = IslandActivityQueue()
    private var watcher = IslandLimitWatcher()
    private var controller: IslandController?
    private var lastAwakeMode: AwakeController.Mode
    /// Set from a SwiftUI scene, since the island's panel has no scene of its
    /// own to open windows from.
    var openWindow: OpenWindowAction?

    init(
        store: UsageStore,
        preferences: AppPreferences,
        accounts: AccountStore,
        awake: AwakeController,
        dashboardNavigation: DashboardNavigation
    ) {
        self.store = store
        self.preferences = preferences
        self.accounts = accounts
        self.awake = awake
        self.dashboardNavigation = dashboardNavigation
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
        queue.enqueue(.windowReset(from: celebration))
    }

    func accountSwitched(_ provider: AccountProvider) {
        if let activity = IslandActivity.accountSwitched(provider: provider, in: accounts) {
            queue.enqueue(activity)
        }
    }

    // MARK: Island lifetime

    private func applyPreference() {
        if preferences.notchIslandEnabled {
            if controller == nil { controller = makeController() }
            controller?.show()
        } else {
            controller?.hide()
            controller = nil
            queue.clear()
        }
    }

    private func makeController() -> IslandController {
        let store = store, preferences = preferences, accounts = accounts, awake = awake
        let controller = IslandController {
            IslandCompactHost(store: store, preferences: preferences, awake: awake)
        } expanded: { [weak self] in
            IslandExpandedHost(
                content: IslandExpandedView(
                    store: store,
                    preferences: preferences,
                    accounts: accounts,
                    awake: awake,
                    openDashboard: { self?.openDashboard($0) }
                ),
                onHeight: { self?.expandedContentHeight($0) }
            )
        } activity: { activity in
            IslandActivityView(activity: activity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        return controller
    }

    /// Sizes the expanded island to its content, capped so it never runs off
    /// a short screen; taller content scrolls.
    private func expandedContentHeight(_ height: CGFloat) {
        guard let controller else { return }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let target = min(height, screenHeight * 0.85).rounded(.up)
        var sizes = controller.sizes
        guard abs(sizes.expanded.height - target) > 1 else { return }
        sizes.expanded.height = target
        controller.sizes = sizes
    }

    private func openDashboard(_ section: DashboardSection) {
        dashboardNavigation.selection = section
        controller?.collapse()
        openWindow?(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
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
        guard let snapshot, controller != nil else { return }
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
        if controller != nil, let activity = IslandActivity.keepAwake(from: lastAwakeMode, to: mode) {
            queue.enqueue(activity)
        }
    }

    private func trackQueue() {
        let current = withObservationTracking {
            queue.current
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackQueue() }
        }
        if let current, let controller {
            controller.present(current, for: queue.duration(for: current))
        }
    }
}

/// The resting view with the real notch width as its center gap.
private struct IslandCompactHost: View {
    var store: UsageStore
    var preferences: AppPreferences
    var awake: AwakeController
    @Environment(\.islandMetrics) private var metrics

    var body: some View {
        IslandCompactView(
            store: store, preferences: preferences, awake: awake,
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
