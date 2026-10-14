// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    /// `~/.claude/sessions`, the registry Claude Code keeps for every live session of this
    /// machine: one `<pid>.json` naming its message socket, and one `<pid>.<hash>.key`
    /// holding the token a foreign sender authenticates with. This is what makes `send`
    /// possible without typing into a pane.
    pub claude_sessions_dir: PathBuf,
    /// `~/.claude/projects`, where Claude Code writes one transcript directory per working
    /// directory. This is what lets `read` answer for a session that has no result file.
    pub claude_projects_dir: PathBuf,
    /// `wb-close`, the one sanctioned way to close a worker pane. It refuses orchestrator
    /// panes itself, which is why this adapter calls it instead of killing panes.
    pub wb_close_bin: PathBuf,
    /// `wb-code`, which opens a workbench session for a project directory.
    pub wb_code_bin: PathBuf,
    /// `claude-worker`, which starts a worker inside an existing workbench session.
    pub claude_worker_bin: PathBuf,
    /// How long starting a session may take.
    ///
    /// Separate from [`Self::command_timeout`], because a start does more than answer a
    /// question: `wb-code` creates a tmux session and a Claude process, `claude-worker`
    /// splits a pane and hands over a job. Two seconds would call every successful start a
    /// failure.
    pub spawn_timeout: Duration,
    /// How long a single call to `wb-state` or `tmux` may take before it counts as failed.
    pub command_timeout: Duration,
    /// How much time one listing may spend on the optional `wb-state` calls that fill gaps
    /// the state files leave.
    ///
    /// The daemon puts every adapter call under a deadline, so a listing that asks about
    /// forty workers one after another would fail as a whole. Once this budget is spent the
    /// remaining gaps stay unknown, which is the honest answer and keeps the list fast.
    ///
    /// It is spent twice, not once: first on filling in fields, then again on finding
    /// sessions whose state file is not written yet. Why the second half is not a share of
    /// the first is written at `ProbeBudget`. A listing therefore has room for up to twice
    /// this value plus the one call that was already running when a deadline passed.
    pub probe_budget: Duration,
    /// How long a transcript that has not moved still counts as a session at work.
    ///
    /// A session writes to its transcript at every step of a turn, so a file that moved a
    /// moment ago belongs to a session that is doing something. The number is a threshold
    /// and not a measurement: a turn that thinks for a long time before it writes anything
    /// looks idle for as long as it thinks. Forty-five seconds is above the pauses a poll
    /// sees in practice and well below the minutes a person leaves a session sitting.
    pub busy_after: Duration,
    /// How long an address that led nowhere is believed before it is looked for again.
    ///
    /// Finding a transcript that is not where the naming rule says costs a scan of every
    /// project directory — 389 of them on the machine this was written on — and a session
    /// whose transcript does not exist yet would pay that on every poll. Remembering the
    /// empty answer for a while turns that into one scan a minute per session.
    pub transcript_retry: Duration,
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
            claude_sessions_dir: home.join(".claude/sessions"),
            claude_projects_dir: home.join(".claude/projects"),
            wb_close_bin: PathBuf::from("wb-close"),
            wb_code_bin: PathBuf::from("wb-code"),
            claude_worker_bin: PathBuf::from("claude-worker"),
            command_timeout: Duration::from_secs(2),
            spawn_timeout: Duration::from_secs(30),
            probe_budget: Duration::from_secs(2),
            busy_after: Duration::from_secs(45),
            transcript_retry: Duration::from_secs(60),
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
