use super::*;

pub(super) type Corrections = HashMap<String, String>;

#[derive(Clone)]
pub(super) struct Selection {
    pub(super) page: usize,
    pub(super) rectangle: Rect,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PageVisit {
    pub(super) source: PathBuf,
    pub(super) page: usize,
    generation: u64,
}

pub(super) struct Document {
    pub(super) pages: Vec<Page>,
    pub(super) words: Vec<Rect>,
    pub(super) suggestions: Vec<Field>,
    pub(super) suggested_values: Vec<FieldValue>,
}

#[derive(Deserialize)]
struct FieldReview {
    status: ValueStatus,
    diagnostic: Option<String>,
}

pub(super) struct CurrentResult {
    pub(super) fields: Vec<FieldValue>,
    pub(super) json: Option<Value>,
}

pub(super) enum Evaluation {
    Deferred,
    Complete(Option<String>),
}

#[derive(Default)]
pub(super) struct State {
    pub(super) pdfs: Vec<PathBuf>,
    pub(super) index: usize,
    pub(super) page: usize,
    pub(super) page_loaded: bool,
    pub(super) source_failed: bool,
    pub(super) identities: HashMap<PathBuf, Identity>,
    pub(super) document: Option<Document>,
    pub(super) mask: Mask,
    pub(super) saved_mask: Option<(Mask, PathBuf)>,
    pub(super) result: Option<CurrentResult>,
    pub(super) corrections: HashMap<PathBuf, Corrections>,
    pub(super) rejected: Vec<Rule>,
    pub(super) selection: Option<Selection>,
    pub(super) marked: Vec<Selection>,
    pub(super) inspect_pending: bool,
    pub(super) evaluate_pending: bool,
    pub(super) revision: u64,
    generation: u64,
}

impl State {
    pub(super) fn source(&self) -> Option<&PathBuf> {
        self.pdfs.get(self.index)
    }

    pub(super) fn visit(&self) -> Option<PageVisit> {
        Some(PageVisit {
            source: self.source()?.clone(),
            page: self.page,
            generation: self.generation,
        })
    }

    pub(super) fn is_current(&self, visit: &PageVisit) -> bool {
        self.source() == Some(&visit.source)
            && self.page == visit.page
            && self.generation == visit.generation
    }

    pub(super) fn select_document(&mut self, index: usize) -> bool {
        if index >= self.pdfs.len() {
            return false;
        }
        self.index = index;
        self.page = 0;
        self.clear_document();
        self.select_page(0)
    }

    pub(super) fn select_page(&mut self, page: usize) -> bool {
        if self.source().is_none()
            || self
                .document
                .as_ref()
                .map_or(page != self.page, |doc| page >= doc.pages.len())
        {
            return false;
        }
        self.page = page;
        self.page_loaded = false;
        self.source_failed = false;
        self.selection = None;
        self.generation += 1;
        self.inspect_pending = true;
        true
    }

    pub(super) fn reload_document(&mut self) -> bool {
        let Some(source) = self.source().cloned() else {
            return false;
        };
        if !self.source_failed || self.identities.remove(&source).is_none() {
            return false;
        }
        self.corrections.remove(&source);
        self.select_document(self.index)
    }

    pub(super) fn reject_read(&mut self, visit: &PageVisit) -> bool {
        if !self.is_current(visit) {
            return false;
        }
        self.clear_document();
        self.inspect_pending = false;
        self.source_failed = true;
        self.generation += 1;
        true
    }

    fn clear_document(&mut self) {
        self.document = None;
        self.page_loaded = false;
        self.selection = None;
        self.marked.clear();
        self.revise_mask();
    }

    pub(super) fn revise_mask(&mut self) -> u64 {
        self.revision += 1;
        self.result = None;
        self.evaluate_pending = true;
        self.revision
    }

    pub(super) fn verify_identity(
        &self,
        visit: &PageVisit,
        returned: Option<Identity>,
    ) -> Result<Identity, String> {
        let expected = self.identities.get(&visit.source);
        match (expected, returned) {
            (None, Some(identity)) => Ok(identity),
            (Some(expected), Some(identity)) if *expected == identity => Ok(identity),
            (Some(expected), None) => Ok(expected.clone()),
            _ => Err(tr("Das PDF hat sich geändert.", "The PDF changed.").into()),
        }
    }

    pub(super) fn apply_evaluation(
        &mut self,
        revision: u64,
        response: &Value,
    ) -> Result<Evaluation, String> {
        if self.revision != revision {
            return Ok(Evaluation::Deferred);
        }
        let (result, status) =
            if let Some(error) = response.get("evaluationError").and_then(Value::as_str) {
                (None, Some(error.to_owned()))
            } else if let Some(result) = response.get("result") {
                let data: HashMap<String, Option<String>> = decode(result, "data")?;
                let mut sources: HashMap<String, Vec<Evidence>> = decode(result, "sources")?;
                let mut review: HashMap<String, FieldReview> = decode(result, "review")?;
                let fields = self
                    .mask
                    .fields
                    .iter()
                    .map(|field| {
                        let FieldReview { status, diagnostic } = review
                            .remove(&field.name)
                            .ok_or("Missing receipt field status")?;
                        Ok(FieldValue {
                            id: field.id.clone(),
                            value: data
                                .get(&field.name)
                                .ok_or("Missing receipt field value")?
                                .clone(),
                            status,
                            sources: sources
                                .remove(&field.name)
                                .ok_or("Missing receipt field sources")?,
                            diagnostic,
                        })
                    })
                    .collect::<Result<Vec<_>, &str>>()?;
                (
                    Some(CurrentResult {
                        fields,
                        json: Some(result.clone()),
                    }),
                    None,
                )
            } else if response.get("fields").is_some() {
                (
                    Some(CurrentResult {
                        fields: decode(response, "fields")?,
                        json: None,
                    }),
                    Some(
                        tr(
                            "Feldnamen müssen für den JSON-Export eindeutig sein.",
                            "Field names must be unique before exporting JSON.",
                        )
                        .into(),
                    ),
                )
            } else {
                return Ok(Evaluation::Deferred);
            };
        self.result = result;
        self.evaluate_pending = false;
        Ok(Evaluation::Complete(status))
    }

    pub(super) fn can_export(&self) -> bool {
        self.page_loaded
            && self
                .result
                .as_ref()
                .is_some_and(|result| result.json.is_some())
    }

    pub(super) fn discard_field_corrections(&mut self, field: &str) {
        for corrections in self.corrections.values_mut() {
            corrections.remove(field);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn identity(value: &str) -> Identity {
        Identity {
            sha256: value.repeat(64),
            byte_count: 100,
        }
    }

    fn two_documents() -> State {
        State {
            pdfs: vec!["/receipts/current.pdf".into(), "/receipts/other.pdf".into()],
            ..State::default()
        }
    }

    #[test]
    fn retry_retains_identity_and_reload_drops_only_current_pdf_state() {
        let mut state = two_documents();
        state.mask.partner = "Draft partner".into();
        state.saved_mask = Some((Mask::default(), "/receipts/saved.json".into()));
        assert!(state.select_document(0));
        let initial = state.visit().unwrap();
        let other = state.pdfs[1].clone();
        state
            .identities
            .insert(initial.source.clone(), identity("a"));
        state.identities.insert(other.clone(), identity("b"));
        let correction = |value: &str| HashMap::from([("field".into(), value.into())]);
        state
            .corrections
            .insert(initial.source.clone(), correction("one"));
        state.corrections.insert(other.clone(), correction("two"));
        state.page_loaded = true;
        state.result = Some(CurrentResult {
            fields: vec![],
            json: Some(json!({})),
        });
        assert!(state.can_export());

        assert!(state.reject_read(&initial));
        assert!(!state.can_export());
        assert!(state.select_page(0));
        let retry = state.visit().unwrap();
        assert!(state.verify_identity(&retry, Some(identity("c"))).is_err());
        assert_eq!(
            state.corrections.get(&initial.source),
            Some(&correction("one"))
        );
        assert!(state.reject_read(&retry));
        assert!(state.reload_document());

        let reload = state.visit().unwrap();
        assert_eq!(reload.source, initial.source);
        assert_eq!(reload.page, 0);
        assert_eq!(state.mask.partner, "Draft partner");
        assert_eq!(
            state.saved_mask.as_ref().unwrap().1,
            Path::new("/receipts/saved.json")
        );
        assert!(!state.identities.contains_key(&initial.source));
        assert!(!state.corrections.contains_key(&initial.source));
        assert_eq!(state.identities.get(&other), Some(&identity("b")));
        assert_eq!(state.corrections.get(&other), Some(&correction("two")));
        assert!(!state.page_loaded);
        assert!(state.inspect_pending);
        assert_eq!(
            state.verify_identity(&reload, Some(identity("c"))).unwrap(),
            identity("c")
        );
    }

    #[test]
    fn an_old_completion_cannot_invalidate_a_new_visit_to_the_same_page() {
        let mut state = two_documents();
        assert!(state.select_document(0));
        let first = state.visit().unwrap();
        assert!(state.select_document(1));
        assert!(state.select_document(0));
        let latest = state.visit().unwrap();
        assert!(state.is_current(&latest));
        assert!(!state.is_current(&first));
        assert!(!state.reject_read(&first));
        assert!(state.inspect_pending);
        assert!(!state.source_failed);
    }

    #[test]
    fn inspection_for_an_old_mask_leaves_the_latest_evaluation_pending() {
        let mut state = two_documents();
        let old = state.revise_mask();
        let new = state.revise_mask();
        let response = json!({"result": {"data": {}, "sources": {}, "review": {}}});
        assert!(matches!(
            state.apply_evaluation(old, &response).unwrap(),
            Evaluation::Deferred
        ));
        assert!(state.evaluate_pending);
        assert!(state.result.is_none());
        assert!(matches!(
            state.apply_evaluation(new, &response).unwrap(),
            Evaluation::Complete(None)
        ));
        assert!(!state.evaluate_pending);
        assert!(state.result.as_ref().unwrap().json.is_some());
    }
}
