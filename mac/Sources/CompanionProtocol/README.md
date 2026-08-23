# CompanionProtocol

The shell's side of the daemon protocol: the wire types, the socket, and the client that
keeps the connection up.

## Where the types come from

`app/protocol/schema/*.json` is the source. The types in `Wire/` are written by hand against
it, and two kinds of test keep them honest:

- `Tests/CompanionProtocolTests/Fixtures/*.jsonl` holds one line per message, produced by
  `cargo run -p companion-protocol --example fixtures -- <verzeichnis>` from the real Rust
  types. The Swift tests decode those lines, so a rename on either side fails in the test
  instead of in the overlay. `tests/mac/e2e-daemon.sh` regenerates the files and fails when
  the committed ones have drifted.
- `SchemaTests` reads the schema files themselves and fails when the schema knows a value
  this shell has no case for.

## What is fixed

Messages are one JSON object per line in both directions. The client opens with `hello`
carrying the token, and the daemon answers with `welcome`, which names the role it derived
from that token, its own version, the id of this daemon run and the namespace of the
connection. A request carries an id; the response carries the same one. Everything else
arrives as an event with a sequence number.

An additive change does not break this shell (`DESIGN.md`, section Architektur, paragraph
Protokoll-Kompatibilität). An unknown event kind, message type, status field or enum value
is read as unrecognised rather than as something the shell believes it understood, and
`DaemonClient.ignoredCount` counts what had to be passed over, so a version drift is visible
instead of silent.

## Parts

| File | Contents |
|---|---|
| `Wire/Ids.swift` | the string ids, the protocol version, the role |
| `Wire/Provenance.swift` | a value together with where it came from |
| `Wire/SessionStatus.swift` | the session status and its two usage types |
| `Wire/Events.swift` | the thirteen events and the envelope the bus adds |
| `Wire/Capabilities.swift` | what one adapter can do |
| `Wire/Messages.swift` | handshake, requests, responses, and the codec |
| `Paths.swift` | where the socket and the token file live |
| `Framing.swift` | line framing and the transport errors |
| `UnixSocketTransport.swift` | the socket, on one private queue |
| `DaemonClient.swift` | handshake, request ids, deadlines, reconnect |

## The token

The daemon writes `tokens.json` into its configuration directory on its first start, mode
0600, and the shell reads the `human` entry from it. It is read again on every connection
attempt, so a daemon that regenerated its tokens is picked up without restarting the shell,
and a missing file is the normal state before the daemon has ever run: the client says so and
keeps retrying. `DESIGN.md` puts the tokens in the system keychain; when that lands on both
sides, `FileTokenSource` is the only type that changes.

## Deadlines

Nothing here waits without an end. A request that gets no answer within its timeout fails
locally rather than leaving a caller hanging, a lost connection fails every request that was
still open, and reconnect uses a capped backoff so a daemon that is not running costs
nothing.
