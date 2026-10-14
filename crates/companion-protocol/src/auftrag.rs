// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::{AuftragId, DeviceId};

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
    /// `prog a b` are one argument and two, and they have to look that way. A working
    /// directory is shown as a leading `(in <dir>)`, because the command runs there and two
    /// commands that differ only in where they run must not read the same. This form is
    /// display only and never handed to a shell; what runs is the structured form, and the
    /// approval binds to that.
    pub fn display(&self) -> String {
        let mut out = String::new();
        if let Some(dir) = &self.working_dir {
            out.push_str("(in ");
            out.push_str(&quote_for_display(dir));
            out.push_str(") ");
        }
        out.push_str(&quote_for_display(&self.program));
        for arg in &self.args {
            out.push(' ');
            out.push_str(&quote_for_display(arg));
        }
        out
    }
}

/// Quotes a word for display when leaving it bare would be ambiguous.
///
/// Control characters are written as escape sequences rather than passed through (added
/// 2026-09-03, security review). An argument holding a newline used to break the approval
/// text into two lines, so one command looked like two in front of the person approving it.
/// The approval binds to the structured form, so that was never a way to run something else
/// — but making two different commands look the same, or one command look like two, is
/// exactly what this function exists to prevent.
fn quote_for_display(word: &str) -> String {
    let plain = !word.is_empty()
        && word.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '=' | '@' | ',')
        });
    if plain {
        return word.to_owned();
    }
    let mut escaped = String::with_capacity(word.len() + 2);
    escaped.push('"');
    for character in word.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            // Everything else the terminal or a text field would act on rather than show:
            // the C0 range and delete (`is_control`), the two Unicode line separators, and
            // the bidirectional overrides, which can print a label in an order the bytes do
            // not have.
            other
                if other.is_control()
                    || matches!(other, '\u{2028}' | '\u{2029}')
                    || ('\u{202a}'..='\u{202e}').contains(&other)
                    || ('\u{2066}'..='\u{2069}').contains(&other) =>
            {
                escaped.push_str(&format!("\\u{{{:04x}}}", other as u32));
            }
            other => escaped.push(other),
        }
    }
    escaped.push('"');
    escaped
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

/// How the person proved it was them when they approved something.
///
/// `DESIGN.md` § Mobil, Freigaben vom Handy: "der Freigabe-Record vermerkt stets Gerät und
/// Bestätigungsart". At the machine the shell of the person is itself the proof — whoever
/// sits in front of an unlocked Mac is the person — which is what [`Self::Shell`] means and
/// why it is the default for a record written before this field existed. From a phone the
/// app says which of the three steps of that chapter it actually took, and [`Self::None`] is
/// a real answer rather than a missing one: the person chose that level and was warned.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalConfirmation {
    /// The desktop shell at the machine. There is no device and no second step.
    #[default]
    Shell,
    /// Face ID or Touch ID immediately before sending.
    Biometric,
    /// The device passcode, which is what a device without biometrics falls back to and what
    /// a high-risk setting demands whatever the level.
    Passcode,
    /// The app asked for nothing: whoever holds the unlocked phone approves.
    ///
    /// Not accepted for an approval from a device (closed 2026-09-03, security review).
    /// `DESIGN.md` § Mobil, Freigaben vom Handy asks for "immer mindestens die
    /// Gerätecode-Bestätigung des Systems", and a device that could send this would be
    /// deciding for itself that the sentence does not apply to it — the flag and the wish
    /// come from the same client. It stays in the enum because a record written before that
    /// day may carry it, and an audit trail does not get to rewrite what happened.
    None,
    /// A kind this build does not know, out of a record a newer one wrote.
    ///
    /// Never read as one of the four above, and [`Self::Shell`] least of all: an audit trail
    /// that turned a confirmation it cannot name into "the person at the Mac" would be making
    /// a claim about somebody. A request that carries this is refused rather than stored — a
    /// client names a kind this daemon knows or gets no approval.
    #[serde(other)]
    Unknown,
}

impl ApprovalConfirmation {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Shell => "shell",
            Self::Biometric => "biometric",
            Self::Passcode => "passcode",
            Self::None => "none",
            Self::Unknown => "unknown",
        }
    }

    /// Whether this is a confirmation a *device* may claim.
    ///
    /// `shell` is not: it means "the person at the machine", and a device that could claim it
    /// would be writing a record indistinguishable from one made at the Mac — which is
    /// exactly what the record is there to prevent.
    ///
    /// [`Self::None`] is not either, since 2026-09-03: see its own documentation. What a
    /// device may say is that it asked for biometrics or for the device passcode, which is
    /// the "mindestens die Gerätecode-Bestätigung" of `DESIGN.md` § Mobil.
    pub fn from_a_device(self) -> bool {
        matches!(self, Self::Biometric | Self::Passcode)
    }
}

/// The person's approval of one exact job text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Approval {
    /// Unix time in milliseconds.
    pub approved_at_ms: u64,
    /// Hex-encoded SHA-256 of the approved job text, so a later edit invalidates it.
    pub text_sha256: String,
    /// The device it came from, or absent for the shell at the machine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<DeviceId>,
    /// How the person proved it was them. Absent means [`ApprovalConfirmation::Shell`],
    /// which is what every approval written before this field existed was.
    #[serde(default)]
    pub confirmation: ApprovalConfirmation,
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
    fn the_working_directory_is_visible_and_distinguishes_two_commands() {
        let here = GateCommand {
            program: "cargo".to_owned(),
            args: vec!["test".to_owned()],
            working_dir: None,
        };
        let elsewhere = GateCommand {
            program: "cargo".to_owned(),
            args: vec!["test".to_owned()],
            working_dir: Some("crates/core".to_owned()),
        };
        assert_eq!(here.display(), "cargo test");
        assert_eq!(elsewhere.display(), "(in crates/core) cargo test");
        assert_ne!(
            here.display(),
            elsewhere.display(),
            "the working directory has to change the shown text"
        );
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

    #[test]
    fn a_control_character_never_reaches_the_approval_text_as_itself() {
        // One command that would have printed as two lines in front of the person
        // approving it, and one that would have printed its arguments in the wrong order.
        let command = GateCommand {
            program: "echo".to_owned(),
            args: vec![
                format!("erste{n}zweite", n = '\u{a}'),
                format!("mit{t}tab", t = '\u{9}'),
                format!("{o}umgedreht", o = '\u{202e}'),
            ],
            working_dir: Some(format!("projekt{r}", r = '\u{d}')),
        };
        let shown = command.display();

        assert!(
            !shown.chars().any(|c| c.is_control()),
            "the approval text stays one line: {shown:?}"
        );
        assert!(shown.contains("erste\\nzweite"), "{shown:?}");
        assert!(shown.contains("mit\\ttab"), "{shown:?}");
        assert!(shown.contains("projekt\\r"), "{shown:?}");
        assert!(shown.contains("\\u{202e}"), "{shown:?}");
        assert!(
            !shown.contains('\u{202e}'),
            "a direction mark reorders what a person reads: {shown:?}"
        );
    }
}
