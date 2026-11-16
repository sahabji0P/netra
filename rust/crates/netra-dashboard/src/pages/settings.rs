//! The settings pages. Every control asks the menu-bar app to change one
//! preference (or do one thing) and shows the new value at once; the app's
//! state file confirms it. Nothing is stored by this window.

use chrono::{DateTime, Datelike, Duration, Utc};
use gpui::{
    AnyElement, Context, Entity, FontWeight, IntoElement, ParentElement, PathPromptOptions, Render, SharedString,
    Styled, Subscription, Window, div, prelude::*, px,
};
use netra_core::aggregate::{self, UsageRange};
use netra_core::bridge::{DashboardState, Preferences};
use netra_core::limits::{self, ProviderLimits};
use netra_core::snapshot::QuotaWindow;
use netra_core::{Library, format, palette, time};
use serde_json::{Value, json};

use crate::components::{
    ButtonKind, Click, banner, button, card, divider, icon, icon_button, on_click, on_index, page_header, page_scroll,
    panel, provider_badge, section_label, segmented, setting_row, stepper, toggle,
};
use crate::pages::Page;
use crate::pages::subscriptions::{LimitStyle, ordered_limits, provider_card};
use crate::store::UsageStore;
use crate::theme::{Theme, alpha};

/// Everything the menu-bar label can show, in the order offered.
const LABEL_ITEMS: [(&str, &str, &str); 8] = [
    ("todayCost", "Today's cost", "API-equivalent cost so far today"),
    ("todayTokens", "Today's tokens", "Tokens processed today"),
    ("weekCost", "This week's cost", "Cost since the week began"),
    ("monthCost", "This month's cost", "Cost since the month began"),
    ("limitPercent", "Limit percent", "The tightest window of the limit source"),
    ("resetCountdown", "Time to reset", "Until that window resets"),
    ("sessionPercent", "Session percent", "The short (5-hour) window"),
    ("weeklyPercent", "Weekly percent", "The weekly window"),
];

const TOKEN_ALERT_STEPS: [u64; 12] = [
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
    10_000_000,
    25_000_000,
    50_000_000,
    100_000_000,
    250_000_000,
    500_000_000,
];

pub struct SettingsPage {
    store: Entity<UsageStore>,
    pub section: Page,
    _observe: Subscription,
}

impl SettingsPage {
    pub fn new(store: Entity<UsageStore>, section: Page, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&store, |_, _, cx| cx.notify());
        SettingsPage { store, section, _observe: observe }
    }

    fn set(&mut self, key: &'static str, value: Value, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.set_preference(key, value, cx));
    }

    fn send(&mut self, command: &'static str, args: Value, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.send(command, args, cx));
    }

    /// A switch bound to one boolean preference.
    fn switch(&self, theme: &Theme, key: &'static str, on: bool, cx: &mut Context<Self>) -> AnyElement {
        toggle(theme, key, on, on_click(cx, move |this: &mut Self, _, cx| this.set(key, json!(!on), cx)))
            .into_any_element()
    }

    /// A segmented control bound to one string preference.
    fn choice(
        &self,
        theme: &Theme,
        key: &'static str,
        options: &'static [(&'static str, &'static str)],
        current: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let labels: Vec<&'static str> = options.iter().map(|o| o.1).collect();
        let selected = options.iter().position(|o| o.0 == current).unwrap_or(0);
        segmented(
            theme,
            key,
            &labels,
            selected,
            on_index(cx, move |this: &mut Self, index, cx| this.set(key, json!(options[index].0), cx)),
        )
        .into_any_element()
    }

    fn action(
        &self,
        theme: &Theme,
        label: &'static str,
        kind: ButtonKind,
        enabled: bool,
        command: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        button(
            theme,
            command,
            label,
            None,
            kind,
            enabled,
            on_click(cx, move |this: &mut Self, _, cx| this.send(command, json!({}), cx)),
        )
        .into_any_element()
    }

    // MARK: Menu bar

    fn menu_bar(&self, theme: &Theme, p: &Preferences, library: &Library, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let now = Utc::now();
        let items = p.strings("menuBarItems");
        let preview = panel(theme, "Preview", Some("How the label reads in your menu bar".into()))
            .child(label_preview(theme, p, library, now, false))
            .child(label_preview(theme, p, library, now, true));

        let look = panel(theme, "Look", None)
            .child(setting_row(
                theme,
                "Icon",
                Some("Netra's eye, two limit bars, a gauge ring, or no icon at all.".into()),
                self.choice(
                    theme,
                    "menuBarIcon",
                    &[("eye", "Eye"), ("bars", "Bars"), ("ring", "Ring"), ("none", "None")],
                    &p.string("menuBarIcon", "eye"),
                    cx,
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Style",
                Some("Plain text, a filled pill, or an outlined pill.".into()),
                self.choice(
                    theme,
                    "menuBarStyle",
                    &[("plain", "Plain"), ("pill", "Pill"), ("outline", "Outline")],
                    &p.string("menuBarStyle", "plain"),
                    cx,
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Color",
                Some("Follow the menu bar, use the provider's color, or go green, amber, red as a limit fills.".into()),
                self.choice(
                    theme,
                    "menuBarTint",
                    &[("mono", "Menu bar"), ("provider", "Provider"), ("status", "Status")],
                    &p.string("menuBarTint", "mono"),
                    cx,
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Compact",
                Some("Smaller text and tighter spacing, for a crowded menu bar.".into()),
                self.switch(theme, "menuBarCompact", p.bool("menuBarCompact", false), cx),
            ));

        // Shown items first, in their order, then the rest.
        let shown: Vec<&(&str, &str, &str)> =
            items.iter().filter_map(|id| LABEL_ITEMS.iter().find(|item| item.0 == id)).collect();
        let hidden: Vec<&(&str, &str, &str)> =
            LABEL_ITEMS.iter().filter(|item| !items.iter().any(|i| i == item.0)).collect();
        let count = shown.len();
        let mut rows: Vec<AnyElement> = Vec::new();
        for (index, item) in shown.into_iter().chain(hidden).enumerate() {
            let on = index < count;
            let id = item.0;
            let current = items.clone();
            let flip = on_click(cx, move |this: &mut Self, _, cx| {
                let mut next = current.clone();
                if on {
                    next.retain(|i| i != id);
                } else {
                    next.push(id.to_string());
                }
                this.set("menuBarItems", json!(next), cx);
            });
            let mover = |offset: isize, cx: &mut Context<Self>| -> Click {
                let current = items.clone();
                on_click(cx, move |this: &mut Self, _, cx| {
                    let mut next = current.clone();
                    let target = index as isize + offset;
                    if target >= 0 && (target as usize) < next.len() {
                        next.swap(index, target as usize);
                        this.set("menuBarItems", json!(next), cx);
                    }
                })
            };
            if index > 0 {
                rows.push(divider(theme).into_any_element());
            }
            rows.push(
                setting_row(
                    theme,
                    item.1,
                    Some(item.2.into()),
                    div()
                        .flex()
                        .items_center()
                        .gap(px(4.))
                        .when(on, |d| {
                            d.child(icon_button(
                                theme,
                                ("item-up", index),
                                "icons/up.svg",
                                "Move left",
                                index > 0,
                                mover(-1, cx),
                            ))
                            .child(icon_button(
                                theme,
                                ("item-down", index),
                                "icons/down.svg",
                                "Move right",
                                index + 1 < count,
                                mover(1, cx),
                            ))
                        })
                        .child(div().w(px(6.)))
                        .child(toggle(theme, ("item", index), on, flip)),
                )
                .into_any_element(),
            );
        }
        let contents = panel(theme, "Shows", Some("Left to right, in this order".into())).children(rows);

        let source = panel(theme, "Limit source", None).child(setting_row(
            theme,
            "Which provider the limit items follow",
            Some("Closest follows whichever provider is nearest a limit right now.".into()),
            self.choice(
                theme,
                "menuBarLimitSource",
                &[("closest", "Closest"), ("claude", "Claude"), ("codex", "Codex"), ("cursor", "Cursor")],
                &p.string("menuBarLimitSource", "closest"),
                cx,
            ),
        ));

        let periods: Vec<(String, String)> = self
            .store
            .read(cx)
            .state()
            .map(|s| s.periods.iter().map(|o| (o.id.clone(), o.title.clone())).collect())
            .unwrap_or_default();
        let opens_on = p.string("defaultPeriod", "today");
        let period_buttons = div().flex().flex_none().p(px(2.)).gap(px(2.)).rounded(px(8.)).bg(theme.well).children(
            periods.into_iter().enumerate().map(|(index, (id, title))| {
                let active = id == opens_on;
                div()
                    .id(("opens-on", index))
                    .px(px(11.))
                    .py(px(3.5))
                    .rounded(px(6.))
                    .text_size(px(12.))
                    .font_weight(if active { FontWeight::SEMIBOLD } else { FontWeight::NORMAL })
                    .text_color(if active { theme.text } else { theme.muted })
                    .when(active, |d| d.bg(theme.surface).shadow_sm())
                    .when(!active, |d| d.cursor_pointer())
                    .on_click(cx.listener(move |this, _, _, cx| this.set("defaultPeriod", json!(id), cx)))
                    .child(title)
            }),
        );
        let popover = panel(theme, "Popover sections", Some("Top to bottom".into()))
            .child(setting_row(
                theme,
                "Subscription limits",
                Some("Plan windows, resets, and pace for each provider.".into()),
                self.switch(theme, "showsLimits", p.bool("showsLimits", true), cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Activity chart",
                Some("Recent usage, stacked by provider.".into()),
                self.switch(theme, "showsActivityChart", p.bool("showsActivityChart", true), cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Provider breakdown",
                Some("Cost and tokens per agent.".into()),
                self.switch(theme, "showsProviderBreakdown", p.bool("showsProviderBreakdown", true), cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Keep Awake control",
                Some("Block idle sleep for 1h, 4h, or until turned off.".into()),
                self.switch(theme, "showsKeepAwake", p.bool("showsKeepAwake", true), cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Opens on",
                Some("The usage period the popover shows first.".into()),
                period_buttons,
            ));

        vec![
            preview.into_any_element(),
            look.into_any_element(),
            contents.into_any_element(),
            source.into_any_element(),
            section_label(theme, "POPOVER").into_any_element(),
            popover.into_any_element(),
        ]
    }

    // MARK: Limits

    fn limits(
        &self,
        theme: &Theme,
        p: &Preferences,
        library: &Library,
        state: &DashboardState,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let now = Utc::now();
        let style = LimitStyle::from(p);
        let providers = library.snapshot.as_ref().map(|s| ordered_limits(s, p, now)).unwrap_or_default();
        let preview = providers.first().map(|first| {
            div()
                .flex()
                .flex_col()
                .gap(px(8.))
                .child(section_label(theme, "PREVIEW"))
                .child(provider_card(theme, first, style, now))
                .into_any_element()
        });

        let display = panel(theme, "Display", None)
            .child(setting_row(
                theme,
                "Bars show",
                Some("Fill limit bars with what you've used, or with what's left.".into()),
                segmented(
                    theme,
                    "barsShowRemaining",
                    &["Used", "Left"],
                    style.show_remaining as usize,
                    on_index(cx, |this: &mut Self, index, cx| this.set("barsShowRemaining", json!(index == 1), cx)),
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Reset times",
                Some("A countdown, or the date and time the window resets.".into()),
                self.choice(
                    theme,
                    "resetTimeStyle",
                    &[("countdown", "Countdown"), ("clock", "Date and time")],
                    &p.string("resetTimeStyle", "countdown"),
                    cx,
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Pace",
                Some("Whether you are ahead of or behind an even burn to the reset.".into()),
                self.switch(theme, "showsPace", style.pace, cx),
            ));

        let mut order = p.strings("limitProviderOrder");
        for known in limits::DEFAULT_ORDER {
            if !order.iter().any(|o| o == known) {
                order.push(known.to_string());
            }
        }
        let count = order.len();
        let rows = order.iter().enumerate().flat_map(|(index, agent)| {
            let mover = |offset: isize, cx: &mut Context<Self>| -> Click {
                let current = order.clone();
                on_click(cx, move |this: &mut Self, _, cx| {
                    let mut next = current.clone();
                    let target = index as isize + offset;
                    if target >= 0 && (target as usize) < next.len() {
                        next.swap(index, target as usize);
                        this.set("limitProviderOrder", json!(next), cx);
                    }
                })
            };
            let row = div()
                .flex()
                .items_center()
                .gap(px(10.))
                .child(provider_badge(theme, agent, 24.))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(12.5))
                        .font_weight(FontWeight::MEDIUM)
                        .child(palette::display_name(agent)),
                )
                .child(icon_button(theme, ("order-up", index), "icons/up.svg", "Move up", index > 0, mover(-1, cx)))
                .child(icon_button(
                    theme,
                    ("order-down", index),
                    "icons/down.svg",
                    "Move down",
                    index + 1 < count,
                    mover(1, cx),
                ))
                .into_any_element();
            (index > 0).then(|| divider(theme).into_any_element()).into_iter().chain([row])
        });
        let order_panel = panel(theme, "Order", Some("Top to bottom in the popover and on Subscriptions".into()))
            .children(rows.collect::<Vec<_>>());

        let claude_on = p.bool("claudeQuotaEnabled", false);
        let needs_approval = claude_on && state.app.claude_keychain_needs_approval;
        let claude = panel(theme, "Claude source", Some("Where Claude's numbers come from".into()))
            .child(setting_row(
                theme,
                "Read real limits from Anthropic",
                Some(
                    "Uses the sign-in Claude Code keeps in your Keychain. macOS asks for permission once. \
                     Off, Netra shows what Claude Code last saved."
                        .into(),
                ),
                self.switch(theme, "claudeQuotaEnabled", claude_on, cx),
            ))
            .when(needs_approval, |d| {
                d.child(divider(theme)).child(setting_row(
                    theme,
                    "Keychain access is waiting",
                    Some("Choose Always Allow when macOS asks, so Netra can keep reading the limits.".into()),
                    self.action(
                        theme,
                        "Allow Keychain access",
                        ButtonKind::Primary,
                        true,
                        "claude.authorizeKeychain",
                        cx,
                    ),
                ))
            });

        preview
            .into_iter()
            .chain([display.into_any_element(), order_panel.into_any_element(), claude.into_any_element()])
            .collect()
    }

    // MARK: Providers

    fn providers(&self, theme: &Theme, p: &Preferences, library: &Library, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let connections = panel(theme, "Account connections", Some("Opt-in".into())).child(setting_row(
            theme,
            "Cursor usage and limits",
            Some(
                "Reads the login Cursor saved on this Mac and asks Cursor's dashboard for your plan limits and \
                 usage. Cursor does not document this, so it can stop working."
                    .into(),
            ),
            self.switch(theme, "cursorUsageEnabled", p.bool("cursorUsageEnabled", false), cx),
        ));

        // Everyone seen in the recorded history, biggest first.
        let total = aggregate::selection(&library.rows, UsageRange::NinetyDays, 0, time::today()).total;
        let hidden = p.strings("hiddenMenuProviders");
        let agents: Vec<(String, f64, u64)> = total.parts().map(|a| (a.name.clone(), a.cost, a.total_tokens)).collect();
        let rows = agents.iter().enumerate().flat_map(|(index, (agent, cost, tokens))| {
            let visible = !hidden.iter().any(|h| h == &agent.to_lowercase());
            let name = agent.to_lowercase();
            let current = hidden.clone();
            let flip = on_click(cx, move |this: &mut Self, _, cx| {
                let mut next = current.clone();
                if visible {
                    next.push(name.clone());
                } else {
                    next.retain(|h| h != &name);
                }
                next.sort();
                next.dedup();
                this.set("hiddenMenuProviders", json!(next), cx);
            });
            let row = div()
                .flex()
                .items_center()
                .gap(px(10.))
                .child(provider_badge(theme, agent, 24.))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .flex_1()
                        .child(
                            div()
                                .text_size(px(12.5))
                                .font_weight(FontWeight::MEDIUM)
                                .child(palette::display_name(agent)),
                        )
                        .child(div().text_size(px(11.)).text_color(theme.muted).child(format!(
                            "{} · {} tokens in the last 90 days",
                            format::provider_cost(*cost, *tokens),
                            format::tokens(*tokens)
                        ))),
                )
                .child(toggle(theme, ("provider-visible", index), visible, flip))
                .into_any_element();
            (index > 0).then(|| divider(theme).into_any_element()).into_iter().chain([row])
        });
        let shown = panel(theme, "Shown in the popover", Some("This window always shows everything".into()))
            .children(rows.collect::<Vec<_>>())
            .when(agents.is_empty(), |d| {
                d.child(div().text_size(px(12.)).text_color(theme.muted).child("No provider has recorded usage yet."))
            });

        vec![connections.into_any_element(), shown.into_any_element()]
    }

    // MARK: Notifications

    fn notifications(
        &self,
        theme: &Theme,
        p: &Preferences,
        state: &DashboardState,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let (status, detail, control): (&str, &str, AnyElement) = match state.app.notifications.as_str() {
            "allowed" => (
                "Notifications are allowed",
                "Netra can alert you when a threshold is crossed.",
                div().into_any_element(),
            ),
            "denied" => (
                "Notifications are turned off",
                "Allow them for Netra in System Settings to get alerts.",
                self.action(theme, "Open Settings", ButtonKind::Secondary, true, "notifications.openSettings", cx),
            ),
            "notDetermined" => (
                "Notifications have not been allowed yet",
                "macOS asks once; alerts stay silent until you allow them.",
                self.action(theme, "Allow notifications", ButtonKind::Primary, true, "notifications.request", cx),
            ),
            _ => ("Checking…", "", div().into_any_element()),
        };
        let permission =
            panel(theme, "Permission", None).child(setting_row(theme, status, Some(detail.into()), control));

        let limit_on = p.bool("providerLimitAlertEnabled", false);
        let limit_at = p.number("providerLimitAlertThreshold", 80.0);
        let token_on = p.bool("dailyTokenAlertEnabled", false);
        let token_at = p.number("dailyTokenAlertThreshold", 1_000_000.0).max(1.0) as u64;
        let step_tokens = move |up: bool| -> u64 {
            if up {
                TOKEN_ALERT_STEPS.iter().copied().find(|s| *s > token_at).unwrap_or(token_at)
            } else {
                TOKEN_ALERT_STEPS.iter().rev().copied().find(|s| *s < token_at).unwrap_or(token_at)
            }
        };

        let alerts = panel(theme, "Alerts", Some("Checked after every refresh".into()))
            .child(setting_row(
                theme,
                "A provider limit is nearly used",
                Some("Once per window, when any plan window passes the threshold.".into()),
                div()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(stepper(
                        theme,
                        "limit-threshold",
                        format!("{limit_at:.0}%"),
                        on_click(cx, move |this: &mut Self, _, cx| {
                            this.set("providerLimitAlertThreshold", json!((limit_at - 5.0).max(5.0)), cx)
                        }),
                        on_click(cx, move |this: &mut Self, _, cx| {
                            this.set("providerLimitAlertThreshold", json!((limit_at + 5.0).min(100.0)), cx)
                        }),
                    ))
                    .child(self.switch(theme, "providerLimitAlertEnabled", limit_on, cx)),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Daily tokens pass a threshold",
                Some("Once a day, when today's tokens across all providers pass it.".into()),
                div()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(stepper(
                        theme,
                        "token-threshold",
                        format::tokens(token_at),
                        on_click(cx, move |this: &mut Self, _, cx| {
                            this.set("dailyTokenAlertThreshold", json!(step_tokens(false)), cx)
                        }),
                        on_click(cx, move |this: &mut Self, _, cx| {
                            this.set("dailyTokenAlertThreshold", json!(step_tokens(true)), cx)
                        }),
                    ))
                    .child(self.switch(theme, "dailyTokenAlertEnabled", token_on, cx)),
            ));

        vec![permission.into_any_element(), alerts.into_any_element()]
    }

    // MARK: General

    fn export_history(&mut self, cx: &mut Context<Self>) {
        let directory = default_folder();
        let chosen = cx.prompt_for_new_path(&directory, Some("netra-usage-history.json"));
        cx.spawn(async move |this, cx| {
            if let Ok(Ok(Some(path))) = chosen.await {
                let _ = this.update(cx, |this, cx| {
                    this.store.update(cx, |store, cx| {
                        store.send_announced("history.export", json!({ "path": path.to_string_lossy() }), cx)
                    });
                });
            }
        })
        .detach();
    }

    fn import_history(&mut self, cx: &mut Context<Self>) {
        let chosen = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Import".into()),
        });
        cx.spawn(async move |this, cx| {
            if let Ok(Ok(Some(paths))) = chosen.await
                && let Some(path) = paths.into_iter().next()
            {
                let _ = this.update(cx, |this, cx| {
                    this.store.update(cx, |store, cx| {
                        store.send_announced("history.import", json!({ "path": path.to_string_lossy() }), cx)
                    });
                });
            }
        })
        .detach();
    }

    fn general(
        &self,
        theme: &Theme,
        p: &Preferences,
        library: &Library,
        state: &DashboardState,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let app = &state.app;
        let launch_on = app.launch_at_login;
        let startup = panel(theme, "Startup", None).child(setting_row(
            theme,
            "Open Netra at login",
            Some(
                if app.launch_at_login_available {
                    "Netra starts in the menu bar when you sign in to your Mac."
                } else {
                    "Available when Netra runs from the Applications folder."
                }
                .into(),
            ),
            if app.launch_at_login_available {
                toggle(
                    theme,
                    "launch-at-login",
                    launch_on,
                    on_click(cx, move |this: &mut Self, _, cx| {
                        this.send("launchAtLogin.set", json!({ "enabled": !launch_on }), cx)
                    }),
                )
                .into_any_element()
            } else {
                div().into_any_element()
            },
        ));

        let delights = panel(theme, "Notch island and celebrations", None)
            .child(setting_row(
                theme,
                "Notch island",
                Some("Live activity around the notch, or a small pill on screens without one.".into()),
                self.switch(theme, "notchIslandEnabled", p.bool("notchIslandEnabled", true), cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Confetti when a limit resets",
                Some("A short burst when a weekly or monthly window starts over.".into()),
                self.switch(theme, "confettiOnReset", p.bool("confettiOnReset", true), cx),
            ));

        let mut facts = Vec::new();
        if let Some(first) = library.rows.first() {
            facts.push(format!("{} recorded days since {}", library.rows.len(), first.date.format("%-d %b %Y")));
        }
        if let Some(engine) = &library.engine {
            facts.push(format!("ccusage {engine}"));
        }
        if let Some(at) = library.complete_scan_at {
            facts.push(format!("last full scan {}", format::age(at, Utc::now())));
        }
        let folder = library.dir.clone();
        let data = panel(theme, "Your data", Some(facts.join(" · ").into()))
            .child(div().text_size(px(12.)).text_color(theme.muted).child(
                "Netra keeps one small history file: tokens and estimated cost per day and agent. It outlives the \
                 agents' own logs, and it never leaves this Mac unless you export it.",
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Export history",
                Some("Save a copy to move to another Mac, or to keep as a backup.".into()),
                button(
                    theme,
                    "export-history",
                    "Export…",
                    Some("icons/export.svg"),
                    ButtonKind::Secondary,
                    true,
                    on_click(cx, |this: &mut Self, _, cx| this.export_history(cx)),
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Import history",
                Some(
                    "Adds the days in an exported file. A day you already have is only replaced by a fuller one, so \
                     importing twice changes nothing. Usage from two Macs on the same day is not added together."
                        .into(),
                ),
                button(
                    theme,
                    "import-history",
                    "Import…",
                    Some("icons/import.svg"),
                    ButtonKind::Secondary,
                    true,
                    on_click(cx, |this: &mut Self, _, cx| this.import_history(cx)),
                ),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Data folder",
                Some(folder.display().to_string().into()),
                button(
                    theme,
                    "reveal-folder",
                    "Show in Finder",
                    None,
                    ButtonKind::Secondary,
                    true,
                    Box::new(move |_, _, cx| cx.reveal_path(&folder.join(netra_core::paths::HISTORY_FILE))),
                ),
            ));

        let site = &app.website;
        let publish_on = p.bool("websitePublishEnabled", false);
        let endpoint = p.string("websiteEndpoint", "");
        let can_publish = publish_on && !endpoint.is_empty() && site.token_saved && !site.publishing;
        let website = panel(theme, "Website", Some("Opt-in".into()))
            .child(setting_row(
                theme,
                "Publish daily totals to your website",
                Some("Sends daily aggregates only, after each refresh. Nothing is sent while this is off.".into()),
                self.switch(theme, "websitePublishEnabled", publish_on, cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Endpoint",
                Some(if endpoint.is_empty() { "Not set".into() } else { SharedString::from(endpoint.clone()) }),
                self.action(theme, "Change…", ButtonKind::Secondary, true, "website.promptEndpoint", cx),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                "Token",
                Some(
                    site.token_error
                        .clone()
                        .unwrap_or_else(|| {
                            if site.token_saved { "Saved in your Keychain" } else { "Not set" }.to_string()
                        })
                        .into(),
                ),
                div()
                    .flex()
                    .gap(px(8.))
                    .child(self.action(theme, "Set token…", ButtonKind::Secondary, true, "website.promptToken", cx))
                    .child(self.action(theme, "Clear", ButtonKind::Danger, site.token_saved, "website.clearToken", cx)),
            ))
            .child(divider(theme))
            .child(setting_row(
                theme,
                if site.publishing { "Publishing…" } else { "Publish now" },
                site.status.clone().map(SharedString::from),
                self.action(theme, "Publish now", ButtonKind::Primary, can_publish, "website.publishNow", cx),
            ));

        let about = card(theme).child(
            div().flex().items_center().gap(px(12.)).child(icon("icons/eye.svg", 26., theme.text)).child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .flex_1()
                    .child(
                        div()
                            .text_size(px(13.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(format!("Netra {}", app.version.clone().unwrap_or_default())),
                    )
                    .child(div().text_size(px(11.5)).text_color(theme.muted).child(match &app.update_available {
                        Some(version) => format!("Version {version} is available. Update with: brew upgrade netra"),
                        None => "You're up to date.".to_string(),
                    })),
            ),
        );

        vec![
            startup.into_any_element(),
            delights.into_any_element(),
            data.into_any_element(),
            website.into_any_element(),
            about.into_any_element(),
        ]
    }
}

impl Render for SettingsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(window);
        let store = self.store.read(cx);
        let library = store.library.clone();
        let preferences = store.preferences();
        let state = library.state.clone();
        let section = self.section;

        let (scroll, body) = page_scroll("settings-page", window, 860.);
        let body = body.child(page_header(&theme, section.title(), section.subtitle(), div()));
        let Some(state) = state else {
            return scroll.child(body.child(banner(
                "Settings are kept by Netra's menu-bar app. Start it, and this page fills in.",
                theme.warning,
            )));
        };
        let cards = match section {
            Page::MenuBar => self.menu_bar(&theme, &preferences, &library, cx),
            Page::Limits => self.limits(&theme, &preferences, &library, &state, cx),
            Page::Providers => self.providers(&theme, &preferences, &library, cx),
            Page::Notifications => self.notifications(&theme, &preferences, &state, cx),
            _ => self.general(&theme, &preferences, &library, &state, cx),
        };
        scroll.child(body.children(cards))
    }
}

fn default_folder() -> std::path::PathBuf {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    let documents = home.join("Documents");
    if documents.is_dir() { documents } else { home }
}

// MARK: Menu-bar label preview

/// The window the limit items read: the limit source's tightest, short or
/// weekly window.
fn label_window<'a>(limits: &'a ProviderLimits, item: &str) -> Option<&'a QuotaWindow> {
    let by_length =
        |wanted: f64| limits.windows.iter().find(|w| w.duration_seconds.is_some_and(|d| (d - wanted).abs() < 60.0));
    match item {
        "sessionPercent" => by_length(5.0 * 3600.0),
        "weeklyPercent" => by_length(7.0 * 86_400.0),
        _ => limits.most_constrained(),
    }
}

/// What each label item reads right now, from the same data the app uses.
/// The app's own drawing is the truth; this is close enough to choose by.
fn label_text(
    item: &str,
    library: &Library,
    source: Option<&ProviderLimits>,
    show_remaining: bool,
    now: DateTime<Utc>,
) -> Option<String> {
    let today = time::today();
    let since = |start: chrono::NaiveDate| library.rows.iter().filter(move |r| r.date >= start && r.date <= today);
    let percent = |window: &QuotaWindow| {
        let used = window.used_percent.clamp(0.0, 999.0);
        format!("{:.0}%", if show_remaining { (100.0 - used).max(0.0) } else { used })
    };
    match item {
        "todayCost" => Some(format::cost(since(today).map(|r| r.cost).sum())),
        "todayTokens" => Some(format::tokens(since(today).map(|r| r.total_tokens).sum())),
        "weekCost" => {
            let monday = today - Duration::days(i64::from(today.weekday().num_days_from_monday()));
            Some(format::cost(since(monday).map(|r| r.cost).sum()))
        }
        "monthCost" => Some(format::cost(since(today.with_day(1).unwrap_or(today)).map(|r| r.cost).sum())),
        "resetCountdown" => {
            let reset = source.and_then(|s| s.most_constrained()).and_then(|w| w.resets_at)?;
            Some(limits::duration((reset - now).num_seconds().max(0) as f64))
        }
        _ => source.and_then(|s| label_window(s, item)).map(percent),
    }
}

/// A strip that looks like a piece of the menu bar, with the label on it.
fn label_preview(
    theme: &Theme,
    p: &Preferences,
    library: &Library,
    now: DateTime<Utc>,
    dark_bar: bool,
) -> impl IntoElement {
    let all = library.snapshot.as_ref().map(|s| ordered_limits(s, p, now)).unwrap_or_default();
    let wanted = p.string("menuBarLimitSource", "closest");
    let used = |l: &ProviderLimits| l.most_constrained().map(|w| w.used_percent).unwrap_or(0.0);
    let source = match wanted.as_str() {
        "closest" => all.iter().max_by(|a, b| used(a).total_cmp(&used(b))),
        agent => all.iter().find(|l| l.agent == agent),
    };
    let show_remaining = p.bool("barsShowRemaining", false);
    let compact = p.bool("menuBarCompact", false);
    let style = p.string("menuBarStyle", "plain");
    let texts: Vec<String> = p
        .strings("menuBarItems")
        .iter()
        .filter_map(|item| label_text(item, library, source, show_remaining, now))
        .collect();

    let bar = if dark_bar { gpui::rgb(0x1D1D20) } else { gpui::rgb(0xE9E9EC) };
    let bar_ink = if dark_bar { gpui::rgb(0xF2F2F3) } else { gpui::rgb(0x1B1B1A) };
    let tint = match p.string("menuBarTint", "mono").as_str() {
        "provider" => source.map(|s| theme.provider(&s.agent)).unwrap_or(bar_ink),
        "status" => source.map(|s| theme.status(used(s))).unwrap_or(bar_ink),
        _ => bar_ink,
    };
    // On a filled pill the text is cut out of it; elsewhere it wears the tint.
    let (fill, ink) = if style == "pill" { (Some(tint), bar) } else { (None, tint) };

    let size = if compact { 11. } else { 12.5 };
    let mark: Option<AnyElement> = match p.string("menuBarIcon", "eye").as_str() {
        "eye" => Some(icon("icons/eye.svg", size + 3., ink).into_any_element()),
        "ring" => Some(icon("icons/ring.svg", size + 2., ink).into_any_element()),
        "bars" => {
            let fraction = |item: &str| {
                source.and_then(|s| label_window(s, item)).map(|w| (w.used_percent / 100.0).clamp(0.0, 1.0) as f32)
            };
            let line = |f: f32, h: f32| {
                div()
                    .w(px(16.))
                    .h(px(h))
                    .rounded(px(h))
                    .bg(alpha(ink, 0.3))
                    .child(div().h_full().w(gpui::relative(f)).min_w(px(h)).rounded(px(h)).bg(ink))
            };
            Some(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(line(fraction("sessionPercent").or(fraction("limitPercent")).unwrap_or(0.4), 4.))
                    .child(line(fraction("weeklyPercent").unwrap_or(0.2), 3.))
                    .into_any_element(),
            )
        }
        _ => None,
    };
    let empty = mark.is_none() && texts.is_empty();

    let label = div()
        .flex()
        .items_center()
        .gap(px(if compact { 4. } else { 6. }))
        .text_size(px(size))
        .font_weight(FontWeight::MEDIUM)
        .text_color(ink)
        .when(style != "plain", |d| {
            d.px(px(if compact { 6. } else { 8. })).py(px(if compact { 1.5 } else { 2.5 })).rounded(px(20.))
        })
        .when_some(fill, |d, fill| d.bg(fill))
        .when(style == "outline", |d| d.border_1().border_color(tint))
        .children(mark)
        .children(texts.into_iter().map(|text| div().child(text)))
        .when(empty, |d| d.child(icon("icons/eye.svg", size + 3., ink)));

    // A few neighbours so the label is judged in company, as it will be.
    let neighbour = |path: &'static str| icon(path, 14., alpha(bar_ink, 0.55));
    div()
        .flex()
        .items_center()
        .justify_end()
        .gap(px(14.))
        .h(px(30.))
        .px(px(14.))
        .rounded(px(8.))
        .bg(bar)
        .child(label)
        .child(neighbour("icons/moon.svg"))
        .child(neighbour("icons/bell.svg"))
        .child(div().text_size(px(12.5)).text_color(alpha(bar_ink, 0.7)).child("Mon 9:41 AM"))
}
