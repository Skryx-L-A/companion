# companion

A screen-corner character that acts as a meta-orchestrator for coding-agent sessions: it
watches which orchestrator sessions are running, can start and manage new ones, and answers
or forwards their questions. The work inside those sessions stays with the orchestrators and
their workers.

## Status

Phase 1 is under way. The Rust core is in place, and so are the two adapters v1 ships with:
one for the Claude Code Workbench, which watches its state files, and one for plain Claude
Code, which drives the CLI headless and reads its transcripts. The macOS shell has not been
started.

## Architecture

- One core daemon per machine, written in Rust: session adapters, event bus, endpoint
  configuration, voice pipeline.
- Native shells per operating system talk to the daemon over a user-only local socket with a
  versioned JSON protocol. No Electron, Tauri, or Qt.
- v1 ships the macOS shell (SwiftUI/AppKit) with adapters for Claude Code Workbench and plain
  Claude Code. Linux and Windows shells, further adapters, and voice follow in later phases.

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

It is installed into a project's `.claude/settings.json` additively: existing hooks stay
untouched, ours is appended, installing twice changes nothing, and the uninstall removes
only our own entry. The command written there is the hook binary next to the daemon that is
running, taken from its own path rather than from a build directory, and quoted so a path
with a space survives the shell.

### Crates

| Crate | What it holds |
|---|---|
| `companion-protocol` | The versioned JSON protocol: envelopes, events, session status, job file, register entry, capabilities, client roles. Serde and schemars only. |
| `companion-core` | Session-adapter trait, event bus, SQLite register with migrations, settings, token store and the role model. |
| `companion-adapter-workbench` | Watches the Claude Code Workbench through its state files, `wb-state` and tmux pane metadata. Read-only by design. |
| `companion-adapter-claude` | Drives plain Claude Code headless, reads its transcripts, and installs the three missing hooks additively. |
| `companion-daemon` | The socket server and two binaries: the daemon itself and `companion-hook`, which Claude Code's hooks call. |

## License

AGPL-3.0-only. See LICENSE.
