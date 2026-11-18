use super::Rect;
use crate::source_canvas::CanvasRect;
use serde::Deserialize;

#[derive(Clone, Copy, Debug, Deserialize)]
pub(super) struct Page {
    pub bounds: Rect,
    pub rotation: u16,
}

impl Page {
    pub fn valid(self) -> bool {
        let Rect {
            x,
            y,
            width,
            height,
        } = self.bounds;
        matches!(self.rotation, 0 | 90 | 180 | 270)
            && [x, y, width, height, x + width, y + height]
                .into_iter()
                .all(f64::is_finite)
            && width > 0.0
            && height > 0.0
    }

    // PDF-Koordinaten beginnen unten links, das gedrehte Raster oben links.
    fn display(self, x: f64, y: f64) -> (f64, f64) {
        let b = self.bounds;
        let u = (x - b.x) / b.width;
        let v = (y - b.y) / b.height;
        match self.rotation {
            90 => (v, u),
            180 => (1.0 - u, v),
            270 => (1.0 - v, 1.0 - u),
            _ => (u, 1.0 - v),
        }
    }

    pub fn point(self, x: f64, y: f64) -> (f64, f64) {
        let (u, v) = match self.rotation {
            90 => (y, x),
            180 => (1.0 - x, y),
            270 => (1.0 - y, 1.0 - x),
            _ => (x, 1.0 - y),
        };
        let b = self.bounds;
        (b.x + u * b.width, b.y + v * b.height)
    }

    pub fn overlay(self, rect: Rect) -> CanvasRect {
        let first = self.display(rect.x, rect.y);
        let second = self.display(rect.x + rect.width, rect.y + rect.height);
        let rect = between(first, second);
        [rect.x, rect.y, rect.width, rect.height]
    }

    pub fn region(self, start: (f64, f64), end: (f64, f64)) -> Rect {
        between(self.point(start.0, start.1), self.point(end.0, end.1))
    }
}

impl Rect {
    pub fn contains(self, x: f64, y: f64) -> bool {
        (self.x..=self.x + self.width).contains(&x) && (self.y..=self.y + self.height).contains(&y)
    }
}

fn between((x1, y1): (f64, f64), (x2, y2): (f64, f64)) -> Rect {
    Rect {
        x: x1.min(x2),
        y: y1.min(y2),
        width: (x2 - x1).abs(),
        height: (y2 - y1).abs(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotated_crop_coordinates_align_and_round_trip() {
        let bounds = Rect {
            x: -12.0,
            y: 24.0,
            width: 128.0,
            height: 256.0,
        };
        let text = Rect {
            x: 4.0,
            y: 88.0,
            width: 16.0,
            height: 32.0,
        };
        for (rotation, expected) in [
            (0, [0.125, 0.625, 0.125, 0.125]),
            (90, [0.25, 0.125, 0.125, 0.125]),
            (180, [0.75, 0.25, 0.125, 0.125]),
            (270, [0.625, 0.75, 0.125, 0.125]),
        ] {
            let page = Page { bounds, rotation };
            let [x, y, w, h] = page.overlay(text);
            assert_eq!([x, y, w, h], expected);
            assert_eq!(page.region((x + w, y + h), (x, y)), text);
        }
    }
}
