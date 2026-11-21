use super::*;
use crate::source_canvas::Zoom;

impl Editor {
    pub(super) fn zoom(&self, direction: i8) {
        if direction == 0 {
            self.view.source.picture.set_zoom(Zoom::Fit);
        } else {
            self.view.source.picture.step_zoom(direction > 0);
        }
    }

    pub(super) fn canvas_point(&self, x: f64, y: f64, clamp: bool) -> Option<(f64, f64)> {
        let (left, top, width, height) = self.view.source.picture.rectangle();
        if width <= 0.0 || height <= 0.0 || !self.editable() {
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

    pub(super) fn drag_selection(&self, dx: f64, dy: f64, finished: bool) {
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
            self.view
                .source
                .picture
                .set_selection(selection.map(|rect| page.overlay(rect)));
        }
    }

    pub(super) fn set_selection(&self, selection: Option<Selection>) {
        self.state.borrow_mut().selection = selection;
        self.render_selection();
    }

    pub(super) fn render_selection(&self) {
        let state = self.state.borrow();
        let page = state
            .document
            .as_ref()
            .and_then(|doc| doc.pages.get(state.page))
            .copied();
        let selection = state.selection.as_ref();
        self.view.source.picture.set_selection(
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
        self.view.source.picture.set_marks(marks);
        if let Some(selection) = selection {
            self.view.mask.selected_region.set_text(&format!(
                "{} {} · {}",
                tr("Seite", "Page"),
                selection.page + 1,
                selection.rectangle.dimensions()
            ));
        }
        self.view.mask.selected.set_visible(selection.is_some());
    }

    pub(super) fn apply_region(self: &Rc<Self>, replace: bool) {
        let mut state = self.state.borrow_mut();
        let Some(selection) = state.selection.take() else {
            return;
        };
        let rule = Rule::Region {
            page: selection.page,
            rectangle: selection.rectangle,
        };
        if replace {
            let Some(field) = state
                .mask
                .fields
                .get_mut(self.view.mask.replace.selected() as usize)
            else {
                return;
            };
            field.rule = rule;
            let id = field.id.clone();
            state.discard_field_corrections(&id);
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

    pub(super) fn show_evidence(self: &Rc<Self>, evidence: &[Evidence]) {
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
                let (x, y, w, h) = self.view.source.picture.rectangle();
                for (adjustment, center) in [
                    (
                        self.view.source.viewport.hadjustment(),
                        x + (left + width / 2.0) * w,
                    ),
                    (
                        self.view.source.viewport.vadjustment(),
                        y + (top + height / 2.0) * h,
                    ),
                ] {
                    adjustment.set_value(center - adjustment.page_size() / 2.0);
                }
            }
        }
    }
}
