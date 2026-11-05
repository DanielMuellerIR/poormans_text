mod clipboard;
mod clipboard_ui;
mod comparison;
mod model;
mod profiles;
mod read_output;
mod source_raster;
mod source_canvas;
use gtk::{gio, glib, prelude::*};
use model::{Options, OutputFile, tr};
use pmt_bridge::{Bridge, ErrorKind, Event, Job, JobHandle};
use serde_json::Value;
use std::{cell::RefCell, ffi::OsString, path::PathBuf, rc::Rc, sync::Arc, time::Duration};

type Shared = Rc<RefCell<State>>;
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
#[derive(Clone)]
struct Controls {
    values: Vec<(String, gtk::Entry)>,
    choices: Vec<(String, gtk::DropDown, Vec<String>)>,
    flags: Vec<(String, gtk::CheckButton)>,
}
impl Controls {
    fn set_profile_mode(&self, active: bool) {
        for (flag, widget) in &self.values {
            widget.set_sensitive(!active || matches!(flag.as_str(), "--jobs" | "--timeout"));
        }
        for (_, widget, _) in &self.choices {
            widget.set_sensitive(!active);
        }
        for (_, widget) in &self.flags {
            widget.set_sensitive(!active);
        }
    }
    fn execution_options(&self) -> Options {
        Options {
            values: self
                .values
                .iter()
                .filter(|(flag, _)| matches!(flag.as_str(), "--jobs" | "--timeout"))
                .map(|(flag, entry)| (flag.clone(), entry.text().to_string()))
                .collect(),
            flags: vec![],
        }
    }
    fn snapshot(&self) -> Options {
        let mut values: Vec<(String, String)> = self
            .values
            .iter()
            .map(|(flag, w)| (flag.clone(), w.text().to_string()))
            .collect();
        // Unveränderte CLI-Defaults weglassen: --notes on setzt sonst bereits eine
        // Präsentationsauswahl und würde zum Beispiel CSV-Eingaben zurückweisen.
        values.extend(self.choices.iter().filter_map(|(flag, w, ids)| {
            if w.selected() == 0 {
                None
            } else {
                ids.get(w.selected() as usize)
                    .map(|v| (flag.clone(), v.clone()))
            }
        }));
        Options {
            values,
            flags: self
                .flags
                .iter()
                .filter(|(_, w)| w.is_active())
                .map(|(flag, _)| flag.clone())
                .collect(),
        }
    }
}
#[derive(Clone)]
struct View {
    window: gtk::ApplicationWindow,
    sources: gtk::TextView,
    status: gtk::Label,
    progress: gtk::ProgressBar,
    diagnostics: gtk::TextView,
    details: gtk::TextView,
    rejection: gtk::Label,
    profile_notice: gtk::Label,
    preview: gtk::TextView,
    files: gtk::DropDown,
    open: gtk::Button,
    copy: gtk::Button,
    compare: gtk::Button,
    convert: gtk::Button,
    cancel: gtk::Button,
    source_controls: gtk::FlowBox,
    options: gtk::Notebook,
    controls: Controls,
    destination: gtk::Entry,
    result_tabs: gtk::Notebook,
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
            let ui = build(app, vec![]);
            *session.borrow_mut() = Some(ui);
        });
    }
    {
        let session = session.clone();
        application.connect_open(move |app, files, _| {
            let paths = files.iter().filter_map(gio::File::path).collect::<Vec<_>>();
            let rejected = paths.len() != files.len();
            if session.borrow().is_none() {
                let ui = build(app, paths);
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

fn label(text: &str) -> gtk::Label {
    gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .build()
}
fn text_view() -> gtk::TextView {
    gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .left_margin(12)
        .right_margin(12)
        .top_margin(10)
        .bottom_margin(10)
        .build()
}
fn scroll(child: &impl IsA<gtk::Widget>, min: i32) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .child(child)
        .min_content_height(min)
        .hexpand(true)
        .vexpand(true)
        .build()
}
fn page(notebook: &gtk::Notebook, title: &str) -> gtk::Box {
    let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
    content.set_margin_top(14);
    content.set_margin_bottom(14);
    content.set_margin_start(14);
    content.set_margin_end(14);
    let scrolled = gtk::ScrolledWindow::builder()
        .child(&content)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Always)
        .overlay_scrolling(false)
        .min_content_height(210)
        .build();
    notebook.append_page(&scrolled, Some(&gtk::Label::new(Some(title))));
    content
}
fn row(parent: &gtk::Box, title: &str, child: &impl IsA<gtk::Widget>) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let l = label(title);
    l.set_width_chars(22);
    row.append(&l);
    child.set_hexpand(true);
    child.set_tooltip_text(Some(title));
    l.set_mnemonic_widget(Some(child));
    row.append(child);
    parent.append(&row);
}
fn entry(
    parent: &gtk::Box,
    title: &str,
    placeholder: &str,
    flag: &str,
    c: &mut Controls,
) -> gtk::Entry {
    let w = gtk::Entry::builder().placeholder_text(placeholder).build();
    row(parent, title, &w);
    c.values.push((flag.into(), w.clone()));
    w
}
fn choice(parent: &gtk::Box, title: &str, flag: &str, items: &[(&str, &str)], c: &mut Controls) {
    let labels = items.iter().map(|(_, text)| *text).collect::<Vec<_>>();
    let w = gtk::DropDown::from_strings(&labels);
    row(parent, title, &w);
    c.choices.push((
        flag.into(),
        w,
        items.iter().map(|(id, _)| (*id).into()).collect(),
    ));
}
fn check(parent: &gtk::Box, title: &str, flag: &str, default: bool, c: &mut Controls) {
    let w = gtk::CheckButton::with_label(title);
    w.set_active(default);
    parent.append(&w);
    c.flags.push((flag.into(), w));
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
fn build(app: &gtk::Application, initial_sources: Vec<PathBuf>) -> (Shared, View) {
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
        "Dokumente, Tabellen, Präsentationen und Sammlungen in Markdown umwandeln",
        "Convert documents, spreadsheets, presentations and collections to Markdown",
    )));
    let source_controls = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(6)
        .column_spacing(8)
        .row_spacing(8)
        .build();
    let choose = gtk::Button::with_label(tr("Dateien wählen…", "Choose files…"));
    let folder = gtk::Button::with_label(tr("Ordner wählen…", "Choose folder…"));
    let clear = gtk::Button::with_label(tr("Leeren", "Clear"));
    let catalog = gtk::Button::with_label(tr("Formate und Werkzeuge", "Formats and tools"));
    for b in [&choose, &folder, &clear, &catalog] {
        source_controls.append(b);
    }
    outer.append(&source_controls);
    let sources = text_view();
    sources.buffer().set_text(tr(
        "Dateien oder Ordner hier ablegen…",
        "Drop files or folders here…",
    ));
    sources.set_tooltip_text(Some(tr(
        "Dateien oder Ordner hier ablegen. Quellen bleiben unverändert.",
        "Drop files or folders here. Source documents remain unchanged.",
    )));
    outer.append(&scroll(&sources, 75));
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
    let options = gtk::Notebook::new();
    let mut controls = Controls {
        values: vec![],
        choices: vec![],
        flags: vec![],
    };
    let output = page(&options, tr("Ausgabe", "Output"));
    let destination = gtk::Entry::builder()
        .placeholder_text(tr(
            "Leer: neben jeder Quelle; sonst neuer Ausgabeordner",
            "Empty: beside each source; otherwise a new output folder",
        ))
        .build();
    let destrow = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    destination.set_hexpand(true);
    destrow.append(&destination);
    let destchoose = gtk::Button::with_label(tr("Ziel wählen…", "Choose target…"));
    destrow.append(&destchoose);
    output.append(&destrow);
    output.append(&label(tr("Vorhandene Ergebnisordner werden niemals überschrieben. Bei mehreren Quellen dient das Ziel als neuer Sammelordner.","Existing result folders are never overwritten. For multiple sources the target is a new parent folder.")));
    choice(
        &output,
        tr("Tabellen", "Tables"),
        "--spreadsheet-format",
        &[("table", "Markdown"), ("tsv", "TSV")],
        &mut controls,
    );
    let output_flags = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(4)
        .column_spacing(16)
        .row_spacing(8)
        .build();
    output.append(&output_flags);
    for (name, flag, default) in [
        (
            tr("YAML-Metadaten", "YAML frontmatter"),
            "--frontmatter",
            false,
        ),
        ("TextBundle", "--textbundle", false),
        (
            tr("Konvertierungsbericht", "Conversion report"),
            "--report",
            false,
        ),
        (tr("Quellzuordnung", "Source mapping"), "--source-map", true),
    ] {
        let checkbox = gtk::CheckButton::with_label(name);
        checkbox.set_active(default);
        output_flags.append(&checkbox);
        controls.flags.push((flag.into(), checkbox));
    }
    let ocr = page(&options, "OCR / PDF");
    choice(
        &ocr,
        tr("Bild-OCR", "Image OCR"),
        "--image-ocr",
        &[("on", tr("Ein", "On")), ("off", tr("Aus", "Off"))],
        &mut controls,
    );
    choice(
        &ocr,
        "PDF OCR",
        "--pdf-ocr",
        &[
            ("auto", tr("Automatisch", "Automatic")),
            ("off", tr("Aus", "Off")),
            ("always", tr("Immer", "Always")),
        ],
        &mut controls,
    );
    choice(
        &ocr,
        tr("OCR-Methode", "OCR method"),
        "--ocr-method",
        &[("standard", tr("Standard (lokal)", "Standard (local)"))],
        &mut controls,
    );
    ocr.append(&label(tr("Strukturierte OCR ist in diesem Linux-Backend nicht verfügbar. Sprachdaten werden nicht automatisch geladen.","Structured OCR is unavailable in this Linux backend. Language data is never downloaded automatically.")));
    entry(
        &ocr,
        tr("OCR-Sprachen", "OCR languages"),
        "de,en",
        "--ocr-language",
        &mut controls,
    );
    entry(
        &ocr,
        tr("PDF-Seiten", "PDF pages"),
        "1,3-5",
        "--pdf-pages",
        &mut controls,
    );
    choice(
        &ocr,
        tr("PDF-Layout", "PDF layout"),
        "--pdf-layout",
        &[
            ("auto", tr("Automatisch", "Automatic")),
            ("legacy", tr("Vorheriges Verfahren", "Legacy extraction")),
        ],
        &mut controls,
    );
    check(
        &ocr,
        tr(
            "PDF-Kopf-/Fußzeilen entfernen",
            "Remove PDF headers/footers",
        ),
        "--pdf-remove-headers-footers",
        false,
        &mut controls,
    );
    check(
        &ocr,
        tr(
            "PDF-Silbentrennung aufheben",
            "Join PDF line breaks in words",
        ),
        "--pdf-dehyphenate",
        false,
        &mut controls,
    );
    let selection = page(&options, tr("Inhaltsauswahl", "Content selection"));
    entry(
        &selection,
        tr("EPUB-Kapitel", "EPUB chapters"),
        "1,3-5",
        "--epub-chapters",
        &mut controls,
    );
    entry(
        &selection,
        tr("Tabellenblätter", "Sheets"),
        "all / visible / 1,3-5",
        "--sheets",
        &mut controls,
    );
    entry(
        &selection,
        tr("Zellbereich", "Cell range"),
        "A1:D20",
        "--cell-range",
        &mut controls,
    );
    entry(
        &selection,
        tr("Folien", "Slides"),
        "1,3-5",
        "--slides",
        &mut controls,
    );
    choice(
        &selection,
        tr("DOCX-Änderungen", "DOCX changes"),
        "--docx-changes",
        &[
            ("accept", tr("Annehmen", "Accept")),
            ("reject", tr("Ablehnen", "Reject")),
            ("mark", tr("Markieren", "Mark")),
        ],
        &mut controls,
    );
    choice(
        &selection,
        tr("Sprechernotizen", "Speaker notes"),
        "--notes",
        &[("on", tr("Ein", "On")), ("off", tr("Aus", "Off"))],
        &mut controls,
    );
    let inspectrow = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let inspectkind = gtk::DropDown::from_strings(&[
        tr("Blätter", "Sheets"),
        tr("Folien", "Slides"),
        tr("Kapitel", "Chapters"),
    ]);
    let inspect = gtk::Button::with_label(tr("Erste Quelle untersuchen", "Inspect first source"));
    inspectrow.append(&inspectkind);
    inspectrow.append(&inspect);
    selection.append(&inspectrow);
    let advanced = page(&options, tr("Ausführung", "Execution"));
    entry(
        &advanced,
        tr("Parallele Dokumente", "Parallel documents"),
        "1…4 (default 1)",
        "--jobs",
        &mut controls,
    );
    entry(
        &advanced,
        tr("Werkzeugzeitlimit (s)", "Tool timeout (s)"),
        "120",
        "--timeout",
        &mut controls,
    );
    let pandoc_entry = entry(
        &advanced,
        tr("Pandoc-Pfad", "Pandoc path"),
        "/usr/bin/pandoc",
        "--pandoc",
        &mut controls,
    );
    advanced.append(&label(tr("Profile werden über die CLI im Profilmenü verwaltet. Einstellungen werden derzeit nicht automatisch gespeichert.","Profiles are managed through the CLI in the Profiles menu. Preferences are not saved automatically.")));
    outer.append(&options);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let convert = gtk::Button::with_label(tr("Umwandeln", "Convert"));
    convert.add_css_class("suggested-action");
    let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
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
    let result_tabs = gtk::Notebook::new();
    result_tabs.set_vexpand(true);
    let preview = text_view();
    let diagnostics = text_view();
    result_tabs.append_page(
        &scroll(&preview, 130),
        Some(&gtk::Label::new(Some(tr(
            "Markdown-Vorschau",
            "Markdown preview",
        )))),
    );
    let diagnostic_page = gtk::Box::new(gtk::Orientation::Vertical, 8);
    diagnostic_page.append(&scroll(&diagnostics, 100));
    let details = text_view();
    let details_expander = gtk::Expander::builder()
        .label(tr("Technische Details (JSON)", "Technical details (JSON)"))
        .build();
    details_expander.set_child(Some(&scroll(&details, 100)));
    diagnostic_page.append(&details_expander);
    result_tabs.append_page(
        &diagnostic_page,
        Some(&gtk::Label::new(Some(tr(
            "Diagnosen / Katalog",
            "Diagnostics / catalog",
        )))),
    );
    outer.append(&result_tabs);
    let result_actions = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(false)
        .min_children_per_line(1)
        .max_children_per_line(3)
        .column_spacing(8)
        .row_spacing(8)
        .build();
    let files = gtk::DropDown::from_strings(&[tr("Noch kein Ergebnis", "No result yet")]);
    files.set_sensitive(false);
    files.set_enable_search(true);
    bounded_dropdown(&files);
    files.set_hexpand(true);
    let open = gtk::Button::with_label(tr("In Standard-App öffnen", "Open in default app"));
    open.set_sensitive(false);
    result_actions.append(&files);
    result_actions.append(&open);
    let copy = gtk::Button::with_label(tr(
        "Vollständiges Markdown kopieren",
        "Copy complete Markdown",
    ));
    copy.set_sensitive(false);
    result_actions.append(&copy);
    let compare = gtk::Button::with_label(tr("Quellvergleich…", "Compare source…"));
    compare.set_sensitive(false);
    result_actions.append(&compare);
    outer.append(&result_actions);
    let shell = gtk::ScrolledWindow::builder()
        .child(&outer)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .overlay_scrolling(false)
        .build();
    window.set_child(Some(&shell));
    let view = View {
        window: window.clone(),
        sources,
        status,
        progress,
        diagnostics,
        details,
        rejection,
        profile_notice,
        preview,
        files,
        open,
        copy,
        compare,
        convert,
        cancel,
        source_controls,
        options,
        controls: controls.clone(),
        destination,
        result_tabs,
    };
    let state = Rc::new(RefCell::new(State {
        sources: vec![],
        generation: 0,
        active: None,
        raster_jobs: vec![],
        cancelled: false,
        closing: false,
        files: vec![],
        clipboard_source: None,
        clipboard_read: None,
        profile: profiles::Selection::default(),
        #[cfg(feature = "ui-self-test")]
        test_response: None,
        #[cfg(feature = "ui-self-test")]
        test_conversion_args: vec![],
        #[cfg(feature = "ui-self-test")]
        test_clear: None,
    }));
    let bridge = Bridge::new(cli_path());
    let bridge = Rc::new(if let Some(path) = std::env::var_os("PMT_PROCESS_GUARD") {
        bridge.with_guard(PathBuf::from(path))
    } else {
        bridge
    });
    clipboard_ui::attach_clipboard(&state, &view);
    profiles::attach(&state, &view, bridge.clone());
    {
        let state = state.clone();
        let view = view.clone();
        view.copy
            .clone()
            .connect_clicked(move |_| clipboard_ui::copy_markdown(&state, &view));
    }

    {
        let state = state.clone();
        let view = view.clone();
        view.compare.clone().connect_clicked(move |_| {
            if state.borrow().is_busy(){view.rejection.set_text(tr("Bitte den laufenden Auftrag beenden, bevor ein weiterer Vergleich geöffnet wird.","Finish the active job before opening another comparison."));return;}
            let selected = state
                .borrow()
                .files
                .get(view.files.selected() as usize)
                .cloned()
                .filter(|file| file.preview);
            if let Some(file) = selected {
                comparison::open(&view.window, file, &state);
            }
        });
    }
    for (button, is_folder) in [(choose.clone(), false), (folder, true)] {
        let state = state.clone();
        let view = view.clone();
        button.connect_clicked(move |_| choose_sources(&state, &view, is_folder));
    }
    {
        let state = state.clone();
        let view = view.clone();
        clear.connect_clicked(move |_| set_sources(&state, &view, vec![]));
    }
    {
        let state = state.clone();
        let view = view.clone();
        destchoose.connect_clicked(move |_| {
            let generation=state.borrow().generation;
            let dialog = gtk::FileDialog::builder()
                .title(tr(
                    "Neuen Ausgabeordner benennen",
                    "Name a new output folder",
                ))
                .initial_name("Markdown-output")
                .build();
            let state = state.clone();
            let view = view.clone();
            dialog.save(
                Some(&view.window.clone()),
                None::<&gio::Cancellable>,
                move |result| {
                    if let Err(ref error)=result {dialog_error(&view,error);return;}
                    if !ticket_current(&state,&view,generation){return;}
                    if let Ok(file)=result {
                        if let Some(path)=file.path() {
                            if let Some(text)=path.to_str(){view.destination.set_text(text);}
                            else {view.rejection.set_text(tr("Der Zielname ist kein gültiges UTF-8. Bitte einen anderen Namen wählen.","The target name is not valid UTF-8. Choose another name."));}
                        }else{reject_remote(&view);}
                    }
                },
            );
        });
    }
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
                    {
                        state.borrow_mut().test_conversion_args = args.clone();
                    }
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
        catalog.connect_clicked(move |_| {
            if !state.borrow().is_busy() {
                let using_profile=state.borrow().profile.name.is_some();
                let path=if using_profile{glib::GString::from("")}else{pandoc_entry.text()};
                let job = if path.trim().is_empty() {
                    bridge.start_catalog()
                } else {
                    bridge.start_operation(vec![
                        "--formats".into(),
                        "--pandoc".into(),
                        OsString::from(path.as_str()),
                    ])
                };
                launch(&state, &view, job, false);
                if using_profile{view.rejection.set_text(tr("Der Katalog zeigt CLI-Standardwerkzeuge. Lokale Profilziele werden bei der Umwandlung geprüft.","The catalog shows CLI default tools. Local profile targets are checked when converting."));}
            }
        });
    }
    {
        let state = state.clone();
        let view = view.clone();
        let bridge = bridge.clone();
        inspect.connect_clicked(move |_| {
            if state.borrow().is_busy() {
                return;
            }
            let source = state.borrow().sources.first().cloned();
            if let Some(source) = source {
                let args = vec![
                    OsString::from(
                        ["--list-sheets", "--list-slides", "--list-chapters"]
                            .get(inspectkind.selected() as usize)
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
    {
        let state = state.clone();
        let view = view.clone();
        view.files.clone().connect_selected_notify(move |combo| {
        state.borrow_mut().generation+=1;
        let selected=state.borrow().files.get(combo.selected() as usize).cloned();view.open.set_sensitive(selected.is_some());view.copy.set_sensitive(selected.as_ref().is_some_and(|file|file.preview));view.compare.set_sensitive(selected.as_ref().is_some_and(|file|file.preview));view.preview.buffer().set_text("");
        if let Some(file)=selected {if file.preview {load_preview(&state,&view,file);}else {view.preview.buffer().set_text(tr("Asset ausgewählt. Öffnen erfolgt nur auf eigenen Klick in der Standard-App.","Asset selected. It opens in the default app only when you click Open."));}}
    });
    }
    {
        let state = state.clone();
        let view = view.clone();
        view.open.clone().connect_clicked(move |_| {
            let selected = state
                .borrow()
                .files
                .get(view.files.selected() as usize)
                .cloned();
            if let Some(file) = selected {
                open_output(&state, &view, file);
            }
        });
    }
    let drop = gtk::DropTarget::new(
        gtk::gdk::FileList::static_type(),
        gtk::gdk::DragAction::COPY,
    );
    {
        let state = state.clone();
        let view = view.clone();
        drop.connect_drop(move |_, value, _, _| {
            if state.borrow().is_busy() {
                return false;
            }
            if let Ok(files) = value.get::<gtk::gdk::FileList>() {
                let offered = files.files();
                let paths: Vec<PathBuf> = offered.iter().filter_map(|file| file.path()).collect();
                if paths.is_empty() || paths.len() != offered.len() {
                    reject_remote(&view);
                    return false;
                }
                set_sources(&state, &view, paths);
                true
            } else {
                false
            }
        });
    }
    view.sources.add_controller(drop);
    {
        let state = state.clone();
        let view = view.clone();
        window.connect_close_request(move |_| {
            if state.borrow().is_busy() {
                state.borrow_mut().closing = true;
                cancel_job(&state, &view);
                glib::Propagation::Stop
            } else {
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
                std::mem::drop(source);
                #[cfg(feature = "ui-self-test")]
                eprintln!("PMT_UI_TEST_CLIPBOARD_CLOSE released-after-job-barrier");
                glib::Propagation::Proceed
            }
        });
    }
    let convert_action = gio::SimpleAction::new("convert", None);
    let button = view.convert.clone();
    convert_action.connect_activate(move |_, _| {
        if button.is_sensitive() {
            button.emit_clicked();
        }
    });
    app.add_action(&convert_action);
    app.set_accels_for_action("app.convert", &["<Control>Return"]);
    let cancel_action = gio::SimpleAction::new("cancel", None);
    let button = view.cancel.clone();
    cancel_action.connect_activate(move |_, _| {
        if button.is_sensitive() {
            button.emit_clicked();
        }
    });
    app.add_action(&cancel_action);
    app.set_accels_for_action("app.cancel", &["Escape"]);
    let choose_action = gio::SimpleAction::new("choose", None);
    choose_action.connect_activate(move |_, _| {
        if choose.is_sensitive() {
            choose.emit_clicked();
        }
    });
    app.add_action(&choose_action);
    app.set_accels_for_action("app.choose", &["<Control>O"]);
    if !initial_sources.is_empty() {
        set_sources(&state, &view, initial_sources);
    }
    window.present();
    launch(&state, &view, bridge.start_catalog(), false);
    #[cfg(feature = "ui-self-test")]
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
    #[cfg(feature = "ui-self-test")]
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
                "--image-ocr".into(),
                "off".into(),
                "--source-map".into(),
                "--output".into(),
                output.into_os_string(),
                "--".into(),
                input.path().into_os_string(),
            ];
            if let Some(pandoc) = std::env::var_os("PMT_UI_TEST_BOUND_PANDOC") {
                args.splice(0..0, ["--pandoc".into(), pandoc]);
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
                                value["outputFiles"][0]["sha256"] = serde_json::json!("0".repeat(64));
                            } else {
                                value["outputFiles"][0]["byteCount"] = serde_json::json!(16 * 1024 * 1024 + 1);
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
    #[cfg(feature = "ui-self-test")]
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
    #[cfg(feature = "ui-self-test")]
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
                for (flag, check) in &view.controls.flags {
                    if flag == "--source-map" {
                        check.set_active(true);
                    }
                }
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
    #[cfg(feature = "ui-self-test")]
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
                for (flag, check) in &view.controls.flags {
                    if flag == "--source-map" {
                        check.set_active(true);
                    }
                }
                for (flag, choice, values) in &view.controls.choices {
                    if flag == "--pdf-ocr" || flag == "--image-ocr" {
                        choice.set_selected(values.iter().position(|v| v == "off").unwrap() as u32);
                    }
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
    (state, view)
}
fn set_sources(state: &Shared, view: &View, paths: Vec<PathBuf>) {
    if state.borrow().is_busy() {
        #[cfg(feature = "ui-self-test")]
        eprintln!("PMT_UI_TEST_REJECTED_SOURCE busy");
        view.rejection.set_text(tr(
            "Lauf aktiv: neue Quellen wurden nicht angenommen. Bitte nach Abschluss erneut öffnen.",
            "A job is active: new sources were not accepted. Open them again when it finishes.",
        ));
        return;
    }
    view.rejection.set_text("");
    let mut s = state.borrow_mut();
    s.generation += 1;
    s.sources = paths;
    s.clipboard_source = None;
    #[cfg(feature = "ui-self-test")]
    {
        use std::os::unix::ffi::OsStrExt;
        eprintln!(
            "PMT_UI_TEST_SOURCES {}",
            serde_json::to_string(
                &s.sources
                    .iter()
                    .map(|p| p.as_os_str().as_bytes())
                    .collect::<Vec<_>>()
            )
            .unwrap_or_default()
        );
    }
    s.files.clear();
    let displayed = s
        .sources
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("\n");
    drop(s);
    view.sources.buffer().set_text(if displayed.is_empty() {
        tr(
            "Dateien oder Ordner hier ablegen…",
            "Drop files or folders here…",
        )
    } else {
        &displayed
    });
    view.files.set_sensitive(false);
    view.files.set_model(Some(&gtk::StringList::new(&[tr(
        "Noch kein Ergebnis",
        "No result yet",
    )])));
    view.open.set_sensitive(false);
    view.copy.set_sensitive(false);
    view.compare.set_sensitive(false);
    view.preview.buffer().set_text("");
    view.diagnostics.buffer().set_text("");
    view.details.buffer().set_text("");
    view.status.set_text(tr(
        "Bereit · neue Quellen gewählt",
        "Ready · new sources selected",
    ));
}
fn choose_sources(state: &Shared, view: &View, folder: bool) {
    let generation = state.borrow().generation;
    let dialog = gtk::FileDialog::builder()
        .title(if folder {
            tr("Quellordner wählen", "Choose source folder")
        } else {
            tr("Quelldokumente wählen", "Choose source documents")
        })
        .build();
    let state = state.clone();
    let view = view.clone();
    if folder {
        dialog.select_folder(
            Some(&view.window.clone()),
            None::<&gio::Cancellable>,
            move |result| {
                if let Err(ref error) = result {
                    dialog_error(&view, error);
                    return;
                }
                if !ticket_current(&state, &view, generation) {
                    return;
                }
                if let Ok(file) = result {
                    if let Some(path) = file.path() {
                        set_sources(&state, &view, vec![path]);
                    } else {
                        reject_remote(&view);
                    }
                }
            },
        );
    } else {
        dialog.open_multiple(
            Some(&view.window.clone()),
            None::<&gio::Cancellable>,
            move |result| {
                if let Err(ref error) = result {
                    dialog_error(&view, error);
                    return;
                }
                if !ticket_current(&state, &view, generation) {
                    return;
                }
                if let Ok(files) = result {
                    let paths: Vec<PathBuf> = (0..files.n_items())
                        .filter_map(|i| files.item(i).and_downcast::<gio::File>())
                        .filter_map(|f| f.path())
                        .collect();
                    if paths.len() != files.n_items() as usize {
                        reject_remote(&view);
                        return;
                    }
                    set_sources(&state, &view, paths);
                }
            },
        );
    }
}
fn cancel_job(state: &Shared, view: &View) {
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
fn launch(state: &Shared, view: &View, job: Job, conversion: bool) {
    launch_completed(state, view, job, conversion, None);
}
fn launch_completed(
    state: &Shared,
    view: &View,
    job: Job,
    conversion: bool,
    mut completed: SuccessHook,
) {
    #[cfg(feature = "ui-self-test")]
    eprintln!("PMT_UI_TEST_JOB_STARTED conversion={conversion}");
    view.rejection.set_text("");
    {
        let mut s = state.borrow_mut();
        s.generation += 1;
        s.cancelled = false;
        s.active = Some(job.handle);
        #[cfg(feature = "ui-self-test")]
        {
            s.test_response = None;
        }
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
                    let closing = closing
                        || std::env::var_os("PMT_UI_TEST_QUIT_ON_FINISH").is_some() && conversion
                        || std::env::var_os("PMT_UI_TEST_QUIT_ON_CATALOG").is_some() && !conversion;
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
                    eprintln!(
                        "PMT_UI_TEST_OPERATION_FINISHED conversion={conversion} cancelled={cancelled}"
                    );
                    view.convert.set_sensitive(true);
                    view.cancel.set_sensitive(false);
                    view.source_controls.set_sensitive(true);
                    view.options.set_sensitive(true);
                    view.progress.set_fraction(0.0);
                    if cancelled {
                        #[cfg(feature = "ui-self-test")]
                        eprintln!("PMT_UI_TEST_CANCELLED cleanup-finished closing={closing}");
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
                                {
                                    state.borrow_mut().test_response = Some(value.clone());
                                }
                                if let Some(completed) = completed.take() {
                                    completed(&value);
                                }
                                render_response(&view, &value);
                                if conversion {
                                    #[cfg(feature = "ui-self-test")]
                                    eprintln!("PMT_UI_TEST_RESULT {}", value);
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
                                {
                                    state.borrow_mut().test_response = error.response.clone();
                                }
                                view.result_tabs.set_current_page(Some(1));
                                #[cfg(feature = "ui-self-test")]
                                eprintln!("PMT_UI_TEST_ERROR {:?}", error);
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
                    let closing = closing
                        || std::env::var_os("PMT_UI_TEST_QUIT_ON_FINISH").is_some() && conversion
                        || std::env::var_os("PMT_UI_TEST_QUIT_ON_CATALOG").is_some() && !conversion;
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
fn load_preview(state: &Shared, view: &View, file: model::OutputFile) {
    let generation = state.borrow().generation;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let text = read_output::text(&file, 2_097_152);
        let _ = tx.send(text);
    });
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(Duration::from_millis(30), move || {
        if state.borrow().generation != generation {
            return glib::ControlFlow::Break;
        }
        match rx.try_recv() {
            Ok(text) => {
                view.preview.buffer().set_text(&text.unwrap_or_else(|e| e));
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}

fn show_files(state: &Shared, view: &View, value: &Value) {
    let mut files = model::outputs(value);
    if let Some(source) = &state.borrow().clipboard_source {
        for file in &mut files {
            file.source_origin = model::SourceOrigin::Clipboard;
            file.bound_input = Some(source.binding.clone());
        }
    }
    state.borrow_mut().files = files.clone();
    view.files.set_sensitive(false);
    view.files.set_model(Some(&gtk::StringList::new(&[tr(
        "Noch kein Ergebnis",
        "No result yet",
    )])));
    view.files.set_sensitive(!files.is_empty());
    let labels = gtk::StringList::new(&[]);
    if files.is_empty() {
        labels.append(tr("Noch kein Ergebnis", "No result yet"));
    }
    for (index, file) in files.iter().enumerate() {
        labels.append(&format!("{} · {}", index + 1, file.label));
    }
    view.files.set_model(Some(&labels));
    if !files.is_empty() {
        view.files.set_selected(0);
    }
}

fn render_response(view: &View, value: &Value) {
    view.diagnostics.buffer().set_text(&model::describe(value));
    view.details
        .buffer()
        .set_text(&serde_json::to_string_pretty(value).unwrap_or_default());
}

fn reject_remote(view: &View) {
    view.rejection.set_text(tr(
        "Nur lokale Dateien und Ordner werden angenommen.",
        "Only local files and folders are accepted.",
    ));
}
fn ticket_current(state: &Shared, view: &View, generation: u64) -> bool {
    if state.borrow().generation != generation || state.borrow().is_busy() {
        view.rejection.set_text(tr(
            "Die Auswahl wurde durch neue Quellen oder einen Lauf überholt. Bitte erneut wählen.",
            "New sources or a job superseded this selection. Choose again.",
        ));
        false
    } else {
        true
    }
}

fn dialog_error(view: &View, error: &glib::Error) {
    if error.matches(gtk::DialogError::Cancelled)
        || error.matches(gtk::DialogError::Dismissed)
        || error.matches(gio::IOErrorEnum::Cancelled)
    {
        return;
    }
    view.rejection.set_text(&format!(
        "{}: {}",
        tr("Dateiauswahl fehlgeschlagen", "File selection failed"),
        error
    ));
    #[cfg(feature = "ui-self-test")]
    eprintln!("PMT_UI_TEST_DIALOG_ERROR {}", error);
}

fn bounded_dropdown(dropdown: &gtk::DropDown) {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
            let label = gtk::Label::builder()
                .xalign(0.0)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .width_chars(18)
                .max_width_chars(32)
                .build();
            item.set_child(Some(&label));
        }
    });
    factory.connect_bind(|_, item| {
        if let Some(item) = item.downcast_ref::<gtk::ListItem>()
            && let Some(text) = item.item().and_downcast::<gtk::StringObject>()
            && let Some(label) = item.child().and_downcast::<gtk::Label>()
        {
            label.set_text(&text.string());
            label.set_tooltip_text(Some(&text.string()));
        }
    });
    dropdown.set_factory(Some(&factory));
    dropdown.set_list_factory(Some(&factory));
}

fn source_bridge(bridge: &Bridge, state: &Shared) -> Bridge {
    if let Some(source) = &state.borrow().clipboard_source {
        bridge.clone().with_input(source.binding.clone())
    } else {
        bridge.clone()
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

fn open_output(state: &Shared, view: &View, file: model::OutputFile) {
    let generation = state.borrow().generation;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let result = read_output::read(
            &file,
            1024 * 1024 * 1024,
            false,
            &std::sync::atomic::AtomicBool::new(false),
        );
        let _ = tx.send((file, result));
    });
    let state = state.clone();
    let view = view.clone();
    glib::timeout_add_local(Duration::from_millis(30), move || {
        if state.borrow().generation != generation || state.borrow().closing {
            return glib::ControlFlow::Break;
        }
        match rx.try_recv() {
            Ok((file, result)) => {
                let result = result.and_then(|snapshot| read_output::revalidate(&snapshot));
                match result {
                    Ok(()) => {
                        let uri = gio::File::for_path(file.path).uri();
                        if let Err(e) = gio::AppInfo::launch_default_for_uri(
                            &uri,
                            None::<&gio::AppLaunchContext>,
                        ) {
                            view.status.set_text(&e.to_string());
                        }
                    }
                    Err(e) => view.rejection.set_text(&e),
                }
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => glib::ControlFlow::Break,
        }
    });
}
