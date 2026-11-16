//! Netra's main window (GPUI): usage, limits, accounts and settings over the
//! files the Swift menu-bar app records. It reads those files and asks the
//! app to make changes through command files; it never runs ccusage, writes
//! usage or preferences, or touches a sign-in. macOS only for now.
//!
//!     cargo run -p netra-dashboard
//!     cargo run -p netra-dashboard -- --page subscriptions
//!     NETRA_DATA_DIR=/some/folder cargo run -p netra-dashboard

mod assets;
mod components;
mod dashboard;
mod pages;
mod store;
mod theme;

use gpui::{
    App, AppContext, Application, Bounds, KeyBinding, Menu, MenuItem, TitlebarOptions, WindowBounds, WindowOptions,
    actions, point, px, size,
};

use crate::dashboard::Dashboard;
use crate::pages::Page;
use crate::store::UsageStore;

actions!(netra_dashboard, [Quit, CloseWindow, Refresh]);

fn main() {
    let Some(dir) = netra_core::paths::data_dir() else {
        eprintln!("netra-dashboard: HOME is not set and NETRA_DATA_DIR is empty");
        std::process::exit(1);
    };

    Application::new().with_assets(assets::Assets).run(move |cx: &mut App| {
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.on_action(|_: &CloseWindow, cx| cx.quit());
        cx.bind_keys([
            KeyBinding::new("cmd-q", Quit, None),
            KeyBinding::new("cmd-w", CloseWindow, None),
            KeyBinding::new("cmd-r", Refresh, None),
        ]);
        cx.set_menus(vec![
            Menu {
                name: "Netra".into(),
                items: vec![
                    MenuItem::action("Refresh Now", Refresh),
                    MenuItem::separator(),
                    MenuItem::action("Quit Netra", Quit),
                ],
            },
            Menu { name: "Window".into(), items: vec![MenuItem::action("Close", CloseWindow)] },
        ]);
        // One window; closing it ends this process. The menu-bar app stays.
        cx.on_window_closed(|cx| cx.quit()).detach();

        let store = UsageStore::new(dir, cx);
        let refresh_store = store.clone();
        cx.on_action(move |_: &Refresh, cx| {
            refresh_store.update(cx, |store, cx| store.send("refresh", serde_json::json!({}), cx));
        });

        let bounds = Bounds::centered(None, size(px(1180.), px(820.)), cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(size(px(960.), px(660.))),
            titlebar: Some(TitlebarOptions {
                title: Some("Netra".into()),
                appears_transparent: true,
                traffic_light_position: Some(point(px(16.), px(18.))),
            }),
            app_id: Some("com.sahabji0P.netra.dashboard".into()),
            ..Default::default()
        };
        cx.open_window(options, |window, cx| cx.new(|cx| Dashboard::new(store, Page::from_args(), window, cx)))
            .expect("open the dashboard window");
        cx.activate(true);
    });
}
