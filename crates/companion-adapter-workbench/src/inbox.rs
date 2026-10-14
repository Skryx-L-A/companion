// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Handing text to a running Claude Code session through its own message socket.
//!
//! This is the channel the workbench itself uses instead of typing into a pane, and the
//! reason it exists is written into `~/.local/bin/wb-inbox`: a job sent as a keystroke
//! sequence can overwrite what is already in the prompt line, can be swallowed silently,
//! and gives the sender no error when it goes wrong. The socket does none of that. It also
//! keeps this adapter inside what `DESIGN.md` § Session-Adapter allows, which is a
//! structured channel and never the terminal image.
//!
//! What the channel looks like, measured against the registry on this machine:
//!
//! * Every live session writes `~/.claude/sessions/<pid>.json` with its `pid`, the
//!   `messagingSocketPath` it listens on, the tmux address it runs in, its name and a
//!   `status` of `busy` or `idle`.
//! * Next to it lies `<pid>.<hash>.key` with a `peerToken`. A sender that does not present
//!   it arrives as an unknown sender and the session holds the message back.
//! * Two lines go over the socket, each terminated by a newline: `{"type":"auth", …}` and
//!   then `{"type":"user","message":{"role":"user","content": …}}`.
//!
//! Three checks stand between "a file names a socket" and "this is the session I meant",
//! and all three are here because the workbench learned them the hard way:
//!
//! 1. The registry lists every live session of the machine, whatever tmux server it runs
//!    on. A pane id like `%0` exists on every server, so a pane id alone is not an address.
//!    The pane's own process id is.
//! 2. The socket file carries a pid in its name, and a name is not a measurement — a newer
//!    process can inherit an old address. `LOCAL_PEERPID` says who is really at the other
//!    end, so nothing is written before that matches.
//! 3. A session is only the right one if its process really hangs below that pane. The
//!    ancestry walk is what stopped a test run from delivering into two live sessions of
//!    the user.
//!
//! Delivery is written, never proven: the socket does not answer, and "written" is not
//! "read". The honest report is what this module returns — which process was written to,
//! and whether the write succeeded.

use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use serde::Deserialize;
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::process::Command;

/// How deep the ancestry walk goes before it gives up. The same limit `wb-inbox` uses.
const ANCESTRY_DEPTH: usize = 40;

/// How long the one `ps` call may take. It is a local process listing; anything slower than
/// this is a machine in trouble, and a `send` that hangs on it would be worse than one that
/// reports it could not find the session.
const PROCESS_TABLE_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Error)]
pub enum InboxError {
    #[error("no live Claude session under pane {pane} (registry {registry})")]
    NoSession { pane: String, registry: String },
    #[error(
        "session {pid} has no readable key file; without it the message would arrive as an unknown sender and be held back"
    )]
    NoToken { pid: i32 },
    #[error("socket {socket} cannot be reached ({source}); the session is probably restarted")]
    Unreachable {
        socket: String,
        #[source]
        source: std::io::Error,
    },
    #[error("process {found} is at socket {socket}, expected {expected}; nothing was sent")]
    WrongPeer {
        socket: String,
        expected: i32,
        found: i32,
    },
    #[error("writing to {socket} failed: {source}")]
    Write {
        socket: String,
        #[source]
        source: std::io::Error,
    },
    #[error("nothing to send: the text is empty")]
    Empty,
    #[error(
        "{count} live Claude sessions hang below pane {pane} ({pids}); none of them is chosen, because picking one would be a guess"
    )]
    Ambiguous {
        pane: String,
        count: usize,
        pids: String,
    },
}

/// One entry of the Claude Code session registry.
#[derive(Debug, Clone, Deserialize)]
pub struct RegistryEntry {
    pub pid: i32,
    #[serde(rename = "messagingSocketPath")]
    pub socket: Option<String>,
    /// The directory the session runs in, as it found itself at start. Together with
    /// [`Self::session_id`] this is the address of its transcript.
    pub cwd: Option<String>,
    /// The conversation this session writes, as Claude Code names the file.
    #[serde(rename = "sessionId")]
    pub session_id: Option<String>,
    /// `<tmux-session>:<window>.<pane>`, as the session found itself at start.
    pub tmux: Option<String>,
    pub name: Option<String>,
    /// `busy` or `idle` at the time the session last wrote the file.
    pub status: Option<String>,
}

impl RegistryEntry {
    /// Whether this entry says it is in the middle of a turn.
    ///
    /// The field is a snapshot the session writes, so it can be a moment behind. It is
    /// still the only measurement there is, and the alternative — claiming every send
    /// arrives in an idle session — would be a guess dressed as a fact.
    pub fn is_busy(&self) -> bool {
        self.status.as_deref() == Some("busy")
    }
}

/// Every registry entry whose process is alive and whose socket exists.
///
/// A file for a process that is gone is normal: the registry keeps the entry until
/// somebody cleans it up. Skipping it here means a dead session never shadows a live one.
pub fn read_registry(dir: &Path) -> Vec<RegistryEntry> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut sessions = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let Some(entry) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<RegistryEntry>(&text).ok())
        else {
            continue;
        };
        if !alive(entry.pid) {
            continue;
        }
        if entry
            .socket
            .as_deref()
            .is_none_or(|socket| !Path::new(socket).exists())
        {
            continue;
        }
        sessions.push(entry);
    }
    sessions.sort_by_key(|entry| entry.pid);
    sessions
}

/// What looking a pane up in the registry produced.
#[derive(Debug, Clone)]
pub enum PaneSession {
    /// Exactly one session belongs to this pane.
    One(Box<RegistryEntry>),
    /// Nothing in the registry hangs below this pane.
    None,
    /// Several do, and nothing measured tells them apart.
    Several(Vec<i32>),
}

/// The session that belongs to a pane.
///
/// The ancestry check is the gate, and it stays the gate: the process has to hang below the
/// pane's process, which is the only part of a pane address that means anything across tmux
/// servers. The tmux address in the registry file — the session's own word about which pane
/// it sits in — is a tie-breaker afterwards and never a shortcut past that check. A pane id
/// like `%0` exists on every tmux server, so an entry that names one and does not descend
/// from it says nothing at all.
///
/// Where the ancestry check leaves several and their own words do not separate them — a
/// Claude session started inside another one, both below the same process — this returns
/// [`PaneSession::Several`] rather than a winner. It used to return the entry with the lower
/// process id, which is usually the outer session and is never a measurement. `pane_for`
/// refuses an ambiguous pane for the same reason: picking one would be a guess, and the thing
/// being picked here is who receives a message.
pub async fn session_for_pane(
    entries: &[RegistryEntry],
    pane_id: &str,
    pane_pid: i32,
) -> PaneSession {
    // One process listing for the whole question. Until 2026-09-03 every hop of every
    // entry's ancestry was its own `ps` call — up to forty per entry, with no timeout, on
    // every send and every transcript read.
    let table = process_table().await;
    let mut below = Vec::new();
    for entry in entries {
        if descends_from(entry.pid, pane_pid, &table) {
            below.push(entry);
        }
    }
    if let [only] = below.as_slice() {
        return PaneSession::One(Box::new((*only).clone()));
    }
    if below.is_empty() {
        return PaneSession::None;
    }

    // Several hang below this pane. One of them may say outright that it is the one in it.
    let suffix = format!(".{pane_id}");
    let named: Vec<&&RegistryEntry> = below
        .iter()
        .filter(|entry| {
            entry
                .tmux
                .as_deref()
                .is_some_and(|at| at.ends_with(&suffix))
        })
        .collect();
    match named.as_slice() {
        [only] => PaneSession::One(Box::new((**only).clone())),
        _ => PaneSession::Several(below.iter().map(|entry| entry.pid).collect()),
    }
}

/// The token a foreign sender authenticates with, out of `<pid>.<hash>.key`.
pub fn peer_token(dir: &Path, pid: i32) -> Option<String> {
    #[derive(Deserialize)]
    struct KeyFile {
        #[serde(rename = "peerToken")]
        peer_token: Option<String>,
    }

    let prefix = format!("{pid}.");
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("key") {
            continue;
        }
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !name.starts_with(&prefix) {
            continue;
        }
        let token = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<KeyFile>(&text).ok())
            .and_then(|file| file.peer_token)
            .filter(|token| !token.is_empty());
        if token.is_some() {
            return token;
        }
    }
    None
}

/// Whether the process at the other end could be looked at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerCheck {
    /// The platform named the process and it was the expected one.
    Matched,
    /// The platform has no way to name it. macOS and Linux both do, so this is what a third
    /// system would report — the message went out, and the one guarantee that the socket
    /// belongs to the session in the registry did not hold for it.
    Unavailable,
}

/// Writes one message into a session's inbox.
///
/// Returns once the two lines are out. Nothing here waits for a reply, because there is
/// none to wait for. The return value carries whether the process at the other end could be
/// checked, because a caller that reports a delivery should be able to say what stood behind
/// it; the comment here used to promise that without anything carrying it.
pub async fn deliver(
    entry: &RegistryEntry,
    token: &str,
    text: &str,
    timeout: std::time::Duration,
) -> Result<PeerCheck, InboxError> {
    if text.trim().is_empty() {
        return Err(InboxError::Empty);
    }
    let socket = entry.socket.clone().unwrap_or_default();

    let stream = match tokio::time::timeout(timeout, UnixStream::connect(&socket)).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(source)) => return Err(InboxError::Unreachable { socket, source }),
        Err(_) => {
            return Err(InboxError::Unreachable {
                socket,
                source: std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "connect did not finish in time",
                ),
            });
        }
    };

    // Who is really at the other end. Where the platform cannot say — every system that is
    // neither macOS nor Linux — the write still happens, and the answer says that the check
    // was not available rather than that it passed.
    let checked = match peer_pid(&stream) {
        Some(found) if found != entry.pid => {
            return Err(InboxError::WrongPeer {
                socket,
                expected: entry.pid,
                found,
            });
        }
        Some(_) => PeerCheck::Matched,
        None => PeerCheck::Unavailable,
    };

    let lines = format!(
        "{}\n{}\n",
        serde_json::json!({ "type": "auth", "token": token }),
        serde_json::json!({
            "type": "user",
            "message": { "role": "user", "content": text }
        })
    );

    let mut stream = stream;
    let write = async {
        stream.write_all(lines.as_bytes()).await?;
        stream.flush().await
    };
    match tokio::time::timeout(timeout, write).await {
        Ok(Ok(())) => Ok(checked),
        Ok(Err(source)) => Err(InboxError::Write { socket, source }),
        Err(_) => Err(InboxError::Write {
            socket,
            source: std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "the write did not finish in time",
            ),
        }),
    }
}

/// The process at the other end of a connected unix socket, where the platform says.
#[cfg(target_vendor = "apple")]
fn peer_pid(stream: &UnixStream) -> Option<i32> {
    use std::os::fd::AsFd;
    nix::sys::socket::getsockopt(&stream.as_fd(), nix::sys::socket::sockopt::LocalPeerPid).ok()
}

#[cfg(target_os = "linux")]
fn peer_pid(stream: &UnixStream) -> Option<i32> {
    use std::os::fd::AsFd;
    nix::sys::socket::getsockopt(&stream.as_fd(), nix::sys::socket::sockopt::PeerCredentials)
        .ok()
        .map(|credentials| credentials.pid())
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
fn peer_pid(_stream: &UnixStream) -> Option<i32> {
    None
}

/// Whether a process is still there. `kill(pid, 0)` asks without sending anything.
fn alive(pid: i32) -> bool {
    #[cfg(unix)]
    {
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok()
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

/// Whether `root` stands somewhere in the ancestry of `pid`. `root` itself counts.
///
/// The table is the whole machine's parent map, read once by the caller. A process that is
/// not in it — it ended between the listing and this walk — ends the walk, which is the same
/// answer the per-process form gave when `ps` found nothing.
fn descends_from(pid: i32, root: i32, table: &HashMap<i32, i32>) -> bool {
    let mut current = pid;
    for _ in 0..ANCESTRY_DEPTH {
        if current == root {
            return true;
        }
        if current <= 1 {
            return false;
        }
        match table.get(&current) {
            Some(parent) => current = *parent,
            None => return false,
        }
    }
    false
}

/// The parent of every process on the machine, from one `ps` call.
///
/// An empty map is what a failed or slow `ps` yields, and then nothing descends from
/// anything: no session is found and the caller says so, rather than writing into a session
/// whose ancestry was never checked.
async fn process_table() -> HashMap<i32, i32> {
    let call = Command::new("ps")
        .args(["-eo", "pid=,ppid="])
        .stdin(std::process::Stdio::null())
        .output();
    let Ok(Ok(output)) = tokio::time::timeout(PROCESS_TABLE_TIMEOUT, call).await else {
        return HashMap::new();
    };
    if !output.status.success() {
        return HashMap::new();
    }
    parse_process_table(&String::from_utf8_lossy(&output.stdout))
}

/// `pid ppid` per line, as `ps -eo pid=,ppid=` writes it. A line that does not carry two
/// numbers is skipped rather than fatal.
fn parse_process_table(text: &str) -> HashMap<i32, i32> {
    let mut table = HashMap::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let (Some(pid), Some(parent)) = (parts.next(), parts.next()) else {
            continue;
        };
        let (Ok(pid), Ok(parent)) = (pid.parse::<i32>(), parent.parse::<i32>()) else {
            continue;
        };
        table.insert(pid, parent);
    }
    table
}

/// The registry directory as a string, for error messages that name where nothing was
/// found instead of only saying that nothing was.
pub fn describe(dir: &Path) -> String {
    dir.display().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_process_table_is_read_once_and_walked_in_memory() {
        // `ps -eo pid=,ppid=` pads its columns; a header or a torn line is skipped.
        let table = parse_process_table("  501     1\n  700   501\n  900   700\nkaputt\n");
        assert!(descends_from(900, 501, &table), "grandchild descends");
        assert!(
            descends_from(501, 501, &table),
            "a process is its own ancestor"
        );
        assert!(
            !descends_from(700, 900, &table),
            "and not the other way round"
        );
        assert!(
            !descends_from(4242, 501, &table),
            "a process the listing does not carry ends the walk"
        );
        assert!(
            !descends_from(900, 501, &HashMap::new()),
            "without a listing nothing descends, so no session is picked"
        );
    }

    /// The peer check is what stands between "a file names this socket" and "this process is
    /// the one the file named". The value it returns is threaded out to the caller now, so it
    /// is worth one test that it really is measured here and not filled in.
    #[tokio::test]
    async fn a_delivery_reports_that_the_peer_was_checked() {
        let socket = std::path::PathBuf::from(format!(
            "/tmp/companion-inbox-unit-{}.sock",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&socket);

        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let accepted = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut text = String::new();
            use tokio::io::AsyncReadExt;
            tokio::io::BufReader::new(stream)
                .read_to_string(&mut text)
                .await
                .unwrap();
            text
        });

        let entry = RegistryEntry {
            pid: std::process::id() as i32,
            socket: Some(socket.display().to_string()),
            cwd: None,
            session_id: None,
            tmux: None,
            name: Some("unit".to_owned()),
            status: Some("idle".to_owned()),
        };
        let checked = deliver(&entry, "tok", "hallo", std::time::Duration::from_secs(5))
            .await
            .expect("the socket is right here");

        // Both systems this program runs on can name the process at a unix socket. On one
        // that cannot, this is where `Unavailable` would show up, and the caller logs it.
        assert_eq!(
            checked,
            PeerCheck::Matched,
            "macOS and Linux both answer this question"
        );
        assert_eq!(accepted.await.unwrap().lines().count(), 2);
        let _ = std::fs::remove_file(&socket);
    }

    #[tokio::test]
    async fn an_empty_message_is_refused_before_anything_is_opened() {
        let entry = RegistryEntry {
            pid: 1,
            socket: Some("/nowhere/at/all.sock".to_owned()),
            cwd: None,
            session_id: None,
            tmux: None,
            name: None,
            status: None,
        };
        assert!(matches!(
            deliver(&entry, "tok", "   ", std::time::Duration::from_secs(1))
                .await
                .expect_err("nothing to send"),
            InboxError::Empty
        ));
    }
}
