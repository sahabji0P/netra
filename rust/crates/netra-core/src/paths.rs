//! Where the Swift app keeps its files.

use std::path::PathBuf;

pub const HISTORY_FILE: &str = "usage-history.json";
pub const SNAPSHOT_FILE: &str = "snapshot.json";
/// The Swift app's mirror of preferences, accounts and status.
pub const STATE_FILE: &str = "dashboard-state.json";
/// Where the dashboard drops commands for the Swift app.
pub const COMMANDS_DIR: &str = "commands";

/// `NETRA_DATA_DIR` when set (fixtures, demos), otherwise the Swift app's
/// folder: `~/Library/Application Support/Netra` on macOS.
pub fn data_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("NETRA_DATA_DIR").filter(|d| !d.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(home.join("Library").join("Application Support").join("Netra"))
}
