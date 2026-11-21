mod actions;
mod dialogs;
mod jobs;
mod options;
mod results;
mod sources;
mod widgets;

pub(crate) use dialogs::{dialog_error, reject_remote, ticket_current};
pub(crate) use jobs::{launch_completed, source_bridge};
pub(crate) use sources::set_sources;
pub(crate) use widgets::{bounded_dropdown, label, row, scroll, text_view};

use crate::{Shared, State, cli_path, clipboard_ui, model::tr, preferences, profiles};
use gtk::{glib, prelude::*};
use pmt_bridge::Bridge;
use std::{cell::RefCell, path::PathBuf, rc::Rc};

#[derive(Clone)]
pub(crate) struct View {
    pub(crate) window: gtk::ApplicationWindow,
    pub(crate) sources: gtk::TextView,
    pub(crate) status: gtk::Label,
    pub(crate) progress: gtk::ProgressBar,
    pub(crate) diagnostics: gtk::TextView,
    pub(crate) details: gtk::TextView,
    pub(crate) rejection: gtk::Label,
    pub(crate) profile_notice: gtk::Label,
    pub(crate) preview: gtk::TextView,
    pub(crate) files: gtk::DropDown,
    pub(crate) open: gtk::Button,
    pub(crate) copy: gtk::Button,
    pub(crate) compare: gtk::Button,
    pub(crate) convert: gtk::Button,
    pub(crate) cancel: gtk::Button,
    pub(crate) source_controls: gtk::FlowBox,
    pub(crate) options: gtk::Notebook,
    pub(crate) controls: options::Controls,
    pub(crate) destination: gtk::Entry,
    pub(crate) result_tabs: gtk::Notebook,
}

pub(crate) fn build(app: &gtk::Application, initial_sources: Vec<PathBuf>) -> (Shared, View) {
    let (window, outer) = build_shell(app);
    let sources = sources::build(&outer);
    let rejection = label("");
    rejection.set_visible(false);
    rejection.connect_label_notify(|label| label.set_visible(!label.label().is_empty()));
    rejection.add_css_class("warning");
    outer.append(&rejection);
    let profile_notice = label("");
    profile_notice.set_visible(false);
    profile_notice.add_css_class("dim-label");
    profile_notice.connect_label_notify(|label| label.set_visible(!label.label().is_empty()));
    outer.append(&profile_notice);
    let preferences_notice = label("");
    preferences_notice.set_visible(false);
    preferences_notice.add_css_class("warning");
    outer.append(&preferences_notice);

    let options = options::build(&outer);
    let actions = actions::build(&outer);
    let results = results::build(&outer);
    let shell = gtk::ScrolledWindow::builder()
        .child(&outer)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .overlay_scrolling(false)
        .build();
    window.set_child(Some(&shell));

    let view = View {
        window,
        sources: sources.list.clone(),
        source_controls: sources.controls.clone(),
        rejection,
        profile_notice,
        options: options.tabs.clone(),
        controls: options.controls.clone(),
        destination: options.destination.clone(),
        status: actions.status,
        progress: actions.progress,
        convert: actions.convert,
        cancel: actions.cancel,
        result_tabs: results.tabs,
        preview: results.preview,
        diagnostics: results.diagnostics,
        details: results.details,
        files: results.files,
        open: results.open,
        copy: results.copy,
        compare: results.compare,
    };
    let state = Rc::new(RefCell::new(State::default()));
    let preferences = preferences::Session::restore(&view, &preferences_notice);
    let bridge = Rc::new(create_bridge());
    clipboard_ui::attach_clipboard(&state, &view);
    profiles::attach(&state, &view, bridge.clone());
    sources.connect(&state, &view, &bridge);
    options.connect(&state, &view);
    actions::connect(&state, &view, &bridge, &sources.catalog, &options);
    results::connect(&state, &view);
    connect_close(&state, &view, preferences);
    actions::install_shortcuts(app, &sources.choose, &view);

    if !initial_sources.is_empty() {
        set_sources(&state, &view, initial_sources);
    }
    view.window.present();
    #[cfg(feature = "ui-self-test")]
    crate::self_test::probe_preferences(&state, &view);
    jobs::launch(&state, &view, bridge.start_catalog(), false);
    #[cfg(feature = "ui-self-test")]
    crate::self_test::start(&state, &view, &bridge);
    (state, view)
}

fn build_shell(app: &gtk::Application) -> (gtk::ApplicationWindow, gtk::Box) {
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("Poor Man’s Text")
        .default_width(1060)
        .default_height(850)
        .build();
    let outer = gtk::Box::new(gtk::Orientation::Vertical, 16);
    outer.set_margin_top(24);
    outer.set_margin_bottom(24);
    outer.set_margin_start(28);
    outer.set_margin_end(28);
    let heading = label("Poor Man’s Text");
    heading.add_css_class("title-1");
    outer.append(&heading);
    outer.append(&label(tr(
        "Dateien in Markdown umwandeln",
        "Convert files to Markdown",
    )));
    (window, outer)
}

fn create_bridge() -> Bridge {
    let bridge = Bridge::new(cli_path());
    if let Some(path) = std::env::var_os("PMT_PROCESS_GUARD") {
        bridge.with_guard(PathBuf::from(path))
    } else {
        bridge
    }
}

fn connect_close(state: &Shared, view: &View, preferences: preferences::Session) {
    let state = state.clone();
    let view = view.clone();
    view.window.clone().connect_close_request(move |_| {
        if state.borrow().is_busy() {
            state.borrow_mut().closing = true;
            jobs::cancel_job(&state, &view);
            return glib::Propagation::Stop;
        }

        preferences.save(&view);
        // Vergleichsfenster sind ebenfalls Application-Fenster und halten sonst
        // nach dem Hauptfenster den Prozess trotz abgeschlossener Jobs offen.
        if let Some(application) = view.window.application() {
            let main = view.window.clone().upcast::<gtk::Window>();
            for child in application.windows() {
                if child != main {
                    child.close();
                }
            }
        }
        let source = state.borrow_mut().clipboard_source.take();
        drop(source);
        #[cfg(feature = "ui-self-test")]
        crate::self_test::window_closed();
        glib::Propagation::Proceed
    });
}
