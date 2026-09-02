import Foundation
import UserNotifications

struct UsageAlertConfiguration: Equatable, Sendable {
    var dailyTokenAlertEnabled: Bool
    var dailyTokenThreshold: Int
    var providerLimitAlertEnabled: Bool
    var providerLimitThreshold: Double

    var hasEnabledAlert: Bool {
        dailyTokenAlertEnabled || providerLimitAlertEnabled
    }
}

struct UsageAlertCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case dailyTokens
        case providerLimit
        case localLimitEstimate
    }

    var key: String
    var kind: Kind
    var title: String
    var body: String
}

struct UsageAlertDedupeState: Equatable, Sendable {
    fileprivate var activeKeys: Set<String> = []
}

enum NotificationAuthorizationState: Equatable, Sendable {
    case checking
    case notDetermined
    case denied
    case allowed

    var permitsAlerts: Bool { self == .allowed }
}

struct UsageAlertEvaluation: Equatable, Sendable {
    var candidates: [UsageAlertCandidate]
    var state: UsageAlertDedupeState
}

/// Pure threshold and deduplication logic. A key remains active while its value
/// is above the configured threshold. Falling below removes it, so a later
/// crossing can alert again; day and reset-cycle identifiers naturally create
/// a new key when the relevant usage window resets.
enum UsageAlertEvaluator {
    static func evaluate(
        snapshot: UsageSnapshot,
        configuration: UsageAlertConfiguration,
        previousState: UsageAlertDedupeState,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UsageAlertEvaluation {
        var active: [UsageAlertCandidate] = []

        if configuration.dailyTokenAlertEnabled {
            let dayKey = dayIdentifier(for: now, calendar: calendar)
            let tokens = snapshot.daily.first { $0.period == dayKey }?.totalTokens ?? 0
            let threshold = max(configuration.dailyTokenThreshold, 1)
            if tokens >= threshold {
                active.append(UsageAlertCandidate(
                    key: "daily-tokens:\(dayKey)",
                    kind: .dailyTokens,
                    title: "Daily token alert",
                    body: "\(Format.tokens(tokens)) tokens used today, above your \(Format.tokens(threshold)) alert."
                ))
            }
        }

        if configuration.providerLimitAlertEnabled {
            let threshold = min(max(configuration.providerLimitThreshold, 1), 100)
            if let quota = snapshot.codexQuota {
                // Without a reset timestamp there is no trustworthy cycle key,
                // so keep the recent value visible in the UI but do not emit a
                // potentially repeating provider-limit notification for it.
                for window in quota.activeWindows(now: now) where
                    window.resetsAt != nil && window.usedPercent >= threshold {
                    active.append(providerCandidate(
                        provider: "Codex",
                        window: window.label,
                        usedPercent: window.usedPercent,
                        threshold: threshold,
                        cycle: cycleIdentifier(window.resetsAt)
                    ))
                }
            }

            // Cursor's provider-reported usage alerts like Codex.
            if let cursor = snapshot.cursorQuota {
                for window in cursor.activeWindows(now: now) where
                    window.resetsAt != nil && window.usedPercent >= threshold {
                    active.append(providerCandidate(
                        provider: "Cursor",
                        window: window.label,
                        usedPercent: window.usedPercent,
                        threshold: threshold,
                        cycle: cycleIdentifier(window.resetsAt)
                    ))
                }
            }

            // Real Claude limits (opt-in OAuth fetch) alert like any other
            // provider-reported quota; windows without a reset never alert.
            if let claude = snapshot.claudeQuota {
                for window in claude.activeWindows(now: now) where
                    window.resetsAt != nil && window.usedPercent >= threshold {
                    active.append(providerCandidate(
                        provider: "Claude",
                        window: window.label,
                        usedPercent: window.usedPercent,
                        threshold: threshold,
                        cycle: cycleIdentifier(window.resetsAt)
                    ))
                }
            }

            // ccusage's active block is a local historical estimate, not an
            // Anthropic quota. Keep that provenance explicit in the alert,
            // and skip it entirely once real Claude limits are available.
            if snapshot.claudeQuota == nil,
               let block = snapshot.activeBlock,
               block.end > now,
               block.percentUsed >= threshold {
                active.append(UsageAlertCandidate(
                    key: "local-limit:claude:5h:\(cycleIdentifier(block.end))",
                    kind: .localLimitEstimate,
                    title: "Claude local usage alert",
                    body: "The local 5h estimate is \(roundedPercent(block.percentUsed)), above your \(roundedPercent(threshold)) alert."
                ))
            }
        }

        let activeKeys = Set(active.map(\.key))
        let candidates = active.filter { !previousState.activeKeys.contains($0.key) }
        return UsageAlertEvaluation(
            candidates: candidates,
            state: UsageAlertDedupeState(activeKeys: activeKeys)
        )
    }

    private static func providerCandidate(
        provider: String,
        window: String,
        usedPercent: Double,
        threshold: Double,
        cycle: String
    ) -> UsageAlertCandidate {
        UsageAlertCandidate(
            key: "provider-limit:\(provider.lowercased()):\(window.lowercased()):\(cycle)",
            kind: .providerLimit,
            title: "\(provider) limit alert",
            body: "The \(window) limit is \(roundedPercent(usedPercent)) used, above your \(roundedPercent(threshold)) alert."
        )
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func cycleIdentifier(_ date: Date?) -> String {
        guard let date else { return "unknown-cycle" }
        return String(Int(date.timeIntervalSince1970.rounded()))
    }

    private static func roundedPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

protocol UsageNotificationScheduling: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func schedule(_ candidate: UsageAlertCandidate) async throws
}

struct SystemUsageNotificationScheduler: UsageNotificationScheduling, @unchecked Sendable {
    let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .allowed
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(_ candidate: UsageAlertCandidate) async throws {
        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "netra.usage.\(candidate.key)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

protocol UsageAlertStatePersisting: Sendable {
    func deliveredKeys() async -> Set<String>
    func setDeliveredKeys(_ keys: Set<String>) async
}

actor UsageAlertDefaultsStore: UsageAlertStatePersisting {
    private enum Key {
        static let deliveredAlertKeys = "preferences.alerts.deliveredKeys"
    }

    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            self.defaults = defaults
        } else {
            defaults = .standard
        }
    }

    func deliveredKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: Key.deliveredAlertKeys) ?? [])
    }

    func setDeliveredKeys(_ keys: Set<String>) {
        defaults.set(keys.sorted(), forKey: Key.deliveredAlertKeys)
    }
}

/// Side-effect boundary called after a fresh usage snapshot. Notification
/// permission is never requested merely because Netra launches; the request is
/// made only after at least one alert setting has been enabled.
actor UsageAlertController {
    private let scheduler: any UsageNotificationScheduling
    private let persistence: any UsageAlertStatePersisting
    private var dedupeState = UsageAlertDedupeState()
    private var loadedPersistedState = false

    init(center: UNUserNotificationCenter = .current()) {
        scheduler = SystemUsageNotificationScheduler(center: center)
        persistence = UsageAlertDefaultsStore()
    }

    init(
        scheduler: any UsageNotificationScheduling,
        persistence: any UsageAlertStatePersisting
    ) {
        self.scheduler = scheduler
        self.persistence = persistence
    }

    func processFreshSnapshot(
        _ snapshot: UsageSnapshot,
        configuration: UsageAlertConfiguration,
        now: Date = .now,
        calendar: Calendar = .current
    ) async {
        if !loadedPersistedState {
            dedupeState = UsageAlertDedupeState(activeKeys: await persistence.deliveredKeys())
            loadedPersistedState = true
        }

        let evaluation = UsageAlertEvaluator.evaluate(
            snapshot: snapshot,
            configuration: configuration,
            previousState: dedupeState,
            now: now,
            calendar: calendar
        )
        // Remove keys whose usage has fallen below threshold (or whose day or
        // reset cycle ended), but do not mark a new crossing as delivered yet.
        // That happens only after the notification center accepts its request.
        dedupeState.activeKeys.formIntersection(evaluation.state.activeKeys)
        await persistDedupeState()

        guard configuration.hasEnabledAlert else { return }

        var authorization = await scheduler.authorizationState()
        if authorization == .notDetermined {
            _ = try? await scheduler.requestAuthorization()
            authorization = await scheduler.authorizationState()
        }
        guard authorization.permitsAlerts else { return }

        for candidate in evaluation.candidates {
            do {
                try await scheduler.schedule(candidate)
                dedupeState.activeKeys.insert(candidate.key)
                await persistDedupeState()
            } catch {
                // Leave the key uncommitted so the next successful refresh can
                // retry delivery while this threshold remains active.
            }
        }
    }

    private func persistDedupeState() async {
        await persistence.setDeliveredKeys(dedupeState.activeKeys)
    }
}
