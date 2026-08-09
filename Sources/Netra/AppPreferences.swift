import Foundation
import Observation
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case todayCost
    case todayTokens
    case highestProviderLimit

    var id: Self { self }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .todayCost: "Today's cost"
        case .todayTokens: "Today's tokens"
        case .highestProviderLimit: "Highest usage indicator"
        }
    }

    var detail: String {
        switch self {
        case .iconOnly: "Keep the menu bar minimal"
        case .todayCost: "Estimated API-equivalent cost"
        case .todayTokens: "Tokens processed today"
        case .highestProviderLimit: "Provider limit or local estimate"
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
