use super::*;

pub(super) fn self_test(
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
    assert!(
        view.controls
            .choice(ValueOption::SpreadsheetFormat)
            .select("tsv")
    );
    view.controls.flag(FlagOption::SourceMap).set_active(false);
    view.controls.value(ValueOption::Sheets).set_text("1");
    view.controls
        .value(ValueOption::CellRange)
        .set_text("A1:B2");
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
                assert!(
                    view.controls
                        .choice(ValueOption::SpreadsheetFormat)
                        .select("table")
                );
                view.controls.flag(FlagOption::SourceMap).set_active(true);
                view.controls
                    .value(ValueOption::CellRange)
                    .set_text("A1:A1");
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
                view.controls.value(ValueOption::Sheets).set_text("");
                view.controls.value(ValueOption::CellRange).set_text("");
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
