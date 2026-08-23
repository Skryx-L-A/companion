// SPDX-License-Identifier: AGPL-3.0-only

//! The register: what ran, when, and what it left behind.
//!
//! SQLite under the configuration directory, as `DESIGN.md` § Datenmodelle prescribes. The
//! schema carries its version in SQLite's own `user_version`, and migrations run forward
//! one step at a time on open, so an older database is upgraded rather than rejected.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Mutex;

use companion_protocol::{
    AuftragId, Cost, Provenance, REGISTRY_SCHEMA_VERSION, RegistryEntry, SelfAnswer, SessionId,
};
use rusqlite::{Connection, OptionalExtension, params};
use thiserror::Error;

/// The migrations, in order. Index 0 takes an empty database to schema version 1.
///
/// A migration is never edited after it has shipped; a change gets a new entry, and the
/// length of this list is the current schema version.
const MIGRATIONS: &[&str] = &["CREATE TABLE registry_entries (
        session_id     TEXT PRIMARY KEY,
        auftrag_id     TEXT,
        project        TEXT,
        started_at_ms  INTEGER NOT NULL,
        ended_at_ms    INTEGER,
        result_path    TEXT,
        open_points    TEXT NOT NULL,
        self_answers   TEXT NOT NULL,
        cost           TEXT NOT NULL
    );
    CREATE INDEX registry_entries_started_at ON registry_entries (started_at_ms DESC);"];

#[derive(Debug, Error)]
pub enum RegistryError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("stored column {column} is not valid JSON: {source}")]
    Decode {
        column: &'static str,
        #[source]
        source: serde_json::Error,
    },
    #[error("database has schema version {found}, this build understands {expected}")]
    NewerSchema { found: u32, expected: u32 },
    #[error("cannot prepare {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
}

/// The register store.
///
/// rusqlite is synchronous and the register is written a few times per session, so the
/// connection sits behind a mutex instead of a connection pool.
#[derive(Debug)]
pub struct Registry {
    connection: Mutex<Connection>,
}

impl Registry {
    pub fn open(path: &Path) -> Result<Self, RegistryError> {
        if let Some(parent) = path.parent() {
            crate::paths::ensure_private_dir(parent).map_err(|source| RegistryError::Io {
                path: parent.display().to_string(),
                source,
            })?;
        }
        let connection = Connection::open(path)?;
        // Owner-only before the first write, so SQLite copies the mode onto the -wal and
        // -shm files it creates next. The directory is already 0700; this is the second
        // lock on a file that names projects and quotes session output.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(
            |source| RegistryError::Io {
                path: path.display().to_string(),
                source,
            },
        )?;
        Self::from_connection(connection)
    }

    /// For tests and for a daemon run that must not leave anything behind.
    pub fn open_in_memory() -> Result<Self, RegistryError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> Result<Self, RegistryError> {
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", true)?;
        let registry = Self {
            connection: Mutex::new(connection),
        };
        registry.migrate()?;
        Ok(registry)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        // A poisoned mutex means another thread panicked while holding it. The register is
        // append-mostly and every write is a single statement, so the data is still
        // consistent and going on is better than taking the daemon down with it.
        self.connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Brings the database up to [`MIGRATIONS`], one step per transaction.
    fn migrate(&self) -> Result<(), RegistryError> {
        let mut connection = self.lock();
        let current: u32 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        let target = MIGRATIONS.len() as u32;

        if current > target {
            return Err(RegistryError::NewerSchema {
                found: current,
                expected: target,
            });
        }

        for (index, migration) in MIGRATIONS.iter().enumerate().skip(current as usize) {
            let transaction = connection.transaction()?;
            transaction.execute_batch(migration)?;
            transaction.pragma_update(None, "user_version", index as u32 + 1)?;
            transaction.commit()?;
        }
        Ok(())
    }

    pub fn schema_version(&self) -> Result<u32, RegistryError> {
        Ok(self
            .lock()
            .query_row("PRAGMA user_version", [], |row| row.get(0))?)
    }

    /// Writes an entry, replacing an earlier one for the same session.
    pub fn upsert(&self, entry: &RegistryEntry) -> Result<(), RegistryError> {
        let open_points = encode("open_points", &entry.open_points)?;
        let self_answers = encode("self_answers", &entry.self_answers)?;
        let cost = encode("cost", &entry.cost)?;

        self.lock().execute(
            "INSERT INTO registry_entries
                (session_id, auftrag_id, project, started_at_ms, ended_at_ms, result_path,
                 open_points, self_answers, cost)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(session_id) DO UPDATE SET
                auftrag_id = excluded.auftrag_id,
                project = excluded.project,
                started_at_ms = excluded.started_at_ms,
                ended_at_ms = excluded.ended_at_ms,
                result_path = excluded.result_path,
                open_points = excluded.open_points,
                self_answers = excluded.self_answers,
                cost = excluded.cost",
            params![
                entry.session_id.as_str(),
                entry.auftrag_id.as_ref().map(AuftragId::as_str),
                entry.project,
                // SQLite stores signed 64-bit integers; a millisecond timestamp fits with
                // room to spare, so the cast is safe for any date this program can see.
                entry.started_at_ms as i64,
                entry.ended_at_ms.map(|stamp| stamp as i64),
                entry.result_path,
                open_points,
                self_answers,
                cost,
            ],
        )?;
        Ok(())
    }

    pub fn get(&self, session_id: &SessionId) -> Result<Option<RegistryEntry>, RegistryError> {
        self.lock()
            .query_row(
                "SELECT session_id, auftrag_id, project, started_at_ms, ended_at_ms,
                        result_path, open_points, self_answers, cost
                 FROM registry_entries WHERE session_id = ?1",
                params![session_id.as_str()],
                decode_row,
            )
            .optional()?
            .transpose()
    }

    /// The most recent entries, newest first.
    pub fn recent(&self, limit: u32) -> Result<Vec<RegistryEntry>, RegistryError> {
        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT session_id, auftrag_id, project, started_at_ms, ended_at_ms,
                    result_path, open_points, self_answers, cost
             FROM registry_entries ORDER BY started_at_ms DESC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit], decode_row)?;

        let mut entries = Vec::new();
        for row in rows {
            entries.push(row??);
        }
        Ok(entries)
    }
}

fn encode<T: serde::Serialize>(column: &'static str, value: &T) -> Result<String, RegistryError> {
    serde_json::to_string(value).map_err(|source| RegistryError::Decode { column, source })
}

fn decode<T: serde::de::DeserializeOwned>(
    column: &'static str,
    text: &str,
) -> Result<T, RegistryError> {
    serde_json::from_str(text).map_err(|source| RegistryError::Decode { column, source })
}

/// Reads one row. The outer `Result` belongs to rusqlite, the inner one to the JSON
/// columns, which rusqlite cannot decode for us.
fn decode_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Result<RegistryEntry, RegistryError>> {
    let session_id: String = row.get(0)?;
    let auftrag_id: Option<String> = row.get(1)?;
    let project: Option<String> = row.get(2)?;
    let started_at_ms: i64 = row.get(3)?;
    let ended_at_ms: Option<i64> = row.get(4)?;
    let result_path: Option<String> = row.get(5)?;
    let open_points: String = row.get(6)?;
    let self_answers: String = row.get(7)?;
    let cost: String = row.get(8)?;

    Ok((|| {
        Ok(RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: SessionId::new(session_id),
            auftrag_id: auftrag_id.map(AuftragId::new),
            project,
            started_at_ms: started_at_ms as u64,
            ended_at_ms: ended_at_ms.map(|stamp| stamp as u64),
            result_path,
            open_points: decode::<Vec<String>>("open_points", &open_points)?,
            self_answers: decode::<Vec<SelfAnswer>>("self_answers", &self_answers)?,
            cost: decode::<Provenance<Cost>>("cost", &cost)?,
        })
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(session: &str) -> RegistryEntry {
        RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: SessionId::new(session),
            auftrag_id: Some(AuftragId::new("job-1")),
            project: Some("/Users/me/AI/companion".to_owned()),
            started_at_ms: 1_700_000_000_000,
            ended_at_ms: None,
            result_path: None,
            open_points: vec!["signing key missing".to_owned()],
            self_answers: vec![SelfAnswer {
                question: "may I write outside the worktree".to_owned(),
                answer: "no".to_owned(),
                source: "guardrails".to_owned(),
                answered_at_ms: 1_700_000_001_000,
            }],
            cost: Provenance::Estimated(Cost {
                tokens: Some(12_000),
                usd: None,
            }),
        }
    }

    #[test]
    fn a_fresh_database_is_migrated_to_the_current_schema() {
        let registry = Registry::open_in_memory().unwrap();
        assert_eq!(registry.schema_version().unwrap(), MIGRATIONS.len() as u32);
    }

    #[test]
    fn migrating_twice_changes_nothing() {
        let registry = Registry::open_in_memory().unwrap();
        registry.migrate().unwrap();
        assert_eq!(registry.schema_version().unwrap(), MIGRATIONS.len() as u32);
    }

    #[test]
    fn an_entry_survives_the_round_trip_including_provenance() {
        let registry = Registry::open_in_memory().unwrap();
        let entry = entry("session-a");
        registry.upsert(&entry).unwrap();

        let loaded = registry.get(&SessionId::new("session-a")).unwrap().unwrap();
        assert_eq!(loaded, entry);
        assert!(matches!(loaded.cost, Provenance::Estimated(_)));
    }

    #[test]
    fn an_unknown_session_is_none_rather_than_an_error() {
        let registry = Registry::open_in_memory().unwrap();
        assert!(registry.get(&SessionId::new("nobody")).unwrap().is_none());
    }

    #[test]
    fn a_second_write_updates_instead_of_duplicating() {
        let registry = Registry::open_in_memory().unwrap();
        registry.upsert(&entry("session-a")).unwrap();

        let mut finished = entry("session-a");
        finished.ended_at_ms = Some(1_700_000_500_000);
        finished.result_path = Some("/tmp/result.md".to_owned());
        registry.upsert(&finished).unwrap();

        let all = registry.recent(10).unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].ended_at_ms, Some(1_700_000_500_000));
    }

    #[test]
    fn recent_returns_the_newest_first() {
        let registry = Registry::open_in_memory().unwrap();
        let mut older = entry("older");
        older.started_at_ms = 1_000;
        let mut newer = entry("newer");
        newer.started_at_ms = 2_000;
        registry.upsert(&older).unwrap();
        registry.upsert(&newer).unwrap();

        let all = registry.recent(10).unwrap();
        assert_eq!(all[0].session_id.as_str(), "newer");
        assert_eq!(all[1].session_id.as_str(), "older");
    }

    #[test]
    fn a_database_from_a_newer_build_is_refused() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "user_version", MIGRATIONS.len() as u32 + 1)
            .unwrap();

        let error = Registry::from_connection(connection).expect_err("must not downgrade");
        assert!(matches!(error, RegistryError::NewerSchema { .. }));
    }
}
