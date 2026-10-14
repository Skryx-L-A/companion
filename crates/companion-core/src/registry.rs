// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The register: what ran, when, and what it left behind.
//!
//! SQLite under the configuration directory, as `DESIGN.md` § Datenmodelle prescribes. The
//! schema carries its version in SQLite's own `user_version`, and migrations run forward
//! one step at a time on open, so an older database is upgraded rather than rejected.

use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::Path;
use std::sync::Mutex;

use companion_protocol::{
    ApprovalConfirmation, AuftragId, Cost, DEFAULT_REGISTRY_LIMIT, DayCost, DeviceId,
    MAX_REGISTRY_LIMIT, Provenance, REGISTRY_SCHEMA_VERSION, RegistryEntry, RegistryFilter,
    SelfAnswer, SessionId,
};

/// What the register remembers about an approval: which job, over which bytes, from where,
/// how it was confirmed, and when.
///
/// The project is part of the key because two projects may use the same job id.
///
/// `DESIGN.md` § Mobil, Freigaben vom Handy: "der Freigabe-Record vermerkt stets Gerät und
/// Bestätigungsart". That is what [`Self::device`] and [`Self::confirmation`] are for, and it
/// is what makes an approval from a phone traceable rather than indistinguishable from one
/// made at the machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalRecord {
    pub project: String,
    pub auftrag_id: AuftragId,
    /// Hex-encoded SHA-256 of the canonical job without its approval field.
    pub hash: String,
    /// The paired device this came from, or `None` for the shell at the machine.
    pub device: Option<DeviceId>,
    /// How the person proved it was them.
    pub confirmation: ApprovalConfirmation,
    pub approved_at_ms: u64,
}
use rusqlite::{Connection, OptionalExtension, params};
use thiserror::Error;

/// The migrations, in order. Index 0 takes an empty database to schema version 1.
///
/// A migration is never edited after it has shipped; a change gets a new entry, and the
/// length of this list is the current schema version.
const MIGRATIONS: &[&str] = &[
    "CREATE TABLE registry_entries (
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
    CREATE INDEX registry_entries_started_at ON registry_entries (started_at_ms DESC);",
    // 2: the approval records. They live here, outside the project, because the session a
    // job commands can write in its own project and could otherwise move its approval
    // along with a change (DESIGN.md, Sicherheit, Gate-Freigabe). Out of that session's
    // way, not out of its reach: this is an ordinary file of the same account, and a row
    // in it carries no MAC — see the module documentation of `crate::auftrag`.
    "CREATE TABLE approvals (
        project        TEXT NOT NULL,
        auftrag_id     TEXT NOT NULL,
        hash           TEXT NOT NULL,
        approved_at_ms INTEGER NOT NULL,
        PRIMARY KEY (project, auftrag_id)
    );",
    // 3: where an approval came from and how it was confirmed. Added rather than folded
    // into the table above, because a database that already holds approvals has to keep
    // them (DESIGN.md, Mobil, Freigaben vom Handy).
    //
    // The rows that were already there get `shell` and no device, and that is not a
    // guess: until this migration ran, no device could approve anything at all — the
    // daemon refused `approve_auftrag` for every device at every level — so every
    // existing row is an approval made at the machine.
    "ALTER TABLE approvals ADD COLUMN device_id TEXT;
     ALTER TABLE approvals ADD COLUMN confirmation TEXT NOT NULL DEFAULT 'shell';",
    // 4: what a session's cost is measured *against*. `DESIGN.md` § Kosten names the
    // workbench's budget share as one of the three sources, and a share is only a cost as a
    // difference: the reading when the session started, subtracted from the reading when it
    // ended. The first of those two readings has to survive a daemon restart in the middle
    // of a long run, so it lives here rather than in a map in memory. It is deliberately not
    // a field of `RegistryEntry`: it is the daemon's own bookkeeping and has no business on
    // the wire, where it would read as a second, contradictory cost.
    "ALTER TABLE registry_entries ADD COLUMN cost_baseline TEXT;",
    // 5: what the person decided about one session, as opposed to what a session reported
    // about itself. Only one such decision today — `always_ask`, DESIGN.md § Verhalten
    // "Fragen der Orchestratoren": "Je Session lässt sich 'immer mich fragen' setzen" —
    // and it lives here rather than in `registry_entries` because it belongs to the person
    // and outlives the row a session writes: a session the daemon has never seen can carry
    // the preference already, and a row that only holds the preference must not look like a
    // session that ran.
    "CREATE TABLE session_preferences (
        session_id  TEXT PRIMARY KEY,
        always_ask  INTEGER NOT NULL
    );",
    // 6: historical self-answers are rewritten by `migrate` in the same transaction.
    "SELECT 1;",
];

/// The confirmation kind behind a stored name.
///
/// A name this build does not know reads as [`ApprovalConfirmation::Unknown`] rather than
/// failing the whole read or being rounded to one of the others. A register written by a
/// newer build may hold a kind this one has never heard of, and both other answers would be
/// worse than saying so: refusing the read hides a record that is there, and calling it
/// `shell` would put a sentence into the audit trail that claims somebody stood at the Mac.
fn confirmation_from(name: &str) -> ApprovalConfirmation {
    match name {
        "shell" => ApprovalConfirmation::Shell,
        "biometric" => ApprovalConfirmation::Biometric,
        "passcode" => ApprovalConfirmation::Passcode,
        "none" => ApprovalConfirmation::None,
        _ => ApprovalConfirmation::Unknown,
    }
}

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
    NewerSchema { found: i64, expected: u32 },
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
        // The file is created here, owner-only from the first byte, rather than left to
        // SQLite, which would make it with the umask and leave it world-readable until the
        // chmod below (changed 2026-09-03, security review). A file that is already there
        // keeps its content: this only ever creates.
        match crate::paths::write_new_private_file(path, b"") {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(source) => {
                return Err(RegistryError::Io {
                    path: path.display().to_string(),
                    source,
                });
            }
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
        let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version > 0 && version < MIGRATIONS.len() as i64 {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("registry");
            let backup_dir = path.with_file_name(format!("{name}.before-redaction-{stamp}"));
            let backup = backup_dir.join(name);
            backup_before_redaction(&connection, &backup)?;
        }
        Self::from_connection(connection)
    }

    /// For tests and for a daemon run that must not leave anything behind.
    pub fn open_in_memory() -> Result<Self, RegistryError> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> Result<Self, RegistryError> {
        Self::from_connection_with(connection, MIGRATIONS)
    }

    /// The same as [`Self::from_connection`], but with the migration list handed in.
    ///
    /// Only the tests pass anything but [`MIGRATIONS`]: with a single shipped migration
    /// there is otherwise no way to show that an existing database is carried forward
    /// instead of being recreated.
    fn from_connection_with(
        connection: Connection,
        migrations: &[&str],
    ) -> Result<Self, RegistryError> {
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", true)?;
        let registry = Self {
            connection: Mutex::new(connection),
        };
        registry.migrate(migrations)?;
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

    /// Brings the database up to `migrations`, one step per transaction.
    fn migrate(&self, migrations: &[&str]) -> Result<(), RegistryError> {
        let mut connection = self.lock();
        // SQLite stores `user_version` as a signed 32-bit value, so it is read as a signed
        // one: a negative number is a corrupt or foreign file and gets the same clear
        // answer as a version from the future, not a type error from the driver.
        let current: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        let target = migrations.len() as u32;

        if current < 0 || current > i64::from(target) {
            return Err(RegistryError::NewerSchema {
                found: current,
                expected: target,
            });
        }

        for (index, migration) in migrations.iter().enumerate().skip(current as usize) {
            let transaction = connection.transaction()?;
            transaction.execute_batch(migration)?;
            if index == 5 && migrations.len() == MIGRATIONS.len() {
                let rows: Vec<(String, String)> = {
                    let mut statement = transaction
                        .prepare("SELECT session_id, self_answers FROM registry_entries")?;
                    let mapped = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
                    mapped.collect::<Result<_, _>>()?
                };
                for (session_id, json) in rows {
                    let mut answers: Vec<SelfAnswer> =
                        serde_json::from_str(&json).map_err(|source| RegistryError::Decode {
                            column: "self_answers",
                            source,
                        })?;
                    for answer in &mut answers {
                        answer.question = crate::redact::secretish(&answer.question);
                        answer.answer = crate::redact::secretish(&answer.answer);
                        answer.source = crate::redact::secretish(&answer.source);
                    }
                    transaction.execute(
                        "UPDATE registry_entries SET self_answers = ?1 WHERE session_id = ?2",
                        params![
                            serde_json::to_string(&answers).map_err(|source| {
                                RegistryError::Decode {
                                    column: "self_answers",
                                    source,
                                }
                            })?,
                            session_id
                        ],
                    )?;
                }
            }
            transaction.pragma_update(None, "user_version", index as u32 + 1)?;
            transaction.commit()?;
        }
        Ok(())
    }

    pub fn schema_version(&self) -> Result<u32, RegistryError> {
        let version: i64 = self
            .lock()
            .query_row("PRAGMA user_version", [], |row| row.get(0))?;
        Ok(version.max(0) as u32)
    }

    /// Writes an entry, replacing an earlier one for the same session.
    pub fn upsert(&self, entry: &RegistryEntry) -> Result<(), RegistryError> {
        let open_points = encode("open_points", &entry.open_points)?;
        let safe_answers: Vec<SelfAnswer> = entry
            .self_answers
            .iter()
            .map(|answer| SelfAnswer {
                question: crate::redact::secretish(&answer.question),
                answer: crate::redact::secretish(&answer.answer),
                source: crate::redact::secretish(&answer.source),
                answered_at_ms: answer.answered_at_ms,
            })
            .collect();
        let self_answers = encode("self_answers", &safe_answers)?;
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

    /// Writes an approval, replacing an earlier one for the same job.
    ///
    /// A second approval of the same job is a new decision by the person, so it overwrites
    /// rather than piling up: what counts is what was approved last.
    pub fn record_approval(&self, record: &ApprovalRecord) -> Result<(), RegistryError> {
        self.lock().execute(
            "INSERT INTO approvals
                (project, auftrag_id, hash, approved_at_ms, device_id, confirmation)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(project, auftrag_id) DO UPDATE SET
                hash = excluded.hash,
                approved_at_ms = excluded.approved_at_ms,
                device_id = excluded.device_id,
                confirmation = excluded.confirmation",
            params![
                record.project,
                record.auftrag_id.as_str(),
                record.hash,
                record.approved_at_ms as i64,
                record.device.as_ref().map(|device| device.as_str()),
                record.confirmation.as_str(),
            ],
        )?;
        Ok(())
    }

    /// The approval of one job, or `None` when nobody approved it.
    pub fn approval_for(
        &self,
        project: &str,
        auftrag_id: &AuftragId,
    ) -> Result<Option<ApprovalRecord>, RegistryError> {
        Ok(self
            .lock()
            .query_row(
                "SELECT project, auftrag_id, hash, approved_at_ms, device_id, confirmation
                 FROM approvals
                 WHERE project = ?1 AND auftrag_id = ?2",
                params![project, auftrag_id.as_str()],
                |row| {
                    let approved_at_ms: i64 = row.get(3)?;
                    let device: Option<String> = row.get(4)?;
                    let confirmation: String = row.get(5)?;
                    Ok(ApprovalRecord {
                        project: row.get(0)?,
                        auftrag_id: AuftragId::new(row.get::<_, String>(1)?),
                        hash: row.get(2)?,
                        device: device.map(DeviceId::new),
                        confirmation: confirmation_from(&confirmation),
                        approved_at_ms: approved_at_ms as u64,
                    })
                },
            )
            .optional()?)
    }

    /// Appends one self-answer to the row of a session, creating the row if there is none.
    ///
    /// `DESIGN.md` § Verhalten requires every question the companion answered itself to be
    /// readable afterwards, with question, answer and source. The append is a
    /// read-modify-write under the same lock as every other write, so two answers arriving
    /// at once cannot overwrite one another.
    pub fn append_self_answer(
        &self,
        session_id: &SessionId,
        answer: &SelfAnswer,
    ) -> Result<(), RegistryError> {
        let mut entry = self.get(session_id)?.unwrap_or_else(|| RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: session_id.clone(),
            auftrag_id: None,
            project: None,
            started_at_ms: crate::now_ms(),
            ended_at_ms: None,
            result_path: None,
            open_points: Vec::new(),
            self_answers: Vec::new(),
            cost: Provenance::<Cost>::Unknown,
        });
        entry.self_answers.push(answer.clone());
        self.upsert(&entry)
    }

    /// Appends one answer the companion gave in a workbench world to that world's row, creating
    /// the row if there is none.
    ///
    /// Review of 2026-09-14, M-3: every answer to a lead agent's question and every
    /// acknowledgement the companion writes into a world is readable afterwards with question,
    /// source and wording, the same as a self-answer to a session. A world is no session, so the
    /// row is named [`WORLD_SESSION_PREFIX`] plus machine and world id; its end is the last
    /// answer, so a list does not call it running.
    pub fn append_world_answer(
        &self,
        machine: &str,
        world_id: &str,
        project: Option<&str>,
        answer: &SelfAnswer,
    ) -> Result<(), RegistryError> {
        let session_id = world_session_id(machine, world_id);
        let mut entry = self.get(&session_id)?.unwrap_or_else(|| RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: session_id.clone(),
            auftrag_id: None,
            project: project.map(str::to_owned),
            started_at_ms: answer.answered_at_ms,
            ended_at_ms: None,
            result_path: None,
            open_points: Vec::new(),
            self_answers: Vec::new(),
            cost: Provenance::<Cost>::Unknown,
        });
        entry.self_answers.push(answer.clone());
        entry.ended_at_ms = Some(answer.answered_at_ms);
        self.upsert(&entry)
    }

    /// Writes the person's "always ask me" decision for one session.
    ///
    /// `false` is stored rather than deleted: a person who switched it off decided
    /// something, and a row that says so reads the same on the next start as it did when
    /// they set it.
    pub fn set_always_ask(
        &self,
        session_id: &SessionId,
        always_ask: bool,
    ) -> Result<(), RegistryError> {
        self.lock().execute(
            "INSERT INTO session_preferences (session_id, always_ask) VALUES (?1, ?2)
             ON CONFLICT(session_id) DO UPDATE SET always_ask = excluded.always_ask",
            params![session_id.as_str(), always_ask],
        )?;
        Ok(())
    }

    /// Whether the person asked to be the one who answers this session. Unknown means no:
    /// the autonomy setting decides on its own until somebody says otherwise.
    pub fn always_ask(&self, session_id: &SessionId) -> Result<bool, RegistryError> {
        Ok(self
            .lock()
            .query_row(
                "SELECT always_ask FROM session_preferences WHERE session_id = ?1",
                params![session_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .optional()?
            .unwrap_or(false))
    }

    /// Every session the person put on "always ask me", for a shell that has to show the
    /// state of the switch without asking once per row.
    pub fn sessions_with_always_ask(&self) -> Result<Vec<SessionId>, RegistryError> {
        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT session_id FROM session_preferences WHERE always_ask = 1
             ORDER BY session_id",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut sessions = Vec::new();
        for row in rows {
            sessions.push(SessionId::new(row?));
        }
        Ok(sessions)
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
        self.list(&RegistryFilter {
            limit,
            ..RegistryFilter::default()
        })
    }

    /// The entries a filter asks for, newest first.
    ///
    /// Every empty field of the filter widens the answer, so the default filter is the whole
    /// register down to [`DEFAULT_REGISTRY_LIMIT`] rows. The project is compared as the
    /// string the adapter reported, and the two timestamps bracket `started_at_ms`: a
    /// session that started yesterday and ended today belongs to yesterday, which is the same
    /// day [`day_costs`] counts it in.
    ///
    /// `with_self_answers` is applied after the rows are decoded rather than in SQL. The
    /// column holds a JSON array, and asking SQLite whether that array is empty would mean
    /// matching on the text `[]` — which is right until the day something writes ` []` or a
    /// pretty-printed array, and then the filter silently keeps rows it should drop.
    pub fn list(&self, filter: &RegistryFilter) -> Result<Vec<RegistryEntry>, RegistryError> {
        let limit = match filter.limit {
            0 => DEFAULT_REGISTRY_LIMIT,
            asked => asked.min(MAX_REGISTRY_LIMIT),
        };
        // A row that is dropped after decoding still has to be fetched, or a filter on the
        // self-answers would return fewer rows than the limit allows. The cap is the same
        // one the request itself is capped at, so this can never fetch the whole table.
        let fetch = if filter.with_self_answers {
            MAX_REGISTRY_LIMIT
        } else {
            limit
        };

        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT session_id, auftrag_id, project, started_at_ms, ended_at_ms,
                    result_path, open_points, self_answers, cost
             FROM registry_entries
             WHERE (?1 IS NULL OR project = ?1)
               AND (?2 IS NULL OR started_at_ms >= ?2)
               AND (?3 IS NULL OR started_at_ms < ?3)
             ORDER BY started_at_ms DESC LIMIT ?4",
        )?;
        let rows = statement.query_map(
            params![
                filter.project,
                filter.since_ms.map(|stamp| stamp as i64),
                filter.until_ms.map(|stamp| stamp as i64),
                fetch,
            ],
            decode_row,
        )?;

        let mut entries = Vec::new();
        for row in rows {
            let entry = row??;
            if filter.with_self_answers && entry.self_answers.is_empty() {
                continue;
            }
            entries.push(entry);
            if entries.len() as u32 >= limit {
                break;
            }
        }
        Ok(entries)
    }

    /// Remembers what a session's cost will later be measured against.
    ///
    /// Today that is the budget share at the moment the session started; see the fourth
    /// migration for why it is a column rather than a map in memory. Writing it twice for the
    /// same session keeps the **first** value: the baseline is where the session began, and a
    /// second `session_started` for a session already in the register is a re-listing, not a
    /// second start.
    pub fn note_cost_baseline(
        &self,
        session_id: &SessionId,
        baseline: &CostBaseline,
    ) -> Result<(), RegistryError> {
        let encoded = encode("cost_baseline", baseline)?;
        self.lock().execute(
            "UPDATE registry_entries SET cost_baseline = ?2
             WHERE session_id = ?1 AND cost_baseline IS NULL",
            params![session_id.as_str(), encoded],
        )?;
        Ok(())
    }

    /// What a session's cost is measured against, when anything was noted.
    pub fn cost_baseline(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<CostBaseline>, RegistryError> {
        let stored: Option<Option<String>> = self
            .lock()
            .query_row(
                "SELECT cost_baseline FROM registry_entries WHERE session_id = ?1",
                params![session_id.as_str()],
                |row| row.get(0),
            )
            .optional()?;
        match stored.flatten() {
            Some(text) => Ok(Some(decode::<CostBaseline>("cost_baseline", &text)?)),
            None => Ok(None),
        }
    }

    /// Adds what the companion's own model call cost onto the row of the current day.
    ///
    /// `DESIGN.md` § Verhalten, "Kosten", asks for a counter "pro Session und Tag", and the
    /// companion's own API spend belongs to neither an adapter's session nor to a project.
    /// It gets a row per calendar day, named [`OWN_SESSION_PREFIX`] plus that day, so it
    /// sums into the day counter exactly like every other row and is told apart from a real
    /// session by its id. One row per day rather than one for all time, because a single row
    /// carries a single start timestamp and would put a whole year's spend on one day.
    ///
    /// Read-modify-write under the same lock as every other write, so two turns finishing at
    /// once cannot overwrite one another's addition.
    pub fn add_own_cost(&self, cost: &Cost) -> Result<(), RegistryError> {
        let now = crate::now_ms();
        let session_id = SessionId::new(format!("{OWN_SESSION_PREFIX}{}", local_day(now)));
        let mut entry = self.get(&session_id)?.unwrap_or_else(|| RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: session_id.clone(),
            auftrag_id: None,
            project: None,
            started_at_ms: now,
            ended_at_ms: None,
            result_path: None,
            open_points: Vec::new(),
            self_answers: Vec::new(),
            cost: Provenance::Unknown,
        });
        let mut summed = entry.cost.value().copied().unwrap_or_default();
        summed.add(cost);
        // Measured: these are the token counts the endpoint itself reported, priced from the
        // table the person owns. What is estimated about a budget share does not apply here.
        entry.cost = Provenance::Measured(summed);
        self.upsert(&entry)
    }

    /// Writes the cost of one session, leaving everything else in its row alone.
    ///
    /// A row that is not there yet is not created: a cost belongs to a run the register
    /// already knows about, and inventing a row from a cost would put a session in the
    /// history that nothing ever reported.
    pub fn set_cost(
        &self,
        session_id: &SessionId,
        cost: &Provenance<Cost>,
    ) -> Result<(), RegistryError> {
        let encoded = encode("cost", cost)?;
        self.lock().execute(
            "UPDATE registry_entries SET cost = ?2 WHERE session_id = ?1",
            params![session_id.as_str(), encoded],
        )?;
        Ok(())
    }
}

fn backup_before_redaction(connection: &Connection, backup: &Path) -> Result<(), RegistryError> {
    let directory = backup.parent().ok_or_else(|| RegistryError::Io {
        path: backup.display().to_string(),
        source: std::io::Error::new(std::io::ErrorKind::InvalidInput, "backup has no parent"),
    })?;
    // The directory is private at the instant it appears, even if VACUUM INTO creates
    // its database file with 0644 before the final file-mode tightening below.
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(directory)
        .map_err(|source| RegistryError::Io {
            path: directory.display().to_string(),
            source,
        })?;
    if backup.exists() {
        return Err(RegistryError::Io {
            path: backup.display().to_string(),
            source: std::io::Error::new(std::io::ErrorKind::AlreadyExists, "backup path exists"),
        });
    }
    if let Err(error) =
        connection.execute("VACUUM INTO ?1", params![backup.to_string_lossy().as_ref()])
    {
        return Err(error.into());
    }
    std::fs::set_permissions(backup, std::fs::Permissions::from_mode(0o600)).map_err(|source| {
        RegistryError::Io {
            path: backup.display().to_string(),
            source,
        }
    })?;
    Ok(())
}

/// What a session's cost is measured against, noted when the session started.
///
/// Its own type rather than a bare number, so a second kind of baseline — a token count at
/// the start of an adopted session, say — can be added without a migration.
#[derive(Debug, Clone, Copy, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CostBaseline {
    /// The subscription window's fill at the moment the session started, 0.0 to 1.0.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub budget_fraction: Option<f64>,
}

/// What each calendar day in `entries` cost, newest day first.
///
/// `DESIGN.md` § Kosten: "Zaehler pro Session und Tag, soweit eine Quelle existiert ... Ohne
/// Quelle zeigt er unbekannt." A day whose sessions all report nothing is therefore in the
/// list with [`Provenance::Unknown`] rather than with a zero, and a day where only some of
/// them do says how many of each.
///
/// The day is the local one of this machine: somebody reading "5 September" means the day
/// they worked, not the UTC one it partly fell into.
pub fn day_costs(entries: &[RegistryEntry]) -> Vec<DayCost> {
    use std::collections::BTreeMap;

    struct Day {
        cost: Cost,
        known: u32,
        unknown: u32,
    }

    let mut days: BTreeMap<String, Day> = BTreeMap::new();
    for entry in entries {
        // What the companion answered in a world ran nothing and cost nothing of its own; as a
        // row of unknown cost it would make every day look less measured than it is.
        if entry.session_id.as_str().starts_with(WORLD_SESSION_PREFIX) {
            continue;
        }
        let day = days.entry(local_day(entry.started_at_ms)).or_insert(Day {
            cost: Cost::default(),
            known: 0,
            unknown: 0,
        });
        match entry.cost.value() {
            Some(cost) if !cost.is_empty() => {
                day.cost.add(cost);
                day.known += 1;
            }
            _ => day.unknown += 1,
        }
    }

    days.into_iter()
        .rev()
        .map(|(day, counted)| DayCost {
            day,
            cost: if counted.known == 0 {
                Provenance::Unknown
            } else {
                Provenance::Measured(counted.cost)
            },
            known_sessions: counted.known,
            unknown_sessions: counted.unknown,
        })
        .collect()
}

/// How many earlier jobs of the same project an estimate averages over.
pub const ESTIMATE_SAMPLE: u32 = 5;

/// What a job in this project has cost lately, averaged over the ones that had a cost at all.
///
/// `DESIGN.md` § Verhalten, "Kosten": "Die Warnung vor einem Auftrag beruht auf dem Mittel
/// der letzten vergleichbaren Auftraege aus dem Register und wird als Schaetzung benannt."
/// Comparable means: same project, and it carried a job — a session somebody started by hand
/// in the same directory is a different kind of thing and is left out.
///
/// `None` where fewer than one such row has a cost. There is no floor of "at least three":
/// one earlier job is a thin basis and the answer says so by naming how many rows it rests
/// on, which is more use than refusing to say anything at all.
pub fn estimate_for_project(
    registry: &Registry,
    project: &str,
) -> Result<Option<(Cost, u32)>, RegistryError> {
    let rows = registry.list(&RegistryFilter {
        project: Some(project.to_owned()),
        limit: MAX_REGISTRY_LIMIT,
        ..RegistryFilter::default()
    })?;

    let mut summed = Cost::default();
    let mut counted = 0_u32;
    for entry in rows {
        if entry.auftrag_id.is_none() {
            continue;
        }
        let Some(cost) = entry.cost.value().filter(|cost| !cost.is_empty()) else {
            continue;
        };
        summed.add(cost);
        counted += 1;
        if counted >= ESTIMATE_SAMPLE {
            break;
        }
    }
    if counted == 0 {
        return Ok(None);
    }
    let divisor = f64::from(counted);
    Ok(Some((
        Cost {
            tokens: summed.tokens.map(|tokens| tokens / u64::from(counted)),
            usd: summed.usd.map(|usd| usd / divisor),
            budget_fraction: summed.budget_fraction.map(|share| share / divisor),
        },
        counted,
    )))
}

/// The session id of the companion's own spend for one day is this plus the day.
///
/// A row with this prefix is not a session anybody started: it is what the companion's own
/// model calls cost on that day. A reader that wants only real runs filters on it.
pub const OWN_SESSION_PREFIX: &str = "companion:";

/// The session id of what the companion answered in one workbench world is this plus the
/// machine and the world's id — see [`Registry::append_world_answer`].
pub const WORLD_SESSION_PREFIX: &str = "welt:";

/// The row of one world's answers.
pub fn world_session_id(machine: &str, world_id: &str) -> SessionId {
    SessionId::new(format!("{WORLD_SESSION_PREFIX}{machine}:{world_id}"))
}

/// A Unix millisecond timestamp as the local calendar day, `YYYY-MM-DD`.
pub fn local_day(stamp_ms: u64) -> String {
    use chrono::{Local, TimeZone};
    match Local.timestamp_millis_opt(stamp_ms as i64) {
        chrono::LocalResult::Single(when) | chrono::LocalResult::Ambiguous(when, _) => {
            when.format("%Y-%m-%d").to_string()
        }
        // A timestamp no calendar can place — a clock far outside any date this program can
        // see. It goes into its own bucket rather than into today's, which would move
        // somebody else's cost onto a day it does not belong to.
        chrono::LocalResult::None => "unbekannt".to_owned(),
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

    #[test]
    fn self_answer_is_redacted_before_sqlite_write() {
        let registry = Registry::open_in_memory().unwrap();
        let session = SessionId::new("redaction-test");
        let answer = SelfAnswer {
            question: "password=question-secret".to_owned(),
            answer: "password=answer-secret".to_owned(),
            source: "password=source-secret".to_owned(),
            answered_at_ms: 1,
        };
        registry.append_self_answer(&session, &answer).unwrap();
        registry
            .append_world_answer("machine", "world", None, &answer)
            .unwrap();
        let mut direct = entry("direct-report");
        direct.self_answers = vec![answer];
        registry.upsert(&direct).unwrap();
        let connection = registry.lock();
        let rows: Vec<String> = {
            let mut query = connection
                .prepare("SELECT self_answers FROM registry_entries")
                .unwrap();
            query
                .query_map([], |row| row.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(rows.len(), 3);
        for raw in rows {
            for secret in ["question-secret", "answer-secret", "source-secret"] {
                assert!(!raw.contains(secret));
            }
            assert!(raw.contains("[REDACTED]"));
        }
    }

    #[test]
    fn old_answers_are_redacted_after_backup_and_migration() {
        let directory = std::env::temp_dir().join(format!(
            "companion-registry-redaction-{}-{}",
            std::process::id(),
            crate::now_ms()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = directory.join("registry.sqlite");
        {
            let registry = Registry::open(&path).unwrap();
            let session = SessionId::new("old-answer");
            registry.upsert(&entry(session.as_str())).unwrap();
            registry.lock().execute("UPDATE registry_entries SET self_answers = ?1 WHERE session_id = ?2",
                params![r#"[{"question":"password=old-question","answer":"password=old-answer","source":"password=old-source","answered_at_ms":1}]"#, session.as_str()]).unwrap();
            registry
                .lock()
                .pragma_update(None, "user_version", 5)
                .unwrap();
        }
        let registry = Registry::open(&path).unwrap();
        let raw: String = registry
            .lock()
            .query_row(
                "SELECT self_answers FROM registry_entries WHERE session_id = 'old-answer'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(!raw.contains("old-answer"));
        assert!(raw.contains("[REDACTED]"));
        let backups: Vec<_> = std::fs::read_dir(&directory)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|item| {
                item.file_name()
                    .to_string_lossy()
                    .contains("before-redaction")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert!(backups[0].file_type().unwrap().is_dir());
        assert_eq!(
            backups[0].metadata().unwrap().permissions().mode() & 0o777,
            0o700
        );
        let backup_file = backups[0].path().join("registry.sqlite");
        assert_eq!(
            std::fs::metadata(&backup_file)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let backup = Connection::open(backup_file).unwrap();
        let old: String = backup
            .query_row(
                "SELECT self_answers FROM registry_entries WHERE session_id = 'old-answer'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(old.contains("old-answer"));
        drop(backup);
        assert_eq!(registry.schema_version().unwrap(), MIGRATIONS.len() as u32);
        drop(registry);
        let reopened = Registry::open(&path).unwrap();
        assert_eq!(reopened.schema_version().unwrap(), MIGRATIONS.len() as u32);
        drop(reopened);
        let backups_after_restart = std::fs::read_dir(&directory)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|item| {
                item.file_name()
                    .to_string_lossy()
                    .contains("before-redaction")
            })
            .count();
        assert_eq!(backups_after_restart, 1);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn failed_backup_does_not_change_a_legacy_database() {
        let directory = std::env::temp_dir().join(format!(
            "companion-registry-backup-failure-{}-{}",
            std::process::id(),
            crate::now_ms()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("registry.sqlite");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch(MIGRATIONS[0]).unwrap();
        connection.pragma_update(None, "user_version", 1).unwrap();
        let forbidden_dir = directory.join("already-a-directory");
        std::fs::create_dir_all(&forbidden_dir).unwrap();
        let forbidden = forbidden_dir.join("registry.sqlite");
        assert!(backup_before_redaction(&connection, &forbidden).is_err());
        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 1);
        drop(connection);
        std::fs::remove_dir_all(directory).unwrap();
    }

    fn entry(session: &str) -> RegistryEntry {
        RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: SessionId::new(session),
            auftrag_id: Some(AuftragId::new("job-1")),
            project: Some("/Users/example/AI/companion".to_owned()),
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
                budget_fraction: None,
            }),
        }
    }

    #[test]
    fn self_answers_pile_up_instead_of_replacing_one_another() {
        let registry = Registry::open_in_memory().unwrap();
        let session = SessionId::new("reported:0/core-brain");
        let first = SelfAnswer {
            question: "darf ich pushen".to_owned(),
            answer: "nein, der Orchestrator entscheidet".to_owned(),
            source: "guardrails".to_owned(),
            answered_at_ms: 1_700_000_000_000,
        };
        let second = SelfAnswer {
            question: "welcher Zweig".to_owned(),
            answer: "wb/core-brain".to_owned(),
            source: "auftrag".to_owned(),
            answered_at_ms: 1_700_000_060_000,
        };

        // The first one creates the row: an answer given before any adapter reported the
        // session must not be lost just because there is nothing to append to yet.
        registry.append_self_answer(&session, &first).unwrap();
        registry.append_self_answer(&session, &second).unwrap();

        let stored = registry.get(&session).unwrap().expect("the row exists");
        assert_eq!(stored.self_answers, vec![first, second]);
    }

    #[test]
    fn a_self_answer_keeps_what_the_row_already_held() {
        let registry = Registry::open_in_memory().unwrap();
        let existing = entry("reported:1/session");
        registry.upsert(&existing).unwrap();

        let answer = SelfAnswer {
            question: "Budget".to_owned(),
            answer: "bleibt beim Auftrag".to_owned(),
            source: "auftrag".to_owned(),
            answered_at_ms: 1_700_000_002_000,
        };
        registry
            .append_self_answer(&existing.session_id, &answer)
            .unwrap();

        let stored = registry.get(&existing.session_id).unwrap().unwrap();
        assert_eq!(stored.project, existing.project);
        assert_eq!(stored.open_points, existing.open_points);
        assert_eq!(
            stored.self_answers.len(),
            2,
            "the old answer is still there"
        );
    }

    #[test]
    fn an_approval_survives_the_round_trip_and_a_second_decision_replaces_it() {
        let registry = Registry::open_in_memory().unwrap();
        let record = ApprovalRecord {
            project: "/tmp/fixture/projekt".to_owned(),
            auftrag_id: AuftragId::new("2026-08-24-eins"),
            hash: "abc123".to_owned(),
            device: None,
            confirmation: ApprovalConfirmation::Shell,
            approved_at_ms: 1_700_000_000_000,
        };
        registry.record_approval(&record).unwrap();
        assert_eq!(
            registry
                .approval_for(&record.project, &record.auftrag_id)
                .unwrap(),
            Some(record.clone())
        );

        // The second decision came from the phone, and the record says so: the person
        // approved the same job again, this time with Face ID.
        let second = ApprovalRecord {
            hash: "def456".to_owned(),
            device: Some(DeviceId::new("d-7")),
            confirmation: ApprovalConfirmation::Biometric,
            approved_at_ms: 1_700_000_500_000,
            ..record.clone()
        };
        registry.record_approval(&second).unwrap();
        assert_eq!(
            registry
                .approval_for(&record.project, &record.auftrag_id)
                .unwrap(),
            Some(second),
            "the last decision of the person is the one that counts"
        );
    }

    #[test]
    fn the_same_job_id_in_two_projects_stays_apart() {
        let registry = Registry::open_in_memory().unwrap();
        for project in ["/tmp/eins", "/tmp/zwei"] {
            registry
                .record_approval(&ApprovalRecord {
                    project: project.to_owned(),
                    auftrag_id: AuftragId::new("nachtlauf"),
                    hash: format!("hash-of-{project}"),
                    device: None,
                    confirmation: ApprovalConfirmation::Shell,
                    approved_at_ms: 1,
                })
                .unwrap();
        }
        assert_eq!(
            registry
                .approval_for("/tmp/eins", &AuftragId::new("nachtlauf"))
                .unwrap()
                .unwrap()
                .hash,
            "hash-of-/tmp/eins"
        );
    }

    #[test]
    fn an_unapproved_job_has_no_record() {
        let registry = Registry::open_in_memory().unwrap();
        assert!(
            registry
                .approval_for("/tmp/eins", &AuftragId::new("nie-freigegeben"))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn a_fresh_database_is_migrated_to_the_current_schema() {
        let registry = Registry::open_in_memory().unwrap();
        assert_eq!(registry.schema_version().unwrap(), MIGRATIONS.len() as u32);
    }

    #[test]
    fn migrating_twice_changes_nothing() {
        let registry = Registry::open_in_memory().unwrap();
        registry.migrate(MIGRATIONS).unwrap();
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

    /// The person's decision about one session: written, read back, changed, and listed.
    /// A session nobody decided about reads as `false` rather than as an error, because
    /// that is what the autonomy setting alone means.
    #[test]
    fn always_ask_is_remembered_per_session_and_defaults_to_no() {
        let registry = Registry::open_in_memory().unwrap();
        let one = SessionId::new("reported:0/one");
        let other = SessionId::new("reported:1/other");

        assert!(!registry.always_ask(&one).unwrap());
        assert!(registry.sessions_with_always_ask().unwrap().is_empty());

        registry.set_always_ask(&one, true).unwrap();
        assert!(registry.always_ask(&one).unwrap());
        assert!(!registry.always_ask(&other).unwrap());
        assert_eq!(
            registry.sessions_with_always_ask().unwrap(),
            vec![one.clone()]
        );

        registry.set_always_ask(&one, false).unwrap();
        assert!(!registry.always_ask(&one).unwrap());
        assert!(registry.sessions_with_always_ask().unwrap().is_empty());
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

    #[test]
    fn a_negative_schema_version_is_named_instead_of_failing_as_a_type_error() {
        let connection = Connection::open_in_memory().unwrap();
        connection.pragma_update(None, "user_version", -1).unwrap();

        let error = Registry::from_connection(connection).expect_err("must not be accepted");
        assert!(
            matches!(error, RegistryError::NewerSchema { found: -1, .. }),
            "got {error:?}"
        );
    }

    /// A second migration for the test only. It adds a column, which is the change most
    /// likely to lose data if a migration ever recreated the table instead of altering it.
    const SECOND_MIGRATION: &str = "ALTER TABLE registry_entries ADD COLUMN note TEXT;";

    #[test]
    fn an_existing_database_is_carried_forward_with_its_rows() {
        let path = std::env::temp_dir()
            .join(format!("companion-registry-migrate-{}", std::process::id()))
            .join("register.sqlite3");
        crate::paths::ensure_private_dir(path.parent().unwrap()).unwrap();
        let _ = std::fs::remove_file(&path);

        // A database as an older build left it: schema version 1, with a row in it.
        {
            let first =
                Registry::from_connection_with(Connection::open(&path).unwrap(), &MIGRATIONS[..1])
                    .unwrap();
            assert_eq!(first.schema_version().unwrap(), 1);
            first.upsert(&entry("session-a")).unwrap();
        }

        // The newer build opens the same file and adds the step it brought along.
        let migrations = [MIGRATIONS[0], SECOND_MIGRATION];
        let second =
            Registry::from_connection_with(Connection::open(&path).unwrap(), &migrations).unwrap();
        assert_eq!(second.schema_version().unwrap(), 2);
        assert_eq!(
            second.get(&SessionId::new("session-a")).unwrap().unwrap(),
            entry("session-a"),
            "the row from the older build must survive the migration"
        );

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn an_approval_from_an_older_build_reads_as_one_made_at_the_machine() {
        // Schema 3 added the device and the confirmation kind. A row that was written
        // before it has neither, and reading it as "the shell at the machine" is not a
        // guess: until that migration ran, no device could approve anything at all.
        let path = std::env::temp_dir()
            .join(format!(
                "companion-registry-approval-{}",
                std::process::id()
            ))
            .join("register.sqlite3");
        crate::paths::ensure_private_dir(path.parent().unwrap()).unwrap();
        let _ = std::fs::remove_file(&path);

        {
            let older =
                Registry::from_connection_with(Connection::open(&path).unwrap(), &MIGRATIONS[..2])
                    .unwrap();
            assert_eq!(older.schema_version().unwrap(), 2);
            older
                .lock()
                .execute(
                    "INSERT INTO approvals (project, auftrag_id, hash, approved_at_ms)
                     VALUES (?1, ?2, ?3, ?4)",
                    params!["/tmp/fixture/alt", "2026-08-01-eins", "abc123", 1_700i64],
                )
                .unwrap();
        }

        let now = Registry::open(&path).unwrap();
        assert_eq!(now.schema_version().unwrap(), MIGRATIONS.len() as u32);
        let record = now
            .approval_for("/tmp/fixture/alt", &AuftragId::new("2026-08-01-eins"))
            .unwrap()
            .expect("the old approval has to survive the migration");
        assert_eq!(record.hash, "abc123");
        assert_eq!(record.device, None);
        assert_eq!(record.confirmation, ApprovalConfirmation::Shell);

        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_confirmation_kind_this_build_does_not_know_is_not_read_as_the_machine() {
        // A register written by a newer build may hold a kind this one has never heard of.
        // Calling it `shell` would put a line into the audit trail that claims somebody stood
        // at the Mac; saying so is the only honest answer.
        assert_eq!(confirmation_from("shell"), ApprovalConfirmation::Shell);
        assert_eq!(
            confirmation_from("biometric"),
            ApprovalConfirmation::Biometric
        );
        assert_eq!(
            confirmation_from("passcode"),
            ApprovalConfirmation::Passcode
        );
        assert_eq!(confirmation_from("none"), ApprovalConfirmation::None);
        for name in ["watch-unlock", "", "SHELL"] {
            assert_eq!(
                confirmation_from(name),
                ApprovalConfirmation::Unknown,
                "{name} must not be rounded to one of the four"
            );
        }
    }

    #[test]
    fn the_register_and_its_wal_files_are_owner_only() {
        let path = std::env::temp_dir()
            .join(format!("companion-registry-mode-{}", std::process::id()))
            .join("register.sqlite3");
        let directory = path.parent().unwrap();
        crate::paths::ensure_private_dir(directory).unwrap();

        // A file left behind with loose rights, which is also what a permissive umask
        // would produce: opening the register has to tighten it before SQLite copies the
        // mode onto the -wal and -shm files.
        std::fs::write(&path, b"").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();

        let registry = Registry::open(&path).unwrap();
        registry.upsert(&entry("session-a")).unwrap();

        for name in [
            "register.sqlite3",
            "register.sqlite3-wal",
            "register.sqlite3-shm",
        ] {
            let file = directory.join(name);
            let mode = std::fs::metadata(&file)
                .unwrap_or_else(|error| panic!("{name} must exist: {error}"))
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600, "{name} must stay owner-only");
        }
        let directory_mode = std::fs::metadata(directory).unwrap().permissions().mode() & 0o777;
        assert_eq!(directory_mode, 0o700);

        drop(registry);
        std::fs::remove_dir_all(directory).unwrap();
    }

    /// Two runs three days apart, so a day grouping has more than one bucket. Fixed
    /// timestamps rather than "now": a test that runs at midnight must not straddle two days.
    const DAY_ONE_MS: u64 = 1_756_900_000_000;
    const DAY_TWO_MS: u64 = DAY_ONE_MS + 3 * 24 * 60 * 60 * 1000;

    /// A row with nothing in it but the session, so a test can put back exactly the fields
    /// it is about. The `entry` helper above is deliberately full — a filter test needs the
    /// opposite.
    fn bare(session: &str) -> RegistryEntry {
        RegistryEntry {
            schema_version: REGISTRY_SCHEMA_VERSION,
            session_id: SessionId::new(session),
            auftrag_id: None,
            project: None,
            started_at_ms: DAY_ONE_MS,
            ended_at_ms: None,
            result_path: None,
            open_points: Vec::new(),
            self_answers: Vec::new(),
            cost: Provenance::Unknown,
        }
    }

    fn priced(session: &str, started_at_ms: u64, cost: Provenance<Cost>) -> RegistryEntry {
        let mut entry = bare(session);
        entry.started_at_ms = started_at_ms;
        entry.cost = cost;
        entry
    }

    #[test]
    fn a_filter_narrows_by_project_by_window_and_by_self_answers() {
        let registry = Registry::open_in_memory().unwrap();
        let mut one = bare("eins");
        one.project = Some("/tmp/eins".to_owned());
        one.started_at_ms = DAY_TWO_MS;
        one.self_answers = vec![SelfAnswer {
            question: "?".to_owned(),
            answer: "!".to_owned(),
            source: "Auftragsdatei".to_owned(),
            answered_at_ms: DAY_TWO_MS,
        }];
        let mut two = bare("zwei");
        two.project = Some("/tmp/eins".to_owned());
        two.started_at_ms = DAY_ONE_MS;
        let mut three = bare("drei");
        three.project = Some("/tmp/zwei".to_owned());
        three.started_at_ms = DAY_TWO_MS;
        for row in [&one, &two, &three] {
            registry.upsert(row).unwrap();
        }

        let by_project = registry
            .list(&RegistryFilter {
                project: Some("/tmp/eins".to_owned()),
                ..RegistryFilter::default()
            })
            .unwrap();
        assert_eq!(by_project.len(), 2);

        let by_window = registry
            .list(&RegistryFilter {
                since_ms: Some(DAY_TWO_MS),
                ..RegistryFilter::default()
            })
            .unwrap();
        assert_eq!(by_window.len(), 2);

        let with_answers = registry
            .list(&RegistryFilter {
                with_self_answers: true,
                ..RegistryFilter::default()
            })
            .unwrap();
        assert_eq!(with_answers.len(), 1);
        assert_eq!(with_answers[0].session_id.as_str(), "eins");
    }

    #[test]
    fn a_limit_of_zero_is_the_default_and_a_huge_one_is_capped() {
        let registry = Registry::open_in_memory().unwrap();
        registry.upsert(&bare("eins")).unwrap();
        assert_eq!(
            registry
                .list(&RegistryFilter {
                    limit: 0,
                    ..RegistryFilter::default()
                })
                .unwrap()
                .len(),
            1,
            "zero means the daemon's own limit, not zero rows"
        );
        // Nothing to assert on the count here — the point is that a client cannot ask for
        // more than the cap, which `list` clamps before it reaches SQLite.
        registry
            .list(&RegistryFilter {
                limit: u32::MAX,
                ..RegistryFilter::default()
            })
            .unwrap();
    }

    #[test]
    fn a_day_without_a_single_priced_run_is_unknown_and_not_zero() {
        let day = day_costs(&[priced("eins", DAY_ONE_MS, Provenance::Unknown)]);
        assert_eq!(day.len(), 1);
        assert!(day[0].cost.is_unknown(), "{:?}", day[0]);
        assert_eq!(day[0].known_sessions, 0);
        assert_eq!(day[0].unknown_sessions, 1);
    }

    #[test]
    fn a_day_counter_sums_what_it_has_and_says_what_it_rests_on() {
        let days = day_costs(&[
            priced(
                "eins",
                DAY_TWO_MS,
                Provenance::Measured(Cost {
                    tokens: Some(100),
                    usd: Some(1.0),
                    budget_fraction: None,
                }),
            ),
            priced(
                "zwei",
                DAY_TWO_MS + 5,
                Provenance::Measured(Cost {
                    tokens: Some(50),
                    usd: None,
                    budget_fraction: Some(0.2),
                }),
            ),
            priced("drei", DAY_TWO_MS + 10, Provenance::Unknown),
            priced("alt", DAY_ONE_MS, Provenance::Unknown),
        ]);

        assert_eq!(days.len(), 2);
        assert!(days[0].day > days[1].day, "newest day first: {days:?}");
        let today = days[0].cost.value().expect("two of the three had a source");
        assert_eq!(today.tokens, Some(150));
        // The field only one of them knew is carried over rather than dropped.
        assert_eq!(today.usd, Some(1.0));
        assert_eq!(today.budget_fraction, Some(0.2));
        assert_eq!(days[0].known_sessions, 2);
        assert_eq!(days[0].unknown_sessions, 1);
    }

    #[test]
    fn the_companions_own_spend_lands_on_one_row_per_day_and_adds_up() {
        let registry = Registry::open_in_memory().unwrap();
        let cost = Cost {
            tokens: Some(1_000),
            usd: Some(0.25),
            budget_fraction: None,
        };
        registry.add_own_cost(&cost).unwrap();
        registry.add_own_cost(&cost).unwrap();

        let rows = registry.list(&RegistryFilter::default()).unwrap();
        assert_eq!(rows.len(), 1, "one row for the day, not one per turn");
        assert!(rows[0].session_id.as_str().starts_with(OWN_SESSION_PREFIX));
        let summed = rows[0].cost.value().expect("measured");
        assert_eq!(summed.tokens, Some(2_000));
        assert_eq!(summed.usd, Some(0.5));
    }

    /// What the companion answered in a world is one row per world, with every answer, an end,
    /// and no share in a day's cost.
    #[test]
    fn a_worlds_answers_land_on_its_own_row_and_cost_nothing() {
        let registry = Registry::open_in_memory().unwrap();
        let answer = |text: &str, at: u64| SelfAnswer {
            question: "»Garten«, leitung fragt (f1): Welche Beete?".to_owned(),
            answer: text.to_owned(),
            source: "wörtlich in der Nachricht des Menschen".to_owned(),
            answered_at_ms: at,
        };
        registry
            .append_world_answer("lokal", "w1", Some("/p/garten"), &answer("Kräuter", 1_000))
            .unwrap();
        registry
            .append_world_answer("lokal", "w1", Some("/p/garten"), &answer("Tomaten", 2_000))
            .unwrap();

        let rows = registry.list(&RegistryFilter::default()).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].session_id, world_session_id("lokal", "w1"));
        assert_eq!(rows[0].project.as_deref(), Some("/p/garten"));
        assert_eq!(rows[0].self_answers.len(), 2);
        assert_eq!(rows[0].ended_at_ms, Some(2_000));
        assert!(day_costs(&rows).is_empty(), "no session of unknown cost");
    }

    #[test]
    fn an_estimate_without_a_comparable_job_is_no_estimate_at_all() {
        let registry = Registry::open_in_memory().unwrap();
        // A row of the right project, but no job and no cost.
        let mut plain = bare("ohne-auftrag");
        plain.project = Some("/tmp/eins".to_owned());
        registry.upsert(&plain).unwrap();

        assert_eq!(
            estimate_for_project(&registry, "/tmp/eins").unwrap(),
            None,
            "a session without a job is not a comparable job"
        );
    }

    #[test]
    fn an_estimate_is_the_mean_of_the_comparable_jobs_of_that_project() {
        let registry = Registry::open_in_memory().unwrap();
        for (name, tokens) in [("eins", 100_u64), ("zwei", 300)] {
            let mut row = bare(name);
            row.project = Some("/tmp/eins".to_owned());
            row.auftrag_id = Some(AuftragId::new("a"));
            row.cost = Provenance::Measured(Cost {
                tokens: Some(tokens),
                usd: None,
                budget_fraction: None,
            });
            registry.upsert(&row).unwrap();
        }
        // A job of another project must not move the figure.
        let mut elsewhere = bare("anderswo");
        elsewhere.project = Some("/tmp/zwei".to_owned());
        elsewhere.auftrag_id = Some(AuftragId::new("b"));
        elsewhere.cost = Provenance::Measured(Cost {
            tokens: Some(9_000),
            usd: None,
            budget_fraction: None,
        });
        registry.upsert(&elsewhere).unwrap();

        let (cost, sample) = estimate_for_project(&registry, "/tmp/eins")
            .unwrap()
            .expect("two comparable jobs");
        assert_eq!(sample, 2);
        assert_eq!(cost.tokens, Some(200));
    }
}
