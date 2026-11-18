mod batch;
mod editor;
mod geometry;

use crate::model::tr;
use gtk::{gdk, gio, glib, prelude::*};
use pmt_bridge::{BoundInput, Bridge, BridgeError, ErrorKind, Event, InputName, Job};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::{
    collections::HashSet,
    ffi::OsString,
    path::{Path, PathBuf},
    sync::mpsc::TryRecvError,
    time::Duration,
};

pub(super) fn open_editor(parent: &gtk::ApplicationWindow, bridge: &Bridge, paths: &[PathBuf]) {
    editor::open(parent.upcast_ref(), bridge, selected_pdfs(paths), None);
}

pub(super) fn open_batch(parent: &gtk::ApplicationWindow, bridge: &Bridge, paths: &[PathBuf]) {
    batch::open(parent.upcast_ref(), bridge, selected_pdfs(paths), None);
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mask {
    version: u32,
    partner: String,
    document_type: String,
    fields: Vec<Field>,
}

impl Default for Mask {
    fn default() -> Self {
        Self {
            version: 1,
            partner: String::new(),
            document_type: String::new(),
            fields: vec![],
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Field {
    id: String,
    name: String,
    rule: Rule,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Rule {
    Region { page: usize, rectangle: Rect },
    RightOf { label: String, kind: ValueKind },
}

impl Rule {
    fn description(&self) -> String {
        match self {
            Self::Region { page, rectangle } => format!(
                "{} {} · {}",
                tr("Bereich auf Seite", "Region on page"),
                page + 1,
                rectangle.dimensions()
            ),
            Self::RightOf { label, kind } => format!(
                "{} “{}” · {}",
                tr("Rechts neben", "Right of"),
                label,
                match kind {
                    ValueKind::Date => tr("Datum", "Date"),
                    ValueKind::Identifier => tr("Kennung", "Identifier"),
                }
            ),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ValueKind {
    Date,
    Identifier,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Rect {
    fn dimensions(self) -> String {
        format!(
            "x {:.1}, y {:.1} · {:.1} × {:.1} mm",
            self.x, self.y, self.width, self.height
        )
    }
}

#[derive(Clone, Debug, Deserialize)]
struct FieldValue {
    id: String,
    value: Option<String>,
    status: ValueStatus,
    sources: Vec<Evidence>,
    diagnostic: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ValueStatus {
    Confirmed,
    Corrected,
    Missing,
    Ambiguous,
}

impl ValueStatus {
    fn title(&self) -> &'static str {
        match self {
            Self::Confirmed => tr("Bestätigt", "Confirmed"),
            Self::Corrected => tr("Korrigiert", "Corrected"),
            Self::Missing => tr("Fehlt", "Missing"),
            Self::Ambiguous => tr("Mehrdeutig", "Ambiguous"),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
struct Evidence {
    page: usize,
    rectangle: Rect,
    text: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Identity {
    sha256: String,
    byte_count: u64,
}

fn decode<T: DeserializeOwned>(value: &Value, key: &str) -> Result<T, String> {
    T::deserialize(
        value
            .get(key)
            .ok_or_else(|| format!("Receipt response is missing {key}"))?,
    )
    .map_err(|error| error.to_string())
}

fn request_job(bridge: &Bridge, request: &Value) -> Result<Job, String> {
    let bytes = serde_json::to_vec(request).map_err(|error| error.to_string())?;
    let input = sealed(&bytes, "receipt-request.json")?;
    let args = vec![
        "receipt-editor".into(),
        "--request".into(),
        input.path().into_os_string(),
    ];
    Ok(bridge.clone().with_input(input).start_operation(args))
}

fn batch_job(
    bridge: &Bridge,
    mask: &Mask,
    sources: &[PathBuf],
    destination: Option<&Path>,
) -> Result<Job, String> {
    let bytes = serde_json::to_vec(mask).map_err(|error| error.to_string())?;
    let input = sealed(&bytes, "receipt-mask.json")?;
    let mut args: Vec<OsString> = vec!["extract".into(), "--mask".into(), input.path().into()];
    if let Some(destination) = destination {
        args.extend(["--output-dir".into(), destination.as_os_str().to_owned()]);
    }
    args.push("--".into());
    args.extend(sources.iter().map(|source| source.as_os_str().to_owned()));
    Ok(bridge.clone().with_input(input).start_receipt_batch(args))
}

fn sealed(bytes: &[u8], name: &str) -> Result<BoundInput, String> {
    InputName::new(name)
        .and_then(|name| BoundInput::new(bytes, name))
        .map_err(|error| error.to_string())
}

fn watch(
    job: Job,
    progress: impl Fn(String) + 'static,
    complete: impl FnOnce(Result<Value, BridgeError>) + 'static,
) {
    let Job { events, .. } = job;
    let mut complete = Some(complete);
    glib::timeout_add_local(Duration::from_millis(25), move || {
        loop {
            let result = match events.try_recv() {
                Ok(Event::ProgressText(text)) => {
                    progress(text);
                    continue;
                }
                Ok(Event::Finished(result)) => result,
                Err(TryRecvError::Empty) => return glib::ControlFlow::Continue,
                Err(TryRecvError::Disconnected) => Err(BridgeError {
                    kind: ErrorKind::Capture,
                    message: "The receipt worker ended without a result.".into(),
                    exit_code: None,
                    signal: None,
                    stderr: String::new(),
                    response: None,
                }),
            };
            complete.take().unwrap()(result);
            return glib::ControlFlow::Break;
        }
    });
}

fn response(result: Result<Value, BridgeError>) -> Result<Value, String> {
    let value = result.map_err(|error| error.to_string())?;
    if value.get("operation").and_then(Value::as_str) != Some("receipt-editor") {
        return Err("Unexpected receipt editor response".into());
    }
    Ok(value)
}

fn path_text(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| {
        tr(
            "Der Dateipfad ist kein gültiges UTF-8.",
            "The file path is not valid UTF-8.",
        )
        .into()
    })
}

fn pdf_paths(existing: &[PathBuf], offered: Vec<PathBuf>) -> Result<Vec<PathBuf>, String> {
    let mut seen: HashSet<PathBuf> = existing
        .iter()
        .filter_map(|path| path.canonicalize().ok())
        .collect();
    let mut added = Vec::new();
    for path in offered {
        if !is_pdf(&path) {
            return Err(tr("Bitte PDF-Dateien wählen.", "Choose PDF files.").into());
        }
        path_text(&path)?;
        let canonical = path.canonicalize().map_err(|error| error.to_string())?;
        if seen.insert(canonical) {
            added.push(path);
        }
    }
    Ok(added)
}

fn selected_pdfs(paths: &[PathBuf]) -> Vec<PathBuf> {
    paths.iter().filter(|path| is_pdf(path)).cloned().collect()
}

fn is_pdf(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("pdf"))
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or(path.as_os_str())
        .to_string_lossy()
        .into_owned()
}

fn file_dialog(title: &str, pattern: Option<&str>) -> gtk::FileDialog {
    let dialog = gtk::FileDialog::builder().title(title).modal(true).build();
    if let Some(pattern) = pattern {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(match pattern {
            "*.pdf" => "PDF",
            _ => "JSON",
        }));
        filter.add_pattern(pattern);
        if pattern == "*.pdf" {
            filter.add_mime_type("application/pdf");
        }
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        dialog.set_filters(Some(&filters));
    }
    dialog
}

fn choose_pdfs(window: &gtk::Window, apply: impl FnOnce(Result<Vec<PathBuf>, String>) + 'static) {
    file_dialog(tr("PDF-Dateien wählen", "Choose PDF files"), Some("*.pdf")).open_multiple(
        Some(window),
        None::<&gio::Cancellable>,
        move |result| match result {
            Ok(files) => apply(
                (0..files.n_items())
                    .map(|i| local_file(files.item(i).and_downcast::<gio::File>()))
                    .collect(),
            ),
            Err(error) if !dismissed(&error) => apply(Err(error.to_string())),
            Err(_) => {}
        },
    );
}

fn choose_file(
    window: &gtk::Window,
    title: &str,
    mode: FileMode<'_>,
    apply: impl FnOnce(Result<PathBuf, String>) + 'static,
) {
    let dialog = file_dialog(
        title,
        match mode {
            FileMode::Folder => None,
            _ => Some("*.json"),
        },
    );
    let callback = move |result| match result {
        Ok(file) => apply(local_file(Some(file))),
        Err(error) if !dismissed(&error) => apply(Err(error.to_string())),
        Err(_) => {}
    };
    match mode {
        FileMode::Open => dialog.open(Some(window), None::<&gio::Cancellable>, callback),
        FileMode::Save(name) => {
            dialog.set_initial_name(Some(name));
            dialog.save(Some(window), None::<&gio::Cancellable>, callback);
        }
        FileMode::Folder => dialog.select_folder(Some(window), None::<&gio::Cancellable>, callback),
    }
}

enum FileMode<'a> {
    Open,
    Save(&'a str),
    Folder,
}

fn local_file(file: Option<gio::File>) -> Result<PathBuf, String> {
    file.and_then(|file| file.path())
        .ok_or_else(|| tr("Bitte lokale Dateien wählen.", "Choose local files.").into())
}

fn dismissed(error: &glib::Error) -> bool {
    error.matches(gtk::DialogError::Cancelled)
        || error.matches(gtk::DialogError::Dismissed)
        || error.matches(gio::IOErrorEnum::Cancelled)
}

fn file_drop(
    widget: &impl IsA<gtk::Widget>,
    apply: impl Fn(Result<Vec<PathBuf>, String>) -> bool + 'static,
) {
    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    drop.connect_drop(move |_, value, _, _| {
        let Ok(files) = value.get::<gdk::FileList>() else {
            return false;
        };
        apply(
            files
                .files()
                .into_iter()
                .map(|file| local_file(Some(file)))
                .collect(),
        )
    });
    widget.add_controller(drop);
}

fn window(parent: &gtk::Window, title: &str, width: i32, height: i32) -> gtk::Window {
    gtk::Window::builder()
        .application(&parent.application().expect("receipt application window"))
        .transient_for(parent)
        .title(title)
        .default_width(width)
        .default_height(height)
        .build()
}

fn padded(spacing: i32, margin: i32) -> gtk::Box {
    gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(spacing)
        .margin_top(margin)
        .margin_bottom(margin)
        .margin_start(margin)
        .margin_end(margin)
        .build()
}

fn section(box_: &gtk::Box, title: &str) {
    let heading = crate::label(title);
    heading.add_css_class("heading");
    box_.append(&heading);
}

fn clear(box_: &gtk::Box) {
    while let Some(child) = box_.first_child() {
        box_.remove(&child);
    }
}

fn icon(name: &str, title: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(name);
    button.set_tooltip_text(Some(title));
    button.update_property(&[gtk::accessible::Property::Label(title)]);
    button
}

fn buttons(parent: &gtk::Box, buttons: &[&gtk::Button]) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    for button in buttons {
        row.append(*button);
    }
    parent.append(&row);
}

fn single_line(text: &str) -> gtk::Label {
    gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .ellipsize(gtk::pango::EllipsizeMode::Middle)
        .hexpand(true)
        .build()
}
