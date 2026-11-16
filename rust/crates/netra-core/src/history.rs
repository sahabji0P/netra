//! `usage-history.json`: Netra's own per-day, per-agent record of usage
//! (Swift `UsageHistory` in `UsageLedger.swift`).
//!
//! This crate only reads the file. The Swift app owns writing it, and its rule
//! (a reading may raise or reprice a day, never lower or drop it) stays there
//! until the engine itself moves.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::model::{AgentStat, PeriodRow};
use crate::time::{apple_date, parse_day};

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageHistory {
    /// Local day (`yyyy-MM-dd`) to that day's usage per agent.
    #[serde(default)]
    pub days: BTreeMap<String, Vec<AgentStat>>,
    /// The ccusage version behind the last complete scan.
    #[serde(default)]
    pub engine: Option<String>,
    #[serde(default, with = "apple_date::option")]
    pub complete_scan_at: Option<DateTime<Utc>>,
}

#[derive(Debug)]
pub enum LoadError {
    Missing,
    Io(std::io::Error),
    Decode(serde_json::Error),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::Missing => write!(f, "file not found"),
            LoadError::Io(e) => write!(f, "{e}"),
            LoadError::Decode(e) => write!(f, "unreadable JSON: {e}"),
        }
    }
}

impl std::error::Error for LoadError {}

pub(crate) fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, LoadError> {
    let bytes = std::fs::read(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => LoadError::Missing,
        _ => LoadError::Io(e),
    })?;
    serde_json::from_slice(&bytes).map_err(LoadError::Decode)
}

impl UsageHistory {
    pub fn load(path: &Path) -> Result<Self, LoadError> {
        read_json(path)
    }

    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Every recorded day, oldest first. Keys that are not days are skipped,
    /// as the Swift app does.
    pub fn rows(&self) -> Vec<PeriodRow> {
        // BTreeMap order on `yyyy-MM-dd` keys is already chronological.
        self.days
            .iter()
            .filter_map(|(key, agents)| parse_day(key).map(|date| PeriodRow::from_parts(key.clone(), date, agents)))
            .collect()
    }
}
