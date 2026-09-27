import SwiftUI

/// What the popover's side panel describes: one provider's usage.
enum UsagePanelTarget: Hashable {
    case provider(String)
}

/// The side panel that slides out beside the popover while a provider's
/// subscription card is hovered: period totals, token mix, per-model split.
struct UsageDetailPanel: View {
    var title: String
    var accent: Color
    var periodCaption: String
    var cost: Double
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    /// (display provider, model) pairs; provider is nil inside one provider.
    var models: [(provider: String?, model: ModelStat)]
    /// Optional Today / This week / This month totals shown above the detail.
    var periods: [(label: String, cost: Double, tokens: Int)] = []

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !periods.isEmpty { periodStrip }
            tokenMix
            Divider()
            modelList
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(periodCaption.capitalized)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.providerCost(title, cost: cost, tokens: totalTokens))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(Format.tokens(totalTokens)) tokens")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var periodStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
                VStack(alignment: .leading, spacing: 2) {
                    Text(period.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(Format.providerCost(title, cost: period.cost, tokens: period.tokens))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    Text(Format.tokens(period.tokens))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < periods.count - 1 { Divider().frame(height: 34).padding(.horizontal, 8) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tokenParts: [(label: String, value: Int, color: Color)] {
        [
            ("Cache reads", cacheReadTokens, Color(red: 0.22, green: 0.53, blue: 0.90)),
            ("Input", inputTokens, Color(nsColor: .systemGray)),
            ("Cache writes", cacheCreationTokens, Color(red: 0.93, green: 0.63, blue: 0)),
            ("Output", outputTokens, Color(red: 0.2, green: 0.7, blue: 0.45)),
        ]
    }

    private var tokenMix: some View {
        let parts = tokenParts.filter { $0.value > 0 }
        let whole = max(parts.reduce(0) { $0 + $1.value }, 1)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                // Segments share the width left after the gaps, so the bar
                // ends at the panel edge instead of overflowing it.
                let available = max(geometry.size.width - Double(max(parts.count - 1, 0)), 0)
                HStack(spacing: 1) {
                    ForEach(parts, id: \.label) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, available * Double(part.value) / Double(whole)))
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .clipShape(Capsule())
            }
            .frame(height: 6)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(parts, id: \.label) { part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5).fill(part.color).frame(width: 7, height: 7)
                        Text(part.label).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(Format.tokens(part.value)).monospacedDigit()
                    }
                    .padding(.trailing, 8)
                }
            }
            .font(.system(size: 10.5))
            .lineLimit(1)
        }
    }

    private var modelList: some View {
        let sorted = models.sorted {
            $0.model.cost == $1.model.cost ? $0.model.totalTokens > $1.model.totalTokens : $0.model.cost > $1.model.cost
        }
        let shown = sorted.prefix(8)
        let whole = max(sorted.reduce(0) { $0 + $1.model.cost }, 0.000_001)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if sorted.isEmpty {
                Text("No per-model detail for this period")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let provider = item.provider {
                            Circle().fill(AgentPalette.color(for: provider)).frame(width: 6, height: 6)
                        }
                        Text(AgentPalette.modelDisplayName(item.model.name))
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(Format.tokens(item.model.totalTokens))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Format.providerCost(item.provider ?? title, cost: item.model.cost, tokens: item.model.totalTokens))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 54, alignment: .trailing)
                    }
                    LimitBar(
                        fraction: item.model.cost / whole,
                        color: (item.provider.map { AgentPalette.color(for: $0) } ?? accent).opacity(0.7),
                        marker: nil
                    )
                    .frame(height: 4)
                }
            }
            if sorted.count > shown.count {
                Text("+\(sorted.count - shown.count) more in the Usage dashboard")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
