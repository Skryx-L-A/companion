// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    #[error(
        "the working directory {dir} resolves outside the project {project}; a gate runs inside \
         the project it belongs to"
    )]
    WorkingDirEscape { dir: String, project: String },
}

/// Environment variables a gate is allowed to see. Everything else is cleared, so a gate
/// runs with a small, predictable environment instead of the whole daemon's — it never
/// inherits variables that only the daemon needs.
const GATE_ENV_ALLOW: [&str; 5] = ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"];

/// Runs the command and waits for it, at most `timeout` long.
///
/// A command that is still running when the time is up is killed and counts as failed: a
/// gate that never answers is not a gate that passed.
pub async fn run(
    command: &GateCommand,
    project: &Path,
    timeout: Duration,
) -> Result<GateOutcome, GateError> {
    let working_dir = resolve_working_dir(command, project)?;

    let mut process = Command::new(&command.program);
    process
        .args(&command.args)
        .current_dir(&working_dir)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for key in GATE_ENV_ALLOW {
        if let Ok(value) = std::env::var(key) {
            process.env(key, value);
        }
    }

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
///
/// The resolved path has to stay inside the project. A `..` that climbs out, or an absolute
/// path somewhere else, is refused rather than run: the approval binds a command to the
/// project it belongs to, and a gate that runs elsewhere is not the gate that was approved.
/// The check is lexical, so it holds whether or not the directory exists yet.
fn resolve_working_dir(command: &GateCommand, project: &Path) -> Result<PathBuf, GateError> {
    let Some(dir) = command.working_dir.as_deref() else {
        return Ok(project.to_path_buf());
    };
    let path = Path::new(dir);
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        project.join(path)
    };
    let resolved = lexical_normalize(&joined);
    let root = lexical_normalize(project);
    if resolved.starts_with(&root) {
        Ok(resolved)
    } else {
        Err(GateError::WorkingDirEscape {
            dir: dir.to_owned(),
            project: project.display().to_string(),
        })
    }
}

/// Resolves `.` and `..` without touching the file system, so a path can be checked for
/// containment before the directory it names exists.
fn lexical_normalize(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
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
            resolve_working_dir(&command, Path::new("/tmp/projekt")).unwrap(),
            Path::new("/tmp/projekt/crates/core")
        );

        command.working_dir = None;
        assert_eq!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")).unwrap(),
            Path::new("/tmp/projekt")
        );
    }

    #[test]
    fn a_working_directory_outside_the_project_is_refused() {
        let mut command = command("/usr/bin/true", &[]);

        // An absolute path somewhere else.
        command.working_dir = Some("/opt/anderswo".to_owned());
        assert!(matches!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")),
            Err(GateError::WorkingDirEscape { .. })
        ));

        // A relative path that climbs out with `..`.
        command.working_dir = Some("../../etc".to_owned());
        assert!(matches!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")),
            Err(GateError::WorkingDirEscape { .. })
        ));

        // A `..` that stays inside is fine.
        command.working_dir = Some("crates/../src".to_owned());
        assert_eq!(
            resolve_working_dir(&command, Path::new("/tmp/projekt")).unwrap(),
            Path::new("/tmp/projekt/src")
        );
    }

    #[tokio::test]
    async fn a_gate_does_not_inherit_the_daemon_environment() {
        // The test process always carries CARGO_* variables, and none of them is on the
        // gate's allow list. If the gate inherited the daemon environment they would show up
        // in `env`; with the environment cleared they cannot.
        let outcome = run(
            &command("/usr/bin/env", &[]),
            Path::new("/tmp"),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert!(outcome.passed, "env should run: {outcome:?}");
        let printed = outcome.output.unwrap_or_default();
        assert!(
            !printed.contains("CARGO"),
            "the gate inherited the daemon environment: {printed}"
        );
        // Every line that is there names an allowed variable, nothing else.
        for line in printed.lines() {
            if let Some((key, _)) = line.split_once('=') {
                assert!(
                    GATE_ENV_ALLOW.contains(&key),
                    "unexpected variable {key} reached the gate"
                );
            }
        }
    }
}
