// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Draws the figure with Cairo.
//!
//! A port of `app/mac/Sources/CompanionFigure/PlaceholderSprites.swift`. Nothing bitmap
//! ships with either shell — the Mac draws the same shapes with Core Graphics — so what is
//! reusable across the platforms is the geometry and the palette, not a file. The numbers
//! below are the Mac's, unchanged, so both shells show the same character.
//!
//! Core Graphics puts the origin bottom left with y growing upwards, Cairo puts it top left
//! with y growing down. The transform in [`render`] flips once, which is why every shape can
//! keep the Mac's coordinates instead of being mirrored by hand.

use gtk4::cairo;

use super::state::FigureState;

/// Side length of the design grid every shape below is written in.
pub const DESIGN_SIZE: f64 = 256.0;

/// Colours of the figure.
///
/// Deliberately not the system accent: the figure sits on the desktop, not inside a window,
/// so it has to read against any wallpaper and must not look like a stray system control.
/// Graphite body, one teal signal colour, amber only for the alert state.
pub mod palette {
    /// Red, green, blue, alpha.
    pub type Rgba = (f64, f64, f64, f64);

    pub const BODY: Rgba = (0.153, 0.180, 0.216, 1.0);
    /// Sleeping is a darker, flatter body, not a translucent one: a see-through figure picks
    /// up whatever wallpaper is behind it and stops looking like the same character.
    pub const BODY_ASLEEP: Rgba = (0.106, 0.125, 0.149, 1.0);
    pub const RIM_ASLEEP: Rgba = (1.0, 1.0, 1.0, 0.10);
    pub const VISOR_ASLEEP: Rgba = (0.35, 0.39, 0.42, 1.0);
    pub const RIM: Rgba = (1.0, 1.0, 1.0, 0.22);
    pub const VISOR: Rgba = (0.055, 0.071, 0.086, 1.0);
    pub const SIGNAL: Rgba = (0.204, 0.753, 0.663, 1.0);
    pub const SIGNAL_DIM: Rgba = (0.204, 0.753, 0.663, 0.35);
    pub const ALERT: Rgba = (0.910, 0.639, 0.239, 1.0);
}

const BODY: Rect = Rect {
    x: 26.0,
    y: 20.0,
    width: 204.0,
    height: 200.0,
};
const BODY_RADIUS: f64 = 62.0;
const VISOR: Rect = Rect {
    x: 62.0,
    y: 126.0,
    width: 132.0,
    height: 46.0,
};
const VISOR_RADIUS: f64 = 23.0;

#[derive(Debug, Clone, Copy)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Rect {
    fn min_x(self) -> f64 {
        self.x
    }
    fn max_x(self) -> f64 {
        self.x + self.width
    }
    fn mid_x(self) -> f64 {
        self.x + self.width / 2.0
    }
    fn mid_y(self) -> f64 {
        self.y + self.height / 2.0
    }
}

/// Draws one frame of one state into `context`, in a box of `size` by `size` user units.
///
/// The caller owns the surface, so the same code serves the on-screen widget and the offline
/// renderer that produces the alpha mask.
pub fn render(context: &cairo::Context, state: FigureState, frame: usize, size: f64) {
    let _ = context.save();
    context.translate(0.0, size);
    let scale = size / DESIGN_SIZE;
    context.scale(scale, -scale);

    let frames = state.frame_count().max(1);
    let index = frame % frames;
    let phase = index as f64 / frames as f64;
    draw(context, state, phase, index);

    let _ = context.restore();
}

fn set_source(context: &cairo::Context, colour: palette::Rgba) {
    context.set_source_rgba(colour.0, colour.1, colour.2, colour.3);
}

fn rounded_rect(context: &cairo::Context, rect: Rect, radius: f64) {
    let radius = radius.min(rect.width / 2.0).min(rect.height / 2.0);
    let (x, y, w, h) = (rect.x, rect.y, rect.width, rect.height);
    context.new_sub_path();
    context.arc(
        x + w - radius,
        y + h - radius,
        radius,
        0.0,
        std::f64::consts::FRAC_PI_2,
    );
    context.arc(
        x + radius,
        y + h - radius,
        radius,
        std::f64::consts::FRAC_PI_2,
        std::f64::consts::PI,
    );
    context.arc(
        x + radius,
        y + radius,
        radius,
        std::f64::consts::PI,
        1.5 * std::f64::consts::PI,
    );
    context.arc(
        x + w - radius,
        y + radius,
        radius,
        1.5 * std::f64::consts::PI,
        std::f64::consts::TAU,
    );
    context.close_path();
}

fn fill_circle(context: &cairo::Context, x: f64, y: f64, radius: f64, colour: palette::Rgba) {
    set_source(context, colour);
    context.new_sub_path();
    context.arc(x, y, radius, 0.0, std::f64::consts::TAU);
    let _ = context.fill();
}

fn draw(context: &cairo::Context, state: FigureState, phase: f64, frame: usize) {
    let asleep = state == FigureState::Sleeping;

    rounded_rect(context, BODY, BODY_RADIUS);
    set_source(
        context,
        if asleep {
            palette::BODY_ASLEEP
        } else {
            palette::BODY
        },
    );
    let _ = context.fill_preserve();

    // A rim instead of a drop shadow: a shadow would widen the alpha mask and swallow
    // clicks that belong to the window underneath.
    match state {
        FigureState::Alert => set_source(context, palette::ALERT),
        FigureState::Sleeping => set_source(context, palette::RIM_ASLEEP),
        _ => set_source(context, palette::RIM),
    }
    context.set_line_width(if state == FigureState::Alert {
        4.0
    } else {
        2.5
    });
    let _ = context.stroke();

    if asleep {
        draw_closed_eye(context);
        return;
    }

    rounded_rect(context, VISOR, VISOR_RADIUS);
    set_source(context, palette::VISOR);
    let _ = context.fill();

    let _ = context.save();
    rounded_rect(context, VISOR, VISOR_RADIUS);
    context.clip();
    draw_ornament(context, state, phase, frame);
    let _ = context.restore();
}

fn draw_ornament(context: &cairo::Context, state: FigureState, phase: f64, frame: usize) {
    let (cx, cy) = (VISOR.mid_x(), VISOR.mid_y());
    match state {
        FigureState::Idle => fill_circle(context, cx, cy, 9.0, palette::SIGNAL),

        FigureState::Listening => {
            // One ring breathing outward, so the figure looks like it is taking something in.
            let radius = 10.0 + 11.0 * (phase * std::f64::consts::PI).sin();
            set_source(context, palette::SIGNAL_DIM);
            context.new_sub_path();
            context.arc(cx, cy, radius, 0.0, std::f64::consts::TAU);
            context.set_line_width(3.0);
            let _ = context.stroke();
            fill_circle(context, cx, cy, 7.0, palette::SIGNAL);
        }

        FigureState::Thinking => {
            // Three dots, the lit one walking left to right.
            let spacing = 26.0;
            let lit = ((phase * 3.0) as usize) % 3;
            for index in 0..3 {
                let x = cx + (index as f64 - 1.0) * spacing;
                let (radius, colour) = if index == lit {
                    (8.0, palette::SIGNAL)
                } else {
                    (5.0, palette::SIGNAL_DIM)
                };
                fill_circle(context, x, cy, radius, colour);
            }
        }

        FigureState::Speaking => {
            // A level meter: the same five heights travel through the bars, so the shape
            // moves while every frame still shows five clearly different bars.
            let pattern = [0.20, 0.55, 1.0, 0.70, 0.35];
            let bar_width = 8.0;
            let spacing = 18.0;
            set_source(context, palette::SIGNAL);
            for index in 0..5 {
                let level = pattern[(index + frame) % pattern.len()];
                let height = 9.0 + 27.0 * level;
                let x = cx + (index as f64 - 2.0) * spacing - bar_width / 2.0;
                rounded_rect(
                    context,
                    Rect {
                        x,
                        y: cy - height / 2.0,
                        width: bar_width,
                        height,
                    },
                    bar_width / 2.0,
                );
            }
            let _ = context.fill();
        }

        FigureState::Alert => {
            // An exclamation mark drawn as two shapes, never a glyph and never an emoji.
            let colour = if frame == 0 {
                palette::ALERT
            } else {
                palette::SIGNAL
            };
            set_source(context, colour);
            rounded_rect(
                context,
                Rect {
                    x: cx - 4.0,
                    y: cy - 4.0,
                    width: 8.0,
                    height: 24.0,
                },
                4.0,
            );
            let _ = context.fill();
            fill_circle(context, cx, cy - 13.0, 4.5, colour);
        }

        FigureState::Sleeping => {}
    }
}

fn draw_closed_eye(context: &cairo::Context) {
    set_source(context, palette::VISOR_ASLEEP);
    context.set_line_width(7.0);
    context.set_line_cap(cairo::LineCap::Round);
    let mid_y = VISOR.mid_y();
    context.move_to(VISOR.min_x() + 22.0, mid_y);
    context.curve_to(
        VISOR.min_x() + 55.0,
        mid_y - 16.0,
        VISOR.max_x() - 55.0,
        mid_y - 16.0,
        VISOR.max_x() - 22.0,
        mid_y,
    );
    let _ = context.stroke();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The drawn pixels of one frame, colour included.
    ///
    /// The alpha mask cannot answer this: every ornament sits inside the visor, which sits
    /// inside the opaque body, so the animation is invisible in the alpha channel. Only the
    /// colour surface shows whether anything moved.
    fn pixels(state: FigureState, frame: usize, size: i32) -> Vec<u8> {
        let surface = cairo::ImageSurface::create(cairo::Format::ARgb32, size, size)
            .expect("a surface of this size exists");
        {
            let context = cairo::Context::new(&surface).expect("a context on it exists");
            render(&context, state, frame, f64::from(size));
        }
        surface.take_data().expect("the data is ours").to_vec()
    }

    #[test]
    fn every_animated_state_actually_moves() {
        for state in FigureState::ALL {
            if !state.is_animated() {
                continue;
            }
            let first = pixels(state, 0, 96);
            let moved = (1..state.frame_count()).any(|frame| pixels(state, frame, 96) != first);
            assert!(moved, "{state:?} draws the same picture in every frame");
        }
    }

    #[test]
    fn a_resting_state_draws_the_same_picture_every_time() {
        for state in [FigureState::Idle, FigureState::Sleeping] {
            assert_eq!(
                pixels(state, 0, 96),
                pixels(state, 7, 96),
                "{state:?} flickers"
            );
        }
    }

    /// Two states have to be told apart at a glance, which they cannot be if they draw the
    /// same thing.
    #[test]
    fn no_two_states_look_alike() {
        for (index, state) in FigureState::ALL.iter().enumerate() {
            for other in &FigureState::ALL[index + 1..] {
                assert_ne!(
                    pixels(*state, 0, 96),
                    pixels(*other, 0, 96),
                    "{state:?} and {other:?} draw the same picture"
                );
            }
        }
    }

    /// The figure has to sit inside its box: a shape drawn past the edge would be clipped by
    /// the surface and would take clicks at the very edge of the window.
    #[test]
    fn nothing_is_drawn_in_the_outermost_row_or_column() {
        let size = 96usize;
        let data = pixels(FigureState::Alert, 0, size as i32);
        let stride = data.len() / size;
        let opaque = |x: usize, y: usize| data[y * stride + x * 4 + 3] > 0;
        for index in 0..size {
            assert!(!opaque(index, 0), "the top row has paint on it at {index}");
            assert!(
                !opaque(index, size - 1),
                "the bottom row has paint on it at {index}"
            );
            assert!(
                !opaque(0, index),
                "the left column has paint on it at {index}"
            );
            assert!(
                !opaque(size - 1, index),
                "the right column has paint on it at {index}"
            );
        }
    }
}
