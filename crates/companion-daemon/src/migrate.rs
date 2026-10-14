// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Changes an existing configuration needs before the daemon can use it well.
//!
//! Everything here is additive and runs at most once per machine. A settings document is the
//! person's, not this program's: a migration may put something in front of them that did not
//! exist when they set the machine up, and it may never take away or overwrite what they
//! chose. Which migrations already ran is remembered in [`MARKER_FILE`] next to the settings,
//! so one that somebody undid on purpose stays undone.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use companion_brain::harness::web_search_possible;
use companion_protocol::{
    BREEZE_PROFILE_ID, EndpointConfig, EndpointProfile, EndpointProtocol, EndpointRole, GERMAN,
    SAY_PROGRAM, VoiceServerSettings,
};
use tracing::{info, warn};

/// Where the applied migrations are listed, one id per line, next to `settings.json`.
///
/// A file rather than a field in the settings: which migration ran is this daemon's
/// bookkeeping about a machine, not part of the document the settings page shows and the
/// paired devices read.
pub const MARKER_FILE: &str = "migrations.applied";

/// Directory the German voice models live in, under the configuration directory. The same
/// place the Mac shell downloads them to.
const VOICE_MODELS_DIR: &str = "voice-models";

/// German `piper` voice models, best first. Both are `de_DE-thorsten`, and the higher one is
/// the one Skryx-L-A's own ear picked over `say`'s `Anna` on 2026-08-27; the round-trip
/// measurement of 2026-09-05 could not tell the two model sizes apart at all (7 per cent of
/// the words wrong either way), so the ear decides and the medium model is the fallback.
const PIPER_GERMAN_MODELS: [&str; 2] = ["de_DE-thorsten-high.onnx", "de_DE-thorsten-medium.onnx"];

/// What this machine has to offer for speaking German, best first.
///
/// A parameter object rather than a set of calls, so a test says what a machine has instead
/// of depending on what the machine running the test happens to have installed.
#[derive(Debug, Clone, Default)]
pub struct GermanVoices {
    /// Absolute path of the `piper` program, when it is installed.
    pub piper_program: Option<String>,
    /// Absolute path of a German `piper` model, when one was downloaded.
    pub piper_model: Option<String>,
    /// Whether `/usr/bin/say` is there, which on a Mac it always is.
    pub has_say: bool,
}

impl GermanVoices {
    /// What this machine actually has. `config_dir` is where the voice models are looked for.
    pub fn on_this_machine(config_dir: &Path) -> Self {
        let piper_program = program_on_path("piper");
        let models = config_dir.join(VOICE_MODELS_DIR);
        let piper_model = PIPER_GERMAN_MODELS
            .iter()
            .map(|name| models.join(name))
            .find(|path| path.is_file())
            .map(|path| path.display().to_string());
        Self {
            piper_program,
            piper_model,
            has_say: Path::new(SAY_PROGRAM).is_file(),
        }
    }

    /// The best German TTS profile this machine can offer, or `None` when it can offer none.
    fn best(&self) -> Option<EndpointProfile> {
        if let (Some(program), Some(model)) = (&self.piper_program, &self.piper_model) {
            return Some(EndpointProfile::piper_german(program, model));
        }
        self.has_say.then(EndpointProfile::say_german)
    }
}

/// Looks a program up along `PATH`, the same way a shell would.
///
/// `which` as a subprocess would do too, but this is one line of the same thing and starts no
/// process during the daemon's start-up.
fn program_on_path(program: &str) -> Option<String> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|directory| directory.join(program))
            .find(|candidate| candidate.is_file())
            .map(|candidate| candidate.display().to_string())
    })
}

/// Adds the best German voice this machine has to the TTS chain, once.
///
/// The reason it exists: a configuration written before language-aware speaking existed has
/// Kokoro as its only voice, and Kokoro has no German phonemes — measured on 2026-09-05 over
/// a TTS-to-speech-recognition round trip, 63 per cent of the words of three German sentences
/// came back wrong. The setup assistant writes a German profile for a new machine; this is
/// how the machines that were set up earlier get one. It also reaches a machine whose German
/// voice is `say`'s `Anna` and where `piper` has since been installed, which is Skryx-L-A's
/// own machine on the day this was written.
///
/// Returns the id of the profile it added, or `None` when it added nothing — which is the
/// normal outcome on every start after the first.
pub fn add_german_voice(
    config: &mut EndpointConfig,
    voices: &GermanVoices,
    applied: &mut Applied,
) -> Option<String> {
    // Nothing to extend: a machine with no speech set up at all is the setup assistant's
    // business, not this one's. Putting a lone `say` profile in an empty document would also
    // silently switch speaking on for somebody who never asked for it.
    if config.chain(EndpointRole::Tts).is_empty() {
        return None;
    }
    let wanted = voices.best()?;
    let marker = format!("german-voice:{}", wanted.id);
    if applied.contains(&marker) {
        return None;
    }
    // Already there under that name, whatever it points at now — the person's own entry, and
    // this is not the place to correct it.
    if config.profile(&wanted.id).is_some() {
        applied.insert(marker);
        return None;
    }

    let id = wanted.id.clone();
    // In front of any weaker German profile that is already in the chain, so `piper` leads
    // and `say`'s `Anna` stays behind it as the fallback. The chain order decides only which
    // German voice is tried first: language-aware routing pulls whichever one it is to the
    // front for a German sentence either way.
    let ahead_of = config
        .chain(EndpointRole::Tts)
        .iter()
        .find(|profile| profile.language.as_deref() == Some(GERMAN))
        .map(|profile| profile.id.clone());
    config.profiles.push(wanted);
    if let Some(binding) = config.roles.get_mut(&EndpointRole::Tts) {
        let position = ahead_of
            .and_then(|other| binding.fallback.iter().position(|name| *name == other))
            .unwrap_or(binding.fallback.len());
        binding.fallback.insert(position, id.clone());
    }
    applied.insert(marker);
    Some(id)
}

/// Id of the migration that gives the companion's helper model a binding. One fixed name and
/// not one per profile: what it stands for is the single decision "this machine has been
/// offered a helper model once", and somebody who took the binding away afterwards must not
/// be given it back the next time the daemon starts.
const SUBAGENT_MARKER: &str = "subagent-llm-from-chat";

/// Binds the role `subagent_llm` to the same chain as `chat_llm`, once, when that chain is
/// led by the `claude` CLI.
///
/// The reason it exists: nobody ever writes this role. The setup assistant writes `chat_llm`
/// and nothing else, and the daemon's own first-start defaults write neither, so a machine
/// set up through the assistant has the role empty — which is what Skryx-L-A's machine looked
/// like on 2026-09-05. Two things fall out with it. `web_research` answers every question
/// with "kein Hilfsmodell mit Websuche ist gerade erreichbar", because
/// [`companion_brain::subagent::choose_web_subagent`] walks an empty chain; and a long tool
/// result is never shortened, because [`companion_brain::subagent::choose_subagent`] walks
/// the same empty chain.
///
/// Only for a `claude` CLI profile ([`web_search_possible`]): that is the one shape that can
/// actually be given live web search, and binding an API profile here would produce a role
/// that condenses but answers research questions with the same refusal as before, which is a
/// worse thing to leave behind than an empty role.
///
/// Returns the profile the role now leads with, or `None` when it bound nothing.
pub fn bind_subagent_llm(config: &mut EndpointConfig, applied: &mut Applied) -> Option<String> {
    if applied.contains(SUBAGENT_MARKER) {
        return None;
    }
    // Already bound, to whatever the person picked — this is not the place to correct it.
    // Marked all the same, so taking that binding away later stays taken away.
    if config.roles.contains_key(&EndpointRole::SubagentLlm) {
        applied.insert(SUBAGENT_MARKER.to_owned());
        return None;
    }
    let chat = config.roles.get(&EndpointRole::ChatLlm)?.clone();
    let primary = config.profile(&chat.primary)?;
    if !web_search_possible(primary) {
        // No marker: a machine whose chat model is an API profile today may well get the
        // `claude` CLI tomorrow, and then this migration is exactly what it needs.
        return None;
    }
    let id = primary.id.clone();
    config.roles.insert(EndpointRole::SubagentLlm, chat);
    applied.insert(SUBAGENT_MARKER.to_owned());
    Some(id)
}

/// Id of the migration that makes Breeze TTS 2 the voice for speaking. One fixed name, for the
/// same reason as [`SUBAGENT_MARKER`]: a person who went back to Kokoro keeps Kokoro.
const BREEZE_MARKER: &str = "breeze-tts-default";

/// The speaking profile the setup assistant has written since the voice track of 2026-08-25,
/// field by field as `LocalSpeechSetup.speaker` spells it: id, model and voice.
const KOKORO_SETUP_ID: &str = "mlx-audio-tts";
const KOKORO_MODEL: &str = "mlx-community/Kokoro-82M-bf16";
const KOKORO_SETUP_VOICE: &str = "af_heart";

/// Whether a profile is the setup's own Kokoro and not somebody's.
///
/// All three fields the setup writes have to match. The model alone is not enough (review of
/// 2026-09-10): a person who added a Kokoro profile of their own, under another name or with
/// another voice, chose Kokoro on purpose, and moving it behind Breeze would overrule that.
fn is_setup_kokoro(profile: &EndpointProfile) -> bool {
    profile.id == KOKORO_SETUP_ID
        && profile.protocol == EndpointProtocol::OpenaiCompat
        && profile.model.as_deref() == Some(KOKORO_MODEL)
        && profile.voice.as_deref() == Some(KOKORO_SETUP_VOICE)
}

/// Puts Breeze TTS 2 in front of the TTS chain, once, where it runs and where Kokoro still
/// leads as the setup left it.
///
/// Skryx-L-A's decision of 2026-09-10: Breeze becomes the default voice, Kokoro stays as the
/// profile behind it. Moving the primary is more than the other migrations here do, and it
/// is bounded accordingly. It only ever replaces the setup's own Kokoro profile, never a
/// voice somebody picked; Kokoro moves to the first fallback rather than out, so an English
/// sentence Breeze cannot speak still gets Kokoro's voice; and the marker makes it once, so
/// going back to Kokoro stays that way.
///
/// `breeze_runs_here` is [`companion_voice::local_models::breeze_runs_here`]: the speech
/// server this daemon starts has the Breeze implementation and the weights are in its cache.
/// Without both nothing happens and nothing is marked, because the setup script may bring
/// them tomorrow — and a Breeze profile in front of a server that cannot load it would fail
/// once on every English sentence before Kokoro spoke it.
///
/// German is not affected: the Breeze profile is tagged `en`, so language-aware routing keeps
/// moving the German profile to the front for a German sentence.
///
/// Returns the id of the profile that now leads, or `None` when it changed nothing.
pub fn adopt_breeze(
    config: &mut EndpointConfig,
    breeze_runs_here: bool,
    applied: &mut Applied,
) -> Option<String> {
    if applied.contains(BREEZE_MARKER) || !breeze_runs_here {
        return None;
    }
    // A profile under that name is somebody's own entry, whatever it points at.
    if config.profile(BREEZE_PROFILE_ID).is_some() {
        applied.insert(BREEZE_MARKER.to_owned());
        return None;
    }
    let binding = config.roles.get(&EndpointRole::Tts)?;
    let primary = config.profile(&binding.primary)?;
    if !is_setup_kokoro(primary) {
        // A voice the person chose leads. Marked, so that it is never second-guessed later.
        applied.insert(BREEZE_MARKER.to_owned());
        return None;
    }

    let kokoro = primary.id.clone();
    // The same server that serves Kokoro: one `mlx_audio.server` loads either model.
    let breeze = EndpointProfile::breeze(primary.url.clone());
    config.profiles.push(breeze);
    if let Some(binding) = config.roles.get_mut(&EndpointRole::Tts) {
        binding.fallback.retain(|name| *name != kokoro);
        binding.fallback.insert(0, kokoro);
        binding.primary = BREEZE_PROFILE_ID.to_owned();
    }
    applied.insert(BREEZE_MARKER.to_owned());
    Some(BREEZE_PROFILE_ID.to_owned())
}

/// The list of migrations this machine has already had, as it stands in [`MARKER_FILE`].
#[derive(Debug, Default)]
pub struct Applied {
    ids: BTreeSet<String>,
    /// True once something was added that is not on disk yet.
    dirty: bool,
}

impl Applied {
    /// Reads the list. A missing file is an empty list, and so is an unreadable one: the
    /// worst a wrong answer here can do is run an additive migration a second time, which is
    /// a far better failure than refusing to start.
    pub fn read(config_dir: &Path) -> Self {
        let path = Self::path(config_dir);
        let ids = match std::fs::read_to_string(&path) {
            Ok(text) => text
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_owned)
                .collect(),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => BTreeSet::new(),
            Err(error) => {
                warn!(path = %path.display(), %error, "cannot read the list of applied migrations");
                BTreeSet::new()
            }
        };
        Self { ids, dirty: false }
    }

    fn contains(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    fn insert(&mut self, id: String) {
        if self.ids.insert(id) {
            self.dirty = true;
        }
    }

    /// Writes the list back when something was added. A failure is logged and nothing else:
    /// the migration itself already succeeded, and refusing to start over the bookkeeping
    /// would be the worse trade.
    pub fn write(&self, config_dir: &Path) {
        if !self.dirty {
            return;
        }
        let path = Self::path(config_dir);
        let mut text = self.ids.iter().cloned().collect::<Vec<_>>().join("\n");
        text.push('\n');
        if let Err(error) = std::fs::write(&path, text) {
            warn!(path = %path.display(), %error, "cannot write the list of applied migrations");
        }
    }

    fn path(config_dir: &Path) -> PathBuf {
        config_dir.join(MARKER_FILE)
    }
}

/// Runs every migration over a document that was read from disk, and says whether it changed.
///
/// The caller writes the document back when this returns `true`, and only then.
/// `speech_server` is the server part of the same settings document, read only.
pub fn run(
    config_dir: &Path,
    endpoints: &mut EndpointConfig,
    speech_server: &VoiceServerSettings,
) -> bool {
    let voices = GermanVoices::on_this_machine(config_dir);
    let mut applied = Applied::read(config_dir);
    let mut changed = false;
    if let Some(id) = add_german_voice(endpoints, &voices, &mut applied) {
        info!(
            profile = %id,
            "added a German voice to the speech chain; the configuration had none and this \
             machine has one"
        );
        changed = true;
    }
    let breeze_runs_here = companion_voice::local_models::breeze_runs_here(speech_server);
    if let Some(id) = adopt_breeze(endpoints, breeze_runs_here, &mut applied) {
        info!(
            profile = %id,
            "made Breeze TTS 2 the voice for speaking, with Kokoro behind it; the chain was \
             led by the setup's Kokoro profile and this machine's speech server has the model"
        );
        changed = true;
    }
    if let Some(id) = bind_subagent_llm(endpoints, &mut applied) {
        info!(
            profile = %id,
            "bound the companion's helper model to the chat model's chain; the role was empty, \
             so web research and the shortening of long tool results had nothing to run on"
        );
        changed = true;
    }
    applied.write(config_dir);
    changed
}

#[cfg(test)]
mod tests {
    use super::*;
    use companion_protocol::{
        EndpointProtocol, PIPER_GERMAN_PROFILE_ID, RoleBinding, SAY_GERMAN_PROFILE_ID,
        SAY_PROFILE_ID,
    };

    fn kokoro_only() -> EndpointConfig {
        EndpointConfig::empty()
            .with_profile(EndpointProfile {
                language: Some("en".to_owned()),
                ..EndpointProfile::local(
                    "mlx-audio-tts",
                    EndpointProtocol::OpenaiCompat,
                    "http://127.0.0.1:8791",
                )
            })
            .with_profile(EndpointProfile::say())
            .with_role(
                EndpointRole::Tts,
                RoleBinding::new("mlx-audio-tts").with_fallback(SAY_PROFILE_ID),
            )
    }

    fn say_machine() -> GermanVoices {
        GermanVoices {
            has_say: true,
            ..GermanVoices::default()
        }
    }

    fn piper_machine() -> GermanVoices {
        GermanVoices {
            piper_program: Some("/usr/local/bin/piper".to_owned()),
            piper_model: Some("/tmp/de_DE-thorsten-high.onnx".to_owned()),
            has_say: true,
        }
    }

    fn chain(config: &EndpointConfig) -> Vec<String> {
        config
            .chain(EndpointRole::Tts)
            .iter()
            .map(|profile| profile.id.clone())
            .collect()
    }

    #[test]
    fn a_configuration_without_a_german_voice_gets_one() {
        let mut config = kokoro_only();
        let mut applied = Applied::default();
        let added = add_german_voice(&mut config, &say_machine(), &mut applied);

        assert_eq!(added.as_deref(), Some(SAY_GERMAN_PROFILE_ID));
        assert_eq!(
            chain(&config),
            vec!["mlx-audio-tts", SAY_PROFILE_ID, SAY_GERMAN_PROFILE_ID]
        );
        let profile = config.profile(SAY_GERMAN_PROFILE_ID).expect("just added");
        assert_eq!(profile.language.as_deref(), Some(GERMAN));
        assert_eq!(profile.voice.as_deref(), Some("Anna"));
        config.validate().expect("still a usable document");
    }

    #[test]
    fn nothing_the_person_configured_is_overwritten() {
        let before = kokoro_only();
        let mut config = before.clone();
        add_german_voice(&mut config, &say_machine(), &mut Applied::default());

        assert_eq!(
            config.profile("mlx-audio-tts"),
            before.profile("mlx-audio-tts"),
            "the primary is untouched"
        );
        assert_eq!(
            config.roles[&EndpointRole::Tts].primary,
            before.roles[&EndpointRole::Tts].primary
        );
        assert!(
            config.roles[&EndpointRole::Tts]
                .fallback
                .starts_with(&before.roles[&EndpointRole::Tts].fallback),
            "the fallbacks that were there keep their order"
        );
    }

    #[test]
    fn a_second_start_adds_nothing() {
        let mut config = kokoro_only();
        let mut applied = Applied::default();
        assert!(add_german_voice(&mut config, &say_machine(), &mut applied).is_some());
        let after_first = config.clone();

        assert_eq!(
            add_german_voice(&mut config, &say_machine(), &mut applied),
            None
        );
        assert_eq!(config, after_first, "idempotent");
    }

    #[test]
    fn a_profile_the_person_deleted_does_not_come_back() {
        let mut config = kokoro_only();
        let mut applied = Applied::default();
        add_german_voice(&mut config, &say_machine(), &mut applied);
        config
            .profiles
            .retain(|profile| profile.id != SAY_GERMAN_PROFILE_ID);
        config
            .roles
            .get_mut(&EndpointRole::Tts)
            .expect("tts is bound")
            .fallback
            .retain(|name| name != SAY_GERMAN_PROFILE_ID);

        assert_eq!(
            add_german_voice(&mut config, &say_machine(), &mut applied),
            None,
            "the marker says this migration already ran once"
        );
        assert!(config.profile(SAY_GERMAN_PROFILE_ID).is_none());
    }

    #[test]
    fn piper_goes_in_front_of_the_german_say_voice() {
        // Skryx-L-A's own machine on 2026-09-05: `say`'s `Anna` is in the chain from the
        // setup, and `piper` was installed afterwards.
        let mut config = kokoro_only();
        add_german_voice(&mut config, &say_machine(), &mut Applied::default());
        let mut applied = Applied::default();

        let added = add_german_voice(&mut config, &piper_machine(), &mut applied);
        assert_eq!(added.as_deref(), Some(PIPER_GERMAN_PROFILE_ID));
        assert_eq!(
            chain(&config),
            vec![
                "mlx-audio-tts",
                SAY_PROFILE_ID,
                PIPER_GERMAN_PROFILE_ID,
                SAY_GERMAN_PROFILE_ID
            ],
            "piper leads the German half, Anna stays behind it as the fallback"
        );
        config.validate().expect("still a usable document");
    }

    #[test]
    fn a_machine_with_no_german_voice_at_all_is_left_alone() {
        let mut config = kokoro_only();
        let before = config.clone();
        assert_eq!(
            add_german_voice(
                &mut config,
                &GermanVoices::default(),
                &mut Applied::default()
            ),
            None
        );
        assert_eq!(config, before);
    }

    #[test]
    fn a_document_with_no_speech_configured_stays_empty() {
        // Adding a voice here would switch speaking on for somebody who never set it up.
        let mut config = EndpointConfig::empty();
        assert_eq!(
            add_german_voice(&mut config, &piper_machine(), &mut Applied::default()),
            None
        );
        assert_eq!(config, EndpointConfig::empty());
    }

    /// The shape the setup assistant leaves behind on this machine: `claude` as the chat
    /// model over the subscription, and no helper model at all.
    fn chat_cli_only() -> EndpointConfig {
        EndpointConfig::empty()
            .with_profile(EndpointProfile {
                args: vec!["--safe-mode".to_owned()],
                ..EndpointProfile::local("claude-cli", EndpointProtocol::Cli, "/usr/bin/claude")
            })
            .with_role(EndpointRole::ChatLlm, RoleBinding::new("claude-cli"))
    }

    #[test]
    fn an_empty_helper_role_is_bound_to_the_chat_models_chain() {
        let mut config = chat_cli_only();
        let mut applied = Applied::default();

        let bound = bind_subagent_llm(&mut config, &mut applied);

        assert_eq!(bound.as_deref(), Some("claude-cli"));
        assert_eq!(
            config.roles[&EndpointRole::SubagentLlm],
            config.roles[&EndpointRole::ChatLlm],
            "the same chain, not a second profile"
        );
        config.validate().expect("still a usable document");
    }

    #[test]
    fn the_whole_chat_chain_comes_along_and_a_second_start_adds_nothing() {
        let mut config = chat_cli_only()
            .with_profile(EndpointProfile::local(
                "claude-fallback",
                EndpointProtocol::Cli,
                "/opt/homebrew/bin/claude",
            ))
            .with_role(
                EndpointRole::ChatLlm,
                RoleBinding::new("claude-cli").with_fallback("claude-fallback"),
            );
        let mut applied = Applied::default();
        assert!(bind_subagent_llm(&mut config, &mut applied).is_some());
        let after_first = config.clone();

        assert_eq!(
            config.roles[&EndpointRole::SubagentLlm].fallback,
            vec!["claude-fallback".to_owned()]
        );
        assert_eq!(bind_subagent_llm(&mut config, &mut applied), None);
        assert_eq!(config, after_first, "idempotent");
    }

    #[test]
    fn an_api_chat_model_leaves_the_helper_role_empty() {
        // Binding it here would produce a role that shortens tool results but still answers
        // every research question with the same refusal — `web_search_possible` says no to
        // anything but the `claude` CLI. No marker either, so a machine that gets the CLI
        // later still receives this migration.
        let mut config = EndpointConfig::empty()
            .with_profile(EndpointProfile::local(
                "chat-api",
                EndpointProtocol::OpenaiCompat,
                "http://127.0.0.1:8080",
            ))
            .with_role(EndpointRole::ChatLlm, RoleBinding::new("chat-api"));
        let mut applied = Applied::default();

        assert_eq!(bind_subagent_llm(&mut config, &mut applied), None);
        assert!(!config.roles.contains_key(&EndpointRole::SubagentLlm));

        let mut with_cli = chat_cli_only();
        assert!(
            bind_subagent_llm(&mut with_cli, &mut applied).is_some(),
            "the same marker list, and the migration is still owed to this machine"
        );
    }

    #[test]
    fn a_codex_chat_model_leaves_the_helper_role_empty() {
        let mut config = EndpointConfig::empty()
            .with_profile(EndpointProfile::local(
                "codex-cli",
                EndpointProtocol::Cli,
                "/usr/local/bin/codex",
            ))
            .with_role(EndpointRole::ChatLlm, RoleBinding::new("codex-cli"));

        assert_eq!(
            bind_subagent_llm(&mut config, &mut Applied::default()),
            None,
            "codex cannot be given web search, so it is not what this role is for"
        );
    }

    #[test]
    fn a_helper_role_the_person_chose_is_never_overwritten_or_restored() {
        let mut config = chat_cli_only().with_role(
            EndpointRole::SubagentLlm,
            RoleBinding::new("claude-cli").with_fallback("claude-cli"),
        );
        let chosen = config.roles[&EndpointRole::SubagentLlm].clone();
        let mut applied = Applied::default();

        assert_eq!(bind_subagent_llm(&mut config, &mut applied), None);
        assert_eq!(config.roles[&EndpointRole::SubagentLlm], chosen);

        // And once taken away on purpose, it stays away.
        config.roles.remove(&EndpointRole::SubagentLlm);
        assert_eq!(bind_subagent_llm(&mut config, &mut applied), None);
        assert!(!config.roles.contains_key(&EndpointRole::SubagentLlm));
    }

    #[test]
    fn a_document_with_no_chat_model_is_left_alone() {
        let mut config = kokoro_only();
        let before = config.clone();
        assert_eq!(
            bind_subagent_llm(&mut config, &mut Applied::default()),
            None
        );
        assert_eq!(config, before);
    }

    /// The TTS chain on Skryx-L-A's machine on 2026-09-10, as the setup assistant and the
    /// German-voice migration left it: Kokoro in front, the German voices behind it.
    fn kokoro_setup() -> EndpointConfig {
        EndpointConfig::empty()
            .with_profile(EndpointProfile {
                model: Some(KOKORO_MODEL.to_owned()),
                voice: Some("af_heart".to_owned()),
                language: Some("en".to_owned()),
                ..EndpointProfile::local(
                    "mlx-audio-tts",
                    EndpointProtocol::OpenaiCompat,
                    "http://127.0.0.1:8791",
                )
            })
            .with_profile(EndpointProfile::piper_german(
                "/usr/local/bin/piper",
                "/tmp/de_DE-thorsten-high.onnx",
            ))
            .with_profile(EndpointProfile::say_german())
            .with_profile(EndpointProfile::say())
            .with_role(
                EndpointRole::Tts,
                RoleBinding::new("mlx-audio-tts")
                    .with_fallback(PIPER_GERMAN_PROFILE_ID)
                    .with_fallback(SAY_GERMAN_PROFILE_ID)
                    .with_fallback(SAY_PROFILE_ID),
            )
    }

    #[test]
    fn breeze_takes_the_lead_over_the_setups_kokoro_where_it_runs() {
        let mut config = kokoro_setup();
        let mut applied = Applied::default();

        let adopted = adopt_breeze(&mut config, true, &mut applied);

        assert_eq!(adopted.as_deref(), Some(BREEZE_PROFILE_ID));
        assert_eq!(
            chain(&config),
            vec![
                BREEZE_PROFILE_ID,
                "mlx-audio-tts",
                PIPER_GERMAN_PROFILE_ID,
                SAY_GERMAN_PROFILE_ID,
                SAY_PROFILE_ID
            ],
            "Kokoro stays, right behind Breeze; the German half keeps its order"
        );
        let breeze = config.profile(BREEZE_PROFILE_ID).expect("just added");
        assert_eq!(
            breeze.url, "http://127.0.0.1:8791",
            "the server Kokoro is on"
        );
        assert_eq!(breeze.language.as_deref(), Some("en"));
        config.validate().expect("still a usable document");
    }

    #[test]
    fn a_machine_that_cannot_run_breeze_keeps_kokoro_and_is_offered_it_later() {
        let mut config = kokoro_setup();
        let before = config.clone();
        let mut applied = Applied::default();

        assert_eq!(adopt_breeze(&mut config, false, &mut applied), None);
        assert_eq!(config, before);

        assert_eq!(
            adopt_breeze(&mut config, true, &mut applied).as_deref(),
            Some(BREEZE_PROFILE_ID),
            "no marker was set, so the machine that got the model since is still owed it"
        );
    }

    #[test]
    fn a_voice_the_person_chose_stays_in_front() {
        let mut config = kokoro_setup();
        config
            .roles
            .insert(EndpointRole::Tts, RoleBinding::new(SAY_PROFILE_ID));
        let before = config.clone();
        let mut applied = Applied::default();

        assert_eq!(adopt_breeze(&mut config, true, &mut applied), None);
        assert_eq!(config, before);

        // Switching back to Kokoro later is a choice too, and it stays one.
        config
            .roles
            .insert(EndpointRole::Tts, RoleBinding::new("mlx-audio-tts"));
        assert_eq!(adopt_breeze(&mut config, true, &mut applied), None);
    }

    #[test]
    fn a_kokoro_profile_of_the_persons_own_stays_in_front() {
        // Same model as the setup's, but under a name and with a voice somebody picked.
        let own = |id: &str, voice: &str| EndpointProfile {
            model: Some(KOKORO_MODEL.to_owned()),
            voice: Some(voice.to_owned()),
            language: Some("en".to_owned()),
            ..EndpointProfile::local(id, EndpointProtocol::OpenaiCompat, "http://127.0.0.1:8791")
        };
        for profile in [
            own("mein-kokoro", "bf_emma"),
            own("mein-kokoro", "af_heart"),
        ] {
            let id = profile.id.clone();
            let mut config = kokoro_setup().with_profile(profile).with_role(
                EndpointRole::Tts,
                RoleBinding::new(id.clone()).with_fallback(SAY_PROFILE_ID),
            );
            let before = config.clone();
            assert_eq!(
                adopt_breeze(&mut config, true, &mut Applied::default()),
                None
            );
            assert_eq!(
                config, before,
                "{id} was chosen, not left behind by the setup"
            );
        }

        // The setup's own id with a voice the person changed afterwards is theirs too.
        let mut config = kokoro_setup();
        config
            .profiles
            .iter_mut()
            .find(|profile| profile.id == KOKORO_SETUP_ID)
            .expect("the setup profile")
            .voice = Some("bf_emma".to_owned());
        let before = config.clone();
        let mut applied = Applied::default();
        assert_eq!(adopt_breeze(&mut config, true, &mut applied), None);
        assert_eq!(config, before);
        assert!(
            applied.contains(BREEZE_MARKER),
            "decided once, so a later start does not second-guess it"
        );
    }

    #[test]
    fn breeze_taken_out_again_does_not_come_back() {
        let mut config = kokoro_setup();
        let mut applied = Applied::default();
        adopt_breeze(&mut config, true, &mut applied);
        config
            .profiles
            .retain(|profile| profile.id != BREEZE_PROFILE_ID);
        config.roles.insert(
            EndpointRole::Tts,
            RoleBinding::new("mlx-audio-tts").with_fallback(SAY_PROFILE_ID),
        );
        let after = config.clone();

        assert_eq!(adopt_breeze(&mut config, true, &mut applied), None);
        assert_eq!(config, after);
    }

    #[test]
    fn a_profile_already_called_breeze_is_the_persons_own() {
        let mut config = kokoro_setup().with_profile(EndpointProfile::local(
            BREEZE_PROFILE_ID,
            EndpointProtocol::OpenaiCompat,
            "http://127.0.0.1:9999",
        ));
        let before = config.clone();
        assert_eq!(
            adopt_breeze(&mut config, true, &mut Applied::default()),
            None
        );
        assert_eq!(config, before);
    }

    #[test]
    fn the_marker_file_survives_a_restart() {
        let directory =
            std::env::temp_dir().join(format!("companion-migrate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).expect("a temporary directory");

        let mut applied = Applied::read(&directory);
        let mut config = kokoro_only();
        assert!(add_german_voice(&mut config, &say_machine(), &mut applied).is_some());
        applied.write(&directory);

        let mut second_start = Applied::read(&directory);
        let mut untouched = kokoro_only();
        let added = add_german_voice(&mut untouched, &say_machine(), &mut second_start);
        let _ = std::fs::remove_dir_all(&directory);
        assert_eq!(
            added, None,
            "the list on disk is what makes this run once and not once per start"
        );
    }
}
