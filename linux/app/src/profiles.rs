use crate::{
    Shared, View, bounded_dropdown, dialog_error, label, launch_completed,
    model::{Options, tr},
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
    row(&content, tr("Profilordner", "Profile store"), &directory);
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
    row(&content, tr("Speichern als", "Save as"), &name);
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
                let options = view.controls.snapshot();
                option_arguments_without_execution(options)
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
            launch_completed(&state, &view, bridge.start_operation(args), false, None);
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
fn option_arguments_without_execution(options: Options) -> Vec<OsString> {
    let mut args = Vec::new();
    for (flag, value) in options.values {
        if !value.trim().is_empty() && !matches!(flag.as_str(), "--jobs" | "--timeout") {
            args.extend([flag.into(), value.into()]);
        }
    }
    args.extend(options.flags.into_iter().map(OsString::from));
    args
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
fn self_test(
    state: &Shared,
    view: &View,
    bridge: Rc<Bridge>,
    fixtures: PathBuf,
    test: TestControls,
) {
    let root = fixtures.join(format!(
        "profile-ui-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let source = root.join("profile.xlsx");
    let original = std::fs::read(fixtures.join("profile.xlsx")).unwrap();
    let changed = std::fs::read(fixtures.join("profile-changed.xlsx")).unwrap();
    std::fs::write(&source, &original).unwrap();
    let store = root.join("store");
    test.directory.set_text(store.to_str().unwrap());
    crate::set_sources(state, view, vec![source.clone()]);
    for (flag, choice, _) in &view.controls.choices {
        if flag == "--spreadsheet-format" {
            choice.set_selected(1);
        }
    }
    for (flag, check) in &view.controls.flags {
        if flag == "--source-map" {
            check.set_active(false);
        }
    }
    for (flag, entry) in &view.controls.values {
        if flag == "--sheets" {
            entry.set_text("1");
        }
        if flag == "--cell-range" {
            entry.set_text("A1:B2");
        }
    }
    test.name.set_text("GUI TSV Bound");
    test.bind.set_active(true);
    test.save.emit_clicked();
    let state = state.clone();
    let view = view.clone();
    let mut step = 1u8;
    glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
        if state.borrow().is_busy() {
            return glib::ControlFlow::Continue;
        }
        let response = state.borrow().test_response.clone().unwrap_or(Value::Null);
        let success = response.get("ok").and_then(Value::as_bool) == Some(true);
        let fail = |message: &str| {
            eprintln!("PMT_UI_TEST_PROFILE_FAILURE {message} {response}");
            view.window.close();
            glib::ControlFlow::Break
        };
        match step {
            1 => {
                if !success {
                    return fail("save-bound-profile");
                }
                eprintln!("PMT_UI_TEST_PROFILE_SAVED bound-tsv-no-source-map");
                for (flag, choice, _) in &view.controls.choices {
                    if flag == "--spreadsheet-format" {
                        choice.set_selected(0);
                    }
                }
                for (flag, check) in &view.controls.flags {
                    if flag == "--source-map" {
                        check.set_active(true);
                    }
                }
                for (flag, entry) in &view.controls.values {
                    if flag == "--cell-range" {
                        entry.set_text("A1:A1");
                    }
                }
                test.bind.set_active(false);
                test.refresh.emit_clicked();
                step = 2;
            }
            2 => {
                if !success {
                    return fail("list-profiles");
                }
                let index = test
                    .names
                    .borrow()
                    .iter()
                    .position(|entry| entry.name == "GUI TSV Bound");
                let Some(index) = index else {
                    return fail("saved-profile-not-listed");
                };
                test.selector.set_selected(index as u32 + 1);
                if state.borrow().profile.name.as_deref() != Some("GUI TSV Bound") {
                    return fail("selection-not-applied");
                }
                view.destination
                    .set_text(root.join("converted").to_str().unwrap());
                view.convert.emit_clicked();
                step = 3;
            }
            3 => {
                if !success {
                    return fail("profile-conversion");
                }
                let Some(path) = response.get("markdownFile").and_then(Value::as_str) else {
                    return fail("profile-markdown-missing");
                };
                let text = std::fs::read_to_string(path).unwrap();
                if !text.contains('\t')
                    || !text.contains("PROFILE_UI_MARKER")
                    || !text.contains("42")
                    || state
                        .borrow()
                        .test_conversion_args
                        .contains(&OsString::from("--source-map"))
                {
                    return fail("gui-default-overrode-profile");
                }
                eprintln!("PMT_UI_TEST_PROFILE_DEFAULTS ignored-table-and-source-map-defaults");
                std::fs::write(&source, &changed).unwrap();
                view.destination
                    .set_text(root.join("forbidden").to_str().unwrap());
                view.convert.emit_clicked();
                step = 4;
            }
            4 => {
                if success || root.join("forbidden").exists() {
                    return fail("binding-mismatch-not-rejected");
                }
                eprintln!("PMT_UI_TEST_PROFILE_BINDING changed-source-rejected");
                std::fs::write(&source, &original).unwrap();
                test.selector.set_selected(0);
                for (flag, entry) in &view.controls.values {
                    if matches!(flag.as_str(), "--sheets" | "--cell-range") {
                        entry.set_text("");
                    }
                }
                view.destination
                    .set_text(root.join("local-future").to_str().unwrap());
                test.name.set_text("GUI Local");
                test.local.set_active(false);
                test.save.emit_clicked();
                step = 5;
            }
            5 => {
                if success
                    || !response
                        .get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_lowercase()
                        .contains("local")
                {
                    return fail("local-permission-not-required");
                }
                eprintln!("PMT_UI_TEST_PROFILE_LOCAL rejected-without-consent");
                test.local.set_active(true);
                test.save.emit_clicked();
                step = 6;
            }
            6 => {
                if !success || root.join("local-future").exists() {
                    return fail("local-profile-save");
                }
                eprintln!("PMT_UI_TEST_PROFILE_LOCAL explicitly-authorized-save-only");
                let selection = Selection {
                    name: Some("GUI TSV Bound".into()),
                    directory: Some(store.clone()),
                    ..Default::default()
                };
                let args = selection
                    .file_arguments(true, root.join("export.json").into_os_string())
                    .unwrap();
                launch_completed(&state, &view, bridge.start_operation(args), false, None);
                step = 7;
            }
            7 => {
                if !success || !root.join("export.json").exists() {
                    return fail("export");
                }
                test.directory
                    .set_text(root.join("import-store").to_str().unwrap());
                let args = state
                    .borrow()
                    .profile
                    .file_arguments(false, root.join("export.json").into_os_string())
                    .unwrap();
                launch_completed(&state, &view, bridge.start_operation(args), false, None);
                step = 8;
            }
            8 => {
                if !success {
                    return fail("import");
                }
                test.refresh.emit_clicked();
                step = 9;
            }
            9 => {
                if !success
                    || test.names.borrow().len() != 1
                    || test.names.borrow()[0].name != "GUI TSV Bound"
                {
                    return fail("imported-profile-list");
                }
                if std::fs::read(&source).unwrap() != original {
                    return fail("source-bytes-changed");
                }
                eprintln!("PMT_UI_TEST_PROFILE_ROUNDTRIP export-import-list-exact-name");
                eprintln!("PMT_UI_TEST_PROFILE_COMPLETE all-positive-and-negative-cases");
                view.window.close();
                return glib::ControlFlow::Break;
            }
            _ => return fail("unknown-step"),
        }
        glib::ControlFlow::Continue
    });
}

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
        let args = option_arguments_without_execution(Options {
            values: vec![
                ("--jobs".into(), "4".into()),
                ("--timeout".into(), "120".into()),
                ("--spreadsheet-format".into(), "tsv".into()),
            ],
            flags: vec!["--report".into()],
        });
        assert_eq!(
            args,
            vec!["--spreadsheet-format", "tsv", "--report"]
                .into_iter()
                .map(OsString::from)
                .collect::<Vec<_>>()
        );
    }
}
