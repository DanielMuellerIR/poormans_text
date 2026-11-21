#[cfg(any(test, feature = "ui-self-test"))]
use crate::model::{FlagOption, ValueOption};
use crate::{
    Shared, View, bounded_dropdown, dialog_error, label, launch_completed, model::tr,
    reject_remote, row, ticket_current,
};
use gtk::{gio, glib, prelude::*};
use pmt_bridge::Bridge;
use serde_json::Value;
use std::{
    cell::{Cell, RefCell},
    ffi::OsString,
    path::PathBuf,
    rc::Rc,
};

#[derive(Clone, Default, Debug)]
pub struct Selection {
    pub name: Option<String>,
    pub directory: Option<PathBuf>,
    pub allow_local: bool,
    pub discard_bound_selection: bool,
}
impl Selection {
    pub fn store_arguments(&self) -> Vec<OsString> {
        self.directory
            .as_ref()
            .map(|path| vec!["--profiles-directory".into(), path.as_os_str().to_owned()])
            .unwrap_or_default()
    }
    pub fn conversion_arguments(&self) -> Vec<OsString> {
        let Some(name) = &self.name else {
            return vec![];
        };
        let mut args = vec!["--profile".into(), name.into()];
        args.extend(self.store_arguments());
        if self.allow_local {
            args.push("--profile-local".into());
        }
        if self.discard_bound_selection {
            args.push("--clear-profile-selection".into());
        }
        args
    }
    fn file_arguments(&self, exporting: bool, path: OsString) -> Result<Vec<OsString>, String> {
        let mut args = self.management(
            if exporting {
                "--export-profile"
            } else {
                "--import-profile"
            },
            path,
        );
        if exporting {
            let Some(name) = &self.name else {
                return Err(tr("Zuerst ein Profil wählen.", "Choose a profile first.").into());
            };
            args.extend(["--profile".into(), name.into()]);
        }
        Ok(args)
    }
    fn management(&self, flag: &str, path: impl Into<OsString>) -> Vec<OsString> {
        let mut args = vec![flag.into(), path.into()];
        args.extend(self.store_arguments());
        if self.allow_local {
            args.push("--profile-local".into());
        }
        args
    }
}
pub(crate) fn scope_label(scope: &str) -> &str {
    match scope {
        "portable" => tr("Übertragbar", "Portable"),
        "documentBound" => tr("An Quelle gebunden", "Document bound"),
        "local" => tr("Lokale Ziele", "Local targets"),
        "localDocumentBound" => tr(
            "Lokale Ziele und Quellenbindung",
            "Local targets and document binding",
        ),
        _ => scope,
    }
}
#[derive(Clone, Debug)]
struct Summary {
    name: String,
    scope: String,
}
fn summaries(value: &Value) -> Vec<Summary> {
    value
        .get("profiles")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            Some(Summary {
                name: entry.get("name")?.as_str()?.into(),
                scope: entry.get("scope")?.as_str()?.into(),
            })
        })
        .collect()
}

pub(crate) fn attach(state: &Shared, view: &View, bridge: Rc<Bridge>) {
    let menu = gtk::MenuButton::builder()
        .label(tr("Profile…", "Profiles…"))
        .build();
    let popup = gtk::Popover::new();
    let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
    content.set_margin_top(14);
    content.set_margin_bottom(14);
    content.set_margin_start(14);
    content.set_margin_end(14);
    let directory = gtk::Entry::builder()
        .placeholder_text(tr(
            "Leer: Standard-Profilordner der CLI",
            "Empty: CLI default profile store",
        ))
        .build();
    row(
        &content,
        tr("Profilordner", "Profile store"),
        tr(
            "Ordner, aus dem die App Profile lädt und in dem sie neue Profile speichert.",
            "Folder where the app loads and saves conversion profiles.",
        ),
        &directory,
    );
    let refresh = gtk::Button::with_label(tr("Vorhandene Profile laden", "Load saved profiles"));
    content.append(&refresh);
    let selector = gtk::DropDown::from_strings(&[tr("Ohne Profil", "No profile")]);
    bounded_dropdown(&selector);
    content.append(&selector);
    let local = gtk::CheckButton::with_label(tr(
        "Lokale Ziele für diese Profilaktion ausdrücklich erlauben",
        "Explicitly allow local targets for this profile action",
    ));
    content.append(&local);
    let discard = gtk::CheckButton::with_label(tr(
        "Gebundene Inhaltsauswahl für diesen Lauf verwerfen",
        "Discard bound content selection for this run",
    ));
    content.append(&discard);
    let help = label(tr(
        "Ein gewähltes Profil bestimmt die Konverteroptionen. Ausgegraute GUI-Werte werden nicht übertragen. Ausführungslimits und ein eigenes Ausgabeziel können zusätzlich gesetzt werden. Der Konverter prüft Quellenbindung und lokale Ziele.",
        "A selected profile supplies conversion options. Dimmed GUI values are not sent. Execution limits and an explicit target can also be set. The converter validates document binding and local targets.",
    ));
    help.set_max_width_chars(64);
    content.append(&help);
    let name = gtk::Entry::builder()
        .placeholder_text(tr("Name für neues Profil", "Name for a new profile"))
        .build();
    row(
        &content,
        tr("Speichern als", "Save as"),
        tr(
            "Name, unter dem die aktuellen Konvertierungsoptionen gespeichert werden.",
            "Name to use when saving the current conversion settings.",
        ),
        &name,
    );
    let bind = gtk::CheckButton::with_label(tr(
        "Inhaltsauswahl an genau eine gewählte Quelle binden",
        "Bind content selection to exactly one selected source",
    ));
    content.append(&bind);
    let actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(3)
        .column_spacing(8)
        .row_spacing(8)
        .build();
    let save = gtk::Button::with_label(tr("Neu speichern", "Save new"));
    let import = gtk::Button::with_label(tr("Importieren…", "Import…"));
    let export = gtk::Button::with_label(tr("Exportieren…", "Export…"));
    for button in [&save, &import, &export] {
        actions.append(button);
    }
    content.append(&actions);
    let scroll = gtk::ScrolledWindow::builder()
        .child(&content)
        .max_content_height(520)
        .propagate_natural_height(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    popup.set_child(Some(&scroll));
    menu.set_popover(Some(&popup));
    view.source_controls.append(&menu);
    let names = Rc::new(RefCell::new(Vec::<Summary>::new()));
    let updating = Rc::new(Cell::new(false));
    {
        let state = state.clone();
        let selector = selector.clone();
        let names = names.clone();
        let local = local.clone();
        let discard = discard.clone();
        directory.connect_changed(move |entry| {
            if state.borrow().is_busy() {
                return;
            }
            state.borrow_mut().profile.directory = if entry.text().is_empty() {
                None
            } else {
                Some(PathBuf::from(entry.text().as_str()))
            };
            names.borrow_mut().clear();
            selector.set_model(Some(&gtk::StringList::new(&[tr(
                "Ohne Profil",
                "No profile",
            )])));
            selector.set_selected(0);
            selector.notify("selected");
            local.set_active(false);
            discard.set_active(false);
        });
    }
    {
        let state = state.clone();
        local.connect_toggled(move |check| {
            state.borrow_mut().profile.allow_local = check.is_active();
        });
    }
    {
        let state = state.clone();
        discard.connect_toggled(move |check| {
            state.borrow_mut().profile.discard_bound_selection = check.is_active();
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        let names = names.clone();
        let updating = updating.clone();
        let local = local.clone();
        let discard = discard.clone();
        selector.connect_selected_notify(move |selector| {
            if updating.get() || state.borrow().is_busy() {
                return;
            }
            let selected = selector
                .selected()
                .checked_sub(1)
                .and_then(|index| names.borrow().get(index as usize).cloned());
            let next = selected.as_ref().map(|entry| entry.name.clone());
            let changed = state.borrow().profile.name != next;
            if changed {
                let mut s = state.borrow_mut();
                s.profile.name = next.clone();
                s.generation += 1;
                drop(s);
                view.destination.set_text("");
                local.set_active(false);
                discard.set_active(false);
            }
            view.controls.set_profile_mode(next.is_some());
            view.destination.set_placeholder_text(Some(if next.is_some(){tr("Leer: Profilziel oder neben der Quelle", "Empty: profile target or beside the source")}else{tr("Leer: neben jeder Quelle; sonst neuer Ausgabeordner", "Empty: beside each source; otherwise a new output folder")}));
            view.profile_notice.set_text(
                &selected
                    .map(|entry| {
                        format!(
                            "{}: {} ({}) · {}",
                            tr("Aktives Profil", "Active profile"),
                            entry.name,
                            entry.scope,
                            tr(
                                "CLI-Profilwerte; Konverteroptionen inaktiv, Ausführung und Ziel explizit",
                                "CLI profile values; conversion options inactive, execution and target explicit"
                            )
                        )
                    })
                    .unwrap_or_default(),
            );
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let names = names.clone();
        let updating = updating.clone();
        let selector = selector.clone();
        let popup = popup.clone();
        refresh.connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            popup.popdown();
            let mut args = vec!["--list-profiles".into()];
            args.extend(state.borrow().profile.store_arguments());
            let names = names.clone();
            let selector = selector.clone();
            let updating = updating.clone();
            let selected = state.borrow().profile.name.clone();
            launch_completed(
                &state,
                &view,
                bridge.start_operation(args),
                false,
                Some(Box::new(move |value| {
                    let profiles = summaries(value);
                    let labels = gtk::StringList::new(&[tr("Ohne Profil", "No profile")]);
                    for entry in &profiles {
                        labels.append(&format!("{} · {}", entry.name, scope_label(&entry.scope)));
                    }
                    let index = selected
                        .and_then(|name| profiles.iter().position(|entry| entry.name == name))
                        .map(|i| i as u32 + 1)
                        .unwrap_or(0);
                    *names.borrow_mut() = profiles;
                    updating.set(true);
                    selector.set_model(Some(&labels));
                    selector.set_selected(index);
                    updating.set(false);
                    selector.notify("selected");
                })),
            );
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let popup = popup.clone();
        let name = name.clone();
        let bind = bind.clone();
        save.connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            let selection = state.borrow().profile.clone();
            let mut args = if selection.name.is_some() {
                selection.conversion_arguments()
            } else {
                view.controls.snapshot().profile_arguments()
            };
            args.extend([
                OsString::from("--save-profile"),
                OsString::from(name.text().as_str()),
            ]);
            if selection.name.is_none() {
                args.extend(selection.store_arguments());
                if selection.allow_local {
                    args.push("--profile-local".into());
                }
            }
            if !view.destination.text().is_empty() {
                args.extend([
                    "--output".into(),
                    OsString::from(view.destination.text().as_str()),
                ]);
            }
            if bind.is_active() {
                let sources = &state.borrow().sources;
                if sources.len() != 1 {
                    view.rejection.set_text(tr(
                        "Für eine Bindung genau eine Quelle wählen.",
                        "Choose exactly one source for a binding.",
                    ));
                    return;
                }
                args.extend(["--profile-source".into(), sources[0].as_os_str().to_owned()]);
            }
            popup.popdown();
            let operation_bridge = if bind.is_active() {
                crate::source_bridge(&bridge, &state)
            } else {
                bridge.as_ref().clone()
            };
            launch_completed(
                &state,
                &view,
                operation_bridge.start_operation(args),
                false,
                None,
            );
        });
    }
    for (button, exporting) in [(import, false), (export, true)] {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let popup = popup.clone();
        button.connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            let selection = state.borrow().profile.clone();
            if exporting && selection.name.is_none() {
                view.rejection
                    .set_text(tr("Zuerst ein Profil wählen.", "Choose a profile first."));
                return;
            }
            popup.popdown();
            let generation = state.borrow().generation;
            let dialog = gtk::FileDialog::builder()
                .title(if exporting {
                    tr(
                        "Profil in neue Datei exportieren",
                        "Export profile to a new file",
                    )
                } else {
                    tr("Profil importieren", "Import profile")
                })
                .build();
            let state = state.clone();
            let view = view.clone();
            let bridge = bridge.clone();
            let parent = view.window.clone();
            let callback = move |result: Result<gio::File, glib::Error>| {
                let file = match result {
                    Ok(file) => file,
                    Err(error) => {
                        dialog_error(&view, &error);
                        return;
                    }
                };
                if !ticket_current(&state, &view, generation) {
                    return;
                }
                let Some(path) = file.path() else {
                    reject_remote(&view);
                    return;
                };
                let args = match selection.file_arguments(exporting, path.into_os_string()) {
                    Ok(args) => args,
                    Err(error) => {
                        view.rejection.set_text(&error);
                        return;
                    }
                };
                launch_completed(&state, &view, bridge.start_operation(args), false, None);
            };
            if exporting {
                dialog.set_initial_name(Some("profile.json"));
                dialog.save(Some(&parent), None::<&gio::Cancellable>, callback);
            } else {
                dialog.open(Some(&parent), None::<&gio::Cancellable>, callback);
            }
        });
    }
    #[cfg(feature = "ui-self-test")]
    if let Some(fixtures) = std::env::var_os("PMT_UI_TEST_PROFILES") {
        let test = TestControls {
            directory,
            refresh,
            selector,
            name,
            save,
            bind,
            local,
            names,
        };
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let mut test = Some(test);
        glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
            if state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            self_test(
                &state,
                &view,
                bridge.clone(),
                PathBuf::from(&fixtures),
                test.take().unwrap(),
            );
            glib::ControlFlow::Break
        });
    }
}
#[cfg(feature = "ui-self-test")]
struct TestControls {
    directory: gtk::Entry,
    refresh: gtk::Button,
    selector: gtk::DropDown,
    name: gtk::Entry,
    save: gtk::Button,
    bind: gtk::CheckButton,
    local: gtk::CheckButton,
    names: Rc<RefCell<Vec<Summary>>>,
}
#[cfg(feature = "ui-self-test")]
mod probe;
#[cfg(feature = "ui-self-test")]
use probe::self_test;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profile_application_has_no_gui_default_overrides() {
        let profile = Selection {
            name: Some("Actual profile".into()),
            directory: Some("/tmp/store".into()),
            ..Default::default()
        };
        assert_eq!(
            profile.conversion_arguments(),
            vec![
                "--profile",
                "Actual profile",
                "--profiles-directory",
                "/tmp/store"
            ]
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
        );
        assert!(
            !profile
                .conversion_arguments()
                .contains(&OsString::from("--source-map"))
        );
    }
    #[test]
    fn local_targets_and_discard_require_explicit_flags() {
        let profile = Selection {
            name: Some("Bound".into()),
            allow_local: true,
            discard_bound_selection: true,
            ..Default::default()
        };
        let args = profile.conversion_arguments();
        assert!(args.contains(&"--profile-local".into()));
        assert!(args.contains(&"--clear-profile-selection".into()));
    }
    #[test]
    fn saved_options_exclude_process_controls() {
        let args = crate::model::Options {
            values: vec![
                (ValueOption::Jobs, "4".into()),
                (ValueOption::Timeout, "120".into()),
                (ValueOption::SpreadsheetFormat, "tsv".into()),
            ],
            flags: vec![FlagOption::Report],
        }
        .profile_arguments();
        assert_eq!(
            args,
            vec!["--spreadsheet-format", "tsv", "--report"]
                .into_iter()
                .map(OsString::from)
                .collect::<Vec<_>>()
        );
    }
}
