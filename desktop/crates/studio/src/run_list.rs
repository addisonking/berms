use gpui_kit::base::v_flex;
use gpui_kit::component::{
    ActiveTheme as _, IndexPath,
    label::Label,
    list::{ListDelegate, ListItem, ListState},
};
use gpui_kit::{App, Context, ParentElement as _, SharedString, Styled as _, Window};

#[derive(Clone)]
pub(crate) struct RunEntry {
    pub(crate) day_id: String,
    pub(crate) segment_id: String,
    pub(crate) title: SharedString,
    pub(crate) subtitle: SharedString,
    pub(crate) run_number: usize,
}

#[derive(Clone)]
pub(crate) struct RunListDelegate {
    entries: Vec<RunEntry>,
    selected: Option<IndexPath>,
}

impl RunListDelegate {
    pub(crate) fn new(entries: Vec<RunEntry>, selected: Option<usize>) -> Self {
        Self {
            entries,
            selected: selected.map(IndexPath::new),
        }
    }
}

impl ListDelegate for RunListDelegate {
    type Item = ListItem;

    fn items_count(&self, _section: usize, _cx: &App) -> usize {
        self.entries.len()
    }

    fn render_item(
        &mut self,
        ix: IndexPath,
        _window: &mut Window,
        cx: &mut Context<ListState<Self>>,
    ) -> Option<Self::Item> {
        let entry = self.entries.get(ix.row)?;
        Some(
            ListItem::new(ix)
                .child(
                    v_flex()
                        .min_w_0()
                        .gap_1()
                        .child(Label::new(entry.title.clone()))
                        .child(
                            Label::new(entry.subtitle.clone())
                                .text_sm()
                                .text_color(cx.theme().muted_foreground),
                        ),
                )
                .selected(self.selected == Some(ix))
                .on_click(cx.listener(move |state, _, window, cx| {
                    state.set_selected_index(Some(ix), window, cx);
                })),
        )
    }

    fn set_selected_index(
        &mut self,
        ix: Option<IndexPath>,
        _window: &mut Window,
        cx: &mut Context<ListState<Self>>,
    ) {
        self.selected = ix;
        cx.notify();
    }
}
