// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Where Claude Code keeps the transcript of a session.
//!
//! Claude Code writes one JSON line per event to
//! `~/.claude/projects/<slug of the working directory>/<session id>.jsonl`. Two adapters
//! need that address — the one that starts sessions itself and the one that watches the
//! workbench's — and they used to derive it with two different rules. Measured against the
//! 389 transcript directories on the machine this was written on, the rule here matches all
//! 389; the other one, which mapped only `/` and `.` to a dash, matched 358 and missed every
//! path containing an underscore. One rule, in one place, is what keeps that from happening
//! again.
//!
//! The rule is Claude Code's and not this program's, so a derived path that does not exist
//! is answered with a scan of the directory rather than with a guess, and with `None` when
//! the scan finds nothing either.

use std::path::{Path, PathBuf};

/// The directory name Claude Code derives from a working directory: every character that is
/// not an ASCII letter or digit becomes a dash.
pub fn slug_for(project: &str) -> String {
    project
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// How much of a candidate transcript is read to find out which directory it was written in.
/// The `cwd` sits on the first line that carries a message, well inside this.
const CWD_PROBE_BYTES: u64 = 64 * 1024;

/// Finds the transcript of a session under the projects directory.
///
/// Three steps, and every one of them ties the file to *this* project:
///
/// 1. The directory the slug rule derives from the project as it was given.
/// 2. The same, from the project with its symlinks resolved. On this machine `/tmp` is a link
///    to `/private/tmp`, and Claude Code files a session under the directory it really ran in
///    — so the two spellings of one path produce two different slugs, and the second is the
///    one on disk.
/// 3. A scan of every project directory, for the case the rule has changed or the session was
///    filed under a third spelling. A candidate found this way is accepted only if the
///    transcript itself says it was written in this project: the `cwd` Claude Code puts on its
///    own lines.
///
/// The third step used to take the first file of the right name in whatever order the
/// directory happened to be read in, with no tie to the project at all. Two projects that
/// carry the same session id — a copied conversation, a restored backup, a worktree of the
/// same repository — would then hand back each other's history, and neither the caller nor
/// the person reading it would see anything wrong with the answer.
///
/// A session id that carries a path separator is refused outright: the id regularly comes
/// from a file another process wrote, and `Path::join` would let `../` or an absolute id
/// leave the projects directory entirely. No session of Claude Code has such an id, so it is
/// no address here either.
pub fn find_transcript(projects_dir: &Path, project: &str, session_id: &str) -> Option<PathBuf> {
    if project.is_empty() || session_id.is_empty() {
        return None;
    }
    if session_id.contains('/') || session_id.contains('\\') {
        return None;
    }
    let file = format!("{session_id}.jsonl");

    let derived = projects_dir.join(slug_for(project)).join(&file);
    if derived.is_file() {
        return Some(derived);
    }

    let resolved = std::fs::canonicalize(project).ok();
    if let Some(resolved) = resolved.as_deref() {
        let derived = projects_dir
            .join(slug_for(&resolved.to_string_lossy()))
            .join(&file);
        if derived.is_file() {
            return Some(derived);
        }
    }

    let mut entries: Vec<PathBuf> = std::fs::read_dir(projects_dir)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .collect();
    // A directory listing has no promised order, and the answer must not depend on one.
    entries.sort();
    for directory in entries {
        let candidate = directory.join(&file);
        if candidate.is_file() && written_in(&candidate, project, resolved.as_deref()) {
            return Some(candidate);
        }
    }
    None
}

/// Whether a transcript says it was written in this project.
///
/// Claude Code puts the working directory on every line it writes for a message. The first
/// one that carries it decides; a file that names none is refused, because an unattributable
/// transcript is exactly the one that must not be handed to a caller who asked about a
/// particular project.
fn written_in(transcript: &Path, project: &str, resolved: Option<&Path>) -> bool {
    let Some(cwd) = first_cwd(transcript) else {
        return false;
    };
    if cwd == project {
        return true;
    }
    let Ok(cwd) = std::fs::canonicalize(&cwd) else {
        return false;
    };
    resolved.is_some_and(|resolved| cwd == resolved)
}

/// The first working directory a transcript names, out of its first [`CWD_PROBE_BYTES`].
fn first_cwd(transcript: &Path) -> Option<String> {
    let chunk = crate::jsonl_history::read_chunk(
        transcript,
        companion_protocol::ReadWindow::FromOffset { offset: 0 },
        CWD_PROBE_BYTES,
    )
    .ok()?;
    chunk.text.lines().find_map(|line| {
        serde_json::from_str::<serde_json::Value>(line)
            .ok()?
            .get("cwd")?
            .as_str()
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_slug_matches_what_claude_code_writes() {
        assert_eq!(
            slug_for("/Users/example/.claude/skills/agent-reach"),
            "-Users-example--claude-skills-agent-reach"
        );
        assert_eq!(
            slug_for("/private/tmp/companion-cli-probe"),
            "-private-tmp-companion-cli-probe"
        );
    }

    #[test]
    fn an_underscore_becomes_a_dash_like_every_other_character() {
        // Measured against the real transcript directories, with a stand-in user name here:
        // /Users/example/.pi-workers/worktrees/traum-m5/_meta/tools lives in
        // -Users-example--pi-workers-worktrees-traum-m5--meta-tools. A rule that mapped only
        // `/` and `.` produced `…-traum-m5-_meta-tools` and found nothing.
        assert_eq!(
            slug_for("/Users/example/.pi-workers/worktrees/traum-m5/_meta/tools/gardener"),
            "-Users-example--pi-workers-worktrees-traum-m5--meta-tools-gardener"
        );
    }

    #[test]
    fn a_session_id_that_is_a_path_is_no_address() {
        let dir = std::env::temp_dir().join(format!("companion-projects-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(find_transcript(&dir, "/tmp/x", "../../etc/passwd"), None);
        assert_eq!(find_transcript(&dir, "/tmp/x", "/etc/passwd"), None);
        assert_eq!(find_transcript(&dir, "", "session"), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A projects directory with one transcript per named project, each saying which working
    /// directory it was written in — the way Claude Code writes them.
    fn projects_with(name: &str, transcripts: &[(&str, &str, &str)]) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("companion-projects-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for (directory, session, cwd) in transcripts {
            let into = dir.join(directory);
            std::fs::create_dir_all(&into).unwrap();
            std::fs::write(
                into.join(format!("{session}.jsonl")),
                format!(
                    "{{\"type\":\"user\",\"cwd\":\"{cwd}\",\"message\":\
                     {{\"role\":\"user\",\"content\":\"hallo\"}}}}\n"
                ),
            )
            .unwrap();
        }
        dir
    }

    #[test]
    fn a_transcript_filed_under_another_slug_is_still_found_by_the_scan() {
        // The scan is what makes a session findable when the naming rule has moved on. What
        // it may not do is hand back somebody else's file, so the transcript has to say it
        // was written in the project that was asked about.
        let dir = projects_with("scan", &[("-somewhere-else", "s1", "/tmp/does/not/match")]);
        assert_eq!(
            find_transcript(&dir, "/tmp/does/not/match", "s1"),
            Some(dir.join("-somewhere-else/s1.jsonl"))
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_same_session_id_under_two_projects_stays_two_sessions() {
        // A copied conversation, a restored backup, a second worktree of one repository: the
        // id says nothing about which project it belongs to. Until 2026-09-03 the scan took
        // whichever file the directory listing offered first, so one project could be handed
        // the other's history with nothing in the answer to show it.
        let dir = projects_with(
            "two-projects",
            &[
                ("-aaa-first-slug", "shared", "/tmp/projekt-eins"),
                ("-zzz-second-slug", "shared", "/tmp/projekt-zwei"),
            ],
        );

        assert_eq!(
            find_transcript(&dir, "/tmp/projekt-eins", "shared"),
            Some(dir.join("-aaa-first-slug/shared.jsonl"))
        );
        assert_eq!(
            find_transcript(&dir, "/tmp/projekt-zwei", "shared"),
            Some(dir.join("-zzz-second-slug/shared.jsonl")),
            "the second project must not be given the first file merely because it sorts first"
        );
        assert_eq!(
            find_transcript(&dir, "/tmp/projekt-drei", "shared"),
            None,
            "a project neither transcript names gets neither"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_transcript_that_names_no_working_directory_is_not_attributed() {
        let dir = std::env::temp_dir().join(format!(
            "companion-projects-{}-anonymous",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let other = dir.join("-somewhere-else");
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(other.join("s1.jsonl"), "{}\n").unwrap();

        assert_eq!(
            find_transcript(&dir, "/tmp/does/not/match", "s1"),
            None,
            "a file that cannot say where it was written belongs to no project in particular"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_project_reached_through_a_symlink_is_found_under_its_real_name() {
        // The reason the scan exists at all: on this machine /tmp is a link to /private/tmp,
        // and Claude Code files a session under the directory it really ran in. Both
        // spellings of one path have to find the same transcript, and the resolved one does
        // it without reading a file.
        let real = std::env::temp_dir().join(format!("companion-real-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&real);
        std::fs::create_dir_all(&real).unwrap();
        let resolved = std::fs::canonicalize(&real).unwrap();

        let dir = projects_with(
            "symlinked",
            &[(
                slug_for(&resolved.to_string_lossy()).as_str(),
                "s1",
                resolved.to_string_lossy().as_ref(),
            )],
        );
        assert_eq!(
            find_transcript(&dir, real.to_string_lossy().as_ref(), "s1"),
            Some(
                dir.join(slug_for(&resolved.to_string_lossy()))
                    .join("s1.jsonl")
            ),
            "the spelling the caller used and the one on disk are the same directory"
        );
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&real);
    }
}
