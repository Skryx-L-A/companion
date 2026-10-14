// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Calling `wb-state` and `tmux`.
//!
//! Both are asked, never trusted: a missing binary, a non-zero exit or an unexpected line
//! is a gap in what the adapter knows, not a crash. The caller falls back to the state
//! files, which is why every function here returns a plain error instead of panicking.

use std::path::Path;
use std::time::Duration;

use thiserror::Error;
use tokio::process::Command;

use crate::config::WorkbenchConfig;

#[derive(Debug, Error)]
pub enum CommandError {
    #[error("{binary} is not installed")]
    NotFound { binary: String },
    #[error("{binary} exited with {code}: {stderr}")]
    Failed {
        binary: String,
        code: String,
        stderr: String,
    },
    #[error("{binary} did not answer within {ms} ms")]
    Timeout { binary: String, ms: u64 },
    #[error("cannot run {binary}: {source}")]
    Io {
        binary: String,
        #[source]
        source: std::io::Error,
    },
}

/// Runs a binary and returns its standard output.
pub async fn run(binary: &Path, args: &[&str], timeout: Duration) -> Result<String, CommandError> {
    let name = binary.display().to_string();
    let future = Command::new(binary)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output();

    let output = match tokio::time::timeout(timeout, future).await {
        Err(_) => {
            return Err(CommandError::Timeout {
                binary: name,
                ms: timeout.as_millis() as u64,
            });
        }
        Ok(Err(source)) if source.kind() == std::io::ErrorKind::NotFound => {
            return Err(CommandError::NotFound { binary: name });
        }
        Ok(Err(source)) => {
            return Err(CommandError::Io {
                binary: name,
                source,
            });
        }
        Ok(Ok(output)) => output,
    };

    if !output.status.success() {
        return Err(CommandError::Failed {
            binary: name,
            code: output
                .status
                .code()
                .map_or_else(|| "signal".to_owned(), |code| code.to_string()),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// One pane as tmux reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pane {
    pub tmux_session: String,
    /// Contents of the `@wb_worker` pane option: the worker that owns this pane, if any.
    /// The workbench sets it on the orchestrator pane too, so it does not say what kind of
    /// pane this is — [`Pane::role`] does.
    pub worker: Option<String>,
    /// Contents of `@wb_role`: `orchestrator`, `worker` or `sidebar`. This is the field
    /// `wb-close` keys on, and the reason it can promise never to close an orchestrator.
    pub role: Option<String>,
    /// The pane id, `%17`. Unique on its tmux server and nowhere else.
    pub pane_id: String,
    /// The process the pane runs. This is the part of a pane address that means something
    /// across tmux servers, and what the session registry is matched against.
    pub pane_pid: Option<i32>,
}

/// Every pane on the tmux server, with the workbench's own pane metadata.
///
/// `capture-pane` is deliberately not used anywhere in this adapter: `DESIGN.md`
/// § Session-Adapter forbids the terminal image as a basis for decisions.
pub async fn list_panes(config: &WorkbenchConfig) -> Result<Vec<Pane>, CommandError> {
    let mut args: Vec<&str> = Vec::new();
    let socket = config
        .tmux_socket
        .as_ref()
        .map(|path| path.display().to_string());
    if let Some(socket) = socket.as_deref() {
        args.push("-S");
        args.push(socket);
    }
    args.extend_from_slice(&["list-panes", "-a", "-F", PANE_FORMAT]);

    let stdout = run(&config.tmux_bin, &args, config.command_timeout).await?;
    Ok(stdout.lines().filter_map(parse_pane).collect())
}

/// The separator between the pane fields, and why it is this one.
///
/// A vertical bar was the obvious choice and the wrong one. tmux forbids `.` and `:` in a
/// session name and nothing else, `list-panes -a` returns every session of the server
/// including the ones a person named themselves, and a session called `a|b` shifted every
/// field of its line by one: the role ended up holding the pane id and the process id came
/// out empty. The pane was then not the wrong one but an unaddressable one.
///
/// `\u{1f}`, the unit separator, is the character this job has an ASCII code for. tmux
/// passes it through a format string unchanged (measured against the running server), and
/// nobody types it into a session name.
const SEPARATOR: char = '\u{1f}';

const PANE_FORMAT: &str =
    "#{session_name}\u{1f}#{@wb_worker}\u{1f}#{@wb_role}\u{1f}#{pane_id}\u{1f}#{pane_pid}";

/// One line of the pane listing.
///
/// Split from the back, not from the front. The four trailing fields cannot carry the
/// separator — a role, a pane id and a process id are tmux's own words — so taking them off
/// the end leaves whatever remains as the session name, separator and all. Together with the
/// choice of separator that makes a name this parser cannot read a name nobody can produce.
fn parse_pane(line: &str) -> Option<Pane> {
    let mut parts = line.rsplitn(5, SEPARATOR);
    let pane_pid = parts.next().unwrap_or("").trim();
    let pane_id = parts.next().unwrap_or("").trim();
    let role = parts.next().unwrap_or("").trim();
    let worker = parts.next().unwrap_or("").trim();
    let session = parts.next()?.trim();
    if session.is_empty() {
        return None;
    }
    Some(Pane {
        tmux_session: session.to_owned(),
        worker: (!worker.is_empty()).then(|| worker.to_owned()),
        role: (!role.is_empty()).then(|| role.to_owned()),
        pane_id: pane_id.to_owned(),
        pane_pid: pane_pid.parse().ok(),
    })
}

/// Closes a worker pane through `wb-close`, which is the workbench's own gate for it.
///
/// Deliberately not `tmux kill-pane`: `wb-close` refuses an orchestrator pane and refuses
/// the caller's own pane, and those two refusals are the whole reason a companion may stop
/// a session at all. Doing it by hand here would mean re-implementing a guarantee that
/// already exists — and re-implementing it worse.
pub async fn close_worker(config: &WorkbenchConfig, worker: &str) -> Result<String, CommandError> {
    run(&config.wb_close_bin, &[worker], config.command_timeout).await
}

/// What a start reported: the tmux session it stands in, and whatever else was said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Started {
    pub tmux_session: Option<String>,
    pub output: String,
}

/// The marker `wb-code` prints when the session stands.
///
/// It exists because the last thing `wb-code` does is `exec tmux attach`, which cannot
/// work without a terminal — and a daemon has none. Without the marker a successful start
/// and a failed one would hand back the same exit code, which is exactly the confusion the
/// workbench wrote this line to end.
const SESSION_MARKER: &str = "wb-code: SITZUNG-STEHT ";

/// Opens a workbench session for a project directory.
///
/// Both channels are read and the exit code is not the verdict: success is the marker.
pub async fn start_session(
    config: &WorkbenchConfig,
    project: &str,
    name: Option<&str>,
    model: Option<&str>,
) -> Result<Started, CommandError> {
    let mut args: Vec<&str> = vec![project];
    if let Some(name) = name {
        args.push("--name");
        args.push(name);
    }
    if let Some(model) = model {
        args.push("--model");
        args.push(model);
    }

    let output = run_both(&config.wb_code_bin, &args, config.spawn_timeout).await?;
    let session = output
        .lines()
        .rev()
        .find_map(|line| line.split_once(SESSION_MARKER))
        .map(|(_, session)| session.trim().to_owned())
        .filter(|session| !session.is_empty());

    match session {
        Some(session) => Ok(Started {
            tmux_session: Some(session),
            output,
        }),
        None => Err(CommandError::Failed {
            binary: config.wb_code_bin.display().to_string(),
            code: "no session".to_owned(),
            stderr: output.trim().to_owned(),
        }),
    }
}

/// Starts a worker inside an existing workbench session.
///
/// `WB_SESSION` is how a caller without a tmux pane of its own names the session the
/// worker belongs in; without it `claude-worker` would look for the caller's own pane and
/// find none. The daemon has no pane, so this is the only correct form here.
pub async fn start_worker(
    config: &WorkbenchConfig,
    tmux_session: &str,
    worker: &str,
    model: &str,
    dir: &str,
    task: &str,
) -> Result<String, CommandError> {
    let binary = &config.claude_worker_bin;
    let name = binary.display().to_string();
    let future = Command::new(binary)
        .args([worker, model, dir, task])
        .env("WB_SESSION", tmux_session)
        .stdin(std::process::Stdio::null())
        .output();

    let output = match tokio::time::timeout(config.spawn_timeout, future).await {
        Err(_) => {
            return Err(CommandError::Timeout {
                binary: name,
                ms: config.spawn_timeout.as_millis() as u64,
            });
        }
        Ok(Err(source)) if source.kind() == std::io::ErrorKind::NotFound => {
            return Err(CommandError::NotFound { binary: name });
        }
        Ok(Err(source)) => {
            return Err(CommandError::Io {
                binary: name,
                source,
            });
        }
        Ok(Ok(output)) => output,
    };

    if !output.status.success() {
        return Err(CommandError::Failed {
            binary: name,
            code: output
                .status
                .code()
                .map_or_else(|| "signal".to_owned(), |code| code.to_string()),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Runs a binary and returns both channels, whatever the exit code was.
///
/// For the one caller that cannot judge by the exit code: see [`SESSION_MARKER`].
async fn run_both(binary: &Path, args: &[&str], timeout: Duration) -> Result<String, CommandError> {
    let name = binary.display().to_string();
    let future = Command::new(binary)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output();

    let output = match tokio::time::timeout(timeout, future).await {
        Err(_) => {
            return Err(CommandError::Timeout {
                binary: name,
                ms: timeout.as_millis() as u64,
            });
        }
        Ok(Err(source)) if source.kind() == std::io::ErrorKind::NotFound => {
            return Err(CommandError::NotFound { binary: name });
        }
        Ok(Err(source)) => {
            return Err(CommandError::Io {
                binary: name,
                source,
            });
        }
        Ok(Ok(output)) => output,
    };

    Ok(format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    ))
}

/// `wb-state list <dir>`: one line per session of that directory,
/// `<sessionKey>|<name>|<tmuxSession>`. The key is empty for the main session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListedSession {
    pub session_key: Option<String>,
    pub name: String,
    pub tmux_session: Option<String>,
}

pub async fn list_sessions(
    config: &WorkbenchConfig,
    dir: &str,
) -> Result<Vec<ListedSession>, CommandError> {
    let stdout = run(&config.wb_state_bin, &["list", dir], config.command_timeout).await?;
    Ok(stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let mut parts = line.split('|');
            let key = parts.next().unwrap_or("").trim();
            let name = parts.next().unwrap_or("").trim();
            let tmux = parts.next().unwrap_or("").trim();
            ListedSession {
                session_key: (!key.is_empty()).then(|| key.to_owned()),
                name: name.to_owned(),
                tmux_session: (!tmux.is_empty()).then(|| tmux.to_owned()),
            }
        })
        .collect())
}

/// `wb-state session <dir> [--key <k>]`: the tmux session of one workbench session.
pub async fn session_tmux(
    config: &WorkbenchConfig,
    dir: &str,
    key: Option<&str>,
) -> Result<Option<String>, CommandError> {
    let mut args = vec!["session", dir];
    if let Some(key) = key {
        args.push("--key");
        args.push(key);
    }
    let stdout = run(&config.wb_state_bin, &args, config.command_timeout).await?;
    Ok(non_empty(&stdout))
}

/// `wb-state by-tmux <tmux-session>`: `<dir>|<sessionKey>` for a pane we found but do not
/// know from the state files yet.
pub async fn by_tmux(
    config: &WorkbenchConfig,
    tmux_session: &str,
) -> Result<Option<(String, Option<String>)>, CommandError> {
    let stdout = run(
        &config.wb_state_bin,
        &["by-tmux", tmux_session],
        config.command_timeout,
    )
    .await?;
    let Some(line) = non_empty(&stdout) else {
        return Ok(None);
    };
    let mut parts = line.split('|');
    let dir = parts.next().unwrap_or("").trim().to_owned();
    let key = parts.next().unwrap_or("").trim();
    Ok((!dir.is_empty()).then(|| (dir, (!key.is_empty()).then(|| key.to_owned()))))
}

/// `wb-state worker-model <name>`.
pub async fn worker_model(
    config: &WorkbenchConfig,
    worker: &str,
) -> Result<Option<String>, CommandError> {
    let stdout = run(
        &config.wb_state_bin,
        &["worker-model", worker],
        config.command_timeout,
    )
    .await?;
    Ok(non_empty(&stdout))
}

/// `wb-state worker-machine <name>`. Empty output means the worker runs locally.
pub async fn worker_machine(
    config: &WorkbenchConfig,
    worker: &str,
) -> Result<Option<String>, CommandError> {
    let stdout = run(
        &config.wb_state_bin,
        &["worker-machine", worker],
        config.command_timeout,
    )
    .await?;
    Ok(non_empty(&stdout))
}

/// `wb-state worker-claude-session <name>`. Empty output means the workbench has not
/// recorded which conversation this worker runs, which is the normal state for a worker of
/// another harness.
pub async fn worker_claude_session(
    config: &WorkbenchConfig,
    worker: &str,
) -> Result<Option<String>, CommandError> {
    let stdout = run(
        &config.wb_state_bin,
        &["worker-claude-session", worker],
        config.command_timeout,
    )
    .await?;
    Ok(non_empty(&stdout))
}

/// `wb-state worker-transcript <name>`: the whole path of a worker's transcript, which the
/// workbench builds from the worker's directory and its conversation id with the same slug
/// rule this crate uses. Empty output means one of the two is unknown.
pub async fn worker_transcript(
    config: &WorkbenchConfig,
    worker: &str,
) -> Result<Option<String>, CommandError> {
    let stdout = run(
        &config.wb_state_bin,
        &["worker-transcript", worker],
        config.command_timeout,
    )
    .await?;
    Ok(non_empty(&stdout))
}

fn non_empty(stdout: &str) -> Option<String> {
    let trimmed = stdout.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}
