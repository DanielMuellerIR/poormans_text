use super::results::{render_response, show_files};
use crate::{Shared, View, model::tr};
use gtk::{glib, prelude::*};
use pmt_bridge::{Bridge, ErrorKind, Event, Job};
use serde_json::Value;
use std::time::Duration;

pub(super) fn cancel_job(state: &Shared, view: &View) {
    let (job, clipboard, rasters) = {
        let mut s = state.borrow_mut();
        if !s.is_busy() {
            return;
        }
        s.cancelled = true;
        s.generation += 1;
        (
            s.active.clone(),
            s.clipboard_read.clone(),
            s.raster_jobs
                .iter()
                .map(|(_, handle)| handle.clone())
                .collect::<Vec<_>>(),
        )
    };
    for handle in rasters {
        handle.cancel();
    }
    if let Some(job) = job {
        job.cancel();
    }
    if let Some(clipboard) = clipboard {
        clipboard.cancel();
    }
    view.status.set_text(tr(
        "Abbruch angefordert · warte auf Bereinigung…",
        "Cancellation requested · waiting for cleanup…",
    ));
    view.cancel.set_sensitive(false);
}

type SuccessHook = Option<Box<dyn FnOnce(&Value)>>;
pub(super) fn launch(state: &Shared, view: &View, job: Job, conversion: bool) {
    launch_completed(state, view, job, conversion, None);
}
pub(crate) fn launch_completed(
    state: &Shared,
    view: &View,
    job: Job,
    conversion: bool,
    mut completed: SuccessHook,
) {
    view.rejection.set_text("");
    {
        let mut s = state.borrow_mut();
        s.generation += 1;
        s.cancelled = false;
        s.active = Some(job.handle);
        #[cfg(feature = "ui-self-test")]
        crate::self_test::job_started(&mut s, conversion);
    }
    if conversion {
        state.borrow_mut().files.clear();
        view.files.set_sensitive(false);
        view.files.set_model(Some(&gtk::StringList::new(&[tr(
            "Noch kein Ergebnis",
            "No result yet",
        )])));
        view.preview.buffer().set_text("");
        view.open.set_sensitive(false);
        view.copy.set_sensitive(false);
        view.compare.set_sensitive(false);
    }
    view.convert.set_sensitive(false);
    view.cancel.set_sensitive(true);
    view.source_controls.set_sensitive(false);
    view.options.set_sensitive(false);
    view.status.set_text(tr("Läuft…", "Running…"));
    view.diagnostics.buffer().set_text("");
    view.details.buffer().set_text("");
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(Duration::from_millis(75), move || {
        view.progress.pulse();
        loop {
            let event = match job.events.try_recv() {
                Ok(event) => event,
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    let closing = {
                        let mut s = state.borrow_mut();
                        s.active = None;
                        s.closing
                    };
                    view.convert.set_sensitive(true);
                    view.cancel.set_sensitive(false);
                    view.source_controls.set_sensitive(true);
                    view.options.set_sensitive(true);
                    view.progress.set_fraction(0.0);
                    view.status.set_text(tr(
                        "Prozessverbindung beendet · kein Erfolg bestätigt",
                        "Process connection ended · no success confirmed",
                    ));
                    #[cfg(feature = "ui-self-test")]
                    let closing = closing || crate::self_test::quit_after_job(conversion);
                    if closing {
                        view.window.close();
                    }
                    return glib::ControlFlow::Break;
                }
            };
            match event {
                Event::ProgressText(text) => {
                    if !state.borrow().cancelled {
                        view.status.set_text(
                            &text
                                .lines()
                                .last()
                                .unwrap_or("")
                                .chars()
                                .take(160)
                                .collect::<String>(),
                        );
                    }
                    let buffer = view.diagnostics.buffer();
                    let mut end = buffer.end_iter();
                    if buffer.char_count() < 1_000_000 {
                        buffer.insert(&mut end, &(text + "\n"));
                    }
                }
                Event::Finished(result) => {
                    let (cancelled, closing) = {
                        let mut s = state.borrow_mut();
                        s.active = None;
                        (s.cancelled, s.closing)
                    };
                    #[cfg(feature = "ui-self-test")]
                    crate::self_test::job_finished(conversion, cancelled);
                    view.convert.set_sensitive(true);
                    view.cancel.set_sensitive(false);
                    view.source_controls.set_sensitive(true);
                    view.options.set_sensitive(true);
                    view.progress.set_fraction(0.0);
                    if cancelled {
                        #[cfg(feature = "ui-self-test")]
                        crate::self_test::job_cancelled(closing);
                        view.status.set_text(tr(
                            "Abbruch beendet · fertige Ausgaben können bestehen",
                            "Cancellation finished · completed outputs may remain",
                        ));
                        let details = match &result {
                            Ok(value) => value.clone(),
                            Err(error) => {
                                serde_json::json!({"message":error.message,"stderr":error.stderr,"response":error.response})
                            }
                        };
                        render_response(&view, &details);
                    } else {
                        match result {
                            Ok(value) => {
                                #[cfg(feature = "ui-self-test")]
                                crate::self_test::job_response(&state, Some(&value));
                                if let Some(completed) = completed.take() {
                                    completed(&value);
                                }
                                render_response(&view, &value);
                                if conversion {
                                    #[cfg(feature = "ui-self-test")]
                                    crate::self_test::conversion_result(&value);
                                    show_files(&state, &view, &value);
                                    view.result_tabs.set_current_page(Some(0));
                                    let ok = value.get("ok").and_then(Value::as_bool) == Some(true);
                                    view.status.set_text(if ok {
                                        tr("Abgeschlossen", "Completed")
                                    } else {
                                        tr(
                                            "Fehler · Diagnosen prüfen",
                                            "Failed · review diagnostics",
                                        )
                                    });
                                } else {
                                    view.result_tabs.set_current_page(Some(1));
                                    view.status.set_text(tr(
                                        "Informationen unter Diagnosen / Katalog",
                                        "Information in Diagnostics / catalog",
                                    ));
                                }
                            }
                            Err(error) => {
                                #[cfg(feature = "ui-self-test")]
                                crate::self_test::job_response(&state, error.response.as_ref());
                                view.result_tabs.set_current_page(Some(1));
                                #[cfg(feature = "ui-self-test")]
                                crate::self_test::job_error(&error);
                                view.status
                                    .set_text(if error.kind == ErrorKind::InvalidCli {
                                        tr(
                                            "Lokale CLI nicht verfügbar · Diagnosen prüfen",
                                            "Local CLI unavailable · review diagnostics",
                                        )
                                    } else {
                                        tr(
                                            "Fehler · Diagnosen prüfen",
                                            "Failed · review diagnostics",
                                        )
                                    });
                                if conversion && let Some(response) = &error.response {
                                    show_files(&state, &view, response);
                                }
                                let details = serde_json::json!({"message":error.message,"exitCode":error.exit_code,"signal":error.signal,"stderr":error.stderr,"response":error.response});
                                render_response(&view, &details);
                            }
                        }
                    }
                    #[cfg(feature = "ui-self-test")]
                    let closing = closing || crate::self_test::quit_after_job(conversion);
                    if closing {
                        view.window.close();
                    }
                    return glib::ControlFlow::Break;
                }
            }
        }
        glib::ControlFlow::Continue
    });
}

pub(crate) fn source_bridge(bridge: &Bridge, state: &Shared) -> Bridge {
    if let Some(source) = &state.borrow().clipboard_source {
        bridge.clone().with_input(source.binding.clone())
    } else {
        bridge.clone()
    }
}
