import Foundation

/// One short-lived event the notch island grows to show, then shrinks back
/// from. Produced from snapshot changes; never stored.
struct IslandActivity: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A window crossed the user's provider-limit alert threshold.
        case runningHot(windowLabel: String, usedPercent: Double, resetsAt: Date?)
        /// A window is exhausted. `alternative` names a provider or parked
        /// account with room left: shown as information only, never acted on.
        case limitReached(windowLabel: String, resetsAt: Date?, alternative: String?)
        /// A window rolled into a new cycle.
        case windowReset(title: String)
        /// The live sign-in changed to another saved account.
        case accountSwitched(accountLabel: String)
        case keepAwake(isOn: Bool, until: Date?)
    }

    /// Stable dedupe key, e.g. "hot:claude:5h:<cycle>".
    var id: String
    /// Provider id ("claude", "codex", "cursor"), nil for app-wide events.
    var agent: String?
    var kind: Kind
    var createdAt: Date = .now
}
