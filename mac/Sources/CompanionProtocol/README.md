# CompanionProtocol

The client side of the daemon protocol: the wire types, the ways to the daemon, and the client
that keeps the connection up. Used by the macOS shell and by the iOS app, which is why neither
the transport nor the source of the token is decided in here.

## Where the types come from

`app/protocol/schema/*.json` is the source. The types in `Wire/` are written by hand against
it, and two kinds of test keep them honest:

- `Tests/CompanionProtocolTests/Fixtures/*.jsonl` holds one line per message, produced by
  `cargo run -p companion-protocol --example fixtures -- <verzeichnis>` from the real Rust
  types. The Swift tests decode those lines, so a rename on either side fails in the test
  instead of in the overlay. `tests/mac/e2e-daemon.sh`, a script in the private part of the
  repository, regenerates the files and fails when the committed ones have drifted; a public
  clone keeps the committed fixtures but has no way to check them against a fresh run.
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
| `Wire/Devices.swift` | paired devices, the pairing offer and what a scanned QR says |
| `Paths.swift` | where the socket and the token file live |
| `Framing.swift` | line framing and the transport errors |
| `Transport.swift` | the transport and token-source protocols, and the backoff ladder |
| `UnixSocketTransport.swift` | the socket, on one private queue |
| `NetworkTransport.swift` | TCP with TLS and a pinned certificate, for the phone |
| `Keychain.swift` | the secret store, the paired machines and their tokens |
| `PairingSession.swift` | redeeming a pairing code, once, over its own connection |
| `DaemonClient.swift` | handshake, request ids, deadlines, reconnect |

## The two ways in

`DaemonClient` is given a `DaemonTransport` and a `TokenSource` and never builds either itself.
That is what `DESIGN.md` § Mobil, Technik der Clients asks for, and it is the whole difference
between the two clients:

| | desktop shell | iOS app |
|---|---|---|
| transport | `UnixSocketTransport` | `NetworkTransport`, TLS with the pinned certificate |
| token | `FileTokenSource`, the file the daemon wrote | `KeychainTokenSource`, out of the pairing |

Everything between the two, the handshake, the request ids, the deadlines, the backoff ladder,
is the same code.

## The token

The daemon writes `tokens.json` into its configuration directory on its first start, mode
0600, and the shell reads the `human` entry from it. It is read again on every connection
attempt, so a daemon that regenerated its tokens is picked up without restarting the shell,
and a missing file is the normal state before the daemon has ever run: the client says so and
keeps retrying.

The phone has no such file. Its token comes out of the pairing, is kept in the keychain as part
of a `PairedMachine`, and is read again on every attempt for the same reason: a machine that was
un-paired and paired anew has a new token.

## The pin

At the network port the app never asks the system whether the certificate is good.
`DESIGN.md` § Mobil, Identität und Vertrauen makes the daemon certificate deliberately
long-lived so the pin never breaks, and Apple's own evaluation refuses a server certificate
valid for more than 398 days, so the certificate is compared, in the connection's own verify
block, against the SHA-256 that came out of the pairing QR and against nothing else. A
mismatch ends the connection; it is never a question put to the person.

## Deadlines

Nothing here waits without an end. A request that gets no answer within its timeout fails
locally rather than leaving a caller hanging, a lost connection fails every request that was
still open, and reconnect uses a capped backoff so a daemon that is not running costs
nothing.

## Coming back from the background

`resumeFromForeground()` does not believe a status of `.ready`. That is the one state that lies
on a phone: iOS froze the app, nothing was read or written, and a socket keeps saying it is open
until somebody tries. So the transport is asked whether it still carries; `NetworkTransport`
answers from `NWConnection`'s viability, and if it says yes, the daemon is asked `get_settings`
under a short deadline. An answer of any kind, a refusal included, proves the line. A deadline
that passes closes the connection and the ordinary reconnect takes over, on the bottom rung.

## One queue

Every transport delivers its handlers on the main queue. `DaemonClient` and `PairingSession` are
on the main actor and read what arrives without a hop, which only holds because of that; both
check it with a `dispatchPrecondition`, so a transport that breaks the contract says so at the
first line instead of corrupting state quietly.
