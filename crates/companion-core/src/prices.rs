// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What a thousand tokens cost, per model.
//!
//! `DESIGN.md` § Verhalten, "Kosten": "API-Preise bei Schluessel-Endpoints. Ohne Quelle
//! zeigt er unbekannt." A price is not something this program can measure — it is published
//! by a provider, it changes, and a number baked into a binary goes stale the day after the
//! release. So it lives in a file in the configuration directory that the person owns and
//! edits, seeded once with the prices that were published on the day named in each row.
//!
//! Two rules keep it honest:
//!
//! - A model that is not in the table has **no** price. Not a guessed one, not the price of
//!   a model whose name looks similar: the cost of that run stays
//!   [`companion_protocol::Provenance::Unknown`], which is what the register and the panel
//!   then show.
//! - Every row carries the date its numbers were read. A price without a date cannot be
//!   judged as current or stale by anybody looking at it later, and the whole point of the
//!   file is that a person can look at it.
//!
//! What a start does to an existing file (decision of 2026-10-09): rows the build ships and
//! the file lacks are appended with their date and the note "vom Daemon aus der Vorgabe
//! ergänzt"; rows the file has are never changed. One consequence is deliberate: a shipped
//! row that somebody deleted comes back at the next start. Whoever wants another price for
//! a shipped model changes its row instead of deleting it.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The file inside the configuration directory.
pub const PRICES_FILE: &str = "prices.json";

/// Schema version of the file, so a later shape can be told from this one.
pub const PRICES_SCHEMA_VERSION: u32 = 1;

/// What one model costs, per million tokens, in US dollars.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelPrice {
    /// The model id as the endpoint names it. Matched case-insensitively, and a row whose
    /// id is a prefix of the one asked about counts as a match when the rest is a build date
    /// or a bracketed variant, so `claude-sonnet-4-5` answers for `claude-sonnet-4-5-20250929`
    /// without a row per build date, and `claude-opus-5` does not answer for
    /// `claude-opus-5-5`.
    pub model: String,
    pub input_per_mtok_usd: f64,
    pub output_per_mtok_usd: f64,
    /// The day these two numbers were read from the provider, `YYYY-MM-DD`.
    pub dated: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// The whole table.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PriceTable {
    pub schema_version: u32,
    pub models: Vec<ModelPrice>,
}

impl Default for PriceTable {
    /// The rows this build ships with.
    ///
    /// List prices of the public APIs, per million tokens, each row dated to the day it was
    /// read. Deliberately short: a model whose price nobody here has checked is left out,
    /// because leaving it out means "unknown" and putting it in with a plausible number
    /// means a wrong figure in somebody's day counter.
    fn default() -> Self {
        let dated = "2026-09-05";
        // Read off platform.claude.com/docs/en/about-claude/pricing on this day. Haiku 5.5 is
        // left out on purpose: its price rises fivefold past 100 000 prompt tokens, and one
        // row per model cannot say that, so a single figure would be wrong for long prompts.
        let claude_five = "2026-10-09";
        Self {
            schema_version: PRICES_SCHEMA_VERSION,
            models: vec![
                ModelPrice {
                    model: "claude-opus-5-5".to_owned(),
                    input_per_mtok_usd: 4.0,
                    output_per_mtok_usd: 20.0,
                    dated: claude_five.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-opus-5".to_owned(),
                    input_per_mtok_usd: 5.0,
                    output_per_mtok_usd: 25.0,
                    dated: claude_five.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-sonnet-5-5".to_owned(),
                    input_per_mtok_usd: 2.0,
                    output_per_mtok_usd: 10.0,
                    dated: claude_five.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-sonnet-5".to_owned(),
                    input_per_mtok_usd: 2.0,
                    output_per_mtok_usd: 10.0,
                    dated: claude_five.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-fable-5-1".to_owned(),
                    input_per_mtok_usd: 10.0,
                    output_per_mtok_usd: 50.0,
                    dated: claude_five.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-fable-5".to_owned(),
                    input_per_mtok_usd: 10.0,
                    output_per_mtok_usd: 50.0,
                    dated: claude_five.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-haiku-4-5".to_owned(),
                    input_per_mtok_usd: 1.0,
                    output_per_mtok_usd: 5.0,
                    dated: dated.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-sonnet-4-5".to_owned(),
                    input_per_mtok_usd: 3.0,
                    output_per_mtok_usd: 15.0,
                    dated: dated.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "claude-opus-4-1".to_owned(),
                    input_per_mtok_usd: 15.0,
                    output_per_mtok_usd: 75.0,
                    dated: dated.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "gpt-4o-mini".to_owned(),
                    input_per_mtok_usd: 0.15,
                    output_per_mtok_usd: 0.6,
                    dated: dated.to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "gpt-4o".to_owned(),
                    input_per_mtok_usd: 2.5,
                    output_per_mtok_usd: 10.0,
                    dated: dated.to_owned(),
                    note: None,
                },
            ],
        }
    }
}

impl PriceTable {
    /// The price of one model, or nothing when the table does not name it.
    ///
    /// The longest matching row wins, so a specific entry beats a shorter prefix of it.
    pub fn price_for(&self, model: &str) -> Option<&ModelPrice> {
        let wanted = model.trim().to_ascii_lowercase();
        if wanted.is_empty() {
            return None;
        }
        self.models
            .iter()
            .filter(|row| {
                let id = row.model.trim().to_ascii_lowercase();
                !id.is_empty()
                    && wanted
                        .strip_prefix(id.as_str())
                        .is_some_and(is_build_of_the_same_model)
            })
            .max_by_key(|row| row.model.len())
    }

    /// What one exchange cost, or nothing when the model is not in the table.
    ///
    /// Nothing, not zero: a run whose price nobody knows has to read as unknown all the way
    /// out to the panel, and a zero would sum into a day counter as if it were free.
    pub fn cost_usd(&self, model: &str, input_tokens: u64, output_tokens: u64) -> Option<f64> {
        let row = self.price_for(model)?;
        let per_token = |tokens: u64, per_mtok: f64| tokens as f64 * per_mtok / 1_000_000.0;
        Some(
            per_token(input_tokens, row.input_per_mtok_usd)
                + per_token(output_tokens, row.output_per_mtok_usd),
        )
    }
}

/// Whether what follows a row's id names a build of that same model rather than another one.
///
/// A plain prefix is not enough since the Claude 5 family: `claude-opus-5` is a prefix of
/// `claude-opus-5-5`, a different model at a different price. What may follow is nothing, a
/// build date (`-20251001` as Anthropic writes it, `-2024-08-06` as OpenAI does) or a
/// bracketed variant such as `[1m]`.
fn is_build_of_the_same_model(rest: &str) -> bool {
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit());
    if rest.is_empty() || rest.starts_with('[') {
        return true;
    }
    let Some(date) = rest.strip_prefix('-') else {
        return false;
    };
    let date = date.split('[').next().unwrap_or_default();
    match date.split('-').collect::<Vec<_>>().as_slice() {
        [day] => day.len() == 8 && digits(day),
        [year, month, day] => {
            year.len() == 4
                && month.len() == 2
                && day.len() == 2
                && [year, month, day].iter().all(|part| digits(part))
        }
        _ => false,
    }
}

/// Where the table lives inside a configuration directory.
pub fn path_in(config_dir: &Path) -> PathBuf {
    config_dir.join(PRICES_FILE)
}

/// Reads the table, writing the shipped one first if there is no file yet.
///
/// A file that is there but does not parse is **not** replaced: it is somebody's edited
/// price list, and overwriting it would throw away work to fix a typo. The shipped table is
/// used for this run and the reason is returned alongside, so a caller can say so once
/// rather than silently pricing everything at the factory rates.
///
/// A file that parses gets the shipped rows it lacks, and only those (decision of
/// 2026-10-09): a model the build knows and the file does not name is appended with the date
/// its numbers were read, and every row the file already has stays exactly as it is, whatever
/// the build would say about it. The file is written only when something was added.
pub fn load_or_create(config_dir: &Path) -> (PriceTable, Option<String>) {
    let path = path_in(config_dir);
    match std::fs::read_to_string(&path) {
        Ok(text) => match serde_json::from_str::<PriceTable>(&text) {
            Ok(mut table) => {
                let added = add_missing_rows(&mut table, &PriceTable::default());
                if added.is_empty() {
                    return (table, None);
                }
                tracing::info!(rows = ?added, "price table: shipped rows added, none changed");
                let complaint = write(&path, &table).err().map(|error| {
                    format!(
                        "die ergänzte Preistabelle {} liess sich nicht schreiben: {error}",
                        path.display()
                    )
                });
                (table, complaint)
            }
            Err(error) => (
                PriceTable::default(),
                Some(format!(
                    "{} ist kein Preistabelle-JSON: {error}",
                    path.display()
                )),
            ),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let table = PriceTable::default();
            let complaint = write(&path, &table).err().map(|error| {
                format!(
                    "die Preistabelle {} liess sich nicht anlegen: {error}",
                    path.display()
                )
            });
            (table, complaint)
        }
        Err(error) => (
            PriceTable::default(),
            Some(format!("{} ist nicht zu lesen: {error}", path.display())),
        ),
    }
}

/// Appends the rows of `shipped` whose model `table` does not name (compared case-
/// insensitively), and returns their ids. Never touches a row that is there.
pub fn add_missing_rows(table: &mut PriceTable, shipped: &PriceTable) -> Vec<String> {
    let mut added = Vec::new();
    for row in &shipped.models {
        let known = table
            .models
            .iter()
            .any(|have| have.model.eq_ignore_ascii_case(&row.model));
        if !known {
            let mut row = row.clone();
            row.note
                .get_or_insert_with(|| "vom Daemon aus der Vorgabe ergänzt".to_owned());
            added.push(row.model.clone());
            table.models.push(row);
        }
    }
    added
}

/// Writes the table, owner-only, the way every other file of this program is written.
pub fn write(path: &Path, table: &PriceTable) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        crate::paths::ensure_private_dir(parent)?;
    }
    let text = serde_json::to_string_pretty(table)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    crate::paths::write_private_file(path, text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Decision of 2026-10-09: an existing file gets what it lacks, and keeps what it has —
    /// even a row the person changed, and even when the build would price it differently.
    #[test]
    fn a_file_gets_the_missing_rows_and_keeps_its_own() {
        let dir =
            std::env::temp_dir().join(format!("companion-prices-merge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let shipped = PriceTable::default();
        let first = shipped.models[0].clone();
        let mine = ModelPrice {
            input_per_mtok_usd: 99.0,
            note: Some("von Hand".to_owned()),
            ..first.clone()
        };
        let edited = PriceTable {
            schema_version: PRICES_SCHEMA_VERSION,
            models: vec![
                mine.clone(),
                ModelPrice {
                    model: "mein-eigenes-modell".to_owned(),
                    input_per_mtok_usd: 1.0,
                    output_per_mtok_usd: 2.0,
                    dated: "2026-01-01".to_owned(),
                    note: None,
                },
            ],
        };
        write(&path_in(&dir), &edited).unwrap();

        let (table, complaint) = load_or_create(&dir);
        assert_eq!(complaint, None);
        assert_eq!(table.models[0], mine, "the person's row stays as it was");
        assert_eq!(table.models[1].model, "mein-eigenes-modell");
        assert_eq!(
            table.models.len(),
            2 + shipped.models.len() - 1,
            "every other shipped row added"
        );
        for row in &table.models[2..] {
            let from = shipped
                .models
                .iter()
                .find(|s| s.model == row.model)
                .unwrap();
            assert_eq!(row.dated, from.dated, "with the date its numbers were read");
            assert_eq!(row.input_per_mtok_usd, from.input_per_mtok_usd);
        }
        let reread: PriceTable =
            serde_json::from_str(&std::fs::read_to_string(path_in(&dir)).unwrap()).unwrap();
        assert_eq!(reread, table, "and the file says so");

        // A second start adds nothing and writes nothing.
        let before = std::fs::metadata(path_in(&dir))
            .unwrap()
            .modified()
            .unwrap();
        let (again, _) = load_or_create(&dir);
        assert_eq!(again, table);
        assert_eq!(
            std::fs::metadata(path_in(&dir))
                .unwrap()
                .modified()
                .unwrap(),
            before
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_model_nobody_priced_costs_nothing_known() {
        let table = PriceTable::default();
        assert!(table.price_for("ein-modell-das-es-nicht-gibt").is_none());
        assert_eq!(
            table.cost_usd("ein-modell-das-es-nicht-gibt", 1000, 1000),
            None
        );
        // And the empty name is not a lookup at all.
        assert!(table.price_for("").is_none());
        assert!(table.price_for("   ").is_none());
    }

    #[test]
    fn a_dated_build_of_a_known_model_uses_that_models_row() {
        let table = PriceTable::default();
        let row = table
            .price_for("claude-haiku-4-5-20251001")
            .expect("the dated build resolves through the prefix");
        assert_eq!(row.model, "claude-haiku-4-5");
        // One million in, one million out.
        let cost = table
            .cost_usd("claude-haiku-4-5-20251001", 1_000_000, 1_000_000)
            .unwrap();
        assert!((cost - 6.0).abs() < 1e-9, "got {cost}");
    }

    #[test]
    fn the_longest_matching_row_wins() {
        let table = PriceTable {
            schema_version: PRICES_SCHEMA_VERSION,
            models: vec![
                ModelPrice {
                    model: "gpt-4o".to_owned(),
                    input_per_mtok_usd: 2.5,
                    output_per_mtok_usd: 10.0,
                    dated: "2026-09-05".to_owned(),
                    note: None,
                },
                ModelPrice {
                    model: "gpt-4o-mini".to_owned(),
                    input_per_mtok_usd: 0.15,
                    output_per_mtok_usd: 0.6,
                    dated: "2026-09-05".to_owned(),
                    note: None,
                },
            ],
        };
        assert_eq!(table.price_for("gpt-4o-mini").unwrap().model, "gpt-4o-mini");
        assert_eq!(table.price_for("gpt-4o").unwrap().model, "gpt-4o");
    }

    #[test]
    fn a_newer_model_of_the_same_family_is_not_priced_as_the_older_one() {
        let table = PriceTable::default();
        assert_eq!(
            table.price_for("claude-opus-5-5").unwrap().model,
            "claude-opus-5-5"
        );
        assert_eq!(
            table.price_for("claude-opus-5").unwrap().model,
            "claude-opus-5"
        );
        assert_eq!(
            table.price_for("claude-opus-5-20260801").unwrap().model,
            "claude-opus-5",
            "a build date is the same model"
        );
        assert_eq!(
            table.price_for("claude-opus-5[1m]").unwrap().model,
            "claude-opus-5"
        );
        assert_eq!(
            table.price_for("gpt-4o-2024-08-06").unwrap().model,
            "gpt-4o"
        );
        // A model nobody priced yet stays unknown instead of inheriting its elder's price.
        assert!(table.price_for("claude-opus-5-7").is_none());
        assert!(table.price_for("claude-haiku-5-5").is_none());
        assert!(table.price_for("claude-haiku-4-5-mini").is_none());
    }

    #[test]
    fn every_shipped_row_carries_the_day_it_was_read() {
        for row in PriceTable::default().models {
            assert!(
                row.dated.len() == 10 && row.dated.chars().filter(|c| *c == '-').count() == 2,
                "{} has no readable date: {}",
                row.model,
                row.dated
            );
        }
    }

    #[test]
    fn the_file_is_written_once_and_read_back_unchanged() {
        let dir = std::env::temp_dir().join(format!("companion-prices-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (first, complaint) = load_or_create(&dir);
        assert!(complaint.is_none(), "{complaint:?}");
        assert!(path_in(&dir).exists(), "the file is laid down on first use");

        // Somebody edits it; the next read takes their numbers, not the shipped ones. Since
        // 2026-10-09 it also gets the shipped rows it lacks, after the person's own.
        let mine = PriceTable {
            schema_version: PRICES_SCHEMA_VERSION,
            models: vec![ModelPrice {
                model: "mein-modell".to_owned(),
                input_per_mtok_usd: 1.0,
                output_per_mtok_usd: 2.0,
                dated: "2026-09-05".to_owned(),
                note: None,
            }],
        };
        write(&path_in(&dir), &mine).unwrap();
        let (second, complaint) = load_or_create(&dir);
        assert!(complaint.is_none(), "{complaint:?}");
        assert_eq!(second.models[0], mine.models[0]);
        assert_eq!(second.models.len(), 1 + first.models.len());
        assert_ne!(second, first);

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_broken_file_is_reported_and_never_overwritten() {
        let dir =
            std::env::temp_dir().join(format!("companion-prices-broken-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        crate::paths::ensure_private_dir(&dir).unwrap();
        std::fs::write(path_in(&dir), b"{ kaputt").unwrap();

        let (table, complaint) = load_or_create(&dir);
        assert_eq!(table, PriceTable::default(), "this run falls back");
        assert!(complaint.is_some(), "and says so");
        assert_eq!(
            std::fs::read_to_string(path_in(&dir)).unwrap(),
            "{ kaputt",
            "somebody's edited file stays as it is"
        );

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
