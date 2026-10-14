# companion

A screen-corner character that acts as a meta-orchestrator for coding-agent sessions: it
watches which orchestrator sessions are running, can start and manage new ones, and answers
or forwards their questions. The work inside those sessions stays with the orchestrators and
their workers.

## Status

Phase 1 and Phase 1b (voice) are built: the Rust core, the security model, both v1 session
adapters, and the macOS shell (`mac/`) with figure, session list, chat and a full voice
loop (push-to-talk, click, wakeword, barge-in). A GTK4 Linux shell (`linux/`) and an iOS
app (`mac/CompanionIOS`) exist as later-phase work; the Linux shell has no voice yet. See
`mac/README.md`, `linux/README.md` and `mac/CompanionIOS/README.md` for each shell's own
state.

## What it does

- **Watches and drives sessions** of the Claude Code Workbench and of plain Claude Code;
  further adapters run the Codex CLI, the Hermes Agent over ACP, and any other CLI on a
  pseudo terminal.
- **Talks.** Push-to-talk, click or wakeword, with barge-in. A finished answer is spoken in
  pieces, so the first sentence plays while the rest is still being prepared
  (`crates/companion-voice/src/pieces.rs`).
- **Asks before it reaches outside.** Actions run without a question, except outward or
  irreversible ones (delete, push, publish, money): those wait for a yes. An optional local
  decider, reachable only on this machine or the local network, can add a question but never
  grant one (`crates/companion-brain/src/decider.rs`).
- **Keeps secrets out of what it says.** Logs, spoken answers, panel events and adapter output
  shorten paths under the home directory and leave out values that look like keys or
  passwords (`crates/companion-core/src/redact.rs`).
- **Reads workbench worlds**: what finished, what waits for you, and it can write into a world
  when it acts (`crates/companion-core/src/worlds.rs`).
- **Shows what a run cost** from a price file you own and edit; a model without an entry shows
  no price rather than an estimate (`crates/companion-core/src/prices.rs`).
- **Installs its skill pack** into a harness with `companion skills install`, and removes it
  again with `companion skills uninstall` (`crates/companion-skills/`).
- **Serves orchestrators over MCP**: `companion mcp` is a stdio MCP server; there is no network
  port (`crates/companion-cli/src/mcp.rs`).
- **Knows your day on macOS**: calendar, reminders and location tools, each behind the
  system's own permission (`crates/companion-macos-ffi/`).

## Architecture

- One core daemon per machine, written in Rust: session adapters, event bus, endpoint
  configuration, voice pipeline.
- Native shells per operating system talk to the daemon over a user-only local socket with a
  versioned JSON protocol. No Electron, Tauri, or Qt.
- v1 ships the macOS shell (SwiftUI/AppKit, `mac/`) with adapters for Claude Code Workbench
  and plain Claude Code, plus voice input (push-to-talk, click, wakeword). A GTK4 Linux shell
  (`linux/`) and an iOS app (`mac/CompanionIOS`) exist as later-phase work, as do the Codex,
  Hermes and generic PTY adapters. There is no Windows shell.

## Build and test

Rust 1.85 or newer, edition 2024. The workspace lives in this directory.

```bash
cargo build --workspace
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
```

`cargo run --bin companion-daemon` starts the daemon. It creates its configuration directory,
generates a token pair on first start and listens on `$XDG_RUNTIME_DIR/companion/companion.sock`,
or on `companion.sock` inside the configuration directory where there is no runtime directory,
as on macOS. `COMPANION_CONFIG_DIR` moves everything somewhere else, which is what the tests
use so a run never touches a real installation.

The end-to-end pass lives outside this directory, in the private part of the repository:
`tests/e2e-write/run.sh` builds a workbench of its own on a separate tmux socket, drives
both adapters against stubs and runs a gate command, then takes everything down again. It
never touches a running session or a real workbench.

The JSON Schema of the wire types is generated from the Rust types and committed under
`protocol/schema/`, so a shell can build against it without a Rust toolchain. A type change
without a matching export fails the test suite; regenerate with

```bash
COMPANION_UPDATE_SCHEMAS=1 cargo test -p companion-protocol
```

### The hook binary

`companion-hook` is what Claude Code calls for its `Stop`, `SubagentStop` and
`Notification` events. It reports to the daemon over the socket and always exits 0, so a
hook can never block a session.

It is installed into a project's `.claude/settings.local.json` additively: existing hooks
stay untouched, ours is appended, installing twice changes nothing, and the uninstall
removes only our own entry. The local file is the default target because the command is an
absolute path on this machine; in the shared `settings.json` it would land in the
repository and hand every colleague a hook that points nowhere. The command itself is the
hook binary next to the running daemon, taken from its own path rather than from a build
directory, and quoted so a path with a space survives the shell.

Because the binary connects once per event, the daemon recognises a reporter that comes
back: a session whose connection has gone away is taken over by the next one instead of
appearing a second time in the list.

### Job files and gates

A job file lives in the project under `.companion/auftraege/<id>.json`. Writing one does not
approve it. The approval is a decision about an exact text: the shell shows the file, the
person approves the hash of its canonical form, and the daemon stores that hash in its
register, outside the project. The copy in the file itself is for reading; the record is
what decides.

That split matters because the session a job commands can write in its own project. It could
add a gate command and fix up the approval inside the file, and the register would still say
no. Running a gate therefore checks three things against each other: the file as it is now,
the record, and the hash the caller sends with the request.

What runs is a program and a list of arguments, handed to the operating system as they
stand. There is no shell anywhere on that path, so there is no string for one to expand.

### Crates

| Crate | What it holds |
|---|---|
| `companion-protocol` | The versioned JSON protocol: envelopes, events, session status, job file, register entry, capabilities, client roles, endpoint configuration. Serde and schemars only. |
| `companion-core` | Session-adapter trait, event bus, SQLite register with migrations, settings, token store and the role model. |
| `companion-daemon` | The socket server and two binaries: the daemon itself and `companion-hook`, which Claude Code's hooks call. |
| `companion-cli` | The `companion` command line tool next to the daemon, for pairing and the device list on a machine without a desktop shell. |
| `companion-skills` | The skill pack and its installer: adds to a harness's configuration, never overwrites what it did not put there, and removes only its own entries. |
| `companion-brain` | The companion's own answer to a chat message: the tool catalogue, the CLI and API chat drivers, subagent runs, condensation. |
| `companion-voice` | The voice half of the daemon: STT/TTS drivers, the endpoint latency probe, and the engine that ties them to the event bus. |
| `companion-wakeword` | The local wakeword engine (MFCC and DTW), plain Rust, no FFI. |
| `companion-wakeword-ffi` | The C ABI over `companion-wakeword`, so a shell that cannot link Rust directly still can. |
| `companion-macos-ffi` | The Objective-C calls behind CoreLocation and EventKit, for the location and calendar tools. |
| `companion-adapter-workbench` | Watches the Claude Code Workbench through its state files, `wb-state` and tmux pane metadata. Read-only by design. |
| `companion-adapter-claude` | Drives plain Claude Code headless, reads its transcripts, and installs the three missing hooks additively. |
| `companion-adapter-codex` | Drives the Codex CLI headless (`codex exec --json`) and reads its rollout files. |
| `companion-adapter-hermes` | Drives the Hermes Agent of Nous Research over ACP and reads its session store. |
| `companion-adapter-pty` | The generic terminal adapter for any configured CLI, run on a pseudo terminal, for harnesses with no hooks or status files. |

## Native shells

### macOS

SwiftUI/AppKit, under `mac/`, its own Swift package. Figure, overlay, session list, chat,
onboarding, and the full voice loop. See `mac/README.md` for how to build it: it needs
`./Scripts/build-wakeword.sh` run once before `swift test`, because SwiftPM cannot build the
Rust wakeword crate itself.

### iOS

Under `mac/CompanionIOS`, its own Xcode project generated from `project.yml` (SwiftPM
builds libraries, not app bundles). Pairing, a session list across paired machines, and chat
in text and voice. See `mac/CompanionIOS/README.md`.

### Linux

GTK4 and `gtk4-layer-shell`, under `linux/`, its own Cargo workspace, kept separate so a
plain `cargo build --workspace` in this directory never needs Wayland or GTK headers.
Building it needs `gtk4` and `gtk4-layer-shell` installed; without them `cargo check` fails at
`gtk4-sys` looking for `gtk4` in the pkg-config search path, which is the expected outcome on
a machine that does not have them. See `linux/README.md`.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE).

- **Free to use** for personal and other noncommercial purposes, for study and
  research, by educational, public and nonprofit institutions, and by individuals
  for their own work, including professional work as freelancer or employee.
  Organizations may evaluate the software for 60 days. Details:
  [ADDITIONAL-PERMISSIONS.md](ADDITIONAL-PERMISSIONS.md).
- **Commercial license required** for use by an organization, such as rolling it
  out to staff, operating it for others or building it into a product or service:
  [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).
- Versions up to the tag `last-agpl` remain available under AGPL-3.0-only.

Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
