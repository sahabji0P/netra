//! The Usage page: headline numbers with period-over-period change, the
//! activity chart, provider and token composition, and a filterable model
//! breakdown. Every number comes from `netra_core::aggregate`.

use chrono::{Datelike, Duration, NaiveDate, Utc};
use gpui::{
    AnyElement, Context, Entity, FontWeight, IntoElement, ParentElement, Render, SharedString, Styled, Subscription,
    Window, div, prelude::*, px, relative,
};
use netra_core::aggregate::{self, Selection, UsageRange};
use netra_core::{FileStatus, Library, PeriodRow, format, palette, time};

use crate::components::{
    StatTile, banner, meter, on_index, page_header, page_scroll, panel, provider_badge, segmented, swatch, text_tooltip,
};
use crate::store::UsageStore;
use crate::theme::{Theme, alpha};

const CHART_HEIGHT: f32 = 190.;
/// Weeks shown in the activity calendar.
const CALENDAR_WEEKS: i64 = 30;
const BREAKDOWN_LIMIT: usize = 15;

#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Metric {
    #[default]
    Cost,
    Tokens,
}

impl Metric {
    fn of_cost_tokens(self, cost: f64, tokens: u64) -> f64 {
        match self {
            Metric::Cost => cost,
            Metric::Tokens => tokens as f64,
        }
    }

    fn format(self, value: f64) -> String {
        match self {
            Metric::Cost => format::cost(value),
            Metric::Tokens => format::tokens(value.max(0.0) as u64),
        }
    }
}

pub struct UsagePage {
    store: Entity<UsageStore>,
    range: UsageRange,
    metric: Metric,
    provider_filter: Option<String>,
    hovered_day: Option<NaiveDate>,
    _observe: Subscription,
}

impl UsagePage {
    pub fn new(store: Entity<UsageStore>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&store, |_, _, cx| cx.notify());
        UsagePage {
            store,
            range: UsageRange::default(),
            metric: Metric::default(),
            provider_filter: None,
            hovered_day: None,
            _observe: observe,
        }
    }
}

impl Render for UsagePage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(window);
        let library = self.store.read(cx).library.clone();
        let today = time::today();
        let current = aggregate::selection(&library.rows, self.range, 0, today);
        let previous = aggregate::selection(&library.rows, self.range, 1, today);

        let range_index = UsageRange::ALL.iter().position(|r| *r == self.range).unwrap_or(1);
        let range_picker = segmented(
            &theme,
            "usage-range",
            &UsageRange::ALL.map(|r| r.label()),
            range_index,
            on_index(cx, |this: &mut Self, index, cx| {
                this.range = UsageRange::ALL[index];
                this.provider_filter = None;
                this.hovered_day = None;
                cx.notify();
            }),
        );

        let (scroll, body) = page_scroll("usage-page", window, 1120.);
        scroll.child(
            body.child(page_header(&theme, "Usage", "Coding-agent activity and API-equivalent cost", range_picker))
                .children(status_banner(&theme, &library))
                .child(self.kpis(&theme, &current, &previous))
                .child(self.activity(&theme, &current, cx))
                .child(
                    div()
                        .flex()
                        .gap(px(16.))
                        .items_start()
                        .child(self.providers(&theme, &current, cx))
                        .child(token_composition(&theme, &current.total)),
                )
                .child(self.breakdown(&theme, &current.total, cx))
                .child(calendar(&theme, &library.rows, today))
                .child(provenance(&theme, &library)),
        )
    }
}

impl UsagePage {
    fn kpis(&self, theme: &Theme, current: &Selection, previous: &Selection) -> impl IntoElement {
        let total = &current.total;
        let days = current.each_day();
        let spark =
            |f: fn(&PeriodRow) -> f64| days.iter().map(|(_, row)| row.map(f).unwrap_or(0.0)).collect::<Vec<_>>();
        let versus = self.range.previous_caption();
        let with_change = |prev: f64, now: f64| aggregate::change(prev, now).map(|c| (c, versus));
        let busiest = current.rows.iter().max_by(|a, b| a.cost.total_cmp(&b.cost));

        let fourth = if self.range == UsageRange::Today {
            StatTile {
                title: "Top provider",
                value: total.agents.first().map(|a| palette::short_name(&a.name)).unwrap_or("—".into()),
                caption: total.agents.first().map(|a| format::cost(a.cost)).unwrap_or("No usage yet".into()),
                change: None,
                spark: Vec::new(),
            }
        } else {
            StatTile {
                title: "Daily average",
                value: format::cost(total.cost / self.range.day_count() as f64),
                caption: busiest
                    .map(|b| format!("Busiest: {} · {}", b.date.format("%-d %b"), format::cost(b.cost)))
                    .unwrap_or("No usage yet".into()),
                change: None,
                spark: Vec::new(),
            }
        };

        div()
            .flex()
            .gap(px(12.))
            .child(
                StatTile {
                    title: "API-equivalent cost",
                    value: format::cost(total.cost),
                    caption: format!("No usage {versus} to compare"),
                    change: with_change(previous.total.cost, total.cost),
                    spark: spark(|r| r.cost),
                }
                .render(theme),
            )
            .child(
                StatTile {
                    title: "Tokens processed",
                    value: format::tokens(total.total_tokens),
                    caption: format!("No usage {versus} to compare"),
                    change: with_change(previous.total.total_tokens as f64, total.total_tokens as f64),
                    spark: spark(|r| r.total_tokens as f64),
                }
                .render(theme),
            )
            .child(
                StatTile {
                    title: "Cache hit rate",
                    value: format::percent(aggregate::cache_hit_rate(total), 0),
                    caption: "of input served from cache".into(),
                    change: None,
                    spark: Vec::new(),
                }
                .render(theme),
            )
            .child(fourth.render(theme))
    }

    fn activity(&self, theme: &Theme, current: &Selection, cx: &mut Context<Self>) -> impl IntoElement {
        let metric = self.metric;
        let days = current.each_day();
        // Stack providers in one fixed order (the range's ranking), so a
        // provider keeps its place from day to day.
        let order: Vec<String> = current
            .total
            .agents
            .iter()
            .map(|a| a.name.clone())
            .chain(current.total.unattributed.iter().map(|a| a.name.clone()))
            .collect();
        let value_of = |row: &PeriodRow| metric.of_cost_tokens(row.cost, row.total_tokens);
        let peak = days.iter().filter_map(|(_, r)| r.map(value_of)).fold(0.0, f64::max);

        let metric_picker = segmented(
            theme,
            "usage-metric",
            &["Cost", "Tokens"],
            if metric == Metric::Cost { 0 } else { 1 },
            on_index(cx, |this: &mut Self, index, cx| {
                this.metric = if index == 0 { Metric::Cost } else { Metric::Tokens };
                cx.notify();
            }),
        );

        let legend = div().flex().flex_wrap().gap(px(12.)).children(order.iter().map(|agent| {
            div()
                .flex()
                .items_center()
                .gap(px(5.))
                .text_size(px(11.5))
                .text_color(theme.muted)
                .child(swatch(theme.provider(agent), 8.))
                .child(palette::short_name(agent))
        }));

        let hovered = self.hovered_day.and_then(|d| days.iter().find(|(day, _)| *day == d).copied());
        let detail: AnyElement = match hovered {
            Some((day, row)) => {
                let label = day.format("%a %-d %b").to_string();
                let parts: Vec<AnyElement> = row
                    .map(|row| {
                        row.parts()
                            .map(|a| {
                                div()
                                    .flex()
                                    .items_center()
                                    .gap(px(4.))
                                    .child(swatch(theme.provider(&a.name), 7.))
                                    .child(format!(
                                        "{} {}",
                                        palette::short_name(&a.name),
                                        metric.format(metric.of_cost_tokens(a.cost, a.total_tokens))
                                    ))
                                    .into_any_element()
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap(px(12.))
                    .text_size(px(11.5))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(label))
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(row.map(|r| metric.format(value_of(r))).unwrap_or("No usage".into())),
                    )
                    .children(parts)
                    .into_any_element()
            }
            None => div()
                .text_size(px(11.5))
                .text_color(theme.faint)
                .child("Hover a day for its providers")
                .into_any_element(),
        };

        let label_every = match days.len() {
            0..=10 => 1,
            11..=31 => 5,
            _ => 15,
        };
        let count = days.len();
        let columns = days.iter().enumerate().map(|(index, (day, row))| {
            let day = *day;
            let is_hovered = self.hovered_day == Some(day);
            let segments: Vec<AnyElement> = row
                .map(|row| {
                    order
                        .iter()
                        .filter_map(|agent| row.parts().find(|a| &a.name == agent))
                        .map(|a| {
                            let v = metric.of_cost_tokens(a.cost, a.total_tokens);
                            let h = if peak > 0.0 { (v / peak) as f32 * CHART_HEIGHT } else { 0.0 };
                            div()
                                .w_full()
                                .h(px((h - 2.).max(if v > 0.0 { 1.5 } else { 0. })))
                                .flex_none()
                                .rounded(px(2.))
                                .bg(theme.provider(&a.name))
                                .into_any_element()
                        })
                        .collect()
                })
                .unwrap_or_default();
            let show_label = index % label_every == 0 || index + 1 == count;
            div()
                .id(("activity-day", index))
                .flex()
                .flex_col()
                .flex_1()
                .min_w(px(0.))
                .items_center()
                .gap(px(6.))
                .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                    if *hovered {
                        this.hovered_day = Some(day);
                    } else if this.hovered_day == Some(day) {
                        this.hovered_day = None;
                    }
                    cx.notify();
                }))
                .child(
                    div()
                        .flex()
                        .flex_col_reverse()
                        .w(relative(if count > 31 { 0.8 } else { 0.62 }))
                        .max_w(px(42.))
                        .h(px(CHART_HEIGHT))
                        .rounded_t(px(4.))
                        .overflow_hidden()
                        .gap(px(2.))
                        .when(is_hovered, |d| d.bg(alpha(theme.text, 0.06)))
                        .children(segments),
                )
                .child(
                    div()
                        .h(px(14.))
                        .text_size(px(10.))
                        .text_color(if is_hovered { theme.text } else { theme.faint })
                        .whitespace_nowrap()
                        .child(if show_label {
                            if count <= 7 { day.format("%a %-d").to_string() } else { day.format("%-d %b").to_string() }
                        } else {
                            String::new()
                        }),
                )
        });

        panel(theme, "Activity", Some(self.range.caption().into()))
            .child(div().flex().items_center().justify_between().gap(px(12.)).child(legend).child(metric_picker))
            .child(div().h(px(18.)).child(detail))
            .child(
                div()
                    .relative()
                    .child(
                        div()
                            .absolute()
                            .top(px(-2.))
                            .left(px(0.))
                            .text_size(px(10.))
                            .text_color(theme.faint)
                            .child(if peak > 0.0 { metric.format(peak) } else { String::new() }),
                    )
                    .child(
                        div()
                            .absolute()
                            .top(px(0.))
                            .left(px(0.))
                            .right(px(0.))
                            .h(px(CHART_HEIGHT))
                            .border_t_1()
                            .border_b_1()
                            .border_color(theme.hairline())
                            .child(
                                div()
                                    .absolute()
                                    .top(px(CHART_HEIGHT / 2.))
                                    .left(px(0.))
                                    .right(px(0.))
                                    .h(px(1.))
                                    .bg(alpha(theme.border, 0.5)),
                            ),
                    )
                    .child(div().flex().items_end().gap(px(2.)).children(columns)),
            )
    }

    fn providers(&self, theme: &Theme, current: &Selection, cx: &mut Context<Self>) -> impl IntoElement {
        let metric = self.metric;
        let total = &current.total;
        let whole = metric.of_cost_tokens(total.cost, total.total_tokens).max(f64::MIN_POSITIVE);
        let rows: Vec<AnyElement> = total
            .parts()
            .map(|agent| {
                let value = metric.of_cost_tokens(agent.cost, agent.total_tokens);
                let share = value / whole;
                let name = agent.name.clone();
                let selected = self.provider_filter.as_deref() == Some(agent.name.as_str());
                let value_text = match metric {
                    Metric::Cost => format::provider_cost(agent.cost, agent.total_tokens),
                    Metric::Tokens => format::tokens(agent.total_tokens),
                };
                div()
                    .id(SharedString::from(format!("provider-{}", agent.name)))
                    .flex()
                    .flex_col()
                    .gap(px(5.))
                    .p(px(7.))
                    .rounded(px(8.))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(alpha(theme.text, 0.08)))
                    .hover(|s| s.bg(alpha(theme.text, 0.05)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.provider_filter = if this.provider_filter.as_deref() == Some(name.as_str()) {
                            None
                        } else {
                            Some(name.clone())
                        };
                        cx.notify();
                    }))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .text_size(px(12.5))
                            .child(provider_badge(theme, &agent.name, 20.))
                            .child(div().flex_1().child(palette::display_name(&agent.name)))
                            .child(div().text_color(theme.muted).text_size(px(11.)).child(format::percent(share, 0)))
                            .child(
                                div().w(px(64.)).flex().justify_end().font_weight(FontWeight::MEDIUM).child(value_text),
                            ),
                    )
                    .child(meter(theme, share, theme.provider(&agent.name), 5.))
                    .into_any_element()
            })
            .collect();
        let empty = rows.is_empty();
        panel(
            theme,
            "Providers",
            Some(format!("By {} · click to filter", if metric == Metric::Cost { "cost" } else { "tokens" }).into()),
        )
        .flex_1()
        .min_w(px(0.))
        .gap(px(8.))
        .when(empty, |d| {
            d.child(div().text_size(px(12.)).text_color(theme.muted).child("No provider activity in this period"))
        })
        .children(rows)
    }

    fn breakdown(&self, theme: &Theme, total: &PeriodRow, cx: &mut Context<Self>) -> impl IntoElement {
        let all = aggregate::model_rows(total);
        let rows: Vec<_> =
            all.iter().filter(|r| self.provider_filter.as_ref().is_none_or(|p| &r.provider == p)).collect();
        let whole: f64 = rows.iter().map(|r| r.cost).sum::<f64>().max(f64::MIN_POSITIVE);
        let hidden = rows.len().saturating_sub(BREAKDOWN_LIMIT);

        let filter_label = match &self.provider_filter {
            Some(p) => format!("{} only · ranked by API-equivalent cost", palette::display_name(p)),
            None => "All providers · ranked by API-equivalent cost".into(),
        };
        let clear = self.provider_filter.is_some().then(|| {
            div()
                .id("breakdown-clear")
                .text_size(px(11.))
                .text_color(theme.accent)
                .cursor_pointer()
                .on_click(cx.listener(|this, _, _, cx| {
                    this.provider_filter = None;
                    cx.notify();
                }))
                .child("Show all")
        });

        let header = div()
            .flex()
            .gap(px(12.))
            .pb(px(6.))
            .border_b_1()
            .border_color(theme.hairline())
            .text_size(px(11.))
            .text_color(theme.muted)
            .child(div().flex_1().child("Model"))
            .child(div().w(px(130.)).child("Share"))
            .child(div().w(px(80.)).flex().justify_end().child("Cost"))
            .child(div().w(px(76.)).flex().justify_end().child("Tokens"));

        let lines = rows.iter().take(BREAKDOWN_LIMIT).map(|row| {
            div()
                .flex()
                .items_center()
                .gap(px(12.))
                .py(px(5.))
                .text_size(px(12.))
                .child(
                    div()
                        .flex()
                        .flex_1()
                        .min_w(px(0.))
                        .items_center()
                        .gap(px(8.))
                        .child(swatch(theme.provider(&row.provider), 8.))
                        .child(div().truncate().child(palette::model_display_name(&row.name)))
                        .child(
                            div().text_size(px(10.5)).text_color(theme.faint).child(palette::short_name(&row.provider)),
                        ),
                )
                .child(div().w(px(130.)).child(meter(theme, row.cost / whole, theme.provider(&row.provider), 5.)))
                .child(
                    div()
                        .w(px(80.))
                        .flex()
                        .justify_end()
                        .font_weight(FontWeight::MEDIUM)
                        .child(format::provider_cost(row.cost, row.tokens)),
                )
                .child(div().w(px(76.)).flex().justify_end().text_color(theme.muted).child(format::tokens(row.tokens)))
        });

        panel(theme, "Breakdown", Some(filter_label.into()))
            .gap(px(6.))
            .children(clear)
            .child(header)
            .when(rows.is_empty(), |d| {
                d.child(
                    div()
                        .py(px(8.))
                        .text_size(px(12.))
                        .text_color(theme.muted)
                        .child("No model details in this period"),
                )
            })
            .children(lines)
            .when(hidden > 0, |d| {
                d.child(
                    div()
                        .pt(px(4.))
                        .text_size(px(11.))
                        .text_color(theme.muted)
                        .child(format!("{hidden} smaller models not shown")),
                )
            })
    }
}

fn token_composition(theme: &Theme, total: &PeriodRow) -> impl IntoElement {
    let parts = aggregate::token_parts(total);
    let whole = parts.iter().map(|p| p.1).sum::<u64>().max(1) as f64;
    let bar = div().flex().w_full().h(px(14.)).rounded(px(5.)).overflow_hidden().bg(theme.well).children(
        parts.iter().filter(|p| p.1 > 0).map(|(part, value)| {
            div().h_full().w(relative((*value as f64 / whole) as f32)).bg(theme.token_part(*part))
        }),
    );
    let legend = parts.iter().map(|(part, value)| {
        div()
            .flex()
            .items_center()
            .gap(px(9.))
            .text_size(px(12.))
            .child(swatch(theme.token_part(*part), 9.))
            .child(div().flex_1().text_color(theme.muted).child(part.label()))
            .child(div().text_size(px(11.)).text_color(theme.muted).child(format::percent(*value as f64 / whole, 1)))
            .child(div().w(px(56.)).flex().justify_end().font_weight(FontWeight::MEDIUM).child(format::tokens(*value)))
    });
    panel(theme, "Token composition", Some(format::tokens(total.total_tokens).into()))
        .flex_1()
        .min_w(px(0.))
        .child(bar)
        .children(legend)
        .child(div().h(px(1.)).bg(theme.hairline()))
        .child(
            div()
                .flex()
                .justify_between()
                .text_size(px(12.))
                .child(div().font_weight(FontWeight::MEDIUM).child("Cache hit rate"))
                .child(
                    div().font_weight(FontWeight::SEMIBOLD).child(format::percent(aggregate::cache_hit_rate(total), 1)),
                ),
        )
}

fn status_banner(theme: &Theme, library: &Library) -> Option<impl IntoElement> {
    let file = library.history_path();
    match &library.history_status {
        FileStatus::Pending => Some(banner("Reading recorded usage…", theme.muted)),
        FileStatus::Missing if !library.has_data() => Some(banner(
            format!("No usage history at {}. Run Netra once so it records usage.", file.display()),
            theme.warning,
        )),
        FileStatus::Missing => Some(banner("usage-history.json is gone; showing what was last read.", theme.warning)),
        FileStatus::Unreadable(error) => Some(banner(
            format!("usage-history.json could not be read ({error}); showing what was last read."),
            theme.bad,
        )),
        FileStatus::Current => None,
    }
}

fn provenance(theme: &Theme, library: &Library) -> impl IntoElement {
    let mut parts = Vec::new();
    if let (Some(first), n) = (library.rows.first(), library.rows.len()) {
        parts.push(format!("{n} recorded days since {}", first.date.format("%-d %b %Y")));
    }
    if let Some(engine) = &library.engine {
        parts.push(format!("ccusage {engine}"));
    }
    if let Some(at) = library.complete_scan_at {
        parts.push(format!("last full scan {}", format::age(at, Utc::now())));
    }
    div().text_size(px(10.5)).text_color(theme.faint).child(parts.join(" · "))
}

/// A calendar of recorded days, one column per week, shaded by cost. One
/// hue from faint to full, so it reads as "more" without a legend lookup;
/// each day's numbers are in its tooltip.
fn calendar(theme: &Theme, rows: &[PeriodRow], today: NaiveDate) -> impl IntoElement {
    // Columns start on Monday; the last column is the current week.
    let this_monday = today - Duration::days(i64::from(today.weekday().num_days_from_monday()));
    let first = this_monday - Duration::weeks(CALENDAR_WEEKS - 1);
    let in_view: Vec<&PeriodRow> = rows.iter().filter(|r| r.date >= first && r.date <= today).collect();
    let peak = in_view.iter().map(|r| r.cost).fold(0.0, f64::max);
    let total: f64 = in_view.iter().map(|r| r.cost).sum();
    let active = in_view.iter().filter(|r| r.cost > 0.0 || r.total_tokens > 0).count();

    let shade = |cost: f64| -> gpui::Hsla {
        if cost <= 0.0 || peak <= 0.0 {
            return alpha(theme.text, 0.06);
        }
        // Four steps; a square root keeps ordinary days visible next to a spike.
        let step = ((cost / peak).sqrt() * 4.0).ceil().clamp(1.0, 4.0);
        alpha(theme.good, 0.2 + 0.2 * step as f32)
    };

    let weeks = (0..CALENDAR_WEEKS).map(|week| {
        let monday = first + Duration::weeks(week);
        let month_label = if monday.day() <= 7 { monday.format("%b").to_string() } else { String::new() };
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_w(px(0.))
            .gap(px(3.))
            .child(div().h(px(13.)).text_size(px(10.)).text_color(theme.faint).whitespace_nowrap().child(month_label))
            .children((0..7).map(|weekday| {
                let day = monday + Duration::days(weekday);
                let row = in_view.iter().find(|r| r.date == day);
                let cell =
                    div().id(("calendar-day", (week * 7 + weekday) as usize)).w_full().h(px(13.)).rounded(px(3.));
                if day > today {
                    return cell.into_any_element();
                }
                let hint = match row {
                    Some(r) => format!(
                        "{} · {} · {} tokens",
                        day.format("%a %-d %b"),
                        format::cost(r.cost),
                        format::tokens(r.total_tokens)
                    ),
                    None => format!("{} · no usage", day.format("%a %-d %b")),
                };
                cell.bg(shade(row.map(|r| r.cost).unwrap_or(0.0))).tooltip(text_tooltip(hint)).into_any_element()
            }))
    });

    let key = div()
        .flex()
        .items_center()
        .gap(px(4.))
        .text_size(px(10.5))
        .text_color(theme.faint)
        .child("Less")
        .children([0.0, 0.05, 0.2, 0.5, 1.0].map(|f| div().size(px(10.)).rounded(px(2.5)).bg(shade(f * peak.max(1.0)))))
        .child("More");

    panel(
        theme,
        "Activity calendar",
        Some(format!("{} over {active} active days · last {CALENDAR_WEEKS} weeks", format::cost(total)).into()),
    )
    .child(div().flex().gap(px(3.)).children(weeks))
    .child(div().flex().justify_end().child(key))
}
