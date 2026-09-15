use std::path::PathBuf;

use berms_footage::Clip;
use berms_rides::Export;
use gpui_kit::base::{h_flex, v_flex};
use gpui_kit::component::{
    ActiveTheme as _, Disableable as _, Icon, IconName, Root, Sizable as _,
    button::{Button, ButtonVariants as _},
    label::Label,
    list::{List, ListEvent, ListState},
    scroll::ScrollableElement as _,
    status_bar::StatusBar,
};
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, Styled as _, Subscription, Window, div, rems,
};

use crate::{
    format,
    library::Library,
    run_list::{RunEntry, RunListDelegate},
    stitch, view,
};

const OFFSET_STEP_SECONDS: i64 = 60;

pub(crate) struct Studio {
    library: Library,
    entries: Vec<RunEntry>,
    unmatched_count: usize,
    selected: Option<usize>,
    busy: Option<SharedString>,
    message: SharedString,
    is_error: bool,
    list_state: Entity<ListState<RunListDelegate>>,
    _subscriptions: Vec<Subscription>,
}

#[derive(Clone, Copy)]
enum ImportKind {
    Footage,
    Export,
}

enum Loaded {
    Footage { root: PathBuf, clips: Vec<Clip> },
    Export(Export),
}

impl Studio {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let list_state =
            cx.new(|cx| ListState::new(RunListDelegate::new(Vec::new(), None), window, cx));
        let subscription = cx.subscribe(&list_state, Self::on_list_event);

        Self {
            library: Library::new(),
            entries: Vec::new(),
            unmatched_count: 0,
            selected: None,
            busy: None,
            message: "Ready".into(),
            is_error: false,
            list_state,
            _subscriptions: vec![subscription],
        }
    }

    fn on_list_event(
        &mut self,
        _list: Entity<ListState<RunListDelegate>>,
        event: &ListEvent,
        cx: &mut Context<Self>,
    ) {
        if let ListEvent::Select(index) = event
            && index.row < self.entries.len()
            && self.selected != Some(index.row)
        {
            self.selected = Some(index.row);
            cx.notify();
        }
    }

    fn import(&mut self, kind: ImportKind, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy.is_some() {
            return;
        }
        self.busy = Some(
            match kind {
                ImportKind::Footage => "Reading footage…",
                ImportKind::Export => "Reading export…",
            }
            .into(),
        );
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let picked: Option<Vec<PathBuf>> = match kind {
                ImportKind::Footage => rfd::AsyncFileDialog::new()
                    .set_title("Choose the folder with the day's footage")
                    .pick_folder()
                    .await
                    .map(|handle| vec![handle.path().to_path_buf()]),
                ImportKind::Export => rfd::AsyncFileDialog::new()
                    .set_title("Choose Berms exports or diagnostics logs")
                    .add_filter("Berms data", &["json", "jsonl"])
                    .pick_files()
                    .await
                    .map(|files| {
                        files
                            .into_iter()
                            .map(|handle| handle.path().to_path_buf())
                            .collect()
                    }),
            };

            let Some(paths) = picked else {
                this.update_in(cx, |this, _, cx| {
                    this.busy = None;
                    cx.notify();
                })
                .ok();
                return;
            };

            let loaded = cx
                .background_executor()
                .spawn(async move {
                    match kind {
                        ImportKind::Footage => {
                            let Some(root) = paths.into_iter().next() else {
                                return Err("no folder chosen".to_owned());
                            };
                            berms_footage::scan_and_probe(&root)
                                .map(|clips| Loaded::Footage { root, clips })
                                .map_err(|error| error.to_string())
                        }
                        ImportKind::Export => {
                            let mut days = Vec::new();
                            for path in paths {
                                if is_diagnostics_log(&path) {
                                    days.push(
                                        berms_logs::load_day(&path).map_err(|e| e.to_string())?,
                                    );
                                } else {
                                    days.extend(
                                        Export::load(&path).map_err(|e| e.to_string())?.days,
                                    );
                                }
                            }
                            Ok(Loaded::Export(Export::from_days(days)))
                        }
                    }
                })
                .await;

            this.update_in(cx, |this, window, cx| {
                this.busy = None;
                match loaded {
                    Ok(Loaded::Footage { root, clips }) => {
                        let count = this.library.set_footage(root, clips);
                        this.set_message(format!("Found {count} clips"), false, cx);
                        this.rebuild(window, cx);
                    }
                    Ok(Loaded::Export(export)) => {
                        let runs = this.library.set_export(export);
                        this.set_message(format!("Loaded {runs} runs"), false, cx);
                        this.rebuild(window, cx);
                    }
                    Err(error) => this.set_message(format!("Import failed: {error}"), true, cx),
                }
            })
            .ok();
        })
        .detach();
    }

    fn build_selected(&mut self, cx: &mut Context<Self>) {
        if self.busy.is_some() {
            return;
        }
        let Some(entry) = self.selected_entry().cloned() else {
            return;
        };
        let Some(segment) = self.library.find_segment(&entry).cloned() else {
            return;
        };
        let Some(root) = self
            .library
            .footage_root()
            .map(std::path::Path::to_path_buf)
        else {
            self.set_message("Add a footage folder first", true, cx);
            return;
        };

        let clips = self.library.footage_for(&entry);
        if clips.is_empty() {
            self.set_message("No footage matched this run", true, cx);
            return;
        }

        let output = stitch::output_path(
            &root,
            segment.started_at,
            &segment.title(),
            entry.run_number,
        );

        self.busy = Some("Building video…".into());
        cx.notify();

        let output_for_task = output.clone();
        let task = cx.background_spawn(async move { stitch::stitch_run(&clips, &output_for_task) });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |this, cx| {
                this.busy = None;
                match result {
                    Ok(()) => this.set_message(format!("Built {}", output.display()), false, cx),
                    Err(error) => this.set_message(format!("Build failed: {error}"), true, cx),
                }
            })
            .ok();
        })
        .detach();
    }

    fn shift_clock(&mut self, delta: i64, window: &mut Window, cx: &mut Context<Self>) {
        self.library.shift_clock(delta);
        self.rebuild(window, cx);
    }

    fn rebuild(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.entries = self.library.entries();
        self.unmatched_count = self.library.unmatched_count();

        if self.entries.is_empty() {
            self.selected = None;
        } else if self.selected.is_none_or(|ix| ix >= self.entries.len()) {
            self.selected = Some(0);
        }

        self.list_state = cx.new(|cx| {
            ListState::new(
                RunListDelegate::new(self.entries.clone(), self.selected),
                window,
                cx,
            )
        });
        self._subscriptions.clear();
        self._subscriptions
            .push(cx.subscribe(&self.list_state, Self::on_list_event));
        cx.notify();
    }

    fn set_message(
        &mut self,
        text: impl Into<SharedString>,
        is_error: bool,
        cx: &mut Context<Self>,
    ) {
        self.message = text.into();
        self.is_error = is_error;
        cx.notify();
    }

    fn selected_entry(&self) -> Option<&RunEntry> {
        self.selected.and_then(|ix| self.entries.get(ix))
    }

    fn render_toolbar(&mut self, cx: &mut Context<Self>) -> AnyElement {
        h_flex()
            .h_12()
            .px_3()
            .gap_2()
            .items_center()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                Button::new("add-footage")
                    .label("Add footage…")
                    .icon(IconName::FolderOpen)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.import(ImportKind::Footage, window, cx)
                    })),
            )
            .child(
                Button::new("add-day")
                    .label("Add day…")
                    .icon(IconName::Calendar)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.import(ImportKind::Export, window, cx)
                    })),
            )
            .child(div().flex_1())
            .child(
                h_flex()
                    .items_center()
                    .gap_1()
                    .child(view::muted("Footage clock", cx))
                    .child(
                        Button::new("clock-back")
                            .ghost()
                            .icon(IconName::Minus)
                            .tooltip("Shift the footage clock one minute earlier")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.shift_clock(-OFFSET_STEP_SECONDS, window, cx)
                            })),
                    )
                    .child(Label::new(format::offset(self.library.offset_seconds())).text_sm())
                    .child(
                        Button::new("clock-forward")
                            .ghost()
                            .icon(IconName::Plus)
                            .tooltip("Shift the footage clock one minute later")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.shift_clock(OFFSET_STEP_SECONDS, window, cx)
                            })),
                    ),
            )
            .into_any_element()
    }

    fn render_sidebar(&mut self, cx: &mut Context<Self>) -> AnyElement {
        v_flex()
            .w_72()
            .h_full()
            .border_r_1()
            .border_color(cx.theme().border)
            .child(h_flex().px_3().py_2().child(view::muted("Runs", cx)))
            .child(div().flex_1().min_h_0().child(List::new(&self.list_state)))
            .into_any_element()
    }

    fn render_detail(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if let Some(entry) = self.selected_entry().cloned() {
            self.render_run(&entry, cx)
        } else if self.entries.is_empty() {
            self.render_empty(cx)
        } else {
            view::centered(view::muted("Select a run to see its footage", cx))
        }
    }

    fn render_run(&mut self, entry: &RunEntry, cx: &mut Context<Self>) -> AnyElement {
        let Some(segment) = self.library.find_segment(entry).cloned() else {
            return div().into_any_element();
        };

        let matched = self.library.matching_clips(&segment);
        let unassigned = self.library.unmatched_clips();
        let busy = self.busy.is_some();

        let clip_rows: Vec<AnyElement> = matched
            .iter()
            .map(|&ix| view::clip_row(&self.library.clips()[ix], false, cx))
            .collect();

        let unassigned_rows: Vec<AnyElement> = if unassigned.is_empty() {
            vec![view::muted("Every clip landed on a run.", cx)]
        } else {
            unassigned
                .iter()
                .map(|clip| view::clip_row(clip, true, cx))
                .collect()
        };

        v_flex()
            .flex_1()
            .min_w_0()
            .h_full()
            .child(
                h_flex()
                    .items_center()
                    .justify_between()
                    .gap_4()
                    .px_6()
                    .py_4()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        v_flex()
                            .min_w_0()
                            .gap_1()
                            .child(Label::new(entry.title.clone()).text_lg())
                            .child(view::muted(entry.subtitle.to_string(), cx)),
                    )
                    .child(
                        Button::new("build-run")
                            .label("Build video")
                            .primary()
                            .loading(busy)
                            .disabled(busy || clip_rows.is_empty())
                            .on_click(cx.listener(|this, _, _, cx| this.build_selected(cx))),
                    ),
            )
            .child(
                div()
                    .id("run-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scrollbar()
                    .p_6()
                    .child(
                        v_flex()
                            .gap_6()
                            .child(
                                h_flex()
                                    .gap_6()
                                    .child(view::stat(
                                        "Time",
                                        format::duration(segment.duration()),
                                        cx,
                                    ))
                                    .child(view::stat(
                                        "Distance",
                                        format::distance(segment.distance_meters),
                                        cx,
                                    ))
                                    .child(view::stat(
                                        "Vert",
                                        format::vertical(segment.vertical_meters),
                                        cx,
                                    ))
                                    .child(view::stat(
                                        "Max speed",
                                        format::speed(segment.maximum_speed_meters_per_second),
                                        cx,
                                    ))
                                    .child(view::stat("Clips", clip_rows.len().to_string(), cx)),
                            )
                            .child(
                                v_flex()
                                    .gap_1()
                                    .child(view::section_label("Trails", cx))
                                    .child(Label::new(if segment.trails.is_empty() {
                                        "No catalog match for this run".to_owned()
                                    } else {
                                        segment.trails.join(" → ")
                                    })),
                            )
                            .child(view::section(
                                &format!("Clips ({})", clip_rows.len()),
                                clip_rows,
                                cx,
                            ))
                            .child(view::section(
                                &format!("Not matched to a run ({})", unassigned_rows.len()),
                                unassigned_rows,
                                cx,
                            )),
                    ),
            )
            .into_any_element()
    }

    fn render_empty(&mut self, cx: &mut Context<Self>) -> AnyElement {
        view::centered(
            v_flex()
                .items_center()
                .gap_3()
                .max_w(rems(26.))
                .child(
                    Icon::new(IconName::Map)
                        .large()
                        .text_color(cx.theme().muted_foreground),
                )
                .child(Label::new("Line up your footage").text_lg())
                .child(
                    Label::new(
                        "Add the folder with this day's clips and the Berms export. Clips are matched to runs by time.",
                    )
                    .text_sm()
                    .text_center()
                    .text_color(cx.theme().muted_foreground),
                )
                .child(
                    h_flex()
                        .gap_2()
                        .child(
                            Button::new("empty-add-footage")
                                .label("Add footage…")
                                .icon(IconName::FolderOpen)
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.import(ImportKind::Footage, window, cx)
                                })),
                        )
                        .child(
                            Button::new("empty-add-day")
                                .outline()
                                .label("Add day…")
                                .icon(IconName::Calendar)
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.import(ImportKind::Export, window, cx)
                                })),
                        ),
                ),
        )
    }

    fn render_status(&self, cx: &App) -> AnyElement {
        let left: SharedString = match &self.busy {
            Some(busy) => busy.clone(),
            None => self.message.clone(),
        };
        let left_color = if self.is_error {
            cx.theme().danger
        } else {
            cx.theme().muted_foreground
        };

        StatusBar::new()
            .left(Label::new(left).text_sm().text_color(left_color))
            .right(view::muted(
                format!(
                    "{} runs · {} clips · {} unmatched",
                    self.entries.len(),
                    self.library.clip_count(),
                    self.unmatched_count
                ),
                cx,
            ))
            .into_any_element()
    }
}

fn is_diagnostics_log(path: &std::path::Path) -> bool {
    path.extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
}

impl Render for Studio {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(self.render_toolbar(cx))
            .child(
                h_flex()
                    .items_stretch()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_sidebar(cx))
                    .child(self.render_detail(cx)),
            )
            .child(self.render_status(cx))
            .children(Root::render_dialog_layer(window, cx))
            .children(Root::render_sheet_layer(window, cx))
            .children(Root::render_notification_layer(window, cx))
    }
}
