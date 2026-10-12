import SwiftUI

/// A provider's own logo mark at the given size. Placeholder until the
/// official marks land: a filled dot in the provider's palette color.
struct ProviderLogo: View {
    var agent: String
    var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(AgentPalette.color(for: agent))
            .frame(width: size, height: size)
            .accessibilityLabel(AgentPalette.displayName(agent))
    }
}
