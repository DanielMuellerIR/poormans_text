use super::*;

pub(super) fn test_verified(
    state: &Rc<RefCell<State>>,
    pane: &Pane,
    d: &Descriptor,
    selected: Option<usize>,
) {
    let stage = state.borrow().test_stage;
    if stage == 1 {
        let index = state
            .borrow()
            .verified
            .as_ref()
            .unwrap()
            .positions
            .iter()
            .position(|position| position.snippet.contains("Grüße"))
            .expect("Unicode mapping missing");
        state.borrow_mut().test_stage = 2;
        pane.selector.set_selected(index as u32 + 1);
    } else if stage == 2 {
        static PAUSED: AtomicBool = AtomicBool::new(false);
        if std::env::var_os("PMT_UI_TEST_COMPARISON_PAUSE").is_some()
            && !PAUSED.swap(true, Ordering::AcqRel)
        {
            let state = state.clone();
            let pane = pane.clone();
            let d = d.clone();
            glib::timeout_add_local_once(Duration::from_secs(4), move || {
                test_verified(&state, &pane, &d, selected)
            });
            return;
        }
        let checked = state.borrow().verified.clone().unwrap();
        let position = &checked.positions[selected.unwrap()];
        let (start, end) = pane
            .text
            .buffer()
            .selection_bounds()
            .expect("GTK selection missing");
        assert_eq!(
            pane.text.buffer().text(&start, &end, false).as_str(),
            position.snippet
        );
        assert_eq!(start.offset(), position.start);
        assert_eq!(end.offset(), position.end);
        eprintln!(
            "PMT_UI_TEST_COMPARISON_UTF8 gtk-selection-exact {} {}",
            position.start, position.end
        );
        let original = fs::read(&d.source).unwrap();
        let changed = String::from_utf8(original.clone())
            .unwrap()
            .replace("Grüße", "Ändern");
        assert_eq!(original.len(), changed.len());
        state.borrow_mut().original = Some(original);
        state.borrow_mut().test_stage = 3;
        fs::write(&d.source, changed).unwrap();
    }
}
