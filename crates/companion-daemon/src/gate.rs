// SPDX-License-Identifier: AGPL-3.0-only

//! Running a gate command of an approved job.
//!
//! `DESIGN.md` § Sicherheit: the daemon runs the text that was approved and nothing else,
//! without shell evaluation of variables or substitutions. That is not a promise made in a
//! comment here, it is the shape of the data: a gate command is a program and a list of
//! arguments, and this module hands exactly those to the operating system. There is no
//! string a shell could expand, because there is no shell.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use companion_protocol::GateCommand;
use tokio::process::Command;

/// How much of a gate's output is carried back. Enough to see what went wrong, little
/// enough that a runaway command cannot fill the event stream.
const MAX_OUTPUT_BYTES: usize = 8 * 1024;

/// What running one gate command produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GateOutcome {
    pub passed: bool,
    /// Absent when a signal ended the process or the timeout did.
    pub exit_code: Option<i32>,
    pub output: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum GateError {
    #[error("{program} is not installed")]
    NotFound { program: String },
    #[error("cannot run {program}: {source}")]
    Io {
        program: String,
        #[source]
        source: std::io::Error,
    },
}

/// Runs the command and waits for it, at most `timeout` long.
///
/// A command that is still running when the time is up is killed and counts as failed: a
/// gate that never answers is not a gate that passed.
pub async fn run(
    command: &GateCommand,
    project: &Path,
    timeout: Duration,
) -> Result<GateOutcome, GateError> {
    let working_dir = resolve_working_dir(command, project);

    let mut process = Command::new(&command.program);
    process
        .args(&command.args)
        .current_dir(&working_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let child = process.spawn().map_err(|source| {
        if source.kind() == std::io::ErrorKind::NotFound {
            GateError::NotFound {
                program: command.program.clone(),
            }
        } else {
            GateError::Io {
                program: command.program.clone(),
                source,
            }
        }
    })?;

    let output = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(source)) => {
            return Err(GateError::Io {
                program: command.program.clone(),
                source,
            });
        }
        Err(_) => {
            // kill_on_drop took care of the process when the future was dropped.
            return Ok(GateOutcome {
                passed: false,
                exit_code: None,
                output: Some(format!(
                    "the gate did not finish within {} seconds and was stopped",
                    timeout.as_secs()
                )),
            });
        }
    };

    let mut text = String::new();
    push_trimmed(&mut text, &output.stdout);
    push_trimmed(&mut text, &output.stderr);

    Ok(GateOutcome {
        passed: output.status.success(),
        exit_code: output.status.code(),
        output: (!text.is_empty()).then_some(text),
    })
}

/// Where the command runs: what the job file says, resolved against the project when it is
/// relative, and the project itself when the file says nothing.
fn resolve_working_dir(command: &GateCommand, project: &Path) -> PathBuf {
    match command.working_dir.as_deref() {
        None => project.to_path_buf(),
        Some(dir) => {
            let path = Path::new(dir);
            if path.is_absolute() {
                path.to_path_buf()
            } else {
                project.join(path)
            }
        }
    }
}

fn push_trimmed(into: &mut String, bytes: &[u8]) {
    if bytes.is_empty() {
        return;
    }
    let room = MAX_OUTPUT_BYTES.saturating_sub(into.len());
    if room == 0 {
        return;
    }
    let mut end = bytes.len().min(room);
    // Never cut a character in half.
    while end > 0 && !bytes.is_char_boundary_at(end) {
        end -= 1;
    }
    into.push_str(&String::from_utf8_lossy(&bytes[..end]));
    if end < bytes.len() {
        into.push_str("\n[output cut off]");
    }
}

/// `str::is_char_boundary` for a byte slice that may not be valid UTF-8 yet.
trait ByteBoundary {
    fn is_char_boundary_at(&self, index: usize) -> bool;
}

impl ByteBoundary for [u8] {
    fn is_char_boundary_at(&self, index: usize) -> bool {
        index == 0 || index >= self.len() || (self[index] & 0xC0) != 0x80
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(program: &str, args: &[&str]) -> GateCommand {
        GateCommand {
            program: program.to_owned(),
            args: args.iter().map(|arg| (*arg).to_owned()).collect(),
            working_dir: None,
        }
    }

    #[tokio::test]
    async fn a_command_that_succeeds_passes() {
        let outcome = run(
            &command("/usr/bin/true", &[]),
            Path::new("/tmp"),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert!(outcome.passed);
        assert_eq!(outcome.exit_code, Some(0));
    }

    #[tokio::test]
    async fn a_command_that_fails_reports_its_exit_code() {
        let outcome = run(
            &command("/usr/bin/false", &[]),
            Path::new("/tmp"),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert!(!outcome.passed);
        assert_eq!(outcome.exit_code, Some(1));
    }

    #[tokio::test]
    async fn output_comes_back_and_no_shell_touches_the_arguments() {
        // If a shell were involved, the $(…) would run and the output would differ. It
        // comes back verbatim because there is no shell.
        let outcome = run(
            &command("/bin/echo", &["$(whoami)", "a b"]),
            Path::new("/tmp"),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert!(outcome.passed);
        assert_eq!(outcome.output.as_deref(), Some("$(whoami) a b\n"));
    }

    #[tokio::test]
    async fn a_gate_that_never_answers_is_stopped_and_counts_as_failed() {
        let outcome = run(
            &command("/bin/sleep", &["30"]),
            Path::new("/tmp"),
            Duration::from_millis(200),
        )
        .await
        .unwrap();
        assert!(!outcome.passed);
        assert_eq!(outcome.exit_code, None);
        assert!(
            outcome
                .output
                .as_deref()
                .is_some_and(|text| text.contains("did not finish")),
            "the reason must be visible: {outcome:?}"
        );
    }

    #[tokio::test]
    async fn a_program_that_does_not_exist_is_named() {
        let error = run(
            &command("/usr/bin/there-is-no-such-program", &[]),
            Path::new("/tmp"),
            Duration::from_secs(10),
        )
        .await
        .expect_err("nothing to run");
        assert!(matches!(error, GateError::NotFound { .. }));
    }

    #[test]
    fn a_relative_working_directory_is_resolved_against_the_project() {
        let mut command = command("/usr/bin/true", &[]);
        command.working_dir = Some("crates/core".to_owned());
        assert_eq!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")),
            Path::new("/tmp/projekt/crates/core")
        );

        command.working_dir = Some("/opt/anderswo".to_owned());
        assert_eq!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")),
            Path::new("/opt/anderswo")
        );

        command.working_dir = None;
        assert_eq!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")),
            Path::new("/tmp/projekt")
        );
    }
}
