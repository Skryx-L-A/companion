// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The alpha channel of one frame, and the input region built from it.
//!
//! A port of `app/mac/Sources/CompanionFigure/AlphaMask.swift`, plus the piece the Mac does
//! not need: on Wayland a click goes through a surface only where the surface says it has no
//! input, so the mask is also handed to the compositor as an input region
//! (`DESIGN.md` § Figur und Overlay, "Klicks außerhalb der Figur gehen durch, per Treffertest
//! gegen die Alpha-Maske des aktuellen Animationsbilds").
//!
//! Rows run top-down, the way the image surface stores them.

use gtk4::cairo;

use super::render;
use super::state::FigureState;

/// Alpha below this counts as transparent. Set just above zero so the antialiased rim of a
/// drawn shape still belongs to the figure, while its shadow does not.
pub const DEFAULT_THRESHOLD: u8 = 25;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlphaMask {
    width: usize,
    height: usize,
    alpha: Vec<u8>,
}

impl AlphaMask {
    /// Builds a mask from raw alpha bytes. Panics when the grid does not match its size,
    /// which can only be a programming error in this crate.
    pub fn new(width: usize, height: usize, alpha: Vec<u8>) -> Self {
        assert_eq!(
            alpha.len(),
            width * height,
            "alpha grid does not match its size"
        );
        Self {
            width,
            height,
            alpha,
        }
    }

    /// Draws one frame into an alpha-only surface and keeps the result.
    ///
    /// Alpha-only rather than a colour surface whose alpha channel is read afterwards: it is
    /// the same thing Core Graphics does on the Mac, and it costs a quarter of the memory.
    pub fn render(state: FigureState, frame: usize, pixels: usize) -> Option<Self> {
        if pixels == 0 {
            return None;
        }
        let size = i32::try_from(pixels).ok()?;
        let surface = cairo::ImageSurface::create(cairo::Format::A8, size, size).ok()?;
        {
            let context = cairo::Context::new(&surface).ok()?;
            render::render(&context, state, frame, pixels as f64);
        }
        let stride = usize::try_from(surface.stride()).ok()?;
        let data = surface.take_data().ok()?;

        let mut alpha = Vec::with_capacity(pixels * pixels);
        for row in 0..pixels {
            let start = row * stride;
            alpha.extend_from_slice(data.get(start..start + pixels)?);
        }
        Some(Self::new(pixels, pixels, alpha))
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn height(&self) -> usize {
        self.height
    }

    /// Alpha at a pixel, rows counted from the top. Out of range reads as transparent.
    pub fn alpha_at(&self, x: usize, y: usize) -> u8 {
        if x >= self.width || y >= self.height {
            return 0;
        }
        self.alpha[y * self.width + x]
    }

    /// True when the figure covers this point of a box `width` by `height` user units, with
    /// the origin top left — the way GTK counts inside a widget.
    pub fn is_opaque(&self, x: f64, y: f64, width: f64, height: f64, threshold: u8) -> bool {
        if width <= 0.0 || height <= 0.0 {
            return false;
        }
        // Eine Maske ohne Pixel bedeckt nichts. Ohne diese Zeile liefe `self.width - 1`
        // weiter unten unter null durch.
        if self.width == 0 || self.height == 0 {
            return false;
        }
        if x < 0.0 || y < 0.0 || x >= width || y >= height {
            return false;
        }
        let column = ((x / width) * self.width as f64) as usize;
        let row = ((y / height) * self.height as f64) as usize;
        self.alpha_at(column.min(self.width - 1), row.min(self.height - 1)) > threshold
    }

    /// Share of pixels that count as covered. The tests use it to catch an empty frame.
    pub fn coverage(&self) -> f64 {
        if self.alpha.is_empty() {
            return 0.0;
        }
        let covered = self
            .alpha
            .iter()
            .filter(|value| **value > DEFAULT_THRESHOLD)
            .count();
        covered as f64 / self.alpha.len() as f64
    }

    /// The covered pixels as horizontal runs, scaled to a box of `width` by `height`.
    ///
    /// One rectangle per run rather than per pixel: the figure is convex enough that a row
    /// is almost always a single run, which keeps the region a few hundred rectangles rather
    /// than tens of thousands.
    pub fn runs(&self, width: i32, height: i32, threshold: u8) -> Vec<cairo::RectangleInt> {
        let mut rectangles = Vec::new();
        if width <= 0 || height <= 0 || self.width == 0 || self.height == 0 {
            return rectangles;
        }
        for row in 0..self.height {
            let y = (row as f64 * height as f64 / self.height as f64).floor() as i32;
            let next_y = ((row + 1) as f64 * height as f64 / self.height as f64).ceil() as i32;
            let row_height = (next_y - y).max(1);

            let mut run_start: Option<usize> = None;
            for column in 0..=self.width {
                let covered = column < self.width && self.alpha_at(column, row) > threshold;
                match (covered, run_start) {
                    (true, None) => run_start = Some(column),
                    (false, Some(start)) => {
                        let x = (start as f64 * width as f64 / self.width as f64).floor() as i32;
                        let end = (column as f64 * width as f64 / self.width as f64).ceil() as i32;
                        rectangles.push(cairo::RectangleInt::new(
                            x,
                            y,
                            (end - x).max(1),
                            row_height,
                        ));
                        run_start = None;
                    }
                    _ => {}
                }
            }
        }
        rectangles
    }

    /// The region a Wayland surface hands the compositor so that everything the figure does
    /// not cover stops being input for this window.
    pub fn input_region(&self, width: i32, height: i32) -> cairo::Region {
        let region = cairo::Region::create();
        for rectangle in self.runs(width, height, DEFAULT_THRESHOLD) {
            let _ = region.union_rectangle(&rectangle);
        }
        region
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid(rows: &[&str]) -> AlphaMask {
        let width = rows[0].len();
        let alpha: Vec<u8> = rows
            .iter()
            .flat_map(|row| row.chars().map(|c| if c == '#' { 255 } else { 0 }))
            .collect();
        AlphaMask::new(width, rows.len(), alpha)
    }

    #[test]
    fn a_point_off_the_figure_is_not_covered() {
        let mask = grid(&["..#..", ".###.", "#####"]);
        assert!(mask.is_opaque(2.5, 2.5, 5.0, 3.0, DEFAULT_THRESHOLD));
        assert!(!mask.is_opaque(0.5, 0.5, 5.0, 3.0, DEFAULT_THRESHOLD));
        assert!(!mask.is_opaque(-1.0, 1.0, 5.0, 3.0, DEFAULT_THRESHOLD));
        assert!(!mask.is_opaque(6.0, 1.0, 5.0, 3.0, DEFAULT_THRESHOLD));
    }

    #[test]
    fn a_row_of_covered_pixels_becomes_one_rectangle() {
        let mask = grid(&[".###."]);
        let runs = mask.runs(5, 1, DEFAULT_THRESHOLD);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].x(), 1);
        assert_eq!(runs[0].width(), 3);
    }

    #[test]
    fn a_gap_in_a_row_stays_a_gap() {
        let mask = grid(&["##.##"]);
        let runs = mask.runs(5, 1, DEFAULT_THRESHOLD);
        assert_eq!(runs.len(), 2, "a hole must not be filled in: {runs:?}");
    }

    /// Eine Maske ohne Pixel bedeckt nichts, und fragt man sie danach, rechnet sie nicht in
    /// den Unterlauf.
    #[test]
    fn eine_maske_ohne_pixel_bedeckt_nichts() {
        let mask = AlphaMask::new(0, 0, Vec::new());
        assert!(!mask.is_opaque(0.0, 0.0, 10.0, 10.0, DEFAULT_THRESHOLD));
        assert!(mask.runs(10, 10, DEFAULT_THRESHOLD).is_empty());
        assert!(mask.input_region(10, 10).is_empty());
        assert_eq!(mask.coverage(), 0.0);
    }

    #[test]
    fn an_empty_frame_gives_an_empty_region() {
        let mask = grid(&["....", "...."]);
        assert!(mask.input_region(4, 2).is_empty());
        assert_eq!(mask.coverage(), 0.0);
    }

    #[test]
    fn the_region_covers_the_figure_and_leaves_the_corners_out() {
        let mask = grid(&["..#..", ".###.", "#####"]);
        let region = mask.input_region(5, 3);
        assert!(region.contains_point(2, 0), "the tip belongs to the figure");
        assert!(
            !region.contains_point(0, 0),
            "the corner has to let a click through"
        );
    }

    #[test]
    fn every_drawn_state_has_something_on_it() {
        for state in FigureState::ALL {
            let mask = AlphaMask::render(state, 0, 64).expect("a frame renders");
            let coverage = mask.coverage();
            assert!(
                coverage > 0.25 && coverage < 0.95,
                "{state:?} covers {coverage} of its box, which is not a figure"
            );
        }
    }

    #[test]
    fn the_middle_of_the_figure_is_solid_and_the_corner_is_not() {
        let mask = AlphaMask::render(FigureState::Idle, 0, 64).expect("a frame renders");
        assert!(mask.is_opaque(32.0, 32.0, 64.0, 64.0, DEFAULT_THRESHOLD));
        assert!(!mask.is_opaque(1.0, 1.0, 64.0, 64.0, DEFAULT_THRESHOLD));
    }

    /// Why the input region may be computed once per state instead of once per frame:
    /// every ornament is drawn inside the visor, which is inside the opaque body, so the
    /// animation never changes which pixels take a click.
    #[test]
    fn the_silhouette_does_not_move_between_the_frames_of_one_state() {
        for state in FigureState::ALL {
            let first = AlphaMask::render(state, 0, 64).expect("a frame renders");
            for frame in 1..state.frame_count() {
                let later = AlphaMask::render(state, frame, 64).expect("a frame renders");
                assert_eq!(first, later, "{state:?} changed shape at frame {frame}");
            }
        }
    }
}
