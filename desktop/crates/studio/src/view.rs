use berms_footage::Clip;
use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::{ActiveTheme as _, Icon, IconName, Sizable as _, label::Label};
use gpui_kit::{AnyElement, App, IntoElement, ParentElement as _, Styled as _};

use crate::format;

pub(crate) fn centered(content: impl IntoElement) -> AnyElement {
    v_flex()
        .flex_1()
        .min_w_0()
        .size_full()
        .items_center()
        .justify_center()
        .child(content)
        .into_any_element()
}

pub(crate) fn section_label(title: &str, cx: &App) -> AnyElement {
    Label::new(title.to_owned())
        .text_sm()
        .text_color(cx.theme().muted_foreground)
        .into_any_element()
}

pub(crate) fn section(title: &str, children: Vec<AnyElement>, cx: &App) -> AnyElement {
    v_flex()
        .gap_1()
        .child(section_label(title, cx))
        .children(children)
        .into_any_element()
}

pub(crate) fn muted(text: impl Into<String>, cx: &App) -> AnyElement {
    Label::new(text.into())
        .text_sm()
        .text_color(cx.theme().muted_foreground)
        .into_any_element()
}

pub(crate) fn stat(label: &str, value: String, cx: &App) -> AnyElement {
    v_flex()
        .gap_1()
        .child(muted(label, cx))
        .child(Label::new(value))
        .into_any_element()
}

pub(crate) fn clip_row(clip: &Clip, unassigned: bool, cx: &App) -> AnyElement {
    let chapters = match clip.chapter_count() {
        1 => "1 chapter".to_owned(),
        count => format!("{count} chapters"),
    };
    let meta = if unassigned {
        format!("{chapters} · not on any run")
    } else {
        format!("{chapters} · {}", format::duration(clip.duration))
    };

    h_flex()
        .items_center()
        .gap_3()
        .py_2()
        .border_b_1()
        .border_color(cx.theme().border)
        .child(
            Icon::new(IconName::File)
                .small()
                .text_color(cx.theme().muted_foreground),
        )
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap_1()
                .child(Label::new(clip.name.clone()))
                .child(muted(meta, cx)),
        )
        .child(muted(format::clock(clip.recorded_at), cx))
        .into_any_element()
}
