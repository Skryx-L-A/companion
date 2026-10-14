// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! `companion skills install|uninstall` — the skill pack installer.
//!
//! `DESIGN.md` § Skill-Paket: the installer only ever adds to an existing configuration and
//! never overwrites content it did not put there itself; every install has a matching
//! uninstall, and every skill carries a version. The pack's files (`skills/` at the
//! repository root) are compiled into this library with `include_str!`, so an installed
//! `companion` needs no checkout of the repository sitting next to it to run this command.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;

use companion_protocol::SkillLevel;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const USAGE: &str = "\
companion skills — install or remove the companion skill pack in a coding-agent harness

  companion skills install --harness <claude|agents> [--level recommended|many|all] [--target <dir>]
  companion skills uninstall --harness <claude|agents> [--target <dir>]
  companion skills help

Installing only ever adds: a skill directory (or AGENTS.md section) that is already there
and was not put there by an earlier install of this pack is left alone, with a message.
Uninstalling removes only what an earlier install of this pack wrote, and only where the
content still has the hash that install recorded — anything changed by hand since is left
in place.

--harness claude targets the skills directory of Claude Code (default ~/.claude/skills).
--harness agents targets a project's AGENTS.md (default ./AGENTS.md) and writes one marked,
idempotent section into it, never touching the rest of the file.
--level chooses the tier from DESIGN.md § Skill-Paket; recommended is the default, and is
also what many and all install until the pack ships a first reviewed extension.
";

const AGENTS_MD_START: &str = "<!-- companion-skills:start -->";
const AGENTS_MD_END: &str = "<!-- companion-skills:end -->";
const MANIFEST_FILE_NAME: &str = ".companion-skills.json";

thread_local! { static QUIET: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }

macro_rules! emit {
    ($($arg:tt)*) => {
        QUIET.with(|quiet| { if !quiet.get() { println!($($arg)*); } });
    };
}

struct Quiet;
impl Quiet {
    fn new() -> Self {
        QUIET.with(|quiet| quiet.set(true));
        Self
    }
}
impl Drop for Quiet {
    fn drop(&mut self) {
        QUIET.with(|quiet| quiet.set(false));
    }
}

/// One skill of the pack, embedded at compile time out of `skills/<name>/SKILL.md`.
struct EmbeddedSkill {
    name: &'static str,
    content: &'static str,
}

const EMBEDDED_SKILLS: &[EmbeddedSkill] = &[
    EmbeddedSkill {
        name: "companion-protocol",
        content: include_str!("../../../../skills/companion-protocol/SKILL.md"),
    },
    EmbeddedSkill {
        name: "loop-kit",
        content: include_str!("../../../../skills/loop-kit/SKILL.md"),
    },
    EmbeddedSkill {
        name: "reviewer-pass",
        content: include_str!("../../../../skills/reviewer-pass/SKILL.md"),
    },
    EmbeddedSkill {
        name: "session-handoff",
        content: include_str!("../../../../skills/session-handoff/SKILL.md"),
    },
    EmbeddedSkill {
        name: "spec-first",
        content: include_str!("../../../../skills/spec-first/SKILL.md"),
    },
];

const PACK_MANIFEST_JSON: &str = include_str!("../../../../skills/manifest.json");

#[derive(Debug, Deserialize)]
struct PackManifest {
    package_version: String,
    skills: Vec<PackSkillEntry>,
}

#[derive(Debug, Deserialize)]
struct PackSkillEntry {
    name: String,
    version: String,
    tier: SkillLevel,
}

static PACK_MANIFEST: LazyLock<PackManifest> = LazyLock::new(|| {
    serde_json::from_str(PACK_MANIFEST_JSON)
        .expect("skills/manifest.json embedded at build time is valid JSON")
});

/// The manifest an install writes at the target, and an uninstall reads back.
#[derive(Debug, Default, Serialize, Deserialize)]
struct TargetManifest {
    package_version: String,
    #[serde(default)]
    level: SkillLevel,
    installed_at_ms: u64,
    /// Present for `--harness claude`: one entry per installed skill directory.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    skills: BTreeMap<String, SkillEntry>,
    /// Present for `--harness agents`: the one marked section in `AGENTS.md`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agents_md: Option<AgentsMdEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
struct SkillEntry {
    version: String,
    /// File path relative to the skill's own directory, to its sha256 hex digest.
    files: BTreeMap<String, String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct AgentsMdEntry {
    sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Harness {
    Claude,
    Agents,
}

impl Harness {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "claude" => Ok(Self::Claude),
            "agents" => Ok(Self::Agents),
            other => Err(format!("no such harness {other} (want claude or agents)")),
        }
    }

    fn default_target(self) -> PathBuf {
        match self {
            // Claude Code reads skills out of a fixed directory in the person's home.
            Self::Claude => companion_core::paths::home_dir()
                .join(".claude")
                .join("skills"),
            // AGENTS.md is per project; the natural default is the directory `companion`
            // is run from, not a fixed home-relative path.
            Self::Agents => PathBuf::from("."),
        }
    }
}

fn parse_level(value: &str) -> Result<SkillLevel, String> {
    serde_json::from_value(serde_json::Value::String(value.to_owned()))
        .map_err(|_| format!("no such skill level {value} (want none, recommended, many or all)"))
}

fn tier_rank(level: SkillLevel) -> u8 {
    match level {
        SkillLevel::None => 0,
        SkillLevel::Recommended => 1,
        SkillLevel::Many => 2,
        SkillLevel::All => 3,
    }
}

/// The embedded skills belonging to a level: every skill whose own tier is at or below the
/// requested level. `--level none` resolves to nothing, since no skill ships at tier none.
fn skills_for_level(level: SkillLevel) -> Vec<&'static EmbeddedSkill> {
    PACK_MANIFEST
        .skills
        .iter()
        .filter(|entry| tier_rank(entry.tier) <= tier_rank(level))
        .filter_map(|entry| {
            EMBEDDED_SKILLS
                .iter()
                .find(|skill| skill.name == entry.name)
        })
        .collect()
}

fn skill_version(name: &str) -> &'static str {
    PACK_MANIFEST
        .skills
        .iter()
        .find(|entry| entry.name == name)
        .map(|entry| entry.version.as_str())
        .unwrap_or("0.0.0")
}

struct InstallOptions {
    harness: Harness,
    level: SkillLevel,
    target: Option<PathBuf>,
}

impl InstallOptions {
    fn parse(arguments: &[String], require_harness: bool) -> Result<Self, String> {
        let mut harness = None;
        let mut level = SkillLevel::Recommended;
        let mut target = None;
        let mut iterator = arguments.iter();
        while let Some(argument) = iterator.next() {
            match argument.as_str() {
                "--harness" => {
                    let value = iterator
                        .next()
                        .ok_or_else(|| "--harness needs a value".to_owned())?;
                    harness = Some(Harness::parse(value)?);
                }
                "--level" => {
                    let value = iterator
                        .next()
                        .ok_or_else(|| "--level needs a value".to_owned())?;
                    level = parse_level(value)?;
                }
                "--target" => {
                    let value = iterator
                        .next()
                        .ok_or_else(|| "--target needs a value".to_owned())?;
                    target = Some(PathBuf::from(value));
                }
                other => return Err(format!("no option {other}\n\n{USAGE}")),
            }
        }
        let harness = match harness {
            Some(harness) => harness,
            None if require_harness => {
                return Err(format!("--harness is required\n\n{USAGE}"));
            }
            None => Harness::Claude,
        };
        Ok(Self {
            harness,
            level,
            target,
        })
    }
}

fn install(arguments: &[String]) -> Result<(), String> {
    let options = InstallOptions::parse(arguments, true)?;
    let target = options
        .target
        .clone()
        .unwrap_or_else(|| options.harness.default_target());
    if options.level == SkillLevel::None {
        return match options.harness {
            Harness::Claude => uninstall_claude(&target),
            Harness::Agents => uninstall_agents(&target),
        };
    }
    let skills = skills_for_level(options.level);

    match options.harness {
        Harness::Claude => install_claude(&target, &skills, options.level),
        Harness::Agents => install_agents(&target, &skills, options.level),
    }
}

fn manifest_path(target: &Path) -> PathBuf {
    target.join(MANIFEST_FILE_NAME)
}

fn load_manifest(path: &Path) -> Result<Option<TargetManifest>, String> {
    match fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).map(Some).map_err(|error| {
            format!(
                "{} does not read as a companion manifest: {error}",
                path.display()
            )
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("cannot read {}: {error}", path.display())),
    }
}

fn write_manifest(path: &Path, manifest: &TargetManifest) -> Result<(), String> {
    let mut text = serde_json::to_string_pretty(manifest).map_err(|error| error.to_string())?;
    text.push('\n');
    fs::write(path, text).map_err(|error| format!("cannot write {}: {error}", path.display()))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// True when `path` itself is a symlink. `Path::exists` and `fs::metadata` follow symlinks,
/// so neither of them can answer this question.
fn is_symlink(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.file_type().is_symlink()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(format!("cannot look at {}: {error}", path.display())),
    }
}

/// Resolves `<target>/<name>` for one entry of the manifest at the target, and refuses
/// everything that is not a plain child directory of `target`.
///
/// The names come out of `.companion-skills.json`, a file that merely sits at the target —
/// we did not necessarily write it. Without this check `target.join(name)` happily follows a
/// name like `../../victim`, and `uninstall` then calls `remove_dir_all` outside `--target`.
/// A single component that is neither `.`, `..` nor a root keeps the join inside the
/// canonicalised target by construction; a symlink at that spot is refused as well, because
/// removing or writing through it would again act somewhere else.
fn resolve_skill_dir(target: &Path, name: &str) -> Result<Option<PathBuf>, String> {
    let mut components = Path::new(name).components();
    let one_plain_component =
        matches!(components.next(), Some(Component::Normal(_))) && components.next().is_none();
    if !one_plain_component {
        return Ok(None);
    }
    let Ok(anchor) = target.canonicalize() else {
        return Ok(None);
    };
    let skill_dir = anchor.join(name);
    if is_symlink(&skill_dir)? {
        return Ok(None);
    }
    Ok(Some(skill_dir))
}

fn install_claude(
    target: &Path,
    skills: &[&'static EmbeddedSkill],
    level: SkillLevel,
) -> Result<(), String> {
    if is_symlink(target)? {
        return Err(format!("skill target {} is a symlink", target.display()));
    }
    fs::create_dir_all(target)
        .map_err(|error| format!("cannot create {}: {error}", target.display()))?;
    let path = manifest_path(target);
    let mut manifest = load_manifest(&path)?.unwrap_or_default();

    let mut installed = Vec::new();
    let mut skipped = Vec::new();
    let mut symlinked = Vec::new();

    for skill in skills {
        let skill_dir = target.join(skill.name);
        let already_ours = manifest.skills.contains_key(skill.name);
        if skill_dir.exists() && !already_ours {
            skipped.push(skill.name);
            continue;
        }
        // `exists()` above follows symlinks, and so do `create_dir_all` and `fs::write`
        // below: a symlink named like one of our skills — or a `SKILL.md` symlink inside a
        // directory the manifest already counts as ours — would otherwise make the install
        // write the skill text through it into any file the user can reach. In doubt we
        // skip and say so, rather than write.
        if is_symlink(&skill_dir)? || is_symlink(&skill_dir.join("SKILL.md"))? {
            symlinked.push(skill.name);
            continue;
        }
        fs::create_dir_all(&skill_dir)
            .map_err(|error| format!("cannot create {}: {error}", skill_dir.display()))?;
        let file_path = skill_dir.join("SKILL.md");
        fs::write(&file_path, skill.content)
            .map_err(|error| format!("cannot write {}: {error}", file_path.display()))?;

        let mut files = BTreeMap::new();
        files.insert("SKILL.md".to_owned(), sha256_hex(skill.content.as_bytes()));
        manifest.skills.insert(
            skill.name.to_owned(),
            SkillEntry {
                version: skill_version(skill.name).to_owned(),
                files,
            },
        );
        installed.push(skill.name);
    }

    manifest.package_version = PACK_MANIFEST.package_version.clone();
    manifest.level = level;
    manifest.installed_at_ms = companion_core::now_ms();
    write_manifest(&path, &manifest)?;

    report_install(target, &installed, &skipped, &symlinked);
    Ok(())
}

fn report_install(target: &Path, installed: &[&str], skipped: &[&str], symlinked: &[&str]) {
    if installed.is_empty() && skipped.is_empty() && symlinked.is_empty() {
        emit!("Level none: nothing to install.");
        return;
    }
    if !installed.is_empty() {
        emit!(
            "Installed into {}: {}",
            target.display(),
            installed.join(", ")
        );
    }
    if !skipped.is_empty() {
        emit!(
            "Left alone, already there and not from this pack: {}",
            skipped.join(", ")
        );
    }
    if !symlinked.is_empty() {
        emit!(
            "Left alone, a symlink is in the way and writing would go through it: {}",
            symlinked.join(", ")
        );
    }
}

fn agents_block(skills: &[&'static EmbeddedSkill]) -> String {
    let mut block = String::new();
    block.push_str(AGENTS_MD_START);
    block.push('\n');
    block.push_str(
        "<!-- Generated by `companion skills install --harness agents`. Everything between\n     these two markers is replaced on every install; nothing else in this file is\n     touched. Run `companion skills uninstall --harness agents` to remove it again. -->\n",
    );
    for skill in skills {
        block.push('\n');
        block.push_str("## ");
        block.push_str(skill.name);
        block.push_str(" (v");
        block.push_str(skill_version(skill.name));
        block.push_str(")\n\n");
        block.push_str(strip_frontmatter(skill.content).trim_end());
        block.push('\n');
    }
    block.push('\n');
    block.push_str(AGENTS_MD_END);
    block.push('\n');
    block
}

/// The body of a `SKILL.md` without its YAML frontmatter: the frontmatter's `name` and
/// `description` are metadata for a skills directory, not prose an `AGENTS.md` reader wants.
fn strip_frontmatter(content: &str) -> &str {
    if !content.starts_with("---\n") {
        return content;
    }
    let mut offset = 4;
    let mut found_close = false;
    for line in content[offset..].split_inclusive('\n') {
        offset += line.len();
        if line.trim_end_matches('\n') == "---" {
            found_close = true;
            break;
        }
    }
    if !found_close {
        return content;
    }
    content[offset..].trim_start_matches('\n')
}

/// Finds the byte range of an existing marked section, markers included.
fn find_block(content: &str) -> Result<Option<(usize, usize)>, String> {
    let start = content.find(AGENTS_MD_START);
    // `agents_block` always ends the marker line with exactly one `\n`; folding that
    // newline into `end` here makes `content[start..end]` equal to a freshly built block
    // byte for byte, which is what the install-time hash is taken over.
    let end = content.find(AGENTS_MD_END).map(|index| {
        let after_marker = index + AGENTS_MD_END.len();
        if content[after_marker..].starts_with('\n') {
            after_marker + 1
        } else {
            after_marker
        }
    });
    match (start, end) {
        (Some(start), Some(end)) if start < end => Ok(Some((start, end))),
        (None, None) => Ok(None),
        _ => Err(
            "AGENTS.md has only one of the companion-skills markers; fix it by hand before installing or uninstalling"
                .to_owned(),
        ),
    }
}

fn install_agents(
    target: &Path,
    skills: &[&'static EmbeddedSkill],
    level: SkillLevel,
) -> Result<(), String> {
    if is_symlink(target)? || is_symlink(&target.join("AGENTS.md"))? {
        return Err(format!(
            "AGENTS.md target {} is a symlink",
            target.display()
        ));
    }
    fs::create_dir_all(target)
        .map_err(|error| format!("cannot create {}: {error}", target.display()))?;
    let agents_path = target.join("AGENTS.md");
    let existing = match fs::read_to_string(&agents_path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(format!("cannot read {}: {error}", agents_path.display())),
    };

    if skills.is_empty() {
        // `none` follows the same manifest and hash checks as explicit uninstall.
        return uninstall_agents(target);
    }

    let manifest_path = manifest_path(target);
    let mut manifest = load_manifest(&manifest_path)?.unwrap_or_default();
    if let Some((start, end)) = find_block(&existing)? {
        match &manifest.agents_md {
            Some(entry) if sha256_hex(&existing.as_bytes()[start..end]) == entry.sha256 => {}
            Some(_) => {
                return Err(
                    "AGENTS.md companion-skills section was edited; leaving it alone".to_owned(),
                );
            }
            None => {
                return Err(
                    "AGENTS.md already has an untracked companion-skills section; leaving it alone"
                        .to_owned(),
                );
            }
        }
    }
    let block = agents_block(skills);
    let new_content = match find_block(&existing)? {
        Some((start, end)) => {
            let mut content = String::with_capacity(existing.len() - (end - start) + block.len());
            content.push_str(&existing[..start]);
            content.push_str(&block);
            content.push_str(&existing[end..]);
            content
        }
        None => {
            let mut content = existing.clone();
            if !content.is_empty() && !content.ends_with('\n') {
                content.push('\n');
            }
            if !content.is_empty() {
                content.push('\n');
            }
            content.push_str(&block);
            content
        }
    };
    fs::write(&agents_path, &new_content)
        .map_err(|error| format!("cannot write {}: {error}", agents_path.display()))?;

    manifest.package_version = PACK_MANIFEST.package_version.clone();
    manifest.level = level;
    manifest.installed_at_ms = companion_core::now_ms();
    manifest.agents_md = Some(AgentsMdEntry {
        sha256: sha256_hex(block.as_bytes()),
    });
    write_manifest(&manifest_path, &manifest)?;

    let names: Vec<&str> = skills.iter().map(|skill| skill.name).collect();
    emit!(
        "Wrote the companion-skills section of {} ({}).",
        agents_path.display(),
        names.join(", ")
    );
    Ok(())
}

fn remove_block(content: &str) -> Result<String, String> {
    match find_block(content)? {
        None => Ok(content.to_owned()),
        Some((start, end)) => {
            let mut trimmed_start = start;
            // Take one preceding blank line with it, so uninstall does not leave a
            // growing gap of empty lines behind after several install/uninstall rounds.
            while trimmed_start >= 2 && &content[trimmed_start - 2..trimmed_start] == "\n\n" {
                trimmed_start -= 1;
            }
            let mut result = String::with_capacity(content.len() - (end - trimmed_start));
            result.push_str(&content[..trimmed_start]);
            let rest = content[end..].trim_start_matches('\n');
            result.push_str(rest);
            Ok(result)
        }
    }
}

fn uninstall(arguments: &[String]) -> Result<(), String> {
    let options = InstallOptions::parse(arguments, true)?;
    let target = options
        .target
        .clone()
        .unwrap_or_else(|| options.harness.default_target());

    match options.harness {
        Harness::Claude => uninstall_claude(&target),
        Harness::Agents => uninstall_agents(&target),
    }
}

fn uninstall_claude(target: &Path) -> Result<(), String> {
    uninstall_claude_except(target, &[])
}

/// On a tier downgrade, retain the skills still in the selected tier and remove only
/// manifest-owned skills that are no longer selected.
fn uninstall_claude_except(target: &Path, keep: &[&str]) -> Result<(), String> {
    if is_symlink(target)? {
        return Err(format!("skill target {} is a symlink", target.display()));
    }
    let path = manifest_path(target);
    let Some(mut manifest) = load_manifest(&path)? else {
        emit!("Nothing installed at {}.", target.display());
        return Ok(());
    };

    let mut removed = Vec::new();
    let mut kept = Vec::new();
    let mut refused = Vec::new();
    let names: Vec<String> = manifest
        .skills
        .keys()
        .filter(|name| !keep.contains(&name.as_str()))
        .cloned()
        .collect();
    for name in names {
        let entry = manifest.skills.get(&name).expect("just read from this map");
        let Some(skill_dir) = resolve_skill_dir(target, &name)? else {
            refused.push(name);
            continue;
        };
        // An entry without a single recorded file leaves the loop below with nothing to
        // compare, so `all_matched` would still say "ours" and `remove_dir_all` would fire
        // without any hash ever having been checked. No files recorded means we have no
        // evidence this directory is ours, which is the opposite of a match.
        let mut all_matched = !entry.files.is_empty();
        for (relative_path, expected_hash) in &entry.files {
            let file_path = skill_dir.join(relative_path);
            match fs::read(&file_path) {
                Ok(bytes) if sha256_hex(&bytes) == *expected_hash => {}
                Ok(_) => all_matched = false,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(format!("cannot read {}: {error}", file_path.display())),
            }
        }
        if skill_dir.exists() {
            let children = fs::read_dir(&skill_dir)
                .map_err(|error| format!("cannot list {}: {error}", skill_dir.display()))?;
            for child in children {
                let child = child.map_err(|error| error.to_string())?;
                if !entry
                    .files
                    .contains_key(&child.file_name().to_string_lossy().to_string())
                {
                    all_matched = false;
                }
            }
        }
        if all_matched {
            if skill_dir.exists() {
                fs::remove_dir_all(&skill_dir)
                    .map_err(|error| format!("cannot remove {}: {error}", skill_dir.display()))?;
            }
            manifest.skills.remove(&name);
            removed.push(name);
        } else {
            kept.push(name);
        }
    }

    if manifest.skills.is_empty() && manifest.agents_md.is_none() {
        fs::remove_file(&path)
            .map_err(|error| format!("cannot remove {}: {error}", path.display()))?;
    } else {
        write_manifest(&path, &manifest)?;
    }

    if !removed.is_empty() {
        emit!("Removed from {}: {}", target.display(), removed.join(", "));
    }
    if !kept.is_empty() {
        emit!(
            "Left in place, changed by hand since install: {}",
            kept.join(", ")
        );
    }
    if !refused.is_empty() {
        emit!(
            "Left in place, not a plain skill directory of this target: {}",
            refused.join(", ")
        );
    }
    if removed.is_empty() && kept.is_empty() && refused.is_empty() {
        emit!("Nothing tracked at {}.", target.display());
    }
    Ok(())
}

fn uninstall_agents(target: &Path) -> Result<(), String> {
    if is_symlink(target)? || is_symlink(&target.join("AGENTS.md"))? {
        return Err(format!(
            "AGENTS.md target {} is a symlink",
            target.display()
        ));
    }
    let path = manifest_path(target);
    let Some(manifest) = load_manifest(&path)? else {
        emit!("Nothing installed at {}.", target.display());
        return Ok(());
    };
    let Some(agents_entry) = &manifest.agents_md else {
        emit!(
            "No companion-skills section tracked at {}.",
            target.display()
        );
        return Ok(());
    };

    let agents_path = target.join("AGENTS.md");
    let content = match fs::read_to_string(&agents_path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            emit!(
                "{} is gone; clearing the manifest entry.",
                agents_path.display()
            );
            String::new()
        }
        Err(error) => return Err(format!("cannot read {}: {error}", agents_path.display())),
    };

    match find_block(&content)? {
        None => {
            emit!("No companion-skills section in {}.", agents_path.display());
        }
        Some((start, end)) => {
            let current_hash = sha256_hex(&content.as_bytes()[start..end]);
            if current_hash != agents_entry.sha256 {
                emit!(
                    "The companion-skills section of {} was changed since install; leaving it in place.",
                    agents_path.display()
                );
                return Ok(());
            }
            let new_content = remove_block(&content)?;
            fs::write(&agents_path, &new_content)
                .map_err(|error| format!("cannot write {}: {error}", agents_path.display()))?;
            emit!(
                "Removed the companion-skills section from {}.",
                agents_path.display()
            );
        }
    }

    let mut manifest = manifest;
    manifest.agents_md = None;
    if manifest.skills.is_empty() {
        fs::remove_file(&path)
            .map_err(|error| format!("cannot remove {}: {error}", path.display()))?;
    } else {
        write_manifest(&path, &manifest)?;
    }
    Ok(())
}

/// Entry point for `companion skills <subcommand>`.
pub fn run(arguments: &[String]) -> Result<(), String> {
    let mut rest = arguments.iter();
    match rest.next().map(String::as_str) {
        Some("install") => install(&arguments[1..]),
        Some("uninstall") => uninstall(&arguments[1..]),
        Some("help") | Some("--help") | Some("-h") | None => {
            print!("{USAGE}");
            Ok(())
        }
        Some(other) => Err(format!("no skills command {other}\n\n{USAGE}")),
    }
}

/// Apply a settings tier through the same manifest rules as the CLI. The target is explicit
/// so callers and tests cannot accidentally fall back to a real home directory.
pub fn apply_level(level: SkillLevel, harness: Harness, target: &Path) -> Result<String, String> {
    let _quiet = Quiet::new();
    let path = manifest_path(target);
    let before = load_manifest(&path)?;
    if level == SkillLevel::None && before.is_none() {
        return Ok("Skill-Paket: nichts Eigenes vorhanden".to_owned());
    }
    if let Some(manifest) = &before {
        if manifest.level == level && manifest.package_version == PACK_MANIFEST.package_version {
            return Ok("Skill-Paket: Stufe bereits angewandt".to_owned());
        }
    }
    if level == SkillLevel::None {
        match harness {
            Harness::Claude => uninstall_claude(target)?,
            Harness::Agents => uninstall_agents(target)?,
        }
    } else {
        let skills = skills_for_level(level);
        match harness {
            Harness::Claude => {
                let keep: Vec<&str> = skills.iter().map(|skill| skill.name).collect();
                if before.is_some() {
                    uninstall_claude_except(target, &keep)?;
                }
                install_claude(target, &skills, level)?;
            }
            Harness::Agents => install_agents(target, &skills, level)?,
        }
    }
    let after = load_manifest(&path)?;
    let (installed, skipped) = match harness {
        Harness::Claude if level != SkillLevel::None => {
            let installed = after.as_ref().map_or(0, |m| m.skills.len());
            (
                installed,
                skills_for_level(level).len().saturating_sub(installed),
            )
        }
        Harness::Agents if level != SkillLevel::None => (1, 0),
        _ => (0, 0),
    };
    if level == SkillLevel::None {
        let previously_tracked = before.as_ref().map_or(0, |m| match harness {
            Harness::Claude => m.skills.len(),
            Harness::Agents => usize::from(m.agents_md.is_some()),
        });
        let remaining = after.as_ref().map_or(0, |m| match harness {
            Harness::Claude => m.skills.len(),
            Harness::Agents => usize::from(m.agents_md.is_some()),
        });
        Ok(format!(
            "Skill-Paket: {} eigene Einträge entfernt, {remaining} wegen Änderungen behalten",
            previously_tracked.saturating_sub(remaining)
        ))
    } else {
        Ok(format!(
            "Skill-Paket: {installed} installiert, {skipped} übersprungen"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "companion-skills-test-{name}-{}-{}",
            std::process::id(),
            companion_core::now_ms()
        ));
        assert_ne!(
            dir,
            companion_core::paths::home_dir(),
            "test target must not be HOME"
        );
        assert!(dir.starts_with(std::env::temp_dir()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn the_pack_manifest_names_exactly_the_embedded_skills() {
        let mut manifest_names: Vec<&str> = PACK_MANIFEST
            .skills
            .iter()
            .map(|entry| entry.name.as_str())
            .collect();
        manifest_names.sort_unstable();
        let mut embedded_names: Vec<&str> =
            EMBEDDED_SKILLS.iter().map(|skill| skill.name).collect();
        embedded_names.sort_unstable();
        assert_eq!(
            manifest_names, embedded_names,
            "skills/manifest.json must list exactly the skills embedded in this binary"
        );
    }

    #[test]
    fn every_embedded_skill_names_its_own_version_in_its_frontmatter() {
        for skill in EMBEDDED_SKILLS {
            let expected = format!("version: {}", skill_version(skill.name));
            assert!(
                skill.content.contains(&expected),
                "{} frontmatter must contain `{expected}`",
                skill.name
            );
        }
    }

    #[test]
    fn recommended_is_all_five_skills_today() {
        let skills = skills_for_level(SkillLevel::Recommended);
        assert_eq!(skills.len(), 5);
    }

    #[test]
    fn level_none_installs_nothing() {
        let skills = skills_for_level(SkillLevel::None);
        assert!(skills.is_empty());
    }

    #[test]
    fn many_and_all_are_at_least_the_recommended_core() {
        let recommended: Vec<&str> = skills_for_level(SkillLevel::Recommended)
            .iter()
            .map(|skill| skill.name)
            .collect();
        for level in [SkillLevel::Many, SkillLevel::All] {
            let names: Vec<&str> = skills_for_level(level)
                .iter()
                .map(|skill| skill.name)
                .collect();
            for name in &recommended {
                assert!(names.contains(name), "{level:?} must include {name}");
            }
        }
    }

    #[test]
    fn a_fresh_target_gets_every_skill_and_a_manifest() {
        let target = temp_dir("fresh");
        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        for skill in &skills {
            let content = fs::read_to_string(target.join(skill.name).join("SKILL.md")).unwrap();
            assert_eq!(content, skill.content);
        }
        let manifest = load_manifest(&manifest_path(&target)).unwrap().unwrap();
        assert_eq!(manifest.skills.len(), skills.len());
        assert_eq!(manifest.level, SkillLevel::Recommended);

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn install_never_overwrites_a_skill_dir_it_did_not_create() {
        let target = temp_dir("foreign");
        fs::create_dir_all(target.join("loop-kit")).unwrap();
        fs::write(target.join("loop-kit").join("SKILL.md"), "not ours").unwrap();

        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        let content = fs::read_to_string(target.join("loop-kit").join("SKILL.md")).unwrap();
        assert_eq!(
            content, "not ours",
            "a foreign skill directory must be left untouched"
        );

        let manifest = load_manifest(&manifest_path(&target)).unwrap().unwrap();
        assert!(
            !manifest.skills.contains_key("loop-kit"),
            "a skipped skill must not be recorded as ours"
        );
        assert!(manifest.skills.len() >= 4, "the other skills still install");

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn foreign_directory_is_reported_as_skipped() {
        let target = temp_dir("foreign-report");
        fs::create_dir_all(target.join("loop-kit")).unwrap();
        fs::write(target.join("loop-kit/SKILL.md"), "foreign").unwrap();
        let report = apply_level(SkillLevel::Recommended, Harness::Claude, &target).unwrap();
        assert!(report.contains("4 installiert, 1 übersprungen"), "{report}");
        assert_eq!(
            fs::read_to_string(target.join("loop-kit/SKILL.md")).unwrap(),
            "foreign"
        );
        fs::remove_dir_all(target).unwrap();
    }

    #[test]
    fn lowering_a_tier_removes_only_obsolete_manifest_owned_skills() {
        let target = temp_dir("lower-tier");
        install_claude(&target, &skills_for_level(SkillLevel::All), SkillLevel::All).unwrap();
        let extra = target.join("reviewed-extra");
        fs::create_dir_all(&extra).unwrap();
        fs::write(extra.join("SKILL.md"), "old extra").unwrap();
        let path = manifest_path(&target);
        let mut manifest = load_manifest(&path).unwrap().unwrap();
        manifest.skills.insert(
            "reviewed-extra".to_owned(),
            SkillEntry {
                version: "1.0.0".to_owned(),
                files: BTreeMap::from([("SKILL.md".to_owned(), sha256_hex(b"old extra"))]),
            },
        );
        write_manifest(&path, &manifest).unwrap();
        apply_level(SkillLevel::Recommended, Harness::Claude, &target).unwrap();
        assert!(!extra.exists());
        assert!(target.join("loop-kit/SKILL.md").exists());
        fs::remove_dir_all(target).unwrap();
    }

    #[test]
    fn reinstalling_updates_a_skill_this_pack_already_owns() {
        let target = temp_dir("reinstall");
        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        // Simulate a package upgrade: the file on disk is stale, but it is ours (tracked
        // in the manifest), so a second install must refresh it rather than skip it.
        fs::write(target.join("loop-kit").join("SKILL.md"), "stale content").unwrap();
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        let content = fs::read_to_string(target.join("loop-kit").join("SKILL.md")).unwrap();
        assert_eq!(
            content,
            skills
                .iter()
                .find(|s| s.name == "loop-kit")
                .unwrap()
                .content
        );

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn uninstall_removes_only_files_still_at_their_installed_hash() {
        let target = temp_dir("uninstall");
        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        // One skill is hand-edited after install; uninstall must leave exactly that one.
        fs::write(target.join("spec-first").join("SKILL.md"), "hand-edited").unwrap();

        uninstall_claude(&target).unwrap();

        assert!(!target.join("loop-kit").exists());
        assert!(target.join("spec-first").exists());
        let content = fs::read_to_string(target.join("spec-first").join("SKILL.md")).unwrap();
        assert_eq!(content, "hand-edited");

        let manifest = load_manifest(&manifest_path(&target)).unwrap().unwrap();
        assert!(manifest.skills.contains_key("spec-first"));
        assert!(!manifest.skills.contains_key("loop-kit"));

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn uninstall_never_leaves_the_target_over_a_name_from_the_manifest() {
        // The manifest is a file at the target, not something only we can have written.
        // A name that escapes `--target` must not reach `remove_dir_all`.
        let root = temp_dir("escape");
        let target = root.join("home").join("skills");
        let victim = root.join("victim");
        fs::create_dir_all(&target).unwrap();
        fs::create_dir_all(&victim).unwrap();
        fs::write(victim.join("precious.txt"), "do not delete me").unwrap();
        fs::write(
            manifest_path(&target),
            r#"{"package_version":"1.0.0","level":"recommended","installed_at_ms":0,
                "skills":{"../../victim":{"version":"1.0.0","files":{}}}}"#,
        )
        .unwrap();

        uninstall_claude(&target).unwrap();

        assert!(
            victim.join("precious.txt").exists(),
            "a `..` in a manifest name must never reach remove_dir_all"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn uninstall_treats_an_entry_without_recorded_files_as_not_ours() {
        // With no file hashes there is no evidence the directory came from this pack, so
        // there is nothing to match and the directory stays.
        let target = temp_dir("no-files");
        fs::create_dir_all(target.join("loop-kit")).unwrap();
        fs::write(target.join("loop-kit").join("SKILL.md"), "not ours").unwrap();
        fs::write(
            manifest_path(&target),
            r#"{"package_version":"1.0.0","level":"recommended","installed_at_ms":0,
                "skills":{"loop-kit":{"version":"1.0.0","files":{}}}}"#,
        )
        .unwrap();

        uninstall_claude(&target).unwrap();

        assert!(
            target.join("loop-kit").join("SKILL.md").exists(),
            "an empty files map must not count as `everything matched`"
        );

        let _ = fs::remove_dir_all(&target);
    }

    #[cfg(unix)]
    #[test]
    fn install_does_not_write_through_a_symlink() {
        let root = temp_dir("symlink");
        let target = root.join("home").join("skills");
        let secret = root.join("secret.txt");
        fs::create_dir_all(target.join("loop-kit")).unwrap();
        fs::write(&secret, "private content").unwrap();
        std::os::unix::fs::symlink(&secret, target.join("loop-kit").join("SKILL.md")).unwrap();
        // Say the skill is ours, so the "already there and not from this pack" brake does
        // not cover this on its own.
        fs::write(
            manifest_path(&target),
            r#"{"package_version":"1.0.0","level":"recommended","installed_at_ms":0,
                "skills":{"loop-kit":{"version":"1.0.0","files":{"SKILL.md":"deadbeef"}}}}"#,
        )
        .unwrap();

        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        assert_eq!(
            fs::read_to_string(&secret).unwrap(),
            "private content",
            "install must not write the skill text through a SKILL.md symlink"
        );
        assert!(
            target.join("spec-first").join("SKILL.md").exists(),
            "the other skills still install"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn install_leaves_a_symlinked_skill_directory_alone() {
        let root = temp_dir("symlink-dir");
        let target = root.join("home").join("skills");
        let elsewhere = root.join("elsewhere");
        fs::create_dir_all(&target).unwrap();
        fs::create_dir_all(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, target.join("loop-kit")).unwrap();
        // Again as an entry the manifest calls ours, so the skip is the symlink check and
        // not the "already there and not from this pack" brake.
        fs::write(
            manifest_path(&target),
            r#"{"package_version":"1.0.0","level":"recommended","installed_at_ms":0,
                "skills":{"loop-kit":{"version":"1.0.0","files":{"SKILL.md":"deadbeef"}}}}"#,
        )
        .unwrap();

        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        assert!(
            !elsewhere.join("SKILL.md").exists(),
            "install must not write into the target of a symlinked skill directory"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn uninstall_removes_the_manifest_once_nothing_is_left_tracked() {
        let target = temp_dir("clean-uninstall");
        let skills = skills_for_level(SkillLevel::Recommended);
        install_claude(&target, &skills, SkillLevel::Recommended).unwrap();

        uninstall_claude(&target).unwrap();

        assert!(!manifest_path(&target).exists());
        for skill in &skills {
            assert!(!target.join(skill.name).exists());
        }

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn agents_install_adds_a_marked_section_and_leaves_the_rest_alone() {
        let target = temp_dir("agents-fresh");
        fs::create_dir_all(&target).unwrap();
        fs::write(
            target.join("AGENTS.md"),
            "# Project agents\n\nSome hand-written instructions.\n",
        )
        .unwrap();

        let skills = skills_for_level(SkillLevel::Recommended);
        install_agents(&target, &skills, SkillLevel::Recommended).unwrap();

        let content = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        assert!(content.starts_with("# Project agents\n\nSome hand-written instructions.\n"));
        assert!(content.contains(AGENTS_MD_START));
        assert!(content.contains(AGENTS_MD_END));
        assert!(content.contains("## loop-kit"));

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn agents_install_is_idempotent() {
        let target = temp_dir("agents-idempotent");
        fs::create_dir_all(&target).unwrap();
        let skills = skills_for_level(SkillLevel::Recommended);
        install_agents(&target, &skills, SkillLevel::Recommended).unwrap();
        let once = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        install_agents(&target, &skills, SkillLevel::Recommended).unwrap();
        let twice = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        assert_eq!(
            once, twice,
            "installing twice must not duplicate the section"
        );

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn agents_uninstall_leaves_a_hand_edited_section_in_place() {
        let target = temp_dir("agents-hand-edit");
        fs::create_dir_all(&target).unwrap();
        let skills = skills_for_level(SkillLevel::Recommended);
        install_agents(&target, &skills, SkillLevel::Recommended).unwrap();

        let mut content = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        content.push_str("\n<!-- a person added this line inside the tracked block -->\n");
        // Insert the note before the end marker so it counts as a hand edit of the block.
        let content = content.replacen(
            AGENTS_MD_END,
            "a person's own note\n<!-- companion-skills:end -->",
            1,
        );
        fs::write(target.join("AGENTS.md"), &content).unwrap();

        uninstall_agents(&target).unwrap();

        let after = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        assert!(
            after.contains("a person's own note"),
            "a section changed since install must be left alone, not deleted"
        );

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn agents_uninstall_removes_an_untouched_section() {
        let target = temp_dir("agents-clean-uninstall");
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("AGENTS.md"), "# Before\n").unwrap();
        let skills = skills_for_level(SkillLevel::Recommended);
        install_agents(&target, &skills, SkillLevel::Recommended).unwrap();

        uninstall_agents(&target).unwrap();

        let content = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        assert_eq!(content, "# Before\n");
        assert!(!manifest_path(&target).exists());

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn level_none_removes_an_existing_agents_section() {
        let target = temp_dir("agents-level-none");
        fs::create_dir_all(&target).unwrap();
        let recommended = skills_for_level(SkillLevel::Recommended);
        install_agents(&target, &recommended, SkillLevel::Recommended).unwrap();

        install_agents(&target, &[], SkillLevel::None).unwrap();

        let content = fs::read_to_string(target.join("AGENTS.md")).unwrap();
        assert!(!content.contains(AGENTS_MD_START));

        let _ = fs::remove_dir_all(&target);
    }

    #[test]
    fn strip_frontmatter_drops_the_yaml_header_only() {
        let with_frontmatter = "---\nname: x\nversion: 1.0.0\n---\n\n# Title\n\nBody.\n";
        assert_eq!(strip_frontmatter(with_frontmatter), "# Title\n\nBody.\n");
        assert_eq!(
            strip_frontmatter("# No frontmatter\n"),
            "# No frontmatter\n"
        );
    }

    #[test]
    fn parse_level_accepts_the_four_wire_names() {
        assert_eq!(parse_level("none").unwrap(), SkillLevel::None);
        assert_eq!(parse_level("recommended").unwrap(), SkillLevel::Recommended);
        assert_eq!(parse_level("many").unwrap(), SkillLevel::Many);
        assert_eq!(parse_level("all").unwrap(), SkillLevel::All);
        assert!(parse_level("everything").is_err());
    }
}
