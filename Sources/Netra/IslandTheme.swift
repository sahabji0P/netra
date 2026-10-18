import SwiftUI

/// Shared look of the notch island. The island is always black so it blends
/// with the camera notch, whatever the system appearance.
enum IslandTheme {
    static let background = Color.black
    static let card = Color(white: 0.07)
    static let track = Color(white: 0.16)
    static let secondaryText = Color(white: 0.55)
    static let warning = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let critical = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let fresh = Color(red: 0.19, green: 0.82, blue: 0.35)
    /// A newer Netra release is out.
    static let update = Color(red: 0.94, green: 0.54, blue: 0.36)

    static let cardRadius: CGFloat = 20
    static let expandedBottomRadius: CGFloat = 32
    static let compactBottomRadius: CGFloat = 14

    /// One spring for every island morph so all states move alike.
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.78)
}
