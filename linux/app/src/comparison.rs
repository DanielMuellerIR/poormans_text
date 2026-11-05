use crate::{
    bounded_dropdown, label,
    model::{OutputFile, tr},
};
use gtk::{glib, prelude::*};
use serde_json::Value;
use std::{
    cell::RefCell,
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
const SOURCE_LIMIT: u64 = 1024 * 1024 * 1024;
const OUTPUT_LIMIT: u64 = 16 * 1024 * 1024;
const POSITION_LIMIT: usize = 2048;

#[derive(Clone)]
struct Descriptor {
    source: PathBuf,
    bound_input: crate::model::InputSlot,
    file: OutputFile,
    source_count: u64,
    source_hash: String,
    mappings: Vec<Value>,
    relative: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Stamp {
    fn of(m: &fs::Metadata) -> Self {
        Self {
            device: m.dev(),
            inode: m.ino(),
            size: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}
#[derive(Clone)]
struct Position {
    start: i32,
    end: i32,
    label: String,
    snippet: String,
    page: Option<u32>,
    frame: Option<u32>,
}
#[derive(Clone)]
enum SourceVerification {
    File { stamp: Stamp, parent: Stamp },
    Bound { stamp: crate::read_output::Stamp },
}
#[derive(Clone)]
struct Verified {
    text: String,
    positions: Vec<Position>,
    source: SourceVerification,
    output_snapshot: Arc<crate::read_output::Snapshot>,
    limited: bool,
}
impl Descriptor {
    fn parse(file: &OutputFile) -> Result<Self, String> {
        let context = file.context.as_ref().ok_or_else(|| {
            tr(
                "Keine Vergleichsdaten vorhanden.",
                "No comparison data is available.",
            )
            .to_string()
        })?;
        let identity = context.get("sourceIdentity").ok_or_else(|| {
            tr(
                "Keine Quellidentität. Bei der Umwandlung Quellzuordnung oder Bericht aktivieren.",
                "No source identity. Enable source mapping or a report when converting.",
            )
            .to_string()
        })?;
        if identity.get("memberPath").is_some_and(|v| !v.is_null()) {
            return Err(tr("Paketinterne Quelldatenströme sind in dieser Vergleichsansicht noch nicht unterstützt.","Package-member source streams are not supported by this comparison view yet.").into());
        }
        let (source_count, source_hash) = crate::read_output::fingerprint(identity)?;
        if source_count > SOURCE_LIMIT {
            return Err(tr(
                "Die Quelle überschreitet die Prüfgrenze von 1 GiB.",
                "The source exceeds the 1 GiB verification limit.",
            )
            .into());
        }
        let source = PathBuf::from(
            context
                .get("input")
                .and_then(Value::as_str)
                .ok_or("Missing input path")?,
        );
        if !source.is_absolute() {
            return Err("Source path must be absolute".into());
        }
        if let Some(input) = &file.bound_input {
            if source != input.path() {
                return Err("Bound input path does not match the recorded source".into());
            }
        } else if file.source_origin == crate::model::SourceOrigin::Clipboard {
            return Err("The retained clipboard source is unavailable".into());
        }

        let (_, relative, output_count, _) = crate::read_output::reference(file)?;
        let relative = relative
            .to_str()
            .ok_or("Result path is not UTF-8")?
            .to_string();
        if output_count > OUTPUT_LIMIT {
            return Err(tr(
                "Das Ergebnis überschreitet die Vergleichsgrenze von 16 MiB.",
                "The result exceeds the 16 MiB comparison limit.",
            )
            .into());
        }
        let mut owned_file = file.clone();
        let bound_input = crate::model::InputSlot::new(owned_file.bound_input.take());
        Ok(Self {
            bound_input,
            source,
            file: owned_file,
            source_count,
            source_hash,
            mappings: context
                .get("sourceMappings")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
            relative,
        })
    }
}
fn parent_stamp(path: &Path) -> Result<Stamp, String> {
    let parent = path.parent().ok_or("Missing parent directory")?;
    let metadata = fs::symlink_metadata(parent).map_err(|e| e.to_string())?;
    if !metadata.is_dir() {
        return Err("The comparison parent is not a regular directory".into());
    }
    Ok(Stamp::of(&metadata))
}
fn read_verified(
    path: &Path,
    count: u64,
    expected: &str,
    capture: bool,
    cancel: &AtomicBool,
) -> Result<(Vec<u8>, Stamp, Stamp), String> {
    let parent = parent_stamp(path)?;
    let file = crate::read_output::source_file(path)?;
    let (bytes, verified_stamp) =
        crate::read_output::stream(file, count, expected, capture, cancel)?;
    let current = crate::read_output::source_file(path)?
        .metadata()
        .map_err(|e| e.to_string())?;
    let after = Stamp::of(&current);
    if !current.is_file()
        || crate::read_output::Stamp::of(&current) != verified_stamp
        || parent_stamp(path)? != parent
    {
        return Err("Source changed".into());
    }

    Ok((bytes, after, parent))
}
fn byte_range(text: &str, offset: u64, length: u64) -> Result<(usize, usize), String> {
    let offset = usize::try_from(offset).map_err(|_| "Position overflow")?;
    let length = usize::try_from(length).map_err(|_| "Position overflow")?;
    let end = offset.checked_add(length).ok_or("Position overflow")?;
    text.get(offset..end)
        .ok_or("Position is outside UTF-8 result bytes")?;
    Ok((offset, end))
}
fn location(value: &Value) -> String {
    let mut parts = Vec::new();
    for (key, title) in [
        ("page", tr("Seite", "Page")),
        ("sheet", tr("Blatt", "Sheet")),
        ("sheetIndex", tr("Blattindex", "Sheet index")),
        ("cell", tr("Zelle", "Cell")),
        ("slide", tr("Folie", "Slide")),
        ("frame", tr("Bild", "Frame")),
        ("chapter", tr("Kapitel", "Chapter")),
        ("paragraph", tr("Absatz", "Paragraph")),
        ("message", tr("Nachricht", "Message")),
        ("note", tr("Notiz", "Note")),
    ] {
        if let Some(value) = value.get(key).filter(|v| !v.is_null()) {
            parts.push(format!(
                "{title} {}",
                value
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| value.to_string())
            ));
        }
    }
    if parts.is_empty() {
        tr("Belegte Position", "Recorded position").into()
    } else {
        parts.join(", ")
    }
}
fn verify(d: &Descriptor, cancel: &AtomicBool) -> Result<Verified, String> {
    let source = if d.bound_input.is_bound() {
        let input = d.bound_input.get().ok_or("Clipboard source was released")?;
        let (_, stamp) = crate::read_output::stream(
            input.reader().map_err(|e| e.to_string())?,
            d.source_count,
            &d.source_hash,
            false,
            cancel,
        )?;
        SourceVerification::Bound { stamp }
    } else {
        let (_, stamp, parent) =
            read_verified(&d.source, d.source_count, &d.source_hash, false, cancel)?;
        SourceVerification::File { stamp, parent }
    };
    let snapshot = crate::read_output::read(&d.file, OUTPUT_LIMIT, true, cancel)?;
    from_snapshot(d, source, snapshot, cancel)
}
fn from_snapshot(
    d: &Descriptor,
    source: SourceVerification,
    mut snapshot: crate::read_output::Snapshot,
    cancel: &AtomicBool,
) -> Result<Verified, String> {
    let bytes = std::mem::take(&mut snapshot.data);
    let text = String::from_utf8(bytes).map_err(|_| "Result is not valid UTF-8")?;
    let (positions, limited) = mapped_positions(&text, &d.mappings, &d.relative, cancel)?;
    Ok(Verified {
        text,
        positions,
        source,
        output_snapshot: Arc::new(snapshot),
        limited,
    })
}
fn mapped_positions(
    text: &str,
    mappings: &[Value],
    relative: &str,
    cancel: &AtomicBool,
) -> Result<(Vec<Position>, bool), String> {
    let mut ranges = Vec::new();
    let mut endpoints = Vec::new();
    let mut limited = false;
    for mapping in mappings {
        if cancel.load(Ordering::Acquire) {
            return Err("Comparison cancelled".into());
        }
        let output = mapping.get("output").ok_or("Incomplete result position")?;
        if output.get("file").and_then(Value::as_str) != Some(relative) {
            continue;
        }
        if ranges.len() == POSITION_LIMIT {
            limited = true;
            break;
        }
        let offset = output
            .get("utf8Offset")
            .and_then(Value::as_u64)
            .ok_or("Invalid byte position")?;
        let length = output
            .get("utf8Length")
            .and_then(Value::as_u64)
            .ok_or("Invalid byte length")?;
        let (start, end) = byte_range(text, offset, length)?;
        let snippet = text[start..end]
            .chars()
            .take(70)
            .map(|c| if matches!(c, '\n' | '\r') { ' ' } else { c })
            .collect::<String>();
        ranges.push((
            start,
            end,
            location(mapping.get("source").unwrap_or(&Value::Null)),
            snippet,
            mapping
                .pointer("/source/page")
                .and_then(Value::as_u64)
                .and_then(|v| u32::try_from(v).ok())
                .filter(|v| (1..=1000).contains(v)),
            mapping
                .pointer("/source/frame")
                .and_then(Value::as_u64)
                .and_then(|v| u32::try_from(v).ok())
                .filter(|v| (1..=1000).contains(v)),
        ));
        endpoints.extend([start, end]);
    }
    endpoints.sort_unstable();
    endpoints.dedup();
    let mut characters = std::collections::HashMap::with_capacity(endpoints.len());
    let mut next = 0usize;
    // Alle Endpunkte werden in einem einzigen Durchlauf über die UTF8-Zeichen übersetzt.
    for (count, (byte, _)) in text
        .char_indices()
        .chain(std::iter::once((text.len(), '\0')))
        .enumerate()
    {
        if count % 4096 == 0 && cancel.load(Ordering::Acquire) {
            return Err("Comparison cancelled".into());
        }
        if next == endpoints.len() {
            break;
        }
        if byte == endpoints[next] {
            characters.insert(
                byte,
                i32::try_from(count).map_err(|_| "Character position overflow")?,
            );
            next += 1;
        }
    }
    let mut positions = Vec::with_capacity(ranges.len());
    for (start, end, label, snippet, page, frame) in ranges {
        if cancel.load(Ordering::Acquire) {
            return Err("Comparison cancelled".into());
        }
        positions.push(Position {
            start: *characters.get(&start).ok_or("Invalid character endpoint")?,
            end: *characters.get(&end).ok_or("Invalid character endpoint")?,
            label,
            snippet,
            page,
            frame,
        });
    }
    Ok((positions, limited))
}
fn unchanged(d: &Descriptor, v: &Verified) -> bool {
    let source_unchanged = match &v.source {
        SourceVerification::File { stamp, parent } => {
            fs::symlink_metadata(&d.source)
                .ok()
                .filter(|m| m.is_file())
                .is_some_and(|m| Stamp::of(&m) == *stamp)
                && parent_stamp(&d.source).ok().as_ref() == Some(parent)
        }
        SourceVerification::Bound { stamp } => d
            .bound_input
            .get()
            .and_then(|input| input.reader().ok())
            .and_then(|file| file.metadata().ok())
            .is_some_and(|metadata| crate::read_output::Stamp::of(&metadata) == *stamp),
    };
    source_unchanged && crate::read_output::revalidate(&v.output_snapshot).is_ok()
}

#[derive(Clone)]
struct Pane {
    window: gtk::Window,
    status: gtk::Label,
    selector: gtk::DropDown,
    text: gtk::TextView,
    check: gtk::Button,
    raster: Option<crate::source_raster::Pane>,
}
struct State {
    verified: Option<Verified>,
    generation: u64,
    cancel: Arc<AtomicBool>,
    updating: bool,
    #[cfg(feature = "ui-self-test")]
    test_stage: u8,
    #[cfg(feature = "ui-self-test")]
    original: Option<Vec<u8>>,
}
pub(crate) fn open(parent: &gtk::ApplicationWindow, file: OutputFile, root: &crate::Shared) {
    let window = gtk::Window::builder()
        .title(tr(
            "Verifizierter Quellvergleich",
            "Verified source comparison",
        ))
        .transient_for(parent)
        .destroy_with_parent(true)
        .default_width(850)
        .default_height(600)
        .build();
    window.set_application(parent.application().as_ref());
    let descriptor = match Descriptor::parse(&file) {
        Ok(d) => Rc::new(d),
        Err(error) => {
            let message = label(&error);
            message.set_margin_start(16);
            message.set_margin_end(16);
            message.set_margin_top(16);
            message.set_margin_bottom(16);
            window.set_child(Some(&message));
            window.present();
            return;
        }
    };
    let handlers = crate::model::SignalHandlers::default();

    let body = gtk::Box::new(gtk::Orientation::Vertical, 10);
    body.set_margin_top(16);
    body.set_margin_bottom(16);
    body.set_margin_start(16);
    body.set_margin_end(16);
    let status = label(tr(
        "Quelle und Ausgabe werden geprüft…",
        "Verifying source and output…",
    ));
    body.append(&status);
    if file.source_origin == crate::model::SourceOrigin::Clipboard {
        body.append(&label(tr("Zwischenablage · unveränderliche Originalbytes dieser Umwandlung; keine laufende Dateiquelle.","Clipboard · immutable original bytes of this conversion; not a live source file.")));
    }

    body.append(&label(tr("Diese passive Ansicht nutzt verifizierte Quellbytes und protokollierte Ergebnisstellen. Links in der Originalvorschau sind inaktiv; Textmarkierungen beziehen sich auf das Ergebnis.","This passive view uses verified source bytes and recorded result positions. Links in the original preview are inactive; text highlights refer to the result.")));
    let selector = gtk::DropDown::from_strings(&[tr(
        "Keine verifizierten Positionen",
        "No verified positions",
    )]);
    bounded_dropdown(&selector);
    selector.set_enable_search(true);
    selector.set_sensitive(false);
    body.append(&selector);
    let check = gtk::Button::with_label(tr("Erneut prüfen", "Recheck"));
    body.append(&check);
    let text = gtk::TextView::builder()
        .editable(false)
        .cursor_visible(false)
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .child(&text)
        .vexpand(true)
        .hexpand(true)
        .build();
    let raster = crate::source_raster::Pane::for_file(&file, root, parent, &window);
    if let Some(raster) = &raster {
        let split = gtk::Paned::new(gtk::Orientation::Horizontal);
        split.set_start_child(Some(&raster.widget));
        split.set_end_child(Some(&scroll));
        split.set_position(320);
        split.set_vexpand(true);
        split.set_hexpand(true);
        body.append(&split);
    } else {
        body.append(&scroll);
    }
    window.set_child(Some(&body));
    let pane = Pane {
        window: window.clone(),
        status,
        selector,
        text,
        check,
        raster,
    };
    let state = Rc::new(RefCell::new(State {
        verified: None,
        generation: 0,
        cancel: Arc::new(AtomicBool::new(false)),
        updating: false,
        #[cfg(feature = "ui-self-test")]
        test_stage: if std::env::var_os("PMT_UI_TEST_COMPARISON").is_some() {
            1
        } else {
            0
        },
        #[cfg(feature = "ui-self-test")]
        original: None,
    }));
    if let Some(raster) = &pane.raster {
        let is_page = raster.is_page();
        let state = state.clone();
        let selector = pane.selector.clone();
        let text = pane.text.clone();
        raster.set_navigation(move |number| {
            let found = {
                let s = state.borrow();
                s.verified.as_ref().and_then(|v| {
                    v.positions
                        .iter()
                        .position(|p| (if is_page { p.page } else { p.frame }) == Some(number))
                })
            };
            if let Some(index) = found {
                selector.set_selected(index as u32 + 1);
                true
            } else {
                selector.set_selected(0);
                let begin = text.buffer().start_iter();
                text.buffer().select_range(&begin, &begin);
                #[cfg(feature = "ui-self-test")]
                if std::env::var_os("PMT_UI_TEST_RASTER").is_some() {
                    eprintln!("PMT_UI_TEST_RASTER_UNMAPPED no-invented-result-selection");
                }
                false
            }
        });
    }
    if let Some(raster) = &pane.raster {
        let state = state.clone();
        let d = descriptor.clone();
        raster.set_validation(move || {
            state
                .borrow()
                .verified
                .as_ref()
                .is_some_and(|verified| unchanged(&d, verified))
        });
    }
    {
        let state = state.clone();
        let pane = pane.clone();
        let d = descriptor.clone();
        let button = pane.check.clone();
        let id = button.connect_clicked(move |_| start_check(&state, &pane, &d, None));
        handlers.borrow_mut().push((button.upcast(), id));
    }
    {
        let state = state.clone();
        let pane = pane.clone();
        let d = descriptor.clone();
        let selector = pane.selector.clone();
        let id = selector.connect_selected_notify(move |selector| {
            if state.borrow().updating {
                return;
            }
            let index = selector.selected().checked_sub(1).map(|v| v as usize);
            if let Some(index) = index {
                start_check(&state, &pane, &d, Some(index));
            }
        });
        handlers.borrow_mut().push((selector.upcast(), id));
    }
    {
        let state = state.clone();
        let raster = pane.raster.clone();
        let d = descriptor.clone();
        let pane = pane.clone();
        let connections = handlers.clone();
        let id = window.connect_close_request(move |_| {
            state.borrow().cancel.store(true, Ordering::Release);
            d.bound_input.clear();
            state.borrow_mut().verified = None;
            state.borrow_mut().updating = true;
            #[cfg(feature = "ui-self-test")]
            {
                state.borrow_mut().original = None;
            }
            pane.text.buffer().set_text("");
            pane.selector.set_model(Some(&gtk::StringList::new(&[])));
            if raster.as_ref().is_some_and(|r| !r.close_when_idle()) {
                glib::Propagation::Stop
            } else {
                crate::model::disconnect_handlers(&connections);
                glib::Propagation::Proceed
            }
        });
        handlers.borrow_mut().push((window.clone().upcast(), id));
    }
    {
        let state = state.clone();
        let d = descriptor.clone();
        window.connect_destroy(move |_| {
            state.borrow().cancel.store(true, Ordering::Release);
            d.bound_input.clear();
        });
    }
    {
        let state = state.clone();
        let pane = pane.clone();
        let d = descriptor.clone();
        glib::timeout_add_local(Duration::from_millis(250), move || {
            if state.borrow().cancel.load(Ordering::Acquire) || !pane.window.is_visible() {
                return glib::ControlFlow::Break;
            }
            let changed = state
                .borrow()
                .verified
                .as_ref()
                .is_some_and(|v| !unchanged(&d, v));
            if changed {
                state.borrow_mut().verified = None;
                if let Some(raster) = &pane.raster {
                    raster.invalidate();
                }
                pane.selector.set_sensitive(false);
                let begin = pane.text.buffer().start_iter();
                pane.text.buffer().select_range(&begin, &begin);
                pane.status.set_text(tr("Quelle, Ausgabe oder Ordner geändert. Bitte erneut prüfen; Positionssprünge sind gesperrt.","Source, result or folder changed. Recheck; position jumps are disabled."));
                #[cfg(feature = "ui-self-test")]
                if state.borrow().test_stage == 3 {
                    assert!(!pane.selector.is_sensitive());
                    assert!(pane.text.buffer().selection_bounds().is_none());
                    eprintln!("PMT_UI_TEST_COMPARISON_WATCH positions-disabled-on-change");
                    state.borrow_mut().test_stage = 4;
                    pane.check.emit_clicked();
                }
            }
            glib::ControlFlow::Continue
        });
    }
    window.present();
    start_check(&state, &pane, &descriptor, None);
}
fn start_check(
    state: &Rc<RefCell<State>>,
    pane: &Pane,
    d: &Rc<Descriptor>,
    selected: Option<usize>,
) {
    let (generation, cancel) = {
        let mut s = state.borrow_mut();
        s.cancel.store(true, Ordering::Release);
        s.cancel = Arc::new(AtomicBool::new(false));
        s.generation += 1;
        s.verified = None;
        (s.generation, s.cancel.clone())
    };
    if let Some(raster) = &pane.raster {
        raster.invalidate();
    }
    pane.selector.set_sensitive(false);
    pane.check.set_sensitive(false);
    pane.status.set_text(tr(
        "Quelle und Ausgabe werden geprüft…",
        "Verifying source and output…",
    ));
    let begin = pane.text.buffer().start_iter();
    pane.text.buffer().select_range(&begin, &begin);
    let (sender, receiver) = std::sync::mpsc::channel();
    let descriptor = (**d).clone();
    std::thread::spawn(move || {
        let _ = sender.send(verify(&descriptor, &cancel));
    });
    let state = state.clone();
    let pane = pane.clone();
    let current = d.clone();
    glib::timeout_add_local(Duration::from_millis(25), move || {
        if state.borrow().generation != generation || state.borrow().cancel.load(Ordering::Acquire)
        {
            return glib::ControlFlow::Break;
        }
        match receiver.try_recv() {
            Ok(Ok(verified)) => {
                if !unchanged(&current, &verified) {
                    pane.status.set_text(tr(
                        "Quelle oder Ausgabe während der Prüfung geändert. Bitte erneut prüfen.",
                        "Source or result changed during verification. Recheck.",
                    ));
                    pane.check.set_sensitive(true);
                    return glib::ControlFlow::Break;
                }
                pane.text.buffer().set_text(&verified.text);
                #[cfg(feature = "ui-self-test")]
                if current.bound_input.is_bound()
                    && std::env::var_os("PMT_UI_TEST_BOUND_SOURCE").is_some()
                {
                    eprintln!(
                        "PMT_UI_TEST_BOUND_SOURCE_VERIFIED positions={}",
                        verified.positions.len()
                    );
                    if pane.raster.is_none() {
                        eprintln!("PMT_UI_TEST_BOUND_TEXT_COMPLETE passive-verified-markdown");
                        let parent = pane.window.transient_for().unwrap();
                        glib::idle_add_local_once(move || parent.close());
                    }
                }

                if let Some(raster) = &pane.raster {
                    let position = selected.and_then(|index| verified.positions.get(index));
                    raster.verified_for(
                        position.and_then(|p| p.page),
                        position.and_then(|p| p.frame),
                    );
                }
                let names = gtk::StringList::new(&[tr(
                    "Belegte Stelle wählen",
                    "Choose a recorded location",
                )]);
                for position in &verified.positions {
                    names.append(&format!("{} · {}", position.label, position.snippet));
                }
                state.borrow_mut().updating = true;
                pane.selector.set_model(Some(&names));
                pane.selector
                    .set_selected(selected.map(|i| i as u32 + 1).unwrap_or(0));
                state.borrow_mut().updating = false;
                pane.selector.set_sensitive(!verified.positions.is_empty());
                pane.check.set_sensitive(true);
                pane.status.set_text(&format!(
                    "{} · {} {}{}",
                    tr(
                        "Quelle und Ausgabe sind unverändert",
                        "Source and output are unchanged"
                    ),
                    verified.positions.len(),
                    tr("belegte Positionen", "recorded positions"),
                    if verified.limited {
                        tr(" (Liste auf 2048 begrenzt)", " (list limited to 2048)")
                    } else {
                        ""
                    }
                ));
                if let Some(position) = selected.and_then(|index| verified.positions.get(index)) {
                    let mut start = pane.text.buffer().iter_at_offset(position.start);
                    let end = pane.text.buffer().iter_at_offset(position.end);
                    pane.text.buffer().select_range(&start, &end);
                    #[cfg(feature = "ui-self-test")]
                    if std::env::var_os("PMT_UI_TEST_RASTER").is_some()
                        && (position.page == Some(2) || position.frame == Some(2))
                    {
                        let (a, b) = pane.text.buffer().selection_bounds().unwrap();
                        let selected = pane.text.buffer().text(&a, &b, false);
                        assert!(selected.contains(if position.page == Some(2) {
                            "PAGE TWO"
                        } else {
                            "Frame 2"
                        }));
                        assert_eq!((a.offset(), b.offset()), (position.start, position.end));
                        eprintln!(
                            "PMT_UI_TEST_RASTER_MAPPING exact-utf8-reference-for-second-source-unit"
                        );
                    }
                    pane.text.scroll_to_iter(&mut start, 0.1, false, 0.0, 0.0);
                }
                state.borrow_mut().verified = Some(verified);
                #[cfg(feature = "ui-self-test")]
                test_verified(&state, &pane, &current, selected);

                glib::ControlFlow::Break
            }
            Ok(Err(error)) => {
                pane.status.set_text(&error);
                pane.selector.set_sensitive(false);
                pane.check.set_sensitive(true);
                state.borrow_mut().verified = None;
                #[cfg(feature = "ui-self-test")]
                if state.borrow().test_stage == 4 {
                    assert!(error.contains("geändert") || error.contains("changed"));
                    eprintln!("PMT_UI_TEST_COMPARISON_HASH changed-source-rejected");
                    let original = state.borrow_mut().original.take().unwrap();
                    fs::write(&current.source, &original).unwrap();
                    assert_eq!(fs::read(&current.source).unwrap(), original);
                    eprintln!(
                        "PMT_UI_TEST_COMPARISON_COMPLETE unicode-position-and-negative-source"
                    );
                    let parent = pane.window.transient_for();
                    pane.window.close();
                    if let Some(parent) = parent {
                        parent.close();
                    }
                }
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => {
                pane.status.set_text(tr(
                    "Prüfprozess ohne Ergebnis beendet.",
                    "Verification worker ended without a result.",
                ));
                pane.check.set_sensitive(true);
                glib::ControlFlow::Break
            }
        }
    });
}

#[cfg(feature = "ui-self-test")]
fn test_verified(state: &Rc<RefCell<State>>, pane: &Pane, d: &Descriptor, selected: Option<usize>) {
    let stage = state.borrow().test_stage;
    if stage == 1 {
        let index = state
            .borrow()
            .verified
            .as_ref()
            .unwrap()
            .positions
            .iter()
            .position(|position| position.snippet.contains("Grüße"))
            .expect("Unicode mapping missing");
        state.borrow_mut().test_stage = 2;
        pane.selector.set_selected(index as u32 + 1);
    } else if stage == 2 {
        static PAUSED: AtomicBool = AtomicBool::new(false);
        if std::env::var_os("PMT_UI_TEST_COMPARISON_PAUSE").is_some()
            && !PAUSED.swap(true, Ordering::AcqRel)
        {
            let state = state.clone();
            let pane = pane.clone();
            let d = d.clone();
            glib::timeout_add_local_once(Duration::from_secs(4), move || {
                test_verified(&state, &pane, &d, selected)
            });
            return;
        }
        let checked = state.borrow().verified.clone().unwrap();
        let position = &checked.positions[selected.unwrap()];
        let (start, end) = pane
            .text
            .buffer()
            .selection_bounds()
            .expect("GTK selection missing");
        assert_eq!(
            pane.text.buffer().text(&start, &end, false).as_str(),
            position.snippet
        );
        assert_eq!(start.offset(), position.start);
        assert_eq!(end.offset(), position.end);
        eprintln!(
            "PMT_UI_TEST_COMPARISON_UTF8 gtk-selection-exact {} {}",
            position.start, position.end
        );
        let original = fs::read(&d.source).unwrap();
        let changed = String::from_utf8(original.clone())
            .unwrap()
            .replace("Grüße", "Ändern");
        assert_eq!(original.len(), changed.len());
        state.borrow_mut().original = Some(original);
        state.borrow_mut().test_stage = 3;
        fs::write(&d.source, changed).unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, symlink};
    struct Fixture {
        root: PathBuf,
        source: PathBuf,
        output: PathBuf,
        descriptor: Descriptor,
        snippet: String,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn hash(data: &[u8]) -> String {
        let mut sum = glib::Checksum::new(glib::ChecksumType::Sha256).unwrap();
        sum.update(data);
        sum.string().unwrap()
    }
    fn fixture() -> Fixture {
        let root = std::env::temp_dir().join(format!(
            "pmt-comparison-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let output_root = root.join("result");
        fs::create_dir(&output_root).unwrap();
        let source = root.join("Quelle-e\u{301}.csv");
        let original = "A,B\nZeile,Grüße 👩‍💻 e\u{301}\n";
        fs::write(&source, original).unwrap();
        let output = output_root.join("é.md");
        let snippet = "Grüße 👩‍💻 e\u{301}".to_string();
        let text = format!("# é 👩‍💻\n\n{}\n", snippet);
        fs::write(&output, &text).unwrap();
        let offset = text.find(&snippet).unwrap();
        let response = serde_json::json!({"input":source,"outputDirectory":output_root,"markdownFile":output,"sourceIdentity":{"byteCount":original.len(),"sha256":hash(original.as_bytes())},"outputFiles":[{"path":"é.md","byteCount":text.len(),"sha256":hash(text.as_bytes())}],"sourceMappings":[{"source":{"sheet":"e\u{301}","cell":"B2"},"output":{"file":"é.md","utf8Offset":offset,"utf8Length":snippet.len()}}]});
        let file = crate::model::outputs(&response).remove(0);
        Fixture {
            root,
            source,
            output,
            descriptor: Descriptor::parse(&file).unwrap(),
            snippet,
        }
    }
    fn bound_fixture() -> Fixture {
        let mut f = fixture();
        let bytes = fs::read(&f.source).unwrap();
        let input = pmt_bridge::BoundInput::new(
            &bytes,
            pmt_bridge::InputName::new("clipboard.html").unwrap(),
        )
        .unwrap();
        let mut response = (**f.descriptor.file.context.as_ref().unwrap()).clone();
        response["input"] = serde_json::json!(input.path());
        let mut file = crate::model::outputs(&response).remove(0);
        file.bound_input = Some(input);
        file.source_origin = crate::model::SourceOrigin::Clipboard;
        f.descriptor = Descriptor::parse(&file).unwrap();
        fs::remove_file(&f.source).unwrap();
        f
    }
    #[test]
    fn bound_source_survives_original_path_loss_and_uses_verified_unicode_ranges() {
        let f = bound_fixture();
        let v = verify(&f.descriptor, &AtomicBool::new(false)).unwrap();
        assert!(unchanged(&f.descriptor, &v));
        let p = &v.positions[0];
        assert_eq!(
            v.text
                .chars()
                .skip(p.start as usize)
                .take((p.end - p.start) as usize)
                .collect::<String>(),
            f.snippet
        );
        assert!(!f.descriptor.source.exists());
    }
    #[test]
    fn bound_source_hash_mismatch_and_output_replacement_are_rejected() {
        let mut f = bound_fixture();
        let cancel = AtomicBool::new(false);
        let v = verify(&f.descriptor, &cancel).unwrap();
        f.descriptor.source_hash = "0".repeat(64);
        assert!(verify(&f.descriptor, &cancel).is_err());
        fs::write(&f.output, "CHANGED").unwrap();
        assert!(!unchanged(&f.descriptor, &v));
    }
    #[test]
    fn clipboard_marker_without_retained_input_fails_closed() {
        let f = bound_fixture();
        let mut file = f.descriptor.file.clone();
        file.bound_input = None;
        assert!(Descriptor::parse(&file).is_err());
    }
    #[test]
    fn sha256_uses_standard_vector() {
        assert_eq!(
            hash(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
    #[test]
    fn unicode_byte_positions_select_complete_scalars() {
        let fixture = fixture();
        let checked = verify(&fixture.descriptor, &AtomicBool::new(false)).unwrap();
        let position = &checked.positions[0];
        assert_eq!(
            checked
                .text
                .chars()
                .skip(position.start as usize)
                .take((position.end - position.start) as usize)
                .collect::<String>(),
            fixture.snippet
        );
        assert_ne!(
            position.start as usize,
            checked.text.find(&fixture.snippet).unwrap()
        );
    }
    #[test]
    fn offsets_inside_utf8_and_overflow_are_rejected() {
        for (offset, length) in [(1, 1), (0, 1), (u64::MAX, 1)] {
            assert!(byte_range("é", offset, length).is_err());
        }
    }
    #[test]
    fn source_and_output_modifications_disable_comparison() {
        let fixture = fixture();
        let cancel = AtomicBool::new(false);
        assert!(verify(&fixture.descriptor, &cancel).is_ok());
        let original = fs::read(&fixture.source).unwrap();
        let mut changed = original.clone();
        changed[0] = b'Z';
        fs::write(&fixture.source, &changed).unwrap();
        assert!(verify(&fixture.descriptor, &cancel).is_err());
        fs::write(&fixture.source, original).unwrap();
        fs::write(&fixture.output, "CHANGED").unwrap();
        assert!(verify(&fixture.descriptor, &cancel).is_err());
    }
    #[test]
    fn symlink_replacement_is_not_followed() {
        let fixture = fixture();
        let replacement = fixture.root.join("replacement");
        fs::copy(&fixture.source, &replacement).unwrap();
        fs::remove_file(&fixture.source).unwrap();
        symlink(&replacement, &fixture.source).unwrap();
        assert!(verify(&fixture.descriptor, &AtomicBool::new(false)).is_err());
    }
    #[test]
    fn replacement_between_verified_read_and_gui_commit_is_rejected() {
        let fixture = fixture();
        let d = &fixture.descriptor;
        let cancel = AtomicBool::new(false);
        let (_, source_stamp, source_parent) =
            read_verified(&d.source, d.source_count, &d.source_hash, false, &cancel).unwrap();
        let snapshot = crate::read_output::read(&d.file, OUTPUT_LIMIT, true, &cancel).unwrap();
        let original = fs::read(&fixture.output).unwrap();
        fs::rename(&fixture.output, fixture.root.join("verified-original.md")).unwrap();
        fs::write(&fixture.output, &original).unwrap();
        let checked = from_snapshot(
            d,
            SourceVerification::File {
                stamp: source_stamp,
                parent: source_parent,
            },
            snapshot,
            &cancel,
        )
        .unwrap();
        assert!(
            !unchanged(d, &checked),
            "GUI must reject even a same-byte replacement after the verified read"
        );
        assert!(crate::read_output::revalidate(&checked.output_snapshot).is_err());
    }
    #[test]
    fn overlapping_large_mappings_have_bounded_snippets_and_shared_linear_endpoints() {
        let text = "é\n".repeat(4 * 1024 * 1024);
        let mapping = serde_json::json!({"output":{"file":"large.md","utf8Offset":0,"utf8Length":text.len()}});
        let mappings = vec![mapping; POSITION_LIMIT];
        let cancel = AtomicBool::new(false);
        let (positions, limited) = mapped_positions(&text, &mappings, "large.md", &cancel).unwrap();
        assert_eq!(positions.len(), 2048);
        assert!(!limited);
        assert!(positions.iter().all(|p| p.snippet.chars().count() == 70
            && p.snippet.len() <= 280
            && !p.snippet.contains('\n')
            && p.start == 0
            && p.end == 8 * 1024 * 1024));
        assert!(positions.iter().map(|p| p.snippet.len()).sum::<usize>() <= 2048 * 280);
        cancel.store(true, Ordering::Release);
        assert!(mapped_positions(&text, &mappings, "large.md", &cancel).is_err());
    }
    #[test]
    fn output_document_keeps_its_parent_identity_context() {
        let response = serde_json::json!({"input":"/tmp/source.enex","sourceIdentity":{"sha256":"abc"},"documents":[{"markdownFile":"/tmp/output/doc.md","assets":[]}]});
        let file = crate::model::outputs(&response).remove(0);
        assert_eq!(
            file.context.unwrap().get("input").and_then(Value::as_str),
            Some("/tmp/source.enex")
        );
    }
}
