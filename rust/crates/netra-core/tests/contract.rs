//! Contract tests against synthetic captures of the files the Swift app
//! writes, and ports of the Swift tests that pin the same rules
//! (`LimitSummaryTests`, `CalculationRegressionTests`).

use chrono::{DateTime, Duration, NaiveDate, Utc};
use netra_core::aggregate::{self, TokenPart, UsageRange};
use netra_core::limits::{self, Pace};
use netra_core::snapshot::QuotaWindow;
use netra_core::time::from_apple_seconds;
use netra_core::{AgentStat, ModelStat, PeriodRow, Snapshot, UsageHistory};

fn history() -> UsageHistory {
    UsageHistory::from_json(include_str!("fixtures/usage-history.json")).expect("history fixture decodes")
}

fn snapshot() -> Snapshot {
    Snapshot::from_json(include_str!("fixtures/snapshot.json")).expect("snapshot fixture decodes")
}

fn day(s: &str) -> NaiveDate {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
}

/// The moment the fixture snapshot was taken.
fn fixture_now() -> DateTime<Utc> {
    from_apple_seconds(816_461_900.0).unwrap()
}

// MARK: - History

#[test]
fn history_decodes_days_in_order_and_skips_non_day_keys() {
    let rows = history().rows();
    let keys: Vec<&str> = rows.iter().map(|r| r.period.as_str()).collect();
    assert_eq!(keys, ["2026-11-13", "2026-11-15", "2026-11-16"]);
    assert!(history().complete_scan_at.is_some());
}

#[test]
fn row_totals_include_other_but_its_agent_list_does_not() {
    let rows = history().rows();
    let row = &rows[1];
    assert_eq!(row.cost, 11.0);
    assert_eq!(row.total_tokens, 1150);
    assert_eq!(row.agents.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(), ["codex", "claude"]);
    assert_eq!(row.unattributed.as_ref().map(|a| a.cost), Some(1.0));
    // Models are combined by name across every part, other included.
    let gpt = row.models.iter().find(|m| m.name == "gpt-test").unwrap();
    assert_eq!(gpt.cost, 7.0);
    assert_eq!(gpt.total_tokens, 750);
}

#[test]
fn missing_token_fields_default_to_zero() {
    let rows = history().rows();
    let codex = rows[1].agents.iter().find(|a| a.name == "codex").unwrap();
    assert_eq!(codex.cache_creation_tokens, 0);
}

// MARK: - Aggregation

#[test]
fn selection_ends_today_and_previous_is_the_equal_window_before() {
    let rows = history().rows();
    let today = day("2026-11-16");
    let current = aggregate::selection(&rows, UsageRange::SevenDays, 0, today);
    assert_eq!((current.start, current.end), (day("2026-11-10"), today));
    assert_eq!(current.rows.len(), 3);
    assert_eq!(current.each_day().len(), 7);
    assert_eq!(current.total.cost, 21.5);

    let today_only = aggregate::selection(&rows, UsageRange::Today, 0, today);
    assert_eq!(today_only.total.total_tokens, 900);
    let yesterday = aggregate::selection(&rows, UsageRange::Today, 1, today);
    assert_eq!(yesterday.total.cost, 11.0);

    let empty = aggregate::selection(&rows, UsageRange::SevenDays, 1, today);
    assert!(empty.rows.is_empty());
    assert_eq!(aggregate::change(empty.total.cost, current.total.cost), None);
}

#[test]
fn swift_previous_period_case() {
    // CalculationRegressionTests.testDashboardPreviousPeriodIsTheEqualWindowBefore
    let today = day("2026-09-26");
    let rows: Vec<PeriodRow> = (0..14)
        .map(|i| {
            let date = today - Duration::days(i);
            let agent =
                AgentStat { name: "claude".into(), cost: (i + 1) as f64, total_tokens: 10, ..Default::default() };
            PeriodRow::from_parts(date.format("%Y-%m-%d").to_string(), date, &[agent])
        })
        .collect();
    let mut sorted = rows.clone();
    sorted.sort_by_key(|r| r.date);
    let current = aggregate::selection(&sorted, UsageRange::SevenDays, 0, today);
    let previous = aggregate::selection(&sorted, UsageRange::SevenDays, 1, today);
    assert_eq!(current.rows.len(), 7);
    assert_eq!(previous.rows.len(), 7);
    assert_eq!(current.total.cost, (1..=7).sum::<i32>() as f64);
    assert_eq!(previous.total.cost, (8..=14).sum::<i32>() as f64);
    assert!((aggregate::change(77.0, 28.0).unwrap() + 0.636).abs() < 0.001);
    assert_eq!(aggregate::change(0.0, 5.0), None);
}

#[test]
fn aggregate_merges_agents_and_their_models() {
    let rows = history().rows();
    let total = aggregate::selection(&rows, UsageRange::ThirtyDays, 0, day("2026-11-16")).total;
    let claude = total.agents.iter().find(|a| a.name == "claude").unwrap();
    assert_eq!(claude.cost, 14.5);
    let a = claude.models.iter().find(|m| m.name == "claude-test-a").unwrap();
    assert_eq!((a.cost, a.total_tokens), (12.0, 1100));
    assert_eq!(total.agents[0].name, "claude", "most expensive first");
}

#[test]
fn model_rows_keep_unattributed_usage_as_other() {
    let rows = history().rows();
    let total = aggregate::selection(&rows, UsageRange::SevenDays, 0, day("2026-11-16")).total;
    let model_rows = aggregate::model_rows(&total);
    let other = model_rows.iter().find(|r| r.provider == "other").expect("residual line");
    assert_eq!((other.name.as_str(), other.cost, other.tokens), ("gpt-test", 1.0, 100));
    let sum: f64 = model_rows.iter().map(|r| r.cost).sum();
    assert!((sum - total.cost).abs() < 1e-9, "model lines add up to the total");
}

#[test]
fn model_rows_infer_provider_when_no_agent_reports_models() {
    let model = ModelStat { name: "gpt-5".into(), cost: 2.0, total_tokens: 20, ..Default::default() };
    let row = PeriodRow { models: vec![model], cost: 2.0, total_tokens: 20, ..Default::default() };
    let rows = aggregate::model_rows(&row);
    assert_eq!(rows[0].provider, "codex");
}

#[test]
fn cache_hit_rate_and_token_parts() {
    let rows = history().rows();
    let first = &rows[0];
    assert!((aggregate::cache_hit_rate(first) - 800.0 / 950.0).abs() < 1e-12);
    let parts = aggregate::token_parts(first);
    assert_eq!(parts[0], (TokenPart::CacheReads, 800));
    assert_eq!(parts.len(), 4, "parts add up, so no 'other' slice");
    assert_eq!(aggregate::cache_hit_rate(&PeriodRow::default()), 0.0);

    let reasoning = PeriodRow { total_tokens: 10, input_tokens: 4, ..Default::default() };
    assert_eq!(aggregate::token_parts(&reasoning).last(), Some(&(TokenPart::Other, 6)));
}

// MARK: - Snapshot and limits

#[test]
fn snapshot_decodes_dates_from_apple_reference_seconds() {
    let snapshot = snapshot();
    assert_eq!(snapshot.fetched_at.to_rfc3339(), "2026-11-15T18:56:13.500+00:00");
    assert_eq!(snapshot.active_block.as_ref().unwrap().percent_used, 1223.0);
}

#[test]
fn provider_limits_follow_order_and_drop_expired_windows() {
    let limits = limits::provider_limits(&snapshot(), &limits::DEFAULT_ORDER, fixture_now());
    let agents: Vec<&str> = limits.iter().map(|l| l.agent.as_str()).collect();
    assert_eq!(agents, ["claude", "codex", "cursor", "cursor-grok-bot"]);

    let claude = &limits[0];
    assert_eq!(claude.windows.len(), 3, "the expired window is gone");
    assert_eq!(claude.source, "Reported by Anthropic");
    assert_eq!(claude.plan.as_deref(), Some("team"));
    assert_eq!(claude.note.as_deref(), Some("Extra usage credits used up"));
    assert_eq!(claude.most_constrained().unwrap().label, "weekly · Test");

    let reversed = limits::provider_limits(&snapshot(), &["codex", "claude"], fixture_now());
    assert_eq!(reversed[0].agent, "codex");
}

#[test]
fn codex_tolerates_unknown_source_and_counts_banked_resets() {
    let limits = limits::provider_limits(&snapshot(), &["codex"], fixture_now());
    let codex = &limits[0];
    assert_eq!(codex.source, "Last Codex session");
    assert_eq!(codex.windows.len(), 2, "an undated window stays while its observation is fresh");
    assert_eq!(codex.reset_credit_expiries.len(), 2, "expired credits are dropped");
    assert_eq!(codex.banked_reset_count(), 4, "the reported count wins when larger");
    let soonest = codex.reset_credit_expiries[0].unwrap();
    assert_eq!(soonest, from_apple_seconds(817_752_542.0).unwrap());
    assert!(limits::banked_resets(codex, fixture_now()).unwrap().starts_with("4 banked resets · next expires in "));

    let later = fixture_now() + Duration::hours(2);
    let codex_later = &limits::provider_limits(&snapshot(), &["codex"], later)[0];
    assert_eq!(codex_later.windows.len(), 1, "undated windows expire after an hour");
}

#[test]
fn grok_bot_window_becomes_its_own_provider() {
    let limits = limits::provider_limits(&snapshot(), &["cursor", "cursor-grok-bot"], fixture_now());
    assert_eq!(limits[0].windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), ["included usage"]);
    assert_eq!(limits[1].windows[0].label, "weekly");
    assert_eq!(limits[1].plan, None);
}

#[test]
fn claude_falls_back_to_the_local_block_estimate() {
    let mut snapshot = snapshot();
    snapshot.claude_quota = None;
    let limits = limits::provider_limits(&snapshot, &["claude"], fixture_now());
    assert!(limits[0].is_estimate);
    assert_eq!(limits::amount(&limits[0].windows[0], false, true), "12.2× of peak");
    let after_block = from_apple_seconds(816_472_801.0).unwrap();
    assert!(limits::provider_limits(&snapshot, &["claude"], after_block).is_empty());
}

// MARK: - Limit text (ports of LimitSummaryTests)

fn window(used: f64, elapsed: f64, now: DateTime<Utc>) -> QuotaWindow {
    let duration = 7.0 * 86_400.0;
    let remaining = (1.0 - elapsed) * duration;
    QuotaWindow {
        label: "weekly".into(),
        used_percent: used,
        resets_at: Some(now + Duration::milliseconds((remaining * 1000.0) as i64)),
        duration_seconds: Some(duration),
    }
}

#[test]
fn titles_read_as_sentence_case() {
    assert_eq!(limits::title("5h"), "Session · 5h");
    assert_eq!(limits::title("weekly"), "Weekly");
    assert_eq!(limits::title("weekly · Fable"), "Weekly · Fable");
    assert_eq!(limits::title("auto models"), "Auto models");
    assert_eq!(limits::title("2h"), "2-hour");
    assert_eq!(limits::title("Grok Bot"), "Grok Bot");
}

#[test]
fn amount_honours_used_or_remaining_and_clamps() {
    let now = fixture_now();
    let w = window(54.4, 0.5, now);
    assert_eq!(limits::amount(&w, false, false), "54% used");
    assert_eq!(limits::amount(&w, true, false), "46% left");
    let over = window(130.0, 0.5, now);
    assert_eq!(limits::amount(&over, true, false), "0% left");
    assert_eq!(limits::amount(&over, false, true), "1.3× of peak");
}

#[test]
fn countdown_resets() {
    let now = fixture_now();
    assert_eq!(limits::reset_countdown(now + Duration::hours(52), now), "Resets in 2d 4h");
    assert_eq!(limits::reset_countdown(now + Duration::minutes(192), now), "Resets in 3h 12m");
    assert_eq!(limits::reset_countdown(now + Duration::seconds(20), now), "Resets in 1m");
}

#[test]
fn pace_compares_usage_with_even_burn() {
    let now = fixture_now();
    assert_eq!(limits::pace(&window(50.0, 0.52, now), now), Some(Pace::OnPace));
    assert_eq!(limits::pace(&window(100.0, 0.4, now), now), Some(Pace::Exhausted));
    assert_eq!(limits::pace(&window(20.0, 0.5, now), now), Some(Pace::Behind { points: 30 }));
    let Some(Pace::Ahead { points, runs_out_in: Some(runs_out) }) = limits::pace(&window(60.0, 0.5, now), now) else {
        panic!("expected ahead of pace");
    };
    assert_eq!(points, 10);
    assert!((runs_out - 2.333 * 86_400.0).abs() < 3_600.0);
    let undated =
        QuotaWindow { label: "weekly".into(), used_percent: 50.0, resets_at: Some(now), duration_seconds: None };
    assert_eq!(limits::pace(&undated, now), None);
    assert_eq!(limits::pace(&window(5.0, 0.01, now), now), None);
    assert_eq!(limits::pace(&window(0.0, 0.4, now), now), None, "no usage, no pace");
    assert!(limits::needs_attention(Some(Pace::Exhausted)));
    assert!(!limits::needs_attention(Some(Pace::OnPace)));
}

#[test]
fn the_dashboard_state_reads_preferences_accounts_and_results() {
    use netra_core::DashboardState;

    let state = DashboardState::from_json(include_str!("fixtures/dashboard-state.json")).unwrap();
    assert_eq!(state.version, 1);
    assert_eq!(state.app.version.as_deref(), Some("1.5.0"));
    assert_eq!(state.app.notifications, "allowed");
    assert!(state.written_at.is_some());

    let prefs = &state.preferences;
    assert_eq!(prefs.string("menuBarStyle", "plain"), "pill");
    assert_eq!(prefs.strings("menuBarItems"), ["todayCost", "limitPercent"]);
    assert!(prefs.bool("claudeQuotaEnabled", false));
    assert_eq!(prefs.number("providerLimitAlertThreshold", 0.0), 80.0);
    assert!(prefs.bool("notInTheFile", true), "a missing key falls back to the default");
    assert_eq!(prefs.number("aKeyFromANewerNetra", 0.0), 7.0, "unknown keys are carried");

    let claude = &state.accounts.providers[0];
    assert!(claude.managing && claude.live_is_saved);
    assert_eq!(claude.accounts.len(), 2);
    assert!(claude.accounts[0].active);
    let parked = claude.accounts[1].limits.as_ref().unwrap();
    assert!(!parked.is_live);
    assert_eq!(parked.windows[0].quota_window().used_percent, 91.0);
    assert!(claude.accounts[0].last_active_at.is_some(), "a date without fractional seconds still reads");

    assert_eq!(state.navigate.as_ref().map(|n| (n.page.as_str(), n.nonce)), Some(("subscriptions", 3)));
    assert!(state.result("abc-1").is_some_and(|r| r.ok));
    assert!(state.result("missing").is_none());
}

#[test]
fn an_empty_dashboard_state_is_all_defaults() {
    let state = netra_core::DashboardState::from_json("{}").unwrap();
    assert!(state.accounts.providers.is_empty());
    assert!(state.preferences.bool("showsLimits", true));
}
