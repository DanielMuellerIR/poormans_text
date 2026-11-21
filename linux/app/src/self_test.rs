use crate::model::{FlagOption, ValueOption};
use crate::{
    Shared, State, View, clipboard_ui, comparison, launch_completed, model, read_output,
    set_sources,
};
use gtk::{glib, prelude::*};
use pmt_bridge::Bridge;
use serde_json::Value;
use std::{ffi::OsString, path::PathBuf, rc::Rc, sync::Arc, time::Duration};

pub(crate) fn probe_preferences(state: &Shared, view: &View) {
    crate::preferences::probe(state, view);
}

pub(crate) fn start(state: &Shared, view: &View, bridge: &Rc<Bridge>) {
    probe_conversion(state, view);
    probe_bound_source(state, view, bridge);
    probe_clipboard(state, view);
    probe_comparison(state, view);
    probe_raster(state, view);
}

fn probe_conversion(state: &Shared, view: &View) {
    if let Some(input) = std::env::var_os("PMT_UI_TEST_INPUT") {
        let state = state.clone();
        let view = view.clone();
        glib::timeout_add_local(Duration::from_millis(100), move || {
            if state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            if !input.is_empty() {
                set_sources(&state, &view, vec![PathBuf::from(&input)]);
            }
            if let Ok(destination) = std::env::var("PMT_UI_TEST_OUTPUT") {
                view.destination.set_text(&destination);
            }
            view.convert.emit_clicked();
            if let Ok(delay) = std::env::var("PMT_UI_TEST_CANCEL_MS")
                .unwrap_or_default()
                .parse::<u64>()
            {
                let button = view.cancel.clone();
                glib::timeout_add_local_once(Duration::from_millis(delay), move || {
                    button.emit_clicked()
                });
            }
            if let Ok(delay) = std::env::var("PMT_UI_TEST_CLOSE_MS")
                .unwrap_or_default()
                .parse::<u64>()
            {
                let window = view.window.clone();
                glib::timeout_add_local_once(Duration::from_millis(delay), move || window.close());
            }
            glib::ControlFlow::Break
        });
    }
}

fn probe_bound_source(state: &Shared, view: &View, bridge: &Rc<Bridge>) {
    if let Some(path) = std::env::var_os("PMT_UI_TEST_BOUND_SOURCE") {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        let path = PathBuf::from(path);
        let mut started = false;
        glib::timeout_add_local(Duration::from_millis(50), move || {
            if started || state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            started = true;
            let bytes = std::fs::read(&path).unwrap();
            let ext = path.extension().unwrap().to_str().unwrap();
            let input = pmt_bridge::BoundInput::new(
                &bytes,
                pmt_bridge::InputName::new(&format!("clipboard.{ext}")).unwrap(),
            )
            .unwrap();
            let output = path.parent().unwrap().join(format!(
                "bound-compare-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let mut args = vec![
                ValueOption::ImageOcr.cli_flag().into(),
                "off".into(),
                FlagOption::SourceMap.cli_flag().into(),
                "--output".into(),
                output.into_os_string(),
                "--".into(),
                input.path().into_os_string(),
            ];
            if let Some(pandoc) = std::env::var_os("PMT_UI_TEST_BOUND_PANDOC") {
                args.splice(0..0, [ValueOption::Pandoc.cli_flag().into(), pandoc]);
            }
            let job = bridge
                .as_ref()
                .clone()
                .with_input(input.clone())
                .start_conversion(args);
            let next_state = state.clone();
            let next_view = view.clone();
            launch_completed(
                &state,
                &view,
                job,
                true,
                Some(Box::new(move |value| {
                    let mut file = model::outputs(value).remove(0);
                    file.bound_input = Some(input);
                    file.source_origin = model::SourceOrigin::Clipboard;
                    glib::idle_add_local_once(move || {
                        let error_probe = std::env::var_os("PMT_UI_TEST_BOUND_ERROR").is_some();
                        let identity = {
                            use std::os::unix::fs::MetadataExt;
                            let reader = file.bound_input.as_ref().unwrap().reader().unwrap();
                            let m = reader.metadata().unwrap();
                            (m.dev(), m.ino())
                        };
                        if error_probe {
                            let mut value = (**file.context.as_ref().unwrap()).clone();
                            if std::env::var_os("PMT_UI_TEST_BOUND_VERIFY_ERROR").is_some() {
                                value["outputFiles"][0]["sha256"] =
                                    serde_json::json!("0".repeat(64));
                            } else {
                                value["outputFiles"][0]["byteCount"] =
                                    serde_json::json!(16 * 1024 * 1024 + 1);
                            }
                            file.context = Some(Arc::new(read_output::Context::new(value)));
                        }
                        next_state.borrow_mut().files = vec![file.clone()];
                        if std::env::var_os("PMT_UI_TEST_BOUND_RELEASE").is_some() {
                            let state = next_state.clone();
                            let view = next_view.clone();
                            next_state.borrow_mut().test_clear =
                                Some(Box::new(move || set_sources(&state, &view, vec![])));
                        }
                        comparison::open(&next_view.window, file, &next_state);
                        if error_probe {
                            glib::timeout_add_local_once(Duration::from_millis(50), move || {
                                set_sources(&next_state, &next_view, vec![]);
                                let main = next_view.window.clone().upcast::<gtk::Window>();
                                for child in next_view.window.application().unwrap().windows() {
                                    if child != main {
                                        child.close();
                                    }
                                }
                                glib::timeout_add_local_once(
                                    Duration::from_millis(450),
                                    move || {
                                        use std::os::unix::fs::MetadataExt;
                                        assert!(next_view.window.is_visible());
                                        let count = std::fs::read_dir("/proc/self/fd")
                                            .unwrap()
                                            .filter_map(Result::ok)
                                            .filter_map(|e| std::fs::metadata(e.path()).ok())
                                            .filter(|m| (m.dev(), m.ino()) == identity)
                                            .count();
                                        assert_eq!(
                                            count, 0,
                                            "failed comparison retained sealed source"
                                        );
                                        eprintln!(
                                            "PMT_UI_TEST_BOUND_ERROR_RELEASE app-open-source-cleared-fds=0"
                                        );
                                        next_view.window.close();
                                    },
                                );
                            });
                        }
                    });
                })),
            );
            glib::ControlFlow::Break
        });
    }
}

fn probe_clipboard(state: &Shared, view: &View) {
    if let Some(fixtures) = std::env::var_os("PMT_UI_TEST_CLIPBOARD") {
        let state = state.clone();
        let view = view.clone();
        glib::timeout_add_local(Duration::from_millis(50), move || {
            if state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            clipboard_ui::self_test(&state, &view, PathBuf::from(&fixtures));
            glib::ControlFlow::Break
        });
    }
}

fn probe_comparison(state: &Shared, view: &View) {
    if let Some(fixtures) = std::env::var_os("PMT_UI_TEST_COMPARISON") {
        let state = state.clone();
        let view = view.clone();
        let mut started = false;
        glib::timeout_add_local(Duration::from_millis(50), move || {
            if state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            if !started {
                let fixtures = PathBuf::from(&fixtures);
                let source = fixtures.join("Vergleich-e\u{301}.csv");
                std::fs::write(&source, "Name,Text\nZeile,Grüße 👩‍💻 e\u{301}\n").unwrap();
                set_sources(&state, &view, vec![source]);
                view.controls.flag(FlagOption::SourceMap).set_active(true);
                view.destination.set_text(
                    fixtures
                        .join(format!(
                            "comparison-{}",
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap()
                                .as_nanos()
                        ))
                        .to_str()
                        .unwrap(),
                );
                view.convert.emit_clicked();
                started = true;
                return glib::ControlFlow::Continue;
            }
            let file = state
                .borrow()
                .files
                .iter()
                .find(|file| file.preview)
                .cloned()
                .expect("Real CLI result missing");
            comparison::open(&view.window, file, &state);
            glib::ControlFlow::Break
        });
    }
}

fn probe_raster(state: &Shared, view: &View) {
    if let Some(input) = std::env::var_os("PMT_UI_TEST_RASTER") {
        let state = state.clone();
        let view = view.clone();
        let mut started = false;
        glib::timeout_add_local(Duration::from_millis(50), move || {
            if state.borrow().is_busy() {
                return glib::ControlFlow::Continue;
            }
            if !started {
                let input = PathBuf::from(&input);
                let directory = input.parent().unwrap();
                set_sources(&state, &view, vec![input.clone()]);
                view.controls.flag(FlagOption::SourceMap).set_active(true);
                for option in [ValueOption::PdfOcr, ValueOption::ImageOcr] {
                    assert!(view.controls.choice(option).select("off"));
                }
                view.destination.set_text(
                    directory
                        .join(format!(
                            "raster-ui-{}",
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap()
                                .as_nanos()
                        ))
                        .to_str()
                        .unwrap(),
                );
                view.convert.emit_clicked();
                started = true;
                return glib::ControlFlow::Continue;
            }
            let file = state
                .borrow()
                .files
                .iter()
                .find(|file| file.preview)
                .cloned()
                .expect("Real raster conversion result missing");
            comparison::open(&view.window, file, &state);
            glib::ControlFlow::Break
        });
    }
}

pub(crate) fn source_rejected() {
    eprintln!("PMT_UI_TEST_REJECTED_SOURCE busy");
}

pub(crate) fn sources_changed(sources: &[PathBuf]) {
    use std::os::unix::ffi::OsStrExt;
    let paths: Vec<_> = sources
        .iter()
        .map(|path| path.as_os_str().as_bytes())
        .collect();
    eprintln!(
        "PMT_UI_TEST_SOURCES {}",
        serde_json::to_string(&paths).unwrap_or_default()
    );
}

pub(crate) fn conversion_arguments(state: &Shared, args: &[OsString]) {
    state.borrow_mut().test_conversion_args = args.to_vec();
}

pub(crate) fn window_closed() {
    eprintln!("PMT_UI_TEST_CLIPBOARD_CLOSE released-after-job-barrier");
}

pub(crate) fn dialog_failed(error: &glib::Error) {
    eprintln!("PMT_UI_TEST_DIALOG_ERROR {}", error);
}

pub(crate) fn job_started(state: &mut State, conversion: bool) {
    eprintln!("PMT_UI_TEST_JOB_STARTED conversion={conversion}");
    state.test_response = None;
}

pub(crate) fn job_finished(conversion: bool, cancelled: bool) {
    eprintln!("PMT_UI_TEST_OPERATION_FINISHED conversion={conversion} cancelled={cancelled}");
}

pub(crate) fn job_cancelled(closing: bool) {
    eprintln!("PMT_UI_TEST_CANCELLED cleanup-finished closing={closing}");
}

pub(crate) fn job_response(state: &Shared, value: Option<&Value>) {
    state.borrow_mut().test_response = value.cloned();
}

pub(crate) fn conversion_result(value: &Value) {
    eprintln!("PMT_UI_TEST_RESULT {}", value);
}

pub(crate) fn job_error(error: &pmt_bridge::BridgeError) {
    eprintln!("PMT_UI_TEST_ERROR {:?}", error);
}

pub(crate) fn quit_after_job(conversion: bool) -> bool {
    let flag = if conversion {
        "PMT_UI_TEST_QUIT_ON_FINISH"
    } else {
        "PMT_UI_TEST_QUIT_ON_CATALOG"
    };
    std::env::var_os(flag).is_some()
}
