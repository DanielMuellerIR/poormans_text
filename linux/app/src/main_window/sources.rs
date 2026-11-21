use super::{
    dialogs::{dialog_error, reject_remote, ticket_current},
    widgets::{scroll, text_view},
};
use crate::{Shared, View, model::tr, receipt};
use gtk::{gio, prelude::*};
use pmt_bridge::Bridge;
use std::{path::PathBuf, rc::Rc};

pub(super) struct Sources {
    pub list: gtk::TextView,
    pub controls: gtk::FlowBox,
    pub choose: gtk::Button,
    pub catalog: gtk::Button,
    folder: gtk::Button,
    clear: gtk::Button,
    receipt_editor: gtk::Button,
    receipt_batch: gtk::Button,
}

pub(super) fn build(outer: &gtk::Box) -> Sources {
    let source_controls = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(6)
        .column_spacing(8)
        .row_spacing(8)
        .build();
    let choose = gtk::Button::with_label(tr("Dateien wählen…", "Choose files…"));
    choose.set_tooltip_text(Some(tr(
        "Fügt eine oder mehrere Dateien zur Konvertierungsliste hinzu.",
        "Adds one or more files to the conversion list.",
    )));
    let folder = gtk::Button::with_label(tr("Ordner wählen…", "Choose folder…"));
    folder.set_tooltip_text(Some(tr(
        "Sucht in einem Ordner und seinen Unterordnern nach Dokumenten für die Konvertierung.",
        "Looks for documents to convert in a folder and its subfolders.",
    )));
    let clear = gtk::Button::with_label(tr("Leeren", "Clear"));
    clear.set_tooltip_text(Some(tr(
        "Leert die aktuelle Quellliste.",
        "Clears the current source list.",
    )));
    let catalog = gtk::Button::with_label(tr("Formate und Werkzeuge", "Formats and tools"));
    catalog.set_tooltip_text(Some(tr(
        "Zeigt unterstützte Formate und die dafür verfügbaren Werkzeuge.",
        "Shows supported formats and the tools available for them.",
    )));
    let receipt_editor =
        gtk::Button::with_label(tr("Belegmaske bearbeiten…", "Edit receipt mask…"));
    receipt_editor.set_tooltip_text(Some(tr(
        "Erstellt oder testet Regeln, die Werte wie Rechnungsnummern aus PDF-Belegen lesen.",
        "Creates or tests rules that read values such as invoice numbers from PDF receipts.",
    )));
    let receipt_batch = gtk::Button::with_label(tr("Belegmaske anwenden…", "Apply receipt mask…"));
    receipt_batch.set_tooltip_text(Some(tr(
        "Wendet dieselbe gespeicherte Maske auf mehrere PDF-Belege an und schreibt je Beleg eine JSON-Datei.",
        "Applies one saved mask to multiple PDF receipts and writes one JSON file per receipt.",
    )));
    for b in [
        &choose,
        &folder,
        &clear,
        &catalog,
        &receipt_editor,
        &receipt_batch,
    ] {
        source_controls.append(b);
    }
    outer.append(&source_controls);
    let sources = text_view();
    sources.buffer().set_text(tr(
        "Dateien oder Ordner hier ablegen…",
        "Drop files or folders here…",
    ));
    sources.set_tooltip_text(Some(tr(
        "Dateien oder Ordner hier ablegen. Quellen bleiben unverändert.",
        "Drop files or folders here. Source documents remain unchanged.",
    )));
    outer.append(&scroll(&sources, 75));
    Sources {
        list: sources,
        controls: source_controls,
        choose,
        catalog,
        folder,
        clear,
        receipt_editor,
        receipt_batch,
    }
}

impl Sources {
    pub(super) fn connect(&self, state: &Shared, view: &View, bridge: &Rc<Bridge>) {
        for (button, open) in [
            (
                &self.receipt_editor,
                receipt::open_editor as fn(&gtk::ApplicationWindow, &Bridge, &[PathBuf]),
            ),
            (&self.receipt_batch, receipt::open_batch),
        ] {
            let window = view.window.downgrade();
            let state = state.clone();
            let bridge = bridge.clone();
            button.connect_clicked(move |_| {
                if let Some(window) = window.upgrade() {
                    open(&window, &bridge, &state.borrow().sources);
                }
            });
        }
        for (button, is_folder) in [(&self.choose, false), (&self.folder, true)] {
            let state = state.clone();
            let view = view.clone();
            button.connect_clicked(move |_| choose_sources(&state, &view, is_folder));
        }
        {
            let state = state.clone();
            let view = view.clone();
            self.clear
                .connect_clicked(move |_| set_sources(&state, &view, vec![]));
        }
        let drop = gtk::DropTarget::new(
            gtk::gdk::FileList::static_type(),
            gtk::gdk::DragAction::COPY,
        );
        {
            let state = state.clone();
            let view = view.clone();
            drop.connect_drop(move |_, value, _, _| {
                if state.borrow().is_busy() {
                    return false;
                }
                if let Ok(files) = value.get::<gtk::gdk::FileList>() {
                    let offered = files.files();
                    let paths: Vec<PathBuf> =
                        offered.iter().filter_map(|file| file.path()).collect();
                    if paths.is_empty() || paths.len() != offered.len() {
                        reject_remote(&view);
                        return false;
                    }
                    set_sources(&state, &view, paths);
                    true
                } else {
                    false
                }
            });
        }
        view.sources.add_controller(drop);
    }
}

pub(crate) fn set_sources(state: &Shared, view: &View, paths: Vec<PathBuf>) {
    if state.borrow().is_busy() {
        #[cfg(feature = "ui-self-test")]
        crate::self_test::source_rejected();
        view.rejection.set_text(tr(
            "Lauf aktiv: neue Quellen wurden nicht angenommen. Bitte nach Abschluss erneut öffnen.",
            "A job is active: new sources were not accepted. Open them again when it finishes.",
        ));
        return;
    }
    view.rejection.set_text("");
    let mut s = state.borrow_mut();
    s.generation += 1;
    s.sources = paths;
    s.clipboard_source = None;
    #[cfg(feature = "ui-self-test")]
    crate::self_test::sources_changed(&s.sources);
    s.files.clear();
    let displayed = s
        .sources
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("\n");
    drop(s);
    view.sources.buffer().set_text(if displayed.is_empty() {
        tr(
            "Dateien oder Ordner hier ablegen…",
            "Drop files or folders here…",
        )
    } else {
        &displayed
    });
    view.files.set_sensitive(false);
    view.files.set_model(Some(&gtk::StringList::new(&[tr(
        "Noch kein Ergebnis",
        "No result yet",
    )])));
    view.open.set_sensitive(false);
    view.copy.set_sensitive(false);
    view.compare.set_sensitive(false);
    view.preview.buffer().set_text("");
    view.diagnostics.buffer().set_text("");
    view.details.buffer().set_text("");
    view.status.set_text(tr(
        "Bereit · neue Quellen gewählt",
        "Ready · new sources selected",
    ));
}
fn choose_sources(state: &Shared, view: &View, folder: bool) {
    let generation = state.borrow().generation;
    let dialog = gtk::FileDialog::builder()
        .title(if folder {
            tr("Quellordner wählen", "Choose source folder")
        } else {
            tr("Quelldokumente wählen", "Choose source documents")
        })
        .build();
    let state = state.clone();
    let view = view.clone();
    if folder {
        dialog.select_folder(
            Some(&view.window.clone()),
            None::<&gio::Cancellable>,
            move |result| {
                if let Err(ref error) = result {
                    dialog_error(&view, error);
                    return;
                }
                if !ticket_current(&state, &view, generation) {
                    return;
                }
                if let Ok(file) = result {
                    if let Some(path) = file.path() {
                        set_sources(&state, &view, vec![path]);
                    } else {
                        reject_remote(&view);
                    }
                }
            },
        );
    } else {
        dialog.open_multiple(
            Some(&view.window.clone()),
            None::<&gio::Cancellable>,
            move |result| {
                if let Err(ref error) = result {
                    dialog_error(&view, error);
                    return;
                }
                if !ticket_current(&state, &view, generation) {
                    return;
                }
                if let Ok(files) = result {
                    let paths: Vec<PathBuf> = (0..files.n_items())
                        .filter_map(|i| files.item(i).and_downcast::<gio::File>())
                        .filter_map(|f| f.path())
                        .collect();
                    if paths.len() != files.n_items() as usize {
                        reject_remote(&view);
                        return;
                    }
                    set_sources(&state, &view, paths);
                }
            },
        );
    }
}
