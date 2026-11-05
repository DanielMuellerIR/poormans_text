use crate::model::tr;
use gtk::{gdk, gio, glib, prelude::*};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
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
    root: PathBuf,
    path: PathBuf,
    pub mime: String,
}
impl Source {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    fn stage(data: &[u8], offer: &Offer) -> Result<Self, String> {
        let mut random = [0u8; 16];
        fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut random))
            .map_err(|e| e.to_string())?;
        let name = random
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let root = std::env::temp_dir().join(format!("poormans-text-clipboard-{name}"));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .map_err(|e| e.to_string())?;
        let root = root.canonicalize().map_err(|e| e.to_string())?;
        let source = Self {
            path: root.join(format!("clipboard.{}", offer.extension)),
            root,
            mime: offer.mime.clone(),
        };
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&source.path)
            .map_err(|e| e.to_string())?;
        file.write_all(data)
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(source)
    }
}
impl Drop for Source {
    fn drop(&mut self) {
        // Nur die eigene Quelle entfernen. Fremde oder bereits fertige Ausgaben
        // dürfen auch bei einer ungewöhnlichen Zielwahl niemals mitgelöscht werden.
        let _ = fs::remove_file(&self.path);
        let _ = fs::remove_dir(&self.root);
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

/// Nur Eigentumsgrenze des temporären Clipboard-Verzeichnisses; keine Formatlogik.
pub fn destination_is_private(source: &Source, path: &str) -> bool {
    let mut existing = PathBuf::from(path);
    if !existing.is_absolute() {
        let Ok(cwd) = std::env::current_dir() else {
            return true;
        };
        existing = cwd.join(existing);
    }
    let mut tail = Vec::new();
    while !existing.exists() {
        let Some(name) = existing.file_name().map(|s| s.to_os_string()) else {
            return true;
        };
        tail.push(name);
        if !existing.pop() {
            return true;
        }
    }
    let Ok(mut resolved) = existing.canonicalize() else {
        return true;
    };
    for name in tail.iter().rev() {
        resolved.push(name);
    }
    resolved.starts_with(source.root())
}

#[cfg(test)]
pub fn markdown_text(path: &Path) -> Result<String, String> {
    let file = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut data = Vec::new();
    file.take(16 * 1024 * 1024 + 1)
        .read_to_end(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() > 16 * 1024 * 1024 {
        return Err(tr(
            "Markdown überschreitet die Zwischenablagegrenze von 16 MiB.",
            "Markdown exceeds the 16 MiB clipboard limit.",
        )
        .into());
    }
    String::from_utf8(data).map_err(|e| e.to_string())
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
                if fs::read(source.path()).map_err(|e| e.to_string())? != expected {
                    return Err("Clipboard bytes changed".into());
                }
                let root = source.root().to_path_buf();
                if source.path().extension().and_then(|s| s.to_str()) != Some(offer.extension) {
                    return Err("Clipboard extension changed".into());
                }
                drop(source);
                if root.exists() {
                    return Err("Clipboard source was not removed".into());
                }
                eprintln!(
                    "PMT_UI_TEST_CLIPBOARD_ENCODING {} exact-bytes-and-cleanup",
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
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn only_real_supported_encodings_are_offered() {
        for mime in [
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/tiff",
            "image/bmp",
            "image/webp",
            "text/html;charset=utf-8",
            "application/rtf",
        ] {
            assert!(Offer::new(mime).is_some());
        }
        for mime in ["text/plain", "text/richtext", "application/octet-stream"] {
            assert!(Offer::new(mime).is_none());
        }
    }
    #[test]
    fn private_source_preserves_bytes_and_cleans_itself() {
        let bytes = b"{\\rtf1 ORIGINAL_BYTES}";
        let source = Source::stage(bytes, &Offer::new("application/rtf").unwrap()).unwrap();
        let root = source.root.clone();
        assert_eq!(fs::read(source.path()).unwrap(), bytes);
        assert_eq!(
            fs::metadata(source.root()).unwrap().permissions().mode() & 0o777,
            0o700
        );
        drop(source);
        assert!(!root.exists());
    }
    #[test]
    fn copy_reads_the_complete_file_and_rejects_over_16_mib() {
        let source = Source::stage(
            b"# Complete\n![asset](asset.png)\n",
            &Offer::new("text/html").unwrap(),
        )
        .unwrap();
        assert_eq!(
            markdown_text(source.path()).unwrap(),
            "# Complete\n![asset](asset.png)\n"
        );
        fs::write(source.path(), vec![42u8; 16 * 1024 * 1024 + 1]).unwrap();
        assert!(markdown_text(source.path()).is_err());
    }
    #[test]
    fn source_cleanup_preserves_an_unexpected_file() {
        let source = Source::stage(b"x", &Offer::new("text/html").unwrap()).unwrap();
        let root = source.root.clone();
        fs::write(root.join("user-output"), b"KEEP").unwrap();
        drop(source);
        assert_eq!(fs::read(root.join("user-output")).unwrap(), b"KEEP");
        fs::remove_file(root.join("user-output")).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
