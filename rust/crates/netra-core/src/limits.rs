//! Every provider's limit windows normalized for display, and the text rules
//! for them (Swift `ProviderLimits` and `LimitText` in `LimitSummary.swift`).

use chrono::{DateTime, Local, Utc};

use crate::format;
use crate::snapshot::{ClaudeSource, CodexSource, LimitResetCredit, QuotaWindow, Snapshot, seconds_between};

/// Cursor's Grok Bot allowance is its own provider with its own card.
pub const GROK_BOT_AGENT: &str = "cursor-grok-bot";
const GROK_WINDOW_LABEL: &str = "Grok Bot";

/// Provider order when the user has not chosen one (Swift's
/// `AppPreferences.limitProviders`). The user's custom order is a Swift
/// preference this crate does not read yet.
pub const DEFAULT_ORDER: [&str; 4] = ["claude", "codex", "cursor", GROK_BOT_AGENT];

#[derive(Debug, Clone, PartialEq)]
pub struct ProviderLimits {
    pub agent: String,
    pub plan: Option<String>,
    /// Where the numbers come from, e.g. "Reported by Anthropic".
    pub source: &'static str,
    pub observed_at: Option<DateTime<Utc>>,
    pub windows: Vec<QuotaWindow>,
    /// A local estimate (Claude's 5h block vs your peak), not a real quota.
    pub is_estimate: bool,
    pub note: Option<String>,
    /// Banked resets the account can redeem, soonest expiry first.
    pub reset_credit_expiries: Vec<Option<DateTime<Utc>>>,
    pub reset_credit_count: u32,
}

impl ProviderLimits {
    fn new(agent: &str, source: &'static str, observed_at: Option<DateTime<Utc>>, windows: Vec<QuotaWindow>) -> Self {
        ProviderLimits {
            agent: agent.into(),
            plan: None,
            source,
            observed_at,
            windows,
            is_estimate: false,
            note: None,
            reset_credit_expiries: Vec::new(),
            reset_credit_count: 0,
        }
    }

    /// The server may cap the detail list, so the reported count wins when larger.
    pub fn banked_reset_count(&self) -> u32 {
        (self.reset_credit_expiries.len() as u32).max(self.reset_credit_count)
    }

    /// The window closest to exhaustion.
    pub fn most_constrained(&self) -> Option<&QuotaWindow> {
        self.windows.iter().max_by(|a, b| a.used_percent.total_cmp(&b.used_percent))
    }
}

/// Providers with limit data in the snapshot, in `order`.
pub fn provider_limits(snapshot: &Snapshot, order: &[&str], now: DateTime<Utc>) -> Vec<ProviderLimits> {
    order
        .iter()
        .filter_map(|agent| match *agent {
            "claude" => claude(snapshot, now),
            "codex" => codex(snapshot, now),
            "cursor" => cursor(snapshot, now, false),
            GROK_BOT_AGENT => cursor(snapshot, now, true),
            _ => None,
        })
        .collect()
}

fn claude(snapshot: &Snapshot, now: DateTime<Utc>) -> Option<ProviderLimits> {
    if let Some(quota) = &snapshot.claude_quota {
        let windows = quota.active_windows(now);
        if !windows.is_empty() {
            let source = match quota.source {
                ClaudeSource::Oauth => "Reported by Anthropic",
                ClaudeSource::ClaudeCodeCache => "Via Claude Code",
                ClaudeSource::LastSeen => "Last seen",
            };
            let mut limits = ProviderLimits::new("claude", source, Some(quota.fetched_at), windows);
            limits.plan = quota.subscription_type.clone();
            limits.note = quota.extra_usage.as_ref().and_then(|e| e.summary());
            return Some(limits);
        }
    }
    let block = snapshot.active_block.as_ref().filter(|b| b.end > now)?;
    let mut limits = ProviderLimits::new(
        "claude",
        "Local estimate",
        Some(snapshot.fetched_at),
        vec![QuotaWindow {
            label: "5h block vs your peak".into(),
            used_percent: block.percent_used,
            resets_at: Some(block.end),
            duration_seconds: Some(5.0 * 3600.0),
        }],
    );
    limits.is_estimate = true;
    Some(limits)
}

fn codex(snapshot: &Snapshot, now: DateTime<Utc>) -> Option<ProviderLimits> {
    let quota = snapshot.codex_quota.as_ref()?;
    let windows = quota.active_windows(now);
    if windows.is_empty() {
        return None;
    }
    let source = match quota.source {
        Some(CodexSource::Live) => "Reported by OpenAI",
        Some(CodexSource::LastSeen) => "Last seen",
        _ => "Last Codex session",
    };
    let mut limits = ProviderLimits::new("codex", source, quota.observed_at, windows);
    limits.plan = quota.plan_type.clone();
    limits.note = quota.limit_reached_type.as_ref().map(|reached| {
        if reached.contains("credits_depleted") { "Workspace credits used up".into() } else { "Limit reached".into() }
    });
    let mut credits: Vec<&LimitResetCredit> =
        quota.reset_credits.iter().flatten().filter(|c| c.is_available(now)).collect();
    credits.sort_by_key(|c| c.expires_at.unwrap_or(DateTime::<Utc>::MAX_UTC));
    limits.reset_credit_expiries = credits.iter().map(|c| c.expires_at).collect();
    limits.reset_credit_count = quota.reset_credits_available.unwrap_or(0);
    Some(limits)
}

/// Cursor's plan windows, or (with `grok`) Grok Bot's weekly window alone.
fn cursor(snapshot: &Snapshot, now: DateTime<Utc>, grok: bool) -> Option<ProviderLimits> {
    let quota = snapshot.cursor_quota.as_ref()?;
    let windows: Vec<QuotaWindow> = quota
        .active_windows(now)
        .into_iter()
        .filter(|w| (w.label == GROK_WINDOW_LABEL) == grok)
        .map(|mut w| {
            if grok {
                w.label = "weekly".into();
            }
            w
        })
        .collect();
    if windows.is_empty() {
        return None;
    }
    let agent = if grok { GROK_BOT_AGENT } else { "cursor" };
    let mut limits = ProviderLimits::new(agent, "Reported by Cursor", Some(quota.fetched_at), windows);
    if !grok {
        limits.plan = quota.plan_type.clone();
    }
    Some(limits)
}

// MARK: - Text

pub fn title(label: &str) -> String {
    match label {
        "5h" => "Session · 5h".into(),
        "included usage" => "Included usage".into(),
        "auto models" => "Auto models".into(),
        "on-demand spend" => "On-demand spend".into(),
        _ => {
            if let Some(hours) = label.strip_suffix('h').and_then(|h| h.parse::<u32>().ok()) {
                return format!("{hours}-hour");
            }
            capitalize_first(label)
        }
    }
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
}

/// "54% used" or "46% left"; estimates past 100% read as a multiplier.
pub fn amount(window: &QuotaWindow, show_remaining: bool, is_estimate: bool) -> String {
    if is_estimate {
        return format!("{} of peak", format::peak_percent(window.used_percent));
    }
    let used = window.used_percent.clamp(0.0, 100.0);
    if show_remaining {
        format!("{}% left", (100.0 - used).round() as i64)
    } else {
        format!("{}% used", used.round() as i64)
    }
}

/// "3h 48m", "2d 4h", "12m"; never less than a minute.
pub fn duration(seconds: f64) -> String {
    let minutes = ((seconds / 60.0) as i64).max(1);
    if minutes < 60 {
        return format!("{minutes}m");
    }
    let hours = minutes / 60;
    if hours < 24 {
        return if minutes % 60 == 0 { format!("{hours}h") } else { format!("{hours}h {}m", minutes % 60) };
    }
    let days = hours / 24;
    if hours % 24 == 0 { format!("{days}d") } else { format!("{days}d {}h", hours % 24) }
}

/// "Resets in 3h 48m".
pub fn reset_countdown(resets_at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    format!("Resets in {}", duration(seconds_between(now, resets_at)))
}

/// The local clock time a window resets: "6:30 PM", "Fri 9:00 AM", "28 Nov 9:00 AM".
pub fn reset_clock(resets_at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let local = resets_at.with_timezone(&Local);
    let time = local.format("%-I:%M %p").to_string();
    if local.date_naive() == now.with_timezone(&Local).date_naive() {
        return time;
    }
    let day = if seconds_between(now, resets_at) < 6.0 * 86_400.0 {
        local.format("%a").to_string()
    } else {
        local.format("%-d %b").to_string()
    };
    format!("{day} {time}")
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Pace {
    Exhausted,
    OnPace,
    Ahead { points: i64, runs_out_in: Option<f64> },
    Behind { points: i64 },
}

/// Compares usage with an even burn across the window. `None` when the length
/// is unknown, too little has elapsed to judge, or nothing is used yet.
pub fn pace(window: &QuotaWindow, now: DateTime<Utc>) -> Option<Pace> {
    let elapsed = window.elapsed_fraction(now).filter(|e| *e >= 0.05)?;
    let duration = window.duration_seconds?;
    let resets_at = window.resets_at?;
    let used = window.used_percent.clamp(0.0, 100.0);
    if used >= 100.0 {
        return Some(Pace::Exhausted);
    }
    if used < 1.0 {
        return None;
    }
    let delta = used - elapsed * 100.0;
    if delta.abs() < 5.0 {
        return Some(Pace::OnPace);
    }
    if delta < 0.0 {
        return Some(Pace::Behind { points: (-delta).round() as i64 });
    }
    let rate = used / (elapsed * duration);
    let until_empty = (rate > 0.0).then(|| (100.0 - used) / rate);
    let remaining = seconds_between(now, resets_at);
    Some(Pace::Ahead { points: delta.round() as i64, runs_out_in: until_empty.filter(|u| *u < remaining) })
}

pub fn pace_text(pace: Pace) -> String {
    match pace {
        Pace::Exhausted => "Limit reached".into(),
        Pace::OnPace => "On pace".into(),
        Pace::Behind { points } => format!("{points}% under pace"),
        Pace::Ahead { points, runs_out_in: Some(t) } => format!("{points}% ahead · runs out in ~{}", duration(t)),
        Pace::Ahead { points, runs_out_in: None } => format!("{points}% ahead of pace"),
    }
}

/// Whether a pace needs attention: the limit is reached, or it will run out
/// before the window resets.
pub fn needs_attention(pace: Option<Pace>) -> bool {
    matches!(pace, Some(Pace::Exhausted) | Some(Pace::Ahead { runs_out_in: Some(_), .. }))
}

/// "3 banked resets · next expires in 12d".
pub fn banked_resets(limits: &ProviderLimits, now: DateTime<Utc>) -> Option<String> {
    let count = limits.banked_reset_count();
    if count == 0 {
        return None;
    }
    let noun = if count == 1 { "banked reset" } else { "banked resets" };
    match limits.reset_credit_expiries.first().copied().flatten() {
        Some(soonest) => Some(format!("{count} {noun} · next expires in {}", duration(seconds_between(now, soonest)))),
        None => Some(format!("{count} {noun}")),
    }
}
