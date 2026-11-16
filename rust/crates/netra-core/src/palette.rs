//! Provider presentation as plain data (Swift `AgentPalette`). Colors are
//! fixed per provider, never assigned by rank, and are always paired with a
//! text label. The UI crate turns the hex values into its own color type.

/// A provider color for each appearance, as `0xRRGGBB`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Swatch {
    pub light: u32,
    pub dark: u32,
}

impl Swatch {
    pub const fn pick(self, dark: bool) -> u32 {
        if dark { self.dark } else { self.light }
    }
}

const fn swatch(light: u32, dark: u32) -> Swatch {
    Swatch { light, dark }
}

/// macOS `systemGray` in each appearance, for unknown providers.
pub const NEUTRAL: Swatch = swatch(0x8E8E93, 0x8E8E93);

pub fn color(agent: &str) -> Swatch {
    match agent.to_lowercase().as_str() {
        "claude" => swatch(0xC65D33, 0xD4653A),          // terracotta
        "codex" => swatch(0x2A78D6, 0x3987E5),           // blue
        "opencode" => swatch(0x1BAF7A, 0x199E70),        // aqua
        "gemini" => swatch(0xEDA100, 0xC98500),          // amber
        "pi" => swatch(0xE87BA4, 0xD55181),              // magenta
        "copilot" => swatch(0x008300, 0x008300),         // green
        "cursor" => swatch(0x4A3AA7, 0x9085E9),          // violet
        "cursor-grok-bot" => swatch(0x8C80D8, 0xC4BDF4), // pale violet
        "hermes" => swatch(0xE34948, 0xE66767),          // red
        _ => NEUTRAL,
    }
}

pub fn display_name(agent: &str) -> String {
    let name = match agent.to_lowercase().as_str() {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "opencode" => "OpenCode",
        "gemini" => "Gemini CLI",
        "pi" => "Pi",
        "copilot" => "Copilot CLI",
        "cursor" => "Cursor",
        "cursor-grok-bot" => "Cursor Grok Bot",
        "hermes" => "Hermes",
        "droid" => "Droid",
        "amp" => "Amp",
        "goose" => "Goose",
        "kilo" => "Kilo Code",
        "codebuff" => "Codebuff",
        "kimi" => "Kimi CLI",
        "qwen" => "Qwen Code",
        "openclaw" => "OpenClaw",
        "other" => "Other",
        _ => {
            let mut chars = agent.chars();
            return chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default();
        }
    };
    name.into()
}

pub fn short_name(agent: &str) -> String {
    match agent.to_lowercase().as_str() {
        "claude" => "Claude".into(),
        "gemini" => "Gemini".into(),
        "copilot" => "Copilot".into(),
        "cursor-grok-bot" => "Grok Bot".into(),
        _ => display_name(agent),
    }
}

/// Best-effort provider inference from a model id.
pub fn provider_for_model(model: &str) -> Option<&'static str> {
    let m = model.to_lowercase();
    let starts = |prefixes: &[&str]| prefixes.iter().any(|p| m.starts_with(p));
    if starts(&["claude"]) {
        Some("claude")
    } else if starts(&["gpt", "o1", "o3", "o4"]) {
        Some("codex")
    } else if starts(&["gemini"]) {
        Some("gemini")
    } else if starts(&["kimi", "deepseek", "qwen"]) {
        Some("opencode")
    } else if starts(&["composer", "grok", "cursor"]) {
        Some("cursor")
    } else {
        None
    }
}

/// Trim noisy date-stamp suffixes: `claude-haiku-4-5-20251001` → `claude-haiku-4-5`.
pub fn model_display_name(model: &str) -> String {
    if model == "default" {
        return "Auto".into();
    }
    if let Some(rest) = model.strip_prefix("grok-bot") {
        let mode = rest.trim_start_matches('-');
        return if mode.is_empty() || mode == "default" { "Grok Bot".into() } else { format!("Grok Bot · {mode}") };
    }
    // `-20` followed by exactly six digits at the very end.
    if model.len() > 9 {
        let (head, tail) = model.split_at(model.len() - 9);
        if tail.starts_with("-20") && tail[3..].bytes().all(|b| b.is_ascii_digit()) {
            return head.into();
        }
    }
    model.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_names_lose_date_stamps_only() {
        assert_eq!(model_display_name("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
        assert_eq!(model_display_name("claude-opus-5-5"), "claude-opus-5-5");
        assert_eq!(model_display_name("default"), "Auto");
        assert_eq!(model_display_name("grok-bot-fast"), "Grok Bot · fast");
        assert_eq!(model_display_name("grok-bot"), "Grok Bot");
    }

    #[test]
    fn providers_inferred_from_model_ids() {
        assert_eq!(provider_for_model("gpt-5.4-codex"), Some("codex"));
        assert_eq!(provider_for_model("Claude-Fable-5-2"), Some("claude"));
        assert_eq!(provider_for_model("mystery"), None);
        assert_eq!(display_name("mystery"), "Mystery");
        assert_eq!(short_name("cursor-grok-bot"), "Grok Bot");
    }
}
