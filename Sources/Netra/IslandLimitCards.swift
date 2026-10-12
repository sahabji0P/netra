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
                        .minimumScaleFactor(0.7)
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

/// One provider in the expanded island: logo, name and live account, the
/// rings, and the reset countdown. Extra rows follow the user's island
/// sections. Tapping the account chip lists the saved accounts in place.
struct IslandProviderCard: View {
    var limits: ProviderLimits
    var preferences: AppPreferences
    var accountLabel: String?
    var accounts: AccountStore? = nil
    /// This provider's estimated spend today.
    var todayCost: Double = 0
    /// The active 5h block's cost, shown under Claude's local estimate.
    var activeBlockCost: Double?
    /// The only card: rings beside the details instead of above them.
    var isWide = false
    var now: Date = .now

    @State private var picksAccount = false
    @State private var showsCredits = false

    private var provider: AccountProvider? { AccountProvider(rawValue: limits.agent) }
    private var canPick: Bool {
        guard let accounts, let provider else { return false }
        return accounts.accounts(for: provider).count > 1
    }

    var body: some View {
        let windows = limits.windows
        VStack(alignment: .leading, spacing: 10) {
            header
            if picksAccount, let accounts, let provider {
                IslandAccountPicker(accounts: accounts, provider: provider) { picksAccount = false }
            } else if isWide {
                HStack(alignment: .top, spacing: 22) {
                    rings(windows).padding(.leading, 6)
                    details(windows)
                }
            } else {
                rings(windows)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                details(windows)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { IslandCardBackground(color: AgentPalette.color(for: limits.agent)) }
        .animation(IslandTheme.morph, value: picksAccount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AgentPalette.displayName(limits.agent)) limits")
    }

    private func rings(_ windows: [QuotaWindow]) -> some View {
        IslandLimitRings(
            limits: limits, windows: [windows.first, IslandData.secondaryWindow(limits)].compactMap { $0 },
            showRemaining: preferences.barsShowRemaining, size: 96, now: now
        )
    }

    private func details(_ windows: [QuotaWindow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let outer = windows.first {
                resetFooter(outer)
            }
            if preferences.showsIslandSection(.windowDetails) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(windows.enumerated()), id: \.element) { index, window in
                        windowRow(window, index: index)
                    }
                }
            } else if preferences.showsIslandSection(.secondWindow), let second = IslandData.secondaryWindow(limits) {
                secondLine(second)
            }
            if limits.isEstimate {
                Text("Local estimate vs your heaviest 5h block\(activeBlockCost.map { " · \(Format.cost($0)) so far" } ?? "")")
                    .font(.system(size: 10))
                    .foregroundStyle(IslandTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if preferences.showsIslandSection(.providerSpend) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.cost(todayCost))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("today")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity)
                .help("Estimated at API list prices — what this usage would cost pay-as-you-go, not your subscription bill.")
            }
            if preferences.showsIslandSection(.bankedResets), let banked = bankedText {
                bankedResets(banked)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let creditBlue = Color(red: 0.49, green: 0.77, blue: 1)

    /// The banked-reset count and the next expiry; tapping lists every
    /// credit with its own expiry. Display only: redeeming happens in Codex.
    private func bankedResets(_ banked: String) -> some View {
        let credits = limits.resetCredits.filter { $0.isAvailable(at: now) }
        return VStack(spacing: 5) {
            Button {
                showsCredits.toggle()
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text(banked)
                        if !credits.isEmpty {
                            Image(systemName: showsCredits ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.creditBlue)
                    Text(nextExpiry(credits))
                        .font(.system(size: 9.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Self.creditBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(credits.isEmpty)
            .help("Redeem banked resets in \(AgentPalette.displayName(limits.agent))")
            if showsCredits {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                        HStack(spacing: 4) {
                            Text(credit.title ?? "Reset")
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(credit.expiresAt.map { "expires \(IslandText.resetsIn($0, now: now))" } ?? "no expiry")
                                .foregroundStyle(IslandTheme.secondaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .font(.system(size: 9.5))
                    }
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            }
        }
        .animation(IslandTheme.morph, value: showsCredits)
    }

    private func nextExpiry(_ credits: [LimitResetCredit]) -> String {
        guard let soonest = credits.compactMap(\.expiresAt).min() else {
            return credits.isEmpty ? "Redeem in \(AgentPalette.shortName(limits.agent))" : "No expiry"
        }
        return "Next expires in \(IslandText.resetsIn(soonest, now: now))"
    }

    private var bankedText: String? {
        let count = limits.bankedResetCount
        guard count > 0 else { return nil }
        return count == 1 ? "1 banked reset" : "\(count) banked resets"
    }

    private var header: some View {
        HStack(spacing: 5) {
            ProviderLogo(agent: limits.agent, size: 15)
            Text(AgentPalette.shortName(limits.agent))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            if let label = limits.isEstimate ? accountLabel ?? "estimate" : accountLabel ?? limits.plan.map(Self.planBadge) {
                Button {
                    picksAccount.toggle()
                } label: {
                    IslandAccountChip(label: label, agent: limits.agent, showsMenu: canPick, isOpen: picksAccount)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .disabled(!canPick)
                .help(canPick ? "Switch \(AgentPalette.displayName(limits.agent)) account" : limits.source)
            }
        }
    }

    private func secondLine(_ window: QuotaWindow) -> some View {
        let remaining = preferences.barsShowRemaining && !limits.isEstimate
        return HStack(spacing: 4) {
            Text(LimitText.title(window.label))
                .foregroundStyle(IslandTheme.secondaryText)
                .lineLimit(1)
            Text(IslandText.rowAmount(window, showRemaining: remaining, isEstimate: limits.isEstimate))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(window.usedPercent >= 90 ? IslandTheme.critical : .white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
            if let resetsAt = window.resetsAt {
                Text("· \(IslandText.resetsIn(resetsAt, now: now))")
                    .monospacedDigit()
                    .foregroundStyle(IslandTheme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .help(LimitText.reset(resetsAt, style: preferences.resetTimeStyle, now: now))
            }
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity)
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
        let pace = preferences.showsIslandSection(.pace) && !limits.isEstimate ? LimitText.pace(outer, now: now) : nil
        VStack(spacing: 6) {
            if let resetsAt = outer.resetsAt {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(IslandText.resetsIn(resetsAt, now: now))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(limits.isEstimate ? "until the block ends" : "to reset")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            if let pace {
                IslandPaceBadge(pace: pace)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Sources report plans as "team", "pro", "Max 5x"; show them uniformly.
    static func planBadge(_ plan: String) -> String {
        plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

/// The saved accounts for one provider, shown in place of a card's rings.
/// Switching happens only on a click, through the account switcher.
struct IslandAccountPicker: View {
    var accounts: AccountStore
    var provider: AccountProvider
    var done: () -> Void

    var body: some View {
        let active = accounts.activeAccount(for: provider)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(accounts.accounts(for: provider)) { account in
                let isActive = account.id == active?.id
                Button {
                    guard !isActive else { return done() }
                    Task {
                        await accounts.switchTo(account)
                        done()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(isActive ? AgentPalette.color(for: provider.agent) : IslandTheme.secondaryText)
                        Text(accounts.roster.label(for: account))
                            .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(isActive ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(accounts.switching != nil)
            }
            if accounts.switching == provider {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Switching…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(IslandTheme.secondaryText)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
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

/// Who is signed in, as a small capsule; with a chevron when the card can
/// list other saved accounts to switch to.
struct IslandAccountChip: View {
    var label: String
    var agent: String
    var showsMenu = false
    var isOpen = false

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
            if showsMenu {
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
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
