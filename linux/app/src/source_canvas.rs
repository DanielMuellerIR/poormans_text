use gtk::{gdk, glib, graphene, prelude::*, subclass::prelude::*};
use std::cell::{Cell, RefCell};

pub(crate) type CanvasRect = [f64; 4];

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Zoom {
    Fit,
    Scale(f64),
}

mod imp {
    use super::*;
    pub struct SourceCanvas {
        pub(super) texture: RefCell<Option<gdk::Texture>>,
        pub(super) zoom: Cell<Zoom>,
        pub(super) marks: RefCell<Vec<CanvasRect>>,
        pub(super) selection: Cell<Option<CanvasRect>>,
    }
    impl Default for SourceCanvas {
        fn default() -> Self {
            Self {
                texture: RefCell::new(None),
                zoom: Cell::new(Zoom::Fit),
                marks: RefCell::new(vec![]),
                selection: Cell::new(None),
            }
        }
    }
    #[glib::object_subclass]
    impl ObjectSubclass for SourceCanvas {
        const NAME: &'static str = "PMTSourceCanvas";
        type Type = super::SourceCanvas;
        type ParentType = gtk::Widget;
        fn class_init(klass: &mut Self::Class) {
            klass.set_accessible_role(gtk::AccessibleRole::Img);
        }
    }
    impl ObjectImpl for SourceCanvas {
        fn dispose(&self) {
            self.texture.borrow_mut().take();
        }
    }
    impl WidgetImpl for SourceCanvas {
        // GtkViewport scrollt nur über das Mindestmaß. Fit bleibt deshalb
        // schrumpfbar; Prozentzoom fordert die tatsächlich gezeichneten Pixel an.
        fn measure(&self, orientation: gtk::Orientation, _: i32) -> (i32, i32, i32, i32) {
            let size = match (self.zoom.get(), self.texture.borrow().as_ref()) {
                (Zoom::Scale(scale), Some(t)) => {
                    let pixels = if orientation == gtk::Orientation::Horizontal {
                        t.width()
                    } else {
                        t.height()
                    };
                    (f64::from(pixels) * scale).ceil().clamp(1.0, 4096.0) as i32
                }
                _ => 1,
            };
            (size, size, -1, -1)
        }
        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let texture = self.texture.borrow();
            let Some(texture) = texture.as_ref() else {
                return;
            };
            let obj = self.obj();
            let (x, y, w, h) = super::placement(
                obj.width(),
                obj.height(),
                texture.width(),
                texture.height(),
                self.zoom.get(),
            );
            if w > 0.0 && h > 0.0 {
                snapshot.append_texture(
                    texture,
                    &graphene::Rect::new(x as f32, y as f32, w as f32, h as f32),
                );
                let draw = |[left, top, width, height]: CanvasRect, color: [f32; 3]| {
                    let [r, g, b] = color;
                    let bounds = graphene::Rect::new(
                        (x + left * w) as f32,
                        (y + top * h) as f32,
                        (width * w) as f32,
                        (height * h) as f32,
                    );
                    snapshot.append_color(&gdk::RGBA::new(r, g, b, 0.20), &bounds);
                    snapshot.append_border(
                        &gtk::gsk::RoundedRect::from_rect(bounds, 0.0),
                        &[1.5; 4],
                        &std::array::from_fn(|_| gdk::RGBA::new(r, g, b, 1.0)),
                    );
                };
                snapshot.push_clip(&graphene::Rect::new(x as f32, y as f32, w as f32, h as f32));
                for &rect in self.marks.borrow().iter() {
                    draw(rect, [0.85, 0.35, 0.07]);
                }
                if let Some(rect) = self.selection.get() {
                    draw(rect, [0.15, 0.48, 0.85]);
                }
                snapshot.pop();
            }
        }
    }
}
glib::wrapper! {
    pub struct SourceCanvas(ObjectSubclass<imp::SourceCanvas>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}
impl SourceCanvas {
    pub(crate) fn new() -> Self {
        glib::Object::new()
    }
    pub(crate) fn set_texture(&self, texture: Option<&gdk::Texture>) {
        *self.imp().texture.borrow_mut() = texture.cloned();
        self.imp().zoom.set(Zoom::Fit);
        self.imp().marks.borrow_mut().clear();
        self.imp().selection.set(None);
        self.queue_resize();
        self.queue_draw();
    }
    pub(crate) fn texture(&self) -> Option<gdk::Texture> {
        self.imp().texture.borrow().clone()
    }
    pub(crate) fn zoom(&self) -> Zoom {
        self.imp().zoom.get()
    }
    pub(crate) fn set_zoom(&self, zoom: Zoom) {
        let zoom = match zoom {
            // Ganze Prozentwerte im Status entsprechen der tatsächlichen Skalierung.
            Zoom::Scale(v) if v.is_finite() => {
                Zoom::Scale((v.clamp(0.25, 4.0) * 100.0).round() / 100.0)
            }
            Zoom::Scale(_) => Zoom::Fit,
            Zoom::Fit => Zoom::Fit,
        };
        self.imp().zoom.set(zoom);
        self.queue_resize();
        self.queue_draw();
    }
    pub(crate) fn step_zoom(&self, zoom_in: bool) -> bool {
        let Some(texture) = self.texture() else {
            return false;
        };
        let scale = match self.zoom() {
            Zoom::Fit => self.rectangle().2 / f64::from(texture.width()),
            Zoom::Scale(scale) => scale,
        };
        if (zoom_in && scale >= 4.0) || (!zoom_in && scale <= 0.25) {
            return false;
        }
        let next = if zoom_in { scale * 1.25 } else { scale / 1.25 };
        self.set_zoom(Zoom::Scale(next));
        true
    }
    pub(crate) fn set_marks(&self, marks: Vec<CanvasRect>) {
        *self.imp().marks.borrow_mut() = marks;
        self.queue_draw();
    }
    pub(crate) fn set_selection(&self, selection: Option<CanvasRect>) {
        self.imp().selection.set(selection);
        self.queue_draw();
    }
    pub(crate) fn rectangle(&self) -> (f64, f64, f64, f64) {
        let Some(t) = self.texture() else {
            return (0.0, 0.0, 0.0, 0.0);
        };
        placement(
            self.width(),
            self.height(),
            t.width(),
            t.height(),
            self.zoom(),
        )
    }
}
fn placement(
    width: i32,
    height: i32,
    pixels_w: i32,
    pixels_h: i32,
    zoom: Zoom,
) -> (f64, f64, f64, f64) {
    if width <= 0 || height <= 0 || pixels_w <= 0 || pixels_h <= 0 {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let scale = match zoom {
        Zoom::Fit => {
            (f64::from(width) / f64::from(pixels_w)).min(f64::from(height) / f64::from(pixels_h))
        }
        Zoom::Scale(v) if v.is_finite() => v.clamp(0.25, 4.0),
        _ => return (0.0, 0.0, 0.0, 0.0),
    };
    let w = f64::from(pixels_w) * scale;
    let h = f64::from(pixels_h) * scale;
    (
        (f64::from(width) - w) / 2.0,
        (f64::from(height) - h) / 2.0,
        w,
        h,
    )
}
