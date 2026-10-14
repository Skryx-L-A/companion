// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What the companion reads out of a workbench world, and how it speaks about it.
//!
//! `claude-workbench/docs/AGENTS-PLAN.md` § 7: the companion is the way "braucht dich" reaches
//! the person — the question of a world's lead agent, the message an agent marked for them —
//! it gives the morning overview of what finished and what waits, and it writes into a world
//! as a player. The worlds themselves are the workbench's: one data library writes them, and
//! its two reading commands (`wb-welt finden --json`, `wb-welt ansicht <welt> --json`) are the
//! only way in. This module holds what those two print, as far as the companion reads it, and
//! every sentence the companion makes of it, so the notice at the figure, the morning overview
//! and the list the model reads say the same thing the same way.
//!
//! Nothing here starts a process. The daemon runs the commands and hands their output in.
//!
//! **Tolerant on purpose.** Every field the companion does not need is left out, and every field
//! it does need defaults when it is missing: the view is the workbench's, it grows, and a world
//! whose view gained a field must not vanish from the companion for it. A world whose view does
//! not parse at all is kept with the error, so the person hears that it could not be read rather
//! than nothing.

use std::collections::HashMap;

use chrono::{DateTime, Local, TimeZone};
use serde::Deserialize;

/// The stage a world's lead agent has in its profile.
pub const LEAD_STAGE: &str = "hauptagent";

/// The id of the one human of a world. The workbench's data library fixes it
/// (`HUMAN_ACTORS`, `WORLD_HUMAN`).
pub const WORLD_HUMAN: &str = "mensch";

/// The id the companion writes under. One of the workbench's `HUMAN_ACTORS`, so a world takes
/// it as an external actor: it counts like the person, and it is stored `verified: false`
/// like every CLI sender, because it is one.
pub const COMPANION_SENDER: &str = "companion";

/// How much of a question or a message one line of the overview or of the model's list
/// carries. The whole text is in the world; this is what fits in a sentence somebody hears.
const LINE_TEXT_CHARS: usize = 240;

/// The shortest a notice at the figure is allowed to get before it names only the world.
const NOTICE_TEXT_CHARS: usize = 160;

/// Whether a model name is one no agent may run on. `AGENTS-PLAN.md` § 8.1: "Fable nie. Kein
/// Agent läuft auf Fable, auch nicht als Fallback, auch nicht auf Antrag." The workbench's
/// library refuses it the same way, by the name containing `fable` in any case.
pub fn model_is_forbidden(model: &str) -> bool {
    model.to_lowercase().contains("fable")
}

// MARK: - What the commands print

/// One world as `wb-welt finden --json` lists it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct FoundWorld {
    /// The world's store on the machine it was found on. What every other command takes.
    pub path: String,
    /// `global` or `project`.
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub state: Option<String>,
    /// Set when the world was found but its `world.json` could not be read.
    #[serde(default)]
    pub error: Option<String>,
}

/// `wb-welt ansicht <welt> --json`, the parts the companion reads.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct WorldView {
    /// False when a writer held the world's lock too long and the view was read without it.
    #[serde(default = "yes")]
    pub consistent: bool,
    #[serde(default)]
    pub world: WorldInfo,
    #[serde(default)]
    pub agents: Vec<AgentView>,
    #[serde(default)]
    pub tickets: Vec<TicketView>,
    #[serde(default)]
    pub questions: Vec<QuestionView>,
    #[serde(default)]
    pub humans: HashMap<String, HumanView>,
    /// Parts of the world the view could not read, each as the library described it.
    #[serde(default)]
    pub errors: Vec<serde_json::Value>,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct WorldInfo {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub pause: Option<Switch>,
    #[serde(default)]
    pub stop: Option<Switch>,
}

/// The pause or the stop of a world: its state and the reason somebody gave.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Switch {
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct AgentView {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub stage: String,
    /// `aktiv`, `pausiert` or `gestoppt`.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub machine: Option<String>,
    #[serde(default)]
    pub specialty: Option<String>,
    #[serde(default)]
    pub runtime: Option<Switch>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct TicketView {
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// offen, läuft, wartet, braucht dich, zur Abnahme, abgenommen, zurückgegeben, verworfen,
    /// unterbrochen — the plan's words, as the library writes them.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub assignee: Option<String>,
    #[serde(default)]
    pub recipients: Vec<String>,
    #[serde(default)]
    pub sender: String,
    #[serde(default)]
    pub updated_at: Option<String>,
    #[serde(default)]
    pub approval: Option<Approval>,
}

/// Who accepted or returned a ticket, and when.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Approval {
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub time: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct QuestionView {
    pub id: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default)]
    pub recommendation: Option<String>,
    #[serde(default)]
    pub sender: String,
    /// `offen`, `beantwortet` or `zurückgenommen`.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub ticket: Option<String>,
    #[serde(default)]
    pub created_at: Option<String>,
    /// `agent-antrag` for a team lead's application to the lead agent. Not a question to the
    /// person (`docs/AGENTS-OBERFLAECHE.md`, "Katalog": "zählen nicht als Frage an den
    /// Menschen").
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct HumanView {
    #[serde(default)]
    pub postbox: Postbox,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Postbox {
    #[serde(default)]
    pub deliveries: Vec<Delivery>,
}

/// One message in the person's postbox.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Delivery {
    /// What `wb-kanal quittieren --zustellung` takes.
    #[serde(default)]
    pub delivery_id: String,
    #[serde(default)]
    pub kind: String,
    /// `frage` or `ergebnis` for a message that counts as "braucht dich" until acknowledged.
    #[serde(default)]
    pub mark: Option<String>,
    #[serde(default)]
    pub sender: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub ticket: Option<String>,
    #[serde(default)]
    pub time: Option<String>,
    #[serde(default)]
    pub acknowledged: bool,
}

/// `agents_traeger.py status`, the part that says who sleeps and why.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct CarrierStatus {
    /// Per agent id, why and until when it sleeps.
    #[serde(default)]
    pub schlaf: HashMap<String, Sleep>,
    /// Whether the carrier has a login to start a turn with. Without one every agent with work
    /// sleeps for "Anmeldung", which the carrier checks before each claim.
    #[serde(default)]
    pub anmeldung: Option<Login>,
}

/// The login a carrier starts its turns with. Never a value, only whether there is one.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Login {
    #[serde(default)]
    pub available: bool,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct Sleep {
    /// `kontingent` or `anmeldung`, or whatever the carrier calls it next.
    #[serde(default)]
    pub grund: String,
    /// Unix time in seconds.
    #[serde(default)]
    pub bis: Option<f64>,
}

// MARK: - One world as the daemon last read it

/// One world, where it was found, and what its view said at the last reading.
#[derive(Debug, Clone, PartialEq)]
pub struct WorldState {
    /// The machine the world lives on, as the settings name it (`lokal`, `peer`).
    pub machine: String,
    pub found: FoundWorld,
    /// `Ok` with the view, or `Err` with why it could not be read.
    pub view: Result<WorldView, String>,
}

impl WorldState {
    /// The world's id, from the view if it was read and from the finding otherwise, and its
    /// path where neither has one.
    pub fn id(&self) -> String {
        match &self.view {
            Ok(view) if !view.world.id.is_empty() => view.world.id.clone(),
            _ => self
                .found
                .id
                .clone()
                .unwrap_or_else(|| self.found.path.clone()),
        }
    }

    /// What the person calls the world.
    pub fn name(&self) -> String {
        match &self.view {
            Ok(view) if !view.world.name.trim().is_empty() => view.world.name.trim().to_owned(),
            _ => self
                .found
                .name
                .clone()
                .filter(|name| !name.trim().is_empty())
                .unwrap_or_else(|| self.found.path.clone()),
        }
    }

    /// The world's lead agent, where the view names one.
    pub fn lead(&self) -> Option<&AgentView> {
        self.view
            .as_ref()
            .ok()?
            .agents
            .iter()
            .find(|agent| agent.stage == LEAD_STAGE)
    }

    /// Whether `reference` — an id, a name or a path, as the person or the model wrote it —
    /// names this world.
    pub fn is_named(&self, reference: &str) -> bool {
        let reference = reference.trim();
        !reference.is_empty()
            && (reference == self.id()
                || reference == self.found.path
                || reference.eq_ignore_ascii_case(&self.name())
                || self
                    .found
                    .project
                    .as_deref()
                    .is_some_and(|project| project == reference))
    }
}

// MARK: - "Braucht dich"

/// Why a world needs the person.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NeedKind {
    /// An open question of the lead agent (`wb-welt frage`).
    Question,
    /// A message an agent marked as a question for the person (`--markierung frage`).
    MarkedQuestion,
    /// A message an agent marked as a result for the person (`--markierung ergebnis`).
    MarkedResult,
    /// A ticket standing on "braucht dich" with no open question of its own.
    Ticket,
}

/// One thing a world needs from the person.
#[derive(Debug, Clone, PartialEq)]
pub struct NeedItem {
    /// Stable across readings: the same question is the same key an hour later, which is what
    /// keeps the companion from announcing it twice.
    pub key: String,
    pub kind: NeedKind,
    pub machine: String,
    pub world_id: String,
    pub world_name: String,
    pub world_path: String,
    /// The agent it comes from.
    pub from: String,
    pub text: String,
    pub options: Vec<String>,
    pub recommendation: Option<String>,
    pub ticket: Option<String>,
    /// The question to answer with `wb-welt antwort`, for [`NeedKind::Question`].
    pub question_id: Option<String>,
    /// The delivery to acknowledge with `wb-kanal quittieren`, for a marked message.
    pub delivery_id: Option<String>,
    pub at_ms: Option<u64>,
}

impl NeedItem {
    /// Whether the person acknowledging it — hearing it, reading it — is what settles it. A
    /// question is settled only by an answer or a withdrawal (`AGENTS-PLAN.md` § 13, "Fragen").
    pub fn settles_by_acknowledging(&self) -> bool {
        self.delivery_id.is_some()
    }

    /// Whether the notice at the figure carries this item's whole text, not a shortened one.
    ///
    /// A marked message is acknowledged from its notice only where the notice held all of it:
    /// a banner that showed the first 160 characters of a long result is not the result read
    /// (review of 2026-09-14, M-2). A longer one is acknowledged in the conversation, after the
    /// companion read it out in full.
    pub fn notice_is_whole(&self) -> bool {
        one_line(&self.text).chars().count() <= NOTICE_TEXT_CHARS
    }

    /// Whether a shell may acknowledge this item from its notice: a marked message whose notice
    /// carries its whole text.
    pub fn acknowledged_from_notice(&self) -> bool {
        self.settles_by_acknowledging() && self.notice_is_whole()
    }
}

/// Everything one world needs from the person, oldest first.
pub fn needs(world: &WorldState) -> Vec<NeedItem> {
    let Ok(view) = &world.view else {
        return Vec::new();
    };
    let id = world.id();
    let name = world.name();
    let base = |kind: NeedKind, local: String| NeedItem {
        key: format!("{}|{}|{local}", world.machine, id),
        kind,
        machine: world.machine.clone(),
        world_id: id.clone(),
        world_name: name.clone(),
        world_path: world.found.path.clone(),
        from: String::new(),
        text: String::new(),
        options: Vec::new(),
        recommendation: None,
        ticket: None,
        question_id: None,
        delivery_id: None,
        at_ms: None,
    };

    let mut items = Vec::new();
    let open_questions: Vec<&QuestionView> = view
        .questions
        .iter()
        .filter(|question| question.state == "offen")
        .filter(|question| question.kind.as_deref() != Some("agent-antrag"))
        .collect();
    for question in &open_questions {
        items.push(NeedItem {
            from: question.sender.clone(),
            text: question.text.clone(),
            options: question.options.clone(),
            recommendation: question.recommendation.clone(),
            ticket: question.ticket.clone(),
            question_id: Some(question.id.clone()),
            at_ms: question.created_at.as_deref().and_then(parse_time_ms),
            ..base(NeedKind::Question, format!("frage|{}", question.id))
        });
    }

    if let Some(human) = view.humans.get(WORLD_HUMAN) {
        for delivery in &human.postbox.deliveries {
            if delivery.acknowledged || delivery.delivery_id.is_empty() {
                continue;
            }
            let kind = match delivery.mark.as_deref() {
                Some("frage") => NeedKind::MarkedQuestion,
                Some("ergebnis") => NeedKind::MarkedResult,
                // An unmarked message does not count and is never acknowledged
                // (`AGENTS-OBERFLAECHE.md`, "Unmarkierte Nachrichten an den Menschen").
                _ => continue,
            };
            items.push(NeedItem {
                from: delivery.sender.clone(),
                text: delivery.text.clone(),
                ticket: delivery.ticket.clone(),
                delivery_id: Some(delivery.delivery_id.clone()),
                at_ms: delivery.time.as_deref().and_then(parse_time_ms),
                ..base(kind, format!("zustellung|{}", delivery.delivery_id))
            });
        }
    }

    for ticket in &view.tickets {
        if ticket.state != "braucht dich" {
            continue;
        }
        // The lead agent's question sets its ticket to "braucht dich" (`AGENTS-PLAN.md` § 4);
        // the question already says what it needs, and the ticket a second time is noise.
        if open_questions
            .iter()
            .any(|question| question.ticket.as_deref() == Some(ticket.id.as_str()))
        {
            continue;
        }
        items.push(NeedItem {
            from: ticket
                .assignee
                .clone()
                .unwrap_or_else(|| ticket.sender.clone()),
            text: ticket.title.clone(),
            ticket: Some(ticket.id.clone()),
            at_ms: ticket.updated_at.as_deref().and_then(parse_time_ms),
            ..base(NeedKind::Ticket, format!("ticket|{}", ticket.id))
        });
    }

    items.sort_by_key(|item| item.at_ms.unwrap_or(u64::MAX));
    items
}

/// The sentence at the figure and in the notice log for one item.
pub fn notice_line(item: &NeedItem) -> String {
    let world = &item.world_name;
    let text = shorten(&one_line(&item.text), NOTICE_TEXT_CHARS);
    let sentence = match item.kind {
        NeedKind::Question => {
            let mut sentence = format!("»{world}«: {} fragt: {text}", item.from);
            if let Some(recommendation) = &item.recommendation {
                let recommendation = shorten(&one_line(recommendation), 80);
                sentence = format!("{} Empfehlung: {recommendation}", with_stop(&sentence));
            }
            sentence
        }
        NeedKind::MarkedQuestion => format!("»{world}«: Frage von {} an dich: {text}", item.from),
        NeedKind::MarkedResult => format!("»{world}«: Ergebnis von {} für dich: {text}", item.from),
        NeedKind::Ticket => format!("»{world}«: Das Ticket »{text}« braucht dich"),
    };
    with_stop(&sentence)
}

// MARK: - Die Morgen-Übersicht

/// The lines the morning overview takes from the worlds, in the shape of the other lines of its
/// facts (`Schlüssel: Wert.`, details under a line with `- `).
///
/// `since_ms` is when the last overview was given: what was accepted or handed to the person
/// after it is "fertig". `None`, the first overview there ever was, counts the last day.
/// `carriers` holds `agents_traeger.py status` per world id where it could be read, and the
/// reason where not; a world missing from it has no carrier asked.
pub fn overview_lines(
    worlds: &[WorldState],
    since_ms: Option<u64>,
    carriers: &HashMap<String, Result<CarrierStatus, String>>,
    now_ms: u64,
) -> Vec<String> {
    if worlds.is_empty() {
        return vec!["Welten: keine gefunden.".to_owned()];
    }
    let since = since_ms.unwrap_or_else(|| now_ms.saturating_sub(24 * 60 * 60 * 1000));
    let mut lines = vec![format!(
        "Welten: {} ({}).",
        worlds.len(),
        worlds
            .iter()
            .map(WorldState::name)
            .collect::<Vec<_>>()
            .join(", ")
    )];

    for world in worlds {
        let header = match world.lead() {
            Some(lead) => format!("Welt »{}«, Hauptagent {}", world.name(), lead.id),
            None => format!("Welt »{}«", world.name()),
        };
        let view = match &world.view {
            Ok(view) => view,
            Err(reason) => {
                lines.push(format!(
                    "{header}: nicht lesbar ({}).",
                    shorten(&one_line(reason), 120)
                ));
                continue;
            }
        };
        let mut details = Vec::new();

        // Fertig: accepted tickets and results handed to the person since the last overview.
        let accepted: Vec<String> = view
            .tickets
            .iter()
            .filter(|ticket| ticket.state == "abgenommen")
            .filter(|ticket| {
                ticket
                    .approval
                    .as_ref()
                    .and_then(|approval| approval.time.as_deref())
                    .and_then(parse_time_ms)
                    .is_some_and(|at| at >= since)
            })
            .map(|ticket| format!("»{}«", one_line(&ticket.title)))
            .collect();
        if !accepted.is_empty() {
            details.push(format!(
                "- Abgenommen seit dem letzten Überblick: {}.",
                accepted.join(", ")
            ));
        }
        if let Some(human) = view.humans.get(WORLD_HUMAN) {
            for delivery in &human.postbox.deliveries {
                if delivery.mark.as_deref() != Some("ergebnis") {
                    continue;
                }
                if !delivery
                    .time
                    .as_deref()
                    .and_then(parse_time_ms)
                    .is_some_and(|at| at >= since)
                {
                    continue;
                }
                details.push(format!(
                    "- Ergebnis an dich von {}: {}",
                    delivery.sender,
                    with_stop(&shorten(&one_line(&delivery.text), LINE_TEXT_CHARS))
                ));
            }
        }

        // Wartet: what needs the person, and what waits for acceptance.
        for item in needs(world) {
            let text = with_stop(&shorten(&one_line(&item.text), LINE_TEXT_CHARS));
            details.push(match item.kind {
                NeedKind::Question => format!("- Wartet auf dich: Frage von {}: {text}", item.from),
                NeedKind::MarkedQuestion => {
                    format!("- Wartet auf dich: Frage von {} im Chat: {text}", item.from)
                }
                NeedKind::MarkedResult => {
                    format!(
                        "- Wartet auf dich: Ergebnis von {} zum Lesen: {text}",
                        item.from
                    )
                }
                NeedKind::Ticket => format!("- Wartet auf dich: Ticket {text}"),
            });
        }
        let for_acceptance: Vec<String> = view
            .tickets
            .iter()
            .filter(|ticket| ticket.state == "zur Abnahme")
            .map(|ticket| format!("»{}«", one_line(&ticket.title)))
            .collect();
        if !for_acceptance.is_empty() {
            details.push(format!("- Zur Abnahme: {}.", for_acceptance.join(", ")));
        }

        // Schläft: the world's own pause and stop, the agents that are paused or stopped, and
        // what the carrier says about sleep for quota and login.
        if let Some(stop) = view
            .world
            .stop
            .as_ref()
            .filter(|stop| stop.state == "gestoppt")
        {
            details.push(format!(
                "- Schläft: die ganze Welt ist gestoppt{}.",
                reason_suffix(&stop.reason)
            ));
        } else if let Some(pause) = view
            .world
            .pause
            .as_ref()
            .filter(|pause| pause.state == "pausiert")
        {
            details.push(format!(
                "- Schläft: die ganze Welt ist pausiert{}.",
                reason_suffix(&pause.reason)
            ));
        }
        for agent in &view.agents {
            if agent.state != "pausiert" && agent.state != "gestoppt" {
                continue;
            }
            let reason = agent
                .runtime
                .as_ref()
                .and_then(|runtime| runtime.reason.clone());
            details.push(format!(
                "- Schläft: {} ist {}{}.",
                agent.id,
                agent.state,
                reason_suffix(&reason)
            ));
        }
        match carriers.get(&world.id()) {
            Some(Ok(carrier)) => {
                if let Some(login) = carrier.anmeldung.as_ref().filter(|login| !login.available) {
                    details.push(format!(
                        "- Schläft: wer Arbeit hat, wartet auf die Anmeldung des Trägers{}.",
                        reason_suffix(&login.reason)
                    ));
                }
                let mut sleeping: Vec<(&String, &Sleep)> = carrier.schlaf.iter().collect();
                sleeping.sort_by(|left, right| left.0.cmp(right.0));
                for (agent, sleep) in sleeping {
                    if sleep.bis.is_some_and(|bis| (bis * 1000.0) as u64 <= now_ms) {
                        continue;
                    }
                    let until = sleep
                        .bis
                        .map(|bis| format!(" bis {}", clock((bis * 1000.0) as i64, now_ms)))
                        .unwrap_or_default();
                    details.push(format!(
                        "- Schläft: {agent}{until}, Grund: {}.",
                        sleep_reason(&sleep.grund)
                    ));
                }
            }
            Some(Err(reason)) => details.push(format!(
                "- Träger: nicht erreichbar ({}).",
                shorten(&one_line(reason), 120)
            )),
            None => {}
        }

        if !view.consistent {
            details.push(
                "- Hinweis: die Welt wurde während eines Schreibvorgangs gelesen.".to_owned(),
            );
        }
        if details.is_empty() {
            lines.push(format!("{header}: nichts offen, nichts fertig."));
        } else {
            lines.push(format!("{header}:"));
            lines.extend(details);
        }
    }
    lines
}

// MARK: - Die Liste für das Modell

/// The worlds as the companion's model reads them: one block per world with its lead agent,
/// its agents, what it needs from the person with the ids to answer or acknowledge it, and
/// its tickets that wait for acceptance.
pub fn listing(worlds: &[WorldState]) -> String {
    if worlds.is_empty() {
        return "Keine Welt gefunden.".to_owned();
    }
    let mut lines = Vec::new();
    for world in worlds {
        lines.push(format!(
            "Welt »{}« — id {}, Maschine {}, Ablage {}",
            world.name(),
            world.id(),
            world.machine,
            world.found.path
        ));
        let view = match &world.view {
            Ok(view) => view,
            Err(reason) => {
                lines.push(format!(
                    "  nicht lesbar: {}",
                    shorten(&one_line(reason), 200)
                ));
                continue;
            }
        };
        match world.lead() {
            Some(lead) => lines.push(format!("  Hauptagent: {}", lead.id)),
            None => lines.push("  Hauptagent: keiner".to_owned()),
        }
        let state = match (&view.world.stop, &view.world.pause) {
            (Some(stop), _) if stop.state == "gestoppt" => "gestoppt",
            (_, Some(pause)) if pause.state == "pausiert" => "pausiert",
            _ => "läuft",
        };
        lines.push(format!("  Stand der Welt: {state}"));
        let agents: Vec<String> = view
            .agents
            .iter()
            .map(|agent| {
                let mut entry = format!("{} ({}", agent.id, agent.stage);
                if let Some(team) = agent.team.as_deref().filter(|team| !team.is_empty()) {
                    entry.push_str(&format!(", Team {team}"));
                }
                if agent.state != "aktiv" && !agent.state.is_empty() {
                    entry.push_str(&format!(", {}", agent.state));
                }
                entry.push(')');
                entry
            })
            .collect();
        if !agents.is_empty() {
            lines.push(format!("  Agenten: {}", agents.join(", ")));
        }
        let items = needs(world);
        if items.is_empty() {
            lines.push("  Braucht dich: nichts".to_owned());
        }
        for item in items {
            let text = shorten(&one_line(&item.text), LINE_TEXT_CHARS);
            match item.kind {
                NeedKind::Question => {
                    let mut line = format!(
                        "  Frage {} von {}: {text}",
                        item.question_id.as_deref().unwrap_or_default(),
                        item.from
                    );
                    if !item.options.is_empty() {
                        line.push_str(&format!(" | Optionen: {}", item.options.join(" / ")));
                    }
                    if let Some(recommendation) = &item.recommendation {
                        line.push_str(&format!(" | Empfehlung: {recommendation}"));
                    }
                    lines.push(line);
                }
                NeedKind::MarkedQuestion | NeedKind::MarkedResult => lines.push(format!(
                    "  {} von {} (Zustellung {}): {text}",
                    if item.kind == NeedKind::MarkedQuestion {
                        "Markierte Frage"
                    } else {
                        "Markiertes Ergebnis"
                    },
                    item.from,
                    item.delivery_id.as_deref().unwrap_or_default()
                )),
                NeedKind::Ticket => lines.push(format!(
                    "  Ticket {} braucht dich: {text}",
                    item.ticket.as_deref().unwrap_or_default()
                )),
            }
        }
        for ticket in view
            .tickets
            .iter()
            .filter(|ticket| ticket.state == "zur Abnahme")
        {
            lines.push(format!(
                "  Zur Abnahme: Ticket {} »{}«{}",
                ticket.id,
                one_line(&ticket.title),
                ticket
                    .assignee
                    .as_deref()
                    .map(|assignee| format!(", bearbeitet von {assignee}"))
                    .unwrap_or_default()
            ));
        }
        let open = view
            .tickets
            .iter()
            .filter(|ticket| !matches!(ticket.state.as_str(), "abgenommen" | "verworfen"))
            .count();
        lines.push(format!("  Tickets offen: {open}"));
    }
    lines.join("\n")
}

// MARK: - Kleinteile

/// An RFC 3339 time as milliseconds since the epoch. `None` for anything else: a time that
/// does not parse is a time the companion does not know, not the epoch.
pub fn parse_time_ms(time: &str) -> Option<u64> {
    DateTime::parse_from_rfc3339(time.trim())
        .ok()
        .and_then(|when| u64::try_from(when.timestamp_millis()).ok())
}

/// Control characters and line breaks as spaces, runs of spaces as one. A world's text is an
/// agent's, and a line of the overview must not become two.
fn one_line(text: &str) -> String {
    text.split(|c: char| c.is_control() || c.is_whitespace())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// At most `limit` characters, with an ellipsis where something was cut.
fn shorten(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_owned();
    }
    let cut: String = text.chars().take(limit.saturating_sub(1)).collect();
    format!("{}…", cut.trim_end())
}

/// The sentence with exactly one closing mark.
fn with_stop(sentence: &str) -> String {
    let sentence = sentence.trim_end();
    if sentence.ends_with(['.', '?', '!', '…']) {
        sentence.to_owned()
    } else {
        format!("{sentence}.")
    }
}

fn reason_suffix(reason: &Option<String>) -> String {
    reason
        .as_deref()
        .map(one_line)
        .filter(|reason| !reason.is_empty())
        .map(|reason| format!(" ({})", shorten(reason.trim_end_matches('.'), 120)))
        .unwrap_or_default()
}

fn sleep_reason(grund: &str) -> String {
    match grund {
        "kontingent" => "Kontingent".to_owned(),
        "anmeldung" => "Anmeldung".to_owned(),
        "" => "unbekannt".to_owned(),
        other => one_line(other),
    }
}

/// A wake time as the person reads it: the time of day on the same day, the date in front of
/// it on another one.
fn clock(ms: i64, now_ms: u64) -> String {
    let (Some(when), Some(now)) = (
        Local.timestamp_millis_opt(ms).single(),
        Local.timestamp_millis_opt(now_ms as i64).single(),
    ) else {
        return ms.to_string();
    };
    if when.date_naive() == now.date_naive() {
        when.format("%H:%M").to_string()
    } else {
        when.format("%d.%m. %H:%M").to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A trimmed copy of what `wb-welt ansicht --json` printed for the workbench's demo world
    /// (`mac/bin/demo-welt`, 2026-09-14), with the fields the companion does not read left out.
    const VIEW: &str = r#"{
      "schema_version": 1, "consistent": true,
      "world": {"id": "welt-e639", "name": "Kalender-App", "kind": "project", "state": "läuft",
                "pause": {"state": "läuft", "reason": null}, "stop": {"state": "läuft", "reason": null},
                "governance": {"identity_verified": false}},
      "agents": [
        {"id": "leitung", "stage": "hauptagent", "state": "aktiv", "team": null,
         "runtime": {"state": "aktiv", "reason": null}, "memory": {"text": "x"}},
        {"id": "margaret", "stage": "mitglied", "state": "pausiert", "team": null,
         "runtime": {"state": "pausiert", "reason": "Wartet auf den Entwurf der Farben"}},
        {"id": "hedy", "stage": "teamleiter", "state": "aktiv", "team": "recherche"}
      ],
      "tickets": [
        {"id": "t-feiertage", "title": "Feiertagsquellen vergleichen", "state": "abgenommen",
         "sender": "leitung", "assignee": "rosalind",
         "approval": {"agent": "hedy", "time": "2026-09-14T14:26:24Z", "note": "passt"}},
        {"id": "t-sync-tests", "title": "Synchronisation testen", "state": "zur Abnahme",
         "sender": "ada", "assignee": "grace"},
        {"id": "t-ics-import", "title": "ICS-Import parsen", "state": "braucht dich",
         "sender": "leitung", "assignee": "linus"},
        {"id": "t-farben", "title": "Farben festlegen", "state": "braucht dich",
         "sender": "leitung", "assignee": "margaret", "updated_at": "2026-09-14T14:26:40Z"}
      ],
      "questions": [
        {"id": "frage-kalender", "text": "Welche Kalender?", "state": "beantwortet", "sender": "leitung"},
        {"id": "frage-wiederholung", "state": "offen", "sender": "leitung",
         "text": "Soll der Import wiederkehrende Termine mit Ausnahmen\nschon unterstützen?",
         "options": ["Ja, vollständig", "Nur einfache Wiederholungen", "Später"],
         "recommendation": "Nur einfache Wiederholungen", "ticket": "t-ics-import",
         "created_at": "2026-09-14T14:26:32Z"},
        {"id": "antrag-1", "state": "offen", "sender": "ada", "kind": "agent-antrag",
         "text": "Neues Mitglied anlegen?", "created_at": "2026-09-14T14:26:31Z"}
      ],
      "humans": {"mensch": {"postbox": {"open": 3, "total": 4, "deliveries": [
        {"delivery_id": "result-12_t-wochenplan", "kind": "ticket-ergebnis", "mark": "ergebnis",
         "sender": "leitung", "text": "Bis Freitag abnahmebereit.", "ticket": "t-wochenplan",
         "time": "2026-09-14T14:26:25Z", "acknowledged": false},
        {"delivery_id": "m-hedy", "kind": "direktchat", "mark": "ergebnis", "sender": "hedy",
         "text": "Die Feiertagsquelle ist abgenommen.", "time": "2026-09-14T14:26:33Z",
         "acknowledged": false},
        {"delivery_id": "m-linus", "kind": "direktchat", "sender": "linus",
         "text": "Unmarkiert.", "time": "2026-09-14T14:26:33Z", "acknowledged": false},
        {"delivery_id": "m-alt", "kind": "direktchat", "mark": "frage", "sender": "leitung",
         "text": "Schon gelesen.", "time": "2026-09-14T10:00:00Z", "acknowledged": true}
      ]}, "read_state": {}}},
      "errors": []
    }"#;

    fn world() -> WorldState {
        WorldState {
            machine: "lokal".to_owned(),
            found: FoundWorld {
                path: "/tmp/demo/projekte/kalender-app/.werkbank/agents".to_owned(),
                kind: "project".to_owned(),
                project: Some("/tmp/demo/projekte/kalender-app".to_owned()),
                id: Some("welt-e639".to_owned()),
                name: Some("Kalender-App".to_owned()),
                state: Some("läuft".to_owned()),
                error: None,
            },
            view: Ok(serde_json::from_str(VIEW).unwrap()),
        }
    }

    /// Open questions of the lead agent and unacknowledged marked messages need the person; an
    /// application to the lead agent, an unmarked message, an acknowledged one and a ticket
    /// whose question is already listed do not.
    #[test]
    fn what_needs_the_person_is_the_open_question_and_the_marked_messages() {
        let items = needs(&world());
        let keys: Vec<&str> = items.iter().map(|item| item.key.as_str()).collect();
        assert_eq!(
            keys,
            [
                "lokal|welt-e639|zustellung|result-12_t-wochenplan",
                "lokal|welt-e639|frage|frage-wiederholung",
                "lokal|welt-e639|zustellung|m-hedy",
                "lokal|welt-e639|ticket|t-farben",
            ]
        );
        let question = &items[1];
        assert_eq!(question.kind, NeedKind::Question);
        assert_eq!(question.question_id.as_deref(), Some("frage-wiederholung"));
        assert!(!question.settles_by_acknowledging());
        assert_eq!(items[2].kind, NeedKind::MarkedResult);
        assert_eq!(items[2].delivery_id.as_deref(), Some("m-hedy"));
        assert!(items[2].settles_by_acknowledging());
    }

    #[test]
    fn a_notice_names_the_world_the_sender_and_the_question_on_one_line() {
        let items = needs(&world());
        assert_eq!(
            notice_line(&items[1]),
            "»Kalender-App«: leitung fragt: Soll der Import wiederkehrende Termine mit \
             Ausnahmen schon unterstützen? Empfehlung: Nur einfache Wiederholungen."
        );
        assert_eq!(
            notice_line(&items[2]),
            "»Kalender-App«: Ergebnis von hedy für dich: Die Feiertagsquelle ist abgenommen."
        );
        assert_eq!(
            notice_line(&items[3]),
            "»Kalender-App«: Das Ticket »Farben festlegen« braucht dich."
        );
    }

    /// A marked message is acknowledged from its notice only where the notice carries all of
    /// it; a long one is cut there, and a cut result is not a result read (M-2).
    #[test]
    fn only_a_marked_message_that_fits_whole_is_acknowledged_from_its_notice() {
        let items = needs(&world());
        let mut result = items[2].clone();
        assert!(result.acknowledged_from_notice());
        assert!(!items[1].acknowledged_from_notice(), "a question never");

        result.text = "Wort ".repeat(32).trim_end().to_owned();
        assert_eq!(result.text.chars().count(), 159);
        assert!(result.acknowledged_from_notice(), "159 characters fit");

        result.text = format!("{}\n\nund noch mehr dazu", "x".repeat(150));
        assert!(!result.notice_is_whole());
        assert!(!result.acknowledged_from_notice());
        assert!(notice_line(&result).ends_with('…'), "the notice is cut");
    }

    /// The plan's overview: what finished since the last one, what waits, what sleeps and why.
    #[test]
    fn the_overview_says_what_finished_what_waits_and_what_sleeps() {
        let since = parse_time_ms("2026-09-14T14:00:00Z");
        let now = parse_time_ms("2026-09-14T15:00:00Z").unwrap();
        let mut carriers = HashMap::new();
        let mut schlaf = HashMap::new();
        schlaf.insert(
            "linus".to_owned(),
            Sleep {
                grund: "kontingent".to_owned(),
                bis: Some((now / 1000 + 3600) as f64),
            },
        );
        carriers.insert(
            "welt-e639".to_owned(),
            Ok(CarrierStatus {
                schlaf,
                anmeldung: Some(Login {
                    available: true,
                    reason: None,
                }),
            }),
        );

        let lines = overview_lines(&[world()], since, &carriers, now);
        let text = lines.join("\n");
        assert!(text.starts_with("Welten: 1 (Kalender-App)."), "{text}");
        assert!(
            text.contains("Welt »Kalender-App«, Hauptagent leitung:"),
            "{text}"
        );
        assert!(
            text.contains(
                "- Abgenommen seit dem letzten Überblick: »Feiertagsquellen vergleichen«."
            ),
            "{text}"
        );
        assert!(
            text.contains("- Ergebnis an dich von hedy: Die Feiertagsquelle ist abgenommen."),
            "{text}"
        );
        assert!(
            text.contains("- Wartet auf dich: Frage von leitung: Soll der Import"),
            "{text}"
        );
        assert!(
            text.contains("- Zur Abnahme: »Synchronisation testen«."),
            "{text}"
        );
        assert!(
            text.contains("- Schläft: margaret ist pausiert (Wartet auf den Entwurf der Farben)."),
            "{text}"
        );
        assert!(text.contains("- Schläft: linus bis "), "{text}");
        assert!(text.contains(", Grund: Kontingent."), "{text}");
        // The application to the lead agent is not the person's, and neither is an unmarked
        // message.
        assert!(!text.contains("Neues Mitglied"), "{text}");
        assert!(!text.contains("Unmarkiert"), "{text}");
        assert!(!text.contains("Anmeldung des Trägers"), "{text}");

        // A carrier without a login keeps every agent with work asleep, and says so.
        let status: CarrierStatus = serde_json::from_str(
            r#"{"world": "welt-e639", "schlaf": {},
                "anmeldung": {"kind": "claude-login-readonly", "available": false,
                              "reason": "Anmeldedatei fehlt oder ist nicht lesbar"}}"#,
        )
        .unwrap();
        carriers.insert("welt-e639".to_owned(), Ok(status));
        let text = overview_lines(&[world()], since, &carriers, now).join("\n");
        assert!(
            text.contains(
                "- Schläft: wer Arbeit hat, wartet auf die Anmeldung des Trägers (Anmeldedatei \
                 fehlt oder ist nicht lesbar)."
            ),
            "{text}"
        );
    }

    /// An acceptance before the last overview was already told, and a carrier that could not be
    /// asked says so instead of pretending nobody sleeps.
    #[test]
    fn what_was_told_before_stays_out_and_an_unreachable_carrier_is_named() {
        let since = parse_time_ms("2026-09-14T14:30:00Z");
        let now = parse_time_ms("2026-09-14T15:00:00Z").unwrap();
        let mut carriers = HashMap::new();
        carriers.insert(
            "welt-e639".to_owned(),
            Err("Datei fehlt: traeger.json".to_owned()),
        );
        let text = overview_lines(&[world()], since, &carriers, now).join("\n");
        assert!(!text.contains("Abgenommen seit"), "{text}");
        assert!(!text.contains("Ergebnis an dich"), "{text}");
        assert!(
            text.contains("- Träger: nicht erreichbar (Datei fehlt: traeger.json)."),
            "{text}"
        );
    }

    #[test]
    fn a_world_that_could_not_be_read_is_named_rather_than_left_out() {
        let mut broken = world();
        broken.view = Err("ssh: connect to host peer port 22: Operation timed out".to_owned());
        broken.machine = "peer".to_owned();
        let text = overview_lines(&[broken.clone()], None, &HashMap::new(), 0).join("\n");
        assert!(
            text.contains("Welt »Kalender-App«: nicht lesbar (ssh: connect"),
            "{text}"
        );
        assert!(needs(&broken).is_empty());
        assert!(listing(&[broken]).contains("nicht lesbar: ssh: connect"));
    }

    #[test]
    fn the_model_reads_every_id_it_needs_to_answer_or_acknowledge() {
        let text = listing(&[world()]);
        assert!(
            text.contains("Welt »Kalender-App« — id welt-e639, Maschine lokal"),
            "{text}"
        );
        assert!(text.contains("Hauptagent: leitung"), "{text}");
        assert!(
            text.contains(
                "Frage frage-wiederholung von leitung: Soll der Import wiederkehrende Termine \
                 mit Ausnahmen schon unterstützen? | Optionen: Ja, vollständig / Nur einfache \
                 Wiederholungen / Später | Empfehlung: Nur einfache Wiederholungen"
            ),
            "{text}"
        );
        assert!(
            text.contains("Markiertes Ergebnis von hedy (Zustellung m-hedy)"),
            "{text}"
        );
        assert!(
            text.contains(
                "Zur Abnahme: Ticket t-sync-tests »Synchronisation testen«, bearbeitet von grace"
            ),
            "{text}"
        );
        assert!(text.contains("margaret (mitglied, pausiert)"), "{text}");
    }

    #[test]
    fn a_world_is_named_by_its_id_its_name_its_store_or_its_project() {
        let world = world();
        assert!(world.is_named("welt-e639"));
        assert!(world.is_named("kalender-app"));
        assert!(world.is_named("/tmp/demo/projekte/kalender-app/.werkbank/agents"));
        assert!(world.is_named("/tmp/demo/projekte/kalender-app"));
        assert!(!world.is_named(""));
        assert!(!world.is_named("Global"));
    }

    /// A view with fields the companion has never heard of, and without most of the ones it
    /// reads, still parses: the view is the workbench's and grows.
    #[test]
    fn a_view_with_new_fields_and_missing_ones_still_reads() {
        let view: WorldView = serde_json::from_str(
            r#"{"world": {"id": "w", "name": "N", "neu": 1}, "zukunft": [1, 2]}"#,
        )
        .unwrap();
        assert!(view.consistent);
        assert!(view.agents.is_empty());
        let found: Vec<FoundWorld> =
            serde_json::from_str(r#"[{"path": "/w", "kind": "global", "error": null}]"#).unwrap();
        assert_eq!(found[0].path, "/w");
    }

    #[test]
    fn a_time_that_is_not_rfc3339_is_unknown() {
        assert_eq!(
            parse_time_ms("2026-09-14T14:26:24Z"),
            Some(1_789_395_984_000)
        );
        assert_eq!(
            parse_time_ms("2026-09-14T16:26:24+02:00"),
            Some(1_789_395_984_000)
        );
        assert_eq!(parse_time_ms("gestern"), None);
    }
}
