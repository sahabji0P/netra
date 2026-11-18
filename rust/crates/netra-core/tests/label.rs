//! The menu-bar label's text rules, mirroring `MenuBarLabelTests.swift` on
//! the same sample: Claude 5h 38% and weekly 64%, Codex weekly 82%, and
//! $12.48 / 4.2M tokens today.

use chrono::{DateTime, NaiveDate, Utc};
use netra_core::label::{Label, LabelSettings};
use netra_core::time;
use netra_core::{AgentStat, PeriodRow, Snapshot};
use serde_json::json;

fn now() -> DateTime<Utc> {
    "2026-06-10T12:00:00Z".parse().unwrap()
}

fn today() -> NaiveDate {
    now().date_naive()
}

fn at(seconds: i64) -> f64 {
    time::to_apple_seconds(now() + chrono::Duration::seconds(seconds))
}

fn sample() -> Snapshot {
    let json = json!({
        "fetchedAt": at(0),
        "claudeQuota": {
            "windows": [
                { "label": "5h", "usedPercent": 38, "resetsAt": at(2 * 3600 + 600), "durationSeconds": 18000 },
                { "label": "weekly", "usedPercent": 64, "resetsAt": at(3 * 86400), "durationSeconds": 604800 },
            ],
            "fetchedAt": at(0), "subscriptionType": "max",
        },
        "codexQuota": {
            "windows": [{ "label": "weekly", "usedPercent": 82, "resetsAt": at(4 * 86400), "durationSeconds": 604800 }],
            "planType": "plus", "observedAt": at(0),
        },
    });
    Snapshot::from_json(&json.to_string()).unwrap()
}

fn rows() -> Vec<PeriodRow> {
    let agent = |name: &str, cost: f64, tokens: u64| AgentStat {
        name: name.into(),
        cost,
        total_tokens: tokens,
        ..AgentStat::default()
    };
    vec![PeriodRow::from_parts(
        "2026-06-10",
        today(),
        &[agent("claude", 12.48, 4_200_000), agent("hermes", 3.0, 1_000)],
    )]
}

fn items(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

fn texts(settings: &LabelSettings, ids: &[&str]) -> Vec<String> {
    let rows = rows();
    let snapshot = sample();
    Label::new(settings, &rows, Some(&snapshot), today(), now()).texts(&items(ids))
}

fn settings() -> LabelSettings {
    LabelSettings { hidden_providers: vec!["hermes".into()], ..LabelSettings::default() }
}

#[test]
fn items_show_in_order_and_a_missing_window_is_left_out() {
    // Codex's weekly 82% is the closest to a limit; it has no session window.
    let ids = ["limitPercent", "resetCountdown", "todayCost", "sessionPercent", "weeklyPercent", "todayTokens"];
    assert_eq!(texts(&settings(), &ids), ["82%", "4d", "$12.48", "7d 82%", "4.2M"]);
}

#[test]
fn a_chosen_source_drives_the_limit_items() {
    let mut s = settings();
    s.limit_source = "claude".into();
    let ids = ["sessionPercent", "weeklyPercent", "limitPercent", "resetCountdown"];
    assert_eq!(texts(&s, &ids), ["5h 38%", "7d 64%", "64%", "3d"]);
    s.show_remaining = true;
    assert_eq!(texts(&s, &ids), ["5h 62%", "7d 36%", "36%", "3d"]);
}

#[test]
fn the_countdown_follows_the_limit_item_before_it() {
    let mut s = settings();
    s.limit_source = "claude".into();
    assert_eq!(texts(&s, &["sessionPercent", "resetCountdown"]), ["5h 38%", "2h 10m"]);
    assert_eq!(texts(&s, &["weeklyPercent", "todayCost", "resetCountdown"]), ["7d 64%", "$12.48", "3d"]);
    // Nothing before it: the tightest window (weekly, 64%).
    assert_eq!(texts(&s, &["resetCountdown", "sessionPercent"]), ["3d", "5h 38%"]);
}

#[test]
fn hidden_providers_are_neither_the_closest_source_nor_in_the_cost() {
    let mut s = settings();
    s.hidden_providers.push("codex".into());
    assert_eq!(texts(&s, &["limitPercent", "todayCost"]), ["64%", "$12.48"]);
    s.hidden_providers.clear();
    assert_eq!(texts(&s, &["todayCost"]), ["$15.48"]);
}

#[test]
fn an_item_that_draws_nothing_says_why() {
    let s = settings();
    let rows = rows();
    let snapshot = sample();
    let label = Label::new(&s, &rows, Some(&snapshot), today(), now());
    let session = label.item("sessionPercent", &[]);
    assert_eq!(session.text, None);
    assert_eq!(
        session.reason.as_deref(),
        Some("Codex is closest to a limit right now and has no session (5-hour) window.")
    );
    let weekly = label.item("weeklyPercent", &[]);
    assert_eq!((weekly.agent.as_deref(), weekly.window.as_deref()), (Some("codex"), Some("Weekly")));

    // No usage and no limits: every item is empty, with a reason.
    let empty = Label::new(&s, &[], None, today(), now());
    for id in ["todayCost", "todayTokens", "weekCost", "monthCost", "limitPercent", "resetCountdown"] {
        let value = empty.item(id, &[]);
        assert!(value.text.is_none() && value.reason.is_some(), "{id}");
    }
    assert_eq!(empty.bar_fractions(), None);
    assert_eq!(empty.ring_fraction(), None);
}

#[test]
fn icons_follow_the_limit_source() {
    let mut s = settings();
    s.limit_source = "claude".into();
    let rows = rows();
    let snapshot = sample();
    let label = Label::new(&s, &rows, Some(&snapshot), today(), now());
    assert_eq!(label.bar_fractions(), Some((0.38, Some(0.64))));
    assert_eq!(label.ring_fraction(), Some(0.64));
}

#[test]
fn an_estimate_stands_in_only_without_a_real_quota_and_never_counts_down() {
    let json = json!({
        "fetchedAt": at(0),
        "activeBlock": { "start": at(-3600), "end": at(4 * 3600), "tokens": 10, "cost": 1, "projectedCost": 2, "percentUsed": 140 },
    });
    let snapshot = Snapshot::from_json(&json.to_string()).unwrap();
    let mut s = settings();
    s.show_remaining = true;
    let rows = rows();
    let label = Label::new(&s, &rows, Some(&snapshot), today(), now());
    assert_eq!(label.texts(&items(&["limitPercent", "sessionPercent"])), ["140%", "5h 140%"]);
}
