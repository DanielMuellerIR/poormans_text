use crate::model::tr;
use gtk::{gdk, gio, glib, prelude::*};
use pmt_bridge::{BoundInput, InputName};
#[cfg(any(test, feature = "ui-self-test"))]
use std::fs;
#[cfg(any(test, feature = "ui-self-test"))]
use std::io::Read;
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

pub const MAXIMUM_BYTES: usize = 64 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub mime: String,
    pub extension: &'static str,
}
impl Offer {
    pub fn new(mime: &str) -> Option<Self> {
        let extension = match mime.split(';').next()?.trim().to_ascii_lowercase().as_str() {
            "text/html" => "html",
            "application/rtf" | "text/rtf" => "rtf",
            "image/png" => "png",
            "image/jpeg" => "jpg",
            "image/gif" => "gif",
            "image/tiff" => "tiff",
            "image/bmp" | "image/x-bmp" | "image/x-ms-bmp" => "bmp",
            "image/webp" => "webp",
            "image/heic" => "heic",
            _ => return None,
        };
        Some(Self {
            mime: mime.into(),
            extension,
        })
    }
}
pub fn offers(clipboard: &gdk::Clipboard) -> Vec<Offer> {
    clipboard
        .formats()
        .mime_types()
        .iter()
        .filter_map(|mime| Offer::new(mime))
        .collect()
}

#[derive(Debug)]
pub struct Source {
    pub binding: BoundInput,
    path: PathBuf,
    pub mime: String,
}
impl Source {
    pub fn path(&self) -> &Path {
        &self.path
    }
    fn stage(data: &[u8], offer: &Offer) -> Result<Self, String> {
        let name =
            InputName::new(&format!("clipboard.{}", offer.extension)).map_err(|e| e.to_string())?;
        let binding = BoundInput::new(data, name).map_err(|e| e.to_string())?;
        Ok(Self {
            path: binding.path(),
            binding,
            mime: offer.mime.clone(),
        })
    }
    #[cfg(any(test, feature = "ui-self-test"))]
    pub fn bytes(&self) -> Result<Vec<u8>, String> {
        let mut data = Vec::new();
        self.binding
            .reader()
            .map_err(|e| e.to_string())?
            .read_to_end(&mut data)
            .map_err(|e| e.to_string())?;
        Ok(data)
    }
}
#[derive(Clone)]
pub struct ReadHandle {
    cancel: gio::Cancellable,
    cancelled: Arc<AtomicBool>,
}
impl ReadHandle {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.cancel.cancel();
    }
}
type Completion = Box<dyn FnOnce(Result<Source, String>)>;

pub fn read(
    clipboard: &gdk::Clipboard,
    offer: Offer,
    done: impl FnOnce(Result<Source, String>) + 'static,
) -> ReadHandle {
    read_with_limit(clipboard, offer, MAXIMUM_BYTES, Box::new(done))
}
fn read_with_limit(
    clipboard: &gdk::Clipboard,
    offer: Offer,
    limit: usize,
    done: Completion,
) -> ReadHandle {
    let handle = ReadHandle {
        cancel: gio::Cancellable::new(),
        cancelled: Arc::new(AtomicBool::new(false)),
    };
    let finished = Arc::new(AtomicBool::new(false));
    let completed = finished.clone();
    let done: Completion = Box::new(move |result| {
        completed.store(true, Ordering::Release);
        done(result);
    });
    let timeout = handle.clone();
    glib::timeout_add_local_once(Duration::from_secs(30), move || {
        if !finished.load(Ordering::Acquire) {
            timeout.cancel();
        }
    });
    let task = handle.clone();
    let mime = offer.mime.clone();
    clipboard.read_async(
        &[&mime],
        glib::Priority::DEFAULT,
        Some(&handle.cancel),
        move |result| match result {
            Ok((stream, actual)) if actual.as_str() == offer.mime => {
                read_next(stream, Vec::new(), offer, limit, task, done)
            }
            Ok(_) => done(Err(tr(
                "Die Zwischenablage lieferte eine andere Kodierung.",
                "The clipboard returned a different encoding.",
            )
            .into())),
            Err(error) => done(Err(error.to_string())),
        },
    );
    handle
}
fn read_next(
    stream: gio::InputStream,
    mut data: Vec<u8>,
    offer: Offer,
    limit: usize,
    task: ReadHandle,
    done: Completion,
) {
    let next = stream.clone();
    let cancel = task.cancel.clone();
    stream.read_bytes_async(
        64 * 1024,
        glib::Priority::DEFAULT,
        Some(&cancel),
        move |result| {
            if task.cancelled.load(Ordering::Acquire) {
                done(Err(tr(
                    "Zwischenablage-Lesen abgebrochen.",
                    "Clipboard read cancelled.",
                )
                .into()));
                return;
            }
            match result {
                Ok(bytes) if bytes.is_empty() => stage_async(data, offer, task.cancelled, done),
                Ok(bytes) => {
                    if bytes.len() > limit.saturating_sub(data.len()) {
                        done(Err(tr(
                            "Die Zwischenablage überschreitet 64 MiB.",
                            "Clipboard content exceeds 64 MiB.",
                        )
                        .into()));
                        return;
                    }
                    data.extend_from_slice(&bytes);
                    read_next(next, data, offer, limit, task, done);
                }
                Err(error) => done(Err(error.to_string())),
            }
        },
    );
}
fn stage_async(data: Vec<u8>, offer: Offer, cancelled: Arc<AtomicBool>, done: Completion) {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut result = if cancelled.load(Ordering::Acquire) {
            Err("Clipboard read cancelled.".into())
        } else {
            Source::stage(&data, &offer)
        };
        if cancelled.load(Ordering::Acquire) {
            result = Err("Clipboard read cancelled.".into());
        }
        let _ = sender.send(result);
    });
    let mut done = Some(done);
    glib::timeout_add_local(Duration::from_millis(20), move || {
        match receiver.try_recv() {
            Ok(result) => {
                if let Some(done) = done.take() {
                    done(result);
                }
                glib::ControlFlow::Break
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => glib::ControlFlow::Continue,
            Err(_) => {
                if let Some(done) = done.take() {
                    done(Err("Clipboard worker ended without a source.".into()));
                }
                glib::ControlFlow::Break
            }
        }
    });
}

#[cfg(feature = "ui-self-test")]
pub fn self_test(
    clipboard: &gdk::Clipboard,
    fixtures: &Path,
    done: impl FnOnce(Result<(), String>) + 'static,
) {
    use std::{cell::RefCell, rc::Rc};
    let records = [
        ("image/png", "png"),
        ("image/jpeg", "jpg"),
        ("image/gif", "gif"),
        ("image/tiff", "tiff"),
        ("image/bmp", "bmp"),
        ("image/webp", "webp"),
        ("image/heic", "heic"),
        ("text/html", "html"),
        ("application/rtf", "rtf"),
    ]
    .into_iter()
    .map(|(mime, ext)| {
        fs::read(fixtures.join(format!("source.{ext}")))
            .map(|data| (Offer::new(mime).unwrap(), data))
    })
    .collect::<Result<Vec<_>, _>>();
    let records = match records {
        Ok(records) => Rc::new(records),
        Err(error) => {
            done(Err(error.to_string()));
            return;
        }
    };
    let providers = records
        .iter()
        .map(|(offer, data)| {
            gdk::ContentProvider::for_bytes(&offer.mime, &glib::Bytes::from_owned(data.clone()))
        })
        .collect::<Vec<_>>();
    if let Err(error) = clipboard.set_content(Some(&gdk::ContentProvider::new_union(&providers))) {
        done(Err(error.to_string()));
        return;
    }
    type Done = Rc<RefCell<Option<Box<dyn FnOnce(Result<(), String>)>>>>;
    fn next(
        clipboard: gdk::Clipboard,
        records: Rc<Vec<(Offer, Vec<u8>)>>,
        index: usize,
        done: Done,
    ) {
        if index == records.len() {
            limit_probe(clipboard, done);
            return;
        }
        let (offer, expected) = records[index].clone();
        let next_clipboard = clipboard.clone();
        read(&clipboard, offer.clone(), move |result| {
            let checked = result.and_then(|source| {
                if source.bytes()? != expected {
                    return Err("Clipboard bytes changed".into());
                }
                if source.path().extension().and_then(|s| s.to_str()) != Some(offer.extension) {
                    return Err("Clipboard extension changed".into());
                }
                drop(source);
                eprintln!(
                    "PMT_UI_TEST_CLIPBOARD_ENCODING {} exact-bytes-sealed-no-host-file",
                    offer.mime
                );
                Ok(())
            });
            if let Err(error) = checked {
                if let Some(done) = done.borrow_mut().take() {
                    done(Err(error));
                }
            } else {
                next(next_clipboard, records, index + 1, done);
            }
        });
    }
    fn limit_probe(clipboard: gdk::Clipboard, done: Done) {
        let provider = gdk::ContentProvider::for_bytes(
            "application/rtf",
            &glib::Bytes::from_owned(vec![42u8; MAXIMUM_BYTES + 1]),
        );
        if let Err(error) = clipboard.set_content(Some(&provider)) {
            if let Some(done) = done.borrow_mut().take() {
                done(Err(error.to_string()));
            }
            return;
        }
        let next_clipboard = clipboard.clone();
        read(
            &clipboard,
            Offer::new("application/rtf").unwrap(),
            move |result| {
                if !result
                    .as_ref()
                    .err()
                    .is_some_and(|error| error.contains("64 MiB"))
                {
                    if let Some(done) = done.borrow_mut().take() {
                        done(Err(format!("64MiB limit not proved: {result:?}")));
                    }
                    return;
                }
                eprintln!("PMT_UI_TEST_CLIPBOARD_LIMIT 64MiB-rejected");
                next_clipboard
                    .set_content(Some(&gdk::ContentProvider::for_bytes(
                        "application/rtf",
                        &glib::Bytes::from_static(b"{\\rtf1 CANCELLATION_FIXTURE}"),
                    )))
                    .unwrap();
                let cancel = read(
                    &next_clipboard,
                    Offer::new("application/rtf").unwrap(),
                    move |result| {
                        if let Some(done) = done.borrow_mut().take() {
                            done(if result.is_err() {
                                eprintln!("PMT_UI_TEST_CLIPBOARD_CANCEL cancelled-and-cleaned");
                                Ok(())
                            } else {
                                Err("Clipboard cancellation was ignored".into())
                            });
                        }
                    },
                );
                cancel.cancel();
            },
        );
    }
    next(
        clipboard.clone(),
        records,
        0,
        Rc::new(RefCell::new(Some(Box::new(done)))),
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_real_supported_encodings_are_offered() {
        for mime in [
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/tiff",
            "image/bmp",
            "image/webp",
            "image/heic",
            "text/html;charset=utf-8",
            "application/rtf",
        ] {
            assert!(Offer::new(mime).is_some());
        }
        for mime in [
            "text/plain",
            "text/richtext",
            "application/octet-stream",
            "image/heif",
            "image/heic-sequence",
            "image/heif-sequence",
        ] {
            assert!(Offer::new(mime).is_none());
        }
    }
    #[test]
    fn adversarial_tmpdir_parent_swap_never_touches_canary() {
        use std::os::unix::fs::symlink;
        if std::env::var_os("PMT_CLIPBOARD_CANARY_CHILD").is_some() {
            let root = std::env::temp_dir();
            let moved = root.with_file_name("moved");
            let foreign = root.with_file_name("foreign");
            let first = Source::stage(b"PRIVATE_FIRST", &Offer::new("text/html").unwrap()).unwrap();
            fs::rename(&root, &moved).unwrap();
            symlink(&foreign, &root).unwrap();
            let second =
                Source::stage(b"PRIVATE_SECOND", &Offer::new("text/html").unwrap()).unwrap();
            assert_eq!(first.bytes().unwrap(), b"PRIVATE_FIRST");
            assert_eq!(second.bytes().unwrap(), b"PRIVATE_SECOND");
            drop(first);
            drop(second);
            assert_eq!(
                fs::read(foreign.join("clipboard.html")).unwrap(),
                b"FOREIGN_CANARY"
            );
            assert_eq!(
                fs::read(moved.join("sentinel")).unwrap(),
                b"ORIGINAL_PARENT"
            );
            assert_eq!(fs::read_dir(&foreign).unwrap().count(), 1);
            assert_eq!(fs::read_dir(&moved).unwrap().count(), 1);
            return;
        }
        let base = std::path::PathBuf::from("/tmp").join(format!(
            "pmt-clipboard-canary-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&base).unwrap();
        let root = base.join("tmpdir");
        let foreign = base.join("foreign");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&foreign).unwrap();
        fs::write(root.join("sentinel"), b"ORIGINAL_PARENT").unwrap();
        fs::write(foreign.join("clipboard.html"), b"FOREIGN_CANARY").unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "clipboard::tests::adversarial_tmpdir_parent_swap_never_touches_canary",
                "--nocapture",
            ])
            .env("TMPDIR", &root)
            .env("PMT_CLIPBOARD_CANARY_CHILD", "1")
            .status()
            .unwrap();
        assert!(status.success());
        fs::remove_file(&root).unwrap();
        fs::remove_file(base.join("moved/sentinel")).unwrap();
        fs::remove_dir(base.join("moved")).unwrap();
        fs::remove_file(foreign.join("clipboard.html")).unwrap();
        fs::remove_dir(foreign).unwrap();
        fs::remove_dir(base).unwrap();
    }
    #[test]
    fn private_source_preserves_original_bytes_without_a_host_path() {
        let bytes = b"{\\rtf1 ORIGINAL_BYTES}";
        let source = Source::stage(bytes, &Offer::new("application/rtf").unwrap()).unwrap();
        assert_eq!(source.bytes().unwrap(), bytes);
        assert_eq!(source.path(), Path::new("/dev/pmt-input/clipboard.rtf"));
        assert!(!source.path().exists());
        assert_eq!(source.bytes().unwrap(), bytes);
    }
}
