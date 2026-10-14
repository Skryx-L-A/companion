// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Reading the Hermes session store, `$HERMES_HOME/state.db`.
//!
//! ACP hands out no transcript, so this is where `read` gets its text. The store is SQLite
//! and it belongs to a foreign program: it is opened read-only, and nothing here writes,
//! migrates or vacuums. What comes out is quoted material for the model, never instruction
//! — `DESIGN.md` § Session-Adapter, and the rule about third-party content generally.
//!
//! The rules below are not guessed. They were read out of Hermes 0.20.5 itself — the
//! schema from a store the program created, the reading rules from `SessionDB.get_messages`
//! — and checked against a store filled through Hermes' own writer:
//!
//! * **Which rows are the conversation.** `active = 1` is what is live. `compacted = 1` is
//!   what in-place compaction archived: durable display history, and dropping it would make
//!   earlier turns silently unreachable. `active = 0` together with `compacted = 0` is a
//!   soft-deleted row from an undo or a rewind, and it never comes back.
//! * **The order is the row id**, not the timestamp. Hermes says why in its own source: a
//!   clock that jumps backwards would otherwise reorder a conversation.
//! * **Compaction duplicates rows.** Each generation copies the protected tail, so the same
//!   message can exist several times with different ids and flags. Hermes collapses them on
//!   role, content, timestamp and the three tool fields, keeping the live row and otherwise
//!   the newest. The same rule is applied here, or a compacted session would read as if
//!   everything had been said twice.
//! * **Content can be structured.** A multimodal turn is stored as JSON behind the marker
//!   `\0json:`; the text parts are what a transcript shows, and the rest — an inline image,
//!   for instance — is not text and is left out.
//!
//! **Why this does not sit on `companion_core::jsonl_history`.** That module reads a file
//! that only ever grows, and it redeems an offset by seeking back into it — an offset is a
//! byte position in the *source*, valid for as long as nothing before it changes. Hermes'
//! store can shrink and reorder: a rewind or an undo removes rows outright, and compaction
//! copies a message under a new id, which is exactly the case the adapter's own read-mark
//! tracking (`ReadMark` in `lib.rs`) exists to catch. Forcing that onto `JsonlHistory` would
//! mean teaching a module built for an append-only file about a store that is neither, for
//! one caller. What is shared instead is the *shape* of the bound: `MAX_MESSAGE_ROWS` below
//! plays the part `JsonlHistory::max_bytes` plays for a file — a `LIMIT` a query never
//! exceeds, applied identically to `Tail` and `FromOffset` — and the byte-slicing helper,
//! `companion_core::jsonl_history::slice_from`, is reused as it is rather than copied a
//! fifth time.

use std::path::Path;

use rusqlite::{Connection, OpenFlags};
use thiserror::Error;

/// The marker Hermes puts in front of a JSON-encoded content field.
const JSON_MARKER: &str = "\u{0}json:";

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("no session store at {path}")]
    Missing { path: String },
    #[error("the session store at {path} cannot be read: {source}")]
    Unreadable {
        path: String,
        #[source]
        source: rusqlite::Error,
    },
    #[error("the session store holds no session {id}")]
    UnknownSession { id: String },
}

/// One message, as far as a transcript cares.
#[derive(Debug, Clone)]
struct Message {
    id: i64,
    active: i64,
    role: String,
    content: Option<String>,
    tool_call_id: Option<String>,
    tool_calls: Option<String>,
    tool_name: Option<String>,
    timestamp: f64,
}

/// How many of a session's most recent messages a read considers.
///
/// Applied to every read, `Tail` and `FromOffset` alike, on purpose: a `read`'s byte offset
/// has to describe a position in whatever text a later read of the same window reconstructs,
/// and a limit that only `Tail` obeyed would make that text depend on which kind of read asked
/// for it — a `FromOffset` continuation right after a `Tail` one would then start from a
/// different transcript than the one the offset was measured against. Four thousand messages
/// is far beyond anything a real session leaves behind in this adapter's own tests, so nothing
/// observable changes for an ordinary one; it only stops a session that grew far larger from
/// being read and parsed from its very first row on every single call.
const MAX_MESSAGE_ROWS: u32 = 4_000;

/// The conversation of one session as plain text, one `role: text` line per message.
///
/// The same shape the other adapters render, so a reader of the companion sees one format
/// whichever harness the session ran on. Rows without text — an assistant turn that is
/// nothing but a tool call — leave no line: there is no text to quote, and inventing one
/// would put words in an agent's mouth.
pub fn transcript(db: &Path, session_id: &str) -> Result<String, StoreError> {
    transcript_limited(db, session_id, MAX_MESSAGE_ROWS)
}

fn transcript_limited(db: &Path, session_id: &str, row_limit: u32) -> Result<String, StoreError> {
    let connection = open(db)?;
    let unreadable = |source| StoreError::Unreadable {
        path: db.display().to_string(),
        source,
    };

    let exists: i64 = connection
        .query_row(
            "SELECT count(*) FROM sessions WHERE id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .map_err(unreadable)?;
    if exists == 0 {
        return Err(StoreError::UnknownSession {
            id: session_id.to_owned(),
        });
    }

    // Newest first with a `LIMIT`, rather than the whole table in ascending order: `dedupe`
    // sorts its result by the earliest id in every group regardless of what order the rows
    // arrived in, so nothing downstream needs to know this query ran backwards.
    let mut statement = connection
        .prepare(
            "SELECT id, active, role, content, tool_call_id, tool_calls, tool_name, timestamp \
             FROM messages \
             WHERE session_id = ?1 AND (active = 1 OR compacted = 1) \
             ORDER BY id DESC LIMIT ?2",
        )
        .map_err(unreadable)?;
    let rows = statement
        .query_map(rusqlite::params![session_id, row_limit], |row| {
            Ok(Message {
                id: row.get(0)?,
                active: row.get::<_, Option<i64>>(1)?.unwrap_or(0),
                role: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                content: row.get(3)?,
                tool_call_id: row.get(4)?,
                tool_calls: row.get(5)?,
                tool_name: row.get(6)?,
                timestamp: row.get::<_, Option<f64>>(7)?.unwrap_or(0.0),
            })
        })
        .map_err(unreadable)?;

    let mut messages = Vec::new();
    for row in rows {
        messages.push(row.map_err(unreadable)?);
    }

    let mut text = String::new();
    for message in dedupe(messages) {
        let Some(spoken) = message.content.as_deref().and_then(content_text) else {
            continue;
        };
        let spoken = spoken.trim();
        if spoken.is_empty() {
            continue;
        }
        text.push_str(&message.role);
        text.push_str(": ");
        text.push_str(spoken);
        text.push('\n');
    }
    Ok(text)
}

/// Collapses the copies compaction leaves behind, keeping the live row and otherwise the
/// newest one. The key is Hermes' own: role, content, timestamp and the three tool fields,
/// so two genuinely different tool calls that happen to agree on role and text stay apart.
///
/// The transcript is ordered by the *earliest* id in every group, not by whichever copy
/// ends up kept: compaction's live copy carries a new, larger id than the message it stands
/// in for, so ordering by the kept row's own id would place an old message after everything
/// that was said since — including its own answer.
fn dedupe(messages: Vec<Message>) -> Vec<Message> {
    /// Role, content, timestamp and the three tool fields. The timestamp goes in as its
    /// bits: it is a float in the store, and two rows either carry the same one or they do
    /// not — no rounding is wanted here.
    type Key = (
        String,
        Option<String>,
        u64,
        Option<String>,
        Option<String>,
        Option<String>,
    );

    let mut seen: std::collections::HashMap<Key, (i64, Message)> = std::collections::HashMap::new();

    for message in messages {
        let key: Key = (
            message.role.clone(),
            message.content.clone(),
            message.timestamp.to_bits(),
            message.tool_call_id.clone(),
            message.tool_calls.clone(),
            message.tool_name.clone(),
        );
        match seen.get_mut(&key) {
            Some((earliest_id, kept)) => {
                *earliest_id = (*earliest_id).min(message.id);
                if (kept.active, kept.id) < (message.active, message.id) {
                    *kept = message;
                }
            }
            None => {
                seen.insert(key, (message.id, message));
            }
        }
    }

    let mut kept: Vec<(i64, Message)> = seen.into_values().collect();
    kept.sort_by_key(|(earliest_id, _)| *earliest_id);
    kept.into_iter().map(|(_, message)| message).collect()
}

/// The text of a content field, whether it is a plain string or a structured turn.
fn content_text(content: &str) -> Option<String> {
    let Some(encoded) = content.strip_prefix(JSON_MARKER) else {
        return Some(content.to_owned());
    };
    let value: serde_json::Value = serde_json::from_str(encoded).ok()?;
    if let Some(text) = value.as_str() {
        return Some(text.to_owned());
    }
    let parts: Vec<&str> = value
        .as_array()?
        .iter()
        .filter(|part| part.get("type").and_then(serde_json::Value::as_str) == Some("text"))
        .filter_map(|part| part.get("text").and_then(serde_json::Value::as_str))
        .collect();
    (!parts.is_empty()).then(|| parts.join("\n"))
}

/// Opens the store read-only.
///
/// Read-only is the point, not a precaution: this is another program's database, and it may
/// be open and writing while this runs. SQLite's own locking is what makes that safe, and a
/// connection that cannot write cannot disturb it even in principle.
fn open(db: &Path) -> Result<Connection, StoreError> {
    if !db.exists() {
        return Err(StoreError::Missing {
            path: db.display().to_string(),
        });
    }
    Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|source| StoreError::Unreadable {
        path: db.display().to_string(),
        source,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn a_structured_turn_yields_its_text_and_leaves_the_image_out() {
        let encoded = format!(
            "{JSON_MARKER}[{{\"type\":\"text\",\"text\":\"Und dieses Bild?\"}},{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"data:image/png;base64,AAAA\"}}}}]"
        );
        assert_eq!(content_text(&encoded).as_deref(), Some("Und dieses Bild?"));
    }

    #[test]
    fn a_plain_string_passes_through_untouched() {
        assert_eq!(
            content_text("Was steht drin?").as_deref(),
            Some("Was steht drin?")
        );
    }

    #[test]
    fn the_live_copy_of_a_compacted_message_is_the_one_that_stays() {
        let archived = Message {
            id: 1,
            active: 0,
            role: "user".to_owned(),
            content: Some("hallo".to_owned()),
            tool_call_id: None,
            tool_calls: None,
            tool_name: None,
            timestamp: 12.5,
        };
        let copy = Message {
            id: 8,
            active: 1,
            ..archived.clone()
        };
        let kept = dedupe(vec![archived, copy]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].id, 8);
    }

    #[test]
    fn dedupe_orders_by_when_a_message_was_first_said_not_by_the_kept_copys_own_id() {
        let archived = Message {
            id: 1,
            active: 0,
            role: "user".to_owned(),
            content: Some("frueh gesagt".to_owned()),
            tool_call_id: None,
            tool_calls: None,
            tool_name: None,
            timestamp: 1.0,
        };
        let between = Message {
            id: 3,
            active: 1,
            role: "assistant".to_owned(),
            content: Some("dazwischen".to_owned()),
            tool_call_id: None,
            tool_calls: None,
            tool_name: None,
            timestamp: 2.0,
        };
        let live_copy = Message {
            id: 8,
            active: 1,
            ..archived.clone()
        };
        let kept = dedupe(vec![archived, between, live_copy]);
        let texts: Vec<&str> = kept.iter().filter_map(|m| m.content.as_deref()).collect();
        assert_eq!(
            texts,
            vec!["frueh gesagt", "dazwischen"],
            "the compacted message stays where it was first said, not where its live \
             copy's larger id would put it"
        );
    }

    fn minimal_store(dir: &Path) -> PathBuf {
        let db = dir.join("state.db");
        let connection = Connection::open(&db).unwrap();
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
                 );",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO sessions (id, source, started_at, cwd) VALUES ('s-1', 'acp', 1.0, '/tmp')",
                [],
            )
            .unwrap();
        db
    }

    #[test]
    fn the_row_limit_keeps_only_the_most_recent_messages() {
        let dir = std::env::temp_dir().join(format!("hermes-store-limit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db = minimal_store(&dir);
        let connection = Connection::open(&db).unwrap();
        for index in 0..5 {
            connection
                .execute(
                    "INSERT INTO messages (session_id, role, content, timestamp, active, compacted) \
                     VALUES ('s-1', 'user', ?1, ?2, 1, 0)",
                    rusqlite::params![format!("nachricht {index}"), index as f64],
                )
                .unwrap();
        }
        drop(connection);

        let text = transcript_limited(&db, "s-1", 2).unwrap();
        assert_eq!(
            text, "user: nachricht 3\nuser: nachricht 4\n",
            "only the most recent rows within the limit"
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
