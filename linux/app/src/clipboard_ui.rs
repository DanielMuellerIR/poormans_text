use crate::{Shared, View, clipboard, label, model::tr, set_sources};
#[cfg(feature = "ui-self-test")]
use gtk::gio;
use gtk::{glib, prelude::*};
#[cfg(feature = "ui-self-test")]
use std::path::PathBuf;
use std::{cell::RefCell, rc::Rc, sync::Arc, time::Duration};

pub(crate) fn attach_clipboard(state: &Shared, view: &View) {
    let menu = gtk::MenuButton::builder()
        .label(tr("Zwischenablage…", "Clipboard…"))
        .build();
    let popup = gtk::Popover::new();
    let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
    content.set_margin_top(14);
    content.set_margin_bottom(14);
    content.set_margin_start(14);
    content.set_margin_end(14);
    content.append(&label(tr(
        "Angebotene Originalkodierung wählen. Reiner Text wird nicht als Legacyformat ausgegeben.",
        "Choose an offered original encoding. Plain text is not relabelled as a legacy format.",
    )));
    let refresh =
        gtk::Button::with_label(tr("Angebotene Formate anzeigen", "Show offered formats"));
    content.append(&refresh);
    let selector = gtk::DropDown::from_strings(&[tr("Noch nicht gelesen", "Not read yet")]);
    content.append(&selector);
    let note = label("");
    note.set_max_width_chars(64);
    content.append(&note);
    let paste = gtk::Button::with_label(tr("Diese Kodierung übernehmen", "Use this encoding"));
    paste.set_sensitive(false);
    content.append(&paste);
    popup.set_child(Some(&content));
    menu.set_popover(Some(&popup));
    view.source_controls.append(&menu);
    let offers = Rc::new(RefCell::new(Vec::<clipboard::Offer>::new()));
    {
        let offers = offers.clone();
        let selector = selector.clone();
        let note = note.clone();
        let paste = paste.clone();
        let window = view.window.clone();
        refresh.connect_clicked(move |_| {
            let clipboard = window.clipboard();
            let available = clipboard::offers(&clipboard);
            let names = gtk::StringList::new(&[tr(
                "Kodierung ausdrücklich wählen",
                "Choose an encoding explicitly",
            )]);
            for offer in &available {
                names.append(&format!("{} (.{})", offer.mime, offer.extension));
            }
            if available.is_empty() {
                names.append(tr(
                    "Keine unterstützte Originalkodierung",
                    "No supported original encoding",
                ));
            }
            note.set_text(&format!(
                "{}: {}",
                tr("Tatsächlich angeboten", "Actually offered"),
                clipboard
                    .formats()
                    .mime_types()
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
            paste.set_sensitive(false);
            *offers.borrow_mut() = available;
            selector.set_model(Some(&names));
            selector.set_selected(0);
        });
    }
    {
        let paste = paste.clone();
        let offers = offers.clone();
        selector.connect_selected_notify(move |selector| {
            paste.set_sensitive(
                selector.selected() > 0 && (selector.selected() as usize) <= offers.borrow().len(),
            );
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        paste.connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            if selector.selected() == 0 {
                return;
            }
            let Some(offer) = offers
                .borrow()
                .get(selector.selected().saturating_sub(1) as usize)
                .cloned()
            else {
                return;
            };
            popup.popdown();
            begin_clipboard(&state, &view, offer);
        });
    }
}
fn begin_clipboard(state: &Shared, view: &View, offer: clipboard::Offer) {
    if state.borrow().is_busy() {
        return;
    }
    let generation = {
        let mut s = state.borrow_mut();
        s.generation += 1;
        s.cancelled = false;
        s.generation
    };
    view.rejection.set_text("");
    view.files.set_sensitive(false);
    view.open.set_sensitive(false);
    view.copy.set_sensitive(false);
    view.compare.set_sensitive(false);
    view.source_controls.set_sensitive(false);
    view.options.set_sensitive(false);
    view.convert.set_sensitive(false);
    view.cancel.set_sensitive(true);
    view.status.set_text(tr(
        "Zwischenablage wird begrenzt gelesen…",
        "Reading bounded clipboard content…",
    ));
    let next_state = state.clone();
    let next_view = view.clone();
    let clipboard = view.window.clipboard();
    let task = clipboard::read(&clipboard, offer, move |result| {
        let (current, closing) = {
            let mut s = next_state.borrow_mut();
            s.clipboard_read = None;
            (s.generation == generation && !s.cancelled, s.closing)
        };
        next_view.source_controls.set_sensitive(true);
        next_view.options.set_sensitive(true);
        next_view.convert.set_sensitive(true);
        next_view.cancel.set_sensitive(false);
        let selected = next_state
            .borrow()
            .files
            .get(next_view.files.selected() as usize)
            .cloned();
        next_view
            .files
            .set_sensitive(!next_state.borrow().files.is_empty());
        next_view.open.set_sensitive(selected.is_some());
        next_view
            .copy
            .set_sensitive(selected.as_ref().is_some_and(|file| file.preview));
        next_view
            .compare
            .set_sensitive(selected.as_ref().is_some_and(|file| file.preview));
        if current && !closing {
            match result {
                Ok(source) => {
                    let source = Arc::new(source);
                    let rejected_source = next_view.rejection.label().to_string();
                    set_sources(&next_state, &next_view, vec![source.path().to_path_buf()]);
                    next_view.sources.buffer().set_text(&format!(
                        "{} · {}",
                        tr("Zwischenablage", "Clipboard"),
                        source.mime
                    ));
                    next_state.borrow_mut().clipboard_source = Some(source);
                    if !rejected_source.is_empty() {
                        next_view.rejection.set_text(&rejected_source);
                    }
                    next_view.status.set_text(tr(
                        "Zwischenablage bereit · neuen Zielordner wählen",
                        "Clipboard ready · choose a new target folder",
                    ));
                }
                Err(error) => {
                    next_view.status.set_text(tr(
                        "Zwischenablage nicht übernommen",
                        "Clipboard content was not accepted",
                    ));
                    next_view.rejection.set_text(&error);
                }
            }
        } else {
            drop(result);
            next_view.status.set_text(tr(
                "Zwischenablage-Lesen beendet · bereinigt",
                "Clipboard read finished · cleaned up",
            ));
        }
        if closing {
            next_view.window.close();
        }
    });
    state.borrow_mut().clipboard_read = Some(task);
}
pub(crate) fn copy_markdown(state: &Shared, view: &View) {
    let Some(file) = state
        .borrow()
        .files
        .get(view.files.selected() as usize)
        .cloned()
        .filter(|file| file.preview)
    else {
        return;
    };
    let generation = state.borrow().generation;
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = crate::read_output::text(&file, 16 * 1024 * 1024);
        let _ = sender.send(result);
    });
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(Duration::from_millis(20), move || {
        if state.borrow().generation != generation || state.borrow().closing {
            return glib::ControlFlow::Break;
        }
        match receiver.try_recv() {
            Ok(Ok(text)) => {
                view.window.clipboard().set_text(&text);
                view.status.set_text(tr(
                    "Benanntes Markdown kopiert · Assets bleiben im Ausgabeordner",
                    "Named Markdown copied · assets remain in the output folder",
                ));
                glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                view.rejection.set_text(&error);
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}

#[cfg(feature = "ui-self-test")]
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
            for (flag, choice, _) in &view.controls.choices {
                if flag == "--image-ocr" {
                    choice.set_selected(1);
                }
            }
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
