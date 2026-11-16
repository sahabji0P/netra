//! The parts of `snapshot.json` the dashboard needs: when it was taken, the
//! active 5-hour block, and each provider's limit windows (Swift
//! `UsageSnapshot`, `ClaudeQuota`, `CodexQuota`, `CursorQuota`).
//!
//! Usage totals are *not* read from here: they come from the history file,
//! which the snapshot's `daily` rows are built from anyway. Unknown fields are
//! ignored and every block is optional, so a newer Swift app does not break
//! this reader. Account identifiers in the file are never decoded.

use std::path::Path;

use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::history::{LoadError, read_json};
use crate::time::apple_date;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    #[serde(with = "apple_date")]
    pub fetched_at: DateTime<Utc>,
    #[serde(default)]
    pub active_block: Option<BlockStat>,
    #[serde(default)]
    pub claude_quota: Option<ClaudeQuota>,
    #[serde(default)]
    pub codex_quota: Option<CodexQuota>,
    #[serde(default)]
    pub cursor_quota: Option<CursorQuota>,
}

impl Snapshot {
    pub fn load(path: &Path) -> Result<Self, LoadError> {
        read_json(path)
    }

    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub label: String,
    pub used_percent: f64,
    #[serde(default, with = "apple_date::option")]
    pub resets_at: Option<DateTime<Utc>>,
    /// The window's full length, when the source states it. Enables pace.
    #[serde(default)]
    pub duration_seconds: Option<f64>,
}

impl QuotaWindow {
    /// Fraction of the window already elapsed, or `None` without a length.
    pub fn elapsed_fraction(&self, now: DateTime<Utc>) -> Option<f64> {
        let duration = self.duration_seconds.filter(|d| *d > 0.0)?;
        let remaining = seconds_between(now, self.resets_at?);
        Some((1.0 - remaining / duration).clamp(0.0, 1.0))
    }
}

pub(crate) fn seconds_between(from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    (to - from).num_milliseconds() as f64 / 1000.0
}

/// A window without a reset time is shown only this long after it was seen.
const UNDATED_WINDOW_FRESHNESS: f64 = 60.0 * 60.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ClaudeSource {
    #[default]
    Oauth,
    ClaudeCodeCache,
    LastSeen,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeQuota {
    pub windows: Vec<QuotaWindow>,
    #[serde(default)]
    pub subscription_type: Option<String>,
    #[serde(with = "apple_date")]
    pub fetched_at: DateTime<Utc>,
    #[serde(default)]
    pub source: ClaudeSource,
    #[serde(default)]
    pub extra_usage: Option<ClaudeExtraUsage>,
}

impl ClaudeQuota {
    /// Windows that have not reset yet; undated ones only while fresh.
    pub fn active_windows(&self, now: DateTime<Utc>) -> Vec<QuotaWindow> {
        self.windows
            .iter()
            .filter(|w| match w.resets_at {
                Some(reset) => reset > now,
                None => seconds_between(self.fetched_at, now) <= UNDATED_WINDOW_FRESHNESS,
            })
            .cloned()
            .collect()
    }
}

/// Anthropic's extra-usage credits (Swift `ClaudeExtraUsage`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeExtraUsage {
    pub is_enabled: bool,
    #[serde(default, rename = "usedUSD")]
    pub used_usd: Option<f64>,
    #[serde(default, rename = "monthlyLimitUSD")]
    pub monthly_limit_usd: Option<f64>,
    #[serde(default)]
    pub disabled_reason: Option<String>,
    #[serde(default)]
    pub ever_enabled: bool,
}

impl ClaudeExtraUsage {
    /// One line for the limit card, or `None` when there is nothing to say.
    pub fn summary(&self) -> Option<String> {
        use crate::format::cost;
        if self.is_enabled {
            let used = self.used_usd.map(cost).unwrap_or_else(|| "$0.00".into());
            return Some(match self.monthly_limit_usd {
                Some(limit) => format!("Extra usage on · {used} of {} this month", cost(limit)),
                None => format!("Extra usage on · {used} used this month"),
            });
        }
        if !self.ever_enabled {
            return None;
        }
        Some(if self.disabled_reason.as_deref() == Some("out_of_credits") {
            "Extra usage credits used up".into()
        } else {
            "Extra usage off".into()
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CodexSource {
    Live,
    SessionLog,
    LastSeen,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitResetCredit {
    #[serde(default)]
    pub title: Option<String>,
    /// `None` means it does not expire.
    #[serde(default, with = "apple_date::option")]
    pub expires_at: Option<DateTime<Utc>>,
}

impl LimitResetCredit {
    pub fn is_available(&self, now: DateTime<Utc>) -> bool {
        self.expires_at.is_none_or(|e| e > now)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexQuota {
    pub windows: Vec<QuotaWindow>,
    #[serde(default)]
    pub plan_type: Option<String>,
    #[serde(default, with = "apple_date::option")]
    pub observed_at: Option<DateTime<Utc>>,
    /// Unknown future sources decode as `None` rather than failing the file.
    #[serde(default, deserialize_with = "lenient_codex_source")]
    pub source: Option<CodexSource>,
    #[serde(default)]
    pub limit_reached_type: Option<String>,
    #[serde(default)]
    pub reset_credits_available: Option<u32>,
    #[serde(default)]
    pub reset_credits: Option<Vec<LimitResetCredit>>,
}

fn lenient_codex_source<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<CodexSource>, D::Error> {
    let raw = Option::<String>::deserialize(d)?;
    Ok(raw.and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok()))
}

impl CodexQuota {
    pub fn active_windows(&self, now: DateTime<Utc>) -> Vec<QuotaWindow> {
        self.windows
            .iter()
            .filter(|w| match (w.resets_at, self.observed_at) {
                (Some(reset), _) => reset > now,
                (None, Some(seen)) if seen <= now => seconds_between(seen, now) <= UNDATED_WINDOW_FRESHNESS,
                (None, _) => false,
            })
            .cloned()
            .collect()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorQuota {
    pub windows: Vec<QuotaWindow>,
    #[serde(default)]
    pub plan_type: Option<String>,
    #[serde(with = "apple_date")]
    pub fetched_at: DateTime<Utc>,
}

impl CursorQuota {
    pub fn active_windows(&self, now: DateTime<Utc>) -> Vec<QuotaWindow> {
        self.windows.iter().filter(|w| w.resets_at.is_none_or(|r| r > now)).cloned().collect()
    }
}

/// The active 5-hour billing block, estimated locally by ccusage.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockStat {
    #[serde(with = "apple_date")]
    pub start: DateTime<Utc>,
    #[serde(with = "apple_date")]
    pub end: DateTime<Utc>,
    pub tokens: u64,
    pub cost: f64,
    pub projected_cost: f64,
    pub percent_used: f64,
}
