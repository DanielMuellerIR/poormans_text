use super::*;
use crate::source_raster::receipt_texture;
use pmt_bridge::JobHandle;
use serde_json::json;

enum Request {
    ReadPage {
        visit: PageVisit,
        mask_revision: Option<u64>,
    },
    Evaluate {
        visit: PageVisit,
        revision: u64,
    },
    File {
        action: FileAction,
        path: PathBuf,
    },
}

#[derive(Clone, Copy)]
pub(super) enum FileAction {
    LoadMask,
    SaveMask,
    Export,
}

impl FileAction {
    fn protocol_name(self) -> &'static str {
        match self {
            Self::LoadMask => "loadMask",
            Self::SaveMask => "saveMask",
            Self::Export => "export",
        }
    }
}

pub(super) struct Active {
    handle: JobHandle,
    request: Request,
    cancelled: bool,
}

impl Active {
    pub(super) fn locks_editor(&self) -> bool {
        matches!(self.request, Request::File { .. })
    }

    pub(super) fn cancelled(&self) -> bool {
        self.cancelled
    }

    pub(super) fn cancel(&mut self) {
        self.cancelled = true;
        self.handle.cancel();
    }

    pub(super) fn cancel_evaluation(&mut self) -> bool {
        if matches!(self.request, Request::Evaluate { .. }) {
            self.cancel();
            true
        } else {
            false
        }
    }
}

impl Editor {
    pub(super) fn pump(self: &Rc<Self>) {
        if self.closing.get() || self.active.borrow().is_some() {
            return;
        }
        let (request, payload) = {
            let mut state = self.state.borrow_mut();
            let Some(visit) = state.visit() else {
                return;
            };
            let source = visit.source.to_str().expect("validated PDF path");
            let identity = state.identities.get(&visit.source);
            let corrections = state.corrections.get(&visit.source);
            if state.inspect_pending {
                let (mask_revision, payload) = if state.document.is_some() {
                    (
                        None,
                        json!({
                            "action": "previewPage", "source": source, "page": visit.page,
                            "sourceIdentity": identity,
                        }),
                    )
                } else {
                    (
                        Some(state.revision),
                        json!({
                            "action": "inspect", "source": source, "page": visit.page,
                            "sourceIdentity": identity, "mask": state.mask, "corrections": corrections,
                        }),
                    )
                };
                state.inspect_pending = false;
                (
                    Request::ReadPage {
                        visit,
                        mask_revision,
                    },
                    payload,
                )
            } else if state.evaluate_pending
                && state.page_loaded
                && self.debounce.borrow().is_none()
            {
                let payload = json!({
                    "action": "evaluate", "source": source, "sourceIdentity": identity,
                    "mask": state.mask, "corrections": corrections,
                });
                state.evaluate_pending = false;
                (
                    Request::Evaluate {
                        visit,
                        revision: state.revision,
                    },
                    payload,
                )
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
        if matches!(request, Request::Evaluate { .. }) {
            self.view
                .footer
                .status
                .set_text(tr("Felder werden ausgewertet…", "Evaluating fields…"));
        }
        *self.active.borrow_mut() = Some(Active {
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
                if let Some(editor) = weak.upgrade() {
                    editor.finish_job(result);
                }
            },
        );
    }

    fn finish_job(self: &Rc<Self>, result: Result<Value, BridgeError>) {
        let Some(active) = self.active.borrow_mut().take() else {
            return;
        };
        if self.closing.get() {
            if let Some(window) = self.window.upgrade() {
                window.close();
            }
            return;
        }
        if !active.cancelled {
            self.finished(active.request, response(result));
            return;
        }
        if matches!(
            active.request,
            Request::File {
                action: FileAction::SaveMask | FileAction::Export,
                ..
            }
        ) {
            let committed = match result {
                Ok(value) => Some(value),
                Err(error) if error.kind == ErrorKind::Cancelled => error
                    .response
                    .filter(|value| value.get("ok").and_then(Value::as_bool) == Some(true)),
                Err(_) => None,
            };
            if let Some(value) = committed {
                self.finished(active.request, response(Ok(value)));
                return;
            }
        }
        let pending = {
            let state = self.state.borrow();
            state.inspect_pending || state.evaluate_pending
        };
        if !pending {
            self.view
                .footer
                .status
                .set_text(tr("Vorgang abgebrochen.", "Operation cancelled."));
        }
        self.update_controls();
        self.pump();
    }

    fn finished(self: &Rc<Self>, request: Request, result: Result<Value, String>) {
        match request {
            Request::ReadPage {
                visit,
                mask_revision,
            } => {
                let current = self.state.borrow().is_current(&visit);
                if current
                    && let Err(error) =
                        result.and_then(|value| self.show_inspection(&visit, mask_revision, &value))
                {
                    self.read_failed(&visit, &error);
                }
            }
            Request::Evaluate { visit, revision } => {
                let current = {
                    let state = self.state.borrow();
                    state.is_current(&visit) && revision == state.revision
                };
                if current
                    && let Err(error) =
                        result.and_then(|value| self.show_evaluation(&visit, revision, &value))
                {
                    self.read_failed(&visit, &error);
                }
            }
            Request::File { action, path } => {
                if let Err(error) = result.and_then(|value| self.finish_file(action, path, &value))
                {
                    self.view.footer.status.set_text(&error);
                }
            }
        }
        self.update_controls();
        self.pump();
    }

    fn read_failed(self: &Rc<Self>, visit: &PageVisit, error: &str) {
        if !self.state.borrow_mut().reject_read(visit) {
            return;
        }
        self.stop_debounce();
        self.drag_start.set(None);
        self.view.source.picture.set_texture(None);
        self.view.source.source_status.set_text(error);
        self.view.footer.status.set_text("");
        self.render_selection();
        self.render_suggestions();
        self.render_results();
    }

    fn show_evaluation(
        self: &Rc<Self>,
        visit: &PageVisit,
        revision: u64,
        response: &Value,
    ) -> Result<(), String> {
        let identity = decode(response, "sourceIdentity")?;
        let evaluation = {
            let mut state = self.state.borrow_mut();
            if state.identities.get(&visit.source) != Some(&identity) {
                return Err(tr("Das PDF hat sich geändert.", "The PDF changed.").into());
            }
            state.apply_evaluation(revision, response)?
        };
        self.show_evaluation_status(evaluation);
        self.render_results();
        Ok(())
    }

    fn show_evaluation_status(&self, evaluation: Evaluation) {
        if let Evaluation::Complete(status) = evaluation {
            self.view
                .footer
                .status
                .set_text(status.as_deref().unwrap_or(""));
        }
    }

    fn show_inspection(
        self: &Rc<Self>,
        visit: &PageVisit,
        mask_revision: Option<u64>,
        response: &Value,
    ) -> Result<(), String> {
        let mut state = self.state.borrow_mut();
        let supplied_identity = mask_revision
            .map(|_| decode(response, "sourceIdentity"))
            .transpose()?;
        let identity = state.verify_identity(visit, supplied_identity)?;
        #[derive(Deserialize)]
        struct Word {
            rectangle: Rect,
        }
        let words: Vec<Rect> = decode::<Vec<Word>>(response, "words")?
            .into_iter()
            .map(|word| word.rectangle)
            .collect();
        let can_click = !words.is_empty();
        let truncated: bool = decode(response, "wordsTruncated")?;
        let pages: Vec<Page> = if mask_revision.is_some() {
            let pages: Vec<Page> = decode(response, "pages")?;
            if pages.len() > 1000 || !pages.iter().all(|page| page.valid()) {
                return Err("Invalid receipt page geometry".into());
            }
            pages
        } else {
            state
                .document
                .as_ref()
                .ok_or("Missing receipt geometry")?
                .pages
                .clone()
        };
        if visit.page >= pages.len() {
            return Err("Invalid receipt page geometry".into());
        }
        let texture = receipt_texture(
            response.get("preview").ok_or("Missing receipt raster")?,
            (visit.page + 1) as u32,
            pages.len(),
            &identity.sha256,
            identity.byte_count,
        )?;
        let evaluation = if let Some(revision) = mask_revision {
            let document = Document {
                pages,
                words,
                suggestions: decode(response, "suggestions")?,
                suggested_values: decode(response, "suggestedValues")?,
            };
            let evaluation = state.apply_evaluation(revision, response)?;
            state.document = Some(document);
            state.identities.insert(visit.source.clone(), identity);
            evaluation
        } else {
            if let Some(document) = state.document.as_mut() {
                document.words = words;
            }
            Evaluation::Deferred
        };
        state.page_loaded = true;
        drop(state);
        self.show_evaluation_status(evaluation);
        self.view.source.picture.set_texture(Some(&texture));
        self.view.source.viewport.hadjustment().set_value(0.0);
        self.view.source.viewport.vadjustment().set_value(0.0);
        self.render_selection();
        if mask_revision.is_some() {
            self.render_suggestions();
            self.render_results();
        }
        self.view.source.source_status.set_text(if truncated {
            tr(
                "Nur die ersten 10.000 Wörter sind anklickbar. Weitere Wörter mit einem Rahmen auswählen.",
                "Only the first 10,000 words are clickable. Drag a rectangle to select other words.",
            )
        } else if can_click {
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

    pub(super) fn cancel(&self) {
        {
            let mut state = self.state.borrow_mut();
            state.inspect_pending = false;
            state.evaluate_pending = false;
        }
        if let Some(active) = self.active.borrow_mut().as_mut() {
            if matches!(active.request, Request::ReadPage { .. }) {
                self.view.source.source_status.set_text(tr(
                    "PDF-Ladevorgang abgebrochen.",
                    "Reading the PDF was cancelled.",
                ));
            }
            active.cancel();
        }
        self.stop_debounce();
        self.view
            .footer
            .status
            .set_text(tr("Abbruch angefordert.", "Cancellation requested."));
        self.update_controls();
    }

    pub(super) fn file_action(self: &Rc<Self>, action: FileAction) {
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
            FileAction::LoadMask => (
                tr("Extraktionsmaske wählen", "Choose extraction mask"),
                FileMode::Open,
            ),
            FileAction::SaveMask => (
                tr("Extraktionsmaske speichern", "Save extraction mask"),
                FileMode::Save("receipt-mask.json"),
            ),
            FileAction::Export => (
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
                Ok(path) => editor.start_file(action, path),
                Err(error) => editor.view.footer.status.set_text(&error),
            }
        });
    }

    pub(super) fn start_file(self: &Rc<Self>, action: FileAction, path: PathBuf) {
        if !self.editable() || self.active.borrow().is_some() {
            return;
        }
        let path_value = match path_text(&path) {
            Ok(path) => path,
            Err(error) => {
                self.view.footer.status.set_text(&error);
                return;
            }
        };
        let name = action.protocol_name();
        let payload = {
            let state = self.state.borrow();
            match action {
                FileAction::LoadMask => json!({"action": name, "path": path_value}),
                FileAction::SaveMask => {
                    json!({"action": name, "path": path_value, "mask": state.mask})
                }
                FileAction::Export => {
                    if !state.can_export() {
                        return;
                    }
                    let Some(source) = state.source() else {
                        return;
                    };
                    let Some(identity) = state.identities.get(source) else {
                        return;
                    };
                    json!({
                        "action": name, "path": path_value, "source": source.to_str(),
                        "sourceIdentity": identity, "mask": state.mask,
                        "corrections": state.corrections.get(source),
                    })
                }
            }
        };
        self.view.footer.status.set_text("");
        self.start(Request::File { action, path }, payload);
    }

    fn finish_file(
        self: &Rc<Self>,
        action: FileAction,
        path: PathBuf,
        response: &Value,
    ) -> Result<(), String> {
        match action {
            FileAction::LoadMask => self.install_mask(decode(response, "mask")?, path),
            FileAction::SaveMask => {
                let mut state = self.state.borrow_mut();
                state.saved_mask = Some((state.mask.clone(), path.clone()));
                self.view.footer.status.set_text(&format!(
                    "{} {}",
                    tr("Maske gespeichert", "Mask saved"),
                    path.display()
                ));
            }
            FileAction::Export => self.view.footer.status.set_text(&format!(
                "{} {}",
                tr("JSON exportiert", "JSON exported"),
                path.display()
            )),
        }
        Ok(())
    }
}
