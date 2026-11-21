mod canvas;
mod fields;
mod jobs;
mod state;
mod view;

use self::{
    fields::FieldRow,
    jobs::{Active, FileAction},
    state::{Document, Evaluation, PageVisit, Selection, State},
    view::View,
};
use super::*;
use crate::{label, scroll, source_canvas::SourceCanvas, text_view};
use geometry::Page;
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
};

struct Editor {
    window: glib::WeakRef<gtk::Window>,
    bridge: Bridge,
    state: RefCell<State>,
    syncing_entries: Cell<bool>,
    debounce: RefCell<Option<glib::SourceId>>,
    drag_start: Cell<Option<(f64, f64)>>,
    field_rows: RefCell<Vec<FieldRow>>,
    view: View,
    active: RefCell<Option<Active>>,
    closing: Cell<bool>,
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
    let editor = Rc::new(Editor {
        window: window.downgrade(),
        bridge: bridge.clone(),
        state: RefCell::new(State::default()),
        syncing_entries: Cell::new(false),
        debounce: RefCell::new(None),
        drag_start: Cell::new(None),
        field_rows: RefCell::new(vec![]),
        view: View::new(&window),
        active: RefCell::new(None),
        closing: Cell::new(false),
    });
    editor.connect(&window);
    if let Some((mask, path)) = loaded_mask {
        editor.install_mask(mask, path);
    } else {
        editor.rebuild_fields();
        editor.render_results();
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
    fn connect(self: &Rc<Self>, window: &gtk::Window) {
        clicked(&self.view.source.add, self, |editor| {
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
        file_drop(&self.view.source.container, move |paths| {
            weak.upgrade().is_some_and(|editor| editor.add_pdfs(paths))
        });
        clicked(&self.view.source.previous_pdf, self, |editor| {
            editor.move_document(-1)
        });
        clicked(&self.view.source.next_pdf, self, |editor| {
            editor.move_document(1)
        });
        clicked(&self.view.source.previous_page, self, |editor| {
            editor.move_page(-1)
        });
        clicked(&self.view.source.next_page, self, |editor| {
            editor.move_page(1)
        });
        clicked(&self.view.source.retry, self, |editor| {
            let (page, loaded) = {
                let state = editor.state.borrow();
                (state.page, state.page_loaded)
            };
            if loaded {
                editor.changed(false);
            } else {
                editor.show_page(page);
            }
        });
        clicked(&self.view.source.reload_source, self, |editor| {
            editor.reload_source()
        });
        clicked(&self.view.source.zoom_out, self, |editor| editor.zoom(-1));
        clicked(&self.view.source.fit, self, |editor| editor.zoom(0));
        clicked(&self.view.source.zoom_in, self, |editor| editor.zoom(1));
        clicked(&self.view.mask.clear_region, self, |editor| {
            editor.set_selection(None)
        });
        clicked(&self.view.mask.add_region, self, |editor| {
            editor.apply_region(false)
        });
        clicked(&self.view.mask.replace_region, self, |editor| {
            editor.apply_region(true)
        });
        clicked(&self.view.mask.load, self, |editor| {
            editor.file_action(FileAction::LoadMask)
        });
        clicked(&self.view.mask.reload, self, |editor| {
            let path = editor
                .state
                .borrow()
                .saved_mask
                .as_ref()
                .map(|(_, path)| path.clone());
            if let Some(path) = path {
                editor.start_file(FileAction::LoadMask, path);
            }
        });
        clicked(&self.view.mask.save, self, |editor| {
            editor.file_action(FileAction::SaveMask)
        });
        clicked(&self.view.footer.export, self, |editor| {
            editor.file_action(FileAction::Export)
        });
        clicked(&self.view.footer.preview_json, self, |editor| {
            editor.show_json()
        });
        clicked(&self.view.footer.cancel, self, |editor| editor.cancel());
        clicked(&self.view.footer.batch, self, |editor| {
            if let Some(window) = editor.window.upgrade() {
                let state = editor.state.borrow();
                let mask = state.saved_mask.clone();
                batch::open(&window, &editor.bridge, state.pdfs.clone(), mask);
            }
        });
        for (entry, partner) in [
            (&self.view.mask.partner, true),
            (&self.view.mask.document_type, false),
        ] {
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
        self.view.source.picture.add_controller(drag);

        let editor = self.clone();
        window.connect_close_request(move |_| {
            editor.closing.set(true);
            if editor.active.borrow().is_some() {
                editor.cancel();
                glib::Propagation::Stop
            } else {
                editor.stop_debounce();
                glib::Propagation::Proceed
            }
        });
    }

    fn add_pdfs(self: &Rc<Self>, paths: Result<Vec<PathBuf>, String>) -> bool {
        if !self.editable() {
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
                self.view.footer.status.set_text(&error);
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
        if !self.editable() || !self.state.borrow_mut().select_document(index) {
            return;
        }
        self.document_loading();
    }

    fn reload_source(self: &Rc<Self>) {
        if !self.editable()
            || self.active.borrow().is_some()
            || !self.state.borrow_mut().reload_document()
        {
            return;
        }
        self.document_loading();
    }

    fn document_loading(self: &Rc<Self>) {
        self.stop_debounce();
        self.view.footer.status.set_text("");
        self.render_results();
        self.render_suggestions();
        self.page_loading();
    }

    fn move_page(self: &Rc<Self>, offset: isize) {
        let page = self.state.borrow().page.checked_add_signed(offset);
        if let Some(page) = page {
            self.show_page(page);
        }
    }

    fn show_page(self: &Rc<Self>, page: usize) {
        if !self.editable() || !self.state.borrow_mut().select_page(page) {
            return;
        }
        self.page_loading();
    }

    fn page_loading(self: &Rc<Self>) {
        if let Some(active) = self.active.borrow_mut().as_mut() {
            if active.cancel_evaluation() {
                self.state.borrow_mut().evaluate_pending = true;
            } else {
                active.cancel();
            }
        }
        self.drag_start.set(None);
        self.view.source.picture.set_texture(None);
        self.view
            .source
            .source_status
            .set_text(tr("PDF wird gelesen…", "Reading PDF…"));
        self.render_selection();
        self.update_controls();
        self.pump();
    }

    fn changed(self: &Rc<Self>, debounce: bool) {
        self.stop_debounce();
        let revision = self.state.borrow_mut().revise_mask();
        if let Some(active) = self.active.borrow_mut().as_mut() {
            active.cancel_evaluation();
        }
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

    fn editable(&self) -> bool {
        !self.closing.get()
            && !self
                .active
                .borrow()
                .as_ref()
                .is_some_and(Active::locks_editor)
    }

    fn update_controls(&self) {
        let state = self.state.borrow();
        let source = state.source();
        self.view
            .source
            .filename
            .set_text(&source.map(|path| file_name(path)).unwrap_or_default());
        self.view
            .source
            .filename
            .set_tooltip_text(source.and_then(|path| path.to_str()));
        let loaded = self.view.source.picture.texture().is_some();
        if let Some(doc) = &state.document {
            self.view.source.page_count.set_text(&format!(
                "{} {}/{}",
                tr("Seite", "Page"),
                state.page + 1,
                doc.pages.len()
            ));
        } else {
            self.view
                .source
                .page_count
                .set_text(tr("Seite —", "Page —"));
        }
        self.view.source.doc_count.set_text(&if source.is_some() {
            format!("PDF {}/{}", state.index + 1, state.pdfs.len())
        } else {
            "PDF —".to_owned()
        });
        let editable = self.editable();
        let active = self.active.borrow();
        let pages = state.document.as_ref().map_or(0, |doc| doc.pages.len());
        self.view
            .source
            .previous_pdf
            .set_sensitive(editable && state.index > 0);
        self.view
            .source
            .next_pdf
            .set_sensitive(editable && state.index + 1 < state.pdfs.len());
        self.view
            .source
            .previous_page
            .set_sensitive(editable && pages > 0 && state.page > 0);
        self.view
            .source
            .next_page
            .set_sensitive(editable && state.page + 1 < pages);
        for button in [
            &self.view.source.zoom_in,
            &self.view.source.zoom_out,
            &self.view.source.fit,
        ] {
            button.set_sensitive(loaded);
        }
        self.view.source.add.set_sensitive(editable);
        self.view.mask.partner.set_sensitive(editable);
        self.view.mask.document_type.set_sensitive(editable);
        self.view.mask.fields.set_sensitive(editable);
        self.view.mask.suggestions.set_sensitive(editable);
        self.view.mask.selected.set_sensitive(editable);
        self.view
            .mask
            .load
            .set_sensitive(editable && active.is_none());
        self.view
            .mask
            .reload
            .set_sensitive(editable && active.is_none() && state.saved_mask.is_some());
        self.view
            .mask
            .save
            .set_sensitive(editable && active.is_none() && !state.mask.fields.is_empty());
        self.view
            .footer
            .preview_json
            .set_sensitive(state.can_export());
        self.view.footer.export.set_sensitive(
            editable && active.is_none() && !state.mask.fields.is_empty() && state.can_export(),
        );
        self.view
            .footer
            .cancel
            .set_sensitive(active.as_ref().is_some_and(|active| !active.cancelled()));
        self.view.footer.batch.set_sensitive(editable);
        self.view.source.reload_source.set_visible(
            editable
                && active.is_none()
                && state.source_failed
                && source.is_some_and(|source| state.identities.contains_key(source)),
        );
        self.view.source.retry.set_visible(
            editable
                && source.is_some()
                && active.is_none()
                && !state.inspect_pending
                && (!loaded || (state.result.is_none() && !state.evaluate_pending)),
        );
        self.view
            .mask
            .add_region
            .set_sensitive(state.mask.fields.len() < 500);
        self.view
            .mask
            .replace
            .set_sensitive(!state.mask.fields.is_empty());
        self.view
            .mask
            .replace_region
            .set_sensitive(!state.mask.fields.is_empty());
        if let Some((_, path)) = &state.saved_mask {
            self.view.mask.mask_file.set_label(&file_name(path));
            self.view.mask.mask_file.set_tooltip_text(path.to_str());
            self.view.mask.mask_file.set_visible(true);
        } else {
            self.view.mask.mask_file.set_visible(false);
        }
        if source.is_none() {
            self.view.source.source_status.set_text(tr(
                "PDF-Dateien hier ablegen oder hinzufügen.",
                "Drop or add PDF files.",
            ));
        }
    }

    fn install_mask(self: &Rc<Self>, mask: Mask, path: PathBuf) {
        self.syncing_entries.set(true);
        self.view.mask.partner.set_text(&mask.partner);
        self.view.mask.document_type.set_text(&mask.document_type);
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
        self.view.footer.status.set_text("");
        self.changed(false);
    }

    fn show_json(&self) {
        let state = self.state.borrow();
        if !state.page_loaded {
            return;
        }
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

impl Drop for Editor {
    fn drop(&mut self) {
        self.stop_debounce();
    }
}
