//! Small building blocks shared by the pages: panels, rows, meters and the
//! controls a settings page needs. Plain functions returning elements; none
//! hold state.

use gpui::{
    AnyElement, AnyView, App, ClickEvent, Context, Div, FontWeight, IntoElement, ParentElement, Render, Rgba,
    SharedString, Stateful, Styled, Svg, Window, div, prelude::*, px, relative, svg,
};

use crate::assets::provider_mark;
use crate::theme::{Theme, alpha};

pub type Click = Box<dyn Fn(&ClickEvent, &mut Window, &mut App) + 'static>;

/// A single-color icon from the embedded set.
pub fn icon(path: &'static str, size: f32, color: impl Into<gpui::Hsla>) -> Svg {
    svg().path(path).size(px(size)).flex_none().text_color(color.into())
}

/// A provider's mark on a soft tile of its own color. Providers without a
/// published mark get a dot, never an invented logo.
pub fn provider_badge(theme: &Theme, agent: &str, size: f32) -> Div {
    let color = theme.provider(agent);
    // OpenAI's and Cursor's marks are monochrome by their brand rules.
    let ink = match agent.to_lowercase().as_str() {
        "codex" | "cursor" | "copilot" | "opencode" => theme.text,
        _ => color,
    };
    div()
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .size(px(size))
        .rounded(px(size * 0.28))
        .bg(alpha(color, if theme.dark { 0.2 } else { 0.13 }))
        .child(match provider_mark(agent) {
            Some(path) => icon(path, size * 0.56, ink).into_any_element(),
            None => div().size(px(size * 0.3)).rounded(px(size)).bg(color).into_any_element(),
        })
}

/// Page title, one line of explanation, and controls on the right.
pub fn page_header(theme: &Theme, title: &'static str, subtitle: &'static str, accessory: impl IntoElement) -> Div {
    div()
        .flex()
        .items_end()
        .gap(px(16.))
        .pb(px(4.))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .flex_1()
                .min_w(px(0.))
                .child(div().text_size(px(26.)).font_weight(FontWeight::SEMIBOLD).child(title))
                .child(div().text_size(px(12.5)).text_color(theme.muted).child(subtitle)),
        )
        .child(accessory)
}

/// A plain card.
pub fn card(theme: &Theme) -> Div {
    div()
        .flex()
        .flex_col()
        .flex_none()
        .gap(px(14.))
        .p(px(18.))
        .rounded(px(14.))
        .bg(theme.surface)
        .border_1()
        .border_color(theme.hairline())
}

/// A titled card. `detail` sits at the right of the title line.
pub fn panel(theme: &Theme, title: impl Into<SharedString>, detail: Option<SharedString>) -> Div {
    card(theme).child(
        div()
            .flex()
            .items_center()
            .justify_between()
            .gap(px(12.))
            .child(div().text_size(px(13.)).font_weight(FontWeight::SEMIBOLD).child(title.into()))
            .children(detail.map(|d| div().text_size(px(11.)).text_color(theme.muted).child(d))),
    )
}

/// A group label above a run of cards.
pub fn section_label(theme: &Theme, text: &'static str) -> Div {
    div().pt(px(6.)).text_size(px(11.)).font_weight(FontWeight::SEMIBOLD).text_color(theme.faint).child(text)
}

pub fn divider(theme: &Theme) -> Div {
    div().h(px(1.)).flex_none().bg(theme.hairline())
}

/// A one-line notice above the page content.
pub fn banner(text: impl Into<SharedString>, color: Rgba) -> Div {
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .px(px(12.))
        .py(px(9.))
        .rounded(px(10.))
        .bg(alpha(color, 0.1))
        .text_color(color)
        .text_size(px(12.))
        .font_weight(FontWeight::MEDIUM)
        .child(icon("icons/warning.svg", 13., color))
        .child(div().flex_1().min_w(px(0.)).child(text.into()))
}

/// A small rounded label, such as a plan name.
pub fn tag(text: impl Into<SharedString>, color: Rgba) -> Div {
    div()
        .flex_none()
        .px(px(7.))
        .py(px(1.5))
        .rounded(px(6.))
        .bg(alpha(color, 0.14))
        .text_color(color)
        .text_size(px(10.5))
        .font_weight(FontWeight::SEMIBOLD)
        .child(text.into())
}

/// A small square color key next to a label.
pub fn swatch(color: impl Into<gpui::Hsla>, size: f32) -> Div {
    div().flex_none().size(px(size)).rounded(px(size * 0.3)).bg(color.into())
}

/// A horizontal bar filled to `fraction` (clamped to 0...1).
pub fn meter(theme: &Theme, fraction: f64, color: Rgba, height: f32) -> Div {
    let fraction = fraction.clamp(0.0, 1.0) as f32;
    div().w_full().h(px(height)).rounded(px(height / 2.)).bg(theme.well).overflow_hidden().child(
        div()
            .h_full()
            .w(relative(fraction))
            .min_w(px(if fraction > 0.0 { height } else { 0. }))
            .rounded(px(height / 2.))
            .bg(color),
    )
}

/// A row of mutually exclusive options. `on_select` gets the chosen index.
pub fn segmented(
    theme: &Theme,
    id: &'static str,
    labels: &[&'static str],
    selected: usize,
    on_select: impl Fn(usize, &mut Window, &mut App) + Clone + 'static,
) -> Stateful<Div> {
    div().id(id).flex().flex_none().p(px(2.)).gap(px(2.)).rounded(px(8.)).bg(theme.well).children(
        labels.iter().enumerate().map(|(index, label)| {
            let on_select = on_select.clone();
            let active = index == selected;
            div()
                .id((id, index))
                .px(px(11.))
                .py(px(3.5))
                .rounded(px(6.))
                .text_size(px(12.))
                .font_weight(if active { FontWeight::SEMIBOLD } else { FontWeight::NORMAL })
                .text_color(if active { theme.text } else { theme.muted })
                .when(active, |d| d.bg(theme.surface).shadow_sm())
                .when(!active, |d| d.cursor_pointer().hover(|s| s.text_color(theme.text)))
                .on_click(move |_, window, cx| on_select(index, window, cx))
                .child(*label)
        }),
    )
}

/// An on/off switch.
pub fn toggle(theme: &Theme, id: impl Into<gpui::ElementId>, on: bool, on_click: Click) -> Stateful<Div> {
    div()
        .id(id)
        .flex()
        .flex_none()
        .items_center()
        .w(px(34.))
        .h(px(20.))
        .p(px(2.))
        .rounded(px(10.))
        .cursor_pointer()
        .bg(if on { theme.good } else { theme.well })
        .when(on, |d| d.justify_end())
        .on_click(on_click)
        .child(div().size(px(16.)).rounded(px(8.)).bg(gpui::white()).shadow_sm())
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ButtonKind {
    Primary,
    Secondary,
    Danger,
}

/// A text button, optionally led by an icon. A disabled button ignores clicks.
pub fn button(
    theme: &Theme,
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    lead: Option<&'static str>,
    kind: ButtonKind,
    enabled: bool,
    on_click: Click,
) -> Stateful<Div> {
    let (fill, ink) = match kind {
        ButtonKind::Primary => (alpha(theme.primary, 1.0), theme.on_primary),
        ButtonKind::Secondary => (alpha(theme.well, 1.0), theme.text),
        ButtonKind::Danger => (alpha(theme.bad, 0.12), theme.bad),
    };
    div()
        .id(id)
        .flex()
        .flex_none()
        .items_center()
        .gap(px(6.))
        .px(px(11.))
        .py(px(5.))
        .rounded(px(7.))
        .bg(fill)
        .text_color(ink)
        .text_size(px(12.))
        .font_weight(FontWeight::MEDIUM)
        .when(enabled, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)).on_click(on_click))
        .when(!enabled, |d| d.opacity(0.45))
        .children(lead.map(|path| icon(path, 12., ink)))
        .child(label.into())
}

/// A square button that is only an icon; `hint` is its tooltip.
pub fn icon_button(
    theme: &Theme,
    id: impl Into<gpui::ElementId>,
    path: &'static str,
    hint: &'static str,
    enabled: bool,
    on_click: Click,
) -> Stateful<Div> {
    div()
        .id(id)
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .size(px(24.))
        .rounded(px(6.))
        .when(enabled, |d| d.cursor_pointer().hover(|s| s.bg(alpha(theme.text, 0.08))).on_click(on_click))
        .when(!enabled, |d| d.opacity(0.3))
        .tooltip(text_tooltip(hint))
        .child(icon(path, 13., theme.muted))
}

/// A value with a minus and a plus beside it.
pub fn stepper(theme: &Theme, id: &'static str, value: String, minus: Click, plus: Click) -> Div {
    let side = |suffix: &'static str, glyph: &'static str, click: Click| {
        div()
            .id((id, if suffix == "minus" { 0usize } else { 1usize }))
            .flex()
            .items_center()
            .justify_center()
            .w(px(24.))
            .h(px(24.))
            .cursor_pointer()
            .text_size(px(14.))
            .text_color(theme.muted)
            .hover(|s| s.bg(alpha(theme.text, 0.08)))
            .on_click(click)
            .child(glyph)
    };
    div()
        .flex()
        .flex_none()
        .items_center()
        .rounded(px(7.))
        .bg(theme.well)
        .overflow_hidden()
        .child(side("minus", "−", minus))
        .child(
            div()
                .min_w(px(58.))
                .px(px(6.))
                .flex()
                .justify_center()
                .text_size(px(12.))
                .font_weight(FontWeight::MEDIUM)
                .child(value),
        )
        .child(side("plus", "+", plus))
}

/// One settings line: the title with its control on the right, and the
/// explanation underneath. The explanation is a direct child of the column,
/// not of the title row, so GPUI measures its wrapped height at the real
/// width (text inside a flex row is measured before the row is sized).
pub fn setting_row(
    theme: &Theme,
    title: impl Into<SharedString>,
    detail: Option<SharedString>,
    control: impl IntoElement,
) -> Div {
    div()
        .flex()
        .flex_col()
        .gap(px(3.))
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(16.))
                .min_h(px(22.))
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .text_size(px(12.5))
                        .font_weight(FontWeight::MEDIUM)
                        .truncate()
                        .child(title.into()),
                )
                .child(div().flex_none().child(control)),
        )
        .children(detail.map(|d| div().pr(px(120.)).text_size(px(11.5)).text_color(theme.muted).child(d)))
}

/// A headline number with a caption and optional period-over-period change.
pub struct StatTile {
    pub title: &'static str,
    pub value: String,
    pub caption: String,
    /// Relative change and what it compares with; `None` shows `caption` only.
    pub change: Option<(f64, &'static str)>,
    /// Daily values for a tiny bar sparkline.
    pub spark: Vec<f64>,
}

impl StatTile {
    pub fn render(self, theme: &Theme) -> AnyElement {
        let caption = match self.change {
            Some((change, versus)) => div()
                .flex()
                .gap(px(4.))
                .child(div().text_color(theme.text).child(format!(
                    "{} {:.0}%",
                    if change >= 0.0 { "↑" } else { "↓" },
                    change.abs() * 100.0
                )))
                .child(div().text_color(theme.muted).child(format!("vs {versus}"))),
            None => div().text_color(theme.muted).child(self.caption),
        };
        let peak = self.spark.iter().cloned().fold(0.0, f64::max);
        card(theme)
            .flex_1()
            .min_w(px(0.))
            .gap(px(8.))
            .p(px(16.))
            .child(div().text_size(px(11.5)).text_color(theme.muted).child(self.title))
            .child(
                div()
                    .flex()
                    .items_end()
                    .justify_between()
                    .gap(px(8.))
                    .child(div().text_size(px(26.)).font_weight(FontWeight::SEMIBOLD).child(self.value))
                    .when(peak > 0.0, |d| {
                        d.child(div().flex().flex_none().items_end().w(px(76.)).h(px(24.)).gap(px(1.5)).children(
                            self.spark.iter().map(|v| {
                                div()
                                    .flex_1()
                                    .max_w(px(5.))
                                    .h(px((v / peak * 22.0).max(1.5) as f32))
                                    .rounded(px(1.5))
                                    .bg(alpha(theme.text, 0.32))
                            }),
                        ))
                    }),
            )
            .child(div().text_size(px(11.)).child(caption))
            .into_any_element()
    }
}

/// Adapts a view method to the `Fn(index, …)` callback `segmented` takes.
pub fn on_index<V: 'static>(
    cx: &Context<V>,
    f: impl Fn(&mut V, usize, &mut Context<V>) + 'static,
) -> impl Fn(usize, &mut Window, &mut App) + Clone + 'static {
    let view = cx.entity().downgrade();
    let f = std::rc::Rc::new(f);
    move |index, _, cx| {
        let f = f.clone();
        let _ = view.update(cx, |this, cx| f(this, index, cx));
    }
}

/// Adapts a view method to a click handler.
pub fn on_click<V: 'static>(cx: &Context<V>, f: impl Fn(&mut V, &mut Window, &mut Context<V>) + 'static) -> Click {
    let view = cx.entity().downgrade();
    Box::new(move |_, window, cx| {
        let _ = view.update(cx, |this, cx| f(this, window, cx));
    })
}

struct Tooltip(SharedString);

impl Render for Tooltip {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(window);
        div()
            .px(px(8.))
            .py(px(4.))
            .rounded(px(6.))
            .bg(theme.primary)
            .text_color(theme.on_primary)
            .text_size(px(11.5))
            .font_family(".SystemUIFont")
            .shadow_md()
            .child(self.0.clone())
    }
}

/// A plain text tooltip builder for `.tooltip(…)`.
pub fn text_tooltip(text: impl Into<SharedString>) -> impl Fn(&mut Window, &mut App) -> AnyView + 'static {
    let text: SharedString = text.into();
    move |_, cx| cx.new(|_| Tooltip(text.clone())).into()
}

pub fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
}

/// Width of the sidebar; the page column is sized from what is left.
pub const SIDEBAR_WIDTH: f32 = 214.;

/// The scrolling body every page sits in. The top inset clears the
/// transparent title bar.
///
/// The column gets an explicit width worked out from the window instead of
/// `max_w`: GPUI measures wrapped text before a max-width clamp applies, so
/// a clamped column reports its text one line short and rows spill out of
/// their cards.
pub fn page_scroll(id: &'static str, window: &Window, max_width: f32) -> (Stateful<Div>, Div) {
    let available = f32::from(window.viewport_size().width) - SIDEBAR_WIDTH;
    let width = available.min(max_width).max(320.);
    (
        div().id(id).size_full().overflow_y_scroll().flex().flex_col().items_center(),
        div().flex().flex_col().flex_none().w(px(width)).gap(px(16.)).px(px(32.)).pt(px(44.)).pb(px(32.)),
    )
}
