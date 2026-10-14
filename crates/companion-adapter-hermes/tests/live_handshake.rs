// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! One test against a real Hermes, for the day somebody has one.
//!
//! It is ignored by default and needs to be pointed at an installation:
//!
//! ```text
//! COMPANION_HERMES_BIN=/path/to/venv/bin/hermes \
//! COMPANION_HERMES_HOME=/path/to/a/throwaway/home \
//!   cargo test -p companion-adapter-hermes -- --ignored
//! ```
//!
//! `COMPANION_HERMES_HOME` is not optional on purpose. A test that reaches into somebody's
//! real `~/.hermes` would be reading their work and writing into their configuration, and
//! the house rule for tests is that they never touch the live environment. Point it at a
//! directory that may be thrown away.
//!
//! What it checks is exactly what a first connection can check without a model provider:
//! the process starts, the handshake answers, and the agent names itself. Everything past
//! that needs a provider, and configuring one is a decision for the person who owns the
//! machine.

use std::path::PathBuf;
use std::time::Duration;

use companion_adapter_hermes::{HermesAdapter, HermesConfig};
use companion_core::adapter::SessionAdapter;

#[tokio::test]
#[ignore = "needs a Hermes installation; see the module comment"]
async fn a_real_hermes_answers_the_handshake_and_lists_its_sessions() {
    let Some(binary) = std::env::var_os("COMPANION_HERMES_BIN") else {
        panic!("set COMPANION_HERMES_BIN to the `hermes` of an installation");
    };
    let Some(home) = std::env::var_os("COMPANION_HERMES_HOME") else {
        panic!("set COMPANION_HERMES_HOME to a throwaway home, never to the real one");
    };

    let mut config = HermesConfig::for_home(PathBuf::from(home));
    config.hermes_bin = PathBuf::from(binary);
    // The observed cold start spent about ten seconds on plugin discovery before the
    // handshake came back. Room for a slower machine, not room for a hang.
    config.request_timeout = Duration::from_secs(180);

    let adapter = HermesAdapter::new(config);
    let installation = adapter.installation();
    assert!(
        installation.usable(),
        "COMPANION_HERMES_BIN does not point at a file"
    );

    let initialized = adapter.probe().await.expect("the handshake");
    assert_eq!(initialized.agent_name.as_deref(), Some("hermes-agent"));
    assert!(
        !initialized
            .agent_version
            .as_deref()
            .unwrap_or_default()
            .is_empty(),
        "the agent names its version"
    );

    if initialized.list_sessions {
        use companion_core::adapter::SessionAdapter;
        // A fresh home has no sessions, and a used one has some. Either is fine; what is
        // checked is that the answer parses at all.
        adapter.list().await.expect("the session list");
    }

    // What the test started, the test ends.
    adapter.shutdown().await.expect("the agent process ends");
}

/// The same process, handshake and session-list path as the live test, with a tiny ACP
/// responder and an explicitly supplied home below `TMPDIR`. No PATH lookup or real Hermes
/// home is involved.
#[cfg(unix)]
#[tokio::test]
async fn the_handshake_fixture_uses_only_a_scratch_hermes_installation() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "companion-hermes-handshake-fixture-{}",
        std::process::id()
    ));
    let _cleanup = ScratchRoot(root.clone());
    let home = root.join("home");
    std::fs::create_dir_all(&home).expect("the scratch Hermes home is writable");

    let binary = root.join("hermes-fixture");
    std::fs::write(
        &binary,
        b"#!/bin/sh\nwhile IFS= read -r request; do\ncase \"$request\" in\n*initialize*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"agentCapabilities\":{\"sessionCapabilities\":{\"list\":{}}},\"agentInfo\":{\"name\":\"hermes-agent\",\"version\":\"fixture\"},\"protocolVersion\":1}}' ;;\n*session/list*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessions\":[]}}' ;;\nesac\ndone\n",
    )
    .expect("the fixture executable is writable");
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755))
        .expect("the fixture executable is executable");

    let mut config = HermesConfig::for_home(&home);
    config.hermes_bin = binary;
    config.request_timeout = Duration::from_secs(5);

    let adapter = HermesAdapter::new(config);
    let installation = adapter.installation();
    assert!(
        installation.usable(),
        "the explicitly supplied fixture is usable"
    );

    let initialized = adapter.probe().await.expect("the fixture handshake");
    assert_eq!(initialized.agent_name.as_deref(), Some("hermes-agent"));
    assert_eq!(initialized.agent_version.as_deref(), Some("fixture"));

    let sessions = adapter.list().await.expect("the fixture session list");
    assert!(sessions.is_empty());
    adapter.shutdown().await.expect("the fixture process ends");
}

struct ScratchRoot(PathBuf);

impl Drop for ScratchRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
