use crate::source_canvas::{SourceCanvas, Zoom};
use crate::{
    Shared, cli_path, label,
    model::{OutputFile, tr},
};
use gtk::{gdk, glib, prelude::*};
use pmt_bridge::{Bridge, Event, JobHandle};
use serde_json::Value;
use std::{
    cell::RefCell,
    ffi::OsString,
    path::PathBuf,
    rc::Rc,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
const PNG_LIMIT: usize = 5 * 1024 * 1024;
type Validation = Rc<RefCell<Option<Box<dyn Fn() -> bool>>>>;
type Navigation = Rc<RefCell<Option<Box<dyn Fn(u32) -> bool>>>>;
static NEXT_JOB: AtomicU64 = AtomicU64::new(1);
#[derive(Debug)]
struct VerifiedPNG {
    bytes: Vec<u8>,
    count: u32,
    width: u32,
    height: u32,
}
fn payload(
    value: &Value,
    kind: &str,
    index: u32,
    hash: &str,
    size: u64,
) -> Result<VerifiedPNG, String> {
    if value.get("operation").and_then(Value::as_str) != Some("source-preview") {
        return Err("Unexpected source preview operation".into());
    }
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) || size > 128 * 1024 * 1024
    {
        return Err("Invalid expected source identity or source size limit".into());
    }
    let p = value.get("preview").ok_or("Missing source preview")?;
    let number = |key: &str| {
        p.get(key)
            .and_then(Value::as_u64)
            .ok_or_else(|| format!("Invalid preview {key}"))
    };
    let identity = p
        .get("sourceIdentity")
        .ok_or("Missing preview source identity")?;
    if identity.get("sha256").and_then(Value::as_str) != Some(hash)
        || identity.get("byteCount").and_then(Value::as_u64) != Some(size)
        || identity.get("memberPath").is_some_and(|v| !v.is_null())
    {
        return Err(tr(
            "Die Quelle hat sich geändert. Das Quellraster bleibt gesperrt.",
            "The source changed. The source raster remains blocked.",
        )
        .into());
    }
    let count = number("count")?;
    let width = number("width")?;
    let height = number("height")?;
    let length = number("byteCount")?;
    if p.get("kind").and_then(Value::as_str) != Some(kind)
        || number("index")? != index as u64
        || !(1..=1000).contains(&count)
        || index == 0
        || index as u64 > count
        || !(1..=1024).contains(&width)
        || !(1..=1024).contains(&height)
        || !(33..=PNG_LIMIT as u64).contains(&length)
    {
        return Err("Invalid preview bounds or source selection".into());
    }
    let encoded = p
        .get("png")
        .and_then(Value::as_str)
        .ok_or("Missing PNG payload")?;
    if encoded.len() != 4 * (length as usize).div_ceil(3)
        || encoded.len() > 4 * PNG_LIMIT.div_ceil(3)
    {
        return Err("Source preview Base64 exceeds its declared bounds".into());
    }
    let bytes = glib::base64_decode(encoded);
    if bytes.len() != length as usize || glib::base64_encode(&bytes).as_str() != encoded {
        return Err("Source preview Base64 is not canonical".into());
    }
    let expected = p
        .get("sha256")
        .and_then(Value::as_str)
        .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
        .ok_or("Missing PNG fingerprint")?;
    let mut sum = glib::Checksum::new(glib::ChecksumType::Sha256).ok_or("SHA256 unavailable")?;
    sum.update(&bytes);
    if sum.string().as_deref() != Some(expected) {
        return Err("Source preview fingerprint mismatch".into());
    }
    if bytes[..8] != [137, 80, 78, 71, 13, 10, 26, 10]
        || bytes[8..16] != [0, 0, 0, 13, 73, 72, 68, 82]
    {
        return Err("Invalid PNG header".into());
    }
    let dimension = |offset| u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap());
    if dimension(16) as u64 != width
        || dimension(20) as u64 != height
        || bytes[24] != 8
        || ![2, 6].contains(&bytes[25])
        || bytes[26..29] != [0, 0, 0]
    {
        return Err("PNG dimensions disagree with preview bounds".into());
    }
    Ok(VerifiedPNG {
        bytes,
        count: count as u32,
        width: width as u32,
        height: height as u32,
    })
}
struct State {
    allowed: bool,
    closing: bool,
    generation: u64,
    active: Option<JobHandle>,
    pending: Option<u32>,
    index: u32,
    count: u32,
    #[cfg(feature = "ui-self-test")]
    test_stage: u8,
    #[cfg(feature = "ui-self-test")]
    original: Option<Vec<u8>>,
}
#[derive(Clone)]
pub(crate) struct Pane {
    pub widget: gtk::Box,
    state: Rc<RefCell<State>>,
    root: Shared,
    root_generation: u64,
    parent: gtk::ApplicationWindow,
    window: gtk::Window,
    source: PathBuf,
    bound_input: crate::model::InputSlot,
    handlers: crate::model::SignalHandlers,
    kind: String,
    hash: String,
    size: u64,
    navigate: Navigation,
    validate: Validation,
    picture: SourceCanvas,
    viewport: gtk::ScrolledWindow,
    zoom_buttons: Vec<gtk::Button>,
    zoom_status: gtk::Label,
    status: gtk::Label,
    counter: gtk::Label,
    previous: gtk::Button,
    next: gtk::Button,
    cancel: gtk::Button,
}
impl Pane {
    pub fn for_file(
        file: &OutputFile,
        root: &Shared,
        parent: &gtk::ApplicationWindow,
        window: &gtk::Window,
    ) -> Option<Self> {
        let context = file.context.as_ref()?;
        let identity = context.get("sourceIdentity")?;
        if identity.get("memberPath").is_some_and(|v| !v.is_null()) {
            return None;
        }
        let source = PathBuf::from(context.get("input")?.as_str()?);
        let extension = source
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let mappings = context.get("sourceMappings").and_then(Value::as_array);
        let kind = if extension == "pdf"
            || mappings.is_some_and(|m| {
                m.iter()
                    .any(|v| v.pointer("/source/page").and_then(Value::as_u64).is_some())
            }) {
            "page"
        } else if [
            "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "webp", "heic",
        ]
        .contains(&extension.as_str())
            || mappings.is_some_and(|m| {
                m.iter()
                    .any(|v| v.pointer("/source/frame").and_then(Value::as_u64).is_some())
            })
        {
            "frame"
        } else {
            return None;
        };
        let hash = identity.get("sha256")?.as_str()?.to_owned();
        let size = identity.get("byteCount")?.as_u64()?;
        let widget = gtk::Box::new(gtk::Orientation::Vertical, 8);
        widget.set_size_request(220, -1);
        widget.append(&label(tr(
            "Quelle · passive Rastervorschau",
            "Source · passive raster preview",
        )));
        let counter = label("—");
        widget.append(&counter);
        let buttons = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .row_spacing(6)
            .column_spacing(6)
            .max_children_per_line(3)
            .build();
        let previous = gtk::Button::with_label(tr("Zurück", "Previous"));
        let next = gtk::Button::with_label(tr("Weiter", "Next"));
        let cancel = gtk::Button::with_label(tr("Abbrechen", "Cancel"));
        for button in [&previous, &next, &cancel] {
            buttons.insert(button, -1);
            button.set_sensitive(false);
        }
        widget.append(&buttons);
        let zoom_controls = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .row_spacing(6)
            .column_spacing(6)
            .min_children_per_line(1)
            .max_children_per_line(2)
            .build();
        let zoom_buttons = vec![
            gtk::Button::with_label(tr("Anpassen", "Fit")),
            gtk::Button::with_label("100%"),
            gtk::Button::with_label("−"),
            gtk::Button::with_label("+"),
        ];
        for (button, title) in zoom_buttons.iter().zip([
            tr("Anpassen", "Fit"),
            tr(
                "Ein Vorschaupixel pro logischem Pixel",
                "One preview pixel per logical pixel",
            ),
            tr("Verkleinern", "Zoom out"),
            tr("Vergrößern", "Zoom in"),
        ]) {
            button.set_tooltip_text(Some(title));
            button.update_property(&[gtk::accessible::Property::Label(title)]);
            button.set_sensitive(false);
        }
        for pair in zoom_buttons.chunks(2) {
            let group = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            group.set_homogeneous(true);
            for button in pair {
                group.append(button);
            }
            zoom_controls.insert(&group, -1);
        }
        widget.append(&zoom_controls);
        let zoom_status = label("—");
        widget.append(&zoom_status);
        let picture = SourceCanvas::new();
        picture.update_property(&[gtk::accessible::Property::Label(tr(
            "Geprüfte Quellseite oder Quellbild",
            "Verified source page or frame",
        ))]);
        let viewport = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Automatic)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .hexpand(true)
            .vexpand(true)
            .child(&picture)
            .build();
        widget.append(&viewport);
        let status = label(tr(
            "Quelle und Ergebnis müssen verifiziert sein.",
            "Source and result must be verified.",
        ));
        widget.append(&status);
        widget.append(&label(tr("PNG-Vorschau: maximal 1024 Pixel je Kante · Zoom vergrößert nur diese Vorschau · ICC/XMP entfernt · Transparenz auf Weiß · keine PDF-Anmerkungen, aktiven Links oder Quellmarkierungen.","Preview PNG: at most 1024 pixels per edge · zoom enlarges this preview only · ICC/XMP removed · transparency on white · no PDF annotations, active links or source-box highlights.")));
        let pane = Self {
            widget,
            state: Rc::new(RefCell::new(State {
                allowed: false,
                closing: false,
                generation: 0,
                active: None,
                pending: None,
                index: 0,
                count: 0,
                #[cfg(feature = "ui-self-test")]
                test_stage: if std::env::var_os("PMT_UI_TEST_RASTER").is_some() {
                    0
                } else {
                    255
                },
                #[cfg(feature = "ui-self-test")]
                original: None,
            })),
            root: root.clone(),
            root_generation: root.borrow().generation,
            parent: parent.clone(),
            window: window.clone(),
            source,
            bound_input: crate::model::InputSlot::new(file.bound_input.clone()),
            handlers: crate::model::SignalHandlers::default(),
            kind: kind.into(),
            hash,
            size,
            navigate: Rc::new(RefCell::new(None)),
            validate: Rc::new(RefCell::new(None)),
            picture,
            viewport,
            zoom_buttons,
            zoom_status,
            status,
            counter,
            previous,
            next,
            cancel,
        };
        {
            let pane = pane.clone();
            let pane_original_handlers = pane.handlers.clone();
            let button = pane.previous.clone();
            let id = button.connect_clicked(move |_| {
                let index = pane.state.borrow().index;
                if index > 1 {
                    pane.navigate_to(index - 1);
                }
            });
            pane_original_handlers
                .borrow_mut()
                .push((button.upcast(), id));
        }
        {
            let pane = pane.clone();
            let pane_original_handlers = pane.handlers.clone();
            let button = pane.next.clone();
            let id = button.connect_clicked(move |_| {
                let s = pane.state.borrow();
                let index = s.index + 1;
                let count = s.count;
                drop(s);
                if index <= count {
                    pane.navigate_to(index);
                }
            });
            pane_original_handlers
                .borrow_mut()
                .push((button.upcast(), id));
        }
        {
            let pane = pane.clone();
            let handlers = pane.handlers.clone();
            let button = pane.cancel.clone();
            let id = button.connect_clicked(move |_| pane.invalidate());
            handlers.borrow_mut().push((button.upcast(), id));
        }
        for (index, button) in pane.zoom_buttons.iter().enumerate() {
            let owned = pane.clone();
            let id = button.connect_clicked(move |_| {
                if owned.picture.texture().is_none() {
                    return;
                }
                let scale = match owned.picture.zoom() {
                    Zoom::Scale(value) => value,
                    Zoom::Fit => {
                        let texture = owned.picture.texture().unwrap();
                        (owned.viewport.hadjustment().page_size() / f64::from(texture.width())).min(
                            owned.viewport.vadjustment().page_size() / f64::from(texture.height()),
                        )
                    }
                };
                let zoom = match index {
                    0 => Zoom::Fit,
                    1 => Zoom::Scale(1.0),
                    2 if scale <= 0.25 => return,
                    3 if scale >= 4.0 => return,
                    2 => Zoom::Scale(scale / 1.25),
                    _ => Zoom::Scale(scale * 1.25),
                };
                owned.picture.set_zoom(zoom);
                owned.viewport.hadjustment().set_value(0.0);
                owned.viewport.vadjustment().set_value(0.0);
                owned.zoom_status.set_text(&match owned.picture.zoom() {
                    Zoom::Fit => tr("Zoom · Anpassen", "Zoom · Fit").into(),
                    Zoom::Scale(v) => format!("Zoom · {:.0}%", v * 100.0),
                });
            });
            pane.handlers
                .borrow_mut()
                .push((button.clone().upcast(), id));
        }
        {
            let pane = pane.clone();
            glib::timeout_add_local(Duration::from_millis(100), move || {
                if !pane.window.is_visible() || pane.state.borrow().closing {
                    return glib::ControlFlow::Break;
                }
                if pane.root.borrow().generation != pane.root_generation {
                    pane.invalidate();
                    return glib::ControlFlow::Break;
                }
                if pane.state.borrow().pending.is_some()
                    && pane.state.borrow().active.is_none()
                    && !pane.root.borrow().is_busy()
                {
                    pane.start_pending();
                }
                glib::ControlFlow::Continue
            });
        }
        {
            let input = pane.bound_input.clone();
            pane.window.connect_destroy(move |_| input.clear());
        }
        Some(pane)
    }
    pub fn set_validation(&self, handler: impl Fn() -> bool + 'static) {
        *self.validate.borrow_mut() = Some(Box::new(handler));
    }
    pub fn set_navigation(&self, handler: impl Fn(u32) -> bool + 'static) {
        *self.navigate.borrow_mut() = Some(Box::new(handler));
    }
    fn navigate_to(&self, index: u32) {
        if !self
            .navigate
            .borrow()
            .as_ref()
            .is_some_and(|handler| handler(index))
        {
            self.request(index);
        }
    }
    pub fn is_page(&self) -> bool {
        self.kind == "page"
    }
    pub fn mapping_index(&self, page: Option<u32>, frame: Option<u32>) -> Option<u32> {
        if self.kind == "page" { page } else { frame }
    }
    pub fn verified_for(&self, page: Option<u32>, frame: Option<u32>) {
        if let Some(index) = self.mapping_index(page, frame) {
            if self.state.borrow().closing {
                return;
            }
            self.state.borrow_mut().allowed = true;
            if self.state.borrow().index != index {
                self.request(index);
            }
        } else {
            self.verified();
        }
    }
    pub fn invalidate(&self) {
        let mut s = self.state.borrow_mut();
        s.allowed = false;
        s.generation += 1;
        s.pending = None;
        s.index = 0;
        if let Some(job) = &s.active {
            job.cancel();
        }
        self.picture.set_texture(None);
        for button in &self.zoom_buttons {
            button.set_sensitive(false);
        }
        self.zoom_status.set_text("—");
        self.previous.set_sensitive(false);
        self.next.set_sensitive(false);
        self.cancel.set_sensitive(s.active.is_some());
        self.status.set_text(tr(
            "Quellraster gesperrt · erneut prüfen.",
            "Source raster blocked · recheck.",
        ));
    }
    pub fn verified(&self) {
        if self.state.borrow().closing {
            return;
        }
        self.state.borrow_mut().allowed = true;
        if self.state.borrow().index == 0 {
            self.request(1);
        }
    }
    pub fn close_when_idle(&self) -> bool {
        self.bound_input.clear();
        self.navigate.borrow_mut().take();
        self.validate.borrow_mut().take();
        self.state.borrow_mut().closing = true;
        self.invalidate();
        #[cfg(feature = "ui-self-test")]
        {
            self.state.borrow_mut().original = None;
        }
        let idle = self.state.borrow().active.is_none();
        if idle {
            crate::model::disconnect_handlers(&self.handlers);
        }
        #[cfg(feature = "ui-self-test")]
        if idle && std::env::var_os("PMT_UI_TEST_BOUND_ERROR").is_some() {
            assert!(self.picture.texture().is_none());
            let window = self.window.downgrade();
            let canvas = self.picture.downgrade();
            glib::timeout_add_local_once(Duration::from_millis(350), move || {
                assert!(window.upgrade().is_none());
                assert!(canvas.upgrade().is_none());
                eprintln!(
                    "PMT_UI_TEST_BOUND_ERROR_CANVAS_RELEASE window-canvas-dropped-no-texture"
                );
            });
        }
        idle
    }
    fn request(&self, index: u32) {
        {
            let mut s = self.state.borrow_mut();
            if !s.allowed || s.closing {
                return;
            }
            s.generation += 1;
            s.pending = Some(index);
            if let Some(job) = &s.active {
                job.cancel();
                return;
            }
        }
        self.start_pending();
    }
    fn start_pending(&self) {
        let stale = {
            let root = self.root.borrow();
            root.closing || root.generation != self.root_generation
        };
        if stale {
            self.invalidate();
            self.status.set_text(tr(
                "Quellenauswahl geändert. Den Vergleich erneut öffnen.",
                "Source selection changed. Reopen the comparison.",
            ));
            return;
        }
        if self.root.borrow().is_busy() {
            return;
        }
        let (index, generation) = {
            let mut s = self.state.borrow_mut();
            if !s.allowed || s.closing || s.active.is_some() {
                return;
            }
            let Some(index) = s.pending.take() else {
                return;
            };
            (index, s.generation)
        };
        let bridge = Bridge::new(cli_path());
        let bridge = if let Some(path) = std::env::var_os("PMT_PROCESS_GUARD") {
            bridge.with_guard(PathBuf::from(path))
        } else {
            bridge
        };
        let bridge = if self.bound_input.is_bound() {
            let Some(input) = self.bound_input.get() else {
                self.invalidate();
                self.status.set_text("Clipboard source was released");
                return;
            };
            bridge.with_input(input)
        } else {
            bridge
        };
        let job = bridge.start_operation(vec![
            OsString::from(if self.kind == "page" {
                "--preview-page"
            } else {
                "--preview-frame"
            }),
            index.to_string().into(),
            "--".into(),
            self.source.as_os_str().to_owned(),
        ]);
        let id = NEXT_JOB.fetch_add(1, Ordering::Relaxed);
        self.root
            .borrow_mut()
            .raster_jobs
            .push((id, job.handle.clone()));
        self.state.borrow_mut().active = Some(job.handle);
        self.picture.set_texture(None);
        for button in &self.zoom_buttons {
            button.set_sensitive(false);
        }
        self.zoom_status.set_text("—");
        self.previous.set_sensitive(false);
        self.next.set_sensitive(false);
        self.cancel.set_sensitive(true);
        self.status
            .set_text(tr("Quellraster wird geprüft…", "Verifying source raster…"));
        let pane = self.clone();
        glib::timeout_add_local(Duration::from_millis(25), move || {
            if pane.root.borrow().generation != pane.root_generation || pane.root.borrow().closing {
                pane.invalidate();
            }
            loop {
                match job.events.try_recv() {
                    Ok(Event::ProgressText(_)) => {}
                    Ok(Event::Finished(result)) => {
                        pane.root
                            .borrow_mut()
                            .raster_jobs
                            .retain(|(key, _)| *key != id);
                        let apply = {
                            let mut s = pane.state.borrow_mut();
                            s.active = None;
                            s.generation == generation && s.allowed && !s.closing
                        };
                        pane.cancel.set_sensitive(false);
                        if apply {
                            let checked = if pane
                                .validate
                                .borrow()
                                .as_ref()
                                .is_some_and(|verify| verify())
                            {
                                result.map_err(|e| e.to_string()).and_then(|v| {
                                    payload(&v, &pane.kind, index, &pane.hash, pane.size)
                                })
                            } else {
                                Err(tr(
                                    "Quelle oder Ergebnis während der Rasterprüfung geändert.",
                                    "Source or result changed during raster verification.",
                                )
                                .into())
                            };
                            match checked {
                                Ok(checked) => {
                                    let texture = gdk::Texture::from_bytes(
                                        &glib::Bytes::from_owned(checked.bytes),
                                    );
                                    match texture {
                                        Ok(texture)
                                            if texture.width() == checked.width as i32
                                                && texture.height() == checked.height as i32 =>
                                        {
                                            pane.picture.set_texture(Some(&texture));
                                            for button in &pane.zoom_buttons {
                                                button.set_sensitive(true);
                                            }
                                            pane.zoom_status
                                                .set_text(tr("Zoom · Anpassen", "Zoom · Fit"));
                                            pane.viewport.hadjustment().set_value(0.0);
                                            pane.viewport.vadjustment().set_value(0.0);
                                            let mut s = pane.state.borrow_mut();
                                            s.index = index;
                                            s.count = checked.count;
                                            pane.counter.set_text(&format!(
                                                "{} {index}/{} · {}×{}",
                                                if pane.kind == "page" {
                                                    tr("Seite", "Page")
                                                } else {
                                                    tr("Bild", "Frame")
                                                },
                                                checked.count,
                                                checked.width,
                                                checked.height
                                            ));
                                            pane.previous.set_sensitive(index > 1);
                                            pane.next.set_sensitive(index < checked.count);
                                            pane.status.set_text(tr("Quellbytes stimmen mit dem Vergleichsbeleg überein.","Source bytes match the comparison identity."));
                                        }
                                        Ok(_) => pane
                                            .status
                                            .set_text("Decoded preview dimensions changed"),
                                        Err(e) => pane.status.set_text(&e.to_string()),
                                    }
                                }
                                Err(e) => pane.status.set_text(&e),
                            }
                        }
                        #[cfg(feature = "ui-self-test")]
                        pane.test_finished(index, apply && pane.picture.texture().is_some());
                        let closing = pane.state.borrow().closing;
                        if closing {
                            pane.window.close();
                        } else {
                            pane.start_pending();
                        }
                        if pane.root.borrow().closing && !pane.root.borrow().is_busy() {
                            pane.parent.close();
                        }
                        return glib::ControlFlow::Break;
                    }
                    Err(std::sync::mpsc::TryRecvError::Empty) => {
                        return glib::ControlFlow::Continue;
                    }
                    Err(_) => {
                        pane.root
                            .borrow_mut()
                            .raster_jobs
                            .retain(|(key, _)| *key != id);
                        pane.state.borrow_mut().active = None;
                        pane.status
                            .set_text("Source preview process connection ended without a result");
                        if pane.state.borrow().closing {
                            pane.window.close();
                        }
                        if pane.root.borrow().closing && !pane.root.borrow().is_busy() {
                            pane.parent.close();
                        }
                        return glib::ControlFlow::Break;
                    }
                }
            }
        });
    }
}

#[cfg(feature = "ui-self-test")]
impl Pane {
    fn test_zoom(&self) {
        let pane = self.clone();
        let texture = self.picture.texture().unwrap();
        let generation = self.state.borrow().generation;
        let mut step = 0;
        self.window.set_default_size(1100, 850);
        glib::timeout_add_local(Duration::from_millis(700), move || {
            assert_eq!(
                pane.state.borrow().generation,
                generation,
                "zoom started a preview request"
            );
            assert!(
                pane.state.borrow().active.is_none() && pane.root.borrow().raster_jobs.is_empty()
            );
            assert_eq!(pane.picture.texture().as_ref(), Some(&texture));
            match step {
                0 => pane.zoom_buttons[0].emit_clicked(),
                2 => pane.zoom_buttons[1].emit_clicked(),
                4 => {
                    for _ in 0..20 {
                        pane.zoom_buttons[3].emit_clicked();
                    }
                }
                6 => {
                    let h = pane.viewport.hadjustment();
                    let v = pane.viewport.vadjustment();
                    h.set_value(h.upper() - h.page_size());
                    v.set_value(v.upper() - v.page_size());
                }
                8 => {
                    pane.window.set_default_size(700, 700);
                }
                10 => {
                    for _ in 0..30 {
                        pane.zoom_buttons[2].emit_clicked();
                    }
                }
                12 => {
                    pane.zoom_buttons[0].emit_clicked();
                }
                14 => {
                    pane.window.set_default_size(1200, 900);
                }
                16 => {
                    let weak_window = pane.window.downgrade();
                    let weak_canvas = pane.picture.downgrade();
                    let weak_texture = texture.downgrade();
                    let parent = pane.parent.clone();
                    pane.window.close();
                    glib::timeout_add_local_once(Duration::from_millis(500), move || {
                        assert!(parent.is_visible());
                        assert!(weak_window.upgrade().is_none());
                        assert!(weak_canvas.upgrade().is_none());
                        assert!(weak_texture.upgrade().is_none());
                        eprintln!("PMT_UI_TEST_ZOOM_RELEASE window-canvas-texture-dropped");
                        parent.close();
                    });
                    return glib::ControlFlow::Break;
                }
                _ => {
                    let (x, y, w, h) = pane.picture.rectangle();
                    let cw = f64::from(pane.picture.width());
                    let ch = f64::from(pane.picture.height());
                    assert!(cw > 0.0 && ch > 0.0 && x >= -0.01 && y >= -0.01);
                    let zoom = pane.picture.zoom();
                    match zoom {
                        Zoom::Fit => {
                            assert!(x + w <= cw + 0.01 && y + h <= ch + 0.01);
                            assert!(
                                (w / h - f64::from(texture.width()) / f64::from(texture.height()))
                                    .abs()
                                    < 0.0001
                            );
                        }
                        Zoom::Scale(scale) => {
                            assert!((w - f64::from(texture.width()) * scale).abs() < 0.01);
                            assert!((h - f64::from(texture.height()) * scale).abs() < 0.01);
                        }
                    }
                    if step == 3 {
                        assert_eq!(zoom, Zoom::Scale(1.0));
                    }
                    if step == 5 {
                        assert_eq!(zoom, Zoom::Scale(4.0));
                        assert!(
                            pane.viewport.hadjustment().upper()
                                > pane.viewport.hadjustment().page_size()
                        );
                    }
                    if step == 7 {
                        assert!(
                            pane.viewport.hadjustment().value() > 0.0
                                && pane.viewport.vadjustment().value() > 0.0
                        );
                    }
                    if step == 9 {
                        assert_eq!(zoom, Zoom::Scale(4.0));
                        assert!(pane.window.width() <= 710);
                        assert!(
                            pane.viewport.hadjustment().value()
                                <= pane.viewport.hadjustment().upper()
                                    - pane.viewport.hadjustment().page_size()
                        );
                    }
                    if step == 11 {
                        assert_eq!(zoom, Zoom::Scale(0.25));
                    }
                    if step == 13 {
                        if w / f64::from(texture.width()) < 0.25 {
                            pane.zoom_buttons[2].emit_clicked();
                            assert_eq!(
                                pane.picture.zoom(),
                                Zoom::Fit,
                                "zoom out must not enlarge a small fitted preview"
                            );
                        }
                        assert!(
                            pane.window.width() <= 710,
                            "narrow comparison did not shrink: {}",
                            pane.window.width()
                        );
                        assert_eq!(pane.viewport.hadjustment().value(), 0.0);
                        assert_eq!(pane.viewport.vadjustment().value(), 0.0);
                    }
                    eprintln!(
                        "PMT_UI_TEST_ZOOM_STAGE {step} window={}x{} canvas={}x{} rect={x},{y},{w},{h} scroll={},{} zoom={zoom:?} device={}",
                        pane.window.width(),
                        pane.window.height(),
                        pane.picture.width(),
                        pane.picture.height(),
                        pane.viewport.hadjustment().value(),
                        pane.viewport.vadjustment().value(),
                        pane.picture.scale_factor()
                    );
                }
            }
            step += 1;
            glib::ControlFlow::Continue
        });
    }
    fn test_finished(&self, index: u32, displayed: bool) {
        if std::env::var_os("PMT_UI_TEST_RASTER_ZOOM").is_some() {
            if displayed && self.state.borrow().test_stage == 0 {
                self.state.borrow_mut().test_stage = 255;
                self.test_zoom();
            }
            return;
        }
        if self.bound_input.is_bound() && std::env::var_os("PMT_UI_TEST_BOUND_SOURCE").is_some() {
            if displayed && std::env::var_os("PMT_UI_TEST_BOUND_RELEASE").is_some() {
                use std::os::unix::fs::MetadataExt;
                let identity = {
                    let input = self.bound_input.get().unwrap();
                    let file = input.reader().unwrap();
                    let m = file.metadata().unwrap();
                    (m.dev(), m.ino())
                };
                let weak_window = self.window.downgrade();
                let weak_texture = self.picture.texture().unwrap().downgrade();
                let weak_canvas = self.picture.downgrade();
                let before = std::fs::read_dir("/proc/self/fd")
                    .unwrap()
                    .filter_map(Result::ok)
                    .filter_map(|e| std::fs::metadata(e.path()).ok())
                    .filter(|m| (m.dev(), m.ino()) == identity)
                    .count();
                assert!(before >= 1);
                eprintln!("PMT_UI_TEST_BOUND_FD_BASELINE {before}");
                let clear = self
                    .root
                    .borrow_mut()
                    .test_clear
                    .take()
                    .expect("source-clear test callback");
                clear();
                self.window.close();
                let parent = self.parent.clone();
                glib::timeout_add_local_once(Duration::from_millis(350), move || {
                    assert!(
                        parent.is_visible(),
                        "release must be checked with the app still open"
                    );
                    let count = std::fs::read_dir("/proc/self/fd")
                        .unwrap()
                        .filter_map(Result::ok)
                        .filter_map(|entry| std::fs::metadata(entry.path()).ok())
                        .filter(|m| (m.dev(), m.ino()) == identity)
                        .count();
                    assert_eq!(count, 0, "closed comparison still retains sealed input FDs");
                    assert!(
                        weak_window.upgrade().is_none(),
                        "closed comparison still has widget reference cycles"
                    );
                    assert!(
                        weak_canvas.upgrade().is_none(),
                        "closed comparison retained its raster canvas"
                    );
                    assert!(
                        weak_texture.upgrade().is_none(),
                        "closed comparison retained its raster texture"
                    );
                    eprintln!("PMT_UI_TEST_BOUND_WIDGET_RELEASE window-and-texture-dropped");
                    eprintln!("PMT_UI_TEST_BOUND_RELEASE_COMPLETE app-open-source-cleared-fds=0");
                    parent.close();
                });
                return;
            }
            if self.root.borrow().closing {
                assert!(!displayed, "cancelled bound preview committed stale pixels");
                eprintln!("PMT_UI_TEST_BOUND_CANCEL_COMPLETE cleanup-no-stale-texture");
                return;
            }
            assert!(displayed, "bound raster failed: {}", self.status.text());
            if std::env::var_os("PMT_UI_TEST_BOUND_CLOSE").is_some() {
                self.request(2);
                self.parent.close();
                return;
            }

            if self.state.borrow().count > 1 && index == 1 {
                self.request(2);
                return;
            }
            eprintln!("PMT_UI_TEST_BOUND_RASTER_COMPLETE original-frame-valid-hash index={index}");
            let parent = self.parent.clone();
            let delay = std::env::var("PMT_UI_TEST_BOUND_PAUSE_MS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0)
                .min(5000);
            glib::timeout_add_local_once(Duration::from_millis(delay), move || parent.close());
            return;
        }

        let stage = self.state.borrow().test_stage;
        if stage == 0 && displayed && index == 1 {
            eprintln!("PMT_UI_TEST_RASTER_FIRST real-texture");
            if std::env::var_os("PMT_UI_TEST_RASTER_CLOSE").is_some() {
                self.state.borrow_mut().test_stage = 20;
                self.request(2);
                self.parent.close();
            } else {
                self.state.borrow_mut().test_stage = 1;
                self.request(2);
                self.invalidate();
            }
        } else if stage == 1 {
            assert!(!displayed);
            assert!(self.picture.texture().is_none());
            assert!(self.root.borrow().raster_jobs.is_empty());
            eprintln!("PMT_UI_TEST_RASTER_CANCEL cleanup-barrier-no-stale-texture");
            self.state.borrow_mut().test_stage = 2;
            self.verified();
        } else if stage == 2 && displayed && index == 1 {
            self.state.borrow_mut().test_stage = 3;
            self.next.emit_clicked();
        } else if stage == 3 && displayed && index == 2 {
            assert_eq!(self.state.borrow().index, 2);
            eprintln!("PMT_UI_TEST_RASTER_SECOND real-page2-texture");
            self.state.borrow_mut().test_stage = 4;
            let pane = self.clone();
            glib::timeout_add_local_once(Duration::from_secs(4), move || {
                let original = std::fs::read(&pane.source).unwrap();
                let mut changed = original.clone();
                changed.push(b'\n');
                std::fs::write(&pane.source, changed).unwrap();
                pane.state.borrow_mut().original = Some(original);
                pane.request(1);
            });
        } else if stage == 4 {
            assert!(!displayed);
            assert!(self.picture.texture().is_none());
            assert!(self.root.borrow().raster_jobs.is_empty());
            let original = self.state.borrow_mut().original.take().unwrap();
            std::fs::write(&self.source, original).unwrap();
            self.state.borrow_mut().test_stage = 5;
            eprintln!("PMT_UI_TEST_RASTER_CHANGED source-change-rejected-before-texture");
            eprintln!("PMT_UI_TEST_RASTER_COMPLETE");
            self.window.close();
            self.parent.close();
        } else if stage == 20 {
            assert!(!displayed);
            assert!(self.root.borrow().raster_jobs.is_empty());
            eprintln!("PMT_UI_TEST_RASTER_CLOSE cleanup-before-main-close");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Value {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAFElEQVR4nGNkYPjPwMDAxAAGUAoAEkIBBYa3P50AAAAASUVORK5CYII=";
        let data = glib::base64_decode(png);
        let mut sum = glib::Checksum::new(glib::ChecksumType::Sha256).unwrap();
        sum.update(&data);
        serde_json::json!({"operation":"source-preview","preview":{"sourceIdentity":{"sha256":"1111111111111111111111111111111111111111111111111111111111111111","byteCount":10},"kind":"frame","index":2,"count":3,"width":2,"height":3,"png":png,"byteCount":data.len(),"sha256":sum.string().unwrap()}})
    }
    #[test]
    fn accepts_bounded_canonical_verified_png_payload() {
        let p = payload(
            &fixture(),
            "frame",
            2,
            "1111111111111111111111111111111111111111111111111111111111111111",
            10,
        )
        .unwrap();
        assert_eq!((p.width, p.height, p.count), (2, 3, 3));
    }
    #[test]
    fn changed_source_is_rejected_before_any_png_decode() {
        let mut v = fixture();
        v["preview"]["png"] = Value::Null;
        assert!(
            payload(
                &v,
                "frame",
                2,
                "2222222222222222222222222222222222222222222222222222222222222222",
                10
            )
            .unwrap_err()
            .contains("source")
                || payload(
                    &v,
                    "frame",
                    2,
                    "2222222222222222222222222222222222222222222222222222222222222222",
                    10
                )
                .unwrap_err()
                .contains("Quelle")
        );
    }
    #[test]
    fn incorrect_selection_hash_and_bytecount_are_rejected() {
        for key in ["index", "count", "byteCount"] {
            let mut v = fixture();
            v["preview"][key] = serde_json::json!(0);
            assert!(
                payload(
                    &v,
                    "frame",
                    2,
                    "1111111111111111111111111111111111111111111111111111111111111111",
                    10
                )
                .is_err()
            );
        }
        let mut v = fixture();
        v["preview"]["sha256"] = serde_json::json!("0".repeat(64));
        assert!(
            payload(
                &v,
                "frame",
                2,
                "1111111111111111111111111111111111111111111111111111111111111111",
                10
            )
            .is_err()
        );
    }
    #[test]
    fn oversized_dimensions_and_payload_are_rejected_before_texture_decode() {
        let mut v = fixture();
        v["preview"]["width"] = serde_json::json!(1025);
        assert!(
            payload(
                &v,
                "frame",
                2,
                "1111111111111111111111111111111111111111111111111111111111111111",
                10
            )
            .is_err()
        );
        v = fixture();
        v["preview"]["byteCount"] = serde_json::json!(PNG_LIMIT + 1);
        assert!(
            payload(
                &v,
                "frame",
                2,
                "1111111111111111111111111111111111111111111111111111111111111111",
                10
            )
            .is_err()
        );
    }
    #[test]
    fn noncanonical_base64_and_ihdr_mismatch_are_rejected() {
        let mut v = fixture();
        let mut encoded = v["preview"]["png"].as_str().unwrap().to_owned();
        encoded.replace_range(0..1, " ");
        v["preview"]["png"] = serde_json::json!(encoded);
        assert!(
            payload(
                &v,
                "frame",
                2,
                "1111111111111111111111111111111111111111111111111111111111111111",
                10
            )
            .is_err()
        );
        v = fixture();
        v["preview"]["width"] = serde_json::json!(1);
        assert!(
            payload(
                &v,
                "frame",
                2,
                "1111111111111111111111111111111111111111111111111111111111111111",
                10
            )
            .is_err()
        );
    }
}
