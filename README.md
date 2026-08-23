# companion

A screen-corner character that acts as a meta-orchestrator for coding-agent sessions: it
watches which orchestrator sessions are running, can start and manage new ones, and answers
or forwards their questions. The work inside those sessions stays with the orchestrators and
their workers.

## Status

Phase 1 is under way. The Rust core is in place: the wire protocol, the session-adapter
interface with its event bus, the register, the settings file and the daemon that serves
them on a user-only Unix socket. No session adapter talks to a real harness yet, and the
macOS shell has not been started.

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

`cargo run -p companion-daemon` starts the daemon. It creates its configuration directory,
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

### Crates

| Crate | What it holds |
|---|---|
| `companion-protocol` | The versioned JSON protocol: envelopes, events, session status, job file, register entry, capabilities, client roles. Serde and schemars only. |
| `companion-core` | Session-adapter trait, event bus, SQLite register with migrations, settings, token store and the role model. |
| `companion-daemon` | The socket server and the binary: handshake, role check, request dispatch, event fan-out. |

## License

AGPL-3.0-only. See LICENSE.
