// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The rollout reader against files a real `codex` wrote.
//!
//! Ignored by default and pointed at a home on purpose:
//!
//! ```text
//! COMPANION_CODEX_HOME=$HOME/.codex \
//!   cargo test -p companion-adapter-codex --test live_rollout -- --ignored
//! ```
//!
//! It only reads, and it names no content in its output: a rollout is somebody's working
//! session. What it checks is the shape — that the lines the parser expects are the lines
//! the CLI writes, and that the fields it reads come out as numbers rather than as silence.
//!
//! This is deliberately not a turn. Driving `codex exec --json` costs subscription quota
//! and is the one thing this adapter still has never done; the two field names the stream
//! parser accepts in both spellings stay open until somebody runs one.

use std::path::PathBuf;

use companion_adapter_codex::rollout;

const FIXTURE_ROLLOUT: &str = concat!(
    r#"{"type":"turn_context","payload":{"model":"fixture-model"}}"#,
    "\n",
    r#"{"type":"event_msg","payload":{"type":"task_started","model_context_window":128}}"#,
    "\n",
    r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42},"model_context_window":128}}}"#,
    "\n",
    r#"{"type":"event_msg","payload":{"type":"agent_message","message":"fixture answer"}}"#,
    "\n",
);

#[test]
#[ignore = "reads a real codex home; see the module comment"]
fn the_rollout_reader_understands_what_the_cli_actually_writes() {
    let Some(home) = std::env::var_os("COMPANION_CODEX_HOME") else {
        panic!("set COMPANION_CODEX_HOME to the codex home to read");
    };
    let sessions = PathBuf::from(home).join("sessions");
    assert!(
        sessions.is_dir(),
        "no sessions directory under that home: {}",
        sessions.display()
    );

    let mut files = Vec::new();
    collect(&sessions, &mut files);
    assert!(!files.is_empty(), "no rollout files to read");
    println!("{} rollout files", files.len());

    let mut with_model = 0;
    let mut with_window = 0;
    let mut with_tokens = 0;
    let mut with_budget = 0;
    let mut with_output = 0;

    for file in &files {
        let summary = rollout::summarise(file);
        with_model += usize::from(summary.model.is_some());
        with_window += usize::from(summary.context_window.is_some());
        with_tokens += usize::from(summary.used_tokens.is_some());
        with_budget += usize::from(summary.budget.is_some());
        with_output += usize::from(summary.last_output.is_some());
    }

    println!(
        "model {with_model}, window {with_window}, tokens {with_tokens}, \
         quota {with_budget}, last output {with_output} of {}",
        files.len()
    );
    assert!(
        with_window > 0,
        "not one rollout named its context window; the parser and the format have drifted"
    );
    assert!(
        with_model > 0,
        "not one rollout named its model; the parser and the format have drifted"
    );
}

/// The same sessions-directory walk and rollout parser as the live test, but rooted at an
/// explicitly created directory below `TMPDIR`; the real `~/.codex` is never consulted.
#[test]
fn the_rollout_reader_uses_only_a_scratch_codex_home() {
    let home = std::env::temp_dir().join(format!(
        "companion-codex-rollout-fixture-{}",
        std::process::id()
    ));
    let _cleanup = ScratchHome(home.clone());
    let sessions = home.join("sessions/2026/09/21");
    std::fs::create_dir_all(&sessions).expect("the scratch Codex home is writable");
    let rollout_path = sessions.join("rollout-fixture.jsonl");
    std::fs::write(&rollout_path, FIXTURE_ROLLOUT).expect("the fixture rollout is writable");

    let mut files = Vec::new();
    collect(&home.join("sessions"), &mut files);
    assert_eq!(files, vec![rollout_path]);

    let summary = rollout::summarise(&files[0]);
    assert_eq!(summary.model.as_deref(), Some("fixture-model"));
    assert_eq!(summary.context_window, Some(128));
    assert_eq!(summary.used_tokens, Some(42));
    assert_eq!(summary.last_output.as_deref(), Some("fixture answer"));
}

struct ScratchHome(PathBuf);

impl Drop for ScratchHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn collect(dir: &std::path::Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
}
