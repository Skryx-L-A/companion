// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What happens when a session reports itself done.
//!
//! `DESIGN.md` § Verhalten, "Fertig-Meldung": "Drei Stufen, Standard ist die erste: nur
//! weiterleiten; Gate-Befehl aus der Auftragsdatei ausfuehren und Result-Datei per Subagent
//! gegen das Fertig-Kriterium pruefen; eigene Reviewer-Session starten." The setting behind
//! it is [`DoneHandling`], and until this module existed nothing in the daemon read it: the
//! first stage happened because the `done` event reaches the shell either way, and the other
//! two happened not at all.
//!
//! The three stages are cumulative. `Gate` runs the gate commands of the approved job and
//! then has a subagent judge the result file against the job's `fertig_kriterium`.
//! `Reviewer` does all of that and additionally starts a second session that reviews the work
//! blind against the reference, with the `reviewer-pass` role of the shipped skill pack.
//!
//! **Nothing here skips an approval.** The gate commands are run through the same
//! [`crate::gate`] that `run_gate` uses, out of the same file, after the same check
//! ([`companion_core::auftrag::read_approved`]): the job has to carry an approval whose hash
//! matches the file as it stands right now, or nothing runs. That is how `DESIGN.md` §
//! Sicherheit is to be read here — the person approved a text that contains those commands
//! verbatim, so running them when the job they belong to reports itself finished is inside
//! that approval and not beside it. What this module never does is invent a command, widen
//! one, or run one out of a job whose approval no longer matches.
//!
//! **Where the result file may come from.** A `done` event out of a real adapter carries a
//! path that adapter measured from its own state files, and that path is trusted. A `done`
//! a session sent over the socket is a sentence, and its path is only read when it lies
//! inside the project of the approved job — otherwise a docked session could name any file
//! on the machine and have the daemon read it out to a subagent that may be in the cloud.
//! What tells the two apart is [`companion_core::AdapterEvent::self_reported`] and not the
//! adapter the event was published under: a reported session an adapter adopts is published
//! under that adapter, so until 2026-09-05 every orchestrator session the workbench
//! recognised as its own passed as measured (Befund 2 of the reviewer pass).
//!
//! **Which job a session belongs to** is likewise never taken from what the session says.
//! It stands in the register row that `spawn` wrote through the adapter's `session_started`,
//! and `ServerState::record_reported` deliberately writes neither project nor job id — see
//! there for what a connection with the `agent` role could otherwise run.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use companion_brain::{Outcome, Verdict};
use companion_core::{AdapterEvent, SpawnOptions};
use companion_protocol::{
    AdapterId, Auftrag, AuftragId, DoneHandling, Event, ProactiveClass, Reference, RegistryEntry,
    SelfAnswer, SessionId,
};
use tracing::{debug, warn};

use companion_protocol::REPORTED_ADAPTER;

use crate::server::ServerState;

/// How much of a result file is read and judged. A result file is prose about a piece of
/// work; past this it is a log, and a critic given a log judges the log.
const MAX_RESULT_BYTES: u64 = 256 * 1024;

/// Runs whatever the settings ask for when a session says it is done.
///
/// Never fails outwards: the person is told what happened, including that a stage could not
/// run and why. A finished-report check that quietly did nothing would be worse than one
/// that says "no gate command in the job".
///
/// `self_reported` is the provenance of the event, straight off
/// [`companion_core::AdapterEvent::self_reported`]: false where an adapter measured the
/// session, true where the session itself sent the sentence over the socket.
pub(crate) async fn on_done(
    state: Arc<ServerState>,
    self_reported: bool,
    session_id: SessionId,
    result_path: Option<String>,
) {
    let handling = state.done_handling();
    if handling == DoneHandling::Forward {
        debug!(session = %session_id, "done handling is forward; the event is the whole of it");
        return;
    }

    // A workbench task is checked by its lead agent and that agent's reviewer, and the
    // companion does not check it a second time: for a task the stage stands on forward,
    // whatever the setting says for other sessions (`AGENTS-PLAN.md` § 4, "Vergeben und
    // prüfen"). The gate verdict may still run as an extra brake where the job is approved.
    if state.is_task_session(&session_id) {
        match gate_for_task(&state, &session_id).await {
            Some(report) => announce(&state, &session_id, &report),
            None => debug!(
                session = %session_id,
                "a workbench task's result is forwarded and not checked a second time"
            ),
        }
        return;
    }

    let report = run(&state, self_reported, &session_id, result_path, handling).await;
    announce(&state, &session_id, &report);
}

/// The gate verdict for a workbench task that reported its result, or `None` where there is
/// nothing the daemon may run.
///
/// Only the gate commands: no critic and no reviewer, because the task has had both from the
/// workbench. And only out of a job the register row names — a row the daemon writes from an
/// adapter's own `spawn`, never from a report — whose approval matches the file as it stands.
/// A job id a carrier merely reported is never one to run commands from; that is Befund 1 of
/// 2026-09-05, and it holds for a task as for any other reported session. A task the workbench
/// started on its own therefore gets no gate here, which is the plan's forward.
async fn gate_for_task(state: &Arc<ServerState>, session_id: &SessionId) -> Option<Report> {
    let entry = state.registry().get(session_id).ok().flatten()?;
    let (Some(project), Some(auftrag_id)) = (entry.project, entry.auftrag_id) else {
        return None;
    };
    let project = PathBuf::from(project);
    let auftrag =
        companion_core::auftrag::read_approved(&project, &auftrag_id, state.registry()).ok()?;
    let gates = run_gates(state, session_id, &auftrag, &project).await;
    Some(Report {
        lines: vec![
            format!("Session {session_id} meldet Aufgabe {auftrag_id} zur Abnahme."),
            gates,
        ],
        verdict: None,
        auftrag_id: Some(auftrag_id),
    })
}

/// The report one finished session produced: the lines a person reads, and the verdict
/// where a critic reached one.
struct Report {
    lines: Vec<String>,
    verdict: Option<Verdict>,
    /// The job this was about, for the register entry.
    auftrag_id: Option<AuftragId>,
}

impl Report {
    fn only(line: impl Into<String>) -> Self {
        Self {
            lines: vec![line.into()],
            verdict: None,
            auftrag_id: None,
        }
    }

    fn text(&self) -> String {
        self.lines.join("\n")
    }
}

async fn run(
    state: &Arc<ServerState>,
    self_reported: bool,
    session_id: &SessionId,
    event_result_path: Option<String>,
    handling: DoneHandling,
) -> Report {
    let entry = match state.registry().get(session_id) {
        Ok(Some(entry)) => entry,
        Ok(None) => {
            return Report::only(format!(
                "Session {session_id} meldet sich fertig, steht aber nicht im Register. Ohne \
                 Registereintrag ist der Auftrag nicht zu finden, also lief keine Prüfung."
            ));
        }
        Err(error) => {
            warn!(%error, session = %session_id, "cannot read the register");
            return Report::only(format!(
                "Session {session_id} meldet sich fertig. Das Register ließ sich nicht lesen \
                 ({error}), also lief keine Prüfung."
            ));
        }
    };

    let (Some(project), Some(auftrag_id)) = (entry.project.clone(), entry.auftrag_id.clone())
    else {
        return Report::only(format!(
            "Session {session_id} meldet sich fertig. Sie gehört zu keinem Auftrag, und ohne \
             Auftragsdatei gibt es weder Gate-Befehl noch Fertig-Kriterium – es wurde nichts \
             geprüft."
        ));
    };
    let project = PathBuf::from(&project);

    let auftrag = match companion_core::auftrag::read_approved(
        &project,
        &auftrag_id,
        state.registry(),
    ) {
        Ok(auftrag) => auftrag,
        Err(error) => {
            return Report::only(format!(
                "Session {session_id} meldet Auftrag {auftrag_id} fertig. Die Auftragsdatei ist \
                 nicht als freigegeben zu lesen ({error}), also lief kein Gate-Befehl und keine \
                 Prüfung."
            ));
        }
    };

    let mut report = Report {
        lines: vec![format!(
            "Session {session_id} meldet Auftrag {auftrag_id} fertig."
        )],
        verdict: None,
        auftrag_id: Some(auftrag_id.clone()),
    };

    report
        .lines
        .push(run_gates(state, session_id, &auftrag, &project).await);

    let (line, verdict) = check_result(
        state,
        self_reported,
        session_id,
        &entry,
        &auftrag,
        &project,
        event_result_path,
    )
    .await;
    report.lines.push(line);
    report.verdict = verdict;

    if handling == DoneHandling::Reviewer {
        report
            .lines
            .push(start_reviewer(state, session_id, &auftrag, &project).await);
    }

    report
}

/// Runs every gate command of the approved job, in the order the file lists them, and
/// publishes each verdict as the same `gate_result` event a `run_gate` request produces.
///
/// A job without gate commands is said so plainly. `DESIGN.md`'s stage two is "Gate-Befehl
/// aus der Auftragsdatei ausfuehren", and a job that names none has nothing to run — guessing
/// one from the project (a `cargo test` because there is a `Cargo.toml`) would be the daemon
/// running a command nobody approved.
async fn run_gates(
    state: &Arc<ServerState>,
    session_id: &SessionId,
    auftrag: &Auftrag,
    project: &Path,
) -> String {
    if auftrag.gate_commands.is_empty() {
        return "Der Auftrag nennt keinen Gate-Befehl, also lief keiner.".to_owned();
    }

    let mut lines = Vec::new();
    for command in &auftrag.gate_commands {
        let display = crate::gate::redacted_display(command);
        match crate::gate::run(command, project, state.gate_timeout()).await {
            Ok(outcome) => {
                lines.push(format!(
                    "{display}: {}{}",
                    if outcome.passed {
                        "bestanden"
                    } else {
                        "durchgefallen"
                    },
                    match outcome.exit_code {
                        Some(code) if !outcome.passed => format!(" (Exit {code})"),
                        _ => String::new(),
                    }
                ));
                state.bus().publish(
                    AdapterId::new(REPORTED_ADAPTER),
                    companion_core::AdapterEvent::for_session(
                        session_id.clone(),
                        crate::gate::redacted_result_event(command, outcome),
                    ),
                );
            }
            Err(error) => lines.push(format!(
                "{display}: nicht ausführbar ({})",
                companion_core::redact::secretish(&error.to_string())
            )),
        }
    }
    format!("Gate: {}", lines.join("; "))
}

/// Has a subagent judge the result file against the job's done criterion.
async fn check_result(
    state: &Arc<ServerState>,
    self_reported: bool,
    session_id: &SessionId,
    entry: &RegistryEntry,
    auftrag: &Auftrag,
    project: &Path,
    event_result_path: Option<String>,
) -> (String, Option<Verdict>) {
    let (path, trusted) = path_to_judge(self_reported, event_result_path, &entry.result_path);
    let Some(path) = path else {
        return (
            "Ergebnisdatei: keine genannt, also nicht gegen das Fertig-Kriterium geprüft."
                .to_owned(),
            None,
        );
    };

    let text = match read_result(Path::new(&path), project, trusted) {
        Ok(text) => text,
        Err(reason) => {
            return (
                format!("Ergebnisdatei {path}: {reason} – nicht geprüft."),
                None,
            );
        }
    };

    let Some(brain) = state.brain_if_any() else {
        return (
            format!(
                "Ergebnisdatei {path}: dieser Daemon läuft ohne eigenes Modell, also gab es \
                 keinen Subagenten, der sie gegen das Fertig-Kriterium hätte prüfen können."
            ),
            None,
        );
    };

    match brain
        .judge_result(session_id, &auftrag.done_criterion, &text)
        .await
    {
        Some(verdict) => {
            let line = format!("Fertig-Kriterium: {}. {}", verdict.word(), verdict.text);
            (line, Some(verdict))
        }
        None => (
            format!(
                "Ergebnisdatei {path}: kein Subagent verfügbar oder der Lauf schlug fehl, also \
                 steht die Prüfung gegen das Fertig-Kriterium aus."
            ),
            None,
        ),
    }
}

/// Which result path to judge, and whether it may be read from outside the project.
///
/// The event's own path first: it is the freshest, and where an adapter measured it, it is
/// also the one the daemon may read without a containment check. A path the session named
/// itself is checked against the project, and so is one out of the register — that row does
/// not record who wrote it, so it is treated the strict way whatever put it there.
///
/// Its own function because this is the whole of the rule Befund 2 of the reviewer pass was
/// about, and it used to read `adapter.as_str() != REPORTED_ADAPTER`. That asked the wrong
/// question twice over: an adopted session's events are published under the adapter that
/// adopted it, and the events that actually reach [`on_done`] come off an adapter's own
/// stream and never carry the reported id at all — so the containment check below it could
/// not be reached. What decides is where the path came from, which is what
/// [`companion_core::AdapterEvent::self_reported`] says.
fn path_to_judge(
    self_reported: bool,
    event_result_path: Option<String>,
    recorded: &Option<String>,
) -> (Option<String>, bool) {
    match event_result_path {
        Some(path) => (Some(path), !self_reported),
        None => (recorded.clone(), false),
    }
}

/// Reads a result file, or says why it was not read.
///
/// `trusted` is what an adapter measured itself. Everything else has to lie inside the
/// project of the approved job: a docked orchestrator names its own result path over the
/// socket, and without this it could name any file this account can read and have the daemon
/// hand it to a subagent.
fn read_result(path: &Path, project: &Path, trusted: bool) -> Result<String, String> {
    #[cfg(test)]
    {
        read_result_after_check(path, project, trusted, || {})
    }
    #[cfg(not(test))]
    {
        read_result_after_check(path, project, trusted)
    }
}

/// The test-only callback exercises the exact check/use boundary.
fn read_result_after_check(
    path: &Path,
    project: &Path,
    trusted: bool,
    #[cfg(test)] after_check: impl FnOnce(),
) -> Result<String, String> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    if !trusted && !companion_core::paths::inside(path, project) {
        return Err(format!(
            "liegt außerhalb des Projekts {} und wurde von der Session selbst genannt",
            project.display()
        ));
    }
    #[cfg(test)]
    after_check();
    // O_NOFOLLOW rejects a replacement of the final component. O_NONBLOCK lets
    // a FIFO or device be rejected by the descriptor type check without hanging.
    // The inode comparison also catches a replaced parent directory.
    #[cfg(target_os = "macos")]
    const SAFE_OPEN_FLAGS: i32 = 0x0100 | 0x0004; // O_NOFOLLOW | O_NONBLOCK
    #[cfg(target_os = "linux")]
    const SAFE_OPEN_FLAGS: i32 = 0x20000 | 0x0800; // O_NOFOLLOW | O_NONBLOCK
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(SAFE_OPEN_FLAGS)
        .open(path)
        .map_err(|error| format!("nicht zu lesen ({error})"))?;
    let meta = file
        .metadata()
        .map_err(|error| format!("nicht zu lesen ({error})"))?;
    if !meta.is_file() {
        return Err("ist keine Datei".to_owned());
    }
    if meta.nlink() > 1 {
        return Err("hat mehrere Dateinamen".to_owned());
    }
    if !trusted {
        let canonical = path
            .canonicalize()
            .map_err(|error| format!("nicht zu lesen ({error})"))?;
        let root = project
            .canonicalize()
            .map_err(|error| format!("nicht zu lesen ({error})"))?;
        let current = canonical
            .metadata()
            .map_err(|error| format!("nicht zu lesen ({error})"))?;
        if !canonical.starts_with(root)
            || meta.dev() != current.dev()
            || meta.ino() != current.ino()
        {
            return Err(format!(
                "liegt außerhalb des Projekts {} und wurde von der Session selbst genannt",
                project.display()
            ));
        }
    }
    if meta.len() > MAX_RESULT_BYTES {
        return Err(format!(
            "ist {} Bytes groß, mehr als die {MAX_RESULT_BYTES}, die eine Ergebnisdatei sein \
             darf",
            meta.len()
        ));
    }
    let mut content = String::new();
    file.by_ref()
        .take(MAX_RESULT_BYTES + 1)
        .read_to_string(&mut content)
        .map_err(|error| format!("nicht zu lesen ({error})"))?;
    if content.len() as u64 > MAX_RESULT_BYTES {
        return Err(format!(
            "ist größer als die erlaubten {MAX_RESULT_BYTES} Bytes"
        ));
    }
    Ok(content)
}

/// Starts the session of the third stage: a critic that has not seen how the work was made.
///
/// It goes through the adapter's own `spawn`, the same way the shell's `spawn` request does,
/// with no job id of its own — the reviewer is not working on the job, it is judging it, and
/// giving it the job id would let it run that job's gate commands.
async fn start_reviewer(
    state: &Arc<ServerState>,
    session_id: &SessionId,
    auftrag: &Auftrag,
    project: &Path,
) -> String {
    // The adapter that owns the finished session is the one that can start another like it.
    let adapters = state.adapter_set();
    let mut owner = None;
    for adapter in adapters.iter() {
        match adapter.list().await {
            Ok(sessions) => {
                if sessions.iter().any(|session| &session.id == session_id) {
                    owner = Some(Arc::clone(adapter));
                    break;
                }
            }
            Err(error) => debug!(adapter = %adapter.id(), %error, "adapter cannot be asked"),
        }
    }
    let Some(adapter) = owner else {
        return "Reviewer-Session: kein Adapter kennt die fertige Session mehr, also wurde \
                keine gestartet."
            .to_owned();
    };

    match adapter
        .spawn(SpawnOptions {
            project: project.display().to_string(),
            auftrag_id: None,
            model: None,
            prompt: Some(reviewer_prompt(auftrag)),
        })
        .await
    {
        Ok(session) => format!(
            "Reviewer-Session {} läuft; ihr Bericht kommt über die Sessionliste.",
            session.id
        ),
        Err(error) => format!("Reviewer-Session ließ sich nicht starten: {error}"),
    }
}

/// The prompt the reviewer session gets.
///
/// It quotes the three independence rules of the `reviewer-pass` skill of the shipped skill
/// pack (`skills/reviewer-pass/SKILL.md`) rather than naming the skill and hoping the harness
/// has it installed: fresh context, judged blind against a concrete reference, refutation as
/// the default stance. What it deliberately does not carry is any account of how the work was
/// made — that is the first of those three rules.
fn reviewer_prompt(auftrag: &Auftrag) -> String {
    let reference = match &auftrag.reference {
        Some(Reference::Path { path }) => format!("Referenz: die Datei {path}."),
        Some(Reference::Text { text }) => format!("Referenz:\n{text}"),
        None => "Referenz: keine außer dem Fertig-Kriterium selbst.".to_owned(),
    };
    let guardrails = if auftrag.guardrails.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nVerbote des Auftrags:\n- {}",
            auftrag.guardrails.join("\n- ")
        )
    };

    format!(
        "Du bist ein unabhängiger Kritiker nach der Rolle `reviewer-pass`: frischer Kontext, \
         blind gegen eine Referenz, Widerlegung als Standardhaltung. Du weißt nicht, wie diese \
         Arbeit entstanden ist, und du sollst es auch nicht herausfinden.\n\n\
         Im Projekt wurde Auftrag {id} als fertig gemeldet. Prüfe, ob die Arbeit das \
         Fertig-Kriterium erfüllt.\n\n\
         Ziel des Auftrags:\n{goal}\n\n\
         Fertig-Kriterium:\n{criterion}\n\n\
         {reference}{guardrails}\n\n\
         Arbeitsweise: Ein Befund pro Zeile – wo (Datei und Zeile, oder das Kriterium beim \
         Namen), was gegen welchen Teil der Referenz verstößt, und wie schwer (blockiert \
         fertig / sollte behoben werden / Anmerkung). Zum Schluss eine Zeile mit der größten \
         Lücke. Lob ist kein Befund. Du reparierst nichts und weitest den Umfang nicht aus. \
         Findest du nach ernsthaften Widerlegungsversuchen nichts, sage das ausdrücklich – und \
         sage, was du versucht hast.",
        id = auftrag.id,
        goal = auftrag.goal,
        criterion = auftrag.done_criterion,
        reference = reference,
        guardrails = guardrails,
    )
}

/// Puts the report in front of the person and into the register.
///
/// Both, because they answer different questions. The notice is what somebody sees now; the
/// register entry is what they can look up next week, which is what `DESIGN.md` § Verhalten
/// asks for when it says every self-answer is "im Panel nachlesbar". The check *is* a
/// self-answer in the sense that section means: a question the companion settled out of the
/// job file instead of waking anybody — the question is whether the work is done, the source
/// is the job's own done criterion.
///
/// The notice is a [`Event::ProactiveNotice`] of class [`ProactiveClass::SessionReport`] and
/// no longer a turn of the companion's own. Until 2026-09-05 this called `Brain::announce`,
/// which writes a `chat_delta` and a `chat_done` and therefore a companion line straight into
/// the chat history — a session reporting about itself, in the one place `DESIGN.md` §
/// Chat-Hygiene keeps for the conversation. As an event it reaches the same person over the
/// figure and the notice log, it costs no model call, and it arrives in a daemon that has no
/// brain at all, which the old way did not.
fn announce(state: &Arc<ServerState>, session_id: &SessionId, report: &Report) {
    let text = report.text();

    state.bus().publish(
        AdapterId::new(crate::proactive::PROACTIVE_ADAPTER),
        // No session id, for the reason the observer gives at its own `publish`: the sentence
        // names the session, and an event carrying its id would reach a docked orchestrator
        // that happens to own it. This is the person's notice.
        AdapterEvent::adapter_wide(Event::ProactiveNotice {
            class: ProactiveClass::SessionReport,
            text: companion_core::redact::secretish(&text),
            quiet: false,
            ack: None,
            notice_id: None,
        }),
    );

    let answer = SelfAnswer {
        question: match &report.auftrag_id {
            Some(id) => format!("Ist Auftrag {id} wirklich fertig?"),
            None => "Ist die fertig gemeldete Arbeit wirklich fertig?".to_owned(),
        },
        answer: match &report.verdict {
            Some(verdict) => format!("{}: {}", verdict.word(), text),
            None => text,
        },
        source: match report.verdict.as_ref().map(|verdict| verdict.outcome) {
            Some(Outcome::Met) | Some(Outcome::NotMet) => {
                "Fertig-Meldung: Gate-Befehle der freigegebenen Auftragsdatei und ein Subagent \
                 gegen ihr fertig_kriterium"
                    .to_owned()
            }
            _ => "Fertig-Meldung: Gate-Befehle der freigegebenen Auftragsdatei".to_owned(),
        },
        answered_at_ms: companion_core::now_ms(),
    };
    if let Err(error) = state.registry().append_self_answer(session_id, &answer) {
        warn!(%error, session = %session_id, "cannot write the finished-report check into the register");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-done-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn only_a_path_an_adapter_measured_may_be_read_from_outside_the_project() {
        let named = || Some("/woanders/ergebnis.md".to_owned());
        let recorded = Some("/im/projekt/ergebnis.md".to_owned());

        // Measured by an adapter: read as it stands, which is what the whole trusted branch
        // is for — an adapter derives the path from its own state files.
        assert_eq!(path_to_judge(false, named(), &None), (named(), true));

        // Said by the session itself: the same path, now fenced to the project.
        assert_eq!(path_to_judge(true, named(), &None), (named(), false));

        // Nothing in the event: the register's own path, and never trusted, because the row
        // does not record who wrote it.
        assert_eq!(
            path_to_judge(false, None, &recorded),
            (recorded.clone(), false)
        );
        assert_eq!(path_to_judge(true, None, &recorded), (recorded, false));
        assert_eq!(path_to_judge(false, None, &None), (None, false));
    }

    #[test]
    fn a_path_the_session_named_outside_its_project_is_not_read() {
        let root = temp("outside");
        let project = root.join("projekt");
        std::fs::create_dir_all(&project).unwrap();
        let elsewhere = root.join("geheim.md");
        std::fs::write(&elsewhere, "Zugangsdaten").unwrap();

        let refusal = read_result(&elsewhere, &project, false)
            .expect_err("a path the session chose has to stay inside the project");
        assert!(refusal.contains("außerhalb"), "{refusal}");

        // The very same file is read when an adapter measured the path itself.
        assert_eq!(
            read_result(&elsewhere, &project, true).unwrap(),
            "Zugangsdaten"
        );

        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_symlink_out_of_the_project_does_not_count_as_inside_it() {
        let root = temp("symlink");
        let project = root.join("projekt");
        std::fs::create_dir_all(&project).unwrap();
        let elsewhere = root.join("geheim.md");
        std::fs::write(&elsewhere, "Zugangsdaten").unwrap();
        std::os::unix::fs::symlink(&elsewhere, project.join("ergebnis.md")).unwrap();

        let refusal = read_result(&project.join("ergebnis.md"), &project, false)
            .expect_err("a link that leaves the project leaves it");
        assert!(refusal.contains("außerhalb"), "{refusal}");

        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn replacing_a_checked_result_with_an_outside_symlink_reads_nothing() {
        let root = temp("race");
        let project = root.join("projekt");
        std::fs::create_dir_all(&project).unwrap();
        let result = project.join("ergebnis.md");
        let outside = root.join("draussen.md");
        std::fs::write(&result, "inside").unwrap();
        std::fs::write(&outside, "outside").unwrap();
        let refusal = read_result_after_check(&result, &project, false, || {
            std::fs::remove_file(&result).unwrap();
            std::os::unix::fs::symlink(&outside, &result).unwrap();
        })
        .expect_err("the open must not follow the replacement");
        assert!(refusal.contains("nicht zu lesen"), "{refusal}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_result_hardlink_to_an_outside_file_is_refused() {
        let root = temp("hardlink");
        let project = root.join("projekt");
        std::fs::create_dir_all(&project).unwrap();
        let outside = root.join("outside.md");
        std::fs::write(&outside, "outside marker").unwrap();
        let result = project.join("result.md");
        std::fs::hard_link(&outside, &result).unwrap();
        assert!(read_result(&result, &project, false).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_result_fifo_returns_without_blocking() {
        use std::sync::mpsc;
        let root = temp("fifo");
        let project = root.join("projekt");
        std::fs::create_dir_all(&project).unwrap();
        let fifo = project.join("result.md");
        assert!(
            std::process::Command::new("/usr/bin/mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let (tx, rx) = mpsc::channel();
        let reader_path = fifo.clone();
        let reader_project = project.clone();
        let reader = std::thread::spawn(move || {
            tx.send(read_result(&reader_path, &reader_project, false))
                .unwrap();
        });
        let quick = rx.recv_timeout(std::time::Duration::from_millis(500));
        if quick.is_err() {
            // Release the old blocking open before joining the thread.
            let _ = std::fs::OpenOptions::new().write(true).open(&fifo);
        }
        reader.join().unwrap();
        assert!(
            matches!(quick, Ok(Err(_))),
            "FIFO open must return an error promptly"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_ordinary_result_file_inside_the_project_is_read() {
        let root = temp("inside");
        let project = root.join("projekt");
        std::fs::create_dir_all(project.join("berichte")).unwrap();
        let result = project.join("berichte/fertig.md");
        std::fs::write(&result, "Alles gebaut.").unwrap();

        assert_eq!(
            read_result(&result, &project, false).unwrap(),
            "Alles gebaut."
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_result_file_that_is_a_whole_log_is_refused_rather_than_judged() {
        let root = temp("huge");
        let project = root.join("projekt");
        std::fs::create_dir_all(&project).unwrap();
        let result = project.join("ergebnis.md");
        std::fs::write(&result, vec![b'x'; MAX_RESULT_BYTES as usize + 1]).unwrap();

        let refusal = read_result(&result, &project, true).expect_err("too big to judge");
        assert!(refusal.contains("Bytes groß"), "{refusal}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_directory_is_not_a_result_file() {
        let root = temp("dir");
        let project = root.join("projekt");
        std::fs::create_dir_all(project.join("ergebnis")).unwrap();

        let refusal =
            read_result(&project.join("ergebnis"), &project, true).expect_err("not a file");
        assert!(refusal.contains("keine Datei"), "{refusal}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn the_reviewer_prompt_carries_the_criterion_and_the_reference_and_no_history() {
        let auftrag = Auftrag {
            schema_version: 1,
            id: AuftragId::new("a1"),
            project: "/tmp/projekt".to_owned(),
            goal: "Den Zähler bauen".to_owned(),
            done_criterion: "cargo test ist grün und der Zähler steht im Panel".to_owned(),
            reference: Some(Reference::Path {
                path: "DESIGN.md".to_owned(),
            }),
            guardrails: vec!["Nichts pushen".to_owned()],
            gate_commands: Vec::new(),
            limits: Default::default(),
            loop_type: companion_protocol::LoopType::Once,
            model: None,
            approval: None,
        };
        let prompt = reviewer_prompt(&auftrag);
        assert!(prompt.contains("cargo test ist grün"), "{prompt}");
        assert!(prompt.contains("DESIGN.md"), "{prompt}");
        assert!(prompt.contains("Nichts pushen"), "{prompt}");
        assert!(prompt.contains("reviewer-pass"), "{prompt}");
        assert!(prompt.contains("Widerlegung"), "{prompt}");
        // The critic is never handed the job id it could run gate commands with, and never
        // told how the work was made.
        assert!(!prompt.contains("Gate-Befehl"), "{prompt}");
    }

    #[test]
    fn a_job_without_a_reference_says_so_rather_than_inventing_one() {
        let auftrag = Auftrag {
            schema_version: 1,
            id: AuftragId::new("a2"),
            project: "/tmp/projekt".to_owned(),
            goal: "Etwas bauen".to_owned(),
            done_criterion: "Es läuft".to_owned(),
            reference: None,
            guardrails: Vec::new(),
            gate_commands: Vec::new(),
            limits: Default::default(),
            loop_type: companion_protocol::LoopType::Once,
            model: None,
            approval: None,
        };
        let prompt = reviewer_prompt(&auftrag);
        assert!(
            prompt.contains("keine außer dem Fertig-Kriterium"),
            "{prompt}"
        );
    }
}
