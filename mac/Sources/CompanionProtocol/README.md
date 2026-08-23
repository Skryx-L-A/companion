# CompanionProtocol

The shell's connection to the daemon. This module is a placeholder and is meant to be
replaced.

## What is fixed and what is not

Fixed for now is only the envelope:

```json
{"protocol_version": 1, "kind": "sessions_changed", "payload": {"sessions": []}}
```

The payload is not modelled. It arrives as a `JSONValue`, and call sites read single fields
out of it and tolerate every one of them being absent. The real schema is being written in
`app/protocol/schema/*.json` by the daemon track; until it exists, guessing at payload types
here would only produce a second definition to keep in sync.

Two further decisions belong to this shell rather than to the protocol, and both may change
when the schema lands: messages are framed as one JSON object per line, and the client
announces itself with a `hello` envelope carrying the role `human`.

## Parts

`Envelope` and `EnvelopeCodec` encode and decode a message. `LineFramer` cuts a byte stream
into lines and keeps the remainder, so a message split across two reads still arrives whole.
`UnixSocketTransport` holds the socket and does all of its work on one private queue.
`DaemonClient` sits on top: it connects, retries with a growing delay while the daemon is
absent, checks the protocol version, and hands everything else to the shell on the main queue.

Authentication is not implemented. Tokens live in the system keychain per DESIGN.md, section
Sicherheit, and the daemon side of that does not exist yet.

## Replacing it

When the schema is final, the envelope stays and the payload handling goes. Generate types
from `app/protocol/schema/*.json`, replace `JSONValue` with them, and adjust the two places
that read payloads: `SessionDecoding` in `CompanionUI` and the `handle(_ envelope:)` method in
`CompanionShell`. Nothing else in the shell touches the wire format.
