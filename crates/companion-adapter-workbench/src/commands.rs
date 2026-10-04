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
    pub worker: Option<String>,
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
    args.extend_from_slice(&["list-panes", "-a", "-F", "#{session_name}|#{@wb_worker}"]);

    let stdout = run(&config.tmux_bin, &args, config.command_timeout).await?;
    Ok(stdout
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(2, '|');
            let session = parts.next()?.trim();
            if session.is_empty() {
                return None;
            }
            let worker = parts.next().unwrap_or("").trim();
            Some(Pane {
                tmux_session: session.to_owned(),
                worker: (!worker.is_empty()).then(|| worker.to_owned()),
            })
        })
        .collect())
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

fn non_empty(stdout: &str) -> Option<String> {
    let trimmed = stdout.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}
