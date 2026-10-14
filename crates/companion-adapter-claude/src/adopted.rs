// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What this adapter remembers about the sessions it started, across a restart of the daemon.
//!
//! `DESIGN.md` § Daemon-Lebenslauf: "nach Absturz oder Update heftet er sich an laufende
//! Sessions wieder an … SDK-Sessions über gespeicherte Kennungen". Until 2026-09-03 the
//! adapter held its sessions only in memory and gave every child `kill_on_drop(true)`, so a
//! daemon restart did not lose those sessions — it killed them, mid-turn, with SIGKILL.
//!
//! The file here is those stored identifiers: one line of JSON per session with its id, the
//! project it runs in, the process that runs it and the transcript it writes. It lives next
//! to the daemon's other state under `config_dir` with the same owner-only permissions, and
//! it is rewritten whenever a session starts or ends — small, and never large enough for
//! that to matter.
//!
//! It is deliberately not a session store: nothing here is authoritative about what a session
//! is doing. It is an address book that survives a restart, and everything it claims is
//! checked against the machine before it is believed.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use companion_protocol::SessionId;
use serde::{Deserialize, Serialize};

/// One session this adapter started, in the form that survives a restart.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredSession {
    pub id: String,
    /// Absolute path of the project the run works in.
    pub project: PathBuf,
    /// The `claude` process. Checked against the machine before it is believed: a pid is a
    /// name, not a measurement, and the number is reused.
    pub pid: u32,
    /// When that process started, as this machine states it.
    ///
    /// The pid alone is not an identity. After a reboot, or once the number has come round
    /// again, some other program wears it — and this adapter would then list a stranger as a
    /// session and send it a SIGTERM on `stop`. The pair (number, start time) is what a
    /// process is; a record without the second half is not trusted with either.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    /// The transcript, where the adapter had already found it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript: Option<PathBuf>,
}

impl StoredSession {
    pub fn session_id(&self) -> SessionId {
        SessionId::new(self.id.clone())
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct StoredFile {
    #[serde(default)]
    sessions: Vec<StoredSession>,
}

/// Reads what a previous run left behind. A file that is not there, or not readable, or not
/// JSON, is an empty list: a broken address book is a reason to adopt nothing, never a reason
/// to refuse to start.
pub fn load(path: &Path) -> Vec<StoredSession> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    match serde_json::from_str::<StoredFile>(&text) {
        Ok(file) => file.sessions,
        Err(error) => {
            tracing::warn!(
                path = %path.display(),
                %error,
                "the remembered claude sessions could not be read, so this run adopts none"
            );
            Vec::new()
        }
    }
}

/// Writes the list, owner-only, creating the directory if it is missing.
pub fn save(path: &Path, sessions: &[StoredSession]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        companion_core::paths::ensure_private_dir(parent)?;
    }
    let text = serde_json::to_vec_pretty(&StoredFile {
        sessions: sessions.to_vec(),
    })?;
    companion_core::paths::write_private_file(path, &text)
}

/// How long the process listing may take. It is a local `ps` on one process id; anything
/// slower than this is a machine in trouble, and a check that hangs would be worse than one
/// that answers "cannot tell" — which is the safe answer here anyway.
const START_TIME_TIMEOUT: Duration = Duration::from_secs(2);

/// Whether a process is still there. `kill(pid, 0)` asks without sending anything.
///
/// A pid that is gone is the normal answer after a restart: the run reads the daemon's pipe
/// on standard input, and when the daemon ends, that pipe closes. Measured against the real
/// CLI on 2026-09-03: `claude -p --input-format stream-json` with its input closed and
/// nothing written to it exits by itself, status 0, without asking the model anything.
///
/// On its own this says nothing about *which* process is there. Use [`is_same_process`]
/// wherever the answer decides what is reported or what gets a signal.
#[cfg(unix)]
pub fn alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok()
}

#[cfg(not(unix))]
pub fn alive(_pid: u32) -> bool {
    false
}

/// When a process started, as `ps` states it — an opaque string, compared only against
/// itself.
///
/// `ps -o lstart=` prints an absolute wall-clock time, so it stays the same for the life of
/// the process, which is what makes it usable as the second half of an identity. The elapsed
/// time (`etime`) would not: it changes with every reading.
///
/// Why a child process and not a system call: this workspace forbids `unsafe`, and the start
/// time is reachable from Rust only through `libc::proc_pidinfo` (macOS) or `/proc` (Linux).
/// `nix` 0.28, which this crate already uses, wraps syscalls and offers no process listing —
/// checked before writing this. `/proc` alone would not cover macOS, which is the machine
/// this runs on. One short `ps` per adopted session at startup and one before a signal is a
/// price worth the certainty; both are bounded by [`START_TIME_TIMEOUT`].
///
/// `None` means "cannot tell", never "no start time". Every caller treats that as *not* the
/// same process, which is the safe direction: a session goes unreported rather than a
/// stranger reported, and nothing is signalled.
pub fn started_at(pid: u32) -> Option<String> {
    let mut child = Command::new("ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let deadline = Instant::now() + START_TIME_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(POLL),
            // A `ps` that will not answer is a `ps` nobody waits for any longer.
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Err(_) => return None,
        }
    }

    let output = child.wait_with_output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!text.is_empty()).then_some(text)
}

/// How often the wait for `ps` looks up. Short enough to be invisible, long enough not to
/// spin.
const POLL: Duration = Duration::from_millis(5);

/// Whether the process behind this record is still the one the record was written for.
///
/// Both halves have to agree, and an unknown half counts as disagreement:
///
/// * The record carries no start time — written by a build that did not record one. It is
///   not trusted, because a pid on its own is exactly the thing this guards against.
/// * The machine will not say when the process started. Then nothing here knows what is
///   under that number.
pub fn is_same_process(pid: u32, recorded: Option<&str>) -> bool {
    let Some(recorded) = recorded else {
        return false;
    };
    if !alive(pid) {
        return false;
    }
    started_at(pid).is_some_and(|current| current == recorded)
}

/// Asks a process to end. `stop` on an adopted session has no `Child` to kill, only the
/// number the previous run wrote down.
///
/// The identity is checked again here and not taken from the adoption: a session can sit in
/// the map for hours before somebody stops it, and in that time the process it names may have
/// ended and its number been handed to something else. A signal is the one operation that
/// cannot be taken back, so it is the one that re-asks.
#[cfg(unix)]
pub fn terminate(pid: u32, recorded: Option<&str>) -> std::io::Result<()> {
    if !is_same_process(pid, recorded) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "the process this session named is no longer the one under that number",
        ));
    }
    let pid = i32::try_from(pid)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "no such process id"))?;
    nix::sys::signal::kill(
        nix::unistd::Pid::from_raw(pid),
        nix::sys::signal::Signal::SIGTERM,
    )
    .map_err(std::io::Error::from)
}

#[cfg(not(unix))]
pub fn terminate(_pid: u32, _recorded: Option<&str>) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "this system has no way to signal a process by id",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-adopted-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn what_was_written_is_what_is_read_back() {
        let dir = temp_dir("roundtrip");
        let path = dir.join("claude-sessions.json");
        let sessions = vec![StoredSession {
            id: "s-1".to_owned(),
            project: PathBuf::from("/tmp/projekt"),
            pid: 4242,
            started_at: Some("Wed Sep  3 04:12:33 2026".to_owned()),
            transcript: Some(PathBuf::from("/tmp/projects/-tmp-projekt/s-1.jsonl")),
        }];
        save(&path, &sessions).unwrap();
        assert_eq!(load(&path), sessions);

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the address book stays owner-only");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_is_not_there_or_not_json_adopts_nothing() {
        let dir = temp_dir("broken");
        assert!(load(&dir.join("nothing.json")).is_empty());
        let path = dir.join("kaputt.json");
        std::fs::write(&path, "{ this is not json").unwrap();
        assert!(load(&path).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn this_process_is_alive_and_a_process_id_that_cannot_exist_is_not() {
        assert!(alive(std::process::id()));
        assert!(!alive(0x7fff_ffff), "no such process on this machine");
    }

    #[test]
    fn a_process_is_the_number_and_the_moment_together() {
        let me = std::process::id();
        let mine = started_at(me).expect("this machine can say when this process started");
        assert!(!mine.is_empty());
        assert_eq!(
            started_at(me).as_deref(),
            Some(mine.as_str()),
            "the start time has to stay the same between two readings, or it is no identity"
        );

        assert!(is_same_process(me, Some(&mine)));
        assert!(
            !is_same_process(me, Some("Mon Jan  1 00:00:00 1990")),
            "a live process under the right number is still the wrong process when it \
             started at another time"
        );
        assert!(
            !is_same_process(me, None),
            "a record without a start time is a bare number, and a bare number is what this \
             guards against"
        );
        assert!(!is_same_process(0x7fff_ffff, Some(&mine)));
        assert_eq!(started_at(0x7fff_ffff), None);
    }

    #[test]
    fn a_process_that_is_not_the_recorded_one_is_never_signalled() {
        // The process here is this test itself: alive, under exactly the number in the
        // record, and not the process the record was written for. A SIGTERM would end the
        // test run — the assertion is that it is refused, and the run surviving is the
        // second half of the proof.
        let me = std::process::id();
        let error = terminate(me, Some("Mon Jan  1 00:00:00 1990"))
            .expect_err("a stranger under a known number must not be signalled");
        assert_eq!(error.kind(), std::io::ErrorKind::NotFound);

        let error = terminate(me, None).expect_err("a bare number is not an identity");
        assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
    }
}
