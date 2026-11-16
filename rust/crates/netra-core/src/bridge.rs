//! The bridge to the Swift menu-bar app (see `docs/dashboard-bridge.md`).
//!
//! Reading: `dashboard-state.json`, which mirrors the app's preferences,
//! managed accounts and status. Writing: one small JSON file per command in
//! `commands/`. That folder is the only place this crate ever writes; the
//! Swift app stays the single writer of usage, preferences and sign-ins, and
//! no secret travels in either direction.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value, json};

use crate::history::LoadError;
use crate::paths::COMMANDS_DIR;
use crate::snapshot::QuotaWindow;

/// Everything the Swift app mirrors for the dashboard. Every field is
/// optional in the file, so an older or newer app never breaks the read.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DashboardState {
    pub version: u32,
    #[serde(deserialize_with = "iso_date")]
    pub written_at: Option<DateTime<Utc>>,
    pub app: AppStatus,
    /// Kept as loose JSON and read through `Preferences`' typed getters, so
    /// a key this build does not know is carried, not dropped.
    pub preferences: Preferences,
    pub periods: Vec<PeriodOption>,
    pub accounts: Accounts,
    pub navigate: Option<Navigate>,
    pub results: Vec<CommandResult>,
}

impl DashboardState {
    pub fn load(path: &Path) -> Result<Self, LoadError> {
        let text = std::fs::read_to_string(path).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => LoadError::Missing,
            _ => LoadError::Io(e),
        })?;
        Self::from_json(&text).map_err(LoadError::Decode)
    }

    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    pub fn result(&self, id: &str) -> Option<&CommandResult> {
        self.results.iter().find(|r| r.id == id)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppStatus {
    pub version: Option<String>,
    pub pid: Option<u32>,
    pub refreshing: bool,
    pub last_error: Option<String>,
    pub launch_at_login: bool,
    pub launch_at_login_available: bool,
    /// "allowed" | "denied" | "notDetermined" | "checking".
    pub notifications: String,
    pub claude_keychain_needs_approval: bool,
    pub update_available: Option<String>,
    pub website: WebsiteStatus,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebsiteStatus {
    pub token_saved: bool,
    pub publishing: bool,
    pub status: Option<String>,
    pub token_error: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct PeriodOption {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Navigate {
    pub page: String,
    pub nonce: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct CommandResult {
    pub id: String,
    pub command: String,
    pub ok: bool,
    pub message: Option<String>,
}

/// The preferences object, as loose JSON with typed readers.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(transparent)]
pub struct Preferences(pub Map<String, Value>);

impl Preferences {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }

    pub fn bool(&self, key: &str, default: bool) -> bool {
        self.get(key).and_then(Value::as_bool).unwrap_or(default)
    }

    pub fn number(&self, key: &str, default: f64) -> f64 {
        self.get(key).and_then(Value::as_f64).unwrap_or(default)
    }

    pub fn string(&self, key: &str, default: &str) -> String {
        self.get(key).and_then(Value::as_str).unwrap_or(default).to_string()
    }

    pub fn strings(&self, key: &str) -> Vec<String> {
        self.get(key)
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
            .unwrap_or_default()
    }

    pub fn set(&mut self, key: &str, value: Value) {
        self.0.insert(key.to_string(), value);
    }
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Accounts {
    pub providers: Vec<AccountProvider>,
    pub notice: Option<AccountNotice>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountProvider {
    /// "claude" | "codex".
    pub provider: String,
    pub managing: bool,
    pub live: Option<LiveIdentity>,
    pub live_is_saved: bool,
    pub switching: bool,
    pub pending_sign_in: bool,
    pub note: Option<String>,
    pub accounts: Vec<Account>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LiveIdentity {
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub organization: Option<String>,
    pub plan: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Account {
    /// Netra's own roster id; never a provider's account id.
    pub id: String,
    pub title: String,
    pub email: Option<String>,
    pub plan: Option<String>,
    pub organization: Option<String>,
    pub initials: String,
    pub active: bool,
    /// "signInAgain" | "deactivated".
    pub attention: Option<String>,
    #[serde(deserialize_with = "iso_date")]
    pub last_active_at: Option<DateTime<Utc>>,
    pub limits: Option<AccountLimits>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountLimits {
    #[serde(deserialize_with = "iso_date")]
    pub observed_at: Option<DateTime<Utc>>,
    pub is_live: bool,
    pub windows: Vec<AccountWindow>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountWindow {
    pub label: String,
    pub used_percent: f64,
    #[serde(deserialize_with = "iso_date")]
    pub resets_at: Option<DateTime<Utc>>,
    pub duration_seconds: Option<f64>,
}

impl AccountWindow {
    /// The same shape the limit rules (`limits::pace`, `limits::amount`) take.
    pub fn quota_window(&self) -> QuotaWindow {
        QuotaWindow {
            label: self.label.clone(),
            used_percent: self.used_percent,
            resets_at: self.resets_at,
            duration_seconds: self.duration_seconds,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountNotice {
    pub id: String,
    pub provider: String,
    pub title: String,
    pub detail: Option<String>,
    pub is_error: bool,
}

/// ISO 8601 with or without fractional seconds; anything else reads as none.
fn iso_date<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
    let text = Option::<String>::deserialize(d)?;
    Ok(text.and_then(|t| DateTime::parse_from_rfc3339(&t).ok()).map(|d| d.with_timezone(&Utc)))
}

// MARK: Commands

static COMMAND_COUNTER: AtomicU64 = AtomicU64::new(0);

/// An id no other command from this or another process will carry: the
/// clock, the process and a counter. It is only ever compared for equality.
fn command_id() -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let count = COMMAND_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{nanos:x}-{:x}-{count:x}", std::process::id())
}

/// The JSON of one command file.
pub fn command_json(id: &str, command: &str, args: Value, now: DateTime<Utc>) -> Value {
    json!({
        "id": id,
        "command": command,
        "at": now.to_rfc3339_opts(SecondsFormat::Millis, true),
        "args": args,
    })
}

/// Drops a command for the Swift app and returns its id. The file is written
/// under a temporary name and renamed, so the app never reads half of it.
pub fn send_command(dir: &Path, command: &str, args: Value) -> std::io::Result<String> {
    let id = command_id();
    let folder = dir.join(COMMANDS_DIR);
    std::fs::create_dir_all(&folder)?;
    let body = serde_json::to_vec(&command_json(&id, command, args, Utc::now()))?;
    let temporary: PathBuf = folder.join(format!("{id}.json.tmp"));
    std::fs::write(&temporary, body)?;
    std::fs::rename(&temporary, folder.join(format!("{id}.json")))?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_lands_as_one_whole_file() {
        let dir = std::env::temp_dir().join(format!("netra-core-bridge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let id = send_command(&dir, "preference.set", json!({ "key": "showsPace", "value": false })).unwrap();
        let files: Vec<_> =
            std::fs::read_dir(dir.join(COMMANDS_DIR)).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(files, vec![std::ffi::OsString::from(format!("{id}.json"))]);
        let text = std::fs::read_to_string(dir.join(COMMANDS_DIR).join(format!("{id}.json"))).unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["command"], "preference.set");
        assert_eq!(value["args"]["key"], "showsPace");
        assert_eq!(value["id"], id.as_str());
        assert!(DateTime::parse_from_rfc3339(value["at"].as_str().unwrap()).is_ok());
        let second = send_command(&dir, "refresh", json!({})).unwrap();
        assert_ne!(id, second);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
