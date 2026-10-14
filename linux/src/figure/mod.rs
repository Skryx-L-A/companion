// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The figure: what it shows, how it is drawn, and which of its pixels take a click.

pub mod mask;
pub mod render;
pub mod state;

pub use mask::AlphaMask;
pub use state::{FigureEvent, FigureState, FigureStateMachine};
