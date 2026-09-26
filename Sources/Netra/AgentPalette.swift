import AppKit
import SwiftUI

/// Central registry of provider presentation: identity colors, display names,
/// and model → provider inference. Colors are fixed per provider (never
/// assigned by rank) and were validated as a categorical palette for
/// colorblind separation and surface contrast in both appearances; provider
/// marks are always paired with a text label, never color alone.
enum AgentPalette {
    static func color(for agent: String) -> Color {
        switch agent.lowercased() {
        case "claude": dynamic(light: 0xC65D33, dark: 0xD4653A)   // terracotta
        case "codex": dynamic(light: 0x2A78D6, dark: 0x3987E5)    // blue
        case "opencode": dynamic(light: 0x1BAF7A, dark: 0x199E70) // aqua
        case "gemini": dynamic(light: 0xEDA100, dark: 0xC98500)   // amber
        case "pi": dynamic(light: 0xE87BA4, dark: 0xD55181)       // magenta
        case "copilot": dynamic(light: 0x008300, dark: 0x008300)  // green
        case "cursor": dynamic(light: 0x4A3AA7, dark: 0x9085E9)   // violet
        case "hermes": dynamic(light: 0xE34948, dark: 0xE66767)   // red
        default: Color(nsColor: .systemGray)
        }
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    static func displayName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "gemini": "Gemini CLI"
        case "pi": "Pi"
        case "copilot": "Copilot CLI"
        case "cursor": "Cursor"
        case "hermes": "Hermes"
        case "droid": "Droid"
        case "amp": "Amp"
        case "goose": "Goose"
        case "kilo": "Kilo Code"
        case "codebuff": "Codebuff"
        case "kimi": "Kimi CLI"
        case "qwen": "Qwen Code"
        case "openclaw": "OpenClaw"
        case "other": "Other"
        default: agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    static func shortName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude"
        case "gemini": "Gemini"
        case "copilot": "Copilot"
        default: displayName(agent)
        }
    }

    /// Best-effort provider inference from a model id, for rows where ccusage
    /// reports a model without an agent attribution.
    static func provider(forModel model: String) -> String? {
        let m = model.lowercased()
        if m.hasPrefix("claude") { return "claude" }
        if m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            return "codex"
        }
        if m.hasPrefix("gemini") { return "gemini" }
        if m.hasPrefix("kimi") || m.hasPrefix("deepseek") || m.hasPrefix("qwen") { return "opencode" }
        if m.hasPrefix("composer") || m.hasPrefix("grok") || m.hasPrefix("cursor") { return "cursor" }
        return nil
    }

    /// Trim noisy date-stamp suffixes: claude-haiku-4-5-20251001 → claude-haiku-4-5
    static func modelDisplayName(_ model: String) -> String {
        // Cursor reports its Auto model selection as the intent "default",
        // and Grok Bot (its separate weekly allowance) as grok-bot-*.
        if model == "default" { return "Auto" }
        if model.hasPrefix("grok-bot") {
            let mode = model.dropFirst("grok-bot".count).drop { $0 == "-" }
            return mode.isEmpty || mode == "default" ? "Grok Bot" : "Grok Bot · \(mode)"
        }
        if let range = model.range(of: #"-20\d{6}$"#, options: .regularExpression) {
            return String(model[..<range.lowerBound])
        }
        return model
    }
}

/// Shared styling for limit meters. Bars always use the provider's color.
enum LimitStyle {
    /// Popover bars keep the provider color; only the number turns red
    /// once a window is nearly exhausted, so color never means two things.
    static func amountColor(usedPercent: Double) -> Color {
        usedPercent >= 90 ? Color(nsColor: NSColor(rgb: 0xD03B3B)) : .primary
    }

}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
