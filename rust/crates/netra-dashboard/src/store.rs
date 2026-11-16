//! The one entity every page observes: what was read from the Swift app's
//! data folder, kept current by polling the files' stamps, plus the commands
//! this window has sent and is waiting to hear back about.
//!
//! Reading and parsing run on the background executor; only the cheap swap
//! of the result happens on the main thread. Polling (not FSEvents) keeps this
//! portable and costs three `stat` calls per tick.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use gpui::{App, AppContext, Context, Entity, Task};
use netra_core::Library;
use netra_core::bridge::{self, DashboardState, Preferences};
use serde_json::{Value, json};

const POLL_INTERVAL: Duration = Duration::from_secs(2);
/// After a command the answer is expected at once, so look more often.
const FAST_POLL_INTERVAL: Duration = Duration::from_millis(150);
/// A command the Swift app has not answered by now never will be.
const COMMAND_TIMEOUT: Duration = Duration::from_secs(6);
const TOAST_LIFETIME: Duration = Duration::from_secs(5);

struct Pending {
    id: String,
    sent_at: Instant,
    /// The preference this command set, shown ahead of the app's answer.
    preference: Option<String>,
    /// Say so when it worked, not only when it failed.
    announce: bool,
}

#[derive(Clone)]
pub struct Toast {
    pub text: String,
    pub is_error: bool,
    pub shown_at: Instant,
}

pub struct UsageStore {
    pub library: Library,
    /// Preference values set here that the app has not confirmed yet.
    overrides: HashMap<String, Value>,
    pending: Vec<Pending>,
    pub toasts: Vec<Toast>,
    _watch: Task<()>,
}

impl UsageStore {
    pub fn new(dir: PathBuf, cx: &mut App) -> Entity<Self> {
        cx.new(|cx: &mut Context<Self>| {
            let watch = cx.spawn(async move |this, cx| {
                loop {
                    let Ok((dir, held)) =
                        this.read_with(cx, |store, _| (store.library.dir.clone(), store.library.held()))
                    else {
                        return;
                    };
                    let reading = cx.background_executor().spawn(async move { Library::poll(&dir, held) }).await;
                    let Ok(busy) = this.update(cx, |store, cx| {
                        let mut changed = store.library.apply(reading);
                        changed |= store.settle();
                        if changed {
                            cx.notify();
                        }
                        !store.pending.is_empty() || !store.toasts.is_empty()
                    }) else {
                        return;
                    };
                    cx.background_executor().timer(if busy { FAST_POLL_INTERVAL } else { POLL_INTERVAL }).await;
                }
            });
            UsageStore {
                library: Library::new(dir),
                overrides: HashMap::new(),
                pending: Vec::new(),
                toasts: Vec::new(),
                _watch: watch,
            }
        })
    }

    pub fn state(&self) -> Option<&DashboardState> {
        self.library.state.as_deref()
    }

    /// Whether the Swift app has published its state, so settings can be shown.
    pub fn connected(&self) -> bool {
        self.library.state.is_some()
    }

    /// The app's preferences with this window's unconfirmed changes on top.
    pub fn preferences(&self) -> Preferences {
        let mut preferences = self.state().map(|s| s.preferences.clone()).unwrap_or_default();
        for (key, value) in &self.overrides {
            preferences.set(key, value.clone());
        }
        preferences
    }

    /// Asks the Swift app to do something. A failure always shows a toast.
    pub fn send(&mut self, command: &str, args: Value, cx: &mut Context<Self>) {
        self.dispatch(command, args, None, false, cx);
    }

    /// Like `send`, and also says so when it worked (imports, exports).
    pub fn send_announced(&mut self, command: &str, args: Value, cx: &mut Context<Self>) {
        self.dispatch(command, args, None, true, cx);
    }

    /// Sets one preference. The new value shows at once; the app's answer
    /// confirms it or puts the old one back.
    pub fn set_preference(&mut self, key: &str, value: Value, cx: &mut Context<Self>) {
        self.overrides.insert(key.to_string(), value.clone());
        self.dispatch("preference.set", json!({ "key": key, "value": value }), Some(key.to_string()), false, cx);
    }

    fn dispatch(
        &mut self,
        command: &str,
        args: Value,
        preference: Option<String>,
        announce: bool,
        cx: &mut Context<Self>,
    ) {
        match bridge::send_command(&self.library.dir, command, args) {
            Ok(id) => self.pending.push(Pending { id, sent_at: Instant::now(), preference, announce }),
            Err(error) => {
                if let Some(key) = preference {
                    self.overrides.remove(&key);
                }
                self.toast(format!("Could not reach Netra: {error}"), true);
            }
        }
        cx.notify();
    }

    fn toast(&mut self, text: String, is_error: bool) {
        self.toasts.push(Toast { text, is_error, shown_at: Instant::now() });
    }

    /// Matches answers to the commands waiting on them, gives up on the ones
    /// that timed out, and retires old toasts. Returns whether anything
    /// visible changed.
    fn settle(&mut self) -> bool {
        let mut changed = false;
        let now = Instant::now();
        let mut toasts = Vec::new();
        let results = self.library.state.as_ref().map(|s| s.results.clone()).unwrap_or_default();
        let overrides = &mut self.overrides;
        self.pending.retain(|pending| {
            if let Some(result) = results.iter().find(|r| r.id == pending.id) {
                if let Some(key) = &pending.preference {
                    overrides.remove(key);
                }
                let message = result.message.clone().filter(|m| !m.is_empty());
                if !result.ok {
                    toasts.push((message.unwrap_or_else(|| "Netra could not do that.".into()), true));
                } else if pending.announce {
                    toasts.push((message.unwrap_or_else(|| "Done.".into()), false));
                }
                changed = true;
                return false;
            }
            if now.duration_since(pending.sent_at) > COMMAND_TIMEOUT {
                if let Some(key) = &pending.preference {
                    overrides.remove(key);
                }
                toasts.push(("Netra did not answer. Is the menu-bar app running?".into(), true));
                changed = true;
                return false;
            }
            true
        });
        // One toast for a burst of unanswered commands is enough.
        toasts.dedup();
        for (text, is_error) in toasts {
            self.toast(text, is_error);
        }
        let before = self.toasts.len();
        self.toasts.retain(|t| now.duration_since(t.shown_at) < TOAST_LIFETIME);
        changed | (self.toasts.len() != before)
    }
}
