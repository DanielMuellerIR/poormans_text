mod clipboard;
mod clipboard_ui;
mod comparison;
mod main_window;
mod model;
mod preferences;
mod profiles;
mod read_output;
mod receipt;
#[cfg(feature = "ui-self-test")]
mod self_test;
mod source_canvas;
mod source_raster;

use gtk::{gio, glib, prelude::*};
use main_window::{
    View, bounded_dropdown, dialog_error, label, launch_completed, reject_remote, row, scroll,
    set_sources, source_bridge, text_view, ticket_current,
};
use model::{OutputFile, tr};
use pmt_bridge::JobHandle;
#[cfg(feature = "ui-self-test")]
use serde_json::Value;
#[cfg(feature = "ui-self-test")]
use std::ffi::OsString;
use std::{cell::RefCell, path::PathBuf, rc::Rc, sync::Arc};

type Shared = Rc<RefCell<State>>;
#[derive(Default)]
struct State {
    sources: Vec<PathBuf>,
    generation: u64,
    active: Option<JobHandle>,
    raster_jobs: Vec<(u64, JobHandle)>,
    cancelled: bool,
    closing: bool,
    files: Vec<OutputFile>,
    clipboard_source: Option<Arc<clipboard::Source>>,
    clipboard_read: Option<clipboard::ReadHandle>,
    profile: profiles::Selection,
    #[cfg(feature = "ui-self-test")]
    test_response: Option<Value>,
    #[cfg(feature = "ui-self-test")]
    test_conversion_args: Vec<OsString>,
    #[cfg(feature = "ui-self-test")]
    test_clear: Option<Box<dyn FnOnce()>>,
}
impl State {
    fn is_busy(&self) -> bool {
        self.active.is_some() || self.clipboard_read.is_some() || !self.raster_jobs.is_empty()
    }
}

fn main() -> glib::ExitCode {
    let application = gtk::Application::builder()
        .application_id("org.poormanstext.Linux")
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    let session: Rc<RefCell<Option<(Shared, View)>>> = Rc::new(RefCell::new(None));
    {
        let session = session.clone();
        application.connect_activate(move |app| {
            if let Some((_, view)) = session.borrow().as_ref() {
                view.window.present();
                return;
            }
            let ui = main_window::build(app, vec![]);
            *session.borrow_mut() = Some(ui);
        });
    }
    {
        let session = session.clone();
        application.connect_open(move |app, files, _| {
            let paths = files.iter().filter_map(gio::File::path).collect::<Vec<_>>();
            let rejected = paths.len() != files.len();
            if session.borrow().is_none() {
                let ui = main_window::build(app, paths);
                *session.borrow_mut() = Some(ui);
            } else if let Some((state, view)) = session.borrow().as_ref() {
                set_sources(state, view, paths);
                view.window.present();
            }
            if rejected && let Some((_, view)) = session.borrow().as_ref() {
                reject_remote(view);
            }
        });
    }
    // Vor GApplication absolut machen: Auch relative Namen mit führendem Minus
    // bleiben damit Dateinamen. OsString erhält ungültige UTF8 bis zur CLI-Diagnose.
    let mut arguments = std::env::args_os();
    let mut argv = vec![
        arguments
            .next()
            .unwrap_or_else(|| "poormans-text-app".into()),
    ];
    for (index, path) in arguments.enumerate() {
        if index == 0 && path == "--" {
            continue;
        }
        let path = PathBuf::from(path);
        let absolute = if path.is_absolute() {
            path
        } else {
            match std::env::current_dir() {
                Ok(directory) => directory.join(path),
                Err(error) => {
                    eprintln!(
                        "{}: {}",
                        tr(
                            "Das Startverzeichnis ist nicht lesbar",
                            "The working directory cannot be read"
                        ),
                        error
                    );
                    return glib::ExitCode::FAILURE;
                }
            }
        };
        argv.push(absolute.into_os_string());
    }
    application.run_with_args_os(&argv)
}

fn cli_path() -> PathBuf {
    if let Some(p) = std::env::var_os("PMT_CLI") {
        return p.into();
    }
    std::env::current_exe()
        .ok()
        .map(|p| p.with_file_name("poormans-text"))
        .unwrap_or_else(|| PathBuf::from("/nonexistent/poormans-text"))
}
