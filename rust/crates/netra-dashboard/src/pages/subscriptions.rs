//! The Subscriptions page: every provider's limit windows with reset times
//! and pace, and the current 5-hour block. The limit rules live in
//! `netra_core::limits`; the options (used or left, countdown or clock,
//! pace, order) are the ones set on the Limits page.

use chrono::{DateTime, Utc};
use gpui::{
    AnyElement, Context, Entity, FontWeight, IntoElement, ParentElement, Render, Styled, Subscription, Window, div,
    prelude::*, px,
};
use netra_core::bridge::Preferences;
use netra_core::limits::{self, ProviderLimits};
use netra_core::snapshot::{BlockStat, QuotaWindow};
use netra_core::{FileStatus, format, palette};
use serde_json::json;

use crate::components::{
    banner, capitalize, card, divider, meter, on_index, page_header, page_scroll, panel, provider_badge, segmented, tag,
};
use crate::store::UsageStore;
use crate::theme::Theme;

/// How limit rows read, from the user's preferences.
#[derive(Clone, Copy)]
pub struct LimitStyle {
    pub show_remaining: bool,
    pub clock: bool,
    pub pace: bool,
}

impl LimitStyle {
    pub fn from(preferences: &Preferences) -> Self {
        LimitStyle {
            show_remaining: preferences.bool("barsShowRemaining", false),
            clock: preferences.string("resetTimeStyle", "countdown") == "clock",
            pace: preferences.bool("showsPace", true),
        }
    }
}

/// Providers in the user's order; ones the order does not name keep the
/// default order after it.
pub fn ordered_limits(
    snapshot: &netra_core::Snapshot,
    preferences: &Preferences,
    now: DateTime<Utc>,
) -> Vec<ProviderLimits> {
    let mut order = preferences.strings("limitProviderOrder");
    for known in limits::DEFAULT_ORDER {
        if !order.iter().any(|o| o == known) {
            order.push(known.to_string());
        }
    }
    let order: Vec<&str> = order.iter().map(String::as_str).collect();
    limits::provider_limits(snapshot, &order, now)
}

pub struct SubscriptionsPage {
    store: Entity<UsageStore>,
    _observe: Subscription,
}

impl SubscriptionsPage {
    pub fn new(store: Entity<UsageStore>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&store, |_, _, cx| cx.notify());
        SubscriptionsPage { store, _observe: observe }
    }
}

impl Render for SubscriptionsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(window);
        let store = self.store.read(cx);
        let library = store.library.clone();
        let preferences = store.preferences();
        let connected = store.connected();
        let style = LimitStyle::from(&preferences);
        let now = Utc::now();

        // The same choice as on the Limits page, so it is saved, not local.
        let toggle = segmented(
            &theme,
            "limits-mode",
            &["Used", "Left"],
            style.show_remaining as usize,
            on_index(cx, |this: &mut Self, index, cx| {
                this.store.update(cx, |store, cx| store.set_preference("barsShowRemaining", json!(index == 1), cx));
            }),
        );

        let providers = library.snapshot.as_ref().map(|s| ordered_limits(s, &preferences, now)).unwrap_or_default();
        let block = library.snapshot.as_ref().and_then(|s| s.active_block.clone()).filter(|b| b.end > now);

        let notice = match (&library.snapshot_status, library.snapshot.as_ref()) {
            (FileStatus::Pending, _) => Some(banner("Reading the last snapshot…", theme.muted)),
            (FileStatus::Missing, None) => {
                Some(banner("No limits yet. Open Netra in the menu bar once so it saves them.", theme.warning))
            }
            (FileStatus::Unreadable(error), _) => Some(banner(
                format!("The saved limits could not be read ({error}); showing what was last read."),
                theme.bad,
            )),
            (_, Some(snapshot)) if (now - snapshot.fetched_at).num_minutes() >= 15 => Some(banner(
                format!("Limits were saved {}. Refresh to update them.", format::age(snapshot.fetched_at, now)),
                theme.warning,
            )),
            _ => None,
        };

        let (scroll, body) = page_scroll("subscriptions-page", window, 1120.);
        scroll.child(
            body.child(page_header(
                &theme,
                "Subscriptions",
                "Plan limits, resets, and pace for every provider",
                if connected { toggle.into_any_element() } else { div().into_any_element() },
            ))
            .children(notice)
            .when(providers.is_empty() && library.snapshot.is_some(), |d| {
                d.child(
                    panel(&theme, "No limits right now", None).child(
                        div()
                            .text_size(px(12.))
                            .text_color(theme.muted)
                            .child("The last snapshot has no limit window that is still open."),
                    ),
                )
            })
            .children(providers.iter().map(|p| provider_card(&theme, p, style, now)))
            .children(block.map(|b| block_card(&theme, &b, now))),
        )
    }
}

pub fn provider_card(theme: &Theme, limits: &ProviderLimits, style: LimitStyle, now: DateTime<Utc>) -> AnyElement {
    let color = theme.provider(&limits.agent);
    let observed = limits.observed_at.map(|at| format!(" · {}", format::age(at, now))).unwrap_or_default();

    let header = div()
        .flex()
        .items_center()
        .gap(px(10.))
        .child(provider_badge(theme, &limits.agent, 28.))
        .child(div().text_size(px(15.)).font_weight(FontWeight::SEMIBOLD).child(palette::display_name(&limits.agent)))
        .children(limits.plan.as_ref().map(|plan| tag(capitalize(plan), color)))
        .child(div().flex_1())
        .child(div().text_size(px(11.)).text_color(theme.muted).child(format!("{}{observed}", limits.source)));

    let windows = limits.windows.iter().map(|w| window_row(theme, w, color, style, limits.is_estimate, now));
    let footer: Vec<String> = limits.note.iter().cloned().chain(limits::banked_resets(limits, now)).collect();

    card(theme)
        .gap(px(13.))
        .child(header)
        .children(windows)
        .when(!footer.is_empty(), |d| {
            d.child(divider(theme))
                .children(footer.into_iter().map(|line| div().text_size(px(11.5)).text_color(theme.muted).child(line)))
        })
        .into_any_element()
}

/// One limit window: its name, a bar, the amount, then reset and pace.
pub fn window_row(
    theme: &Theme,
    window: &QuotaWindow,
    color: gpui::Rgba,
    style: LimitStyle,
    is_estimate: bool,
    now: DateTime<Utc>,
) -> impl IntoElement {
    let used = window.used_percent.clamp(0.0, 100.0);
    let show_remaining = style.show_remaining;
    let fraction = if show_remaining && !is_estimate { (100.0 - used) / 100.0 } else { used / 100.0 };
    let reset = window
        .resets_at
        .map(|r| {
            if style.clock {
                format!("Resets {}", limits::reset_clock(r, now))
            } else {
                limits::reset_countdown(r, now)
            }
        })
        .unwrap_or_default();
    let pace = if is_estimate || !style.pace { None } else { limits::pace(window, now) };
    let attention = limits::needs_attention(pace);

    div()
        .flex()
        .flex_col()
        .gap(px(5.))
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(14.))
                .text_size(px(12.5))
                .child(div().w(px(150.)).flex_none().truncate().child(limits::title(&window.label)))
                .child(div().flex_1().child(meter(theme, fraction, color, 7.)))
                .child(
                    div()
                        .w(px(84.))
                        .flex()
                        .justify_end()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(theme.limit_amount(window.used_percent))
                        .child(limits::amount(window, show_remaining, is_estimate)),
                ),
        )
        .child(div().flex().gap(px(10.)).pl(px(164.)).text_size(px(11.)).text_color(theme.muted).child(reset).children(
            pace.map(|p| div().text_color(if attention { theme.bad } else { theme.faint }).child(limits::pace_text(p))),
        ))
}

fn block_card(theme: &Theme, block: &BlockStat, now: DateTime<Utc>) -> AnyElement {
    panel(theme, "Current 5-hour block", Some("Estimated locally from Claude Code logs".into()))
        .child(
            div()
                .flex()
                .gap(px(32.))
                .child(stat(theme, "So far", format::cost(block.cost)))
                .child(stat(theme, "Projected", format::cost(block.projected_cost)))
                .child(stat(theme, "Tokens", format::tokens(block.tokens)))
                .child(stat(theme, "Vs your peak", format::peak_percent(block.percent_used)))
                .child(stat(theme, "Ends", limits::reset_clock(block.end, now))),
        )
        .into_any_element()
}

fn stat(theme: &Theme, label: &'static str, value: String) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(3.))
        .child(div().text_size(px(11.)).text_color(theme.muted).child(label))
        .child(div().text_size(px(17.)).font_weight(FontWeight::SEMIBOLD).child(value))
}
