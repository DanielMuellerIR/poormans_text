use super::*;

pub(crate) fn self_test(state: &Shared, view: &View, fixtures: PathBuf) {
    let state = state.clone();
    let view = view.clone();
    let clipboard = view.window.clipboard();
    let next = clipboard.clone();
    clipboard::self_test(&clipboard, &fixtures.clone(), move |result| {
        if let Err(error) = result {
            eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE {}", error);
            view.window.close();
            return;
        }
        let data = std::fs::read(fixtures.join("source.png")).unwrap();
        next.set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
            "image/png",
            &glib::Bytes::from_owned(data),
        )))
        .unwrap();
        begin_clipboard(&state, &view, clipboard::Offer::new("image/png").unwrap());
        let state = state.clone();
        let view = view.clone();
        glib::timeout_add_local(Duration::from_millis(50), move || {
            if state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            let root = state.borrow().clipboard_source.as_ref().map(Arc::downgrade);
            let Some(root) = root else {
                eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE source-not-installed");
                view.window.close();
                return glib::ControlFlow::Break;
            };
            assert!(
                view.controls
                    .choice(crate::model::ValueOption::ImageOcr)
                    .select("off")
            );
            let output = fixtures.join(format!(
                "converted-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            view.destination.set_text(output.to_str().unwrap());
            view.convert.emit_clicked();
            if !state.borrow().is_busy() || root.upgrade().is_none() {
                eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE source-not-held-at-start");
                view.window.close();
                return glib::ControlFlow::Break;
            }
            eprintln!("PMT_UI_TEST_CLIPBOARD_HELD during-real-cli-job");
            if std::env::var_os("PMT_UI_TEST_CLIPBOARD_CLOSE_DURING_JOB").is_some() {
                view.window.close();
                return glib::ControlFlow::Break;
            }
            let state = state.clone();
            let view = view.clone();
            let fixtures = fixtures.clone();
            glib::timeout_add_local(Duration::from_millis(50), move || {
                if state.borrow().is_busy() {
                    return glib::ControlFlow::Continue;
                }
                if root.upgrade().is_none() {
                    eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE source-removed-before-clear");
                    view.window.close();
                    return glib::ControlFlow::Break;
                }
                let selected = state
                    .borrow()
                    .files
                    .iter()
                    .find(|file| file.preview)
                    .cloned();
                let Some(selected) = selected else {
                    eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE conversion-not-successful");
                    view.window.close();
                    return glib::ControlFlow::Break;
                };
                if selected.source_origin != crate::model::SourceOrigin::Clipboard {
                    eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE missing-source-origin");
                    view.window.close();
                    return glib::ControlFlow::Break;
                }
                view.compare.emit_clicked();
                let expected = std::fs::read_to_string(selected.path).unwrap();
                copy_markdown(&state, &view);
                let state = state.clone();
                let view = view.clone();
                let root = root.clone();
                let fixtures = fixtures.clone();
                glib::timeout_add_local(Duration::from_millis(50), move || {
                    let clipboard = view.window.clipboard();
                    if !clipboard.formats().contain_mime_type("text/plain") {
                        return glib::ControlFlow::Continue;
                    }
                    let state = state.clone();
                    let view = view.clone();
                    let expected = expected.clone();
                    let root = root.clone();
                    let fixtures = fixtures.clone();
                    clipboard.read_text_async(None::<&gio::Cancellable>, move |result| {
                        if result.ok().flatten().as_deref() != Some(&expected) {
                            eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE copy-not-complete");
                            view.window.close();
                            return;
                        }
                        eprintln!("PMT_UI_TEST_CLIPBOARD_COPY complete-real-md-exact");
                        glib::timeout_add_local(Duration::from_millis(25), move || {
                            if state.borrow().is_busy() {
                                return glib::ControlFlow::Continue;
                            }
                            set_sources(&state, &view, vec![]);
                            if root.upgrade().is_some() {
                                eprintln!("PMT_UI_TEST_CLIPBOARD_FAILURE clear-did-not-clean");
                                view.window.close();
                                return glib::ControlFlow::Break;
                            }
                            eprintln!("PMT_UI_TEST_CLIPBOARD_UI clear-cleaned-after-real-job");
                            let clipboard = view.window.clipboard();
                            clipboard
                                .set_content(Some(&gtk::gdk::ContentProvider::for_bytes(
                                    "image/png",
                                    &glib::Bytes::from_owned(
                                        std::fs::read(fixtures.join("source.png")).unwrap(),
                                    ),
                                )))
                                .unwrap();
                            begin_clipboard(
                                &state,
                                &view,
                                clipboard::Offer::new("image/png").unwrap(),
                            );
                            let state = state.clone();
                            let view = view.clone();
                            glib::timeout_add_local(Duration::from_millis(50), move || {
                                if state.borrow().is_busy() {
                                    return glib::ControlFlow::Continue;
                                }
                                view.window.close();
                                glib::ControlFlow::Break
                            });
                            glib::ControlFlow::Break
                        });
                    });
                    glib::ControlFlow::Break
                });
                glib::ControlFlow::Break
            });
            glib::ControlFlow::Break
        });
    });
}
