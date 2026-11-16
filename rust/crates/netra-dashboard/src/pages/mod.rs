pub mod accounts;
pub mod settings;
pub mod subscriptions;
pub mod usage;

/// Sidebar destinations. The ids are the ones the Swift app passes with
/// `--page` and in `navigate` (see `docs/dashboard-bridge.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Page {
    Usage,
    Subscriptions,
    Accounts,
    MenuBar,
    Limits,
    Providers,
    Notifications,
    General,
}

impl Page {
    pub const OVERVIEW: [Page; 3] = [Page::Usage, Page::Subscriptions, Page::Accounts];
    pub const SETTINGS: [Page; 5] = [Page::MenuBar, Page::Limits, Page::Providers, Page::Notifications, Page::General];

    pub fn from_id(id: &str) -> Option<Page> {
        Self::OVERVIEW.into_iter().chain(Self::SETTINGS).find(|p| p.id() == id.to_lowercase())
    }

    /// `--page subscriptions` opens on that page.
    pub fn from_args() -> Page {
        let args: Vec<String> = std::env::args().collect();
        args.windows(2).find(|w| w[0] == "--page").and_then(|w| Page::from_id(&w[1])).unwrap_or(Page::Usage)
    }

    pub fn id(self) -> &'static str {
        match self {
            Page::Usage => "usage",
            Page::Subscriptions => "subscriptions",
            Page::Accounts => "accounts",
            Page::MenuBar => "menubar",
            Page::Limits => "limits",
            Page::Providers => "providers",
            Page::Notifications => "notifications",
            Page::General => "general",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Page::Usage => "Usage",
            Page::Subscriptions => "Subscriptions",
            Page::Accounts => "Accounts",
            Page::MenuBar => "Menu Bar",
            Page::Limits => "Limits",
            Page::Providers => "Providers",
            Page::Notifications => "Notifications",
            Page::General => "General",
        }
    }

    pub fn subtitle(self) -> &'static str {
        match self {
            Page::Usage => "Coding-agent activity and API-equivalent cost",
            Page::Subscriptions => "Plan limits, resets, and pace for every provider",
            Page::Accounts => "Switch Claude Code and Codex between your accounts",
            Page::MenuBar => "What the menu-bar label and its popover show",
            Page::Limits => "How limit bars, resets, and pace read",
            Page::Providers => "Which agents appear, and optional account connections",
            Page::Notifications => "When Netra should get your attention",
            Page::General => "Startup, your data, and small delights",
        }
    }

    pub fn icon(self) -> &'static str {
        match self {
            Page::Usage => "icons/usage.svg",
            Page::Subscriptions => "icons/limits.svg",
            Page::Accounts => "icons/accounts.svg",
            Page::MenuBar => "icons/menubar.svg",
            Page::Limits => "icons/sliders.svg",
            Page::Providers => "icons/providers.svg",
            Page::Notifications => "icons/bell.svg",
            Page::General => "icons/gear.svg",
        }
    }
}
