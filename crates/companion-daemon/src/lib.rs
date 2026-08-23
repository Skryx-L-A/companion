// SPDX-License-Identifier: AGPL-3.0-only

//! The daemon: one per machine, listening on a user-only Unix socket.
//!
//! The binary is a thin wrapper around [`server::start`]. Everything the daemon does lives
//! in the library so a test can run it in process with an adapter of its own.

pub mod server;

pub use server::{Limits, ServerConfig, ServerError, ServerHandle, start};

/// Version of the daemon binary, reported in the handshake.
pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");
