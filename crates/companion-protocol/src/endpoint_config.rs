// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Which endpoint serves which role, and in what order.
//!
//! `DESIGN.md` § Endpoints: every role points at a provider profile with a protocol, a URL
//! and a key from the keychain, and the person may name a fallback per role. Local, a second
//! machine on the network and cloud are only different URLs, so there is nothing here that
//! knows about machines.
//!
//! This is the endpoint half of the settings document, and it lives in the protocol crate
//! for the same reason [`crate::Settings`] does: `get_settings` and `set_settings` put it
//! on the wire.
//!
//! The one rule this module enforces rather than documents: a profile never carries a key,
//! only the *name* of one ([`EndpointProfile::key_ref`]). There is no field a key could go
//! into, and a name that looks like a key is refused by [`EndpointConfig::validate`], so a
//! settings file that leaked a key would have to be built by hand and would still not load.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::endpoint::{EndpointProtocol, EndpointRole};

/// Longest name a key may have. Long enough for `openai-cloud`, far short of any key.
const MAX_KEY_REF_LEN: usize = 64;

/// Prefixes real keys are known to start with. A `key_ref` that starts with one of them is
/// somebody pasting a key where a name belongs, and that is worth an error rather than a
/// silent success that writes the key into the settings file.
const KEY_LOOKING_PREFIXES: [&str; 6] = ["sk-", "sk_", "pk-", "ghp_", "xoxb-", "AIza"];

/// One provider profile: how to reach a backend, and under which name its key lives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct EndpointProfile {
    /// Name the role bindings and the settings page use.
    pub id: String,
    pub protocol: EndpointProtocol,
    /// Base URL for a protocol that speaks HTTP, for example
    /// `http://127.0.0.1:8765`. For [`EndpointProtocol::Cli`] it is the absolute path of
    /// the program instead.
    pub url: String,
    /// Name under which the key lives in the the secret store of the daemon, never the
    /// key itself. Absent for a local endpoint that needs none.
    ///
    /// Since 2026-09-03 this name is the profile's own [`Self::id`] and nothing else — see
    /// [`Self::key_name`] for why, and [`EndpointConfig::borrowed_keys`] for what refuses a
    /// document that says otherwise. The field stays because it is what says *whether* a
    /// profile needs a key at all, and because a configuration written before that date is
    /// migrated by reading it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_ref: Option<String>,
    /// Model this profile uses. `DESIGN.md` § Endpoints wants the settings page to show it
    /// for every profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Voice this profile speaks with, when the caller names none.
    ///
    /// A speech endpoint has its own set of voice names, and the OpenAI ones are not
    /// among them: Kokoro, the local default here, knows `af_heart` and refuses `alloy`
    /// mid-answer. That belongs next to the model, for the same reason the model does —
    /// which voices exist is a property of the profile, not of the sentence being spoken.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice: Option<String>,
    /// Fixed arguments for a CLI profile, in front of whatever the driver adds.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// The spoken language this profile is good at, as a lowercase ISO code (`"de"`).
    ///
    /// `DESIGN.md` § Voice ties language to the model, not to the app, so this is the one
    /// place that says which language a TTS profile actually speaks well. Absent for a
    /// profile that was never told — Kokoro's `af_heart` reads any text handed to it, German
    /// included, just badly, and nothing here claims otherwise on its behalf. The TTS role
    /// chain uses it to move a matching profile to the front for a sentence detected as that
    /// language; a profile nobody tagged keeps its configured place.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// How much a reasoning model may think before it writes the answer, as the
    /// OpenAI-compatible `reasoning_effort` field. Absent for every profile that never asked
    /// for it, and then nothing is sent at all.
    ///
    /// Opt-in for the same reason `stream_options.include_usage` is not sent: a server that
    /// does not know a field answers the whole request with 400, and a chat that fails over
    /// a knob nobody set would be the worse trade. Measured 2026-09-05 on this machine, both
    /// local servers behind `wb-modell-proxy`: without it, `qwen3.8-27b` over
    /// `mlx_vlm.server` and `ornith:9b` over Ollama spend their whole answer in
    /// `reasoning_content`/`reasoning`, which this protocol does not carry — the person sees
    /// a first token after 30 seconds, or none at all. With `"none"` the first visible token
    /// arrives after half a second on the 9B. It is a string rather than an enum because the
    /// set of accepted values belongs to the server, not to this program.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
}

impl EndpointProfile {
    /// The name this profile's key lives under in the secret store, or `None` when it needs
    /// none.
    ///
    /// The name is the profile's own id, never a name a profile may point at freely. A free
    /// name is what let a profile borrow the key of another one: whoever could write the
    /// settings wrote `{"id": "meins", "url": "https://angreifer.example", "key_ref":
    /// "openai"}`, bound a role to it, and the daemon sent the OpenAI key to that address as
    /// a bearer token. With the name tied to the id, a profile can only ever present the key
    /// that was stored for it, and a new profile has no key at all until somebody stores one
    /// under its name.
    ///
    /// This is the second lock, not the first: since the same day, a paired device cannot
    /// change the endpoints at all ([`crate::Settings::device_forbidden_changes`]). This one
    /// holds whoever writes the file.
    pub fn key_name(&self) -> Option<&str> {
        self.key_ref.as_ref().map(|_| self.id.as_str())
    }

    /// An HTTP profile without a key: a local server.
    pub fn local(
        id: impl Into<String>,
        protocol: EndpointProtocol,
        url: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            protocol,
            url: url.into(),
            key_ref: None,
            model: None,
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        }
    }

    /// The `say` program of macOS as a TTS profile.
    ///
    /// This is the fallback `DESIGN.md` § Voice needs so that a machine with no configured
    /// endpoint can still speak: it is on every Mac, it needs no key and it never leaves
    /// the machine, which is why it can be a default while a cloud endpoint cannot.
    pub fn say() -> Self {
        Self {
            id: SAY_PROFILE_ID.to_owned(),
            protocol: EndpointProtocol::Cli,
            url: SAY_PROGRAM.to_owned(),
            key_ref: None,
            model: None,
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        }
    }

    /// The same program with the German voice macOS ships installed, tagged `de`.
    ///
    /// Kokoro-82M, the local default for speaking, has no German phonemes at all and reads
    /// German text in one of the eight languages it does know. Measured on 2026-09-05 over a
    /// TTS-to-speech-recognition round trip, three German sentences: 63 per cent of the words
    /// came back wrong through Kokoro's `af_heart` against 11 per cent through this voice.
    /// [`PIPER_GERMAN_PROFILE_ID`] is better still where it is installed.
    pub fn say_german() -> Self {
        Self {
            id: SAY_GERMAN_PROFILE_ID.to_owned(),
            protocol: EndpointProtocol::Cli,
            url: SAY_PROGRAM.to_owned(),
            key_ref: None,
            model: None,
            voice: Some(SAY_GERMAN_VOICE.to_owned()),
            args: Vec::new(),
            language: Some(GERMAN.to_owned()),
            reasoning_effort: None,
        }
    }

    /// `piper` with a German voice model, tagged `de`.
    ///
    /// An optional install (the program plus a downloaded `.onnx` model), never something
    /// every machine has, which is why the caller passes both paths rather than this
    /// guessing them. Measured the same way as [`Self::say_german`]: 7 per cent of the words
    /// wrong against that profile's 11, and both of the remaining errors were the speech
    /// recogniser writing "5" for "fünf" rather than anything the voice got wrong.
    pub fn piper_german(program: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            id: PIPER_GERMAN_PROFILE_ID.to_owned(),
            protocol: EndpointProtocol::Cli,
            url: program.into(),
            key_ref: None,
            model: Some(model.into()),
            voice: None,
            args: Vec::new(),
            language: Some(GERMAN.to_owned()),
            reasoning_effort: None,
        }
    }

    /// Breeze TTS 2 on the local speech server at `url`, tagged `en`.
    ///
    /// The default voice for speaking since 2026-09-10, Skryx-L-A's decision. Served by
    /// `mlx_audio.server` (mlx-audio 0.5.1 or newer; the model arrived there on 2026-08-26)
    /// from the MLX conversion [`BREEZE_MODEL`], and spoken with Breeze's own default
    /// speaker tag [`BREEZE_VOICE`]: without it the server forwards a Kokoro voice name.
    ///
    /// English and not German: the model card lists English and Chinese only, so a German
    /// sentence is left to the German profiles, which language-aware routing moves to the
    /// front for it. The measurement behind both choices is in
    /// `shell/messungen/breezetts2/ergebnisse.md` of the private repository.
    pub fn breeze(url: impl Into<String>) -> Self {
        Self {
            id: BREEZE_PROFILE_ID.to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            url: url.into(),
            key_ref: None,
            model: Some(BREEZE_MODEL.to_owned()),
            voice: Some(BREEZE_VOICE.to_owned()),
            args: Vec::new(),
            language: Some(ENGLISH.to_owned()),
            reasoning_effort: None,
        }
    }
}

/// Id of the Breeze TTS 2 profile. Written by `companion_daemon::migrate::adopt_breeze`; the
/// Mac setup assistant does not know it yet and keeps writing Kokoro, which that migration
/// then puts behind Breeze on the daemon's next start.
pub const BREEZE_PROFILE_ID: &str = "breeze-tts";
/// The MLX conversion of Breeze TTS 2 the profile loads, as a Hugging Face repository id.
///
/// The 4-bit weights and not the 8-bit ones, by the house rule that the smaller one wins
/// when it is not measurably worse and faster: on 2026-09-10, quiet machine, three English
/// sentences each, 0 of 60 words wrong for both, real-time factor 0.83 against 0.89, and
/// 6.3 against 7.6 GiB of peak memory.
pub const BREEZE_MODEL: &str = "mlx-community/Breeze-TTS-2-mlx-4bit";
/// Breeze's documented default speaker tag.
pub const BREEZE_VOICE: &str = "S0";
/// The language code an English profile carries.
pub const ENGLISH: &str = "en";

/// Id of the built-in `say` profile.
pub const SAY_PROFILE_ID: &str = "macos-say";
/// Id of the German `say` profile, kept apart from the plain fallback above. Mirrored on the
/// Swift side as `LocalSpeechSetup.sayDeId`, the same way [`SAY_PROFILE_ID`] is: the setup
/// assistant writes this profile for a new machine and `companion_daemon::migrate` adds it to
/// an older one, and the two agree on the name by literal.
pub const SAY_GERMAN_PROFILE_ID: &str = "macos-say-de";
/// Id of the `piper` profile with a German voice model. Mirrored as
/// `LocalSpeechSetup.piperId`, for the same reason.
pub const PIPER_GERMAN_PROFILE_ID: &str = "piper-de";
/// The `say` program of macOS.
pub const SAY_PROGRAM: &str = "/usr/bin/say";
/// The German voice macOS ships installed by default (`de_DE`, `say -v '?'`).
pub const SAY_GERMAN_VOICE: &str = "Anna";
/// The language code the German profiles carry, as [`EndpointProfile::language`] spells it.
pub const GERMAN: &str = "de";

/// Which profile serves a role, and which ones to try when it fails.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RoleBinding {
    pub primary: String,
    /// Tried in order after the primary one failed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fallback: Vec<String>,
}

impl RoleBinding {
    pub fn new(primary: impl Into<String>) -> Self {
        Self {
            primary: primary.into(),
            fallback: Vec::new(),
        }
    }

    pub fn with_fallback(mut self, id: impl Into<String>) -> Self {
        self.fallback.push(id.into());
        self
    }

    /// Primary first, then the fallbacks, each name once.
    fn order(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.primary.as_str())
            .chain(self.fallback.iter().map(String::as_str))
            .scan(Vec::new(), |seen, name| {
                if seen.contains(&name) {
                    return Some(None);
                }
                seen.push(name);
                Some(Some(name))
            })
            .flatten()
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum EndpointError {
    #[error("two endpoint profiles are called {id}")]
    DuplicateProfile { id: String },
    #[error("profile {id} has no id")]
    NamelessProfile { id: String },
    #[error("profile {id} has no url")]
    MissingUrl { id: String },
    #[error("role {role} points at {id}, and there is no profile of that name")]
    UnknownProfile { role: &'static str, id: String },
    #[error(
        "profile {id} puts the key itself where the name of a keychain entry belongs; \
         store the key under a name and put that name here"
    )]
    KeyInSettings { id: String },
    #[error("profile {id} is a cli profile and cli profiles use no key")]
    KeyOnCliProfile { id: String },
    #[error(
        "profile {id} carries a credential in its url; a key belongs in the keychain under a \
         name, not in the address, where it would land in logs and error events"
    )]
    CredentialInUrl { id: String },
    #[error("no endpoint is configured for role {role}")]
    NoEndpoint { role: &'static str },
}

/// The endpoint part of the settings: the profiles, and which role uses which of them.
///
/// The schema deliberately advertises the empty configuration as the default, not the one
/// `Default::default` builds: that one depends on the operating system the daemon runs on
/// (see below), and a generated schema that changes with its build host is not a contract.
/// What a given daemon actually starts with is a runtime matter and reaches the client in
/// `settings_get`, never through a schema annotation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
#[schemars(default = "EndpointConfig::empty")]
pub struct EndpointConfig {
    pub profiles: Vec<EndpointProfile>,
    pub roles: BTreeMap<EndpointRole, RoleBinding>,
}

impl Default for EndpointConfig {
    /// Nothing but what is already on the machine.
    ///
    /// On macOS that is `say` for TTS, so the voice pipeline has one working half out of
    /// the box. STT has no such local default: whisper.cpp is not part of the delivery, and
    /// a cloud endpoint would send audio off the machine, which `DESIGN.md` § Voice makes a
    /// deliberate choice and never a default.
    fn default() -> Self {
        let mut roles = BTreeMap::new();
        let mut profiles = Vec::new();
        if cfg!(target_os = "macos") {
            profiles.push(EndpointProfile::say());
            roles.insert(EndpointRole::Tts, RoleBinding::new(SAY_PROFILE_ID));
        }
        Self { profiles, roles }
    }
}

impl EndpointConfig {
    /// An empty configuration, for a test that wants to name every profile itself.
    pub fn empty() -> Self {
        Self {
            profiles: Vec::new(),
            roles: BTreeMap::new(),
        }
    }

    pub fn with_profile(mut self, profile: EndpointProfile) -> Self {
        self.profiles.push(profile);
        self
    }

    pub fn with_role(mut self, role: EndpointRole, binding: RoleBinding) -> Self {
        self.roles.insert(role, binding);
        self
    }

    pub fn profile(&self, id: &str) -> Option<&EndpointProfile> {
        self.profiles.iter().find(|profile| profile.id == id)
    }

    /// The profiles to try for a role, in order.
    ///
    /// Empty when the role has no binding. A name that no profile answers to is skipped
    /// rather than fatal: the chain is what the daemon works with at runtime, and refusing
    /// to speak because the third fallback was renamed would be the wrong trade.
    /// [`Self::validate`] is where such a name is reported.
    pub fn chain(&self, role: EndpointRole) -> Vec<&EndpointProfile> {
        let Some(binding) = self.roles.get(&role) else {
            return Vec::new();
        };
        binding.order().filter_map(|id| self.profile(id)).collect()
    }

    /// The first profile of a role, or an error naming the role that has none.
    pub fn primary(&self, role: EndpointRole) -> Result<&EndpointProfile, EndpointError> {
        self.chain(role)
            .into_iter()
            .next()
            .ok_or(EndpointError::NoEndpoint {
                role: role.as_str(),
            })
    }

    /// Every profile that is reachable from a role binding, each one once.
    pub fn bound_profiles(&self) -> Vec<&EndpointProfile> {
        let mut kept: Vec<&EndpointProfile> = Vec::new();
        for role in EndpointRole::ALL {
            for profile in self.chain(role) {
                if !kept.iter().any(|already| already.id == profile.id) {
                    kept.push(profile);
                }
            }
        }
        kept
    }

    /// The profiles that name somebody else's key, each in one line.
    ///
    /// Empty for a configuration in which every key belongs to the profile that uses it,
    /// which is what [`EndpointProfile::key_name`] enforces at the point of use. This is the
    /// same rule stated where a *change* can be refused with a reason, so a document that
    /// borrows a key is turned away at `set_settings` instead of quietly resolving to
    /// nothing later.
    ///
    /// Deliberately not part of [`Self::validate`]: a settings file written before
    /// 2026-09-03 may legitimately hold a borrowed-looking name, and it has to load so that
    /// `companion_core::secrets::bind_keys_to_profiles` can move the key over. A daemon that
    /// refused to start over it would take somebody's speech away to close a hole that
    /// [`EndpointProfile::key_name`] has already closed.
    pub fn borrowed_keys(&self) -> Vec<String> {
        self.profiles
            .iter()
            .filter_map(|profile| {
                let named = profile.key_ref.as_deref()?;
                (named != profile.id).then(|| {
                    format!(
                        "profile {} names the key {named}, and a key belongs to the profile it \
                         was stored for; store it under {} instead",
                        profile.id, profile.id
                    )
                })
            })
            .collect()
    }

    /// Checks the configuration before anything uses it.
    pub fn validate(&self) -> Result<(), EndpointError> {
        let mut seen: Vec<&str> = Vec::new();
        for profile in &self.profiles {
            if profile.id.trim().is_empty() {
                // The url stands in for the missing name, so a person can tell which entry
                // of their file is meant. Shortened, because this message reaches a client
                // over the socket and a url is where somebody puts a key by accident.
                return Err(EndpointError::NamelessProfile {
                    id: crate::url::without_credentials(&profile.url),
                });
            }
            if seen.contains(&profile.id.as_str()) {
                return Err(EndpointError::DuplicateProfile {
                    id: profile.id.clone(),
                });
            }
            seen.push(&profile.id);

            if profile.url.trim().is_empty() {
                return Err(EndpointError::MissingUrl {
                    id: profile.id.clone(),
                });
            }
            if !profile.protocol.is_cli()
                && (url_has_userinfo(&profile.url) || url_has_query_credential(&profile.url))
            {
                return Err(EndpointError::CredentialInUrl {
                    id: profile.id.clone(),
                });
            }
            if let Some(key_ref) = &profile.key_ref {
                if profile.protocol.is_cli() {
                    return Err(EndpointError::KeyOnCliProfile {
                        id: profile.id.clone(),
                    });
                }
                if !is_name_not_key(key_ref) {
                    return Err(EndpointError::KeyInSettings {
                        id: profile.id.clone(),
                    });
                }
            }
        }

        for (role, binding) in &self.roles {
            for id in binding.order() {
                if self.profile(id).is_none() {
                    return Err(EndpointError::UnknownProfile {
                        role: role.as_str(),
                        id: id.to_owned(),
                    });
                }
            }
        }
        Ok(())
    }
}

/// Whether a string is the name of a keychain entry rather than a key.
///
/// The test is deliberately narrow: a short name from a small alphabet, and none of the
/// prefixes real keys announce themselves with. It cannot recognise every key, and it does
/// not have to — it has to catch the one mistake that actually happens, which is pasting
/// the key into the settings file where the name belongs.
/// Whether an HTTP url carries a `user:pass@` (or `user@`) credential in its authority.
///
/// Such a credential would be sent on every request and would surface verbatim in logs and
/// error events. Keys belong in the keychain under a name, so a url that hides one is
/// refused. The check looks only at the authority — the part between `://` and the next
/// `/`, `?` or `#` — so an `@` inside a path or query does not trip it.
fn url_has_userinfo(url: &str) -> bool {
    let after_scheme = match url.split_once("://") {
        Some((_, rest)) => rest,
        None => url,
    };
    let authority = after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(after_scheme);
    authority.contains('@')
}

/// Whether a url's query string carries a parameter that is actually a credential —
/// `key`, `api_key`, `token` or `access_token` — the query-string counterpart of the
/// userinfo credential [`url_has_userinfo`] already refuses.
///
/// Some providers accept the key this way (`?key=…`), and unlike a header it survives every
/// place a url gets logged or quoted back in an error: the `reqwest` error a failed request
/// produces names its own url, and that error reaches every authenticated client over the
/// socket (audit 2026-09-03, `endpoint_config.rs:319-326`).
///
/// The names live in [`crate::url::is_credential_parameter`], next to the repair that takes
/// them out again (`companion_core::settings::migrate_url_credentials`): a name refused here
/// but not repaired there would keep a daemon with an older settings file from starting.
fn url_has_query_credential(url: &str) -> bool {
    let Some((_, query)) = url.split_once('?') else {
        return false;
    };
    let query = query.split('#').next().unwrap_or(query);
    query.split('&').any(crate::url::is_credential_parameter)
}

fn is_name_not_key(candidate: &str) -> bool {
    if candidate.is_empty() || candidate.len() > MAX_KEY_REF_LEN {
        return false;
    }
    if KEY_LOOKING_PREFIXES
        .iter()
        .any(|prefix| candidate.starts_with(prefix))
    {
        return false;
    }
    candidate
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn openai(id: &str) -> EndpointProfile {
        EndpointProfile {
            id: id.to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            url: format!("https://{id}.example"),
            key_ref: Some(format!("{id}-key")),
            model: Some("whisper-1".to_owned()),
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        }
    }

    #[test]
    fn a_chain_is_the_primary_then_the_fallbacks_in_order() {
        let config = EndpointConfig::empty()
            .with_profile(openai("cloud"))
            .with_profile(EndpointProfile::local(
                "local",
                EndpointProtocol::WhisperServer,
                "http://127.0.0.1:8765",
            ))
            .with_role(
                EndpointRole::Stt,
                RoleBinding::new("local").with_fallback("cloud"),
            );

        let chain: Vec<&str> = config
            .chain(EndpointRole::Stt)
            .iter()
            .map(|profile| profile.id.as_str())
            .collect();
        assert_eq!(chain, vec!["local", "cloud"]);
        assert_eq!(config.primary(EndpointRole::Stt).unwrap().id, "local");
    }

    #[test]
    fn a_role_without_a_binding_has_an_empty_chain_and_says_so() {
        let config = EndpointConfig::empty();
        assert!(config.chain(EndpointRole::Stt).is_empty());
        assert_eq!(
            config.primary(EndpointRole::Stt),
            Err(EndpointError::NoEndpoint { role: "stt" })
        );
    }

    #[test]
    fn a_name_that_appears_twice_in_a_chain_is_tried_once() {
        let config = EndpointConfig::empty()
            .with_profile(openai("cloud"))
            .with_role(
                EndpointRole::Tts,
                RoleBinding::new("cloud")
                    .with_fallback("cloud")
                    .with_fallback("cloud"),
            );
        assert_eq!(config.chain(EndpointRole::Tts).len(), 1);
    }

    #[test]
    fn a_key_in_the_settings_is_refused_instead_of_stored() {
        let mut profile = openai("cloud");
        profile.key_ref = Some(concat!("sk-", "EXAMPLE0123456789abcd").to_owned());
        let config = EndpointConfig::empty().with_profile(profile);
        assert_eq!(
            config.validate(),
            Err(EndpointError::KeyInSettings {
                id: "cloud".to_owned()
            })
        );
    }

    #[test]
    fn a_long_random_string_is_not_taken_for_a_name() {
        let mut profile = openai("cloud");
        profile.key_ref = Some("a".repeat(MAX_KEY_REF_LEN + 1));
        let config = EndpointConfig::empty().with_profile(profile);
        assert!(matches!(
            config.validate(),
            Err(EndpointError::KeyInSettings { .. })
        ));
    }

    #[test]
    fn a_cli_profile_carries_no_key() {
        let mut profile = EndpointProfile::say();
        profile.key_ref = Some("some-name".to_owned());
        let config = EndpointConfig::empty().with_profile(profile);
        assert_eq!(
            config.validate(),
            Err(EndpointError::KeyOnCliProfile {
                id: SAY_PROFILE_ID.to_owned()
            })
        );
    }

    #[test]
    fn a_binding_that_names_nothing_is_reported() {
        let config = EndpointConfig::empty()
            .with_profile(openai("cloud"))
            .with_role(EndpointRole::Stt, RoleBinding::new("nowhere"));
        assert_eq!(
            config.validate(),
            Err(EndpointError::UnknownProfile {
                role: "stt",
                id: "nowhere".to_owned()
            })
        );
    }

    #[test]
    fn a_key_hidden_in_the_url_is_refused() {
        let profile = EndpointProfile {
            id: "cloud".to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            url: "https://user:sk-secret@api.example.com/v1".to_owned(),
            key_ref: None,
            model: None,
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        };
        let config = EndpointConfig::empty().with_profile(profile);
        assert_eq!(
            config.validate(),
            Err(EndpointError::CredentialInUrl {
                id: "cloud".to_owned()
            })
        );
    }

    #[test]
    fn an_at_sign_in_a_path_is_not_taken_for_a_credential() {
        assert!(!url_has_userinfo("http://127.0.0.1:8765/models/@latest"));
        assert!(!url_has_userinfo("http://127.0.0.1:8765/"));
        assert!(url_has_userinfo("https://user:pass@host/v1"));
        assert!(url_has_userinfo("https://token@host"));
    }

    /// Table-driven: each row names a query string and whether it must be refused as a
    /// credential — `endpoint_config.rs:319-326` in the audit of 2026-09-03.
    #[test]
    fn a_credential_in_the_query_string_is_recognised_regardless_of_name_or_position() {
        let cases: &[(&str, bool)] = &[
            (
                "https://api.example.com/v1?key=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ012",
                true,
            ),
            ("https://api.example.com/v1?api_key=abc123", true),
            ("https://api.example.com/v1?API_KEY=abc123", true),
            ("https://api.example.com/v1?token=abc123", true),
            ("https://api.example.com/v1?access_token=abc123", true),
            (
                "https://api.example.com/v1?model=gpt&access_token=abc123",
                true,
            ),
            (
                "https://api.example.com/v1?access_token=abc123&model=gpt",
                true,
            ),
            ("https://api.example.com/v1?model=gpt-4&stream=true", false),
            ("https://api.example.com/v1", false),
            ("https://api.example.com/v1?", false),
        ];
        for (url, expected) in cases {
            assert_eq!(url_has_query_credential(url), *expected, "url: {url}");
        }
    }

    #[test]
    fn a_query_credential_is_refused_the_same_way_a_userinfo_one_is() {
        let profile = EndpointProfile {
            id: "cloud".to_owned(),
            protocol: EndpointProtocol::OpenaiCompat,
            url: "https://api.example.com/v1?key=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ012".to_owned(),
            key_ref: None,
            model: None,
            voice: None,
            args: Vec::new(),
            language: None,
            reasoning_effort: None,
        };
        let config = EndpointConfig::empty().with_profile(profile);
        assert_eq!(
            config.validate(),
            Err(EndpointError::CredentialInUrl {
                id: "cloud".to_owned()
            })
        );
    }

    #[test]
    fn two_profiles_of_the_same_name_are_refused() {
        let config = EndpointConfig::empty()
            .with_profile(openai("cloud"))
            .with_profile(openai("cloud"));
        assert_eq!(
            config.validate(),
            Err(EndpointError::DuplicateProfile {
                id: "cloud".to_owned()
            })
        );
    }

    #[test]
    fn the_default_configuration_validates_and_sends_no_audio_away() {
        let config = EndpointConfig::default();
        config.validate().expect("the defaults must be usable");
        assert!(
            config.chain(EndpointRole::Stt).is_empty(),
            "no default speech recognition, because every one of them would be a cloud call"
        );
        if cfg!(target_os = "macos") {
            let tts = config.chain(EndpointRole::Tts);
            assert_eq!(tts.len(), 1);
            assert_eq!(tts[0].protocol, EndpointProtocol::Cli);
            assert!(tts[0].key_ref.is_none());
        }
    }

    #[test]
    fn the_breeze_profile_is_a_local_english_voice_on_the_speech_server() {
        let profile = EndpointProfile::breeze("http://127.0.0.1:8791");
        assert_eq!(profile.id, BREEZE_PROFILE_ID);
        assert_eq!(profile.protocol, EndpointProtocol::OpenaiCompat);
        assert_eq!(profile.model.as_deref(), Some(BREEZE_MODEL));
        // Breeze's own speaker tag, never the Kokoro or OpenAI default a server would fill in.
        assert_eq!(profile.voice.as_deref(), Some(BREEZE_VOICE));
        // The model card lists English and Chinese, no German: a German sentence must not be
        // routed here.
        assert_eq!(profile.language.as_deref(), Some(ENGLISH));
        assert!(profile.key_ref.is_none(), "a local server needs no key");

        let config = EndpointConfig::empty()
            .with_profile(profile)
            .with_profile(EndpointProfile::say())
            .with_role(
                EndpointRole::Tts,
                RoleBinding::new(BREEZE_PROFILE_ID).with_fallback(SAY_PROFILE_ID),
            );
        config.validate().expect("a usable document");
        assert_eq!(
            config.primary(EndpointRole::Tts).unwrap().id,
            BREEZE_PROFILE_ID
        );
    }

    #[test]
    fn the_configuration_survives_a_round_trip_through_the_settings_file() {
        let config = EndpointConfig::empty()
            .with_profile(openai("cloud"))
            .with_role(
                EndpointRole::ChatLlm,
                RoleBinding::new("cloud").with_fallback("cloud"),
            );
        let json = serde_json::to_string(&config).unwrap();
        assert!(
            json.contains("\"chat_llm\""),
            "role names stay readable: {json}"
        );
        let back: EndpointConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back, config);
    }

    #[test]
    fn bound_profiles_lists_each_profile_once() {
        let config = EndpointConfig::empty()
            .with_profile(openai("cloud"))
            .with_profile(openai("other"))
            .with_role(EndpointRole::Stt, RoleBinding::new("cloud"))
            .with_role(
                EndpointRole::Tts,
                RoleBinding::new("cloud").with_fallback("other"),
            );
        let names: Vec<&str> = config
            .bound_profiles()
            .iter()
            .map(|profile| profile.id.as_str())
            .collect();
        assert_eq!(names, vec!["cloud", "other"]);
    }

    #[test]
    fn a_profile_can_only_present_the_key_that_was_stored_for_it() {
        // The attack this closes: a profile that names the key of another one, pointed at
        // an address of the attacker's choosing. Before 2026-09-03 the lookup used the name
        // in the document, so this profile would have been handed the OpenAI key.
        let mut borrowing = openai("meins");
        borrowing.url = "https://angreifer.example".to_owned();
        borrowing.key_ref = Some("cloud".to_owned());
        assert_eq!(borrowing.key_name(), Some("meins"));

        let mut honest = openai("cloud");
        honest.key_ref = Some("cloud".to_owned());
        assert_eq!(honest.key_name(), Some("cloud"));

        // No key at all stays no key: a local server gets no Authorization header.
        let local = EndpointProfile::local("lokal", EndpointProtocol::Ollama, "http://127.0.0.1");
        assert_eq!(local.key_name(), None);

        // And such a document is turned away where a change can be refused with a reason.
        let config = EndpointConfig::empty()
            .with_profile(honest)
            .with_profile(borrowing);
        let complaints = config.borrowed_keys();
        assert_eq!(complaints.len(), 1, "{complaints:?}");
        assert!(complaints[0].contains("meins"), "{complaints:?}");

        let mut bound = openai("allein");
        bound.key_ref = Some("allein".to_owned());
        assert!(
            EndpointConfig::empty()
                .with_profile(bound)
                .borrowed_keys()
                .is_empty()
        );
    }
}
