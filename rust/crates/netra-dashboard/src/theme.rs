//! Color tokens for each macOS appearance. Views ask for `Theme::of(window)`
//! on every render, so a switch between light and dark is picked up as soon
//! as the root view re-renders (it observes the window's appearance).
//!
//! The chrome is neutral on purpose: color belongs to the data (a provider's
//! identity, a limit running out), so no page tint competes with it.

use gpui::{Hsla, Rgba, Window, WindowAppearance, rgb};
use netra_core::aggregate::TokenPart;
use netra_core::palette;

#[derive(Debug, Clone, Copy)]
pub struct Theme {
    pub dark: bool,
    /// The page behind everything.
    pub background: Rgba,
    pub sidebar: Rgba,
    /// Panels and tiles.
    pub surface: Rgba,
    /// Controls inside a panel: segmented tracks, bar tracks.
    pub well: Rgba,
    pub border: Rgba,
    pub text: Rgba,
    pub muted: Rgba,
    pub faint: Rgba,
    /// Links and the focus of attention; used sparingly.
    pub accent: Rgba,
    /// Fill of a primary button, and the text on it.
    pub primary: Rgba,
    pub on_primary: Rgba,
    pub good: Rgba,
    pub bad: Rgba,
    pub warning: Rgba,
}

impl Theme {
    pub fn of(window: &Window) -> Theme {
        // `NETRA_APPEARANCE=light|dark` pins the colors, to check one
        // appearance without changing the system setting.
        match std::env::var("NETRA_APPEARANCE").as_deref() {
            Ok("light") => return Self::LIGHT,
            Ok("dark") => return Self::DARK,
            _ => {}
        }
        match window.appearance() {
            WindowAppearance::Dark | WindowAppearance::VibrantDark => Self::DARK,
            WindowAppearance::Light | WindowAppearance::VibrantLight => Self::LIGHT,
        }
    }

    const LIGHT: Theme = Theme {
        dark: false,
        background: hex(0xF7F7F5),
        sidebar: hex(0xEFEFEC),
        surface: hex(0xFFFFFF),
        well: hex(0xECECE8),
        border: hex(0xE1E1DC),
        text: hex(0x1B1B1A),
        muted: hex(0x6A6A66),
        faint: hex(0x9C9C97),
        accent: hex(0x0A6CFF),
        primary: hex(0x1B1B1A),
        on_primary: hex(0xFFFFFF),
        good: hex(0x1F8A3F),
        bad: hex(0xD03B3B),
        warning: hex(0xB86200),
    };

    const DARK: Theme = Theme {
        dark: true,
        background: hex(0x131315),
        sidebar: hex(0x19191C),
        surface: hex(0x1C1C20),
        well: hex(0x2A2A2F),
        border: hex(0x2C2C31),
        text: hex(0xF2F2F3),
        muted: hex(0xA0A0A8),
        faint: hex(0x686870),
        accent: hex(0x4C9BFF),
        primary: hex(0xF2F2F3),
        on_primary: hex(0x131315),
        good: hex(0x30D158),
        bad: hex(0xFF5A52),
        warning: hex(0xFF9F0A),
    };

    /// A provider's identity color in this appearance.
    pub fn provider(&self, agent: &str) -> Rgba {
        rgb(palette::color(agent).pick(self.dark))
    }

    pub fn token_part(&self, part: TokenPart) -> Rgba {
        match part {
            TokenPart::CacheReads => rgb(0x3887E6),
            TokenPart::UncachedInput => rgb(0x8E8E93),
            TokenPart::CacheWrites => rgb(0xEDA100),
            TokenPart::Output => rgb(0x33B373),
            TokenPart::Other => rgb(if self.dark { 0xBF5AF2 } else { 0xAF52DE }),
        }
    }

    /// The number on a limit row turns red once a window is nearly used up;
    /// the bar keeps the provider color, so color never means two things.
    pub fn limit_amount(&self, used_percent: f64) -> Rgba {
        if used_percent >= 90.0 { self.bad } else { self.text }
    }

    /// Good below 75% used, amber from there, red from 90%.
    pub fn status(&self, used_percent: f64) -> Rgba {
        if used_percent >= 90.0 {
            self.bad
        } else if used_percent >= 75.0 {
            self.warning
        } else {
            self.good
        }
    }

    pub fn hairline(&self) -> Hsla {
        alpha(self.border, if self.dark { 0.9 } else { 1.0 })
    }
}

const fn hex(value: u32) -> Rgba {
    Rgba {
        r: ((value >> 16) & 0xFF) as f32 / 255.0,
        g: ((value >> 8) & 0xFF) as f32 / 255.0,
        b: (value & 0xFF) as f32 / 255.0,
        a: 1.0,
    }
}

/// The same color at a lower opacity, for tints and hover fills.
pub fn alpha(color: Rgba, a: f32) -> Hsla {
    let mut hsla: Hsla = color.into();
    hsla.a = a;
    hsla
}
