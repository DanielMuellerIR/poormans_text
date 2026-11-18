use super::*;
use crate::{label, scroll};
use pmt_bridge::JobHandle;
use serde_json::json;
use std::{cell::RefCell, collections::HashMap, rc::Rc};

#[derive(Clone, Copy, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
enum ItemStatus {
    Success,
    ReviewRequired,
    Failed,
    Cancelled,
}

impl ItemStatus {
    fn title(self) -> &'static str {
        match self {
            Self::Success => tr("Exportiert", "Exported"),
            Self::ReviewRequired => tr("Prüfung erforderlich", "Review required"),
            Self::Failed => tr("Fehlgeschlagen", "Failed"),
            Self::Cancelled => tr("Abgebrochen", "Cancelled"),
        }
    }
}

#[derive(Deserialize)]
struct Item {
    source: PathBuf,
    output: Option<PathBuf>,
    status: ItemStatus,
    diagnostic: Option<String>,
}

#[derive(Default)]
struct State {
    sources: Vec<PathBuf>,
    mask: Option<(Mask, PathBuf)>,
    destination: Option<PathBuf>,
    items: HashMap<PathBuf, Item>,
    active: Option<JobHandle>,
    cancelling: bool,
    closing: bool,
}

struct Batch {
    window: glib::WeakRef<gtk::Window>,
    bridge: Bridge,
    state: RefCell<State>,
    choose: gtk::Button,
    add: gtk::Button,
    mask: gtk::Label,
    list: gtk::Box,
    destination: gtk::Label,
    folder: gtk::Button,
    beside: gtk::Button,
    status: gtk::Label,
    progress: gtk::ProgressBar,
    cancel: gtk::Button,
    run: gtk::Button,
}

pub(super) fn open(
    parent: &gtk::Window,
    bridge: &Bridge,
    paths: Vec<PathBuf>,
    mask: Option<(Mask, PathBuf)>,
) {
    let window = window(
        parent,
        tr("Belegmaske anwenden", "Apply receipt mask"),
        760,
        590,
    );
    let outer = padded(12, 18);
    section(&outer, tr("Extraktionsmaske", "Extraction mask"));
    let choose = gtk::Button::with_label(tr("Maske wählen…", "Choose mask…"));
    choose.set_tooltip_text(Some(tr(
        "Wählt die gespeicherte JSON-Maske für alle PDFs in der Liste.",
        "Selects the saved JSON mask for all PDFs in the list.",
    )));
    let mask_label = single_line("");
    let mask_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    mask_row.append(&choose);
    mask_row.append(&mask_label);
    outer.append(&mask_row);

    let sources = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    section(&sources, tr("Belege", "Receipts"));
    let add = gtk::Button::with_label(tr("PDFs hinzufügen…", "Add PDFs…"));
    add.set_tooltip_text(Some(tr(
        "Fügt PDF-Belege hinzu, auf die dieselbe Maske angewendet wird.",
        "Adds PDF receipts that will use the same mask.",
    )));
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    sources.append(&spacer);
    sources.append(&add);
    outer.append(&sources);
    let list = padded(8, 10);
    let listing = scroll(&list, 180);
    listing.set_has_frame(true);
    listing.set_hscrollbar_policy(gtk::PolicyType::Never);
    outer.append(&listing);

    section(&outer, tr("JSON-Ziel", "JSON destination"));
    let folder = gtk::Button::with_label(tr("Ordner wählen…", "Choose folder…"));
    folder.set_tooltip_text(Some(tr(
        "Speichert alle JSON-Dateien in einem gemeinsamen Ordner.",
        "Saves all JSON files in one shared folder.",
    )));
    let beside = gtk::Button::with_label(tr("Neben PDFs speichern", "Save beside PDFs"));
    beside.set_tooltip_text(Some(tr(
        "Speichert jede JSON-Datei im Ordner des zugehörigen PDFs.",
        "Saves each JSON file in the folder containing its PDF.",
    )));
    buttons(&outer, &[&folder, &beside]);
    let destination = single_line("");
    outer.append(&destination);

    let status = label("");
    status.set_selectable(true);
    status.set_visible(false);
    status.connect_label_notify(|label| label.set_visible(!label.label().is_empty()));
    outer.append(&status);
    let progress = gtk::ProgressBar::new();
    progress.set_visible(false);
    outer.append(&progress);
    let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
    cancel.set_tooltip_text(Some(tr(
        "Stoppt die Stapelverarbeitung. Bereits fertig gespeicherte Ergebnisse bleiben erhalten.",
        "Stops the batch. Results already saved are kept.",
    )));
    let run = gtk::Button::with_label(tr("Maske anwenden", "Apply mask"));
    run.set_tooltip_text(Some(tr(
        "Wendet die Maske an und schreibt je Beleg eine JSON-Datei. Vorhandene Dateien werden geschützt.",
        "Applies the mask and writes one JSON file per receipt. Existing files are protected.",
    )));
    run.add_css_class("suggested-action");
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    actions.set_halign(gtk::Align::End);
    actions.append(&cancel);
    actions.append(&run);
    outer.append(&actions);
    window.set_child(Some(&outer));

    let batch = Rc::new(Batch {
        window: window.downgrade(),
        bridge: bridge.clone(),
        state: RefCell::new(State {
            mask,
            ..State::default()
        }),
        choose,
        add,
        mask: mask_label,
        list,
        destination,
        folder,
        beside,
        status,
        progress,
        cancel,
        run,
    });
    batch.connect(&window, &listing);
    batch.add_paths(Ok(paths));
    batch.refresh();
    window.present();
}

impl Batch {
    fn connect(self: &Rc<Self>, window: &gtk::Window, listing: &gtk::ScrolledWindow) {
        clicked(&self.add, self, |batch| {
            let Some(window) = batch.window.upgrade() else {
                return;
            };
            let weak = Rc::downgrade(batch);
            choose_pdfs(&window, move |result| {
                if let Some(batch) = weak.upgrade() {
                    batch.add_paths(result);
                }
            });
        });
        let weak = Rc::downgrade(self);
        file_drop(listing, move |paths| {
            weak.upgrade().is_some_and(|batch| batch.add_paths(paths))
        });
        clicked(&self.choose, self, |batch| {
            let Some(window) = batch.window.upgrade() else {
                return;
            };
            let weak = Rc::downgrade(batch);
            choose_file(
                &window,
                tr("Extraktionsmaske wählen", "Choose extraction mask"),
                FileMode::Open,
                move |result| {
                    if let Some(batch) = weak.upgrade() {
                        match result {
                            Ok(path) => batch.load_mask(path),
                            Err(error) => batch.status.set_text(&error),
                        }
                    }
                },
            );
        });
        clicked(&self.folder, self, |batch| {
            let Some(window) = batch.window.upgrade() else {
                return;
            };
            let weak = Rc::downgrade(batch);
            choose_file(
                &window,
                tr("JSON-Zielordner wählen", "Choose JSON destination folder"),
                FileMode::Folder,
                move |result| {
                    let Some(batch) = weak.upgrade() else {
                        return;
                    };
                    match result.and_then(|path| {
                        path_text(&path)?;
                        Ok(path)
                    }) {
                        Ok(path) => batch.change_destination(Some(path)),
                        Err(error) => batch.status.set_text(&error),
                    }
                },
            );
        });
        clicked(&self.beside, self, |batch| batch.change_destination(None));
        clicked(&self.cancel, self, |batch| batch.cancel());
        clicked(&self.run, self, |batch| batch.run());
        let batch = self.clone();
        window.connect_close_request(move |_| {
            batch.state.borrow_mut().closing = true;
            if batch.state.borrow().active.is_some() {
                batch.cancel();
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
    }

    fn editable(&self) -> bool {
        let state = self.state.borrow();
        !state.closing && state.active.is_none()
    }

    fn add_paths(self: &Rc<Self>, paths: Result<Vec<PathBuf>, String>) -> bool {
        if !self.editable() {
            return false;
        }
        let added = paths.and_then(|paths| pdf_paths(&self.state.borrow().sources, paths));
        match added {
            Ok(added) => {
                if !added.is_empty() {
                    self.state.borrow_mut().sources.extend(added);
                    self.reset();
                }
                true
            }
            Err(error) => {
                self.status.set_text(&error);
                false
            }
        }
    }

    fn change_destination(self: &Rc<Self>, path: Option<PathBuf>) {
        if self.editable() {
            self.state.borrow_mut().destination = path;
            self.reset();
        }
    }

    fn reset(self: &Rc<Self>) {
        self.state.borrow_mut().items.clear();
        self.progress.set_visible(false);
        self.status.set_text("");
        self.refresh();
    }

    fn load_mask(self: &Rc<Self>, path: PathBuf) {
        if !self.editable() {
            return;
        }
        let job = path_text(&path).and_then(|path| {
            request_job(&self.bridge, &json!({"action": "loadMask", "path": path}))
        });
        let job = match job {
            Ok(job) => job,
            Err(error) => {
                self.status.set_text(&error);
                return;
            }
        };
        self.status
            .set_text(tr("Maske wird geladen…", "Loading mask…"));
        self.start(job, move |batch, result| {
            if batch.state.borrow().cancelling {
                batch
                    .status
                    .set_text(tr("Laden abgebrochen.", "Loading cancelled."));
            } else {
                match response(result).and_then(|value| decode(&value, "mask")) {
                    Ok(mask) => {
                        batch.state.borrow_mut().mask = Some((mask, path));
                        batch.reset();
                    }
                    Err(error) => batch.status.set_text(&error),
                }
            }
        });
    }

    fn run(self: &Rc<Self>) {
        if !self.editable() {
            return;
        }
        let job = {
            let state = self.state.borrow();
            let Some((mask, _)) = &state.mask else {
                return;
            };
            if state.sources.is_empty() {
                return;
            }
            batch_job(
                &self.bridge,
                mask,
                &state.sources,
                state.destination.as_deref(),
            )
        };
        let job = match job {
            Ok(job) => job,
            Err(error) => {
                self.status.set_text(&error);
                return;
            }
        };
        self.state.borrow_mut().items.clear();
        self.progress.set_fraction(0.0);
        self.progress.set_visible(true);
        self.status
            .set_text(tr("Stapel wird verarbeitet…", "Processing receipts…"));
        self.start(job, |batch, result| batch.show_results(result));
    }

    fn start(
        self: &Rc<Self>,
        job: Job,
        complete: impl FnOnce(&Rc<Batch>, Result<Value, BridgeError>) + 'static,
    ) {
        self.state.borrow_mut().active = Some(job.handle.clone());
        self.refresh();
        let weak = Rc::downgrade(self);
        let progress = Rc::downgrade(self);
        watch(
            job,
            move |text| {
                let Some(batch) = progress.upgrade() else {
                    return;
                };
                if batch.state.borrow().cancelling || !batch.progress.is_visible() {
                    return;
                }
                if let Some((done, total)) = progress_fraction(&text) {
                    batch.progress.set_fraction(done as f64 / total as f64);
                    batch.status.set_text(&format!(
                        "{done}/{total} {}",
                        tr("verarbeitet", "processed")
                    ));
                }
            },
            move |result| {
                let Some(batch) = weak.upgrade() else {
                    return;
                };
                batch.state.borrow_mut().active.take();
                if batch.state.borrow().closing {
                    if let Some(window) = batch.window.upgrade() {
                        window.close();
                    }
                    return;
                }
                complete(&batch, result);
                batch.state.borrow_mut().cancelling = false;
                batch.refresh();
            },
        );
    }

    fn cancel(&self) {
        let mut state = self.state.borrow_mut();
        if let Some(job) = &state.active {
            job.cancel();
            state.cancelling = true;
        }
        drop(state);
        self.cancel.set_sensitive(false);
        self.status
            .set_text(tr("Abbruch angefordert.", "Cancellation requested."));
    }

    fn show_results(&self, result: Result<Value, BridgeError>) {
        let mut cancelled = self.state.borrow().cancelling;
        let mut failure = None;
        let response = match result {
            Ok(value) => Some(value),
            Err(error) => {
                cancelled |= error.kind == ErrorKind::Cancelled || error.exit_code == Some(130);
                if !cancelled && (error.exit_code != Some(1) || error.response.is_none()) {
                    failure = Some(error.to_string());
                }
                error.response
            }
        };
        let mut state = self.state.borrow_mut();
        if let Some(response) = response {
            cancelled |= response.get("cancelled").and_then(Value::as_bool) == Some(true);
            match decode::<Vec<Item>>(&response, "items") {
                Ok(items) => {
                    state.items = items
                        .into_iter()
                        .map(|item| (item.source.clone(), item))
                        .collect();
                }
                Err(error) if !cancelled => {
                    failure.get_or_insert(error);
                }
                Err(_) => {}
            }
        }
        if cancelled {
            for source in state.sources.clone() {
                state.items.entry(source.clone()).or_insert(Item {
                    source,
                    output: None,
                    status: ItemStatus::Cancelled,
                    diagnostic: None,
                });
            }
        }
        let count = state
            .items
            .values()
            .filter(|item| item.status != ItemStatus::Cancelled)
            .count();
        let total = state.sources.len();
        self.progress
            .set_fraction(count as f64 / total.max(1) as f64);
        self.status.set_text(&if let Some(error) = failure {
            error
        } else if cancelled {
            format!(
                "{count}/{total} · {}",
                tr("Stapel abgebrochen", "Batch cancelled")
            )
        } else {
            format!("{count}/{total} {}", tr("verarbeitet", "processed"))
        });
    }

    fn refresh(self: &Rc<Self>) {
        let state = self.state.borrow();
        let idle = !state.closing && state.active.is_none();
        self.choose.set_sensitive(idle);
        self.add.set_sensitive(idle);
        self.folder.set_sensitive(idle);
        self.beside
            .set_sensitive(idle && state.destination.is_some());
        self.cancel
            .set_sensitive(state.active.is_some() && !state.cancelling);
        self.run
            .set_sensitive(idle && state.mask.is_some() && !state.sources.is_empty());
        self.mask.set_text(&state.mask.as_ref().map_or_else(
            || tr("Keine Maske gewählt", "No mask selected").into(),
            |(_, path)| file_name(path),
        ));
        self.mask
            .set_tooltip_text(state.mask.as_ref().and_then(|(_, path)| path.to_str()));
        self.destination
            .set_text(&state.destination.as_ref().map_or_else(
                || tr("Neben jeder PDF-Datei", "Beside each PDF").into(),
                |path| path.display().to_string(),
            ));
        self.destination
            .set_tooltip_text(state.destination.as_ref().and_then(|path| path.to_str()));
        clear(&self.list);
        if state.sources.is_empty() {
            let hint = label(tr(
                "PDF-Dateien hier ablegen oder hinzufügen.",
                "Drop or add PDF files.",
            ));
            hint.add_css_class("dim-label");
            self.list.append(&hint);
        }
        for (index, source) in state.sources.iter().enumerate() {
            if index > 0 {
                self.list
                    .append(&gtk::Separator::new(gtk::Orientation::Horizontal));
            }
            let item = state.items.get(source);
            let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let title = single_line(&file_name(source));
            title.add_css_class("heading");
            title.set_tooltip_text(source.to_str());
            line.append(&title);
            let status = label(item.map_or_else(
                || {
                    if state.active.is_some() {
                        tr("Wartet", "Waiting")
                    } else {
                        tr("Bereit", "Ready")
                    }
                },
                |item| item.status.title(),
            ));
            match item.map(|item| item.status) {
                Some(ItemStatus::ReviewRequired) => status.add_css_class("warning"),
                Some(ItemStatus::Failed) => status.add_css_class("error"),
                _ => status.add_css_class("dim-label"),
            }
            line.append(&status);
            if let Some(output) = item
                .and_then(|item| item.output.as_ref())
                .filter(|output| output.is_absolute())
            {
                let show = icon(
                    "folder-open-symbolic",
                    tr("JSON im Dateimanager zeigen", "Show JSON in file manager"),
                );
                let output = output.clone();
                clicked(&show, self, move |batch| {
                    let Some(window) = batch.window.upgrade() else {
                        return;
                    };
                    let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(&output)));
                    let weak = Rc::downgrade(batch);
                    launcher.open_containing_folder(
                        Some(&window),
                        None::<&gio::Cancellable>,
                        move |result| {
                            if let Err(error) = result
                                && let Some(batch) = weak.upgrade()
                            {
                                batch.status.set_text(&error.to_string());
                            }
                        },
                    );
                });
                line.append(&show);
            }
            if item.is_some_and(|item| item.status == ItemStatus::ReviewRequired) {
                let review = gtk::Button::with_label(tr("Prüfen…", "Review…"));
                review.set_tooltip_text(Some(tr(
                    "Öffnet den Beleg mit derselben Maske zur Prüfung und Korrektur.",
                    "Opens the receipt with the same mask for review and correction.",
                )));
                review.set_sensitive(idle);
                let source = source.clone();
                clicked(&review, self, move |batch| {
                    if let Some(window) = batch.window.upgrade() {
                        let mask = batch.state.borrow().mask.clone();
                        editor::open(&window, &batch.bridge, vec![source.clone()], mask);
                    }
                });
                line.append(&review);
            }
            let remove = icon("list-remove-symbolic", tr("PDF entfernen", "Remove PDF"));
            remove.set_sensitive(idle);
            let remove_source = source.clone();
            clicked(&remove, self, move |batch| {
                batch
                    .state
                    .borrow_mut()
                    .sources
                    .retain(|path| *path != remove_source);
                batch.reset();
            });
            line.append(&remove);
            self.list.append(&line);
            if let Some(parent) = source.parent().and_then(Path::to_str) {
                let directory = single_line(parent);
                directory.add_css_class("dim-label");
                directory.set_tooltip_text(Some(parent));
                self.list.append(&directory);
            }
            if let Some(diagnostic) = item.and_then(|item| item.diagnostic.as_deref()) {
                let diagnostic = label(diagnostic);
                diagnostic.set_selectable(true);
                self.list.append(&diagnostic);
            }
        }
    }
}

fn clicked(button: &gtk::Button, batch: &Rc<Batch>, action: impl Fn(&Rc<Batch>) + 'static) {
    let weak = Rc::downgrade(batch);
    button.connect_clicked(move |_| {
        if let Some(batch) = weak.upgrade() {
            action(&batch);
        }
    });
}

fn progress_fraction(line: &str) -> Option<(usize, usize)> {
    let (done, total) = line.strip_prefix('[')?.split_once(']')?.0.split_once('/')?;
    let (done, total) = (done.parse().ok()?, total.parse().ok()?);
    (total > 0 && done <= total).then_some((done, total))
}
