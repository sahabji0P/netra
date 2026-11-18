import AppKit

// MARK: - Settings

/// The optional mark at the start of the menu-bar label.
enum MenuBarIconKind: String, CaseIterable, Identifiable, Sendable {
    case eye
    case bars
    case ring
    case none

    var id: Self { self }

    var title: String {
        switch self {
        case .eye: "Eye"
        case .bars: "Limit bars"
        case .ring: "Ring"
        case .none: "None"
        }
    }
}

/// One value the menu-bar label can show, in the user's order.
enum MenuBarItem: String, CaseIterable, Identifiable, Sendable {
    case todayCost
    case todayTokens
    case weekCost
    case monthCost
    case limitPercent
    case resetCountdown
    case sessionPercent
    case weeklyPercent

    var id: Self { self }

    var title: String {
        switch self {
        case .todayCost: "Today's cost"
        case .todayTokens: "Today's tokens"
        case .weekCost: "This week's cost"
        case .monthCost: "This month's cost"
        case .limitPercent: "Tightest limit"
        case .resetCountdown: "Time to reset"
        case .sessionPercent: "Session (5h) limit"
        case .weeklyPercent: "Weekly limit"
        }
    }
}

/// How the label is drawn on the menu bar.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case plain
    case pill
    case outline

    var id: Self { self }

    var title: String {
        switch self {
        case .plain: "Plain"
        case .pill: "Pill"
        case .outline: "Outline"
        }
    }
}

/// Where the label's color comes from.
enum MenuBarTint: String, CaseIterable, Identifiable, Sendable {
    /// A template image: follows the menu bar like every system icon.
    case mono
    /// The limit source's provider color.
    case provider
    /// Green, amber from 75%, red from 90% of the tightest window.
    case status

    var id: Self { self }

    var title: String {
        switch self {
        case .mono: "Menu bar"
        case .provider: "Provider"
        case .status: "Status"
        }
    }
}

extension MenuBarDisplayMode {
    /// The label an existing single-mode choice maps onto, so an upgrade
    /// keeps what the user saw.
    var labelIcon: MenuBarIconKind {
        self == .limitBars ? .bars : .eye
    }

    var labelItems: [MenuBarItem] {
        switch self {
        case .iconOnly, .limitBars: []
        case .todayCost: [.todayCost]
        case .todayTokens: [.todayTokens]
        case .highestProviderLimit: [.limitPercent]
        }
    }
}

/// Everything the label depends on from the preferences, as a value.
struct MenuBarLabelSettings: Equatable, Sendable {
    static let closestSource = "closest"

    var icon: MenuBarIconKind = .eye
    var items: [MenuBarItem] = [.todayCost]
    var style: MenuBarStyle = .plain
    var tint: MenuBarTint = .mono
    /// `closest` or a limit provider's agent name.
    var limitSource: String = closestSource
    var compact = false
    var barsShowRemaining = false
    var hiddenProviders: Set<String> = []
    var limitOrder: [String] = AppPreferences.limitProviders
}

// MARK: - Model

/// What the label shows right now, resolved from the snapshot. A plain
/// value, so it can be built in tests and drawn off the main actor.
struct MenuBarLabelModel: Equatable, Sendable {
    enum Icon: Equatable, Sendable {
        case none
        case eye
        case bars(top: Double, bottom: Double?)
        case ring(Double)
    }

    enum Color: Equatable, Sendable {
        /// Template image.
        case mono
        case agent(String)
        case status(usedPercent: Double)
    }

    var icon: Icon
    var texts: [String]
    var style: MenuBarStyle
    var color: Color
    var compact: Bool
    /// Keep Awake is on: the eye fills, other icons gain a dot.
    var awake: Bool

    var isTemplate: Bool { color == .mono }

    var accessibilityDescription: String {
        let base = texts.isEmpty ? "Netra" : "Netra, \(texts.joined(separator: ", "))"
        return awake ? "\(base), Keep Awake on" : base
    }

    static func make(
        settings: MenuBarLabelSettings,
        snapshot: UsageSnapshot?,
        awake: Bool,
        now: Date = .now
    ) -> MenuBarLabelModel {
        let limits = snapshot.flatMap { limitSource(in: $0, settings: settings, now: now) }
        let tightest = limits?.mostConstrained

        func shown(_ window: QuotaWindow) -> Double {
            let used = min(max(window.usedPercent, 0), 100)
            return settings.barsShowRemaining && limits?.isEstimate != true ? 100 - used : used
        }
        func percent(_ window: QuotaWindow) -> String {
            if limits?.isEstimate == true { return "\(Int(min(max(window.usedPercent, 0), 999).rounded()))%" }
            return "\(Int(shown(window).rounded()))%"
        }

        var texts: [String] = []
        // The window the countdown counts to: the one the limit item before
        // it reads, or the tightest when none comes before it.
        var countdownWindow = tightest
        for item in settings.items {
            let text: String?
            switch item {
            case .todayCost, .weekCost, .monthCost, .todayTokens:
                let tab: PeriodTab = switch item {
                case .weekCost: .week
                case .monthCost: .month
                default: .today
                }
                let row = snapshot?.currentRow(for: tab, now: now)
                    .filtered(hidingProviders: settings.hiddenProviders)
                if item == .todayTokens {
                    let tokens = row?.totalTokens ?? 0
                    text = tokens > 0 ? Format.tokens(tokens) : nil
                } else {
                    let cost = row?.cost ?? 0
                    text = cost > 0 ? Format.cost(cost) : nil
                }
            case .limitPercent:
                text = tightest.map(percent)
                countdownWindow = tightest ?? countdownWindow
            case .resetCountdown:
                text = countdownWindow?.resetsAt.flatMap { reset in
                    reset > now ? LimitText.duration(reset.timeIntervalSince(now)) : nil
                }
            case .sessionPercent:
                let window = limits.flatMap(sessionWindow)
                text = window.map { "\(shortLength($0)) \(percent($0))" }
                countdownWindow = window ?? countdownWindow
            case .weeklyPercent:
                let window = limits.flatMap(weeklyWindow)
                text = window.map { "7d \(percent($0))" }
                countdownWindow = window ?? countdownWindow
            }
            if let text { texts.append(text) }
        }

        var icon: Icon
        switch settings.icon {
        case .none: icon = .none
        case .eye: icon = .eye
        case .bars:
            if let windows = limits?.iconWindows {
                icon = .bars(top: shown(windows.top) / 100, bottom: windows.bottom.map { shown($0) / 100 })
            } else {
                icon = .eye
            }
        case .ring:
            icon = tightest.map { .ring(shown($0) / 100) } ?? .eye
        }
        // Never an empty label: the menu extra would vanish.
        if icon == .none, texts.isEmpty { icon = .eye }

        let color: Color = switch settings.tint {
        case .mono: .mono
        case .provider: limits.map { .agent($0.agent) } ?? .mono
        case .status: tightest.map { .status(usedPercent: $0.usedPercent) } ?? .mono
        }
        return MenuBarLabelModel(
            icon: icon, texts: texts, style: settings.style, color: color,
            compact: settings.compact, awake: awake
        )
    }

    /// The provider whose limits the label reports: the chosen one, or the
    /// visible provider closest to a limit. The Claude local estimate only
    /// stands in when no real quota exists anywhere.
    static func limitSource(in snapshot: UsageSnapshot, settings: MenuBarLabelSettings, now: Date) -> ProviderLimits? {
        if settings.limitSource != MenuBarLabelSettings.closestSource {
            return snapshot.providerLimits(order: [settings.limitSource], now: now).first
        }
        let all = snapshot.providerLimits(order: settings.limitOrder, now: now)
            .filter { !settings.hiddenProviders.contains($0.agent.lowercased()) }
        let real = all.filter { !$0.isEstimate }
        return (real.isEmpty ? all : real).max {
            ($0.mostConstrained?.usedPercent ?? 0) < ($1.mostConstrained?.usedPercent ?? 0)
        }
    }

    /// The short (session) window: at most a day long.
    static func sessionWindow(_ limits: ProviderLimits) -> QuotaWindow? {
        limits.windows
            .filter { ($0.durationSeconds ?? (($0.label == "5h") ? 5 * 3600 : .infinity)) <= 86400 }
            .min { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
    }

    /// The weekly window: about seven days long, or labelled weekly.
    static func weeklyWindow(_ limits: ProviderLimits) -> QuotaWindow? {
        limits.windows.first { window in
            if let duration = window.durationSeconds { return (6 * 86400...8 * 86400).contains(duration) }
            return window.label.hasPrefix("weekly")
        }
    }

    private static func shortLength(_ window: QuotaWindow) -> String {
        guard let duration = window.durationSeconds, duration >= 3600 else { return "5h" }
        return "\(Int((duration / 3600).rounded()))h"
    }
}

// MARK: - Drawing

/// Draws the whole menu-bar label as one image. A `MenuBarExtra` label can
/// only carry an image and text, so the pill and outline styles have to be
/// drawn. The image redraws on demand, so it is sharp at 1x and 2x and
/// resolves provider colors for the appearance it is drawn in.
enum MenuBarLabelRenderer {
    /// Height of the drawn label; the menu bar is about 22 pt tall.
    static let height: CGFloat = 18

    private struct Metrics {
        var font: NSFont
        var capsuleHeight: CGFloat
        var padding: CGFloat
        var iconGap: CGFloat
        var itemGap: CGFloat
        var eyeSize: CGFloat

        init(_ model: MenuBarLabelModel) {
            let base = NSFont.menuBarFont(ofSize: 0).pointSize
            let boxed = model.style != .plain
            let size = (model.compact ? base - 2 : base) - (boxed ? 1.5 : 0)
            font = .monospacedDigitSystemFont(ofSize: size, weight: boxed ? .semibold : .regular)
            capsuleHeight = model.compact ? 15 : 17
            padding = boxed ? (model.compact ? 5 : 7) : 1
            iconGap = model.compact ? 3 : 4
            itemGap = model.compact ? 5 : 7
            eyeSize = model.compact ? 12 : 13.5
        }
    }

    static func image(_ model: MenuBarLabelModel) -> NSImage {
        let metrics = Metrics(model)
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font]
        let textSizes = model.texts.map { ($0 as NSString).size(withAttributes: attributes) }
        let iconWidth = iconWidth(model, metrics)
        let dotWidth: CGFloat = model.awake && model.icon != .eye ? 5 : 0

        var contentWidth = iconWidth + dotWidth
        if !textSizes.isEmpty {
            if contentWidth > 0 { contentWidth += metrics.iconGap }
            contentWidth += textSizes.map(\.width).reduce(0, +)
                + metrics.itemGap * CGFloat(textSizes.count - 1)
        }
        let width = (contentWidth + metrics.padding * 2).rounded(.up)
        let size = NSSize(width: max(width, height), height: height)

        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let color = resolvedColor(model.color)
            let capsule = NSRect(
                x: 0.5, y: (rect.height - metrics.capsuleHeight) / 2,
                width: rect.width - 1, height: metrics.capsuleHeight
            )
            let radius = metrics.capsuleHeight / 2
            switch model.style {
            case .plain: break
            case .pill:
                color.setFill()
                NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius).fill()
            case .outline:
                let path = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: radius - 0.5, yRadius: radius - 0.5)
                path.lineWidth = 1.2
                color.setStroke()
                path.stroke()
            }

            // The content is drawn as one layer: in the label color, or
            // punched out of the pill so the menu bar shows through.
            context.saveGState()
            if model.style == .pill { context.setBlendMode(.destinationOut) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let ink: NSColor = model.style == .pill ? .black : color
            var x = metrics.padding
            let midY = rect.height / 2
            if model.awake, model.icon == .none {
                drawDot(x: x, midY: midY, ink: ink)
                x += dotWidth
            }
            if iconWidth > 0 {
                drawIcon(model, in: NSRect(x: x, y: 0, width: iconWidth, height: rect.height),
                         metrics: metrics, ink: ink)
                x += iconWidth
                if model.awake, model.icon != .eye {
                    drawDot(x: x + 1.5, midY: midY, ink: ink)
                    x += dotWidth
                }
            }
            if !textSizes.isEmpty, x > metrics.padding { x += metrics.iconGap }
            var textAttributes = attributes
            textAttributes[.foregroundColor] = ink
            for (text, textSize) in zip(model.texts, textSizes) {
                let y = midY - textSize.height / 2
                (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: textAttributes)
                x += textSize.width + metrics.itemGap
            }
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
        image.isTemplate = model.isTemplate
        image.accessibilityDescription = model.accessibilityDescription
        return image
    }

    private static func resolvedColor(_ color: MenuBarLabelModel.Color) -> NSColor {
        switch color {
        case .mono: .black
        case .agent(let agent): AgentPalette.nsColor(for: agent)
        case .status(let used): AgentPalette.statusNSColor(usedPercent: used)
        }
    }

    private static func iconWidth(_ model: MenuBarLabelModel, _ metrics: Metrics) -> CGFloat {
        switch model.icon {
        case .none: 0
        case .eye: eyeSymbol(model, metrics).map { $0.size.width } ?? metrics.eyeSize
        case .bars: model.compact ? 15 : 17
        case .ring: model.compact ? 11 : 13
        }
    }

    private static func eyeSymbol(_ model: MenuBarLabelModel, _ metrics: Metrics) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: metrics.eyeSize, weight: .regular)
        return NSImage(systemSymbolName: model.awake ? "eye.fill" : "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func drawDot(x: CGFloat, midY: CGFloat, ink: NSColor) {
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: midY - 1.75, width: 3.5, height: 3.5)).fill()
    }

    private static func drawIcon(_ model: MenuBarLabelModel, in rect: NSRect, metrics: Metrics, ink: NSColor) {
        switch model.icon {
        case .none:
            break
        case .eye:
            guard let symbol = eyeSymbol(model, metrics),
                  let context = NSGraphicsContext.current?.cgContext else { return }
            let target = NSRect(
                x: rect.minX, y: rect.midY - symbol.size.height / 2,
                width: symbol.size.width, height: symbol.size.height
            )
            // Symbols draw black; tint them inside their own layer.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: target)
            ink.setFill()
            target.fill(using: .sourceAtop)
            context.endTransparencyLayer()
        case .bars(let top, let bottom):
            func bar(y: CGFloat, height: CGFloat, fraction: Double) {
                let track = NSRect(x: rect.minX, y: y, width: rect.width, height: height)
                ink.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
                let clamped = CGFloat(min(max(fraction, 0), 1))
                let width = max(fraction > 0 ? height : 0, rect.width * clamped)
                ink.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: rect.minX, y: y, width: width, height: height),
                    xRadius: height / 2, yRadius: height / 2
                ).fill()
            }
            let scale: CGFloat = model.compact ? 0.85 : 1
            if let bottom {
                let topHeight = 4.5 * scale, bottomHeight = 3.5 * scale, gap = 2 * scale
                let y = rect.midY - (topHeight + gap + bottomHeight) / 2
                bar(y: y, height: topHeight, fraction: top)
                bar(y: y + topHeight + gap, height: bottomHeight, fraction: bottom)
            } else {
                let barHeight = 5 * scale
                bar(y: rect.midY - barHeight / 2, height: barHeight, fraction: top)
            }
        case .ring(let fraction):
            let lineWidth: CGFloat = model.compact ? 2 : 2.4
            let diameter = rect.width - lineWidth
            let circle = NSRect(
                x: rect.minX + lineWidth / 2, y: rect.midY - diameter / 2,
                width: diameter, height: diameter
            )
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = lineWidth
            ink.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let clamped = min(max(fraction, 0), 1)
            guard clamped > 0 else { return }
            let arc = NSBezierPath()
            // Flipped coordinates: clockwise from 12 o'clock.
            arc.appendArc(
                withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: diameter / 2,
                startAngle: -90, endAngle: -90 + 360 * clamped, clockwise: false
            )
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            ink.setStroke()
            arc.stroke()
        }
    }
}

/// The original two-bar template icon, kept for the settings previews.
enum MenuBarIcon {
    static func bars(top: Double, bottom: Double?, awake: Bool) -> NSImage {
        MenuBarLabelRenderer.image(MenuBarLabelModel(
            icon: .bars(top: top, bottom: bottom), texts: [], style: .plain,
            color: .mono, compact: false, awake: awake
        ))
    }
}

/// Made-up numbers for previewing the label before any usage is recorded.
enum MenuBarLabelPreview {
    static func sampleSnapshot(now: Date = .now, calendar: Calendar = .current) -> UsageSnapshot {
        let day = PeriodKeys.day(now, calendar)
        let agent = AgentStat(
            name: "claude", cost: 12.48, totalTokens: 4_200_000, inputTokens: 1_200_000, outputTokens: 80_000,
            cacheReadTokens: 2_920_000, models: []
        )
        let row = PeriodRow(period: day, date: calendar.startOfDay(for: now), parts: [agent])
        return UsageSnapshot(
            fetchedAt: now, daily: [row], activeBlock: nil,
            codexQuota: CodexQuota(
                windows: [QuotaWindow(label: "weekly", usedPercent: 82, resetsAt: now.addingTimeInterval(4 * 86400),
                                      durationSeconds: 7 * 86400)],
                planType: "plus", observedAt: now
            ),
            claudeQuota: ClaudeQuota(
                windows: [
                    QuotaWindow(label: "5h", usedPercent: 38, resetsAt: now.addingTimeInterval(2 * 3600 + 600),
                                durationSeconds: 5 * 3600),
                    QuotaWindow(label: "weekly", usedPercent: 64, resetsAt: now.addingTimeInterval(3 * 86400),
                                durationSeconds: 7 * 86400),
                ],
                subscriptionType: "max", fetchedAt: now
            ),
            calendar: calendar
        )
    }

    static var sampleSnapshot: UsageSnapshot { sampleSnapshot() }
}
