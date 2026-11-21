use super::*;

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
    pub(super) fn test_finished(&self, index: u32, displayed: bool) {
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
