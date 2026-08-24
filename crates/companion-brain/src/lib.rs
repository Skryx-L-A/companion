// SPDX-License-Identifier: AGPL-3.0-only

//! The companion's own answer: the part that talks with the person.
//!
//! One message in, a stream of `chat_delta` events out, `chat_tool` wherever a tool ran,
//! and `chat_done` at the end. Which model answers is the fallback chain of the role
//! `chat_llm` from `DESIGN.md` § Endpoints; whether it can do anything besides talk is
//! [`tools::ToolBox`], and the two things that keep it inside the plan live one file down
//! each: the fence around session text in [`prompt::data_block`], and the absence of a tool
//! for anything that acts outward.
//!
//! What is deliberately not here: loop logic. `DESIGN.md` § Loops keeps that with the
//! orchestrator — the companion writes the job file, starts the session and reads the
//! result, and runs no loop of its own.

pub mod driver;
pub mod prompt;
pub mod tools;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use companion_core::adapter::AdapterEvent;
use companion_core::{Autonomy, EndpointConfig, EndpointProfile, EventBus, Registry, SecretStore};
use companion_protocol::{AdapterId, EndpointRole, Event};
use tracing::warn;

pub use driver::{ChatDriver, Conversation, DriverError, Message, Turn};
pub use tools::{SessionAccess, ToolBox, ToolCall, ToolOutcome, ToolSpec};

/// Adapter id every chat event carries. Not a session adapter: it owns no session, and its
/// events have no session id.
pub const BRAIN_ADAPTER: &str = "brain";

/// The ceilings that keep one answer from running away.
#[derive(Debug, Clone, Copy)]
pub struct BrainLimits {
    /// How many times the model may ask for tools before it has to answer.
    ///
    /// Six covers the chain the tools were built for — list, details, read, answer — with
    /// headroom for one extra lookup on the way, and stays short enough that a model which
    /// keeps asking is stopped rather than left to spend the subscription.
    pub max_tool_rounds: u32,
    /// How many earlier messages the next answer sees.
    pub max_history: usize,
    /// Deadline for one call against an API endpoint.
    pub request_timeout: Duration,
    /// Deadline for one CLI run. Longer, because a fresh process has to start first.
    pub cli_timeout: Duration,
}

impl Default for BrainLimits {
    fn default() -> Self {
        Self {
            max_tool_rounds: 6,
            max_history: 20,
            request_timeout: Duration::from_secs(120),
            cli_timeout: Duration::from_secs(180),
        }
    }
}

/// What the brain needs besides its ports.
#[derive(Debug, Clone)]
pub struct BrainConfig {
    /// Where the system prompt file lives.
    pub config_dir: std::path::PathBuf,
    /// How far the companion may act on its own. Read once at start, like the endpoints.
    pub autonomy: Autonomy,
    pub limits: BrainLimits,
}

/// Says an answer out loud.
///
/// A port rather than a direct call into the voice pipeline: a daemon built without speech
/// simply has none of these, and the brain then answers in writing instead of failing.
pub trait Speaker: Send + Sync {
    fn speak(&self, text: String) -> Result<(), String>;
}

#[derive(Debug, thiserror::Error)]
pub enum BrainError {
    #[error("no endpoint is configured for role {role}")]
    NoEndpoint { role: &'static str },
    #[error("the companion is still writing the previous answer")]
    Busy,
    #[error("the message is empty")]
    Empty,
    #[error("cannot read or write the system prompt {path}: {source}")]
    Prompt {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("cannot read the key store: {0}")]
    Secrets(#[from] companion_core::SecretError),
    #[error("the whole fallback chain for role chat_llm failed: {detail}")]
    ChainExhausted { detail: String },
}

/// The companion's answering machinery.
pub struct Brain {
    bus: EventBus,
    endpoints: Arc<EndpointConfig>,
    secrets: Arc<dyn SecretStore>,
    tools: Arc<ToolBox>,
    speaker: Option<Arc<dyn Speaker>>,
    config: BrainConfig,
    http: reqwest::Client,
    /// One answer at a time. The three chat events carry no id, so two answers at once
    /// would interleave into something nobody can read.
    answering: AtomicBool,
    /// What was said earlier, so the next message is not answered out of nowhere.
    history: std::sync::Mutex<Vec<Message>>,
}

impl Brain {
    pub fn new(
        bus: EventBus,
        endpoints: Arc<EndpointConfig>,
        secrets: Arc<dyn SecretStore>,
        registry: Arc<Registry>,
        sessions: Arc<dyn SessionAccess>,
        speaker: Option<Arc<dyn Speaker>>,
        config: BrainConfig,
    ) -> Self {
        let http = reqwest::Client::builder()
            .timeout(config.limits.request_timeout)
            .build()
            // A default client would silently have no request timeout, so a broken build
            // is a loud start-up failure instead of a chat that can hang forever.
            .expect("the HTTP client for the chat endpoints could not be built");
        let tools = Arc::new(ToolBox::new(
            sessions,
            registry,
            config.autonomy,
            bus.clone(),
        ));
        Self {
            bus,
            endpoints,
            secrets,
            tools,
            speaker,
            config,
            http,
            answering: AtomicBool::new(false),
            history: std::sync::Mutex::new(Vec::new()),
        }
    }

    /// Takes one message from the person. The answer arrives as events.
    ///
    /// Returns as soon as the turn is under way: a client that waited for the answer here
    /// would block for the whole turn, tool calls included, and it is listening on the event
    /// stream anyway.
    pub fn chat(self: &Arc<Self>, text: String, voice: bool) -> Result<(), BrainError> {
        if text.trim().is_empty() {
            return Err(BrainError::Empty);
        }
        // Refused here rather than at the first token: a person who has configured no chat
        // model should learn that when they press send.
        if self.endpoints.chain(EndpointRole::ChatLlm).is_empty() {
            return Err(BrainError::NoEndpoint {
                role: EndpointRole::ChatLlm.as_str(),
            });
        }
        if self.answering.swap(true, Ordering::SeqCst) {
            return Err(BrainError::Busy);
        }

        let brain = Arc::clone(self);
        tokio::spawn(async move {
            brain.run_turn(text, voice).await;
            brain.answering.store(false, Ordering::SeqCst);
        });
        Ok(())
    }

    /// Whether an answer is being written right now.
    pub fn is_answering(&self) -> bool {
        self.answering.load(Ordering::SeqCst)
    }

    async fn run_turn(&self, user_text: String, voice: bool) {
        let system = match prompt::load_or_create(&self.config.config_dir) {
            Ok(system) => system,
            Err(error) => {
                self.fail(&error.to_string(), String::new());
                return;
            }
        };

        let mut messages = self.recent_history();
        messages.push(Message::User {
            text: user_text.clone(),
        });
        let base = Conversation { system, messages };

        let mut answer = String::new();
        let mut reasons = Vec::new();
        let mut failure: Option<String> = None;

        for profile in self.endpoints.chain(EndpointRole::ChatLlm) {
            let before = answer.len();
            match self.attempt(profile, &base, &mut answer).await {
                Ok(()) => {
                    failure = None;
                    break;
                }
                Err(error) => {
                    let reason = format!("{}: {error}", profile.id);
                    warn!(profile = %profile.id, %error, "chat endpoint failed");
                    reasons.push(reason);
                    if answer.len() > before {
                        // The person is already reading this answer. Starting again on
                        // another endpoint would write a second one underneath it.
                        failure = Some(
                            BrainError::ChainExhausted {
                                detail: reasons.join("; "),
                            }
                            .to_string(),
                        );
                        break;
                    }
                    failure = Some(
                        BrainError::ChainExhausted {
                            detail: reasons.join("; "),
                        }
                        .to_string(),
                    );
                }
            }
        }

        if let Some(message) = failure {
            self.fail(&message, answer);
            return;
        }

        self.remember(user_text, &answer);
        let spoken = self.speak(voice, &answer);
        self.publish(Event::ChatDone {
            text: answer,
            spoken,
        });
    }

    /// One endpoint, from the first token to the finished answer, tool rounds included.
    async fn attempt(
        &self,
        profile: &EndpointProfile,
        base: &Conversation,
        answer: &mut String,
    ) -> Result<(), DriverError> {
        let key = self.key_for(profile)?;
        let driver = driver::driver_for(
            profile,
            key,
            self.http.clone(),
            self.config.limits.cli_timeout,
        )?;
        let specs = ToolBox::specs();
        let mut conversation = base.clone();

        for round in 0..self.config.limits.max_tool_rounds {
            let turn = {
                let mut sink = |piece: &str| {
                    answer.push_str(piece);
                    self.publish(Event::ChatDelta {
                        text: piece.to_owned(),
                    });
                };
                driver.turn(&conversation, &specs, &mut sink).await?
            };

            if turn.tool_calls.is_empty() {
                return Ok(());
            }
            if !turn.text.is_empty() {
                conversation.messages.push(Message::Assistant {
                    text: turn.text.clone(),
                });
            }
            for call in &turn.tool_calls {
                conversation.messages.push(Message::ToolCall {
                    id: call.id.clone(),
                    name: call.name.clone(),
                    arguments: call.arguments.clone(),
                });
            }
            for call in &turn.tool_calls {
                let outcome = self.tools.run(call).await;
                self.publish(Event::ChatTool {
                    name: call.name.clone(),
                    summary: outcome.summary,
                });
                conversation.messages.push(Message::ToolResult {
                    id: call.id.clone(),
                    name: call.name.clone(),
                    content: outcome.content,
                });
            }

            if round + 1 == self.config.limits.max_tool_rounds {
                // The last round was spent on tools, so there is no answer and there will
                // not be one. Better a sentence that says so than silence.
                let note = format!(
                    "Ich habe die Grenze von {} Werkzeugrunden erreicht und breche hier ab.",
                    self.config.limits.max_tool_rounds
                );
                answer.push_str(&note);
                self.publish(Event::ChatDelta { text: note });
            }
        }
        Ok(())
    }

    /// The key of a profile, or an error naming the entry it is missing.
    fn key_for(&self, profile: &EndpointProfile) -> Result<Option<String>, DriverError> {
        let Some(name) = profile.key_ref.as_deref() else {
            return Ok(None);
        };
        match self.secrets.secret(name)? {
            Some(key) => Ok(Some(key)),
            None => Err(DriverError::MissingKey {
                profile: profile.id.clone(),
                key_ref: name.to_owned(),
            }),
        }
    }

    /// Speaks the answer when the person asked for it and this daemon can.
    fn speak(&self, wanted: bool, answer: &str) -> bool {
        if !wanted || answer.trim().is_empty() {
            return false;
        }
        let Some(speaker) = &self.speaker else {
            return false;
        };
        match speaker.speak(answer.to_owned()) {
            Ok(()) => true,
            Err(reason) => {
                // The written answer is already there, so a mute companion is a note in the
                // log and an honest `spoken: false`, not a failed turn.
                warn!(reason, "the answer could not be spoken");
                false
            }
        }
    }

    /// Ends a turn that went wrong: the reason, then the end of the answer.
    ///
    /// Both on purpose, the same way a failed dictation ends in `error` and `tts_done`: the
    /// error says what happened, `chat_done` says that nothing more is coming, so the shell
    /// can leave the writing state either way.
    fn fail(&self, message: &str, answer: String) {
        self.publish(Event::Error {
            message: message.to_owned(),
        });
        self.publish(Event::ChatDone {
            text: answer,
            spoken: false,
        });
    }

    fn publish(&self, event: Event) {
        self.bus.publish(
            AdapterId::new(BRAIN_ADAPTER),
            AdapterEvent::adapter_wide(event),
        );
    }

    fn recent_history(&self) -> Vec<Message> {
        self.lock_history().clone()
    }

    /// Keeps the exchange, not the tool traffic.
    ///
    /// Tool calls and their results stay inside the turn that needed them: they are the
    /// largest part of a conversation by far, they are only valid next to the call they
    /// answer, and what the next message needs is what was said, not how it was found out.
    fn remember(&self, user_text: String, answer: &str) {
        let mut history = self.lock_history();
        history.push(Message::User { text: user_text });
        if !answer.trim().is_empty() {
            history.push(Message::Assistant {
                text: answer.to_owned(),
            });
        }
        let keep = self.config.limits.max_history;
        if history.len() > keep {
            let drop = history.len() - keep;
            history.drain(..drop);
        }
    }

    fn lock_history(&self) -> std::sync::MutexGuard<'_, Vec<Message>> {
        self.history
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl std::fmt::Debug for Brain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Brain")
            .field("profiles", &self.endpoints.profiles.len())
            .field("autonomy", &self.config.autonomy)
            .field("answering", &self.is_answering())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use companion_core::{NoSecrets, RoleBinding};
    use companion_protocol::{EndpointProtocol, SendOutcome, SessionId, SessionStatus};

    struct NoSessions;

    #[async_trait]
    impl SessionAccess for NoSessions {
        async fn sessions(&self) -> Result<Vec<SessionStatus>, String> {
            Ok(Vec::new())
        }
        async fn read(&self, _session_id: &SessionId, _lines: u32) -> Result<String, String> {
            Ok(String::new())
        }
        async fn answer(
            &self,
            _session_id: &SessionId,
            _text: &str,
        ) -> Result<SendOutcome, String> {
            Ok(SendOutcome::Delivered)
        }
    }

    fn brain(endpoints: EndpointConfig) -> Arc<Brain> {
        Arc::new(Brain::new(
            EventBus::new(64),
            Arc::new(endpoints),
            Arc::new(NoSecrets),
            Arc::new(Registry::open_in_memory().expect("in-memory register")),
            Arc::new(NoSessions),
            None,
            BrainConfig {
                config_dir: std::env::temp_dir()
                    .join(format!("companion-brain-unit-{}", std::process::id())),
                autonomy: Autonomy::Observe,
                limits: BrainLimits::default(),
            },
        ))
    }

    /// A chat endpoint that points at a port nothing listens on.
    fn dead_chat() -> EndpointConfig {
        let mut profile =
            EndpointProfile::local("dead", EndpointProtocol::OpenaiCompat, "http://127.0.0.1:1");
        profile.model = Some("irgendein-modell".to_owned());
        EndpointConfig::empty()
            .with_profile(profile)
            .with_role(EndpointRole::ChatLlm, RoleBinding::new("dead"))
    }

    #[tokio::test]
    async fn a_message_without_a_configured_model_is_refused_at_the_start() {
        let brain = brain(EndpointConfig::empty());
        let error = brain
            .chat("hallo".to_owned(), false)
            .expect_err("must refuse");
        assert!(
            matches!(error, BrainError::NoEndpoint { role: "chat_llm" }),
            "{error}"
        );
    }

    #[tokio::test]
    async fn an_empty_message_is_refused_before_anything_starts() {
        let brain = brain(dead_chat());
        let error = brain
            .chat("   ".to_owned(), false)
            .expect_err("must refuse");
        assert!(matches!(error, BrainError::Empty), "{error}");
    }

    #[tokio::test]
    async fn a_second_message_while_the_first_is_still_running_is_refused() {
        let brain = brain(dead_chat());
        brain.chat("erste".to_owned(), false).unwrap();
        let error = brain
            .chat("zweite".to_owned(), false)
            .expect_err("must refuse");
        assert!(matches!(error, BrainError::Busy), "{error}");
    }

    #[tokio::test]
    async fn a_turn_whose_endpoint_is_dead_ends_in_an_error_and_a_chat_done() {
        let brain = brain(dead_chat());
        let mut events = brain.bus.subscribe();
        brain.chat("was laeuft".to_owned(), false).unwrap();

        let mut saw_error = false;
        loop {
            let envelope = tokio::time::timeout(Duration::from_secs(10), events.recv())
                .await
                .expect("an answer has to come")
                .unwrap();
            assert_eq!(envelope.adapter.as_str(), BRAIN_ADAPTER);
            assert!(
                envelope.session_id.is_none(),
                "a chat event belongs to no session"
            );
            match envelope.event {
                Event::Error { message } => {
                    assert!(message.contains("chat_llm"), "{message}");
                    saw_error = true;
                }
                Event::ChatDone { text, spoken } => {
                    assert!(text.is_empty(), "nothing was written: {text}");
                    assert!(!spoken);
                    break;
                }
                other => panic!("unexpected event {other:?}"),
            }
        }
        assert!(saw_error, "the reason has to reach the person");
    }

    #[test]
    fn history_keeps_the_exchange_and_forgets_the_oldest() {
        let brain = brain(dead_chat());
        for number in 0..30 {
            brain.remember(format!("frage {number}"), &format!("antwort {number}"));
        }
        let history = brain.recent_history();
        assert_eq!(history.len(), BrainLimits::default().max_history);
        assert_eq!(
            history.first(),
            Some(&Message::User {
                text: "frage 20".to_owned()
            }),
            "the oldest exchange is dropped whole: {history:?}"
        );
    }

    #[test]
    fn an_answer_that_never_came_leaves_no_empty_turn_in_the_history() {
        let brain = brain(dead_chat());
        brain.remember("frage".to_owned(), "");
        assert_eq!(brain.recent_history().len(), 1);
    }

    #[test]
    fn nothing_is_spoken_without_a_speaker() {
        let brain = brain(dead_chat());
        assert!(!brain.speak(true, "guten Morgen"), "no speaker, no speech");
        assert!(!brain.speak(false, "guten Morgen"));
    }
}
