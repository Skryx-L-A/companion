// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The connection to the local daemon: one Unix socket, one JSON object per line.
//!
//! Reading happens on its own thread, because the GTK main loop must never block on a socket;
//! what it reads goes to the user interface over an [`async_channel`], which `glib` can await
//! on the main thread. Writing happens straight from the main thread: a request is a few
//! hundred bytes and fits in the socket buffer, so there is nothing to wait for.
//!
//! Unknown messages are counted, not treated as errors. `DESIGN.md` § Architektur,
//! Protokoll-Kompatibilität: additive changes do not break a client, but a version gap has to
//! be visible rather than silent, which is what [`Incoming::Ignored`] is for.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use companion_protocol::{
    ClientMessage, Hello, MIN_SUPPORTED_PROTOCOL_VERSION, PROTOCOL_VERSION, Request,
    RequestEnvelope, RequestId, ServerMessage, WORLD_EVENTS_CAPABILITY,
};

/// The same ceiling the daemon puts on one line (`companion-daemon`, `Limits`). A line longer
/// than this cannot have come from the daemon, so the shell stops reading instead of growing
/// a buffer without end.
pub const MAX_LINE_BYTES: usize = 1024 * 1024;

/// The name this shell gives itself in the daemon's connection list.
pub const CLIENT_NAME: &str = "companion-linux";

#[derive(Debug)]
pub enum ClientError {
    NoSocket {
        path: PathBuf,
        source: std::io::Error,
    },
    NoToken {
        path: PathBuf,
        reason: String,
    },
    /// Die Zeile, die hinausgehen sollte, ist länger als der Daemon eine annimmt.
    ///
    /// Ohne diese Prüfung ginge sie hinaus, der Daemon antwortete mit `bad_request` und
    /// schlösse die Verbindung, und im Panel stünde nur, er habe aufgelegt. Die Grenze gilt
    /// beidseitig, also prüft die Shell sie auch beidseitig.
    LineTooLong {
        bytes: usize,
        limit: usize,
    },
    Io(std::io::Error),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // German, because this reaches the person in the panel.
            Self::NoSocket { path, source } => write!(
                f,
                "Kein Daemon an {}: {source}. Läuft companion-daemon?",
                path.display()
            ),
            Self::NoToken { path, reason } => {
                write!(f, "Kein Token in {}: {reason}", path.display())
            }
            Self::LineTooLong { bytes, limit } => write!(
                f,
                "Die Nachricht ist {bytes} Bytes lang, der Daemon nimmt höchstens {limit}."
            ),
            Self::Io(source) => write!(f, "Verbindungsfehler: {source}"),
        }
    }
}

impl std::error::Error for ClientError {}

/// What the reader thread hands the user interface.
#[derive(Debug)]
pub enum Incoming {
    Message(Box<ServerMessage>),
    /// A well-formed JSON line this build does not understand — a newer daemon's event or
    /// response. Counted and shown, never acted on.
    Ignored {
        raw: String,
    },
    /// The line was not JSON at all, or the connection broke. The connection is over.
    Closed {
        reason: Option<String>,
    },
}

/// The human's token out of the daemon's fallback token file.
///
/// Linux has no keychain the shell can count on, so the file the daemon writes is also what
/// the shell reads. Only the `human` token: a shell that presented the agent one would be
/// asking the daemon to treat the person as a docked orchestrator.
pub fn read_human_token(path: &Path) -> Result<String, ClientError> {
    let text = std::fs::read_to_string(path).map_err(|source| ClientError::NoToken {
        path: path.to_path_buf(),
        reason: source.to_string(),
    })?;
    let parsed: serde_json::Value =
        serde_json::from_str(&text).map_err(|source| ClientError::NoToken {
            path: path.to_path_buf(),
            reason: source.to_string(),
        })?;
    parsed
        .get("human")
        .and_then(serde_json::Value::as_str)
        .filter(|token| !token.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| ClientError::NoToken {
            path: path.to_path_buf(),
            reason: "die Datei nennt kein Feld human".to_owned(),
        })
}

/// A connected socket, plus the request counter that matches answers to questions.
pub struct DaemonClient {
    writer: Arc<Mutex<UnixStream>>,
    next_id: std::cell::Cell<RequestId>,
}

impl DaemonClient {
    /// Connects, says hello and starts the reader thread.
    ///
    /// The [`Welcome`](companion_protocol::Welcome) is not awaited here: it arrives on the
    /// receiver like every other message, so the user interface has one place where daemon
    /// messages turn up instead of two.
    pub fn connect(
        socket: &Path,
        token: String,
    ) -> Result<(Self, async_channel::Receiver<Incoming>), ClientError> {
        let stream = UnixStream::connect(socket).map_err(|source| ClientError::NoSocket {
            path: socket.to_path_buf(),
            source,
        })?;
        let reader = stream.try_clone().map_err(ClientError::Io)?;

        let (sender, receiver) = async_channel::unbounded();
        std::thread::Builder::new()
            .name("companion-daemon-reader".to_owned())
            .spawn(move || read_lines(reader, sender))
            .map_err(ClientError::Io)?;

        let client = Self {
            writer: Arc::new(Mutex::new(stream)),
            next_id: std::cell::Cell::new(1),
        };
        client.say_hello(token)?;
        Ok((client, receiver))
    }

    fn say_hello(&self, token: String) -> Result<(), ClientError> {
        // The full range this build speaks, not only the preferred version: the daemon
        // answers with the highest version both sides know.
        self.write(&ClientMessage::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            min_protocol_version: Some(MIN_SUPPORTED_PROTOCOL_VERSION),
            max_protocol_version: Some(PROTOCOL_VERSION),
            token,
            client_name: CLIENT_NAME.to_owned(),
            // No voice in this shell yet, so nothing to negotiate a format for.
            audio_formats: Vec::new(),
            // This shell puts world notices into its notice log and confirms that with
            // `notice_shown`, so the daemon may count it as a listener.
            client_capabilities: vec![WORLD_EVENTS_CAPABILITY.to_owned()],
        }))
    }

    /// Sends one request and returns the id its answer will carry.
    pub fn send(&self, request: Request) -> Result<RequestId, ClientError> {
        let id = self.next_id.get();
        self.next_id.set(id.wrapping_add(1).max(1));
        self.write(&ClientMessage::Request(RequestEnvelope { id, request }))?;
        Ok(id)
    }

    fn write(&self, message: &ClientMessage) -> Result<(), ClientError> {
        let mut line = serde_json::to_vec(message).map_err(|source| {
            ClientError::Io(std::io::Error::other(format!(
                "Nachricht nicht kodierbar: {source}"
            )))
        })?;
        line.push(b'\n');
        if line.len() > MAX_LINE_BYTES {
            return Err(ClientError::LineTooLong {
                bytes: line.len(),
                limit: MAX_LINE_BYTES,
            });
        }
        let mut stream = self.writer.lock().map_err(|_| {
            ClientError::Io(std::io::Error::other("die Schreibsperre ist zerbrochen"))
        })?;
        stream.write_all(&line).map_err(ClientError::Io)?;
        stream.flush().map_err(ClientError::Io)
    }

    /// Closes the socket in both directions, which ends the reader thread.
    pub fn shutdown(&self) {
        if let Ok(stream) = self.writer.lock() {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

fn read_lines(stream: UnixStream, sender: async_channel::Sender<Incoming>) {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        // `take` rather than a bare `read_line`: a daemon that never sent a newline would
        // otherwise grow this buffer until the machine runs out of memory.
        let read = (&mut reader)
            .take(MAX_LINE_BYTES as u64 + 1)
            .read_line(&mut line);
        let outgoing = match read {
            Ok(0) => Incoming::Closed { reason: None },
            Ok(bytes) if bytes > MAX_LINE_BYTES => Incoming::Closed {
                reason: Some(format!(
                    "Der Daemon schickte eine Zeile über {MAX_LINE_BYTES} Bytes."
                )),
            },
            Ok(_) => match classify(line.trim_end_matches('\n')) {
                // Eine leere Zeile ist nichts, wovon die Gegenseite berichten müsste. Sie
                // vorher wegzuwerfen ist der Unterschied zwischen "der Daemon ist neuer als
                // diese Shell" und einem Zeilenumbruch zu viel.
                None => continue,
                Some(incoming) => incoming,
            },
            Err(source) => Incoming::Closed {
                reason: Some(source.to_string()),
            },
        };
        let closed = matches!(outgoing, Incoming::Closed { .. });
        if sender.send_blocking(outgoing).is_err() || closed {
            return;
        }
    }
}

/// Sorts one line into understood, understood-as-unknown, and broken.
///
/// A line that parses as JSON but not as a [`ServerMessage`] is a newer daemon's message, and
/// the plan says to ignore and count it. A line that is not JSON is not a protocol version
/// gap but a broken stream, and the connection ends.
fn classify(line: &str) -> Option<Incoming> {
    if line.trim().is_empty() {
        return None;
    }
    Some(match serde_json::from_str::<ServerMessage>(line) {
        Ok(message) => Incoming::Message(Box::new(message)),
        Err(_) => match serde_json::from_str::<serde_json::Value>(line) {
            Ok(_) => Incoming::Ignored {
                raw: line.to_owned(),
            },
            Err(source) => Incoming::Closed {
                reason: Some(format!("Der Daemon schickte kein JSON: {source}")),
            },
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_known_message_is_understood() {
        let line = r#"{"type":"welcome","protocol_version":1,"role":"human","daemon_version":"0.1.0","run_id":"r","session_namespace":"n"}"#;
        assert!(matches!(classify(line), Some(Incoming::Message(_))));
    }

    #[test]
    fn an_event_this_build_never_heard_of_is_ignored_and_not_an_error() {
        // What a newer daemon looks like from here: a well-formed line with an event name
        // this build does not know.
        let line = r#"{"type":"event","sequence":4,"run_id":"r","timestamp_ms":0,"adapter":"workbench","session_id":null,"event":{"event":"weather_changed","outlook":"regnerisch"}}"#;
        match classify(line) {
            Some(Incoming::Ignored { raw }) => assert!(raw.contains("weather_changed")),
            other => panic!("must be ignored, got {other:?}"),
        }
    }

    #[test]
    fn a_known_event_with_an_unknown_field_still_arrives() {
        let line = r#"{"type":"event","sequence":4,"run_id":"r","timestamp_ms":0,"adapter":"workbench","session_id":"s","event":{"event":"busy","spin_rate":7}}"#;
        assert!(
            matches!(classify(line), Some(Incoming::Message(_))),
            "an added field must not cost the whole event"
        );
    }

    #[test]
    fn a_line_that_is_not_json_ends_the_connection() {
        assert!(matches!(
            classify("dies ist kein JSON"),
            Some(Incoming::Closed { .. })
        ));
    }

    /// Sonst zählte ein Zeilenumbruch zu viel als "der Daemon ist neuer als diese Shell".
    #[test]
    fn eine_leere_zeile_ist_keine_versionsluecke() {
        assert!(classify("").is_none());
        assert!(classify("   ").is_none());
    }

    #[test]
    fn a_token_file_without_a_human_token_is_refused_by_name() {
        let dir =
            std::env::temp_dir().join(format!("companion-linux-token-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tokens.json");

        std::fs::write(&path, r#"{"agent":"nur-der-agent"}"#).unwrap();
        let error = read_human_token(&path).expect_err("must refuse");
        assert!(error.to_string().contains("human"), "got {error}");

        std::fs::write(&path, r#"{"human":"geheim","agent":"auch-geheim"}"#).unwrap();
        assert_eq!(read_human_token(&path).unwrap(), "geheim");

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
