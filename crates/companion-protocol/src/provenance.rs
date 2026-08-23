// SPDX-License-Identifier: AGPL-3.0-only

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// A value together with where it came from.
///
/// `DESIGN.md` § Session-Adapter requires every status field to carry its origin, and the
/// session list to show an unknown field as unknown rather than as empty or zero. Making
/// `Unknown` a variant without a payload is what enforces that: there is no value to
/// mistake for a measurement.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "origin", content = "value", rename_all = "snake_case")]
pub enum Provenance<T> {
    /// Read from a structured channel: a hook, a status file, an adapter report.
    Measured(T),
    /// Derived or guessed, for example a token count extrapolated from elapsed time.
    Estimated(T),
    /// The adapter cannot supply this field at all.
    Unknown,
}

/// The origin of a [`Provenance`] value without the value itself. Used where only the
/// quality of a field matters, for example in capability descriptions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    Measured,
    Estimated,
    Unknown,
}

impl<T> Provenance<T> {
    pub fn origin(&self) -> Origin {
        match self {
            Self::Measured(_) => Origin::Measured,
            Self::Estimated(_) => Origin::Estimated,
            Self::Unknown => Origin::Unknown,
        }
    }

    pub fn value(&self) -> Option<&T> {
        match self {
            Self::Measured(value) | Self::Estimated(value) => Some(value),
            Self::Unknown => None,
        }
    }

    pub fn is_unknown(&self) -> bool {
        matches!(self, Self::Unknown)
    }

    pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Provenance<U> {
        match self {
            Self::Measured(value) => Provenance::Measured(f(value)),
            Self::Estimated(value) => Provenance::Estimated(f(value)),
            Self::Unknown => Provenance::Unknown,
        }
    }
}

#[allow(
    clippy::derivable_impls,
    reason = "a derived Default would demand T: Default, which Unknown does not need"
)]
impl<T> Default for Provenance<T> {
    fn default() -> Self {
        Self::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measured_value_carries_its_origin() {
        let json = serde_json::to_string(&Provenance::Measured(42u32)).unwrap();
        assert_eq!(json, r#"{"origin":"measured","value":42}"#);
    }

    #[test]
    fn unknown_has_no_value_field() {
        let json = serde_json::to_string(&Provenance::<u32>::Unknown).unwrap();
        assert_eq!(json, r#"{"origin":"unknown"}"#);
    }

    #[test]
    fn unknown_never_decodes_into_a_number() {
        let parsed: Provenance<u32> = serde_json::from_str(r#"{"origin":"unknown"}"#).unwrap();
        assert!(parsed.is_unknown());
        assert_eq!(parsed.value(), None);
    }

    #[test]
    fn round_trips_through_json() {
        let value = Provenance::Estimated(7u64);
        let json = serde_json::to_string(&value).unwrap();
        let back: Provenance<u64> = serde_json::from_str(&json).unwrap();
        assert_eq!(value, back);
    }
}
