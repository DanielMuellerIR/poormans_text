use super::{
    jobs::{cancel_job, launch, source_bridge},
    options::OptionsSection,
    widgets::label,
};
use crate::{
    Shared, View,
    model::{ValueOption, tr},
};
use gtk::{gio, glib, prelude::*};
use pmt_bridge::Bridge;
use std::{ffi::OsString, rc::Rc};

pub(super) struct Actions {
    pub convert: gtk::Button,
    pub cancel: gtk::Button,
    pub status: gtk::Label,
    pub progress: gtk::ProgressBar,
}

pub(super) fn build(outer: &gtk::Box) -> Actions {
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let convert = gtk::Button::with_label(tr("Umwandeln", "Convert"));
    convert.set_tooltip_text(Some(tr(
        "Konvertiert die ausgewählten Quellen mit den eingestellten Optionen.",
        "Converts the selected sources using the current options.",
    )));
    convert.add_css_class("suggested-action");
    let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
    cancel.set_tooltip_text(Some(tr(
        "Stoppt die laufende Konvertierung. Fertige Ausgaben bleiben erhalten.",
        "Stops the current conversion. Completed outputs are kept.",
    )));
    cancel.set_sensitive(false);
    actions.append(&convert);
    actions.append(&cancel);
    let status = label(tr(
        "Bereit · Quellen bleiben unverändert",
        "Ready · Source documents remain unchanged",
    ));
    status.set_hexpand(true);
    status.set_lines(2);
    status.set_max_width_chars(56);
    status.set_ellipsize(gtk::pango::EllipsizeMode::End);
    actions.append(&status);
    outer.append(&actions);
    let progress = gtk::ProgressBar::new();
    outer.append(&progress);
    Actions {
        convert,
        cancel,
        status,
        progress,
    }
}

pub(super) fn connect(
    state: &Shared,
    view: &View,
    bridge: &Rc<Bridge>,
    catalog: &gtk::Button,
    options: &OptionsSection,
) {
    {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        view.convert.clone().connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            match conversion_arguments(&state, &view) {
                Ok(args) => {
                    #[cfg(feature = "ui-self-test")]
                    crate::self_test::conversion_arguments(&state, &args);
                    launch(
                        &state,
                        &view,
                        source_bridge(&bridge, &state).start_conversion(args),
                        true,
                    );
                }
                Err(error) => view.rejection.set_text(&error),
            }
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        view.cancel
            .clone()
            .connect_clicked(move |_| cancel_job(&state, &view));
    }
    {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let pandoc_entry = options.pandoc_entry.clone();
        catalog.connect_clicked(move |_| {
            if !state.borrow().is_busy() {
                let using_profile = state.borrow().profile.name.is_some();
                let path = if using_profile { glib::GString::from("") } else { pandoc_entry.text() };
                let job = if path.trim().is_empty() {
                    bridge.start_catalog()
                } else {
                    bridge.start_operation(vec![
                        "--formats".into(),
                        ValueOption::Pandoc.cli_flag().into(),
                        OsString::from(path.as_str()),
                    ])
                };
                launch(&state, &view, job, false);
                if using_profile {
                    view.rejection.set_text(tr(
                        "Der Katalog zeigt CLI-Standardwerkzeuge. Lokale Profilziele werden bei der Umwandlung geprüft.",
                        "The catalog shows CLI default tools. Local profile targets are checked when converting.",
                    ));
                }
            }
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let inspect_kind = options.inspect_kind.clone();
        options.inspect.connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            let source = state.borrow().sources.first().cloned();
            if let Some(source) = source {
                let args = vec![
                    OsString::from(
                        ["--list-sheets", "--list-slides", "--list-chapters"]
                            .get(inspect_kind.selected() as usize)
                            .copied()
                            .unwrap_or("--list-sheets"),
                    ),
                    OsString::from("--"),
                    source.into_os_string(),
                ];
                launch(
                    &state,
                    &view,
                    source_bridge(&bridge, &state).start_operation(args),
                    false,
                );
            } else {
                view.status.set_text(tr(
                    "Bitte zuerst eine Quelle wählen.",
                    "Choose a source first.",
                ));
            }
        });
    }
}

pub(super) fn install_shortcuts(app: &gtk::Application, choose: &gtk::Button, view: &View) {
    for (name, action_name, accelerator, button) in [
        ("convert", "app.convert", "<Control>Return", &view.convert),
        ("cancel", "app.cancel", "Escape", &view.cancel),
        ("choose", "app.choose", "<Control>O", choose),
    ] {
        let action = gio::SimpleAction::new(name, None);
        let button = button.clone();
        action.connect_activate(move |_, _| {
            if button.is_sensitive() {
                button.emit_clicked();
            }
        });
        app.add_action(&action);
        app.set_accels_for_action(action_name, &[accelerator]);
    }
}

fn conversion_arguments(state: &Shared, view: &View) -> Result<Vec<OsString>, String> {
    if state.borrow().clipboard_source.is_some() {
        let destination = view.destination.text();
        if destination.trim().is_empty()
            || std::path::Path::new(destination.as_str()).starts_with("/dev/pmt-input")
        {
            return Err(tr(
                "Für die Zwischenablage bitte einen neuen Zielordner für das Ergebnis wählen.",
                "For clipboard content, choose a new target folder for the result.",
            )
            .into());
        }
    }
    let profile = state.borrow().profile.clone();
    let options = if profile.name.is_some() {
        view.controls.execution_options()
    } else {
        view.controls.snapshot()
    };
    let mut args = options.arguments(&state.borrow().sources, Some(&view.destination.text()))?;
    let mut profile_args = profile.conversion_arguments();
    profile_args.append(&mut args);
    Ok(profile_args)
}
