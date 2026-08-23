# companion

A screen-corner character that acts as a meta-orchestrator for coding-agent sessions: it
watches which orchestrator sessions are running, can start and manage new ones, and answers
or forwards their questions. The work inside those sessions stays with the orchestrators and
their workers.

## Status

Planning is done; Phase 1 (macOS, core daemon, two session adapters, text chat) has not
started yet.

## Architecture

- One core daemon per machine, written in Rust: session adapters, event bus, endpoint
  configuration, voice pipeline.
- Native shells per operating system talk to the daemon over a user-only local socket with a
  versioned JSON protocol. No Electron, Tauri, or Qt.
- v1 ships the macOS shell (SwiftUI/AppKit) with adapters for Claude Code Workbench and plain
  Claude Code. Linux and Windows shells, further adapters, and voice follow in later phases.

## License

AGPL-3.0-only. See LICENSE.
