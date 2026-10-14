// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! One read against a session store a real Hermes wrote.
//!
//! Ignored by default, and pointed at an installation the same way the handshake test is:
//!
//! ```text
//! COMPANION_HERMES_HOME=/path/to/a/throwaway/home \
//!   cargo test -p companion-adapter-hermes --test live_store -- --ignored
//! ```
//!
//! Never the real `~/.hermes`. This reads somebody's conversations, and the house rule for
//! tests is that they stay away from the live environment; a throwaway home filled on
//! purpose is what belongs here.
//!
//! It names no content in its output either — line counts and roles, never a sentence — the
//! same rule `live_rollout.rs` next door follows. A throwaway home is a decision about where
//! the test may look, not a licence to print what it found into a log that ends up in a
//! report.
//!
//! Why it exists next to the fixture tests: those build a store from a copied schema, which
//! proves the reader against what the schema *said*. This one reads what Hermes' own writer
//! actually put there — including the WAL files it leaves beside the database, which a
//! read-only connection has to cope with.

use std::path::PathBuf;

use companion_adapter_hermes::{HermesAdapter, HermesConfig};
use companion_core::adapter::{ReadWindow, SessionAdapter};
use companion_protocol::SessionId;

#[tokio::test]
#[ignore = "needs a Hermes home with a session in it; see the module comment"]
async fn a_store_a_real_hermes_wrote_reads_back_as_a_transcript() {
    let Some(home) = std::env::var_os("COMPANION_HERMES_HOME") else {
        panic!("set COMPANION_HERMES_HOME to a throwaway home, never to the real one");
    };
    let session = std::env::var("COMPANION_HERMES_SESSION")
        .expect("set COMPANION_HERMES_SESSION to a session id in that store");

    let config = HermesConfig::for_home(PathBuf::from(home));
    assert!(
        config.state_db().exists(),
        "no state.db under that home: {}",
        config.state_db().display()
    );

    let chunk = HermesAdapter::new(config)
        .read(
            &SessionId::new(session),
            ReadWindow::FromOffset { offset: 0 },
        )
        .await
        .expect("the store has that session");

    assert!(!chunk.text.is_empty(), "the session has messages");
    assert_eq!(chunk.next_offset, chunk.text.len() as u64);

    let mut roles: Vec<&str> = chunk
        .text
        .lines()
        .filter_map(|line| line.split_once(": "))
        .map(|(role, _)| role)
        .collect();
    roles.sort_unstable();
    roles.dedup();
    println!(
        "{} lines, {} bytes, roles: {}",
        chunk.text.lines().count(),
        chunk.text.len(),
        roles.join(", ")
    );
    assert!(!roles.is_empty(), "no line carried a role");
    for role in roles {
        assert!(!role.is_empty(), "a line began with a bare colon");
        assert!(
            !role.contains(char::is_whitespace),
            "a role is one word; {role:?} is a line that was rendered wrong"
        );
    }
}

/// The same adapter read as the live test, but against a store created below `TMPDIR`.
/// Keeping the home explicit is important: this test must never fall back to `~/.hermes`.
#[tokio::test]
async fn the_store_reader_uses_only_a_scratch_hermes_home() {
    let home = std::env::temp_dir().join(format!(
        "companion-hermes-store-fixture-{}",
        std::process::id()
    ));
    let _cleanup = ScratchHome(home.clone());
    std::fs::create_dir_all(&home).expect("the scratch Hermes home is writable");

    let db = home.join("state.db");
    let connection = rusqlite::Connection::open(&db).expect("the fixture database opens");
    connection
        .execute_batch(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at REAL, cwd TEXT);
             CREATE TABLE messages (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 session_id TEXT NOT NULL,
                 role TEXT,
                 content TEXT,
                 tool_call_id TEXT,
                 tool_calls TEXT,
                 tool_name TEXT,
                 timestamp REAL,
                 active INTEGER,
                 compacted INTEGER
             );
             INSERT INTO sessions (id, source, started_at, cwd)
                 VALUES ('fixture-session', 'acp', 1.0, '/tmp');
             INSERT INTO messages (session_id, role, content, timestamp, active, compacted)
                 VALUES ('fixture-session', 'user', 'fixture question', 1.0, 1, 0);
             INSERT INTO messages (session_id, role, content, timestamp, active, compacted)
                 VALUES ('fixture-session', 'assistant', 'fixture answer', 2.0, 1, 0);",
        )
        .expect("the fixture schema and rows are valid");
    drop(connection);

    let config = HermesConfig::for_home(&home);
    let chunk = HermesAdapter::new(config)
        .read(
            &SessionId::new("fixture-session"),
            ReadWindow::FromOffset { offset: 0 },
        )
        .await
        .expect("the adapter reads the explicitly supplied scratch home");

    assert_eq!(
        chunk.text,
        "user: fixture question\nassistant: fixture answer\n"
    );
    assert_eq!(chunk.next_offset, chunk.text.len() as u64);
}

struct ScratchHome(PathBuf);

impl Drop for ScratchHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
