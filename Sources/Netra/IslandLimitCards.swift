import SwiftUI

// MARK: - Rings

enum IslandRingColor {
    /// The provider's color, or the island's critical red once a window is
    /// 90% used.
    static func color(agent: String, usedPercent: Double) -> Color {
        usedPercent >= 90 ? IslandTheme.critical : AgentPalette.color(for: agent)
    }
}

/// One limit ring: a track, an arc from 12 o'clock, and an optional white
/// tick at the fraction of the window already elapsed.
struct IslandRing: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat
    var tick: Double? = nil
    var arcOpacity: Double = 1

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(IslandTheme.track, lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: clamped)
                .stroke(color.opacity(arcOpacity), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let tick {
                GeometryReader { geometry in
                    let radius = min(geometry.size.width, geometry.size.height) / 2 - lineWidth / 2
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: lineWidth + 4)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(min(max(tick, 0), 1) * 360))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Concentric rings for one provider: outer = shortest window, inner = the
/// next, drawn at reduced opacity; the outer window's amount in the middle.
struct IslandLimitRings: View {
    var limits: ProviderLimits
    var windows: [QuotaWindow]
    var showRemaining: Bool
    var size: CGFloat = 104
    var now: Date = .now

    static let outerWidth: CGFloat = 9
    static let innerWidth: CGFloat = 7
    static let gap: CGFloat = 4
    static let innerOpacity = 0.55

    var body: some View {
        let remaining = showRemaining && !limits.isEstimate
        let innerSize = size - 2 * (Self.outerWidth + Self.gap)
        ZStack {
            if let outer = windows.first {
                ring(outer, lineWidth: Self.outerWidth, opacity: 1, remaining: remaining)
                    .frame(width: size, height: size)
            }
            if windows.count > 1 {
                ring(windows[1], lineWidth: Self.innerWidth, opacity: Self.innerOpacity, remaining: remaining)
                    .frame(width: innerSize, height: innerSize)
            }
            if let outer = windows.first {
                VStack(spacing: 0) {
                    Text(center(outer, remaining: remaining))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(outer.usedPercent >= 90 ? IslandTheme.critical : .white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(limits.isEstimate ? "of peak" : remaining ? "left · \(IslandText.ringLabel(outer, isEstimate: false))" : IslandText.ringLabel(outer, isEstimate: false))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(width: innerSize - 2 * Self.innerWidth - 6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(windows.map {
            "\(LimitText.title($0.label)) \(LimitText.amount($0, showRemaining: remaining, isEstimate: limits.isEstimate))"
        }.joined(separator: ", "))
    }

    private func ring(_ window: QuotaWindow, lineWidth: CGFloat, opacity: Double, remaining: Bool) -> some View {
        let used = min(max(window.usedPercent, 0), 100) / 100
        // Estimates have no real window to pace against.
        let elapsed = limits.isEstimate ? nil : window.elapsedFraction(now: now)
        return IslandRing(
            fraction: remaining ? 1 - used : used,
            color: IslandRingColor.color(agent: limits.agent, usedPercent: window.usedPercent),
            lineWidth: lineWidth,
            tick: elapsed.map { remaining ? 1 - $0 : $0 },
            arcOpacity: opacity
        )
    }

    private func center(_ window: QuotaWindow, remaining: Bool) -> String {
        if limits.isEstimate { return Format.peakPercent(window.usedPercent) }
        let used = min(max(window.usedPercent, 0), 100)
        return "\(Int((remaining ? 100 - used : used).rounded()))%"
    }
}

// MARK: - Provider card

/// One provider's limits in the expanded island: logo, name, live account,
/// rings, a row per window, then the next reset and the pace.
struct IslandProviderCard: View {
    var limits: ProviderLimits
    var preferences: AppPreferences
    var accountLabel: String?
    /// The active 5h block's cost, shown under Claude's local estimate.
    var activeBlockCost: Double?
    /// The only card: rings beside the details instead of above them.
    var isWide = false
    var now: Date = .now

    var body: some View {
        let windows = IslandData.ringOrder(limits.windows)
        let rings = IslandLimitRings(
            limits: limits, windows: windows,
            showRemaining: preferences.barsShowRemaining, now: now
        )
        VStack(alignment: .leading, spacing: 10) {
            header
            if isWide {
                HStack(alignment: .top, spacing: 22) {
                    rings.padding(.leading, 6)
                    details(windows)
                }
            } else {
                rings
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                details(windows)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { IslandCardBackground(color: AgentPalette.color(for: limits.agent)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AgentPalette.displayName(limits.agent)) limits")
    }

    private func details(_ windows: [QuotaWindow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(windows.enumerated()), id: \.element) { index, window in
                    windowRow(window, index: index)
                }
            }
            if let note = limits.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if limits.isEstimate {
                Text("Local estimate vs your heaviest 5h block\(activeBlockCost.map { " · \(Format.cost($0)) so far" } ?? "")")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let outer = windows.first {
                resetFooter(outer)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderLogo(agent: limits.agent, size: 16)
                Text(AgentPalette.displayName(limits.agent))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 5) {
                if let badge = limits.isEstimate ? "estimate" : limits.plan.map(Self.planBadge) {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(IslandTheme.track, in: Capsule())
                        .fixedSize()
                }
                if let accountLabel {
                    IslandAccountChip(label: accountLabel, agent: limits.agent)
                }
                Text(freshness)
                    .font(.system(size: 9.5))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .lineLimit(1)
                    .help(limits.source)
            }
        }
    }

    private var freshness: String {
        // The source stays in the tooltip; the card is too narrow for both.
        limits.observedAt.map { Format.age(since: $0, now: now) } ?? limits.source
    }

    private func windowRow(_ window: QuotaWindow, index: Int) -> some View {
        let remaining = preferences.barsShowRemaining && !limits.isEstimate
        let dotColor: Color = index > 1
            ? IslandTheme.track
            : IslandRingColor.color(agent: limits.agent, usedPercent: window.usedPercent)
                .opacity(index == 0 ? 1 : IslandLimitRings.innerOpacity)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(LimitText.title(window.label))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(IslandText.rowAmount(window, showRemaining: remaining, isEstimate: limits.isEstimate))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.usedPercent >= 90 ? IslandTheme.critical : .white)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let resetsAt = window.resetsAt {
                Text(LimitText.reset(resetsAt, style: preferences.resetTimeStyle, now: now))
                    .font(.system(size: 9.5))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func resetFooter(_ outer: QuotaWindow) -> some View {
        let pace = preferences.showsPace && !limits.isEstimate ? LimitText.pace(outer, now: now) : nil
        if outer.resetsAt != nil || pace != nil {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(IslandTheme.track).frame(height: 0.5)
                if let resetsAt = outer.resetsAt {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(IslandText.resetsIn(resetsAt, now: now))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(resetCaption(outer))
                            .font(.system(size: 10))
                            .foregroundStyle(IslandTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if let pace {
                    IslandPaceBadge(pace: pace)
                }
            }
        }
    }

    private func resetCaption(_ outer: QuotaWindow) -> String {
        if limits.isEstimate { return "until the block ends" }
        let label = IslandText.ringLabel(outer, isEstimate: false)
        return label.count <= 6 ? "to \(label) reset" : "to reset"
    }

    /// Sources report plans as "team", "pro", "Max 5x"; show them uniformly.
    static func planBadge(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

/// A card surface with a soft glow of the provider's color from the top.
struct IslandCardBackground: View {
    var color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandTheme.cardRadius, style: .continuous)
        shape
            .fill(IslandTheme.card)
            .overlay {
                RadialGradient(
                    colors: [color.opacity(0.30), color.opacity(0.08), .clear],
                    center: .top, startRadius: 0, endRadius: 170
                )
                .clipShape(shape)
            }
            .overlay { shape.strokeBorder(color.opacity(0.22), lineWidth: 0.75) }
    }
}

/// The pace as a small colored capsule.
struct IslandPaceBadge: View {
    var pace: LimitText.Pace

    var body: some View {
        let color = Self.color(pace)
        Text(LimitText.paceText(pace))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    static func color(_ pace: LimitText.Pace) -> Color {
        switch pace {
        case .exhausted: IslandTheme.critical
        case .ahead(_, let runsOut): runsOut == nil ? IslandTheme.warning.opacity(0.85) : IslandTheme.warning
        case .behind: IslandTheme.fresh
        case .onPace: Color(white: 0.85)
        }
    }
}

/// Who is signed in, as a small capsule. Display only: switching lives in
/// the accounts section.
struct IslandAccountChip: View {
    var label: String
    var agent: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(AgentPalette.color(for: agent))
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(IslandTheme.track, in: Capsule())
        .accessibilityLabel("Signed in as \(label)")
    }
}

/// A provider that was used this week but reports no limits.
struct IslandMissingLimitsCard: View {
    var agent: String
    var reason: String
    var accountLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderLogo(agent: agent, size: 16)
                Text(AgentPalette.displayName(agent))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if let accountLabel {
                IslandAccountChip(label: accountLabel, agent: agent)
            }
            IslandRing(fraction: 0, color: AgentPalette.color(for: agent), lineWidth: 9)
                .frame(width: 104, height: 104)
                .overlay {
                    Image(systemName: "questionmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
            Text("Limits unavailable")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Text(reason)
                .font(.system(size: 10))
                .foregroundStyle(IslandTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { IslandCardBackground(color: AgentPalette.color(for: agent)) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Banked resets

/// Banked resets per provider, soonest expiry first. Display only: they are
/// redeemed in the provider's own app.
struct IslandBankedResets: View {
    var cards: [ProviderLimits]
    var now: Date = .now

    var body: some View {
        let banked = cards.filter { $0.bankedResetCount > 0 }
        if !banked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(banked) { limits in
                    HStack(alignment: .top, spacing: 9) {
                        ZStack {
                            Circle().fill(AgentPalette.color(for: limits.agent).opacity(0.18))
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AgentPalette.color(for: limits.agent))
                        }
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LimitText.bankedResets(limits, now: now) ?? "")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(detail(limits))
                                .font(.system(size: 10))
                                .foregroundStyle(IslandTheme.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .help(help(limits))
                }
            }
            .padding(12)
            .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func detail(_ limits: ProviderLimits) -> String {
        let titles = limits.resetCredits.compactMap(\.title)
        let redeem = "Redeem in \(AgentPalette.shortName(limits.agent))"
        guard let first = titles.first else { return redeem }
        return "\(first) · \(redeem)"
    }

    private func help(_ limits: ProviderLimits) -> String {
        limits.resetCredits.map { credit in
            let title = credit.title ?? "Limit reset"
            return credit.expiresAt.map { "\(title) — expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? title
        }.joined(separator: "\n")
    }
}
