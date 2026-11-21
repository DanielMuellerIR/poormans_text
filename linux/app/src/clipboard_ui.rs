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
mod probe;
#[cfg(feature = "ui-self-test")]
pub(crate) use probe::self_test;
