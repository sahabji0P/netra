//! Netra's usage model with no UI and no macOS API: the recorded usage
//! history, the limit windows in the last snapshot, and the sums and text
//! rules every view shows.
//!
//! This crate *reads* what the Swift app writes (`usage-history.json`,
//! `snapshot.json`, `dashboard-state.json`) and writes only command files
//! for it (`bridge`). The rules are ports of the Swift ones named in each
//! module, so both front ends show the same numbers.

pub mod aggregate;
pub mod bridge;
pub mod format;
pub mod history;
pub mod label;
pub mod library;
pub mod limits;
pub mod model;
pub mod palette;
pub mod paths;
pub mod snapshot;
pub mod time;

pub use aggregate::{ModelRow, Selection, UsageRange};
pub use bridge::DashboardState;
pub use history::UsageHistory;
pub use library::{FileStatus, Library};
pub use limits::ProviderLimits;
pub use model::{AgentStat, ModelStat, PeriodRow};
pub use snapshot::Snapshot;
