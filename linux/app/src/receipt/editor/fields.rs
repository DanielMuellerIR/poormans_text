use super::*;

pub(super) struct FieldRow {
    id: String,
    value: gtk::Label,
    details: gtk::Label,
    evidence: gtk::MenuButton,
    correct: gtk::Button,
}

impl Editor {
    pub(super) fn rebuild_fields(self: &Rc<Self>) {
        clear(&self.view.mask.fields);
        section(
            &self.view.mask.fields,
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
            self.view.mask.fields.append(&hint);
        }
        for field in fields {
            self.view
                .mask
                .fields
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
            self.view.mask.fields.append(&top);

            let rule = label(&field.rule.description());
            rule.add_css_class("dim-label");
            self.view.mask.fields.append(&rule);
            let value = label("");
            value.set_selectable(true);
            self.view.mask.fields.append(&value);
            let details = label("");
            details.set_selectable(true);
            details.add_css_class("dim-label");
            self.view.mask.fields.append(&details);
            let evidence = gtk::MenuButton::builder()
                .label(tr("Quelle zeigen", "Show source"))
                .build();
            let correct = gtk::Button::with_label(tr("Wert korrigieren…", "Correct value…"));
            correct.set_tooltip_text(Some(tr(
                "Ändert den Wert nur für diesen Beleg. Die Suchregel der Maske bleibt erhalten.",
                "Changes the value for this receipt only. The mask’s rule stays the same.",
            )));
            let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            actions.append(&evidence);
            actions.append(&correct);
            self.view.mask.fields.append(&actions);

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
                    state.discard_field_corrections(&id);
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
    }

    fn update_replace_fields(&self) {
        let state = self.state.borrow();
        let names = state
            .mask
            .fields
            .iter()
            .map(|field| field.name.as_str())
            .collect::<Vec<_>>();
        let previous = self.view.mask.replace.selected();
        self.view
            .mask
            .replace
            .set_model(Some(&gtk::StringList::new(&names)));
        if (previous as usize) < names.len() {
            self.view.mask.replace.set_selected(previous);
        }
    }

    pub(super) fn render_results(self: &Rc<Self>) {
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

    pub(super) fn render_suggestions(self: &Rc<Self>) {
        clear(&self.view.mask.suggestions);
        let state = self.state.borrow();
        let Some(doc) = &state.document else {
            self.view.mask.suggestions.set_visible(false);
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
        self.view
            .mask
            .suggestions
            .set_visible(!suggestions.is_empty());
        if suggestions.is_empty() {
            return;
        }
        self.view
            .mask
            .suggestions
            .append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        section(
            &self.view.mask.suggestions,
            tr("Vorgeschlagene Felder", "Suggested fields"),
        );
        for (field, value) in &suggestions {
            let info = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let title = label(&field.name);
            title.set_hexpand(true);
            info.append(&title);
            let accept = gtk::Button::with_label(tr("Übernehmen", "Accept"));
            accept.set_tooltip_text(Some(tr(
                "Fügt die vorgeschlagene Suchregel zur Maske hinzu.",
                "Adds the suggested extraction rule to the mask.",
            )));
            accept.set_sensitive(has_room);
            let reject = gtk::Button::with_label(tr("Verwerfen", "Reject"));
            reject.set_tooltip_text(Some(tr(
                "Blendet die vorgeschlagene Suchregel in diesem Editor aus.",
                "Dismisses the suggested extraction rule in this editor.",
            )));
            info.append(&accept);
            info.append(&reject);
            self.view.mask.suggestions.append(&info);
            let rule = label(&field.rule.description());
            rule.add_css_class("dim-label");
            self.view.mask.suggestions.append(&rule);
            if let Some(value) = value {
                if value.sources.is_empty() {
                    self.view
                        .mask
                        .suggestions
                        .append(&label(value.status.title()));
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
                    self.view.mask.suggestions.append(&show);
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
            buttons(&self.view.mask.suggestions, &[&accept, &reject]);
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
        let Some(visit) = state.visit().filter(|_| state.page_loaded) else {
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
        apply.set_tooltip_text(Some(tr(
            "Übernimmt den eingegebenen Wert für diesen Beleg.",
            "Applies the entered value to this receipt.",
        )));
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
                let mut state = editor.state.borrow_mut();
                if editor.editable() && state.is_current(&visit) && state.page_loaded {
                    state
                        .corrections
                        .entry(visit.source.clone())
                        .or_default()
                        .insert(id.clone(), text.text().into());
                    drop(state);
                    editor.changed(false);
                }
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
}
