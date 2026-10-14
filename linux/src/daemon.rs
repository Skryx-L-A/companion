// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Startet den Daemon selbst, wenn niemand am Socket antwortet.
//!
//! Das Gegenstück zu `DaemonLauncher.swift` auf dem Mac: die Shell soll sich wie jede andere
//! Anwendung öffnen lassen, ohne dass jemand den Daemon vorher von Hand startet. Ob der
//! gestartete Daemon wirklich hochkam, sagt allein die gewöhnliche Wiederverbindung der Shell
//! (`reconnect::ReconnectSchedule`) — überwacht wird das Kind nicht.
//!
//! Festgehalten wird es aber: Wer den Daemon selbst gestartet hat, beendet ihn beim Beenden
//! auch wieder ([`stop`]). Sonst bliebe nach jedem Schließen der Shell ein Daemon zurück, den
//! niemand mehr sieht, und beim nächsten Start liefe er weiter, obwohl ihn keiner mehr
//! angefordert hat. Einen Daemon, der schon lief, fasst die Shell dagegen nicht an: Er kann
//! dem Handy, einem Agenten oder einer zweiten Shell gehören.

use std::fs::{self, OpenOptions};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Wie lange ein Daemon Zeit bekommt, sich nach `SIGTERM` selbst zu beenden, bevor `SIGKILL`
/// nachkommt. Zwei Sekunden, weil hier nur noch das Beenden der Shell darauf wartet.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

/// Ob am Socket gerade etwas antwortet.
///
/// Kein Beweis, dass der Daemon dahinter gesund ist, nur, dass ein weiterer Start das
/// Bindewettrennen verlöre, das der Daemon schon selbst führt (`fn bind` in
/// `app/crates/companion-daemon/src/server.rs`): Es prüft mit demselben Mittel — einem
/// Verbindungsversuch —, ob eine Socket-Datei tot ist, bevor es sie für eine hält, die
/// niemand mehr bedient.
///
/// Jeder Fehlschlag zählt gleich als "tot" — ob nichts am Pfad liegt, eine tote Socket-Datei
/// dort liegt, oder irgendeine andere Datei zufällig genau an diesem Pfad. Das entscheidet
/// hier nichts Neues: `bind()` in `server.rs` räumt eine nicht antwortende Datei am Socketpfad
/// schon immer bedingungslos weg, unverändert von diesem Selbststart. Neu ist nur, dass dieser
/// Weg jetzt bei jedem kalten App-Start automatisch läuft statt nur, wenn jemand den Daemon
/// von Hand startete — der Konfigurationsordner ist 0700, also kann an diesem Pfad ohnehin
/// nur eine Datei desselben Benutzers liegen.
pub fn is_alive(socket: &Path) -> bool {
    UnixStream::connect(socket).is_ok()
}

/// Wo das Daemon-Binary liegt, wenn niemand es ausdrücklich genannt hat: neben dem eigenen
/// Binary zuerst — das legt `tools/install-linux.sh` dorthin —, sonst ein blanker Name für
/// die `PATH`-Suche, die `Command::spawn` für einen Namen ohne Trenner selbst schon macht.
pub fn locate_binary(own_executable: io::Result<PathBuf>) -> PathBuf {
    if let Ok(own) = own_executable {
        if let Some(directory) = own.parent() {
            let candidate = directory.join("companion-daemon");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    PathBuf::from("companion-daemon")
}

/// Feste Umgebung, die der gespawnte Daemon sieht, alles andere wird gelöscht.
///
/// Spiegelt `GATE_ENV_ALLOW` in `companion-daemon/src/gate.rs` und `INHERITED_ENV` in
/// `companion-voice/src/server.rs`: eine kleine, vorhersagbare Umgebung statt der vollen
/// Vererbung von dem, was diese Shell selbst gerade zufällig mitbrachte — eine
/// Entwicklerterminalsitzung mit exportierten Zugangsdaten zum Beispiel erreichte den Daemon
/// sonst bei jedem kalten App-Start, nicht nur, wenn jemand ihn selbst von Hand anwarf. Über
/// die fünf Variablen hinaus, die beide Vorbilder schon führen (`PATH`/`HOME`/`LANG`/
/// `LC_ALL`/`TMPDIR`), liest der Daemon selbst `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`
/// (`companion-core::paths::config_dir`/`socket_path`) und reicht `CODEX_HOME`/`HERMES_HOME`
/// an zwei seiner Adapter weiter; die Workbench-, Claude- und Codex-Adapter starten selbst
/// wieder Kindprozesse (`claude`, `codex`, `wb-code`, …), die `PATH` und `HOME` zwingend
/// brauchen, um ihre eigene Konfiguration zu finden — ohne die beiden bräche also nicht nur
/// dieser Selbststart, sondern jeder Adapter. Die Proxy-Variablen sind die einzige echte
/// Netzwerkabhängigkeit: `companion-voice`s Client zu einem entfernten Endpunkt geht über
/// `reqwest`, das sie selbst liest; beide Schreibweisen, weil Werkzeuge sich darin
/// unterscheiden, welche sie prüfen. `USER`/`LOGNAME` stehen für die KINDER auf der Liste,
/// nicht für den Daemon selbst: `claude` löst seine gespeicherte Anmeldung darüber auf, und
/// ohne `USER` beantwortete es jede Chat-Runde mit „Not logged in" — gemessen 2026-08-26
/// beim ersten echten Lauf.
const DAEMON_ENV_ALLOW: [&str; 19] = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "TMPDIR",
    "XDG_CONFIG_HOME",
    "XDG_RUNTIME_DIR",
    "CODEX_HOME",
    "HERMES_HOME",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
];

/// Der PATH, mit dem die Kinder des Daemons wirklich arbeiten können.
///
/// Eine über den Anwendungsstarter geöffnete Shell erbt den schmalen PATH der Sitzung —
/// ohne `~/.local/bin` und `~/.cargo/bin` findet der Workbench-Adapter weder `tmux`-Helfer
/// noch `wb-state` und meldet jede je geschriebene Zustandsdatei als laufende Session
/// (auf dem Mac gemessen: 474 Karteileichen beim ersten echten Lauf, 2026-08-27). Die
/// bekannten Verzeichnisse werden ANGEHÄNGT, wenn sie existieren und fehlen — angehängt,
/// nicht vorangestellt, damit ein bewusst gesetzter PATH seine Ordnung behält.
fn completed_path(inherited: Option<String>) -> String {
    let mut parts: Vec<String> = inherited
        .unwrap_or_else(|| "/usr/bin:/bin".to_string())
        .split(':')
        .map(str::to_string)
        .collect();
    let home = std::env::var("HOME").unwrap_or_default();
    for candidate in [
        format!("{home}/.local/bin"),
        format!("{home}/.cargo/bin"),
        "/usr/local/bin".to_string(),
    ] {
        if !parts.contains(&candidate) && std::path::Path::new(&candidate).is_dir() {
            parts.push(candidate);
        }
    }
    parts.join(":")
}

/// Startet den Daemon, wenn der Socket tot ist. Gibt das Kind zurück, wenn eines entstand.
///
/// `COMPANION_SOCKET` geht als Umgebungsvariable ausdrücklich mit, egal woher `socket`
/// eigentlich kam (Vorgabe oder `--socket`): Nur so bindet der gestartete Daemon garantiert
/// auf denselben Pfad, den diese Shell gleich anfragt. `config_dir` bekommt dieselbe
/// Behandlung, damit Token- und Einstellungsdatei mit dem übereinstimmen, was diese Shell
/// selbst aus `paths::config_dir()` gelesen hat.
///
/// Das eigene Protokoll des Daemons geht in `daemon.log` neben den Rest seiner Dateien, nie
/// auf die eigene Standardausgabe dieser Shell: `stdout`/`stderr` teilt sich sonst niemand,
/// und nichts hier soll sie mit Zeilen füllen, die der Shell nicht gehören.
pub fn launch_if_needed(
    binary: &Path,
    config_dir: &Path,
    socket: &Path,
) -> io::Result<Option<Child>> {
    if is_alive(socket) {
        return Ok(None);
    }

    fs::create_dir_all(config_dir)?;
    fs::set_permissions(config_dir, fs::Permissions::from_mode(0o700))?;

    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(config_dir.join("daemon.log"))?;
    let log_for_stderr = log.try_clone()?;

    let mut process = Command::new(binary);
    process.env_clear();
    for key in DAEMON_ENV_ALLOW {
        if let Ok(value) = std::env::var(key) {
            process.env(key, value);
        }
    }
    // `COMPANION_*` geht als Ganzes durch statt nur der beiden unten fest gesetzten: eine
    // Person kann `COMPANION_LOG` oder `COMPANION_TOKEN_STORE` gesetzt haben, bevor sie diese
    // Shell startete, und das soll beim Daemon ankommen wie zuvor, ohne dass diese Liste jede
    // neue `COMPANION_*`-Variable einzeln nachführen muss.
    for (key, value) in std::env::vars() {
        if key.starts_with("COMPANION_") {
            process.env(key, value);
        }
    }
    let child = process
        .env("COMPANION_CONFIG_DIR", config_dir)
        .env("COMPANION_SOCKET", socket)
        .env("PATH", completed_path(std::env::var("PATH").ok()))
        // Beschreibbares Arbeitsverzeichnis: über den Starter geöffnet sässe der Daemon
        // sonst auf `/`, und ein Kind, das relativ schreibt, träfe die Wurzel (der
        // Sprachserver tat genau das mit seinem relativen `logs`-Verzeichnis).
        .current_dir(config_dir)
        .stdin(Stdio::null())
        .stdout(log)
        .stderr(log_for_stderr)
        .spawn()?;
    Ok(Some(child))
}

/// Beendet einen selbst gestarteten Daemon und wartet, bis er wirklich weg ist.
///
/// Erst `SIGTERM` über das ausgelieferte `kill`, damit der Daemon seine Dateien zu Ende
/// schreiben und den Socket abräumen kann; `Child::kill` allein wäre `SIGKILL` und damit ein
/// Abbruch mitten im Schreiben. Ohne `unsafe` gibt es in der Standardbibliothek kein
/// `SIGTERM` — und `unsafe` ist in dieser Kiste verboten (`Cargo.toml`), aus gutem Grund.
/// Kommt der Daemon binnen [`SHUTDOWN_GRACE`] nicht von selbst, folgt doch `SIGKILL`.
///
/// `wait` am Ende ist keine Höflichkeit: Ohne es bliebe ein Zombie stehen, solange diese
/// Shell noch läuft.
pub fn stop(mut child: Child) {
    let _ = Command::new("kill")
        .arg("-TERM")
        .arg(child.id().to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    let deadline = Instant::now() + SHUTDOWN_GRACE;
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn short_socket_path(name: &str) -> PathBuf {
        // `sockaddr_un.sun_path` ist auch unter Linux nur gut hundert Byte lang; ein Pfad
        // direkt unter `/tmp` bleibt sicher darunter, ein tief verschachtelter Testordner
        // nicht unbedingt.
        std::env::temp_dir().join(format!(
            "companion-daemon-test-{}-{name}",
            std::process::id()
        ))
    }

    #[test]
    fn nothing_at_the_path_reads_as_dead() {
        let socket = short_socket_path("nothing.sock");
        let _ = fs::remove_file(&socket);
        assert!(!is_alive(&socket));
    }

    #[test]
    fn a_stale_file_with_nobody_behind_it_reads_as_dead() {
        let socket = short_socket_path("stale.sock");
        fs::write(&socket, b"stale").unwrap();
        assert!(!is_alive(&socket));
        let _ = fs::remove_file(&socket);
    }

    #[test]
    fn something_listening_reads_as_alive() {
        let socket = short_socket_path("alive.sock");
        let _ = fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        assert!(is_alive(&socket));
        drop(listener);
        let _ = fs::remove_file(&socket);
    }

    #[test]
    fn without_a_bundle_it_falls_back_to_a_bare_name() {
        let found = locate_binary(Err(io::Error::other("kein eigener Pfad in diesem Test")));
        assert_eq!(found, PathBuf::from("companion-daemon"));
    }

    #[test]
    fn a_binary_next_to_the_executable_wins() {
        let directory =
            std::env::temp_dir().join(format!("companion-daemon-bin-test-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let bundled = directory.join("companion-daemon");
        fs::write(&bundled, b"").unwrap();
        fs::set_permissions(&bundled, fs::Permissions::from_mode(0o755)).unwrap();

        let own_executable = directory.join("companion-linux");
        let found = locate_binary(Ok(own_executable));
        assert_eq!(found, bundled);

        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn launch_if_needed_does_nothing_when_the_socket_already_answers() {
        let socket = short_socket_path("already-up.sock");
        let _ = fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let config_dir = std::env::temp_dir().join(format!(
            "companion-daemon-launch-test-{}",
            std::process::id()
        ));

        let launched = launch_if_needed(
            Path::new("/does/not/exist/companion-daemon"),
            &config_dir,
            &socket,
        )
        .unwrap();
        assert!(launched.is_none());

        drop(listener);
        let _ = fs::remove_file(&socket);
        let _ = fs::remove_dir_all(&config_dir);
    }

    #[test]
    fn launch_if_needed_spawns_a_process_when_the_socket_is_dead() {
        let socket = short_socket_path("dead.sock");
        let _ = fs::remove_file(&socket);
        let config_dir = std::env::temp_dir().join(format!(
            "companion-daemon-launch-spawn-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&config_dir);

        // `/bin/true` steht für den Daemon ein: existiert auf jedem Linux, endet sofort, und
        // beweist die Mechanik des Starts (Umgebungsvariablen, Protokolldatei,
        // `Command::spawn`) ohne das echte Rust-Binary gebaut zu haben.
        let launched = launch_if_needed(Path::new("/bin/true"), &config_dir, &socket).unwrap();
        let child = launched.expect("ein toter Socket führt zu einem Kind");
        assert!(config_dir.join("daemon.log").exists());
        // Festgehalten heißt: Die Shell kann es später auch wieder beenden.
        stop(child);

        let _ = fs::remove_dir_all(&config_dir);
    }

    /// Der Fehler, den Skryx-L-A gemeldet hat, in seiner zweiten Hälfte: Ein selbst
    /// gestarteter Daemon muss beim Beenden mitgehen. `sleep` steht dafür ein — ein Prozess,
    /// der von selbst nicht endet, also nur deshalb weg ist, weil er beendet wurde.
    #[test]
    fn stop_ends_a_child_that_would_otherwise_keep_running() {
        let child = Command::new("sleep")
            .arg("30")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id();

        let started = Instant::now();
        stop(child);
        assert!(
            started.elapsed() < SHUTDOWN_GRACE,
            "SIGTERM hat nicht gereicht"
        );

        // Kein `kill -0` auf die pid: Die ist nach dem `wait` wieder frei und könnte in der
        // Zwischenzeit jemand anderem gehören. Dass `stop` zurückkam, bevor die Frist um war,
        // heißt bereits, dass `try_wait` den Prozess als beendet gesehen hat.
        assert!(pid > 0);
    }
}
