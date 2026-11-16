//! What a front end has read from the Swift app's files, and the rule for
//! taking in a new read: a file that is missing or does not parse (a read
//! racing a write, a newer format) never erases what was last read
//! successfully. It is reported, the old data stays on screen, and the file is
//! read again on the next poll.
//!
//! This is the read-side twin of the Swift rule that a failed refresh never
//! overwrites the last successful snapshot.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use chrono::{DateTime, Utc};

use crate::bridge::DashboardState;
use crate::history::{LoadError, UsageHistory};
use crate::model::PeriodRow;
use crate::paths::{HISTORY_FILE, SNAPSHOT_FILE, STATE_FILE};
use crate::snapshot::Snapshot;

/// A file's identity for change detection: modification time and length.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub modified: SystemTime,
    pub len: u64,
}

impl Stamp {
    pub fn of(path: &Path) -> Option<Stamp> {
        let meta = std::fs::metadata(path).ok()?;
        Some(Stamp { modified: meta.modified().ok()?, len: meta.len() })
    }

    pub fn modified_utc(&self) -> DateTime<Utc> {
        self.modified.into()
    }
}

/// How one file stands after the latest poll.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum FileStatus {
    /// Not read yet.
    #[default]
    Pending,
    /// The data shown is this file's current content.
    Current,
    /// The file is not there (Netra has not run yet, or another data folder).
    Missing,
    /// The file is there but could not be read; older data may be shown.
    Unreadable(String),
}

/// One poll of the data folder: each file that changed since the last
/// successful read, read again. `None` means unchanged, so not read.
#[derive(Debug, Default)]
pub struct Reading {
    pub history: Option<(Option<Stamp>, Result<UsageHistory, LoadError>)>,
    pub snapshot: Option<(Option<Stamp>, Result<Snapshot, LoadError>)>,
    pub state: Option<(Option<Stamp>, Result<DashboardState, LoadError>)>,
}

/// The last good data from each file, plus how each file stands now.
#[derive(Debug, Clone, Default)]
pub struct Library {
    pub dir: PathBuf,
    /// Recorded days, oldest first.
    pub rows: Arc<Vec<PeriodRow>>,
    pub engine: Option<String>,
    pub complete_scan_at: Option<DateTime<Utc>>,
    pub snapshot: Option<Arc<Snapshot>>,
    pub history_status: FileStatus,
    pub snapshot_status: FileStatus,
    /// Stamps of the content currently held, to skip unchanged files.
    pub history_stamp: Option<Stamp>,
    pub snapshot_stamp: Option<Stamp>,
    /// The Swift app's preferences, accounts and status; `None` until the
    /// app has written them (an older Netra never does).
    pub state: Option<Arc<DashboardState>>,
    pub state_stamp: Option<Stamp>,
}

/// The stamps of the content a library holds, handed to `poll`.
#[derive(Debug, Clone, Copy, Default)]
pub struct Held {
    pub history: Option<Stamp>,
    pub snapshot: Option<Stamp>,
    pub state: Option<Stamp>,
}

impl Library {
    pub fn new(dir: PathBuf) -> Self {
        Library { dir, ..Default::default() }
    }

    pub fn history_path(&self) -> PathBuf {
        self.dir.join(HISTORY_FILE)
    }

    pub fn snapshot_path(&self) -> PathBuf {
        self.dir.join(SNAPSHOT_FILE)
    }

    /// Whether anything has ever been read successfully.
    pub fn has_data(&self) -> bool {
        !self.rows.is_empty() || self.snapshot.is_some()
    }

    /// Reads every file whose stamp differs from the content held, or that
    /// was not read successfully last time. Blocking: call it off the UI
    /// thread. Takes the paths and stamps, not `&self`, so it can run on a
    /// background thread while the UI keeps the library.
    pub fn held(&self) -> Held {
        Held { history: self.history_stamp, snapshot: self.snapshot_stamp, state: self.state_stamp }
    }

    pub fn poll(dir: &Path, held: Held) -> Reading {
        let read = |name: &str, held: Option<Stamp>| {
            let path = dir.join(name);
            let stamp = Stamp::of(&path);
            (stamp.is_none() || stamp != held).then_some((path, stamp))
        };
        Reading {
            history: read(HISTORY_FILE, held.history).map(|(p, s)| (s, UsageHistory::load(&p))),
            snapshot: read(SNAPSHOT_FILE, held.snapshot).map(|(p, s)| (s, Snapshot::load(&p))),
            state: read(STATE_FILE, held.state).map(|(p, s)| (s, DashboardState::load(&p))),
        }
    }

    /// Takes in a poll. Returns whether anything visible changed.
    pub fn apply(&mut self, reading: Reading) -> bool {
        let mut changed = false;
        if let Some((stamp, result)) = reading.history {
            changed |= match result {
                Ok(history) => {
                    self.rows = Arc::new(history.rows());
                    self.engine = history.engine;
                    self.complete_scan_at = history.complete_scan_at;
                    self.history_stamp = stamp;
                    set(&mut self.history_status, FileStatus::Current);
                    true
                }
                Err(error) => {
                    self.history_stamp = None;
                    set(&mut self.history_status, status_for(&error))
                }
            };
        }
        if let Some((stamp, result)) = reading.snapshot {
            changed |= match result {
                Ok(snapshot) => {
                    self.snapshot = Some(Arc::new(snapshot));
                    self.snapshot_stamp = stamp;
                    set(&mut self.snapshot_status, FileStatus::Current);
                    true
                }
                Err(error) => {
                    self.snapshot_stamp = None;
                    set(&mut self.snapshot_status, status_for(&error))
                }
            };
        }
        if let Some((stamp, result)) = reading.state {
            // A missing or half-written state keeps the last one, like the
            // other files; it carries no status of its own.
            match result {
                Ok(state) => {
                    self.state_stamp = stamp;
                    if self.state.as_deref() != Some(&state) {
                        self.state = Some(Arc::new(state));
                        changed = true;
                    }
                }
                Err(_) => self.state_stamp = None,
            }
        }
        changed
    }
}

fn status_for(error: &LoadError) -> FileStatus {
    match error {
        LoadError::Missing => FileStatus::Missing,
        other => FileStatus::Unreadable(other.to_string()),
    }
}

fn set(slot: &mut FileStatus, value: FileStatus) -> bool {
    let changed = *slot != value;
    *slot = value;
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("netra-core-library-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const HISTORY: &str = r#"{"days":{"2026-11-16":[{"name":"claude","cost":2,"totalTokens":20,"inputTokens":20,"outputTokens":0,"cacheReadTokens":0,"models":[]}]}}"#;

    #[test]
    fn a_broken_file_keeps_the_last_good_data_and_is_read_again() {
        let dir = temp_dir("broken");
        let mut library = Library::new(dir.clone());

        let first = Library::poll(&dir, Held::default());
        library.apply(first);
        assert_eq!(library.history_status, FileStatus::Missing);
        assert!(!library.has_data());

        std::fs::write(dir.join(HISTORY_FILE), HISTORY).unwrap();
        assert!(library.apply(Library::poll(&dir, library.held())));
        assert_eq!(library.rows.len(), 1);
        assert_eq!(library.history_status, FileStatus::Current);

        // Unchanged file: not read at all.
        let again = Library::poll(&dir, library.held());
        assert!(again.history.is_none());

        std::fs::write(dir.join(HISTORY_FILE), "{ half a wri").unwrap();
        library.apply(Library::poll(&dir, library.held()));
        assert!(matches!(library.history_status, FileStatus::Unreadable(_)));
        assert_eq!(library.rows.len(), 1, "the last good days stay");
        assert!(library.history_stamp.is_none(), "so the next poll reads it again");

        std::fs::remove_file(dir.join(HISTORY_FILE)).unwrap();
        library.apply(Library::poll(&dir, library.held()));
        assert_eq!(library.history_status, FileStatus::Missing);
        assert_eq!(library.rows.len(), 1, "a deleted file does not erase what was read");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
