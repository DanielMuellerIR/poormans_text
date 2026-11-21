use super::*;

pub fn probe(state: &crate::Shared, view: &View) {
    let Ok(mode) = std::env::var("PMT_UI_TEST_PREFERENCES") else {
        return;
    };
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(std::time::Duration::from_millis(300), move || {
        if state.borrow().is_busy() {
            return glib::ControlFlow::Continue;
        }
        assert!(view.window.is_visible());
        match mode.as_str() {
            "write" => {
                view.window.set_default_size(1180, 920);
                view.options.set_current_page(Some(2));
                view.controls
                    .value(ValueOption::OcrLanguage)
                    .set_text("de,en");
                view.controls.flag(FlagOption::Report).set_active(true);
                assert!(view.controls.choice(ValueOption::PdfOcr).select("off"));
                view.destination.set_text("/private/never-persist-target");
                view.controls
                    .value(ValueOption::Pandoc)
                    .set_text("/private/never-persist-tool");
                state.borrow_mut().profile.allow_local = true;
            }
            "read" => {
                assert_eq!(
                    (view.window.default_width(), view.window.default_height()),
                    (1180, 920)
                );
                assert_eq!(view.options.current_page(), Some(2));
                assert_eq!(
                    view.controls.value(ValueOption::OcrLanguage).text(),
                    "de,en"
                );
                assert!(view.controls.flag(FlagOption::Report).is_active());
                assert_eq!(
                    view.controls.choice(ValueOption::PdfOcr).selected(),
                    Some("off")
                );
                assert!(state.borrow().sources.is_empty());
                assert!(view.destination.text().is_empty());
                assert!(view.controls.value(ValueOption::Pandoc).text().is_empty());
                assert!(!state.borrow().profile.allow_local);
                assert!(state.borrow().profile.name.is_none());
            }
            "missing" => {
                fn warned(widget: &gtk::Widget) -> bool {
                    if let Some(label) = widget.downcast_ref::<gtk::Label>()
                        && label.is_visible()
                        && label.label().starts_with(tr(
                            "Einstellungen können nicht vollständig",
                            "Preferences could not be fully",
                        ))
                    {
                        return true;
                    }
                    let mut child = widget.first_child();
                    while let Some(widget) = child {
                        if warned(&widget) {
                            return true;
                        }
                        child = widget.next_sibling();
                    }
                    false
                }
                assert!(warned(view.window.upcast_ref()));
            }
            "unchanged" => {}
            _ => panic!("Unknown private preferences probe"),
        }
        eprintln!("PMT_UI_TEST_PREFERENCES {mode} passed");
        let window = view.window.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(400), move || {
            window.close()
        });
        glib::ControlFlow::Break
    });
}
