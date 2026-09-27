import Foundation
import Observation
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case limitBars
    case todayCost
    case todayTokens
    case highestProviderLimit

    var id: Self { self }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .limitBars: "Limit bars"
        case .todayCost: "Today's cost"
        case .todayTokens: "Today's tokens"
        case .highestProviderLimit: "Highest usage indicator"
        }
    }

    var detail: String {
        switch self {
        case .iconOnly: "Keep the menu bar minimal"
        case .limitBars: "Short-window and weekly bars for the provider closest to its limit"
        case .todayCost: "Estimated API-equivalent cost"
        case .todayTokens: "Tokens processed today"
        case .highestProviderLimit: "Percent used of the provider closest to its limit"
        }
    }
}

/// How limit reset times read in the popover.
enum ResetTimeStyle: String, CaseIterable, Identifiable, Sendable {
    case countdown
    case clock

    var id: Self { self }

    var title: String {
        switch self {
        case .countdown: "Countdown (in 2d 4h)"
        case .clock: "Date and time (Mon 3:19 PM)"
        }
    }
}

/// User-controlled presentation and alert settings. Values are written as soon
/// as they change so the menu extra and dashboard always share one source of
/// truth, including after relaunching Netra.
@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let menuBarDisplayMode = "preferences.menuBarDisplayMode"
        static let showsLimits = "preferences.popover.showsLimits"
        static let showsProviderBreakdown = "preferences.popover.showsProviderBreakdown"
        static let showsActivityChart = "preferences.popover.showsActivityChart"
        static let showsKeepAwake = "preferences.popover.showsKeepAwake"
        static let hiddenMenuProviders = "preferences.popover.hiddenProviders"
        static let barsShowRemaining = "preferences.popover.barsShowRemaining"
        static let resetTimeStyle = "preferences.popover.resetTimeStyle"
        static let showsPace = "preferences.popover.showsPace"
        static let limitProviderOrder = "preferences.popover.limitProviderOrder"
        static let defaultPeriod = "preferences.popover.defaultPeriod"
        static let claudeQuotaEnabled = "preferences.limits.claudeQuotaEnabled"
        static let cursorUsageEnabled = "preferences.limits.cursorUsageEnabled"
        static let confettiOnReset = "preferences.celebrate.confettiOnReset"
        static let dailyTokenAlertEnabled = "preferences.alerts.dailyTokens.enabled"
        static let dailyTokenAlertThreshold = "preferences.alerts.dailyTokens.threshold"
        static let providerLimitAlertEnabled = "preferences.alerts.providerLimit.enabled"
        static let providerLimitAlertThreshold = "preferences.alerts.providerLimit.threshold"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var notificationAuthorizationState: NotificationAuthorizationState = .checking

    var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: Key.menuBarDisplayMode) }
    }
    var showsLimits: Bool {
        didSet { defaults.set(showsLimits, forKey: Key.showsLimits) }
    }
    var showsProviderBreakdown: Bool {
        didSet { defaults.set(showsProviderBreakdown, forKey: Key.showsProviderBreakdown) }
    }
    var showsActivityChart: Bool {
        didSet { defaults.set(showsActivityChart, forKey: Key.showsActivityChart) }
    }
    var showsKeepAwake: Bool {
        didSet { defaults.set(showsKeepAwake, forKey: Key.showsKeepAwake) }
    }
    /// Providers the user has hidden from the menu popover. The dashboard
    /// always shows every provider; this only trims the glanceable surface.
    var hiddenMenuProviders: Set<String> {
        didSet { defaults.set(hiddenMenuProviders.sorted(), forKey: Key.hiddenMenuProviders) }
    }
    /// Limit bars fill with what is left instead of what is used.
    var barsShowRemaining: Bool {
        didSet { defaults.set(barsShowRemaining, forKey: Key.barsShowRemaining) }
    }
    var resetTimeStyle: ResetTimeStyle {
        didSet { defaults.set(resetTimeStyle.rawValue, forKey: Key.resetTimeStyle) }
    }
    /// Show whether usage is ahead of or behind an even burn to the reset.
    var showsPace: Bool {
        didSet { defaults.set(showsPace, forKey: Key.showsPace) }
    }
    /// Order of provider limit cards; providers not listed keep default order.
    var limitProviderOrder: [String] {
        didSet { defaults.set(limitProviderOrder, forKey: Key.limitProviderOrder) }
    }
    /// The period the popover opens on.
    var defaultPeriod: PeriodTab {
        didSet { defaults.set(defaultPeriod.rawValue, forKey: Key.defaultPeriod) }
    }

    nonisolated static let limitProviders = ["claude", "codex", "cursor"]

    /// Known limit providers in the user's order.
    var orderedLimitProviders: [String] {
        let known = Self.limitProviders
        return limitProviderOrder.filter(known.contains) + known.filter { !limitProviderOrder.contains($0) }
    }

    func moveLimitProvider(_ provider: String, by offset: Int) {
        var order = orderedLimitProviders
        guard let index = order.firstIndex(of: provider) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        guard target != index else { return }
        order.swapAt(index, target)
        limitProviderOrder = order
    }

    /// Opt-in: fetch real Claude subscription limits with the OAuth token
    /// Claude Code keeps in the Keychain. Off by default because reading that
    /// Keychain item needs macOS consent (prompted only on user action).
    var claudeQuotaEnabled: Bool {
        didSet { defaults.set(claudeQuotaEnabled, forKey: Key.claudeQuotaEnabled) }
    }
    /// Opt-in: query Cursor's undocumented dashboard API (limits and per-event
    /// history) with the login Cursor already saved. Off by default because
    /// it reads another app's credential store and calls endpoints that can
    /// change.
    var cursorUsageEnabled: Bool {
        didSet { defaults.set(cursorUsageEnabled, forKey: Key.cursorUsageEnabled) }
    }
    /// Celebrate with a confetti burst in the popover when a weekly or monthly
    /// subscription window resets — fresh capacity is worth a little moment.
    var confettiOnReset: Bool {
        didSet { defaults.set(confettiOnReset, forKey: Key.confettiOnReset) }
    }

    func isProviderVisibleInMenu(_ name: String) -> Bool {
        !hiddenMenuProviders.contains(name.lowercased())
    }

    func setProvider(_ name: String, visibleInMenu visible: Bool) {
        if visible {
            hiddenMenuProviders.remove(name.lowercased())
        } else {
            hiddenMenuProviders.insert(name.lowercased())
        }
    }
    var dailyTokenAlertEnabled: Bool {
        didSet { defaults.set(dailyTokenAlertEnabled, forKey: Key.dailyTokenAlertEnabled) }
    }
    var dailyTokenAlertThreshold: Int {
        didSet {
            let clamped = max(dailyTokenAlertThreshold, 1)
            defaults.set(clamped, forKey: Key.dailyTokenAlertThreshold)
            if dailyTokenAlertThreshold != clamped { dailyTokenAlertThreshold = clamped }
        }
    }
    var providerLimitAlertEnabled: Bool {
        didSet { defaults.set(providerLimitAlertEnabled, forKey: Key.providerLimitAlertEnabled) }
    }
    var providerLimitAlertThreshold: Double {
        didSet {
            let clamped = min(max(providerLimitAlertThreshold, 1), 100)
            defaults.set(clamped, forKey: Key.providerLimitAlertThreshold)
            if providerLimitAlertThreshold != clamped { providerLimitAlertThreshold = clamped }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarDisplayMode = defaults.string(forKey: Key.menuBarDisplayMode)
            .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .todayCost
        showsLimits = defaults.object(forKey: Key.showsLimits) as? Bool ?? true
        showsProviderBreakdown = defaults.object(forKey: Key.showsProviderBreakdown) as? Bool ?? true
        showsActivityChart = defaults.object(forKey: Key.showsActivityChart) as? Bool ?? true
        showsKeepAwake = defaults.object(forKey: Key.showsKeepAwake) as? Bool ?? true
        hiddenMenuProviders = Set(defaults.stringArray(forKey: Key.hiddenMenuProviders) ?? [])
        barsShowRemaining = defaults.object(forKey: Key.barsShowRemaining) as? Bool ?? false
        resetTimeStyle = defaults.string(forKey: Key.resetTimeStyle)
            .flatMap(ResetTimeStyle.init(rawValue:)) ?? .countdown
        showsPace = defaults.object(forKey: Key.showsPace) as? Bool ?? true
        limitProviderOrder = defaults.stringArray(forKey: Key.limitProviderOrder) ?? []
        defaultPeriod = defaults.string(forKey: Key.defaultPeriod)
            .flatMap(PeriodTab.init(rawValue:)) ?? .today
        claudeQuotaEnabled = defaults.object(forKey: Key.claudeQuotaEnabled) as? Bool ?? false
        cursorUsageEnabled = defaults.object(forKey: Key.cursorUsageEnabled) as? Bool ?? false
        confettiOnReset = defaults.object(forKey: Key.confettiOnReset) as? Bool ?? true
        dailyTokenAlertEnabled = defaults.object(forKey: Key.dailyTokenAlertEnabled) as? Bool ?? false
        dailyTokenAlertThreshold = max(defaults.object(forKey: Key.dailyTokenAlertThreshold) as? Int ?? 1_000_000, 1)
        providerLimitAlertEnabled = defaults.object(forKey: Key.providerLimitAlertEnabled) as? Bool ?? false
        providerLimitAlertThreshold = min(
            max(defaults.object(forKey: Key.providerLimitAlertThreshold) as? Double ?? 80, 1),
            100
        )
    }

    var alertConfiguration: UsageAlertConfiguration {
        UsageAlertConfiguration(
            dailyTokenAlertEnabled: dailyTokenAlertEnabled,
            dailyTokenThreshold: dailyTokenAlertThreshold,
            providerLimitAlertEnabled: providerLimitAlertEnabled,
            providerLimitThreshold: providerLimitAlertThreshold
        )
    }

    func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            notificationAuthorizationState = .notDetermined
        case .denied:
            notificationAuthorizationState = .denied
        case .authorized, .provisional, .ephemeral:
            notificationAuthorizationState = .allowed
        @unknown default:
            notificationAuthorizationState = .denied
        }
    }
}
