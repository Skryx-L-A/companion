// SPDX-License-Identifier: AGPL-3.0-only

//! The settings document.
//!
//! It lives here rather than next to the file handling in `companion-core` because it
//! travels: `get_settings` and `set_settings` put this exact document on the wire, so it is
//! part of the shared vocabulary and not an internal of the daemon. Reading and writing the
//! file stays in `companion_core::settings`, which owns the path, the atomic write and the
//! 0600 mode.
//!
//! The answers of the setup assistant (`DESIGN.md` § Ersteinrichtung) that decide what the
//! daemon *does* live here, one field per point; the ones that only decide what the shell
//! *shows* stay in the shell. The point number is named on every field, so the mapping is
//! traceable in both directions.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::endpoint_config::{EndpointConfig, EndpointError};

/// Version of the settings file format.
pub const SETTINGS_SCHEMA_VERSION: u32 = 1;

/// Id of the generic terminal adapter, the one adapter nobody may end up with by accident.
pub const PTY_ADAPTER_ID: &str = "pty";

/// Longest name the figure may carry. Long enough for a sentence somebody means as a name,
/// short enough that it still fits a menu line.
pub const MAX_FIGURE_NAME_LEN: usize = 64;

/// How far the companion may act on its own with a class of tools.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum ToolBoundary {
    /// Read, never write.
    ReadOnly,
    /// Ask before every use. The default everywhere.
    #[default]
    Ask,
    /// Act without asking.
    Full,
}

impl ToolBoundary {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::Ask => "ask",
            Self::Full => "full",
        }
    }
}

/// The three tool classes that reach outside the machine. `DESIGN.md` § Sicherheit puts
/// them on `ask` and lets only the person raise them, with a warning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct HighRiskSettings {
    pub mail: ToolBoundary,
    pub push: ToolBoundary,
    pub publish: ToolBoundary,
}

impl Default for HighRiskSettings {
    fn default() -> Self {
        Self {
            mail: ToolBoundary::Ask,
            push: ToolBoundary::Ask,
            publish: ToolBoundary::Ask,
        }
    }
}

/// Where the companion may reach a person. `DESIGN.md` § Ersteinrichtung, point 12.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum NotificationChannel {
    /// The character on the screen. The only channel that never leaves the machine, and
    /// therefore the only one that is on by default.
    Figure,
    /// A short sound next to the figure.
    Sound,
    /// Said out loud, over the configured speech output.
    Speech,
    /// A notification of the operating system, seen even when the figure is covered.
    SystemNotification,
    /// A push message to a phone.
    Push,
    /// An email.
    Mail,
}

impl NotificationChannel {
    /// Whether reaching somebody this way sends something off this machine.
    pub fn leaves_the_machine(self) -> bool {
        matches!(self, Self::Push | Self::Mail)
    }
}

/// How far the companion acts on its own when a session reports something.
/// `DESIGN.md` § Ersteinrichtung, point 3.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum Autonomy {
    /// Watch and report, decide nothing. The default.
    #[default]
    Observe,
    /// Answer what is unambiguous, ask about the rest.
    Ask,
    /// Answer and act within the guardrails of the job file.
    Act,
}

/// How much of the skill package goes into a recognised harness.
/// `DESIGN.md` § Ersteinrichtung, point 10.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SkillLevel {
    /// Nothing is installed.
    None,
    /// The obligatory core.
    #[default]
    Recommended,
    /// The core and the checked extensions.
    Many,
    All,
}

/// What happens when a session reports that it is done.
/// `DESIGN.md` § Ersteinrichtung, point 11.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DoneHandling {
    /// The person is told, and nothing else happens. The sparing default.
    #[default]
    Forward,
    /// The gate commands of the job file run, and their verdict is reported with it.
    Gate,
    /// A second session reviews the result before the person sees it.
    Reviewer,
}

/// How much the companion says. `DESIGN.md` § Ersteinrichtung, point 8.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ConversationStyle {
    #[default]
    Terse,
    Detailed,
}

/// How the companion addresses the person. `DESIGN.md` § Ersteinrichtung, point 8.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum AddressForm {
    /// German "du", English first name.
    #[default]
    Informal,
    Formal,
}

/// Whether an adapter is loaded when the settings say nothing about it.
///
/// Most are: an empty `enabled_adapters` means "everything this build has". An opt-in one
/// is not, and that is a security decision rather than a taste one — `DESIGN.md`
/// § Sicherheit points out that a permission level has no hold over a foreign CLI, so the
/// adapter that runs foreign CLIs has to be asked for by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterDefault {
    /// Loaded unless the settings name other adapters instead.
    On,
    /// Loaded only when the settings name it.
    OptIn,
}

/// Everything the daemon reads out of its settings file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct Settings {
    pub schema_version: u32,
    /// Boundary for the companion's own tools, everything that is not high risk.
    /// `DESIGN.md` § Ersteinrichtung, point 13.
    pub tool_boundary: ToolBoundary,
    /// Boundary a spawned session runs under. `DESIGN.md` § Ersteinrichtung, point 2.
    ///
    /// A second field rather than the same one, because the two are different questions:
    /// what the companion may do itself, and what it may let an agent do.
    pub agent_boundary: ToolBoundary,
    pub high_risk: HighRiskSettings,
    /// Adapters the daemon should load. Empty means every adapter it was built with,
    /// with one exception: an adapter that is opt-in stays off until it is named here by
    /// its id. The generic terminal adapter ([`PTY_ADAPTER_ID`]) is the one, because
    /// `DESIGN.md` § Sicherheit says a permission level cannot restrict a foreign CLI —
    /// nobody is to end up with one by accident.
    pub enabled_adapters: Vec<String>,
    /// The command the generic terminal adapter runs, program first, arguments after.
    /// Empty is the default and means it starts nothing: there is no sensible default
    /// program for "any CLI".
    pub pty_command: Vec<String>,
    /// Where the person is told about something. The figure alone by default: every other
    /// channel either makes noise or leaves the machine.
    /// `DESIGN.md` § Ersteinrichtung, point 12.
    pub notification_channels: Vec<NotificationChannel>,
    /// Whether a finished session is worth telling the person about. On by default, because
    /// a run that is done is the one thing somebody is actually waiting for.
    pub forward_done: bool,
    /// What happens with a finished run beyond telling the person.
    /// `DESIGN.md` § Ersteinrichtung, point 11. [`Self::forward_done`] says whether the
    /// person hears about it at all, this says what else runs.
    pub done_handling: DoneHandling,
    pub autonomy: Autonomy,
    /// Whether the companion may read what is installed — skills, tools, MCP servers,
    /// workflows. `DESIGN.md` § Ersteinrichtung, point 4, and § Sicherheit: reading a
    /// working directory is reading somebody's work, so it stays off until it is allowed.
    pub inventory_allowed: bool,
    /// Share of the budget at which the companion stops starting anything new, in per cent.
    /// Zero means no limit. `DESIGN.md` § Ersteinrichtung, point 7.
    pub budget_limit_percent: u8,
    /// `DESIGN.md` § Ersteinrichtung, point 10.
    pub skill_level: SkillLevel,
    /// `DESIGN.md` § Ersteinrichtung, point 8: how much he says.
    pub conversation_style: ConversationStyle,
    /// `DESIGN.md` § Ersteinrichtung, point 8: how he addresses the person.
    pub address_form: AddressForm,
    /// `DESIGN.md` § Ersteinrichtung, point 8: what the figure is called. The companion
    /// writes in this name, which is why it is the daemon's and not only the window's.
    pub figure_name: String,
    /// The provider profiles and which role uses which of them. Keys live in the keychain;
    /// a profile here holds only the name of one.
    /// `DESIGN.md` § Ersteinrichtung, point 9.
    pub endpoints: EndpointConfig,
}

/// The name the figure carries until somebody renames it.
pub const DEFAULT_FIGURE_NAME: &str = "Companion";

impl Default for Settings {
    fn default() -> Self {
        Self {
            schema_version: SETTINGS_SCHEMA_VERSION,
            tool_boundary: ToolBoundary::Ask,
            agent_boundary: ToolBoundary::Ask,
            high_risk: HighRiskSettings::default(),
            enabled_adapters: Vec::new(),
            pty_command: Vec::new(),
            notification_channels: vec![NotificationChannel::Figure],
            forward_done: true,
            done_handling: DoneHandling::default(),
            autonomy: Autonomy::Observe,
            inventory_allowed: false,
            budget_limit_percent: 0,
            skill_level: SkillLevel::default(),
            conversation_style: ConversationStyle::default(),
            address_form: AddressForm::default(),
            figure_name: DEFAULT_FIGURE_NAME.to_owned(),
            endpoints: EndpointConfig::default(),
        }
    }
}

/// Why a settings document cannot be used.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum InvalidSettings {
    #[error("the settings say schema version {found}, this build understands {expected}")]
    UnknownSchema { found: u32, expected: u32 },
    #[error("a budget limit of {percent} per cent is not a share of anything")]
    BudgetOutOfRange { percent: u8 },
    #[error("the figure needs a name")]
    NamelessFigure,
    #[error("the name of the figure is longer than {limit} characters")]
    FigureNameTooLong { limit: usize },
    #[error(transparent)]
    Endpoints(#[from] EndpointError),
}

impl Settings {
    /// Whether an adapter should be loaded at all.
    pub fn adapter_enabled(&self, id: &str, default: AdapterDefault) -> bool {
        let named = self.enabled_adapters.iter().any(|name| name == id);
        match default {
            AdapterDefault::On => named || self.enabled_adapters.is_empty(),
            AdapterDefault::OptIn => named,
        }
    }

    /// Everything that makes this document unusable, checked in one place.
    ///
    /// The same check runs when the file is read and when a client sends a document over
    /// the socket, so a settings page cannot write anything the daemon would refuse to load
    /// on the next start.
    pub fn validate(&self) -> Result<(), InvalidSettings> {
        if self.schema_version > SETTINGS_SCHEMA_VERSION {
            return Err(InvalidSettings::UnknownSchema {
                found: self.schema_version,
                expected: SETTINGS_SCHEMA_VERSION,
            });
        }
        if self.budget_limit_percent > 100 {
            return Err(InvalidSettings::BudgetOutOfRange {
                percent: self.budget_limit_percent,
            });
        }
        let name = self.figure_name.trim();
        if name.is_empty() {
            return Err(InvalidSettings::NamelessFigure);
        }
        if name.chars().count() > MAX_FIGURE_NAME_LEN {
            return Err(InvalidSettings::FigureNameTooLong {
                limit: MAX_FIGURE_NAME_LEN,
            });
        }
        self.endpoints.validate()?;
        Ok(())
    }

    /// What `next` would raise that only a person may raise, each in one line.
    ///
    /// `DESIGN.md` § Sicherheit: mail, push and publish stand on `ask`, and only the person
    /// puts them on `full`, with a warning. The same holds for every other step that widens
    /// what runs without being asked — a boundary going to `full`, the companion acting on
    /// its own, a channel that leaves the machine, and the adapter that runs a foreign CLI,
    /// which no permission level can restrain.
    ///
    /// Only the direction matters. Lowering a boundary, dropping a channel or switching the
    /// terminal adapter off is nobody's risk and needs no confirmation.
    pub fn high_risk_changes(&self, next: &Settings) -> Vec<String> {
        let mut raised = Vec::new();

        let mut boundary = |what: &str, before: ToolBoundary, after: ToolBoundary| {
            if after > before && after == ToolBoundary::Full {
                raised.push(format!(
                    "{what} goes from {} to {}",
                    before.as_str(),
                    after.as_str()
                ));
            }
        };
        boundary(
            "the boundary of the companion's own tools",
            self.tool_boundary,
            next.tool_boundary,
        );
        boundary(
            "the boundary of a spawned session",
            self.agent_boundary,
            next.agent_boundary,
        );
        boundary("mail", self.high_risk.mail, next.high_risk.mail);
        boundary("push", self.high_risk.push, next.high_risk.push);
        boundary("publish", self.high_risk.publish, next.high_risk.publish);

        if next.autonomy > self.autonomy && next.autonomy == Autonomy::Act {
            raised.push("the companion acts on its own within the job file".to_owned());
        }

        for channel in &next.notification_channels {
            if channel.leaves_the_machine() && !self.notification_channels.contains(channel) {
                raised.push(format!("{channel:?} sends a message off this machine"));
            }
        }

        let had_pty = self.adapter_enabled(PTY_ADAPTER_ID, AdapterDefault::OptIn);
        let wants_pty = next.adapter_enabled(PTY_ADAPTER_ID, AdapterDefault::OptIn);
        if wants_pty && !had_pty {
            raised.push(
                "the generic terminal adapter starts a foreign CLI, and no permission level \
                 of this program restrains it"
                    .to_owned(),
            );
        }

        raised
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint_config::{EndpointProfile, RoleBinding};
    use crate::{EndpointProtocol, EndpointRole};

    #[test]
    fn the_defaults_are_the_careful_ones() {
        let settings = Settings::default();
        assert_eq!(
            settings.notification_channels,
            vec![NotificationChannel::Figure],
            "no channel that leaves the machine without being asked for"
        );
        assert!(settings.forward_done, "a finished run is worth saying");
        assert_eq!(settings.autonomy, Autonomy::Observe);
        assert_eq!(settings.tool_boundary, ToolBoundary::Ask);
        assert_eq!(settings.agent_boundary, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.mail, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.push, ToolBoundary::Ask);
        assert_eq!(settings.high_risk.publish, ToolBoundary::Ask);
        assert!(
            !settings.inventory_allowed,
            "reading somebody's work is asked for"
        );
        assert_eq!(settings.budget_limit_percent, 0);
        assert_eq!(settings.done_handling, DoneHandling::Forward);
        assert!(settings.validate().is_ok());
    }

    #[test]
    fn an_opt_in_adapter_stays_off_until_it_is_named() {
        let quiet = Settings::default();
        assert!(
            quiet.adapter_enabled("workbench", AdapterDefault::On),
            "an empty list means every ordinary adapter"
        );
        assert!(
            !quiet.adapter_enabled(PTY_ADAPTER_ID, AdapterDefault::OptIn),
            "an empty list must not hand anybody a terminal adapter"
        );

        let chosen = Settings {
            enabled_adapters: vec![PTY_ADAPTER_ID.to_owned()],
            ..Settings::default()
        };
        assert!(chosen.adapter_enabled(PTY_ADAPTER_ID, AdapterDefault::OptIn));
        assert!(
            !chosen.adapter_enabled("workbench", AdapterDefault::On),
            "a filled list is a choice, and the others are not in it"
        );
    }

    #[test]
    fn a_document_from_an_older_build_gets_the_defaults_for_what_it_does_not_name() {
        // The compat rule of DESIGN.md § Architektur on the settings document: a shell that
        // predates the assistant answers sends the fields it knows and nothing else.
        let older: Settings = serde_json::from_str(
            r#"{"schema_version": 1, "autonomy": "ask", "tool_boundary": "read_only"}"#,
        )
        .unwrap();
        assert_eq!(older.autonomy, Autonomy::Ask);
        assert_eq!(older.tool_boundary, ToolBoundary::ReadOnly);
        assert_eq!(
            older.agent_boundary,
            ToolBoundary::Ask,
            "the careful default"
        );
        assert_eq!(older.figure_name, DEFAULT_FIGURE_NAME);
        assert_eq!(older.skill_level, SkillLevel::Recommended);
    }

    #[test]
    fn the_wire_names_of_the_setup_answers_are_the_ones_the_shell_builds_against() {
        let settings = Settings {
            tool_boundary: ToolBoundary::ReadOnly,
            done_handling: DoneHandling::Reviewer,
            skill_level: SkillLevel::Many,
            conversation_style: ConversationStyle::Detailed,
            address_form: AddressForm::Formal,
            notification_channels: vec![
                NotificationChannel::Figure,
                NotificationChannel::SystemNotification,
            ],
            ..Settings::default()
        };
        let json = serde_json::to_value(&settings).unwrap();
        assert_eq!(json["tool_boundary"], "read_only");
        assert_eq!(json["done_handling"], "reviewer");
        assert_eq!(json["skill_level"], "many");
        assert_eq!(json["conversation_style"], "detailed");
        assert_eq!(json["address_form"], "formal");
        assert_eq!(json["notification_channels"][1], "system_notification");
    }

    #[test]
    fn a_budget_that_is_not_a_share_and_a_figure_without_a_name_are_refused() {
        let over = Settings {
            budget_limit_percent: 101,
            ..Settings::default()
        };
        assert_eq!(
            over.validate(),
            Err(InvalidSettings::BudgetOutOfRange { percent: 101 })
        );

        let nameless = Settings {
            figure_name: "   ".to_owned(),
            ..Settings::default()
        };
        assert_eq!(nameless.validate(), Err(InvalidSettings::NamelessFigure));

        let long = Settings {
            figure_name: "a".repeat(MAX_FIGURE_NAME_LEN + 1),
            ..Settings::default()
        };
        assert_eq!(
            long.validate(),
            Err(InvalidSettings::FigureNameTooLong {
                limit: MAX_FIGURE_NAME_LEN
            })
        );
    }

    #[test]
    fn a_key_in_the_endpoints_makes_the_whole_document_unusable() {
        let settings = Settings {
            endpoints: EndpointConfig::empty().with_profile(EndpointProfile {
                id: "cloud".to_owned(),
                protocol: EndpointProtocol::OpenaiCompat,
                url: "https://example.invalid".to_owned(),
                key_ref: Some("sk-0123456789".to_owned()),
                model: None,
                args: Vec::new(),
            }),
            ..Settings::default()
        };
        assert!(matches!(
            settings.validate(),
            Err(InvalidSettings::Endpoints(
                EndpointError::KeyInSettings { .. }
            ))
        ));
    }

    #[test]
    fn raising_a_permission_is_named_and_lowering_one_is_not() {
        let before = Settings::default();

        let mut after = before.clone();
        after.high_risk.publish = ToolBoundary::Full;
        after.tool_boundary = ToolBoundary::Full;
        after.autonomy = Autonomy::Act;
        after.notification_channels.push(NotificationChannel::Push);
        after.enabled_adapters.push(PTY_ADAPTER_ID.to_owned());
        let raised = before.high_risk_changes(&after);
        assert_eq!(raised.len(), 5, "each raise is named once: {raised:?}");

        let mut lowered = before.clone();
        lowered.tool_boundary = ToolBoundary::ReadOnly;
        lowered.autonomy = Autonomy::Observe;
        lowered.notification_channels = Vec::new();
        assert!(
            before.high_risk_changes(&lowered).is_empty(),
            "taking something away is nobody's risk"
        );

        // What is already on stays there without a fresh confirmation.
        assert!(after.high_risk_changes(&after).is_empty());
    }

    #[test]
    fn a_channel_that_stays_on_the_machine_needs_no_confirmation() {
        let before = Settings::default();
        let after = Settings {
            notification_channels: vec![
                NotificationChannel::Figure,
                NotificationChannel::Sound,
                NotificationChannel::Speech,
                NotificationChannel::SystemNotification,
            ],
            ..Settings::default()
        };
        assert!(before.high_risk_changes(&after).is_empty());
    }

    #[test]
    fn a_role_pointing_nowhere_is_refused_with_the_document() {
        let settings = Settings {
            endpoints: EndpointConfig::empty().with_role(
                EndpointRole::Stt,
                RoleBinding::new("a-profile-that-is-not-there"),
            ),
            ..Settings::default()
        };
        assert!(matches!(
            settings.validate(),
            Err(InvalidSettings::Endpoints(
                EndpointError::UnknownProfile { .. }
            ))
        ));
    }
}
