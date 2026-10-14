// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The Linux shell of companion.
//!
//! `DESIGN.md` § Architektur: one core as a daemon per machine, and a shell per operating
//! system that is native to it. This is the Linux one — GTK4 with wlr-layer-shell, which is
//! what makes an always-on-top, click-through overlay possible on Wayland at all.
//!
//! What it does today is the scope the early Mac shell had: the figure with its state matrix,
//! a session list and a chat with the companion. Voice, the job file and the approvals belong
//! to later steps of the Linux track.
//!
//! A library beside the binary, so the parts that need no compositor — the state matrix, the
//! alpha mask, the line protocol, the argument parsing — can be tested from outside on a
//! machine with no display at all.

pub mod chat;
pub mod client;
pub mod daemon;
pub mod figure;
pub mod mapping;
pub mod options;
pub mod paths;
pub mod reconnect;
pub mod remote;
pub mod theme;
pub mod tray;
pub mod ui;
