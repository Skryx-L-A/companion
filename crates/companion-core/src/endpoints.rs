// SPDX-License-Identifier: AGPL-3.0-only

//! Which endpoint serves which role, and in what order.
//!
//! The types themselves live in `companion-protocol`, because `get_settings` and
//! `set_settings` put the settings document on the wire and the endpoint part of it travels
//! with them. They are re-exported here so the path they were reached under still works.

pub use companion_protocol::{
    EndpointConfig, EndpointError, EndpointProfile, RoleBinding, SAY_PROFILE_ID,
};
