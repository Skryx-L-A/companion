// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::AuftragId;

/// The reference a critic judges the result against.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reference {
    Path { path: String },
    Text { text: String },
}

/// One gate command, split into program and arguments.
///
/// `DESIGN.md` § Sicherheit requires the daemon to run the approved text and nothing else,
/// without shell evaluation of variables or substitutions. Storing the command already
/// split is what makes that structural: there is no string for a shell to expand.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct GateCommand {
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Working directory for the command. Relative paths are resolved against the project.
    pub working_dir: Option<String>,
}

impl GateCommand {
    /// The command as one line, for showing it to the person during approval.
    ///
    /// Arguments that contain a space or anything a reader could misread are quoted, so
    /// two different commands can never produce the same approval text: `prog "a b"` and
    /// `prog a b` are one argument and two, and they have to look that way. This form is
    /// display only and never handed to a shell; what runs is the structured form, and the
    /// approval binds to that.
    pub fn display(&self) -> String {
        let mut out = quote_for_display(&self.program);
        for arg in &self.args {
            out.push(' ');
            out.push_str(&quote_for_display(arg));
        }
        out
    }
}

/// Quotes a word for display when leaving it bare would be ambiguous.
fn quote_for_display(word: &str) -> String {
    let plain = !word.is_empty()
        && word.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '=' | '@' | ',')
        });
    if plain {
        return word.to_owned();
    }
    let escaped = word.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Where a run has to stop even if it is not finished.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Limits {
    pub iterations: Option<u32>,
    pub tokens: Option<u64>,
    /// Wall-clock limit. `DESIGN.md` § Loops names this the stand-in wherever the adapter
    /// reports neither iterations nor tokens.
    pub time_seconds: Option<u64>,
}

/// Which loop discipline the orchestrator runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum LoopType {
    /// One pass, the default.
    Once,
    /// Repeat until the done criterion holds or a limit is hit.
    Loop,
    /// Builder and critic per part, against a reference.
    Gauntlet,
}

/// The person's approval of one exact job text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Approval {
    /// Unix time in milliseconds.
    pub approved_at_ms: u64,
    /// Hex-encoded SHA-256 of the approved job text, so a later edit invalidates it.
    pub text_sha256: String,
}

/// The job file, stored in the project under `.companion/auftraege/<id>.json`.
///
/// `DESIGN.md` § Datenmodelle lists this as: id, projekt, ziel, fertig_kriterium,
/// referenz, guardrails, gate_befehle, limits, loop_typ, modell, freigabe.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Auftrag {
    pub schema_version: u32,
    pub id: AuftragId,
    /// Absolute path of the project directory.
    pub project: String,
    pub goal: String,
    pub done_criterion: String,
    pub reference: Option<Reference>,
    #[serde(default)]
    pub guardrails: Vec<String>,
    #[serde(default)]
    pub gate_commands: Vec<GateCommand>,
    #[serde(default)]
    pub limits: Limits,
    pub loop_type: LoopType,
    pub model: Option<String>,
    /// Absent until the person has approved the exact text. An unapproved job never
    /// causes an outward action.
    pub approval: Option<Approval>,
}

impl Auftrag {
    /// Whether the file carries an approval copy. Only the record outside the project
    /// decides whether a job may really run; this is the display side of it.
    pub fn is_approved(&self) -> bool {
        self.approval.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_different_commands_never_show_the_same_text() {
        let one_argument = GateCommand {
            program: "prog".to_owned(),
            args: vec!["a b".to_owned()],
            working_dir: None,
        };
        let two_arguments = GateCommand {
            program: "prog".to_owned(),
            args: vec!["a".to_owned(), "b".to_owned()],
            working_dir: None,
        };
        assert_eq!(one_argument.display(), r#"prog "a b""#);
        assert_eq!(two_arguments.display(), "prog a b");
        assert_ne!(one_argument.display(), two_arguments.display());
    }

    #[test]
    fn an_ordinary_command_stays_readable() {
        let command = GateCommand {
            program: "/usr/bin/cargo".to_owned(),
            args: vec!["test".to_owned(), "--workspace".to_owned()],
            working_dir: None,
        };
        assert_eq!(command.display(), "/usr/bin/cargo test --workspace");
    }

    #[test]
    fn a_quote_in_an_argument_is_escaped_rather_than_swallowed() {
        let with_quote = format!("say {q}hi{q}", q = '\u{22}');
        let command = GateCommand {
            program: "echo".to_owned(),
            args: vec![with_quote, String::new()],
            working_dir: None,
        };
        let shown = command.display();

        // The inner quotes are escaped, so the argument boundaries stay readable, and
        // the empty argument is visible as one instead of vanishing.
        let escaped_quote = format!("{b}{q}", b = '\u{5c}', q = '\u{22}');
        assert!(shown.contains(&escaped_quote), "got {shown}");
        let empty_argument = format!("{q}{q}", q = '\u{22}');
        assert!(shown.ends_with(&empty_argument), "got {shown}");
    }
}
