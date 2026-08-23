// SPDX-License-Identifier: AGPL-3.0-only

use std::path::PathBuf;
use std::time::Duration;

/// Where the workbench keeps its state and which binaries to ask.
///
/// Every path and every binary is injectable, so a test points the adapter at a fixture
/// directory with stub binaries and never touches the real workbench.
#[derive(Debug, Clone)]
pub struct WorkbenchConfig {
    /// The `wb-state` binary. Looked up in `PATH` when it is a bare name.
    pub wb_state_bin: PathBuf,
    pub tmux_bin: PathBuf,
    /// Socket for `tmux -S`. `None` uses the default socket.
    pub tmux_socket: Option<PathBuf>,
    /// `~/.claude/workbench/sessions`, one JSON file per session.
    pub sessions_dir: PathBuf,
    /// `~/.claude/workbench/limits.jsonl`, one measurement per line, newest last.
    pub limits_file: PathBuf,
    /// `~/.claude/workbench/kontingent.json`, the fallback when no measurement is there.
    pub kontingent_file: PathBuf,
    /// `~/.pi-workers/results`, one directory per worker with its result files.
    pub results_dir: PathBuf,
    /// How long a single call to `wb-state` or `tmux` may take before it counts as failed.
    pub command_timeout: Duration,
}

impl WorkbenchConfig {
    /// The layout on this machine, derived from `$HOME`.
    pub fn for_home(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        let workbench = home.join(".claude/workbench");
        Self {
            wb_state_bin: PathBuf::from("wb-state"),
            tmux_bin: PathBuf::from("tmux"),
            tmux_socket: None,
            sessions_dir: workbench.join("sessions"),
            limits_file: workbench.join("limits.jsonl"),
            kontingent_file: workbench.join("kontingent.json"),
            results_dir: home.join(".pi-workers/results"),
            command_timeout: Duration::from_secs(5),
        }
    }
}

impl Default for WorkbenchConfig {
    fn default() -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        Self::for_home(home)
    }
}
