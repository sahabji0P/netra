import Foundation

/// Optional parts of the expanded island. The provider cards (ring, amount
/// left, reset countdown, account) always show; everything here is the
/// user's choice in Settings.
enum IslandSection: String, CaseIterable, Identifiable, Sendable {
    case usageFooter
    case keepAwake
    case bankedResets
    case secondWindow
    case windowDetails
    case pace
    case accounts
    case detailedStats

    var id: Self { self }

    var title: String {
        switch self {
        case .usageFooter: "Today's spend and 30-day strip"
        case .keepAwake: "Keep awake button"
        case .bankedResets: "Banked resets badge"
        case .secondWindow: "Second limit under each ring"
        case .windowDetails: "Every limit window"
        case .pace: "Pace badge"
        case .accounts: "All saved accounts"
        case .detailedStats: "Detailed stats"
        }
    }

    var detail: String {
        switch self {
        case .usageFooter: "One line at the bottom: today's cost and a heatmap of the last 30 days."
        case .keepAwake: "A button to keep the Mac awake from the island."
        case .bankedResets: "How many banked resets a provider has, on its card."
        case .secondWindow: "For example \"Weekly 98% left\" below the session ring."
        case .windowDetails: "A row per limit window with its own reset time."
        case .pace: "Whether you are using a window faster than time passes."
        case .accounts: "A list of every saved account with last-known limits. The account chip on each card can switch either way."
        case .detailedStats: "Change vs your 7-day average, the 5-hour block, and model and token mix."
        }
    }

    static let defaults: Set<IslandSection> = [.usageFooter, .keepAwake, .bankedResets, .secondWindow]
}
