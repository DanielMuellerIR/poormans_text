use super::*;

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
