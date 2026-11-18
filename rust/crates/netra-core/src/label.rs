//! What the menu-bar label shows, as text (Swift `MenuBarLabelModel.make`
//! in `MenuBarLabel.swift`). The Swift app draws the label; this port lets
//! the settings page say, item by item, what each one adds right now, or why
//! it adds nothing.

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc};

use crate::limits::{self, ProviderLimits};
use crate::model::{PeriodRow, UNATTRIBUTED};
use crate::snapshot::{QuotaWindow, Snapshot};
use crate::{format, palette};

/// "Follow whichever provider is nearest a limit".
pub const CLOSEST_SOURCE: &str = "closest";

/// The preferences the label's text depends on.
#[derive(Debug, Clone, PartialEq)]
pub struct LabelSettings {
    /// `closest` or a limit provider's agent name.
    pub limit_source: String,
    /// Percentages count what is left instead of what is used.
    pub show_remaining: bool,
    /// Providers hidden from the menu, lowercased.
    pub hidden_providers: Vec<String>,
    pub limit_order: Vec<String>,
}

impl Default for LabelSettings {
    fn default() -> Self {
        LabelSettings {
            limit_source: CLOSEST_SOURCE.into(),
            show_remaining: false,
            hidden_providers: Vec::new(),
            limit_order: limits::DEFAULT_ORDER.iter().map(|s| s.to_string()).collect(),
        }
    }
}

/// One label item resolved against the current data.
#[derive(Debug, Clone, PartialEq)]
pub struct ItemValue {
    /// What the item draws; `None` when it draws nothing right now.
    pub text: Option<String>,
    /// Why it draws nothing, in a sentence; `None` when it draws.
    pub reason: Option<String>,
    /// The provider a limit item read, and the title of its window.
    pub agent: Option<String>,
    pub window: Option<String>,
}

impl ItemValue {
    fn shown(text: String) -> Self {
        ItemValue { text: Some(text), reason: None, agent: None, window: None }
    }

    fn nothing(reason: impl Into<String>) -> Self {
        ItemValue { text: None, reason: Some(reason.into()), agent: None, window: None }
    }

    fn of(mut self, limits: &ProviderLimits, window: &QuotaWindow) -> Self {
        self.agent = Some(limits.agent.clone());
        self.window = Some(limits::title(&window.label));
        self
    }
}

/// The label's inputs, resolved once: who the limit items follow and the
/// data the cost items sum.
pub struct Label<'a> {
    settings: &'a LabelSettings,
    rows: &'a [PeriodRow],
    today: NaiveDate,
    now: DateTime<Utc>,
    /// The provider the limit items, the icon and the tint follow.
    pub source: Option<ProviderLimits>,
}

impl<'a> Label<'a> {
    pub fn new(
        settings: &'a LabelSettings,
        rows: &'a [PeriodRow],
        snapshot: Option<&Snapshot>,
        today: NaiveDate,
        now: DateTime<Utc>,
    ) -> Self {
        let source = snapshot.and_then(|s| limit_source(s, settings, now));
        Label { settings, rows, today, now, source }
    }

    /// The source's window closest to exhaustion: what the ring and the
    /// status tint follow.
    pub fn tightest(&self) -> Option<&QuotaWindow> {
        self.source.as_ref().and_then(|s| s.most_constrained())
    }

    /// The fill of the bars icon: the short window, then the most used of
    /// the rest. `None` without limits, when the eye stands in.
    pub fn bar_fractions(&self) -> Option<(f64, Option<f64>)> {
        let source = self.source.as_ref()?;
        let (top, bottom) = icon_windows(source)?;
        Some((self.shown(top) / 100.0, bottom.map(|w| self.shown(w) / 100.0)))
    }

    /// The fill of the ring icon; `None` without limits.
    pub fn ring_fraction(&self) -> Option<f64> {
        self.tightest().map(|w| self.shown(w) / 100.0)
    }

    /// The texts of `items`, in order, leaving out the ones that draw nothing.
    pub fn texts(&self, items: &[String]) -> Vec<String> {
        (0..items.len()).filter_map(|i| self.item(&items[i], &items[..i]).text).collect()
    }

    /// What `item` draws when it comes after `preceding` in the label.
    pub fn item(&self, item: &str, preceding: &[String]) -> ItemValue {
        match item {
            "todayCost" => self.cost(self.today, "today"),
            "weekCost" => {
                // Weeks start on Monday, as the app's week keys do.
                let monday = self.today - Duration::days(i64::from(self.today.weekday().num_days_from_monday()));
                self.cost(monday, "this week")
            }
            "monthCost" => self.cost(self.today.with_day(1).unwrap_or(self.today), "this month"),
            "todayTokens" => match self.usage_since(self.today).1 {
                0 => ItemValue::nothing("No tokens used today yet; it appears with the first usage."),
                tokens => ItemValue::shown(format::tokens(tokens)),
            },
            "limitPercent" | "sessionPercent" | "weeklyPercent" => {
                let Some(source) = &self.source else { return ItemValue::nothing(self.no_source()) };
                match limit_window(source, item) {
                    Some(window) => {
                        let prefix = match item {
                            "sessionPercent" => format!("{} ", short_length(window)),
                            "weeklyPercent" => "7d ".to_string(),
                            _ => String::new(),
                        };
                        ItemValue::shown(format!("{prefix}{}", self.percent(source, window))).of(source, window)
                    }
                    None => {
                        let kind = if item == "sessionPercent" { "session (5-hour)" } else { "weekly" };
                        let name = palette::short_name(&source.agent);
                        ItemValue::nothing(if self.settings.limit_source == CLOSEST_SOURCE {
                            format!("{name} is closest to a limit right now and has no {kind} window.")
                        } else {
                            format!("{name} has no {kind} window.")
                        })
                    }
                }
            }
            "resetCountdown" => {
                let Some(source) = &self.source else { return ItemValue::nothing(self.no_source()) };
                let Some(window) = countdown_window(source, preceding) else {
                    return ItemValue::nothing(self.no_source());
                };
                match window.resets_at.filter(|reset| *reset > self.now) {
                    Some(reset) => {
                        ItemValue::shown(limits::duration((reset - self.now).num_seconds() as f64)).of(source, window)
                    }
                    None => ItemValue::nothing(format!(
                        "{}'s {} window has no upcoming reset time.",
                        palette::short_name(&source.agent),
                        limits::title(&window.label).to_lowercase()
                    )),
                }
            }
            _ => ItemValue::nothing("Not a menu-bar item."),
        }
    }

    fn no_source(&self) -> String {
        if self.settings.limit_source == CLOSEST_SOURCE {
            "No provider is reporting limits right now.".into()
        } else {
            format!("{} isn't reporting limits right now.", palette::short_name(&self.settings.limit_source))
        }
    }

    /// Cost and tokens since `start`, without the hidden providers.
    fn usage_since(&self, start: NaiveDate) -> (f64, u64) {
        let hidden = &self.settings.hidden_providers;
        let visible = |name: &str| !hidden.iter().any(|h| *h == name.to_lowercase());
        self.rows
            .iter()
            .filter(|row| row.date >= start && row.date <= self.today)
            .flat_map(|row| row.parts())
            .filter(|part| visible(if part.name == UNATTRIBUTED { UNATTRIBUTED } else { &part.name }))
            .fold((0.0, 0), |sum, part| (sum.0 + part.cost, sum.1 + part.total_tokens))
    }

    fn cost(&self, start: NaiveDate, span: &str) -> ItemValue {
        let cost = self.usage_since(start).0;
        if cost > 0.0 {
            ItemValue::shown(format::cost(cost))
        } else {
            ItemValue::nothing(format!("No cost recorded {span} yet; it appears with the first usage."))
        }
    }

    /// The percentage as drawn: used, or left when the user counts down.
    /// An estimate has nothing "left", so it always reads as used.
    fn shown(&self, window: &QuotaWindow) -> f64 {
        let used = window.used_percent.clamp(0.0, 100.0);
        let estimate = self.source.as_ref().is_some_and(|s| s.is_estimate);
        if self.settings.show_remaining && !estimate { 100.0 - used } else { used }
    }

    fn percent(&self, source: &ProviderLimits, window: &QuotaWindow) -> String {
        let value = if source.is_estimate { window.used_percent.clamp(0.0, 999.0) } else { self.shown(window) };
        format!("{}%", round_half_away(value))
    }
}

/// Swift's `rounded()`: halves go away from zero.
fn round_half_away(value: f64) -> i64 {
    value.round() as i64
}

/// The provider whose limits the label reports: the chosen one, or the
/// visible provider closest to a limit. Claude's local estimate only stands
/// in when no real quota exists anywhere.
pub fn limit_source(snapshot: &Snapshot, settings: &LabelSettings, now: DateTime<Utc>) -> Option<ProviderLimits> {
    if settings.limit_source != CLOSEST_SOURCE {
        return limits::provider_limits(snapshot, &[settings.limit_source.as_str()], now).into_iter().next();
    }
    let order: Vec<&str> = settings.limit_order.iter().map(String::as_str).collect();
    let all: Vec<ProviderLimits> = limits::provider_limits(snapshot, &order, now)
        .into_iter()
        .filter(|l| !settings.hidden_providers.iter().any(|h| *h == l.agent.to_lowercase()))
        .collect();
    let any_real = all.iter().any(|l| !l.is_estimate);
    let used = |l: &ProviderLimits| l.most_constrained().map(|w| w.used_percent).unwrap_or(0.0);
    // The first of equals wins, as Swift's `max(by:)` does.
    all.into_iter().filter(|l| !any_real || !l.is_estimate).fold(
        None,
        |best: Option<ProviderLimits>, next| match best {
            Some(best) if used(&best) >= used(&next) => Some(best),
            _ => Some(next),
        },
    )
}

/// The window a percent item reads.
fn limit_window<'a>(limits: &'a ProviderLimits, item: &str) -> Option<&'a QuotaWindow> {
    match item {
        "sessionPercent" => session_window(limits),
        "weeklyPercent" => weekly_window(limits),
        _ => limits.most_constrained(),
    }
}

/// The window the countdown counts to: the one the nearest limit item
/// before it reads, or the tightest when none comes before it.
fn countdown_window<'a>(limits: &'a ProviderLimits, preceding: &[String]) -> Option<&'a QuotaWindow> {
    preceding
        .iter()
        .rev()
        .filter(|item| matches!(item.as_str(), "limitPercent" | "sessionPercent" | "weeklyPercent"))
        .find_map(|item| limit_window(limits, item))
        .or_else(|| limits.most_constrained())
}

/// The short (session) window: at most a day long.
pub fn session_window(limits: &ProviderLimits) -> Option<&QuotaWindow> {
    let length =
        |w: &QuotaWindow| w.duration_seconds.unwrap_or(if w.label == "5h" { 5.0 * 3600.0 } else { f64::INFINITY });
    limits.windows.iter().filter(|w| length(w) <= 86_400.0).fold(None, |best: Option<&QuotaWindow>, next| match best {
        Some(best) if best.duration_seconds.unwrap_or(0.0) <= next.duration_seconds.unwrap_or(0.0) => Some(best),
        _ => Some(next),
    })
}

/// The weekly window: about seven days long, or labelled weekly.
pub fn weekly_window(limits: &ProviderLimits) -> Option<&QuotaWindow> {
    limits.windows.iter().find(|w| match w.duration_seconds {
        Some(duration) => (6.0 * 86_400.0..=8.0 * 86_400.0).contains(&duration),
        None => w.label.starts_with("weekly"),
    })
}

/// Swift's `iconWindows`: the short window on top, the most used of the
/// rest below.
fn icon_windows(limits: &ProviderLimits) -> Option<(&QuotaWindow, Option<&QuotaWindow>)> {
    let length = |w: &QuotaWindow| w.duration_seconds.unwrap_or(f64::INFINITY);
    let top = limits.windows.iter().fold(None, |best: Option<&QuotaWindow>, next| match best {
        Some(best) if length(best) <= length(next) => Some(best),
        _ => Some(next),
    })?;
    let bottom =
        limits.windows.iter().filter(|w| *w != top).fold(None, |best: Option<&QuotaWindow>, next| match best {
            Some(best) if best.used_percent >= next.used_percent => Some(best),
            _ => Some(next),
        });
    Some((top, bottom))
}

fn short_length(window: &QuotaWindow) -> String {
    match window.duration_seconds {
        Some(duration) if duration >= 3600.0 => format!("{}h", (duration / 3600.0).round() as i64),
        _ => "5h".into(),
    }
}
