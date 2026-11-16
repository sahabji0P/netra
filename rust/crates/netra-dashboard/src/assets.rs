//! The window's icons, compiled into the binary so it has no resource
//! folder to lose. GPUI draws an SVG as a mask in the current text color, so
//! every file is a single-color shape. Provider marks are the ones the Swift
//! app ships (`ProviderLogo.swift` records where each came from).

use std::borrow::Cow;

use gpui::{AssetSource, Result, SharedString};

macro_rules! assets {
    ($($path:literal),* $(,)?) => {
        const ASSETS: &[(&str, &[u8])] = &[
            $(($path, include_bytes!(concat!("../assets/", $path)))),*
        ];
    };
}

assets![
    "icons/accounts.svg",
    "icons/bars.svg",
    "icons/bell.svg",
    "icons/check.svg",
    "icons/close.svg",
    "icons/dot.svg",
    "icons/down.svg",
    "icons/export.svg",
    "icons/eye.svg",
    "icons/gear.svg",
    "icons/import.svg",
    "icons/limits.svg",
    "icons/menubar.svg",
    "icons/moon.svg",
    "icons/plus.svg",
    "icons/providers.svg",
    "icons/refresh.svg",
    "icons/ring.svg",
    "icons/sliders.svg",
    "icons/swap.svg",
    "icons/up.svg",
    "icons/usage.svg",
    "icons/warning.svg",
    "providers/claude.svg",
    "providers/codex.svg",
    "providers/copilot.svg",
    "providers/cursor.svg",
    "providers/opencode.svg",
];

pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        Ok(ASSETS.iter().find(|(name, _)| *name == path).map(|(_, bytes)| Cow::Borrowed(*bytes)))
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        Ok(ASSETS.iter().filter(|(name, _)| name.starts_with(path)).map(|(name, _)| (*name).into()).collect())
    }
}

/// The mark file for a provider, when it has one.
pub fn provider_mark(agent: &str) -> Option<&'static str> {
    match agent.to_lowercase().as_str() {
        "claude" => Some("providers/claude.svg"),
        "codex" => Some("providers/codex.svg"),
        "cursor" | "cursor-grok-bot" => Some("providers/cursor.svg"),
        "copilot" => Some("providers/copilot.svg"),
        "opencode" => Some("providers/opencode.svg"),
        _ => None,
    }
}
