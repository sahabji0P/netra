import Foundation

/// `dashboard-state.json`: what the GPUI dashboard reads to mirror the menu-bar
/// app (see docs/dashboard-bridge.md). Bridge-only transfer types, built from
/// the stores but never sharing their Codable shapes: a provider account id,
/// token, or Keychain payload has no field here to land in.
struct DashboardState: Codable, Equatable, Sendable {
    var version = 1
    var writtenAt: Date
    var app: App
    var preferences: Preferences
    var periods: [Period]
    var accounts: Accounts
    var navigate: Navigate?
    var results: [CommandResult]

    struct App: Codable, Equatable, Sendable {
        var version: String
        var pid: Int32
        var refreshing: Bool
        var lastError: String?
        var launchAtLogin: Bool
        var launchAtLoginAvailable: Bool
        /// "allowed" | "denied" | "notDetermined" | "checking"
        var notifications: String
        var claudeKeychainNeedsApproval: Bool
        var updateAvailable: String?
        var website: Website
    }

    struct Website: Codable, Equatable, Sendable {
        var tokenSaved: Bool
        var publishing: Bool
        var status: String
        var tokenError: String?
    }

    struct Preferences: Codable, Equatable, Sendable {
        var menuBarIcon: String
        var menuBarItems: [String]
        var menuBarStyle: String
        var menuBarTint: String
        var menuBarLimitSource: String
        var menuBarCompact: Bool
        var showsLimits: Bool
        var showsProviderBreakdown: Bool
        var showsActivityChart: Bool
        var showsKeepAwake: Bool
        var hiddenMenuProviders: [String]
        var defaultPeriod: String
        var barsShowRemaining: Bool
        var resetTimeStyle: String
        var showsPace: Bool
        var limitProviderOrder: [String]
        var claudeQuotaEnabled: Bool
        var cursorUsageEnabled: Bool
        var confettiOnReset: Bool
        var notchIslandEnabled: Bool
        var dailyTokenAlertEnabled: Bool
        var dailyTokenAlertThreshold: Int
        var providerLimitAlertEnabled: Bool
        var providerLimitAlertThreshold: Double
        var websitePublishEnabled: Bool
        var websiteEndpoint: String
    }

    struct Period: Codable, Equatable, Sendable {
        var id: String
        var title: String
    }

    struct Accounts: Codable, Equatable, Sendable {
        var providers: [ProviderAccounts]
        var notice: Notice?
    }

    struct ProviderAccounts: Codable, Equatable, Sendable {
        var provider: String
        var managing: Bool
        var live: LiveIdentity?
        var liveIsSaved: Bool
        var switching: Bool
        var pendingSignIn: Bool
        var note: String?
        var accounts: [Account]
    }

    struct LiveIdentity: Codable, Equatable, Sendable {
        var email: String?
        var displayName: String?
        var organization: String?
        var plan: String?
    }

    struct Account: Codable, Equatable, Sendable {
        /// Netra's own roster UUID, never the provider's account id.
        var id: String
        /// The nickname when set, else the email.
        var title: String
        var email: String?
        var plan: String?
        var organization: String?
        var initials: String
        var active: Bool
        /// "signInAgain" | "deactivated"
        var attention: String?
        var lastActiveAt: Date?
        var limits: Limits?
    }

    struct Limits: Codable, Equatable, Sendable {
        var observedAt: Date
        var isLive: Bool
        var windows: [Window]
    }

    struct Window: Codable, Equatable, Sendable {
        var label: String
        var usedPercent: Double
        var resetsAt: Date?
        var durationSeconds: Double?
    }

    struct Notice: Codable, Equatable, Sendable {
        var id: String
        var provider: String
        var title: String
        var detail: String?
        var isError: Bool
    }

    struct Navigate: Codable, Equatable, Sendable {
        var page: String
        var nonce: Int
    }

    struct CommandResult: Codable, Equatable, Sendable {
        var id: String
        var command: String
        var ok: Bool
        var message: String
        var at: Date
    }

    /// Results kept in the file, newest last.
    static let maxResults = 20

    static func appending(_ result: CommandResult, to results: [CommandResult]) -> [CommandResult] {
        Array((results + [result]).suffix(maxResults))
    }
}

// MARK: - Building from the app's models

extension DashboardState.Preferences {
    @MainActor
    init(_ preferences: AppPreferences) {
        menuBarIcon = preferences.menuBarIcon.rawValue
        menuBarItems = preferences.menuBarItems.map(\.rawValue)
        menuBarStyle = preferences.menuBarStyle.rawValue
        menuBarTint = preferences.menuBarTint.rawValue
        menuBarLimitSource = preferences.menuBarLimitSource
        menuBarCompact = preferences.menuBarCompact
        showsLimits = preferences.showsLimits
        showsProviderBreakdown = preferences.showsProviderBreakdown
        showsActivityChart = preferences.showsActivityChart
        showsKeepAwake = preferences.showsKeepAwake
        hiddenMenuProviders = preferences.hiddenMenuProviders.sorted()
        defaultPeriod = preferences.defaultPeriod.bridgeID
        barsShowRemaining = preferences.barsShowRemaining
        resetTimeStyle = preferences.resetTimeStyle.rawValue
        showsPace = preferences.showsPace
        limitProviderOrder = preferences.orderedLimitProviders
        claudeQuotaEnabled = preferences.claudeQuotaEnabled
        cursorUsageEnabled = preferences.cursorUsageEnabled
        confettiOnReset = preferences.confettiOnReset
        notchIslandEnabled = preferences.notchIslandEnabled
        dailyTokenAlertEnabled = preferences.dailyTokenAlertEnabled
        dailyTokenAlertThreshold = preferences.dailyTokenAlertThreshold
        providerLimitAlertEnabled = preferences.providerLimitAlertEnabled
        providerLimitAlertThreshold = preferences.providerLimitAlertThreshold
        websitePublishEnabled = preferences.websitePublishEnabled
        websiteEndpoint = preferences.websiteEndpoint
    }
}

extension DashboardState {
    static var periodList: [Period] {
        PeriodTab.allCases.map { Period(id: $0.bridgeID, title: $0.caption) }
    }

    static func notificationsValue(_ state: NotificationAuthorizationState) -> String {
        switch state {
        case .checking: "checking"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .allowed: "allowed"
        }
    }

    /// The website status line, as the SwiftUI settings page words it.
    static func websiteStatus(enabled: Bool, state: UsagePublisherState?) -> String {
        guard enabled else { return "Publishing is off." }
        if let error = state?.lastError { return error }
        if let last = state?.lastSuccessAt {
            return "Last published \(last.formatted(date: .abbreviated, time: .shortened))."
        }
        return "Not published yet."
    }

    /// The accounts section, from plain values so it can be tested without
    /// a switcher. Only presentation fields are copied.
    static func accounts(
        roster: AccountRoster,
        live: [AccountProvider: AccountIdentity],
        switching: AccountProvider?,
        pendingSignIn: AccountProvider?,
        codexUsesKeyring: Bool,
        notice: AccountNotice?
    ) -> Accounts {
        let providers = AccountProvider.allCases.map { provider -> ProviderAccounts in
            let identity = live[provider]
            let saved = identity.flatMap { roster.account(matching: $0) }
            let accounts = roster.accounts(for: provider).map { account in
                Account(
                    id: account.id.uuidString,
                    title: account.nickname.flatMap { $0.isEmpty ? nil : $0 } ?? account.title,
                    email: account.identity.email,
                    plan: account.identity.plan,
                    organization: account.identity.organizationName,
                    initials: account.initials,
                    active: account.id == saved?.id,
                    attention: account.attention?.rawValue,
                    lastActiveAt: account.lastActiveAt,
                    limits: account.lastLimits.map { record in
                        Limits(
                            observedAt: record.observedAt, isLive: record.isLive,
                            windows: record.windows.map {
                                Window(label: $0.label, usedPercent: $0.usedPercent,
                                       resetsAt: $0.resetsAt, durationSeconds: $0.durationSeconds)
                            }
                        )
                    }
                )
            }
            return ProviderAccounts(
                provider: provider.rawValue,
                managing: !accounts.isEmpty,
                live: identity.map {
                    LiveIdentity(email: $0.email, displayName: $0.displayName,
                                 organization: $0.organizationName, plan: $0.plan)
                },
                liveIsSaved: saved != nil,
                switching: switching == provider,
                pendingSignIn: pendingSignIn == provider,
                note: provider == .codex && codexUsesKeyring
                    ? AccountSwitchError.codexKeyring.errorDescription : nil,
                accounts: accounts
            )
        }
        return Accounts(
            providers: providers,
            notice: notice.map {
                Notice(id: $0.id.uuidString, provider: $0.provider.rawValue, title: $0.title,
                       detail: $0.detail, isError: $0.isError)
            }
        )
    }
}

extension PeriodTab {
    /// The period's id on the bridge: `today`, `week`, `month`.
    var bridgeID: String {
        switch self {
        case .today: "today"
        case .week: "week"
        case .month: "month"
        }
    }

    /// Accepts a bridge id or the raw value (`Day`, `Week`, `Month`).
    init?(bridgeID: String) {
        if let tab = PeriodTab.allCases.first(where: { $0.bridgeID == bridgeID }) {
            self = tab
        } else if let tab = PeriodTab(rawValue: bridgeID) {
            self = tab
        } else {
            return nil
        }
    }
}

// MARK: - JSON

/// Encoding and decoding rules shared by both bridge files: ISO 8601 dates
/// in UTC with fractional seconds, sorted keys so unchanged state encodes to
/// the same bytes.
enum DashboardJSON {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }
}
