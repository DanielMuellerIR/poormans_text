use super::widgets::{bounded_dropdown, scroll, text_view};
use crate::{
    Shared, View, clipboard_ui, comparison,
    model::{self, OutputFile, tr},
    read_output,
};
use gtk::{gio, glib, prelude::*};
use serde_json::Value;
use std::time::Duration;

pub(super) struct Results {
    pub tabs: gtk::Notebook,
    pub preview: gtk::TextView,
    pub diagnostics: gtk::TextView,
    pub details: gtk::TextView,
    pub files: gtk::DropDown,
    pub open: gtk::Button,
    pub copy: gtk::Button,
    pub compare: gtk::Button,
}

pub(super) fn build(outer: &gtk::Box) -> Results {
    let result_tabs = gtk::Notebook::new();
    result_tabs.set_vexpand(true);
    let preview = text_view();
    let diagnostics = text_view();
    result_tabs.append_page(
        &scroll(&preview, 130),
        Some(&gtk::Label::new(Some(tr(
            "Markdown-Vorschau",
            "Markdown preview",
        )))),
    );
    let diagnostic_page = gtk::Box::new(gtk::Orientation::Vertical, 8);
    diagnostic_page.append(&scroll(&diagnostics, 100));
    let details = text_view();
    let details_expander = gtk::Expander::builder()
        .label(tr("Technische Details (JSON)", "Technical details (JSON)"))
        .build();
    details_expander.set_child(Some(&scroll(&details, 100)));
    diagnostic_page.append(&details_expander);
    result_tabs.append_page(
        &diagnostic_page,
        Some(&gtk::Label::new(Some(tr(
            "Diagnosen / Katalog",
            "Diagnostics / catalog",
        )))),
    );
    outer.append(&result_tabs);
    let result_actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(3)
        .column_spacing(8)
        .row_spacing(8)
        .build();
    let files = gtk::DropDown::from_strings(&[tr("Noch kein Ergebnis", "No result yet")]);
    files.set_tooltip_text(Some(tr(
        "Wählt die Ausgabedatei für Vorschau, Zwischenablage und Quellvergleich.",
        "Selects the output file for preview, copying and source comparison.",
    )));
    files.set_sensitive(false);
    files.set_enable_search(true);
    bounded_dropdown(&files);
    files.set_hexpand(true);
    let open = gtk::Button::with_label(tr("In Standard-App öffnen", "Open in default app"));
    open.set_sensitive(false);
    result_actions.append(&files);
    result_actions.append(&open);
    let copy = gtk::Button::with_label(tr(
        "Vollständiges Markdown kopieren",
        "Copy complete Markdown",
    ));
    copy.set_tooltip_text(Some(tr(
        "Kopiert die gesamte ausgewählte Markdown-Datei in die Zwischenablage.",
        "Copies the entire selected Markdown file to the clipboard.",
    )));
    copy.set_sensitive(false);
    result_actions.append(&copy);
    let compare = gtk::Button::with_label(tr("Quellvergleich…", "Compare source…"));
    compare.set_tooltip_text(Some(tr(
        "Öffnet die ausgewählte Markdown-Ausgabe neben ihrer Quelle.",
        "Opens the selected Markdown output beside its source.",
    )));
    compare.set_sensitive(false);
    result_actions.append(&compare);
    outer.append(&result_actions);
    Results {
        tabs: result_tabs,
        preview,
        diagnostics,
        details,
        files,
        open,
        copy,
        compare,
    }
}

pub(super) fn connect(state: &Shared, view: &View) {
    {
        let state = state.clone();
        let view = view.clone();
        view.copy
            .clone()
            .connect_clicked(move |_| clipboard_ui::copy_markdown(&state, &view));
    }

    {
        let state = state.clone();
        let view = view.clone();
        view.compare.clone().connect_clicked(move |_| {
            if state.borrow().is_busy() {
                view.rejection.set_text(tr(
                    "Bitte den laufenden Auftrag beenden, bevor ein weiterer Vergleich geöffnet wird.",
                    "Finish the active job before opening another comparison.",
                ));
                return;
            }
            let selected = selected_file(&state, &view).filter(|file| file.preview);
            if let Some(file) = selected {
                comparison::open(&view.window, file, &state);
            }
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        view.files.clone().connect_selected_notify(move |_| {
            state.borrow_mut().generation += 1;
            let selected = selected_file(&state, &view);
            let previewable = selected.as_ref().is_some_and(|file| file.preview);
            view.open.set_sensitive(selected.is_some());
            view.copy.set_sensitive(previewable);
            view.compare.set_sensitive(previewable);
            view.preview.buffer().set_text("");
            if let Some(file) = selected {
                if file.preview {
                    load_preview(&state, &view, file);
                } else {
                    view.preview.buffer().set_text(tr(
                        "Asset ausgewählt. Öffnen erfolgt nur auf eigenen Klick in der Standard-App.",
                        "Asset selected. It opens in the default app only when you click Open.",
                    ));
                }
            }
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        view.open.clone().connect_clicked(move |_| {
            if let Some(file) = selected_file(&state, &view) {
                open_output(&state, &view, file);
            }
        });
    }
}

fn selected_file(state: &Shared, view: &View) -> Option<OutputFile> {
    state
        .borrow()
        .files
        .get(view.files.selected() as usize)
        .cloned()
}

fn load_preview(state: &Shared, view: &View, file: OutputFile) {
    let generation = state.borrow().generation;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let text = read_output::text(&file, 2_097_152);
        let _ = tx.send(text);
    });
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(Duration::from_millis(30), move || {
        if state.borrow().generation != generation {
            return glib::ControlFlow::Break;
        }
        match rx.try_recv() {
            Ok(text) => {
                view.preview.buffer().set_text(&text.unwrap_or_else(|e| e));
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}

pub(super) fn show_files(state: &Shared, view: &View, value: &Value) {
    let mut files = model::outputs(value);
    if let Some(source) = &state.borrow().clipboard_source {
        for file in &mut files {
            file.source_origin = model::SourceOrigin::Clipboard;
            file.bound_input = Some(source.binding.clone());
        }
    }
    state.borrow_mut().files = files.clone();
    view.files.set_sensitive(false);
    view.files.set_model(Some(&gtk::StringList::new(&[tr(
        "Noch kein Ergebnis",
        "No result yet",
    )])));
    view.files.set_sensitive(!files.is_empty());
    let labels = gtk::StringList::new(&[]);
    if files.is_empty() {
        labels.append(tr("Noch kein Ergebnis", "No result yet"));
    }
    for (index, file) in files.iter().enumerate() {
        labels.append(&format!("{} · {}", index + 1, file.label));
    }
    view.files.set_model(Some(&labels));
    if !files.is_empty() {
        view.files.set_selected(0);
    }
}

pub(super) fn render_response(view: &View, value: &Value) {
    view.diagnostics.buffer().set_text(&model::describe(value));
    view.details
        .buffer()
        .set_text(&serde_json::to_string_pretty(value).unwrap_or_default());
}

fn open_output(state: &Shared, view: &View, file: OutputFile) {
    let generation = state.borrow().generation;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = read_output::read(
            &file,
            1024 * 1024 * 1024,
            false,
            &std::sync::atomic::AtomicBool::new(false),
        );
        let _ = tx.send((file, result));
    });
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(Duration::from_millis(30), move || {
        if state.borrow().generation != generation || state.borrow().closing {
            return glib::ControlFlow::Break;
        }
        match rx.try_recv() {
            Ok((file, result)) => {
                let result = result.and_then(|snapshot| read_output::revalidate(&snapshot));
                match result {
                    Ok(()) => {
                        let uri = gio::File::for_path(file.path).uri();
                        if let Err(e) = gio::AppInfo::launch_default_for_uri(
                            &uri,
                            None::<&gio::AppLaunchContext>,
                        ) {
                            view.status.set_text(&e.to_string());
                        }
                    }
                    Err(e) => view.rejection.set_text(&e),
                }
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}
