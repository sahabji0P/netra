import Foundation

/// One provider's limit windows, normalized for display. Built from the
/// snapshot so the popover and the menu-bar icon always agree.
struct ProviderLimits: Identifiable, Equatable, Sendable {
    var agent: String
    var plan: String?
    /// Where the numbers come from, e.g. "Via Claude Code", "Reported by Codex".
    var source: String
    var observedAt: Date?
    var windows: [QuotaWindow]
    /// A local estimate (Claude's 5h block vs your peak), not a real quota.
    var isEstimate = false
    /// One short provider-specific line, e.g. Claude's extra-usage status.
    var note: String? = nil
    /// Banked resets the account can redeem, soonest expiry first.
    var resetCredits: [LimitResetCredit] = []
    /// When the server reports only a count (no per-credit detail).
    var resetCreditCount: Int = 0
    var id: String { agent }

    /// The window closest to exhaustion; drives the menu-bar indicator.
    /// Redeemable banked resets. The server may cap the detail list, so the
    /// reported count wins when it is larger.
    var bankedResetCount: Int {
        max(resetCredits.count, resetCreditCount)
    }

    var mostConstrained: QuotaWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// Short window on top, the most-used remaining window below.
    var iconWindows: (top: QuotaWindow, bottom: QuotaWindow?)? {
        guard let top = windows.min(by: {
            ($0.durationSeconds ?? .greatestFiniteMagnitude) < ($1.durationSeconds ?? .greatestFiniteMagnitude)
        }) else { return nil }
        let bottom = windows.filter { $0 != top }.max { $0.usedPercent < $1.usedPercent }
        return (top, bottom)
    }
}

extension UsageSnapshot {
    /// Providers with live limit data, in the user's order.
    func providerLimits(order: [String], now: Date = .now) -> [ProviderLimits] {
        order.compactMap { agent in
            switch agent {
            case "claude": claudeLimits(now: now)
            case "codex": codexLimits(now: now)
            case "cursor": cursorLimits(now: now)
            default: nil
            }
        }
    }

    private func claudeLimits(now: Date) -> ProviderLimits? {
        if let quota = claudeQuota {
            let windows = quota.activeWindows(now: now)
            if !windows.isEmpty {
                let source = switch quota.source {
                case .oauth: "Reported by Anthropic"
                case .claudeCodeCache: "Via Claude Code"
                case .lastSeen: "Last seen"
                }
                return ProviderLimits(
                    agent: "claude", plan: quota.subscriptionType, source: source,
                    observedAt: quota.fetchedAt, windows: windows,
                    note: quota.extraUsage?.summary
                )
            }
        }
        guard let block = activeBlock, block.end > now else { return nil }
        return ProviderLimits(
            agent: "claude", plan: nil, source: "Local estimate",
            observedAt: fetchedAt,
            windows: [QuotaWindow(
                label: "5h block vs your peak", usedPercent: block.percentUsed,
                resetsAt: block.end, durationSeconds: 5 * 3600
            )],
            isEstimate: true
        )
    }

    private func codexLimits(now: Date) -> ProviderLimits? {
        guard let quota = codexQuota else { return nil }
        let windows = quota.activeWindows(now: now)
        guard !windows.isEmpty else { return nil }
        let source = switch quota.source {
        case .live: "Reported by OpenAI"
        case .lastSeen: "Last seen"
        default: "Last Codex session"
        }
        return ProviderLimits(
            agent: "codex", plan: quota.planType,
            source: source,
            observedAt: quota.observedAt, windows: windows,
            note: codexNote(quota),
            resetCredits: bankedResets(quota, now: now),
            resetCreditCount: quota.resetCreditsAvailable ?? 0
        )
    }

    private func codexNote(_ quota: CodexQuota) -> String? {
        guard let reached = quota.limitReachedType else { return nil }
        return reached.contains("credits_depleted") ? "Workspace credits used up" : "Limit reached"
    }

    private func bankedResets(_ quota: CodexQuota, now: Date) -> [LimitResetCredit] {
        (quota.resetCredits ?? [])
            .filter { $0.isAvailable(at: now) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    private func cursorLimits(now: Date) -> ProviderLimits? {
        guard let quota = cursorQuota else { return nil }
        let windows = quota.activeWindows(now: now)
        guard !windows.isEmpty else { return nil }
        return ProviderLimits(
            agent: "cursor", plan: quota.planType, source: "Reported by Cursor",
            observedAt: quota.fetchedAt, windows: windows
        )
    }
}

/// Text rules for limit rows, kept out of the views so they are testable.
enum LimitText {
    static func title(_ label: String) -> String {
        switch label {
        case "5h": return "Session · 5h"
        case "included usage": return "Included usage"
        case "auto models": return "Auto models"
        case "on-demand spend": return "On-demand spend"
        default:
            if let hours = Int(label.dropLast()), label.hasSuffix("h") { return "\(hours)-hour" }
            return label.prefix(1).uppercased() + label.dropFirst()
        }
    }

    /// "54% used" or "46% left"; estimates past 100% read as a multiplier.
    static func amount(_ window: QuotaWindow, showRemaining: Bool, isEstimate: Bool) -> String {
        if isEstimate { return "\(Format.peakPercent(window.usedPercent)) of peak" }
        let used = min(max(window.usedPercent, 0), 100)
        return showRemaining
            ? "\(Int((100 - used).rounded()))% left"
            : "\(Int(used.rounded()))% used"
    }

    static func reset(_ date: Date, style: ResetTimeStyle, now: Date = .now, calendar: Calendar = .current) -> String {
        switch style {
        case .countdown:
            return "Resets in \(duration(date.timeIntervalSince(now)))"
        case .clock:
            let time = date.formatted(date: .omitted, time: .shortened)
            if calendar.isDate(date, inSameDayAs: now) { return "Resets \(time)" }
            let within6Days = date.timeIntervalSince(now) < 6 * 86400
            let day = within6Days
                ? date.formatted(.dateTime.weekday(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated))
            return "Resets \(day) \(time)"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    enum Pace: Equatable {
        case exhausted
        case onPace
        case ahead(points: Int, runsOutIn: TimeInterval?)
        case behind(points: Int)
    }

    /// Compares usage with an even burn across the window. Nil when the
    /// window length is unknown or too little of it has elapsed to judge.
    static func pace(_ window: QuotaWindow, now: Date = .now) -> Pace? {
        guard let elapsed = window.elapsedFraction(now: now), elapsed >= 0.05,
              let duration = window.durationSeconds, let resetsAt = window.resetsAt else { return nil }
        let used = min(max(window.usedPercent, 0), 100)
        if used >= 100 { return .exhausted }
        // Nothing used yet: there is no burn rate to judge.
        if used < 1 { return nil }
        let delta = used - elapsed * 100
        if abs(delta) < 5 { return .onPace }
        if delta < 0 { return .behind(points: Int((-delta).rounded())) }
        let elapsedSeconds = elapsed * duration
        let ratePerSecond = used / elapsedSeconds
        let untilEmpty = ratePerSecond > 0 ? (100 - used) / ratePerSecond : nil
        let remaining = resetsAt.timeIntervalSince(now)
        return .ahead(
            points: Int(delta.rounded()),
            runsOutIn: untilEmpty.flatMap { $0 < remaining ? $0 : nil }
        )
    }

    /// "3 banked resets · next expires in 12d".
    static func bankedResets(_ limits: ProviderLimits, now: Date = .now) -> String? {
        let count = limits.bankedResetCount
        guard count > 0 else { return nil }
        let noun = count == 1 ? "banked reset" : "banked resets"
        guard let soonest = limits.resetCredits.first?.expiresAt else { return "\(count) \(noun)" }
        return "\(count) \(noun) · next expires in \(duration(soonest.timeIntervalSince(now)))"
    }

    static func paceText(_ pace: Pace) -> String {
        switch pace {
        case .exhausted: return "Limit reached"
        case .onPace: return "On pace"
        case .behind(let points): return "\(points)% under pace"
        case .ahead(let points, let runsOut):
            if let runsOut { return "\(points)% ahead · runs out in ~\(duration(runsOut))" }
            return "\(points)% ahead of pace"
        }
    }
}
