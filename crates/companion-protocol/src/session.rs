// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::ids::{AdapterId, AuftragId, MachineId, SessionId};
use crate::provenance::Provenance;

/// What a session is doing right now.
///
/// `DESIGN.md` § Session-Adapter wants unknown things shown as unknown rather than as
/// something plausible, and this field is where an adapter is most tempted to guess. An
/// adapter that only sees a live terminal knows the session exists, not what it is doing:
/// that is [`SessionState::Unknown`]. One whose session has simply vanished knows it is
/// over but not how it went: that is [`SessionState::Lost`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Busy,
    Idle,
    /// Waiting for input from the person, including an open question.
    Waiting,
    /// Finished its work. Only for an adapter that saw it finish.
    Done,
    Error,
    /// The session is there, but the adapter cannot tell what it is doing.
    Unknown,
    /// The session is gone and the adapter never learned how it ended. Over, but not
    /// finished: a crash and a clean end look the same from the outside.
    Lost,
}

impl SessionState {
    /// Whether the session is over, however it ended.
    pub fn is_final(self) -> bool {
        matches!(self, Self::Done | Self::Error | Self::Lost)
    }

    /// Whether the adapter knows what the session is doing.
    pub fn is_known(self) -> bool {
        !matches!(self, Self::Unknown)
    }
}

/// Where a task of the workbench stands, as its carrier reports it.
///
/// The states of `claude-workbench/docs/AGENTS-PLAN.md` § 2, "gleichlautend in Ansicht, Datei
/// und Companion", spelled as the wire names the carrier (`wb-traeger`) sends. A task is not a
/// session: the carrier reports one session per task with `auftrag_id` set, and this is what
/// that task is doing, which [`SessionState`] cannot say — "paused until the quota resets" is
/// neither waiting for the person nor idle, and "ready for acceptance" is not done.
///
/// Reading accepts every `wartet_auf_*` spelling as [`TaskState::WartetAufNutzer`]: carriers
/// from before the rename name the person they wait for in the wire value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskState {
    /// In the backlog, not started yet.
    Offen,
    /// The lead agent is alive and was seen at the last tick.
    Laeuft,
    /// A display without an automatic consequence: a deadline passed without progress, or the
    /// lead agent is gone and could not be revived.
    Steckt,
    /// Paused until the subscription quota resets.
    PausiertKontingent,
    /// Paused for the night window.
    PausiertNacht,
    /// Paused until a wake time the lead agent left behind.
    PausiertWeckzeit,
    /// A question, an approval or a conflict only the person can settle.
    WartetAufNutzer,
    /// Result checked, reviewer run, report written.
    ZurAbnahme,
    /// The lead agent holds the task for unsolvable as it stands.
    Aufgegeben,
    /// A local lead agent handed the task back because it is beyond the model.
    AufgegebenModell,
    /// Accepted by the person.
    Abgenommen,
    /// Discarded by the person.
    Verworfen,
}

impl<'de> Deserialize<'de> for TaskState {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        Self::from_wire(&name)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown task state `{name}`")))
    }
}

impl TaskState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Offen => "offen",
            Self::Laeuft => "laeuft",
            Self::Steckt => "steckt",
            Self::PausiertKontingent => "pausiert_kontingent",
            Self::PausiertNacht => "pausiert_nacht",
            Self::PausiertWeckzeit => "pausiert_weckzeit",
            Self::WartetAufNutzer => "wartet_auf_nutzer",
            Self::ZurAbnahme => "zur_abnahme",
            Self::Aufgegeben => "aufgegeben",
            Self::AufgegebenModell => "aufgegeben_modell",
            Self::Abgenommen => "abgenommen",
            Self::Verworfen => "verworfen",
        }
    }

    /// Every state, for a test that has to cover all of them.
    pub const ALL: [TaskState; 12] = [
        Self::Offen,
        Self::Laeuft,
        Self::Steckt,
        Self::PausiertKontingent,
        Self::PausiertNacht,
        Self::PausiertWeckzeit,
        Self::WartetAufNutzer,
        Self::ZurAbnahme,
        Self::Aufgegeben,
        Self::AufgegebenModell,
        Self::Abgenommen,
        Self::Verworfen,
    ];

    /// The state a wire name stands for, including the older `wartet_auf_*` spellings.
    pub fn from_wire(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|state| state.as_str() == name)
            .or_else(|| {
                name.starts_with("wartet_auf_")
                    .then_some(Self::WartetAufNutzer)
            })
    }

    /// One of the three pauses. "Pausieren löst nie eine Ansprache durch den Companion aus"
    /// (`AGENTS-PLAN.md` § 2).
    pub fn is_paused(self) -> bool {
        matches!(
            self,
            Self::PausiertKontingent | Self::PausiertNacht | Self::PausiertWeckzeit
        )
    }

    /// Whether the task cannot go on without the person: it asks something, it waits for the
    /// acceptance, or its lead agent gave it up. The only states the companion may address on
    /// its own, and only with `proactive.task_events` switched on.
    ///
    /// `steckt` is not among them on purpose: the plan calls it "eine Anzeige ohne
    /// automatische Folge", and the pauses never are.
    pub fn needs_person(self) -> bool {
        matches!(
            self,
            Self::WartetAufNutzer | Self::ZurAbnahme | Self::Aufgegeben | Self::AufgegebenModell
        )
    }

    /// The session state this task state stands for, whatever the carrier put into `state`.
    ///
    /// The daemon files a task's session under this, so every reader of [`SessionState`] sees
    /// the task the same way: a pause is `idle` and never `waiting` — nobody is being waited
    /// for — and a task ready for acceptance is `idle` and never `done`, because `done` is what
    /// starts the finished-report stages (`DoneHandling`), and the workbench checks its own
    /// tasks (`AGENTS-PLAN.md` § 4, "Vergeben und prüfen"). Only the person's own verdict,
    /// accepted or discarded, ends a task.
    pub fn session_state(self) -> SessionState {
        match self {
            Self::Laeuft | Self::Steckt => SessionState::Busy,
            Self::WartetAufNutzer => SessionState::Waiting,
            Self::Abgenommen | Self::Verworfen => SessionState::Done,
            Self::Offen
            | Self::PausiertKontingent
            | Self::PausiertNacht
            | Self::PausiertWeckzeit
            | Self::ZurAbnahme
            | Self::Aufgegeben
            | Self::AufgegebenModell => SessionState::Idle,
        }
    }
}

/// How much of the model context window a session has used up.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct ContextUsage {
    /// Share of the window in use, between 0.0 and 1.0.
    pub used_fraction: f64,
    /// Tokens in the window, if the adapter knows the absolute number.
    pub used_tokens: Option<u64>,
}

/// How much of a subscription or spending budget a session has used up.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct BudgetUsage {
    /// Share of the current window in use, between 0.0 and 1.0.
    pub used_fraction: f64,
    /// Unix time in milliseconds at which the window resets, when known.
    pub resets_at_ms: Option<u64>,
}

/// What kind of agent a session is.
///
/// `DESIGN.md` § Mobil, Sessionansicht: the session list of the phone shows orchestrators
/// and hides workers, because supervising workers is the orchestrator's job and not the
/// companion's. An adapter that cannot tell the two apart says so by leaving the field
/// [`Provenance::Unknown`] — there is no third variant here, because "unknown" is what the
/// origin of every status field already means, and two ways of saying it would let a
/// filter answer differently depending on which one an adapter picked. A list that hides
/// workers therefore hides exactly `Measured(Worker)` and `Estimated(Worker)`, and shows
/// everything else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SessionKind {
    /// Drives other sessions and answers to the person.
    Orchestrator,
    /// Was started by an orchestrator and reports back to it.
    Worker,
}

/// Which machine a session runs on, in a form that survives a rename.
///
/// **The collision rule for session ids.** A [`SessionId`] is unique on the machine that
/// issued it and nowhere else: two machines both running the workbench in
/// `~/AI/companion` produce the very same id for two different sessions. A client that
/// speaks to more than one daemon — the phone in the aggregation mode of `DESIGN.md`
/// § Mobil — therefore keys every session by the pair (`machine.id`, `id`) and never by
/// the id alone. Where the machine identity is unknown, the pair cannot be formed, and the
/// client falls back to the connection it received the session on, which is unique within
/// one client run. The daemon never rewrites an id to make it globally unique: the id is
/// what a person sees and what every command names, and a prefix that changed per client
/// would break both.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct MachineIdentity {
    /// Stable and opaque. Generated once per machine and kept, so a renamed machine is
    /// still recognised as the same one.
    pub id: MachineId,
    /// What to call the machine in a list. Free text a person may change at any time, and
    /// never the thing two sessions are told apart by.
    pub display_name: Option<String>,
}

impl MachineIdentity {
    pub fn new(id: MachineId, display_name: Option<String>) -> Self {
        Self { id, display_name }
    }

    /// The display name where there is one, the id otherwise.
    pub fn label(&self) -> &str {
        self.display_name
            .as_deref()
            .filter(|name| !name.trim().is_empty())
            .unwrap_or_else(|| self.id.as_str())
    }
}

/// The status of one session.
///
/// `DESIGN.md` § Datenmodelle lists this as: id, adapter, maschine, projekt, modell,
/// zustand, laufzeit, kontext, budget, iteration, letzte_ausgabe, offene_frage,
/// auftrag_id. Every field an adapter may not know carries its origin instead of a
/// silently plausible zero.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SessionStatus {
    pub id: SessionId,
    pub adapter: AdapterId,
    /// Machine the session runs on, as the adapter reports it. `local` for this one.
    ///
    /// Carries its origin since 2026-09-03. It used to be a bare `String` that defaulted to
    /// `"local"`, and the workbench adapter filled that same `"local"` in whenever it could
    /// not find out — a guess in the shape of a measurement, in the one field that decides
    /// whether a session runs on this Mac or on the other machine. An adapter that does not
    /// know now says so, and only one that does writes a value.
    #[serde(default, skip_serializing_if = "Provenance::is_unknown")]
    pub machine: Provenance<String>,
    /// Absolute path of the project directory the session works in.
    pub project: Option<String>,
    /// Where the session writes its conversation, when whoever reports it knows.
    ///
    /// Added 2026-09-03. Claude Code hands its hooks the `transcript_path` it writes itself,
    /// which is the one authoritative answer to a question every reader of such a session
    /// otherwise has to derive from a directory-naming rule that belongs to another program.
    /// A reporter that does not know leaves it out, and the field is absent from the wire —
    /// so a peer that predates it sends and reads exactly the bytes it always did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    pub model: Provenance<String>,
    pub state: SessionState,
    /// Unix time in milliseconds of the last sign of life the adapter saw from this session:
    /// the last line of its stream, the last write to its state file, the last change to its
    /// transcript.
    ///
    /// Added 2026-09-03 for `done_limit`. A listing carries at most that many finished
    /// sessions, and until now the daemon cut the tail off in the order the adapters happened
    /// to hand it over — so a machine with weeks of history could answer with twenty sessions
    /// that all ended in June while the one that ended a minute ago fell off the end. With
    /// this field the daemon keeps the newest ones. An adapter that cannot say leaves it out,
    /// and the field is absent from the wire, so a peer that predates it sends and reads
    /// exactly the bytes it always did.
    ///
    /// Not a [`Provenance`]: it is either a timestamp somebody read off the machine or it is
    /// nothing. There is no estimate of it worth ordering a list by.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_ms: Option<u64>,
    /// Milliseconds since the session started.
    pub runtime_ms: Provenance<u64>,
    pub context: Provenance<ContextUsage>,
    pub budget: Provenance<BudgetUsage>,
    pub iteration: Provenance<u32>,
    /// Last output of the session, trimmed to what the shell shows without asking.
    pub last_output: Option<String>,
    /// The question the session is currently blocked on, if any.
    pub open_question: Option<String>,
    /// A tool call this session asked permission for and was refused automatically, by
    /// policy — not a question `open_question` would have a person still answer, since the
    /// agent was already told no before this was ever recorded.
    ///
    /// Written out only when an adapter has one to report. A status that leaves it out is
    /// read back as `None`, which is what keeps a daemon and a shell of different ages
    /// speaking the same wire bytes: nothing an older peer sends changes meaning, and nothing
    /// this build sends about a session it knows nothing more about grows a field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_refused: Option<String>,
    pub auftrag_id: Option<AuftragId>,
    /// Orchestrator or worker, for the list that shows only the first kind.
    ///
    /// Written out only when an adapter knows it. A status that leaves it out is read back
    /// as [`Provenance::Unknown`], which is what keeps a daemon and a shell of different
    /// ages speaking the same wire bytes: nothing an older peer sends changes meaning, and
    /// nothing this build sends about a session it knows nothing more about grows a field.
    #[serde(default, skip_serializing_if = "Provenance::is_unknown")]
    pub kind: Provenance<SessionKind>,
    /// What to call this session in a list, when the adapter has a name for it. The
    /// workbench names its sessions and its workers; a bare terminal has nothing but an id.
    #[serde(default, skip_serializing_if = "Provenance::is_unknown")]
    pub display_name: Provenance<String>,
    /// The machine this session runs on, stable across renames. See [`MachineIdentity`]
    /// for the collision rule that makes this field load-bearing.
    ///
    /// [`Self::machine`] stays what it was: the free-text name of the machine as the
    /// adapter reports it, `local` for this one. The two are kept apart because the old
    /// field is what a person reads and the new one is what a client keys on.
    #[serde(default, skip_serializing_if = "Provenance::is_unknown")]
    pub machine_identity: Provenance<MachineIdentity>,
    /// Where the workbench task this session carries stands. Set only by the workbench's
    /// carrier, which reports one session per task with `auftrag_id` set; every other reporter
    /// leaves the five `task_*` fields out, and a status without them is written and read
    /// exactly as before (added 2026-09-10, `AGENTS-PLAN.md` § 9 step 3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_state: Option<TaskState>,
    /// Why the task stands where it does, in the carrier's own words: what it waits for, why
    /// it is stuck, why an open task was not started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_reason: Option<String>,
    /// The goal of the task, its first sentence. What the person calls the task.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_title: Option<String>,
    /// When a paused task goes on, as an RFC 3339 timestamp.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_wake_at: Option<String>,
    /// The machine the task's lead agent runs on right now. Apart from [`Self::machine`]
    /// because the carrier that reports may run on another machine than the agent it carries.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_machine: Option<String>,
}

impl SessionStatus {
    /// A status with everything unknown that the adapter has not filled in yet.
    pub fn new(id: SessionId, adapter: AdapterId, state: SessionState) -> Self {
        Self {
            id,
            adapter,
            machine: Provenance::Unknown,
            project: None,
            transcript_path: None,
            model: Provenance::Unknown,
            state,
            last_activity_ms: None,
            runtime_ms: Provenance::Unknown,
            context: Provenance::Unknown,
            budget: Provenance::Unknown,
            iteration: Provenance::Unknown,
            last_output: None,
            open_question: None,
            permission_refused: None,
            auftrag_id: None,
            kind: Provenance::Unknown,
            display_name: Provenance::Unknown,
            machine_identity: Provenance::Unknown,
            task_state: None,
            task_reason: None,
            task_title: None,
            task_wake_at: None,
            task_machine: None,
        }
    }

    /// Whether this session carries a workbench task: the carrier reported a task state for
    /// it. Such a session speaks through the task's events and not through its own.
    pub fn is_task(&self) -> bool {
        self.task_state.is_some()
    }

    /// Whether a session list that shows orchestrators may show this one.
    ///
    /// `DESIGN.md` § Mobil, Sessionansicht: the list shows orchestrators and unknowns and
    /// hides workers. A session an adapter never classified stays visible on purpose — a
    /// filter that hid what it does not know would hide half a machine the day an adapter
    /// stops filling the field.
    pub fn is_supervisable(&self) -> bool {
        self.kind.value() != Some(&SessionKind::Worker)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status() -> SessionStatus {
        SessionStatus::new(
            SessionId::new("session"),
            AdapterId::new("adapter"),
            SessionState::Idle,
        )
    }

    #[test]
    fn a_status_without_the_new_fields_serialises_exactly_as_before() {
        // The wire bytes of a daemon that knows nothing more about a session have to stay
        // what they were, or every fixture and every older peer would see a changed
        // message for an unchanged session.
        let json = serde_json::to_value(status()).unwrap();
        let object = json.as_object().unwrap();
        assert!(!object.contains_key("kind"));
        assert!(!object.contains_key("display_name"));
        assert!(!object.contains_key("machine_identity"));
        assert!(
            !object.contains_key("machine"),
            "an adapter that does not know which machine a session runs on writes no key, \
             rather than the word local"
        );
        assert!(!object.contains_key("permission_refused"));
        assert!(!object.contains_key("last_activity_ms"));
        for key in [
            "task_state",
            "task_reason",
            "task_title",
            "task_wake_at",
            "task_machine",
        ] {
            assert!(
                !object.contains_key(key),
                "{key} is written only for a task"
            );
        }
    }

    #[test]
    fn a_task_status_as_the_carrier_sends_it_parses() {
        // The shape agreed with the workbench's carrier (`wb-traeger`): the five fields sit
        // flat on the status, the state in the plan's snake_case spelling.
        let text = r#"{
            "id": "aufgabe-a1", "adapter": "wb-traeger", "project": "/tmp/projekt",
            "model": {"origin": "unknown"}, "state": "busy",
            "runtime_ms": {"origin": "unknown"}, "context": {"origin": "unknown"},
            "budget": {"origin": "unknown"}, "iteration": {"origin": "unknown"},
            "last_output": null, "open_question": null, "auftrag_id": "a1",
            "task_state": "pausiert_kontingent", "task_reason": "Kontingent erschöpft",
            "task_title": "Den Zähler bauen.", "task_wake_at": "2026-09-10T16:20:00+02:00",
            "task_machine": "peer"
        }"#;
        let status: SessionStatus = serde_json::from_str(text).unwrap();
        assert_eq!(status.task_state, Some(TaskState::PausiertKontingent));
        assert_eq!(status.task_title.as_deref(), Some("Den Zähler bauen."));
        assert_eq!(status.task_machine.as_deref(), Some("peer"));
        assert!(status.is_task());
        let back: SessionStatus =
            serde_json::from_str(&serde_json::to_string(&status).unwrap()).unwrap();
        assert_eq!(back, status);
    }

    #[test]
    fn every_task_state_keeps_the_name_the_plan_gives_it() {
        for state in TaskState::ALL {
            assert_eq!(
                serde_json::to_value(state).unwrap(),
                serde_json::Value::String(state.as_str().to_owned())
            );
        }
    }

    #[test]
    fn an_older_waiting_spelling_still_reads_as_waiting_for_the_person() {
        let older = format!("\"wartet_auf_{}\"", "jemand");
        let state: TaskState = serde_json::from_str(&older).unwrap();
        assert_eq!(state, TaskState::WartetAufNutzer);
        assert_eq!(serde_json::to_value(state).unwrap(), "wartet_auf_nutzer");
        assert!(serde_json::from_str::<TaskState>("\"gibt_es_nicht\"").is_err());
    }

    #[test]
    fn a_pause_is_never_waiting_and_acceptance_is_never_done() {
        for state in TaskState::ALL {
            if state.is_paused() {
                assert_eq!(state.session_state(), SessionState::Idle, "{state:?}");
                assert!(!state.needs_person(), "a pause never addresses the person");
            }
        }
        assert_eq!(TaskState::ZurAbnahme.session_state(), SessionState::Idle);
        assert!(TaskState::ZurAbnahme.needs_person());
        assert!(!TaskState::Steckt.needs_person());
        assert!(TaskState::Abgenommen.session_state().is_final());
        assert!(TaskState::Verworfen.session_state().is_final());
    }

    #[test]
    fn a_status_from_an_older_peer_parses_with_the_new_fields_unknown() {
        let text = serde_json::to_string(&status()).unwrap();
        let parsed: SessionStatus = serde_json::from_str(&text).unwrap();
        assert!(parsed.machine.is_unknown());
        assert!(parsed.kind.is_unknown());
        assert!(parsed.display_name.is_unknown());
        assert!(parsed.machine_identity.is_unknown());
        assert_eq!(parsed.permission_refused, None);
        assert_eq!(parsed.last_activity_ms, None);
    }

    #[test]
    fn the_new_fields_survive_a_round_trip() {
        let mut before = status();
        before.machine = Provenance::Measured("peer".to_owned());
        before.kind = Provenance::Measured(SessionKind::Worker);
        before.display_name = Provenance::Measured("mobilkern".to_owned());
        before.machine_identity = Provenance::Measured(MachineIdentity::new(
            MachineId::new("m-1"),
            Some("MacBook".to_owned()),
        ));
        before.permission_refused = Some("run `rm -rf build`".to_owned());
        before.last_activity_ms = Some(1_770_000_090_000);
        let after: SessionStatus =
            serde_json::from_str(&serde_json::to_string(&before).unwrap()).unwrap();
        assert_eq!(before, after);
    }

    #[test]
    fn only_a_known_worker_is_hidden_from_the_session_list() {
        let mut status = status();
        assert!(status.is_supervisable(), "an unknown kind stays visible");
        status.kind = Provenance::Measured(SessionKind::Orchestrator);
        assert!(status.is_supervisable());
        status.kind = Provenance::Measured(SessionKind::Worker);
        assert!(!status.is_supervisable());
        status.kind = Provenance::Estimated(SessionKind::Worker);
        assert!(
            !status.is_supervisable(),
            "a guess still counts as a worker"
        );
    }

    #[test]
    fn a_machine_falls_back_to_its_id_when_it_has_no_name() {
        let named = MachineIdentity::new(MachineId::new("m-1"), Some("MacBook".to_owned()));
        assert_eq!(named.label(), "MacBook");
        let blank = MachineIdentity::new(MachineId::new("m-1"), Some("  ".to_owned()));
        assert_eq!(blank.label(), "m-1");
        let none = MachineIdentity::new(MachineId::new("m-1"), None);
        assert_eq!(none.label(), "m-1");
    }
}
