//! The window's root view: a sidebar, the selected page, and toasts.

use std::time::Duration;

use chrono::Utc;
use gpui::{
    AnyView, Context, Entity, FontWeight, IntoElement, ParentElement, Render, Styled, Subscription, Task, Window, div,
    prelude::*, px,
};
use netra_core::{FileStatus, format};
use serde_json::json;

use crate::components::{SIDEBAR_WIDTH, icon, icon_button, on_click};
use crate::pages::Page;
use crate::pages::accounts::AccountsPage;
use crate::pages::settings::SettingsPage;
use crate::pages::subscriptions::SubscriptionsPage;
use crate::pages::usage::UsagePage;
use crate::store::UsageStore;
use crate::theme::{Theme, alpha};

/// Relative times ("5m ago", "Resets in 3h") are re-rendered this often.
const CLOCK_TICK: Duration = Duration::from_secs(30);

pub struct Dashboard {
    store: Entity<UsageStore>,
    page: Page,
    usage: Entity<UsagePage>,
    subscriptions: Entity<SubscriptionsPage>,
    accounts: Entity<AccountsPage>,
    settings: Entity<SettingsPage>,
    /// The last `navigate` request acted on; `None` until the first state is
    /// read, so a request from before this window opened is not replayed.
    seen_navigation: Option<u64>,
    _subscriptions: Vec<Subscription>,
    _clock: Task<()>,
}

impl Dashboard {
    pub fn new(store: Entity<UsageStore>, page: Page, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let usage = cx.new(|cx| UsagePage::new(store.clone(), cx));
        let subscriptions = cx.new(|cx| SubscriptionsPage::new(store.clone(), cx));
        let accounts = cx.new(|cx| AccountsPage::new(store.clone(), cx));
        let settings = cx.new(|cx| SettingsPage::new(store.clone(), page, cx));
        let observers = vec![
            cx.observe(&store, |this, _, cx| {
                this.follow_navigation(cx);
                cx.notify();
            }),
            cx.observe_window_appearance(window, |_, _, cx| cx.notify()),
        ];
        let clock = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(CLOCK_TICK).await;
                let alive = this.update(cx, |this, cx| {
                    cx.notify();
                    this.usage.update(cx, |_, cx| cx.notify());
                    this.subscriptions.update(cx, |_, cx| cx.notify());
                    this.accounts.update(cx, |_, cx| cx.notify());
                });
                if alive.is_err() {
                    return;
                }
            }
        });
        Dashboard {
            store,
            page,
            usage,
            subscriptions,
            accounts,
            settings,
            seen_navigation: None,
            _subscriptions: observers,
            _clock: clock,
        }
    }

    /// The menu-bar app can point an open window at a page ("Manage
    /// accounts" in the popover). Each request carries a new nonce.
    fn follow_navigation(&mut self, cx: &mut Context<Self>) {
        let Some(state) = self.store.read(cx).state() else { return };
        let request = state.navigate.clone();
        let nonce = request.as_ref().map(|n| n.nonce).unwrap_or(0);
        match self.seen_navigation {
            None => self.seen_navigation = Some(nonce),
            Some(seen) if seen != nonce => {
                self.seen_navigation = Some(nonce);
                if let Some(page) = request.and_then(|n| Page::from_id(&n.page)) {
                    self.select(page, cx);
                    cx.activate(true);
                }
            }
            Some(_) => {}
        }
    }

    fn select(&mut self, page: Page, cx: &mut Context<Self>) {
        self.page = page;
        self.settings.update(cx, |settings, cx| {
            settings.section = page;
            cx.notify();
        });
        cx.notify();
    }

    fn sidebar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let row = |page: Page, cx: &mut Context<Self>| {
            let selected = page == self.page;
            div()
                .id(page.id())
                .flex()
                .items_center()
                .gap(px(9.))
                .px(px(9.))
                .py(px(6.))
                .rounded(px(7.))
                .text_size(px(13.))
                .cursor_pointer()
                .text_color(if selected { theme.text } else { theme.muted })
                .when(selected, |d| d.bg(alpha(theme.text, 0.09)).font_weight(FontWeight::MEDIUM))
                .when(!selected, |d| d.hover(|s| s.bg(alpha(theme.text, 0.05)).text_color(theme.text)))
                .on_click(cx.listener(move |this, _, _, cx| this.select(page, cx)))
                .child(icon(page.icon(), 14., if selected { theme.text } else { theme.muted }))
                .child(page.title())
        };
        let group = |label: &'static str| {
            div()
                .px(px(9.))
                .pt(px(14.))
                .pb(px(5.))
                .text_size(px(10.5))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(theme.faint)
                .child(label)
        };
        let overview: Vec<_> = Page::OVERVIEW.into_iter().map(|p| row(p, cx)).collect();
        let settings: Vec<_> = Page::SETTINGS.into_iter().map(|p| row(p, cx)).collect();

        div()
            .flex()
            .flex_col()
            .flex_none()
            .w(px(SIDEBAR_WIDTH))
            .h_full()
            .px(px(10.))
            // Room for the traffic lights, which sit over the sidebar.
            .pt(px(46.))
            .pb(px(12.))
            .gap(px(1.))
            .bg(theme.sidebar)
            .border_r_1()
            .border_color(theme.hairline())
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .px(px(9.))
                    .pb(px(4.))
                    .child(icon("icons/eye.svg", 18., theme.text))
                    .child(div().text_size(px(15.)).font_weight(FontWeight::SEMIBOLD).child("Netra")),
            )
            .child(group("Overview"))
            .children(overview)
            .child(group("Settings"))
            .children(settings)
            .child(div().flex_1())
            .child(self.live_status(theme, cx))
    }

    /// Whether the window is following the menu-bar app, and a refresh button.
    fn live_status(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let store = self.store.read(cx);
        let library = &store.library;
        let app = store.state().map(|s| &s.app);
        let refreshing = app.is_some_and(|a| a.refreshing);
        let (color, text) = match (&library.history_status, &library.snapshot_status) {
            _ if refreshing => (theme.accent, "Refreshing…".to_string()),
            (FileStatus::Current, FileStatus::Current) => {
                let age = library.snapshot.as_ref().map(|s| format::age(s.fetched_at, Utc::now())).unwrap_or_default();
                (theme.good, format!("Updated {age}"))
            }
            (FileStatus::Pending, _) | (_, FileStatus::Pending) => (theme.faint, "Reading…".to_string()),
            (FileStatus::Unreadable(_), _) | (_, FileStatus::Unreadable(_)) => {
                (theme.bad, "A file could not be read".to_string())
            }
            _ => (theme.warning, "Waiting for Netra".to_string()),
        };
        let detail = match app {
            Some(app) => match (&app.update_available, &app.version) {
                (Some(new), _) => format!("Netra {new} is available"),
                (None, Some(version)) => format!("Netra {version}"),
                _ => "Netra".to_string(),
            },
            None => "Open Netra in the menu bar to change settings".to_string(),
        };
        let connected = store.connected();
        div()
            .flex()
            .items_center()
            .gap(px(8.))
            .pl(px(9.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .flex_1()
                    .min_w(px(0.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_size(px(11.5))
                            .child(div().flex_none().size(px(7.)).rounded(px(3.5)).bg(color))
                            .child(text),
                    )
                    .child(div().text_size(px(10.5)).text_color(theme.faint).child(detail)),
            )
            .child(icon_button(
                theme,
                "refresh",
                "icons/refresh.svg",
                "Refresh now (⌘R)",
                connected && !refreshing,
                on_click(cx, |this: &mut Self, _, cx| {
                    this.store.update(cx, |store, cx| store.send("refresh", json!({}), cx));
                }),
            ))
    }

    fn toasts(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let toasts = self.store.read(cx).toasts.clone();
        div().absolute().bottom(px(18.)).right(px(18.)).flex().flex_col().items_end().gap(px(8.)).children(
            toasts.into_iter().map(|toast| {
                let color = if toast.is_error { theme.bad } else { theme.good };
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .max_w(px(420.))
                    .px(px(12.))
                    .py(px(9.))
                    .rounded(px(10.))
                    .bg(theme.surface)
                    .border_1()
                    .border_color(theme.hairline())
                    .shadow_lg()
                    .text_size(px(12.))
                    .child(icon(if toast.is_error { "icons/warning.svg" } else { "icons/check.svg" }, 13., color))
                    .child(toast.text)
            }),
        )
    }
}

impl Render for Dashboard {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(window);
        let page: AnyView = match self.page {
            Page::Usage => self.usage.clone().into(),
            Page::Subscriptions => self.subscriptions.clone().into(),
            Page::Accounts => self.accounts.clone().into(),
            _ => self.settings.clone().into(),
        };
        div()
            .relative()
            .flex()
            .size_full()
            .bg(theme.background)
            .text_color(theme.text)
            .font_family(".SystemUIFont")
            .child(self.sidebar(&theme, cx))
            .child(div().flex_1().min_w(px(0.)).h_full().child(page))
            .child(self.toasts(&theme, cx))
    }
}
