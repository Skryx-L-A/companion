// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! A second, fast opinion on how far-reaching an outward call is.
//!
//! The decision of 2026-10-09:
//! on `act` the companion sends without asking, and a typed decider may only add a question,
//! never grant anything. Level 4 (outward or irreversible: delete, push, publish, money)
//! stages the call and waits for the yes; level 3 is logged and runs; anything else, and every
//! failure of the decider, changes nothing. The fixed gates (`tool_boundary`, `autonomy`,
//! `NeedsConfirmation`) stay in front of this and are never lowered by it.
//!
//! The decider speaks the System-One wire API (`POST …/v1/systemone`, a `state` and typed
//! `questions`). Only an endpoint on this machine or the local network is accepted: the text
//! is what the companion is about to send to a session, and it does not leave the network.

use std::net::IpAddr;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};

/// How long a decision may take before the call goes its ordinary way.
pub const DECIDER_TIMEOUT: Duration = Duration::from_millis(1500);

/// The four levels, lowest first, in the words the measurement set was judged with.
const LEVELS: [&str; 4] = [
    "harmlos",
    "ändert Lokales umkehrbar",
    "schwer umkehrbar lokal",
    "nach außen wirksam oder unumkehrbar",
];

/// One opinion: how far-reaching is what `text` asks for, 1 to 4, or `None` if there is no
/// answer to be had. `None` must never be read as permission or as refusal.
#[async_trait]
pub trait ConsequenceDecider: Send + Sync {
    async fn level(&self, tool: &str, text: &str) -> Option<u8>;
}

/// A System-One endpoint on this machine or the local network.
pub struct SystemOneDecider {
    url: String,
    model: String,
    http: reqwest::Client,
}

impl SystemOneDecider {
    /// Refuses an endpoint outside the local network: the text it would see is what the
    /// companion is about to send to a session, and that stays at home.
    pub fn new(url: &str, model: &str) -> Result<Self, String> {
        let parsed = reqwest::Url::parse(url).map_err(|error| format!("{url}: {error}"))?;
        if !is_local_host(parsed.host_str().unwrap_or_default()) {
            return Err(format!(
                "{url} liegt nicht auf diesem Rechner oder im lokalen Netz; der Entscheider sieht \
                 Text, der das Netz nicht verlassen darf"
            ));
        }
        let http = reqwest::Client::builder()
            .timeout(DECIDER_TIMEOUT)
            .build()
            .map_err(|error| error.to_string())?;
        Ok(Self {
            url: url.to_owned(),
            model: model.to_owned(),
            http,
        })
    }
}

fn is_local_host(host: &str) -> bool {
    if host == "localhost" || host.ends_with(".local") {
        return true;
    }
    match host.trim_matches(['[', ']']).parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
        Ok(IpAddr::V6(ip)) => ip.is_loopback() || ip.is_unique_local(),
        // A bare host name without a dot is a machine of the local network (`workstation`).
        Err(_) => !host.is_empty() && !host.contains('.'),
    }
}

/// The request body for one decision.
pub fn request_body(model: &str, tool: &str, text: &str) -> Value {
    let redacted = companion_core::redact::secretish(text);
    json!({
        "model": model,
        "state": format!("Der Companion will das Werkzeug {tool} mit diesem Text aufrufen:\n{redacted}"),
        "questions": {
            "folgen": {
                "type": "score",
                "instructions": "Wie folgenreich ist, was hier verlangt wird? 1 harmlos, 2 ändert \
                                 Lokales umkehrbar, 3 schwer umkehrbar lokal, 4 nach außen \
                                 wirksam oder unumkehrbar (löschen, pushen, veröffentlichen, Geld).",
                "criteria": LEVELS,
            }
        }
    })
}

/// The level out of a System-One answer, 1 to 4.
pub fn level_from_answer(answer: &Value) -> Option<u8> {
    let score = answer
        .get("answers")?
        .get("folgen")?
        .get("score")?
        .as_f64()?;
    if !score.is_finite() || !(0.0..=3.0).contains(&score) {
        return None;
    }
    Some(score.round() as u8 + 1)
}

#[async_trait]
impl ConsequenceDecider for SystemOneDecider {
    async fn level(&self, tool: &str, text: &str) -> Option<u8> {
        let response = self
            .http
            .post(&self.url)
            .json(&request_body(&self.model, tool, text))
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        level_from_answer(&response.json::<Value>().await.ok()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_endpoints_of_this_network_are_accepted() {
        for url in [
            "http://127.0.0.1:8090/v1/systemone",
            "http://localhost:8090/v1/systemone",
            "http://192.168.1.20:8090/v1/systemone",
            "http://10.0.0.5/v1/systemone",
            "http://workstation:8090/v1/systemone",
            "http://[::1]:8090/v1/systemone",
        ] {
            assert!(SystemOneDecider::new(url, "local").is_ok(), "{url}");
        }
        for url in [
            "https://openrouter.ai/api/v1/systemone",
            "http://8.8.8.8/v1/systemone",
            "https://api.typesafe.ai/v1/systemone",
        ] {
            assert!(SystemOneDecider::new(url, "jev").is_err(), "{url}");
        }
    }

    #[test]
    fn the_level_is_read_from_the_score_and_nothing_else() {
        let answer =
            |score: Value| json!({"answers": {"folgen": {"type": "score", "score": score}}});
        assert_eq!(level_from_answer(&answer(json!(3.0))), Some(4));
        assert_eq!(level_from_answer(&answer(json!(2.0))), Some(3));
        assert_eq!(level_from_answer(&answer(json!(0.0))), Some(1));
        assert_eq!(level_from_answer(&answer(json!(7.0))), None);
        assert_eq!(level_from_answer(&answer(json!("4"))), None);
        assert_eq!(level_from_answer(&json!({"error": "x"})), None);
    }

    #[test]
    fn the_text_is_redacted_before_it_reaches_the_decider() {
        let body = request_body("m", "send_to_session", "push mit password=geheim123 bitte");
        let state = body["state"].as_str().unwrap();
        assert!(!state.contains("geheim123"), "{state}");
    }
}
