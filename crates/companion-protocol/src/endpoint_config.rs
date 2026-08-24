// SPDX-License-Identifier: AGPL-3.0-only

//! Which endpoint serves which role, and in what order.
//!
//! `DESIGN.md` § Endpoints: every role points at a provider profile with a protocol, a URL
//! and a key from the keychain, and the person may name a fallback per role. Local, Peer
//! and cloud are only different URLs, so there is nothing here that knows about machines.
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_ref: Option<String>,
    /// Model this profile uses. `DESIGN.md` § Endpoints wants the settings page to show it
    /// for every profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Fixed arguments for a CLI profile, in front of whatever the driver adds.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
}

impl EndpointProfile {
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
            args: Vec::new(),
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
            url: "/usr/bin/say".to_owned(),
            key_ref: None,
            model: None,
            args: Vec::new(),
        }
    }
}

/// Id of the built-in `say` profile.
pub const SAY_PROFILE_ID: &str = "macos-say";

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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
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

    /// Checks the configuration before anything uses it.
    pub fn validate(&self) -> Result<(), EndpointError> {
        let mut seen: Vec<&str> = Vec::new();
        for profile in &self.profiles {
            if profile.id.trim().is_empty() {
                return Err(EndpointError::NamelessProfile {
                    id: profile.url.clone(),
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
            if !profile.protocol.is_cli() && url_has_userinfo(&profile.url) {
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
            args: Vec::new(),
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
        profile.key_ref = Some("sk-proj-0123456789abcdef".to_owned());
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
            args: Vec::new(),
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
}
