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

use companion_protocol::{Event, GateCommand};
use tokio::process::Command;

/// Preserve the argument list when safe. If a secret pattern spans arguments, replace
/// the whole list so adjacent fields cannot reconstruct it in a client.
pub fn redacted_args(command: &GateCommand) -> Vec<String> {
    let joined = command.args.join(" ");
    if companion_core::redact::secretish(&joined) != joined {
        vec!["[REDACTED]".to_owned()]
    } else {
        command
            .args
            .iter()
            .map(|arg| companion_core::redact::secretish(arg))
            .collect()
    }
}

pub fn redacted_display(command: &GateCommand) -> String {
    if redacted_args(command) == vec!["[REDACTED]".to_owned()] {
        "[REDACTED]".to_owned()
    } else {
        companion_core::redact::secretish(&command.display())
    }
}

pub fn redacted_result_event(command: &GateCommand, outcome: GateOutcome) -> Event {
    Event::GateResult {
        command: redacted_display(command),
        program: Some(companion_core::redact::secretish(&command.program)),
        args: redacted_args(command),
        exit_code: outcome.exit_code,
        passed: outcome.passed,
        output: outcome
            .output
            .as_deref()
            .map(companion_core::redact::secretish),
    }
}

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
/// inherits variables that only the daemon needs. `USER` is on the list because the Claude
/// CLI refuses to start without it ("Not logged in"), measured on 2026-09-05 for the
/// subagent runner, which had the same hole; a gate that calls `claude` needs it too.
const GATE_ENV_ALLOW: [&str; 6] = ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER"];

/// Runs the command and waits for it, at most `timeout` long.
///
/// A command that is still running when the time is up is killed and counts as failed: a
/// gate that never answers is not a gate that passed.
pub async fn run(
    command: &GateCommand,
    project: &Path,
    timeout: Duration,
) -> Result<GateOutcome, GateError> {
    #[cfg(test)]
    {
        run_inner(command, project, timeout, || {}).await
    }
    #[cfg(not(test))]
    {
        run_inner(command, project, timeout).await
    }
}

async fn run_inner(
    command: &GateCommand,
    project: &Path,
    timeout: Duration,
    #[cfg(test)] after_resolve: impl FnOnce(),
) -> Result<GateOutcome, GateError> {
    let working_dir = resolve_working_dir(command, project)?;
    #[cfg(test)]
    after_resolve();
    // Reject a path whose target changed while the command was being prepared.
    // The process itself still receives only the first canonical path.
    let checked_again = resolve_working_dir(command, project)?;
    if checked_again != working_dir {
        return Err(GateError::WorkingDirEscape {
            dir: command
                .working_dir
                .clone()
                .unwrap_or_else(|| project.display().to_string()),
            project: project.display().to_string(),
        });
    }

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
/// The first check rejects lexical escapes. The second resolves symlinks and checks the
/// resulting existing directory against the canonical project. A missing directory cannot
/// be used by `Command` and is rejected here. Returning that canonical path means a
/// change to a symlink alias after the check cannot redirect the process.
fn resolve_working_dir(command: &GateCommand, project: &Path) -> Result<PathBuf, GateError> {
    let Some(dir) = command.working_dir.as_deref() else {
        return project.canonicalize().map_err(|source| GateError::Io {
            program: command.program.clone(),
            source,
        });
    };
    let path = Path::new(dir);
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        project.join(path)
    };
    let resolved = lexical_normalize(&joined);
    let root = lexical_normalize(project);
    let escaped = || GateError::WorkingDirEscape {
        dir: dir.to_owned(),
        project: project.display().to_string(),
    };
    if !resolved.starts_with(&root) {
        return Err(escaped());
    }
    // Pin the name chosen at check time. A symlink alias may change before spawn,
    // but Command receives the resolved path, never the alias again.
    let canonical = resolved.canonicalize().map_err(|source| GateError::Io {
        program: command.program.clone(),
        source,
    })?;
    let canonical_root = root.canonicalize().map_err(|source| GateError::Io {
        program: command.program.clone(),
        source,
    })?;
    if !canonical.starts_with(canonical_root) {
        return Err(escaped());
    }
    Ok(canonical)
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

    #[test]
    fn split_gate_secret_is_removed_from_all_event_fields() {
        let command = command("/usr/bin/printf", &["password=", "gate-secret"]);
        let event = redacted_result_event(
            &command,
            GateOutcome {
                passed: false,
                exit_code: Some(1),
                output: Some("password=output-secret".to_owned()),
            },
        );
        let Event::GateResult {
            command,
            program,
            args,
            output,
            ..
        } = event
        else {
            panic!("gate event")
        };
        assert_eq!(args, vec!["[REDACTED]"]);
        assert_eq!(command, "[REDACTED]");
        assert_eq!(program.as_deref(), Some("/usr/bin/printf"));
        assert_eq!(output.as_deref(), Some("password=[REDACTED]"));
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
        let root =
            std::env::temp_dir().join(format!("companion-gate-resolve-{}", std::process::id()));
        let project = root.join("projekt");
        std::fs::create_dir_all(project.join("crates/core")).unwrap();
        std::fs::create_dir_all(project.join("src")).unwrap();
        let mut command = command("/usr/bin/true", &[]);
        command.working_dir = Some("crates/core".to_owned());
        assert_eq!(
            resolve_working_dir(&command, &project).unwrap(),
            project.join("crates/core").canonicalize().unwrap()
        );
        command.working_dir = None;
        assert_eq!(
            resolve_working_dir(&command, &project).unwrap(),
            project.canonicalize().unwrap()
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_working_directory_outside_the_project_is_refused() {
        let root =
            std::env::temp_dir().join(format!("companion-gate-escape-{}", std::process::id()));
        let project = root.join("projekt");
        std::fs::create_dir_all(project.join("src")).unwrap();
        let mut command = command("/usr/bin/true", &[]);
        command.working_dir = Some("/opt/anderswo".to_owned());
        assert!(matches!(
            resolve_working_dir(&command, &project),
            Err(GateError::WorkingDirEscape { .. })
        ));
        command.working_dir = Some("../../etc".to_owned());
        assert!(matches!(
            resolve_working_dir(&command, &project),
            Err(GateError::WorkingDirEscape { .. })
        ));
        command.working_dir = Some("src/../src".to_owned());
        assert_eq!(
            resolve_working_dir(&command, &project).unwrap(),
            project.join("src").canonicalize().unwrap()
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_symlink_out_of_the_project_is_refused_as_well() {
        // The lexical check alone passes this: `projekt/hinaus` starts with `projekt`. The
        // commanded session can lay the link after the person approved the job, so this is
        // a way past the approval and not only a mistake.
        let root = std::env::temp_dir().join(format!("companion-gate-{}-link", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let project = root.join("projekt");
        let elsewhere = root.join("anderswo");
        std::fs::create_dir_all(project.join("drin")).expect("the project is writable");
        std::fs::create_dir_all(&elsewhere).expect("the other directory is writable");
        std::os::unix::fs::symlink(&elsewhere, project.join("hinaus")).expect("the link is made");

        let mut command = command("/usr/bin/true", &[]);
        command.working_dir = Some("hinaus".to_owned());
        assert!(
            matches!(
                resolve_working_dir(&command, &project),
                Err(GateError::WorkingDirEscape { .. })
            ),
            "a symlink that leaves the project is not inside it"
        );

        // A link that stays inside is still fine, and so is an ordinary directory.
        std::os::unix::fs::symlink(project.join("drin"), project.join("kurz"))
            .expect("the second link is made");
        command.working_dir = Some("kurz".to_owned());
        resolve_working_dir(&command, &project).expect("a link inside the project is inside it");
        command.working_dir = Some("drin".to_owned());
        resolve_working_dir(&command, &project).expect("an ordinary directory still resolves");

        // A directory that is absent cannot be used by the process either.
        command.working_dir = Some("noch-nicht/da".to_owned());
        assert!(matches!(
            resolve_working_dir(&command, &project),
            Err(GateError::Io { .. })
        ));

        std::fs::remove_dir_all(&root).unwrap();
    }

    #[tokio::test]
    async fn changing_a_checked_symlink_does_not_start_outside_the_project() {
        let root = std::env::temp_dir().join(format!("companion-gate-race-{}", std::process::id()));
        let project = root.join("projekt");
        let inside = project.join("drin");
        let outside = root.join("draussen");
        std::fs::create_dir_all(&inside).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let link = project.join("arbeit");
        std::os::unix::fs::symlink(&inside, &link).unwrap();
        let mut gate = command("/bin/pwd", &[]);
        gate.working_dir = Some("arbeit".to_owned());
        let result = run_inner(&gate, &project, Duration::from_secs(10), || {
            std::fs::remove_file(&link).unwrap();
            std::os::unix::fs::symlink(&outside, &link).unwrap();
        })
        .await;
        assert!(matches!(result, Err(GateError::WorkingDirEscape { .. })));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn changing_a_canonical_working_directory_component_prevents_start() {
        let root =
            std::env::temp_dir().join(format!("companion-gate-component-{}", std::process::id()));
        let project = root.join("projekt");
        let inside = project.join("drin");
        let outside = root.join("draussen");
        std::fs::create_dir_all(&inside).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let mut gate = command("/bin/pwd", &[]);
        gate.working_dir = Some("drin".to_owned());
        let result = run_inner(&gate, &project, Duration::from_secs(10), || {
            std::fs::remove_dir(&inside).unwrap();
            std::os::unix::fs::symlink(&outside, &inside).unwrap();
        })
        .await;
        assert!(matches!(result, Err(GateError::WorkingDirEscape { .. })));
        std::fs::remove_dir_all(root).unwrap();
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
