use super::*;
use crate::{
    bounded_dropdown, label, scroll,
    source_canvas::{SourceCanvas, Zoom},
    source_raster::receipt_texture,
    text_view,
};
use geometry::Page;
use pmt_bridge::JobHandle;
use serde_json::json;
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
};

type Corrections = HashMap<String, String>;

#[derive(Clone)]
struct Selection {
    page: usize,
    rectangle: Rect,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Location {
    source: PathBuf,
    page: usize,
}

struct Document {
    pages: Vec<Page>,
    words: Vec<Rect>,
    suggestions: Vec<Field>,
    suggested_values: Vec<FieldValue>,
}

struct CurrentResult {
    fields: Vec<FieldValue>,
    json: Option<Value>,
}

enum Request {
    Inspect(Location),
    Evaluate(u64),
    LoadMask(PathBuf),
    SaveMask(PathBuf),
    Export(PathBuf),
}

impl Request {
    fn write_or_load(&self) -> bool {
        matches!(
            self,
            Self::LoadMask(_) | Self::SaveMask(_) | Self::Export(_)
        )
    }

    fn commits_output(&self) -> bool {
        matches!(self, Self::SaveMask(_) | Self::Export(_))
    }
}

struct Active {
    handle: JobHandle,
    request: Request,
    cancelled: bool,
}

#[derive(Default)]
struct State {
    pdfs: Vec<PathBuf>,
    index: usize,
    page: usize,
    location: Option<Location>,
    identities: HashMap<PathBuf, Identity>,
    document: Option<Document>,
    mask: Mask,
    saved_mask: Option<(Mask, PathBuf)>,
    result: Option<CurrentResult>,
    corrections: HashMap<PathBuf, Corrections>,
    rejected: Vec<Rule>,
    selection: Option<Selection>,
    marked: Vec<Selection>,
    active: Option<Active>,
    inspect_pending: bool,
    evaluate_pending: bool,
    revision: u64,
    closing: bool,
}

impl State {
    fn source(&self) -> Option<&PathBuf> {
        self.pdfs.get(self.index)
    }

    fn current_location(&self) -> Option<Location> {
        Some(Location {
            source: self.source()?.clone(),
            page: self.page,
        })
    }

    fn editable(&self) -> bool {
        !self.closing
            && !self
                .active
                .as_ref()
                .is_some_and(|active| active.request.write_or_load())
    }
}

struct FieldRow {
    id: String,
    value: gtk::Label,
    details: gtk::Label,
    evidence: gtk::MenuButton,
    correct: gtk::Button,
}

struct Editor {
    window: glib::WeakRef<gtk::Window>,
    bridge: Bridge,
    state: RefCell<State>,
    syncing_entries: Cell<bool>,
    debounce: RefCell<Option<glib::SourceId>>,
    drag_start: Cell<Option<(f64, f64)>>,
    field_rows: RefCell<Vec<FieldRow>>,
    picture: SourceCanvas,
    viewport: gtk::ScrolledWindow,
    filename: gtk::Label,
    doc_count: gtk::Label,
    page_count: gtk::Label,
    source_status: gtk::Label,
    retry: gtk::Button,
    partner: gtk::Entry,
    document_type: gtk::Entry,
    mask_file: gtk::Label,
    selected: gtk::Box,
    selected_region: gtk::Label,
    replace: gtk::DropDown,
    suggestions: gtk::Box,
    fields: gtk::Box,
    status: gtk::Label,
    add: gtk::Button,
    previous_pdf: gtk::Button,
    next_pdf: gtk::Button,
    previous_page: gtk::Button,
    next_page: gtk::Button,
    zoom_out: gtk::Button,
    fit: gtk::Button,
    zoom_in: gtk::Button,
    load: gtk::Button,
    reload: gtk::Button,
    save: gtk::Button,
    add_region: gtk::Button,
    replace_region: gtk::Button,
    preview_json: gtk::Button,
    export: gtk::Button,
    cancel: gtk::Button,
    batch: gtk::Button,
}

pub(in crate::receipt) fn open(
    parent: &gtk::Window,
    bridge: &Bridge,
    paths: Vec<PathBuf>,
    loaded_mask: Option<(Mask, PathBuf)>,
) {
    let window = window(
        parent,
        tr("Belegmaske bearbeiten", "Edit receipt mask"),
        1120,
        790,
    );
    let outer = padded(12, 18);
    let split = gtk::Paned::new(gtk::Orientation::Horizontal);
    split.set_vexpand(true);
    split.set_wide_handle(true);
    split.set_position(560);
    split.set_shrink_start_child(false);
    split.set_shrink_end_child(false);
    split.set_resize_start_child(true);
    outer.append(&split);

    let source = padded(8, 0);
    source.set_size_request(320, -1);
    let add = gtk::Button::with_label(tr("PDFs hinzufügen…", "Add PDFs…"));
    let previous_pdf = icon("go-previous-symbolic", tr("Vorheriges PDF", "Previous PDF"));
    let next_pdf = icon("go-next-symbolic", tr("Nächstes PDF", "Next PDF"));
    let doc_count = gtk::Label::new(None);
    let docs = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    docs.append(&add);
    let doc_nav = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    doc_nav.set_hexpand(true);
    doc_nav.set_halign(gtk::Align::End);
    doc_nav.append(&previous_pdf);
    doc_nav.append(&doc_count);
    doc_nav.append(&next_pdf);
    docs.append(&doc_nav);
    source.append(&docs);
    let filename = single_line("");
    filename.add_css_class("heading");
    source.append(&filename);

    let previous_page = icon(
        "go-previous-symbolic",
        tr("Vorherige Seite", "Previous page"),
    );
    let next_page = icon("go-next-symbolic", tr("Nächste Seite", "Next page"));
    let page_count = gtk::Label::new(None);
    let zoom_out = icon("zoom-out-symbolic", tr("Verkleinern", "Zoom out"));
    let fit = gtk::Button::with_label(tr("Einpassen", "Fit"));
    let zoom_in = icon("zoom-in-symbolic", tr("Vergrößern", "Zoom in"));
    let page_nav = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    page_nav.append(&previous_page);
    page_nav.append(&page_count);
    page_nav.append(&next_page);
    let zoom = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    zoom.set_hexpand(true);
    zoom.set_halign(gtk::Align::End);
    zoom.append(&zoom_out);
    zoom.append(&fit);
    zoom.append(&zoom_in);
    page_nav.append(&zoom);
    source.append(&page_nav);
    let picture = SourceCanvas::new();
    picture.update_property(&[gtk::accessible::Property::Label(tr(
        "PDF-Quelle",
        "Source PDF",
    ))]);
    let viewport = gtk::ScrolledWindow::builder()
        .child(&picture)
        .has_frame(true)
        .hexpand(true)
        .vexpand(true)
        .min_content_height(270)
        .build();
    source.append(&viewport);
    let source_status = label("");
    source_status.add_css_class("dim-label");
    source_status.set_selectable(true);
    source.append(&source_status);
    let retry = gtk::Button::with_label(tr("Erneut versuchen", "Retry"));
    retry.set_halign(gtk::Align::Start);
    source.append(&retry);
    split.set_start_child(Some(&source));

    let right = padded(10, 12);
    section(&right, tr("Extraktionsmaske", "Extraction mask"));
    let partner = gtk::Entry::new();
    let document_type = gtk::Entry::new();
    let metadata = gtk::Grid::builder()
        .row_spacing(8)
        .column_spacing(12)
        .build();
    for (index, (title, entry)) in [
        (tr("Partner", "Partner"), &partner),
        (tr("Dokumenttyp", "Document type"), &document_type),
    ]
    .into_iter()
    .enumerate()
    {
        let name = label(title);
        name.set_mnemonic_widget(Some(entry));
        entry.update_property(&[gtk::accessible::Property::Label(title)]);
        entry.set_hexpand(true);
        entry.set_width_chars(1);
        metadata.attach(&name, 0, index as i32, 1, 1);
        metadata.attach(entry, 1, index as i32, 1, 1);
    }
    right.append(&metadata);
    let load = gtk::Button::with_label(tr("Maske laden…", "Load mask…"));
    let reload = icon(
        "view-refresh-symbolic",
        tr("Maske neu laden", "Reload mask"),
    );
    let save = gtk::Button::with_label(tr("Maske speichern…", "Save mask…"));
    buttons(&right, &[&load, &reload, &save]);
    let mask_file = single_line("");
    mask_file.add_css_class("dim-label");
    right.append(&mask_file);

    let selected = padded(8, 0);
    section(&selected, tr("Ausgewählter Bereich", "Selected region"));
    let selected_region = label("");
    selected.append(&selected_region);
    let add_region = gtk::Button::with_label(tr("Neues Bereichsfeld", "New region field"));
    let clear_region = gtk::Button::with_label(tr("Aufheben", "Clear selection"));
    buttons(&selected, &[&add_region, &clear_region]);
    let replace_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let replace = gtk::DropDown::from_strings(&[]);
    replace.set_hexpand(true);
    replace.update_property(&[gtk::accessible::Property::Label(tr(
        "Feld, dessen Regel ersetzt wird",
        "Field whose rule will be replaced",
    ))]);
    bounded_dropdown(&replace);
    let replace_region = gtk::Button::with_label(tr("Regel ersetzen", "Replace rule"));
    replace_row.append(&replace);
    replace_row.append(&replace_region);
    selected.append(&replace_row);
    right.append(&selected);

    let suggestions = padded(8, 0);
    right.append(&suggestions);
    let fields = padded(10, 0);
    right.append(&fields);
    let right_scroll = gtk::ScrolledWindow::builder()
        .child(&right)
        .width_request(380)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .overlay_scrolling(false)
        .has_frame(true)
        .build();
    split.set_end_child(Some(&right_scroll));

    let status = label("");
    status.set_selectable(true);
    status.set_visible(false);
    status.connect_label_notify(|label| label.set_visible(!label.label().is_empty()));
    outer.append(&status);
    let preview_json = gtk::Button::with_label(tr("JSON-Vorschau", "Preview JSON"));
    let export = gtk::Button::with_label(tr("JSON exportieren…", "Export JSON…"));
    export.add_css_class("suggested-action");
    let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
    let batch = gtk::Button::with_label(tr("Stapelverarbeitung…", "Batch extraction…"));
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    footer.append(&batch);
    footer.append(&cancel);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    footer.append(&spacer);
    footer.append(&preview_json);
    footer.append(&export);
    outer.append(&footer);
    window.set_child(Some(&outer));

    let editor = Rc::new(Editor {
        window: window.downgrade(),
        bridge: bridge.clone(),
        state: RefCell::new(State::default()),
        syncing_entries: Cell::new(false),
        debounce: RefCell::new(None),
        drag_start: Cell::new(None),
        field_rows: RefCell::new(vec![]),
        picture,
        viewport,
        filename,
        doc_count,
        page_count,
        source_status,
        retry,
        partner,
        document_type,
        mask_file,
        selected,
        selected_region,
        replace,
        suggestions,
        fields,
        status,
        add,
        previous_pdf,
        next_pdf,
        previous_page,
        next_page,
        zoom_out,
        fit,
        zoom_in,
        load,
        reload,
        save,
        add_region,
        replace_region,
        preview_json,
        export,
        cancel,
        batch,
    });
    editor.connect(&window, &source, &clear_region);
    if let Some((mask, path)) = loaded_mask {
        editor.install_mask(mask, path);
    } else {
        editor.rebuild_fields();
    }
    editor.update_controls();
    editor.add_pdfs(Ok(paths));
    window.present();
}

fn clicked(button: &gtk::Button, editor: &Rc<Editor>, action: impl Fn(&Rc<Editor>) + 'static) {
    let weak = Rc::downgrade(editor);
    button.connect_clicked(move |_| {
        if let Some(editor) = weak.upgrade() {
            action(&editor);
        }
    });
}

impl Editor {
    fn connect(
        self: &Rc<Self>,
        window: &gtk::Window,
        source: &gtk::Box,
        clear_region: &gtk::Button,
    ) {
        clicked(&self.add, self, |editor| {
            if let Some(window) = editor.window.upgrade() {
                let weak = Rc::downgrade(editor);
                choose_pdfs(&window, move |paths| {
                    if let Some(editor) = weak.upgrade() {
                        editor.add_pdfs(paths);
                    }
                });
            }
        });
        let weak = Rc::downgrade(self);
        file_drop(source, move |paths| {
            weak.upgrade().is_some_and(|editor| editor.add_pdfs(paths))
        });
        clicked(&self.previous_pdf, self, |editor| editor.move_document(-1));
        clicked(&self.next_pdf, self, |editor| editor.move_document(1));
        clicked(&self.previous_page, self, |editor| editor.move_page(-1));
        clicked(&self.next_page, self, |editor| editor.move_page(1));
        clicked(&self.retry, self, |editor| {
            let (page, loaded) = {
                let state = editor.state.borrow();
                (state.page, state.location.is_some())
            };
            if loaded {
                editor.changed(false);
            } else {
                editor.show_page(page);
            }
        });
        clicked(&self.zoom_out, self, |editor| editor.zoom(-1));
        clicked(&self.fit, self, |editor| editor.zoom(0));
        clicked(&self.zoom_in, self, |editor| editor.zoom(1));
        clicked(clear_region, self, |editor| editor.set_selection(None));
        clicked(&self.add_region, self, |editor| editor.apply_region(false));
        clicked(&self.replace_region, self, |editor| {
            editor.apply_region(true)
        });
        clicked(&self.load, self, |editor| editor.file_action("loadMask"));
        clicked(&self.reload, self, |editor| {
            let path = editor
                .state
                .borrow()
                .saved_mask
                .as_ref()
                .map(|(_, path)| path.clone());
            if let Some(path) = path {
                editor.start_file(Request::LoadMask(path));
            }
        });
        clicked(&self.save, self, |editor| editor.file_action("saveMask"));
        clicked(&self.export, self, |editor| editor.file_action("export"));
        clicked(&self.preview_json, self, |editor| editor.show_json());
        clicked(&self.cancel, self, |editor| editor.cancel());
        clicked(&self.batch, self, |editor| {
            if let Some(window) = editor.window.upgrade() {
                let state = editor.state.borrow();
                let mask = state.saved_mask.clone();
                batch::open(&window, &editor.bridge, state.pdfs.clone(), mask);
            }
        });
        for (entry, partner) in [(&self.partner, true), (&self.document_type, false)] {
            let weak = Rc::downgrade(self);
            entry.connect_changed(move |entry| {
                let Some(editor) = weak.upgrade() else {
                    return;
                };
                if editor.syncing_entries.get() {
                    return;
                }
                let mut state = editor.state.borrow_mut();
                if partner {
                    state.mask.partner = entry.text().into();
                } else {
                    state.mask.document_type = entry.text().into();
                }
                drop(state);
                editor.changed(true);
            });
        }
        let keys = gtk::EventControllerKey::new();
        let weak = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            if let Some(editor) = weak.upgrade()
                && modifiers == gdk::ModifierType::ALT_MASK
            {
                match key {
                    gdk::Key::Left => editor.move_document(-1),
                    gdk::Key::Right => editor.move_document(1),
                    _ => return glib::Propagation::Proceed,
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        window.add_controller(keys);

        let drag = gtk::GestureDrag::new();
        drag.set_button(1);
        let weak = Rc::downgrade(self);
        drag.connect_drag_begin(move |_, x, y| {
            if let Some(editor) = weak.upgrade() {
                let point = editor.canvas_point(x, y, false).map(|_| (x, y));
                editor.drag_start.set(point);
            }
        });
        let weak = Rc::downgrade(self);
        drag.connect_drag_update(move |_, dx, dy| {
            if let Some(editor) = weak.upgrade() {
                editor.drag_selection(dx, dy, false);
            }
        });
        let weak = Rc::downgrade(self);
        drag.connect_drag_end(move |_, dx, dy| {
            if let Some(editor) = weak.upgrade() {
                editor.drag_selection(dx, dy, true);
                editor.drag_start.set(None);
            }
        });
        self.picture.add_controller(drag);

        let editor = self.clone();
        window.connect_close_request(move |_| {
            editor.state.borrow_mut().closing = true;
            if editor.state.borrow().active.is_some() {
                editor.cancel();
                glib::Propagation::Stop
            } else {
                editor.stop_debounce();
                glib::Propagation::Proceed
            }
        });
    }

    fn add_pdfs(self: &Rc<Self>, paths: Result<Vec<PathBuf>, String>) -> bool {
        if !self.state.borrow().editable() {
            return false;
        }
        let added = paths.and_then(|paths| pdf_paths(&self.state.borrow().pdfs, paths));
        match added {
            Ok(added) => {
                if !added.is_empty() {
                    let mut state = self.state.borrow_mut();
                    let index = state.pdfs.len();
                    state.pdfs.extend(added);
                    drop(state);
                    self.show_document(index);
                }
                true
            }
            Err(error) => {
                self.status.set_text(&error);
                false
            }
        }
    }

    fn move_document(self: &Rc<Self>, offset: isize) {
        let index = self.state.borrow().index.checked_add_signed(offset);
        if let Some(index) = index {
            self.show_document(index);
        }
    }

    fn show_document(self: &Rc<Self>, index: usize) {
        {
            let mut state = self.state.borrow_mut();
            if !state.editable() || index >= state.pdfs.len() {
                return;
            }
            state.index = index;
            state.page = 0;
            state.document = None;
            state.result = None;
            state.marked.clear();
            state.evaluate_pending = true;
            state.revision += 1;
        }
        self.stop_debounce();
        self.render_results();
        self.render_suggestions();
        self.show_page(0);
    }

    fn move_page(self: &Rc<Self>, offset: isize) {
        let page = self.state.borrow().page.checked_add_signed(offset);
        if let Some(page) = page {
            self.show_page(page);
        }
    }

    fn show_page(self: &Rc<Self>, page: usize) {
        {
            let mut state = self.state.borrow_mut();
            if !state.editable()
                || state.source().is_none()
                || page >= state.document.as_ref().map_or(1, |doc| doc.pages.len())
            {
                return;
            }
            state.page = page;
            state.location = None;
            state.selection = None;
            state.inspect_pending = true;
            if state.result.is_none() {
                state.evaluate_pending = true;
            }
            if let Some(active) = &mut state.active {
                active.cancelled = true;
                active.handle.cancel();
            }
        }
        self.drag_start.set(None);
        self.picture.set_texture(None);
        self.source_status
            .set_text(tr("PDF wird gelesen…", "Reading PDF…"));
        self.status.set_text("");
        self.render_selection();
        self.update_controls();
        self.pump();
    }

    fn changed(self: &Rc<Self>, debounce: bool) {
        self.stop_debounce();
        let revision = {
            let mut state = self.state.borrow_mut();
            state.revision += 1;
            state.result = None;
            state.evaluate_pending = true;
            if let Some(active) = &mut state.active
                && matches!(active.request, Request::Evaluate(_))
            {
                active.cancelled = true;
                active.handle.cancel();
            }
            state.revision
        };
        self.render_results();
        self.update_controls();
        if debounce {
            let weak = Rc::downgrade(self);
            *self.debounce.borrow_mut() = Some(glib::timeout_add_local_once(
                Duration::from_millis(280),
                move || {
                    if let Some(editor) = weak.upgrade() {
                        editor.debounce.borrow_mut().take();
                        if editor.state.borrow().revision == revision {
                            editor.pump();
                        }
                    }
                },
            ));
        } else {
            self.pump();
        }
    }

    fn stop_debounce(&self) {
        if let Some(timeout) = self.debounce.borrow_mut().take() {
            timeout.remove();
        }
    }

    fn pump(self: &Rc<Self>) {
        let (request, payload) = {
            let mut state = self.state.borrow_mut();
            if state.active.is_some() || state.closing {
                return;
            }
            let Some(location) = state.current_location() else {
                return;
            };
            let source = location.source.to_str().expect("validated PDF path");
            let identity = state.identities.get(&location.source);
            if state.inspect_pending {
                let payload = json!({
                    "action": "inspect", "source": source, "page": location.page,
                    "sourceIdentity": identity,
                });
                state.inspect_pending = false;
                (Request::Inspect(location), payload)
            } else if state.evaluate_pending
                && state.location.is_some()
                && self.debounce.borrow().is_none()
            {
                let payload = json!({
                    "action": "evaluate", "source": source, "sourceIdentity": identity,
                    "mask": state.mask, "corrections": state.corrections.get(&location.source),
                });
                state.evaluate_pending = false;
                (Request::Evaluate(state.revision), payload)
            } else {
                return;
            }
        };
        self.start(request, payload);
    }

    fn start(self: &Rc<Self>, request: Request, payload: Value) {
        let job = match request_job(&self.bridge, &payload) {
            Ok(job) => job,
            Err(error) => {
                self.finished(request, Err(error));
                return;
            }
        };
        if matches!(request, Request::Evaluate(_)) {
            self.status
                .set_text(tr("Felder werden ausgewertet…", "Evaluating fields…"));
        }
        self.state.borrow_mut().active = Some(Active {
            handle: job.handle.clone(),
            request,
            cancelled: false,
        });
        self.update_controls();
        let weak = Rc::downgrade(self);
        watch(
            job,
            |_| {},
            move |result| {
                let Some(editor) = weak.upgrade() else {
                    return;
                };
                let active = editor
                    .state
                    .borrow_mut()
                    .active
                    .take()
                    .expect("receipt job");
                if editor.state.borrow().closing {
                    if let Some(window) = editor.window.upgrade() {
                        window.close();
                    }
                    return;
                }
                if !active.cancelled {
                    editor.finished(active.request, response(result));
                    return;
                }
                if active.request.commits_output() {
                    let committed = match result {
                        Ok(value) => Some(value),
                        Err(error) if error.kind == ErrorKind::Cancelled => error
                            .response
                            .filter(|value| value.get("ok").and_then(Value::as_bool) == Some(true)),
                        Err(_) => None,
                    };
                    if let Some(value) = committed {
                        editor.finished(active.request, response(Ok(value)));
                        return;
                    }
                }
                let pending = {
                    let state = editor.state.borrow();
                    state.inspect_pending || state.evaluate_pending
                };
                if !pending {
                    editor
                        .status
                        .set_text(tr("Vorgang abgebrochen.", "Operation cancelled."));
                }
                editor.update_controls();
                editor.pump();
            },
        );
    }

    fn finished(self: &Rc<Self>, request: Request, result: Result<Value, String>) {
        let outcome = match request {
            Request::Inspect(location) => result
                .and_then(|value| self.show_inspection(location, &value))
                .inspect_err(|error| self.source_status.set_text(error)),
            Request::Evaluate(revision) => result.and_then(|value| {
                let mut state = self.state.borrow_mut();
                if state.revision == revision {
                    let identity: Identity = decode(&value, "sourceIdentity")?;
                    if state
                        .source()
                        .and_then(|source| state.identities.get(source))
                        != Some(&identity)
                    {
                        return Err(tr("Das PDF hat sich geändert.", "The PDF changed.").into());
                    }
                    let json = value.get("result").filter(|v| v.is_object()).cloned();
                    self.status.set_text(if json.is_some() {
                        ""
                    } else {
                        tr(
                            "Feldnamen müssen für den JSON-Export eindeutig sein.",
                            "Field names must be unique before exporting JSON.",
                        )
                    });
                    state.result = Some(CurrentResult {
                        fields: decode(&value, "fields")?,
                        json,
                    });
                }
                drop(state);
                self.render_results();
                Ok(())
            }),
            Request::LoadMask(path) => result.and_then(|value| {
                self.install_mask(decode(&value, "mask")?, path);
                Ok(())
            }),
            Request::SaveMask(path) => result.map(|_| {
                let mut state = self.state.borrow_mut();
                state.saved_mask = Some((state.mask.clone(), path.clone()));
                self.status.set_text(&format!(
                    "{} {}",
                    tr("Maske gespeichert", "Mask saved"),
                    path.display()
                ));
            }),
            Request::Export(path) => result.map(|_| {
                self.status.set_text(&format!(
                    "{} {}",
                    tr("JSON exportiert", "JSON exported"),
                    path.display()
                ));
            }),
        };
        if let Err(error) = outcome {
            self.status.set_text(&error);
        }
        self.update_controls();
        self.pump();
    }

    fn show_inspection(
        self: &Rc<Self>,
        location: Location,
        response: &Value,
    ) -> Result<(), String> {
        let pages: Vec<Page> = decode(response, "pages")?;
        if pages.len() > 1000
            || !pages.iter().all(|page| page.valid())
            || location.page >= pages.len()
        {
            return Err("Invalid receipt page geometry".into());
        }
        let identity: Identity = decode(response, "sourceIdentity")?;
        let texture = receipt_texture(
            response.get("preview").ok_or("Missing receipt raster")?,
            (location.page + 1) as u32,
            pages.len(),
            &identity.sha256,
            identity.byte_count,
        )?;
        let mut state = self.state.borrow_mut();
        if state.current_location().as_ref() != Some(&location)
            || state
                .identities
                .get(&location.source)
                .is_some_and(|old| old != &identity)
        {
            return Err(tr("Das PDF hat sich geändert.", "The PDF changed.").into());
        }
        #[derive(Deserialize)]
        struct Word {
            rectangle: Rect,
        }
        let words = if response.get("words").is_some() {
            decode::<Vec<Word>>(response, "words")?
                .into_iter()
                .map(|word| word.rectangle)
                .collect()
        } else {
            vec![]
        };
        state.document = Some(Document {
            pages,
            words,
            suggestions: decode(response, "suggestions")?,
            suggested_values: decode(response, "suggestedValues")?,
        });
        state.identities.insert(location.source.clone(), identity);
        state.location = Some(location);
        drop(state);
        self.picture.set_texture(Some(&texture));
        self.viewport.hadjustment().set_value(0.0);
        self.viewport.vadjustment().set_value(0.0);
        self.render_selection();
        self.render_suggestions();
        let can_click = self
            .state
            .borrow()
            .document
            .as_ref()
            .is_some_and(|doc| !doc.words.is_empty());
        self.source_status.set_text(if can_click {
            tr(
                "Ein Wort anklicken oder einen Bereich aufziehen.",
                "Click a word or drag a rectangle.",
            )
        } else {
            tr(
                "Einen Bereich im PDF aufziehen.",
                "Drag a rectangle on the PDF.",
            )
        });
        Ok(())
    }

    fn cancel(&self) {
        let mut state = self.state.borrow_mut();
        state.inspect_pending = false;
        state.evaluate_pending = false;
        if let Some(active) = &mut state.active {
            active.cancelled = true;
            if matches!(active.request, Request::Inspect(_)) {
                self.source_status.set_text(tr(
                    "PDF-Ladevorgang abgebrochen.",
                    "Reading the PDF was cancelled.",
                ));
            }
            active.handle.cancel();
        }
        drop(state);
        self.stop_debounce();
        self.status
            .set_text(tr("Abbruch angefordert.", "Cancellation requested."));
        self.update_controls();
    }

    fn update_controls(&self) {
        let state = self.state.borrow();
        let source = state.source();
        self.filename
            .set_text(&source.map(|path| file_name(path)).unwrap_or_default());
        self.filename
            .set_tooltip_text(source.and_then(|path| path.to_str()));
        let loaded = self.picture.texture().is_some();
        if let Some(doc) = &state.document {
            self.page_count.set_text(&format!(
                "{} {}/{}",
                tr("Seite", "Page"),
                state.page + 1,
                doc.pages.len()
            ));
        } else {
            self.page_count.set_text(tr("Seite —", "Page —"));
        }
        self.doc_count.set_text(&if source.is_some() {
            format!("PDF {}/{}", state.index + 1, state.pdfs.len())
        } else {
            "PDF —".to_owned()
        });
        let editable = state.editable();
        let pages = state.document.as_ref().map_or(0, |doc| doc.pages.len());
        self.previous_pdf.set_sensitive(editable && state.index > 0);
        self.next_pdf
            .set_sensitive(editable && state.index + 1 < state.pdfs.len());
        self.previous_page.set_sensitive(editable && state.page > 0);
        self.next_page
            .set_sensitive(editable && state.page + 1 < pages);
        for button in [&self.zoom_in, &self.zoom_out, &self.fit] {
            button.set_sensitive(loaded);
        }
        self.add.set_sensitive(editable);
        self.partner.set_sensitive(editable);
        self.document_type.set_sensitive(editable);
        self.fields.set_sensitive(editable);
        self.suggestions.set_sensitive(editable);
        self.selected.set_sensitive(editable);
        self.load.set_sensitive(editable && state.active.is_none());
        self.reload
            .set_sensitive(editable && state.active.is_none() && state.saved_mask.is_some());
        self.save
            .set_sensitive(editable && state.active.is_none() && !state.mask.fields.is_empty());
        self.preview_json.set_sensitive(
            state
                .result
                .as_ref()
                .is_some_and(|result| result.json.is_some()),
        );
        self.export.set_sensitive(
            editable
                && state.active.is_none()
                && !state.mask.fields.is_empty()
                && state
                    .result
                    .as_ref()
                    .is_some_and(|result| result.json.is_some()),
        );
        self.cancel.set_sensitive(
            state
                .active
                .as_ref()
                .is_some_and(|active| !active.cancelled),
        );
        self.batch.set_sensitive(editable);
        self.retry.set_visible(
            editable
                && source.is_some()
                && state.active.is_none()
                && !state.inspect_pending
                && (!loaded || (state.result.is_none() && !state.evaluate_pending)),
        );
        self.add_region.set_sensitive(state.mask.fields.len() < 500);
        self.replace.set_sensitive(!state.mask.fields.is_empty());
        self.replace_region
            .set_sensitive(!state.mask.fields.is_empty());
        if let Some((_, path)) = &state.saved_mask {
            self.mask_file.set_label(&file_name(path));
            self.mask_file.set_tooltip_text(path.to_str());
            self.mask_file.set_visible(true);
        } else {
            self.mask_file.set_visible(false);
        }
        if source.is_none() {
            self.source_status.set_text(tr(
                "PDF-Dateien hier ablegen oder hinzufügen.",
                "Drop or add PDF files.",
            ));
        }
    }

    fn zoom(&self, direction: i8) {
        if direction == 0 {
            self.picture.set_zoom(Zoom::Fit);
        } else if let Some(texture) = self.picture.texture() {
            let current = match self.picture.zoom() {
                Zoom::Fit => self.picture.rectangle().2 / f64::from(texture.width()),
                Zoom::Scale(scale) => scale,
            };
            let next = current * if direction < 0 { 0.8 } else { 1.25 };
            if direction > 0 || next >= 0.25 {
                self.picture.set_zoom(Zoom::Scale(next));
            }
        }
    }

    fn canvas_point(&self, x: f64, y: f64, clamp: bool) -> Option<(f64, f64)> {
        let (left, top, width, height) = self.picture.rectangle();
        if width <= 0.0 || height <= 0.0 || !self.state.borrow().editable() {
            return None;
        }
        let px = (x - left) / width;
        let py = (y - top) / height;
        if clamp || ((0.0..=1.0).contains(&px) && (0.0..=1.0).contains(&py)) {
            Some((px.clamp(0.0, 1.0), py.clamp(0.0, 1.0)))
        } else {
            None
        }
    }

    fn drag_selection(&self, dx: f64, dy: f64, finished: bool) {
        let Some((x, y)) = self.drag_start.get() else {
            return;
        };
        let Some(start) = self.canvas_point(x, y, false) else {
            return;
        };
        let Some(end) = self.canvas_point(x + dx, y + dy, true) else {
            return;
        };
        let state = self.state.borrow();
        let Some(doc) = &state.document else {
            return;
        };
        let page = doc.pages[state.page];
        let selection = if dx.abs() < 3.0 && dy.abs() < 3.0 {
            let (x, y) = page.point(start.0, start.1);
            doc.words.iter().find(|word| word.contains(x, y)).copied()
        } else {
            let rect = page.region(start, end);
            (rect.width > 0.0 && rect.height > 0.0).then_some(rect)
        };
        if finished {
            let selection = selection.map(|rectangle| Selection {
                page: state.page,
                rectangle,
            });
            drop(state);
            self.set_selection(selection);
        } else {
            self.picture
                .set_selection(selection.map(|rect| page.overlay(rect)));
        }
    }

    fn set_selection(&self, selection: Option<Selection>) {
        self.state.borrow_mut().selection = selection;
        self.render_selection();
    }

    fn render_selection(&self) {
        let state = self.state.borrow();
        let page = state
            .document
            .as_ref()
            .and_then(|doc| doc.pages.get(state.page))
            .copied();
        let selection = state.selection.as_ref();
        self.picture.set_selection(
            page.and_then(|page| selection.map(|selection| page.overlay(selection.rectangle))),
        );
        let marks = page
            .map(|page| {
                state
                    .marked
                    .iter()
                    .filter(|mark| mark.page == state.page)
                    .map(|mark| page.overlay(mark.rectangle))
                    .collect()
            })
            .unwrap_or_default();
        self.picture.set_marks(marks);
        if let Some(selection) = selection {
            self.selected_region.set_text(&format!(
                "{} {} · {}",
                tr("Seite", "Page"),
                selection.page + 1,
                selection.rectangle.dimensions()
            ));
        }
        self.selected.set_visible(selection.is_some());
    }

    fn apply_region(self: &Rc<Self>, replace: bool) {
        let mut state = self.state.borrow_mut();
        let Some(selection) = state.selection.take() else {
            return;
        };
        let rule = Rule::Region {
            page: selection.page,
            rectangle: selection.rectangle,
        };
        if replace {
            let Some(field) = state.mask.fields.get_mut(self.replace.selected() as usize) else {
                return;
            };
            field.rule = rule;
            let id = field.id.clone();
            discard_corrections(&mut state, &id);
        } else {
            let name = (1..=state.mask.fields.len() + 1)
                .map(|n| format!("{} {n}", tr("Feld", "Field")))
                .find(|name| state.mask.fields.iter().all(|field| field.name != *name))
                .expect("available field name");
            state.mask.fields.push(Field {
                id: glib::uuid_string_random().to_ascii_uppercase(),
                name,
                rule,
            });
        }
        state.marked.clear();
        drop(state);
        self.render_selection();
        self.rebuild_fields();
        self.render_suggestions();
        self.changed(false);
    }

    fn rebuild_fields(self: &Rc<Self>) {
        clear(&self.fields);
        section(
            &self.fields,
            tr("Felder und aktuelle Werte", "Fields and current values"),
        );
        let fields = self.state.borrow().mask.fields.clone();
        let mut rows = Vec::new();
        if fields.is_empty() {
            let hint = label(tr(
                "Einen Vorschlag übernehmen oder einen PDF-Bereich auswählen.",
                "Accept a suggestion or select a PDF region.",
            ));
            hint.add_css_class("dim-label");
            self.fields.append(&hint);
        }
        for field in fields {
            self.fields
                .append(&gtk::Separator::new(gtk::Orientation::Horizontal));
            let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let name = gtk::Entry::builder()
                .text(&field.name)
                .hexpand(true)
                .build();
            name.update_property(&[gtk::accessible::Property::Label(tr(
                "Feldname",
                "Field name",
            ))]);
            let remove = icon("user-trash-symbolic", tr("Feld entfernen", "Remove field"));
            top.append(&name);
            top.append(&remove);
            self.fields.append(&top);

            let rule = label(&field.rule.description());
            rule.add_css_class("dim-label");
            self.fields.append(&rule);
            let value = label("");
            value.set_selectable(true);
            self.fields.append(&value);
            let details = label("");
            details.set_selectable(true);
            details.add_css_class("dim-label");
            self.fields.append(&details);
            let evidence = gtk::MenuButton::builder()
                .label(tr("Quelle zeigen", "Show source"))
                .build();
            let correct = gtk::Button::with_label(tr("Wert korrigieren…", "Correct value…"));
            let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            actions.append(&evidence);
            actions.append(&correct);
            self.fields.append(&actions);

            let id = field.id.clone();
            let weak = Rc::downgrade(self);
            name.connect_changed(move |entry| {
                if let Some(editor) = weak.upgrade() {
                    let mut state = editor.state.borrow_mut();
                    if let Some(field) = state.mask.fields.iter_mut().find(|field| field.id == id) {
                        field.name = entry.text().into();
                    }
                    drop(state);
                    editor.update_replace_fields();
                    editor.render_suggestions();
                    editor.changed(true);
                }
            });
            let id = field.id.clone();
            clicked(&remove, self, move |editor| {
                {
                    let mut state = editor.state.borrow_mut();
                    state.mask.fields.retain(|field| field.id != id);
                    discard_corrections(&mut state, &id);
                    state.marked.clear();
                }
                editor.render_selection();
                editor.rebuild_fields();
                editor.render_suggestions();
                editor.changed(false);
            });
            let id = field.id.clone();
            clicked(&correct, self, move |editor| editor.correct(&id));
            rows.push(FieldRow {
                id: field.id,
                value,
                details,
                evidence,
                correct,
            });
        }
        *self.field_rows.borrow_mut() = rows;
        self.update_replace_fields();
        self.render_results();
    }

    fn update_replace_fields(&self) {
        let state = self.state.borrow();
        let names = state
            .mask
            .fields
            .iter()
            .map(|field| field.name.as_str())
            .collect::<Vec<_>>();
        let previous = self.replace.selected();
        self.replace.set_model(Some(&gtk::StringList::new(&names)));
        if (previous as usize) < names.len() {
            self.replace.set_selected(previous);
        }
    }

    fn render_results(self: &Rc<Self>) {
        let state = self.state.borrow();
        for row in self.field_rows.borrow().iter() {
            let value = state
                .result
                .as_ref()
                .and_then(|result| result.fields.iter().find(|value| value.id == row.id));
            row.value.set_text(
                value
                    .and_then(|value| value.value.as_deref())
                    .unwrap_or("—"),
            );
            row.details.set_text(
                &value
                    .map(|value| match &value.diagnostic {
                        Some(diagnostic) => format!("{} · {diagnostic}", value.status.title()),
                        None => value.status.title().to_owned(),
                    })
                    .unwrap_or_default(),
            );
            row.details.set_visible(value.is_some());
            row.correct.set_sensitive(value.is_some());
            if let Some(value) = value.filter(|value| !value.sources.is_empty()) {
                let popover = gtk::Popover::new();
                let candidates = padded(4, 4);
                if value.sources.len() == 1 || !matches!(value.status, ValueStatus::Ambiguous) {
                    self.evidence_button(
                        &candidates,
                        &popover,
                        tr("Fundstelle hervorheben", "Highlight source"),
                        value.sources.clone(),
                    );
                } else {
                    for evidence in &value.sources {
                        let name = format!(
                            "{} {} · {}",
                            tr("Seite", "Page"),
                            evidence.page + 1,
                            evidence.text
                        );
                        self.evidence_button(&candidates, &popover, &name, vec![evidence.clone()]);
                    }
                }
                let choices = gtk::ScrolledWindow::builder()
                    .child(&candidates)
                    .max_content_height(260)
                    .propagate_natural_height(true)
                    .propagate_natural_width(true)
                    .build();
                popover.set_child(Some(&choices));
                row.evidence.set_popover(Some(&popover));
                row.evidence.set_visible(true);
            } else {
                row.evidence.set_popover(None::<&gtk::Popover>);
                row.evidence.set_visible(false);
            }
        }
    }

    fn evidence_button(
        self: &Rc<Self>,
        parent: &gtk::Box,
        popover: &gtk::Popover,
        name: &str,
        evidence: Vec<Evidence>,
    ) {
        let button = gtk::Button::new();
        button.set_child(Some(&single_line(name)));
        button.set_tooltip_text(Some(name));
        button.add_css_class("flat");
        let popover = popover.downgrade();
        clicked(&button, self, move |editor| {
            if let Some(popover) = popover.upgrade() {
                popover.popdown();
            }
            editor.show_evidence(&evidence);
        });
        parent.append(&button);
    }

    fn show_evidence(self: &Rc<Self>, evidence: &[Evidence]) {
        let Some(first) = evidence.first() else {
            return;
        };
        let mut state = self.state.borrow_mut();
        state.marked = evidence
            .iter()
            .map(|source| Selection {
                page: source.page,
                rectangle: source.rectangle,
            })
            .collect();
        let navigate = first.page != state.page;
        drop(state);
        if navigate {
            self.show_page(first.page);
        } else {
            self.render_selection();
            let state = self.state.borrow();
            if let Some(page) = state
                .document
                .as_ref()
                .and_then(|doc| doc.pages.get(first.page))
            {
                let [left, top, width, height] = page.overlay(first.rectangle);
                let (x, y, w, h) = self.picture.rectangle();
                for (adjustment, center) in [
                    (self.viewport.hadjustment(), x + (left + width / 2.0) * w),
                    (self.viewport.vadjustment(), y + (top + height / 2.0) * h),
                ] {
                    adjustment.set_value(center - adjustment.page_size() / 2.0);
                }
            }
        }
    }

    fn render_suggestions(self: &Rc<Self>) {
        clear(&self.suggestions);
        let state = self.state.borrow();
        let Some(doc) = &state.document else {
            self.suggestions.set_visible(false);
            return;
        };
        let suggestions =
            doc.suggestions
                .iter()
                .filter(|field| {
                    !state.rejected.contains(&field.rule)
                        && !state.mask.fields.iter().any(|existing| {
                            existing.name == field.name || existing.rule == field.rule
                        })
                })
                .map(|field| {
                    (
                        field.clone(),
                        doc.suggested_values
                            .iter()
                            .find(|value| value.id == field.id)
                            .cloned(),
                    )
                })
                .collect::<Vec<_>>();
        let has_room = state.mask.fields.len() < 500;
        let accept_all = state.mask.fields.len() + suggestions.len() <= 500;
        drop(state);
        self.suggestions.set_visible(!suggestions.is_empty());
        if suggestions.is_empty() {
            return;
        }
        self.suggestions
            .append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        section(
            &self.suggestions,
            tr("Vorgeschlagene Felder", "Suggested fields"),
        );
        for (field, value) in &suggestions {
            let info = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let title = label(&field.name);
            title.set_hexpand(true);
            info.append(&title);
            let accept = gtk::Button::with_label(tr("Übernehmen", "Accept"));
            accept.set_sensitive(has_room);
            let reject = gtk::Button::with_label(tr("Verwerfen", "Reject"));
            info.append(&accept);
            info.append(&reject);
            self.suggestions.append(&info);
            let rule = label(&field.rule.description());
            rule.add_css_class("dim-label");
            self.suggestions.append(&rule);
            if let Some(value) = value {
                if value.sources.is_empty() {
                    self.suggestions.append(&label(value.status.title()));
                } else {
                    let show = gtk::Button::with_label(
                        value
                            .value
                            .as_deref()
                            .unwrap_or_else(|| value.status.title()),
                    );
                    show.add_css_class("flat");
                    show.set_halign(gtk::Align::Start);
                    let evidence = value.sources.clone();
                    clicked(&show, self, move |editor| editor.show_evidence(&evidence));
                    self.suggestions.append(&show);
                }
            }
            let accepted = field.clone();
            clicked(&accept, self, move |editor| {
                editor.choose_suggestions(vec![accepted.clone()], true)
            });
            let rejected = field.clone();
            clicked(&reject, self, move |editor| {
                editor.choose_suggestions(vec![rejected.clone()], false)
            });
        }
        if suggestions.len() > 1 {
            let accept = gtk::Button::with_label(tr("Alle übernehmen", "Accept all"));
            accept.set_sensitive(accept_all);
            let reject = gtk::Button::with_label(tr("Alle verwerfen", "Reject all"));
            buttons(&self.suggestions, &[&accept, &reject]);
            let all = suggestions
                .into_iter()
                .map(|(field, _)| field)
                .collect::<Vec<_>>();
            let accepted = all.clone();
            clicked(&accept, self, move |editor| {
                editor.choose_suggestions(accepted.clone(), true)
            });
            clicked(&reject, self, move |editor| {
                editor.choose_suggestions(all.clone(), false)
            });
        }
    }

    fn choose_suggestions(self: &Rc<Self>, fields: Vec<Field>, accept: bool) {
        let mut state = self.state.borrow_mut();
        if accept {
            state.mask.fields.extend(fields);
            drop(state);
            self.rebuild_fields();
            self.changed(false);
        } else {
            state
                .rejected
                .extend(fields.into_iter().map(|field| field.rule));
            drop(state);
        }
        self.render_suggestions();
    }

    fn correct(self: &Rc<Self>, id: &str) {
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let state = self.state.borrow();
        let Some(source) = state.source().cloned() else {
            return;
        };
        let Some(value) = state
            .result
            .as_ref()
            .and_then(|result| result.fields.iter().find(|value| value.id == id))
        else {
            return;
        };
        let Some(field) = state.mask.fields.iter().find(|field| field.id == id) else {
            return;
        };
        let dialog = gtk::Window::builder()
            .transient_for(&window)
            .destroy_with_parent(true)
            .modal(true)
            .title(tr(
                "Wert dieses Belegs korrigieren",
                "Correct value for this receipt",
            ))
            .default_width(420)
            .build();
        let content = padded(10, 16);
        let name = label(&field.name);
        name.add_css_class("heading");
        content.append(&name);
        let entry = gtk::Entry::builder()
            .text(value.value.as_deref().unwrap_or(""))
            .activates_default(true)
            .build();
        entry.update_property(&[gtk::accessible::Property::Label(tr(
            "Korrigierter Wert",
            "Corrected value",
        ))]);
        content.append(&entry);
        let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
        let apply = gtk::Button::with_label(tr("Übernehmen", "Apply"));
        apply.add_css_class("suggested-action");
        apply.set_sensitive(!entry.text().trim().is_empty());
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        actions.set_halign(gtk::Align::End);
        actions.append(&cancel);
        actions.append(&apply);
        content.append(&actions);
        dialog.set_child(Some(&content));
        dialog.set_default_widget(Some(&apply));
        let weak_apply = apply.downgrade();
        entry.connect_changed(move |entry| {
            if let Some(apply) = weak_apply.upgrade() {
                apply.set_sensitive(!entry.text().trim().is_empty());
            }
        });
        let weak = Rc::downgrade(self);
        let id = id.to_owned();
        let text = entry.downgrade();
        let weak_dialog = dialog.downgrade();
        apply.connect_clicked(move |_| {
            if let Some(text) = text.upgrade()
                && let Some(editor) = weak.upgrade()
                && !text.text().trim().is_empty()
            {
                editor
                    .state
                    .borrow_mut()
                    .corrections
                    .entry(source.clone())
                    .or_default()
                    .insert(id.clone(), text.text().into());
                editor.changed(false);
            }
            if let Some(dialog) = weak_dialog.upgrade() {
                dialog.close();
            }
        });
        let weak_dialog = dialog.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(dialog) = weak_dialog.upgrade() {
                dialog.close();
            }
        });
        let keys = gtk::EventControllerKey::new();
        let weak_dialog = dialog.downgrade();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Escape
                && let Some(dialog) = weak_dialog.upgrade()
            {
                dialog.close();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        dialog.add_controller(keys);
        drop(state);
        entry.grab_focus();
        dialog.present();
    }

    fn install_mask(self: &Rc<Self>, mask: Mask, path: PathBuf) {
        self.syncing_entries.set(true);
        self.partner.set_text(&mask.partner);
        self.document_type.set_text(&mask.document_type);
        self.syncing_entries.set(false);
        {
            let mut state = self.state.borrow_mut();
            state.saved_mask = Some((mask.clone(), path));
            state.mask = mask;
            state.corrections.clear();
            state.marked.clear();
            state.selection = None;
        }
        self.render_selection();
        self.rebuild_fields();
        self.render_suggestions();
        self.status.set_text("");
        self.changed(false);
    }

    fn file_action(self: &Rc<Self>, action: &'static str) {
        let Some(window) = self.window.upgrade() else {
            return;
        };
        let name = self
            .state
            .borrow()
            .source()
            .map(|source| format!("{}.json", file_name(source)))
            .unwrap_or_else(|| "receipt.json".into());
        let (title, mode) = match action {
            "loadMask" => (
                tr("Extraktionsmaske wählen", "Choose extraction mask"),
                FileMode::Open,
            ),
            "saveMask" => (
                tr("Extraktionsmaske speichern", "Save extraction mask"),
                FileMode::Save("receipt-mask.json"),
            ),
            _ => (
                tr("Belegdaten exportieren", "Export receipt data"),
                FileMode::Save(&name),
            ),
        };
        let weak = Rc::downgrade(self);
        choose_file(&window, title, mode, move |result| {
            let Some(editor) = weak.upgrade() else {
                return;
            };
            match result {
                Ok(path) => editor.start_file(match action {
                    "loadMask" => Request::LoadMask(path),
                    "saveMask" => Request::SaveMask(path),
                    _ => Request::Export(path),
                }),
                Err(error) => editor.status.set_text(&error),
            }
        });
    }

    fn start_file(self: &Rc<Self>, request: Request) {
        let payload = {
            let state = self.state.borrow();
            if !state.editable() || state.active.is_some() {
                return;
            }
            let (action, path) = match &request {
                Request::LoadMask(path) => ("loadMask", path),
                Request::SaveMask(path) => ("saveMask", path),
                Request::Export(path) => ("export", path),
                _ => unreachable!("file request"),
            };
            let path = match path_text(path) {
                Ok(path) => path,
                Err(error) => {
                    self.status.set_text(&error);
                    return;
                }
            };
            match request {
                Request::LoadMask(_) => json!({"action": action, "path": path}),
                Request::SaveMask(_) => json!({"action": action, "path": path, "mask": state.mask}),
                Request::Export(_) => {
                    let Some(source) = state.source() else {
                        return;
                    };
                    json!({
                        "action": action, "path": path, "source": source.to_str(),
                        "sourceIdentity": state.identities.get(source), "mask": state.mask,
                        "corrections": state.corrections.get(source),
                    })
                }
                _ => unreachable!("file request"),
            }
        };
        self.status.set_text("");
        self.start(request, payload);
    }

    fn show_json(&self) {
        let state = self.state.borrow();
        let Some(json) = state
            .result
            .as_ref()
            .and_then(|result| result.json.as_ref())
        else {
            return;
        };
        let Some(parent) = self.window.upgrade() else {
            return;
        };
        let window = window(&parent, tr("JSON-Vorschau", "Preview JSON"), 640, 470);
        let text = text_view();
        text.buffer()
            .set_text(&serde_json::to_string_pretty(json).expect("JSON value"));
        window.set_child(Some(&scroll(&text, 260)));
        window.present();
    }
}

fn discard_corrections(state: &mut State, field: &str) {
    for corrections in state.corrections.values_mut() {
        corrections.remove(field);
    }
}
