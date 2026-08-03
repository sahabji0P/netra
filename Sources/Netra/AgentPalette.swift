import SwiftUI

enum AgentPalette {
    static func color(for agent: String) -> Color {
        switch agent.lowercased() {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": Color(red: 0.33, green: 0.55, blue: 0.90)
        case "opencode": Color(red: 0.30, green: 0.69, blue: 0.49)
        case "hermes": Color(red: 0.62, green: 0.47, blue: 0.85)
        default: Color(.systemGray)
        }
    }

    static func displayName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    static func shortName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude"
        default: displayName(agent)
        }
    }

    static func modelColor(for model: String) -> Color {
        let m = model.lowercased()
        if m.hasPrefix("claude") { return color(for: "claude") }
        if m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") { return color(for: "codex") }
        if m.hasPrefix("gemini") { return Color(red: 0.35, green: 0.61, blue: 0.84) }
        if m.hasPrefix("kimi") || m.hasPrefix("deepseek") || m.hasPrefix("qwen") { return color(for: "opencode") }
        if m.hasPrefix("grok") { return Color(.systemGray) }
        return color(for: "hermes")
    }

    /// Trim noisy date-stamp suffixes: claude-haiku-4-5-20251001 → claude-haiku-4-5
    static func modelDisplayName(_ model: String) -> String {
        if let range = model.range(of: #"-20\d{6}$"#, options: .regularExpression) {
            return String(model[..<range.lowerBound])
        }
        return model
    }
}
