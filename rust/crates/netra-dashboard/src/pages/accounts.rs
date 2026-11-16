//! The Accounts page: the Claude Code and Codex accounts Netra can switch
//! between. This window only shows the roster and asks; the menu-bar app
//! owns the sign-ins and does every switch, sign-in and removal itself.

use chrono::{DateTime, Utc};
use gpui::{
    AnyElement, Context, Entity, FontWeight, IntoElement, ParentElement, PromptLevel, Render, SharedString, Styled,
    Subscription, Window, div, prelude::*, px,
};
use netra_core::bridge::{Account, AccountProvider};
use netra_core::{format, limits, palette};
use serde_json::json;

use crate::components::{
    ButtonKind, banner, button, card, divider, icon_button, meter, on_click, page_header, page_scroll, panel,
    provider_badge, tag,
};
use crate::store::UsageStore;
use crate::theme::{Theme, alpha};

pub struct AccountsPage {
    store: Entity<UsageStore>,
    _observe: Subscription,
}

impl AccountsPage {
    pub fn new(store: Entity<UsageStore>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&store, |_, _, cx| cx.notify());
        AccountsPage { store, _observe: observe }
    }

    fn send(&mut self, command: &'static str, args: serde_json::Value, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.send(command, args, cx));
    }

    /// Removing is the one action here that cannot be taken back with a
    /// click, so it asks first.
    fn confirm_remove(&mut self, id: String, title: String, window: &mut Window, cx: &mut Context<Self>) {
        let answer = window.prompt(
            PromptLevel::Warning,
            &format!("Remove “{title}” from Netra?"),
            Some("Netra forgets this account's saved sign-in. The account itself is not signed out or changed."),
            &["Remove", "Cancel"],
            cx,
        );
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(0) {
                let _ = this.update(cx, |this, cx| this.send("account.remove", json!({ "id": id }), cx));
            }
        })
        .detach();
    }

    fn provider_card(
        &self,
        theme: &Theme,
        provider: &AccountProvider,
        busy: bool,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let agent = provider.provider.clone();
        let name = palette::display_name(&agent);
        let live = provider.live.as_ref();
        let signed_in_as = match live {
            Some(live) => {
                let who = live.email.clone().or(live.display_name.clone()).unwrap_or("an account".into());
                format!("Signed in as {who}")
            }
            None => format!("{name} is not signed in on this Mac"),
        };

        let add = {
            let agent = agent.clone();
            button(
                theme,
                SharedString::from(format!("add-{agent}")),
                "Add account",
                Some("icons/plus.svg"),
                ButtonKind::Secondary,
                !busy,
                on_click(cx, move |this: &mut Self, _, cx| {
                    this.send("account.beginSignIn", json!({ "provider": agent }), cx)
                }),
            )
        };
        let save_current = (!provider.live_is_saved && live.is_some()).then(|| {
            let agent = agent.clone();
            button(
                theme,
                SharedString::from(format!("save-{agent}")),
                "Save current account",
                None,
                ButtonKind::Primary,
                !busy,
                on_click(cx, move |this: &mut Self, _, cx| {
                    this.send("account.startManaging", json!({ "provider": agent }), cx)
                }),
            )
        });

        let header = div()
            .flex()
            .items_center()
            .gap(px(10.))
            .child(provider_badge(theme, &agent, 30.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .flex_1()
                    .min_w(px(0.))
                    .child(div().text_size(px(15.)).font_weight(FontWeight::SEMIBOLD).child(name))
                    .child(div().text_size(px(11.5)).text_color(theme.muted).truncate().child(signed_in_as)),
            )
            .children(save_current)
            .child(add);

        let pending = provider.pending_sign_in.then(|| {
            div()
                .flex()
                .items_center()
                .gap(px(12.))
                .p(px(12.))
                .rounded(px(10.))
                .bg(alpha(theme.accent, 0.1))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .flex_1()
                        .child(div().text_size(px(12.5)).font_weight(FontWeight::MEDIUM).child("Waiting for sign-in"))
                        .child(div().text_size(px(11.5)).text_color(theme.muted).child(
                            "Finish signing in in the window Netra opened. Your current account stays signed in.",
                        )),
                )
                .child(button(
                    theme,
                    SharedString::from(format!("cancel-{agent}")),
                    "Cancel",
                    None,
                    ButtonKind::Secondary,
                    true,
                    on_click(cx, |this: &mut Self, _, cx| this.send("account.cancelSignIn", json!({}), cx)),
                ))
        });

        let rows: Vec<AnyElement> = provider
            .accounts
            .iter()
            .enumerate()
            .flat_map(|(index, account)| {
                let line = (index > 0).then(|| divider(theme).into_any_element());
                line.into_iter().chain([self.account_row(theme, provider, account, busy, now, cx)])
            })
            .collect();
        let empty = provider.accounts.is_empty().then(|| {
            div().text_size(px(12.)).text_color(theme.muted).child(if live.is_some() {
                "Save the current account to switch back to it later, then add another."
            } else {
                "Add an account to start."
            })
        });

        card(theme)
            .child(header)
            .children(provider.note.clone().map(|note| banner(note, theme.warning)))
            .children(pending)
            .when(!rows.is_empty() || empty.is_some(), |d| d.child(divider(theme)))
            .children(rows)
            .children(empty)
            .into_any_element()
    }

    fn account_row(
        &self,
        theme: &Theme,
        provider: &AccountProvider,
        account: &Account,
        busy: bool,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let color = theme.provider(&provider.provider);
        // The title is the email when there is no nickname; don't say it twice.
        let subtitle: Vec<String> = [account.email.clone(), account.organization.clone()]
            .into_iter()
            .flatten()
            .filter(|s| !s.is_empty() && *s != account.title)
            .collect();
        let attention = account.attention.as_deref().map(|a| match a {
            "deactivated" => "Deactivated",
            _ => "Sign in again",
        });

        let avatar = div()
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .size(px(32.))
            .rounded(px(16.))
            .bg(alpha(color, if account.active { 0.9 } else { 0.18 }))
            .text_color(if account.active { gpui::white().into() } else { color })
            .text_size(px(12.))
            .font_weight(FontWeight::SEMIBOLD)
            .child(account.initials.clone());

        // A parked account shows its last known limits; the live one is on
        // the Subscriptions page.
        let limit_summary = account.limits.as_ref().filter(|_| !account.active).map(|record| {
            let age = record.observed_at.map(|at| format::age(at, now)).unwrap_or_default();
            div()
                .flex()
                .flex_col()
                .gap(px(5.))
                .w(px(260.))
                .flex_none()
                .children(record.windows.iter().take(2).map(|w| {
                    let window = w.quota_window();
                    // A window whose reset has passed is full again.
                    let reset_passed = window.resets_at.is_some_and(|r| r <= now);
                    let used = if reset_passed { 0.0 } else { window.used_percent };
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .text_size(px(11.))
                        .child(
                            div()
                                .w(px(84.))
                                .flex_none()
                                .text_color(theme.muted)
                                .truncate()
                                .child(limits::title(&window.label)),
                        )
                        .child(div().flex_1().child(meter(theme, used / 100.0, color, 5.)))
                        .child(div().w(px(34.)).flex().justify_end().child(format!("{used:.0}%")))
                }))
                .child(div().text_size(px(10.5)).text_color(theme.faint).child(format!("Last seen {age}")))
        });

        let id = account.id.clone();
        let switch = (!account.active).then(|| {
            let id = id.clone();
            button(
                theme,
                SharedString::from(format!("switch-{id}")),
                if provider.switching { "Switching…" } else { "Switch" },
                Some("icons/swap.svg"),
                ButtonKind::Primary,
                !busy && account.attention.is_none(),
                on_click(cx, move |this: &mut Self, _, cx| this.send("account.switch", json!({ "id": id }), cx)),
            )
        });
        let sign_in_again = account.attention.is_some().then(|| {
            let agent = provider.provider.clone();
            button(
                theme,
                SharedString::from(format!("again-{id}")),
                "Sign in again",
                None,
                ButtonKind::Secondary,
                !busy,
                on_click(cx, move |this: &mut Self, _, cx| {
                    this.send("account.beginSignIn", json!({ "provider": agent }), cx)
                }),
            )
        });
        let rename = {
            let id = id.clone();
            icon_button(
                theme,
                SharedString::from(format!("rename-{id}")),
                "icons/sliders.svg",
                "Rename…",
                true,
                on_click(cx, move |this: &mut Self, _, cx| this.send("account.rename", json!({ "id": id }), cx)),
            )
        };
        let remove = {
            let (id, title) = (id.clone(), account.title.clone());
            icon_button(
                theme,
                SharedString::from(format!("remove-{id}")),
                "icons/close.svg",
                "Remove from Netra…",
                !busy,
                on_click(cx, move |this: &mut Self, window, cx| {
                    this.confirm_remove(id.clone(), title.clone(), window, cx)
                }),
            )
        };

        div()
            .flex()
            .items_center()
            .gap(px(12.))
            .child(avatar)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .flex_1()
                    .min_w(px(0.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(7.))
                            .child(
                                div()
                                    .text_size(px(13.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .truncate()
                                    .child(account.title.clone()),
                            )
                            .children(account.plan.as_ref().map(|plan| tag(crate::components::capitalize(plan), color)))
                            .children(account.active.then(|| tag("Active", theme.good)))
                            .children(attention.map(|text| tag(text, theme.bad))),
                    )
                    .child(div().text_size(px(11.5)).text_color(theme.muted).truncate().child(subtitle.join(" · "))),
            )
            .children(limit_summary)
            .children(sign_in_again)
            .children(switch)
            .child(rename)
            .child(remove)
            .into_any_element()
    }
}

impl Render for AccountsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(window);
        let state = self.store.read(cx).library.state.clone();
        let now = Utc::now();
        let (scroll, body) = page_scroll("accounts-page", window, 1120.);
        let body =
            body.child(page_header(&theme, "Accounts", "Switch Claude Code and Codex between your accounts", div()));

        let Some(state) = state else {
            return scroll.child(
                body.child(
                    panel(&theme, "Open Netra to manage accounts", None).child(
                        div()
                            .text_size(px(12.))
                            .text_color(theme.muted)
                            .child("Accounts are kept by Netra's menu-bar app. Start it, and this page fills in."),
                    ),
                ),
            );
        };
        let accounts = &state.accounts;
        // One switch or sign-in at a time, across both providers.
        let busy = accounts.providers.iter().any(|p| p.switching || p.pending_sign_in);

        let notice = accounts.notice.as_ref().map(|notice| {
            let color = if notice.is_error { theme.bad } else { theme.good };
            div()
                .flex()
                .items_center()
                .gap(px(10.))
                .px(px(12.))
                .py(px(9.))
                .rounded(px(10.))
                .bg(alpha(color, 0.1))
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
                                .text_color(color)
                                .child(notice.title.clone()),
                        )
                        .children(
                            notice.detail.clone().map(|d| div().text_size(px(11.5)).text_color(theme.muted).child(d)),
                        ),
                )
                .child(icon_button(
                    &theme,
                    "dismiss-notice",
                    "icons/close.svg",
                    "Dismiss",
                    true,
                    on_click(cx, |this: &mut Self, _, cx| this.send("account.dismissNotice", json!({}), cx)),
                ))
        });

        let cards: Vec<AnyElement> =
            accounts.providers.iter().map(|p| self.provider_card(&theme, p, busy, now, cx)).collect();

        scroll.child(body.children(notice).children(cards).child(
            div().text_size(px(11.5)).text_color(theme.faint).child(
                "Switching changes only who is signed in. Settings, MCP servers, projects and history stay shared. \
                     Sign-ins are kept in your macOS Keychain, never in Netra's files.",
            ),
        ))
    }
}
