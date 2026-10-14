// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Puts the pieces together: the figure, the panel, and the connection that feeds them.

pub mod overlay;
pub mod panel;

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::process::Child;
use std::rc::Rc;

use companion_protocol::{
    ClientRole, Event, Request, RequestId, ResponseBody, ResponseResult, ServerMessage,
    SessionStatus,
};
use gtk4::prelude::*;
use gtk4::{gio, glib};

use crate::chat::ChatLog;
use crate::client::{DaemonClient, Incoming, read_human_token};
use crate::figure::FigureEvent;
use crate::mapping;
use crate::options::Options;
use crate::paths;
use crate::reconnect::ReconnectSchedule;
use crate::theme::Styles;
use crate::tray::{self, CompanionTray, TrayCommand};

use overlay::Overlay;
use panel::Panel;

/// Reverse-DNS name of the application, the Linux counterpart of the Mac bundle identifier
/// `de.skryx.companion.mac`.
pub const APPLICATION_ID: &str = "de.skryx.companion.linux";

pub fn run(options: Options) -> glib::ExitCode {
    let application = gtk4::Application::builder()
        .application_id(APPLICATION_ID)
        .flags(gio::ApplicationFlags::empty())
        .build();

    // Ein abgelehnter Start endet mit einem Fehler-Code, nicht mit dem Erfolg, den
    // `Application::run` für ein sauber beendetes Programm zurückgibt.
    let refused = Rc::new(Cell::new(false));
    let refusal = Rc::clone(&refused);

    // Die Shell muss hier festgehalten werden. Jeder Rückruf hält nur ein `Weak`, damit
    // Panel und Shell einander nicht gegenseitig am Leben halten — ohne diese eine starke
    // Referenz fiele sie am Ende von `activate` sofort wieder, und danach liefe zwar noch ein
    // Fenster, aber nichts mehr darin. Der Rückruf lebt so lange wie die Anwendung, also die
    // Shell auch, und beim Beenden fällt sie mit ihm.
    let kept: RefCell<Option<Rc<Shell>>> = RefCell::new(None);
    application.connect_activate(move |application| match Shell::new(application, &options) {
        Ok(shell) => {
            shell.start(application);
            *kept.borrow_mut() = Some(shell);
        }
        Err(reason) => {
            eprintln!("{reason}");
            refusal.set(true);
            application.quit();
        }
    });
    // The arguments were parsed before GTK saw them, so GTK is given none of its own.
    let code = application.run_with_args::<&str>(&[]);
    if refused.get() {
        glib::ExitCode::FAILURE
    } else {
        code
    }
}

/// Sagt Nein, wenn diese Anzeige die Figur nicht als Overlay tragen kann.
///
/// `gtk_layer_init_for_window` schreibt in diesem Fall nur eine Warnung und lässt das Fenster
/// ein gewöhnliches Fenster sein. Ein Kachel-Compositor zieht das dann über den ganzen
/// Bildschirm, und die Figur wird auf dessen Kantenlänge skaliert — auf Hyprland waren das
/// achthundert Bildpunkte statt der angeforderten zweihundertsechsundfünfzig, mit einem
/// Fensterrahmen um den ganzen Bildschirm. Genau dann tritt der Fall ein, wenn GTK gar nicht
/// auf Wayland läuft, sondern über XWayland, weil `WAYLAND_DISPLAY` auf keinen Socket zeigt.
/// Ein lautes Nein ist besser als eine bildschirmfüllende Figur.
fn refuse_without_layer_shell(display: &gtk4::gdk::Display) -> Result<(), String> {
    // Die Anzeige wird zuerst nach ihrem Typ gefragt und erst danach nach dem Protokoll:
    // `is_supported` greift auf die Wayland-Registry zu und schreibt auf einer X11-Anzeige
    // eine GTK-CRITICAL-Zeile, bevor es Nein sagt. Diese Zeile sähe aus wie ein Absturz und
    // stünde ausgerechnet vor der Erklärung darunter. Der Name des Typs ist der Weg dahin,
    // den gdk4-wayland als eigene Abhängigkeit nicht wert ist.
    if display.type_().name() == "GdkWaylandDisplay" && gtk4_layer_shell::is_supported() {
        return Ok(());
    }
    Err(
        "Diese Anzeige kann kein wlr-layer-shell, und die Figur ist ein Overlay, das ohne \
         dieses Protokoll nicht auskommt. Als gewöhnliches Fenster würde sie den ganzen \
         Bildschirm einnehmen, statt klein in einer Ecke zu sitzen. Läuft die Shell über \
         XWayland statt auf Wayland, fehlt meist nur ein richtig gesetztes WAYLAND_DISPLAY."
            .to_owned(),
    )
}

/// Sucht den benannten Bildschirm heraus, oder sagt, welche es gibt.
fn chosen_monitor(
    display: &gtk4::gdk::Display,
    name: Option<&str>,
) -> Result<Option<gtk4::gdk::Monitor>, String> {
    let Some(name) = name else {
        return Ok(None);
    };
    match overlay::monitor_named(display, name) {
        Some(monitor) => Ok(Some(monitor)),
        None => {
            let known = overlay::monitor_names(display);
            Err(if known.is_empty() {
                format!(
                    "Es gibt keinen Bildschirm namens {name}, und diese Anzeige nennt gar keinen."
                )
            } else {
                format!(
                    "Es gibt keinen Bildschirm namens {name}. Vorhanden sind: {}.",
                    known.join(", ")
                )
            })
        }
    }
}

/// Alles, was die Shell zwischen zwei Nachrichten weiß, an einer Stelle.
///
/// Ein `Rc`, weil jede Rückrufstelle in GTK etwas davon braucht; die Rückrufe halten nur ein
/// `Weak`, sonst hielte das Panel die Shell und die Shell das Panel für immer am Leben.
struct Shell {
    figure: Rc<Overlay>,
    panel: Rc<Panel>,
    /// Schwach, aus demselben Grund wie unten bei den Rückrufen: Die Anwendung hält über den
    /// Aktivierungs-Rückruf am Ende ein `Rc<Shell>` (`kept` in [`run`]), also darf die Shell
    /// nicht ihrerseits eine starke Referenz auf die Anwendung zurückhalten.
    application: glib::WeakRef<gtk4::Application>,
    socket: PathBuf,
    /// Wo der Daemon liegt, falls er beim Start noch selbst gestartet werden muss
    /// (`daemon::launch_if_needed`).
    daemon_binary: PathBuf,
    /// Der Daemon, den diese Shell selbst gestartet hat, und nur der. Wer schon lief, bleibt
    /// auch stehen: Er kann dem Handy, einem Agenten oder einer zweiten Shell gehören.
    daemon_child: RefCell<Option<Child>>,
    /// Die Farben des Systems. Festgehalten, weil in ihm die Beobachter hängen, die den
    /// Theme-Wechsel mitbekommen — fiele er, färbte sich die Shell nie wieder um.
    styles: Rc<Styles>,
    /// Die aktuelle Verbindung. `None`, solange keine steht — beim Start und zwischen zwei
    /// Versuchen der Staffel.
    client: RefCell<Option<Rc<DaemonClient>>>,
    chat: RefCell<ChatLog>,
    /// Mit wem gesprochen wird. Einmal beim Handschlag geschrieben und dann stehengelassen.
    connection: RefCell<String>,
    /// Das Letzte, was über die Verbindung zu sagen war, neben der Zeile darüber statt
    /// anstelle von ihr: Ein Fehler, der sie ersetzte, nähme den Namen des Daemons mit.
    note: RefCell<String>,
    ignored: Cell<u64>,
    /// Die Anfrage-id der Chatnachricht, deren Antwort noch aussteht.
    ///
    /// Die id und nicht nur ein Ja/Nein: Die Shell schickt `list` von einem halben Dutzend
    /// Stellen aus, und eine dieser Anfragen, die mit einem Fehler zurückfällt, darf nicht
    /// die laufende Chatantwort für beendet erklären.
    pending_chat: Cell<Option<RequestId>>,
    /// Die zuletzt gesehene Sitzungsliste, für die Neuberechnung der erhobenen Hand.
    sessions: RefCell<Vec<SessionStatus>>,
    schedule: RefCell<ReconnectSchedule>,
    /// Der Tray-Dienst, solange einer läuft. `None`, wenn die Registrierung fehlschlug — das
    /// Fenster bleibt dann trotzdem, der Tray ist ein Zweitzugang, kein Erstzugang.
    tray: RefCell<Option<ksni::blocking::Handle<CompanionTray>>>,
}

impl Shell {
    fn new(application: &gtk4::Application, options: &Options) -> Result<Rc<Self>, String> {
        let display = gtk4::gdk::Display::default()
            .ok_or_else(|| "Es gibt keine Anzeige, auf der die Figur sitzen könnte.".to_owned())?;
        refuse_without_layer_shell(&display)?;
        let styles = Styles::install(&display);
        let monitor = chosen_monitor(&display, options.monitor.as_deref())?;

        Ok(Rc::new(Self {
            figure: Rc::new(Overlay::new(application, options, monitor.as_ref())),
            panel: Rc::new(Panel::new(application, options, monitor.as_ref())),
            application: application.downgrade(),
            socket: options.socket.clone().unwrap_or_else(paths::socket_path),
            daemon_binary: options
                .daemon_binary
                .clone()
                .unwrap_or_else(|| crate::daemon::locate_binary(std::env::current_exe())),
            daemon_child: RefCell::new(None),
            styles,
            client: RefCell::new(None),
            chat: RefCell::new(ChatLog::default()),
            connection: RefCell::new(String::new()),
            note: RefCell::new(String::new()),
            ignored: Cell::new(0),
            pending_chat: Cell::new(None),
            sessions: RefCell::new(Vec::new()),
            schedule: RefCell::new(ReconnectSchedule::default()),
            tray: RefCell::new(None),
        }))
    }

    fn start(self: &Rc<Self>, application: &gtk4::Application) {
        self.styles.watch();
        self.install_quit_action(application);
        self.install_panel_toggle_action(application);
        self.spawn_tray();
        self.figure.window().present();
        self.figure.start_idle_clock();
        self.figure.restart_frame_timer(self.figure.state());

        let clicked = Rc::downgrade(self);
        self.figure.on_click(move || {
            if let Some(shell) = clicked.upgrade() {
                shell.toggle_panel();
            }
        });

        let sending = Rc::downgrade(self);
        self.panel.on_send(move |text| {
            if let Some(shell) = sending.upgrade() {
                shell.ask(text);
            }
        });

        self.spawn_daemon_if_needed();
        self.connect();
    }

    /// Der Weg aus der Anwendung heraus, an einer Stelle für das Menü und die Tastenkombination.
    ///
    /// Skryx-L-A hat die Shell auf peer gestartet und sie nicht mehr losbekommen: Eine
    /// layer-shell-Fläche hat keinen Fensterknopf und steht in keiner Fensterliste, und die
    /// Shell bot weder einen Menüpunkt noch eine Taste an. Er musste sie über SSH abschießen.
    ///
    /// Die Anwendung hält von sich aus keine starke Referenz auf sich selbst: Der Rückruf
    /// gehört der Aktion, die Aktion der Anwendung, also wird die Anwendung nur schwach
    /// gehalten. Sonst hielte sie sich selbst am Leben.
    fn install_quit_action(self: &Rc<Self>, application: &gtk4::Application) {
        let action = gio::SimpleAction::new(panel::QUIT_ACTION, None);
        let this = Rc::downgrade(self);
        let application_ref = application.downgrade();
        action.connect_activate(move |_, _| {
            if let Some(shell) = this.upgrade() {
                shell.stop_daemon();
                shell.stop_tray();
            }
            if let Some(application) = application_ref.upgrade() {
                application.quit();
            }
        });
        application.add_action(&action);
        // Strg+Q, wie überall sonst auch. Sie greift, während das Panel den Tastaturfokus hat
        // — die Figur nimmt ihn nie, damit sie niemandem beim Tippen dazwischenkommt.
        application.set_accels_for_action(&format!("app.{}", panel::QUIT_ACTION), &["<Control>q"]);
    }

    /// Der Tastaturweg zum Panel: eine `gio::SimpleAction` an der Anwendung, die GTK von
    /// selbst über D-Bus exportiert (`org.gtk.Actions`, sobald die Anwendung registriert
    /// ist). `crate::remote::toggle_panel` ruft genau diesen Namen bei der laufenden Schale
    /// auf, statt eine zweite Instanz zu öffnen — der Weg, den ein Compositor-Binding wie
    /// `bindings.lua` (siehe `README.md`) an eine Taste hängt.
    fn install_panel_toggle_action(self: &Rc<Self>, application: &gtk4::Application) {
        let action = gio::SimpleAction::new(panel::PANEL_TOGGLE_ACTION, None);
        let this = Rc::downgrade(self);
        action.connect_activate(move |_, _| {
            if let Some(shell) = this.upgrade() {
                shell.toggle_panel();
            }
        });
        application.add_action(&action);
    }

    /// Startet den Tray-Dienst und die kleine Nachrichtenschleife, die seine Klicks von
    /// seinem eigenen Hintergrund-Thread auf den GTK-Thread trägt — dieselbe Bauweise wie
    /// die Empfangsschleife für den Daemon in `connect`. Ein Fehlschlag ist nicht tödlich:
    /// Der Tray ist ein Zweitzugang, kein Erstzugang, und das Fenster bleibt so oder so.
    fn spawn_tray(self: &Rc<Self>) {
        let (sender, receiver) = async_channel::unbounded();
        match tray::spawn(sender) {
            Ok(handle) => *self.tray.borrow_mut() = Some(handle),
            Err(error) => eprintln!("Tray nicht gestartet: {error}"),
        }

        let this = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok(command) = receiver.recv().await {
                let Some(shell) = this.upgrade() else {
                    return;
                };
                shell.handle_tray_command(command);
            }
        });
    }

    fn handle_tray_command(self: &Rc<Self>, command: TrayCommand) {
        match command {
            TrayCommand::TogglePanel => self.toggle_panel(),
            TrayCommand::ToggleFigure => self.figure.toggle_visible(),
            // Dieselben zwei Schritte wie die Beenden-Aktion (`install_quit_action`): Der
            // Tray-Rückruf kann sie nicht selbst ausführen, weil er auf ksnis
            // Hintergrund-Thread läuft, wo weder die Anwendung noch der Daemon-Zugriff
            // sicher wären.
            TrayCommand::Quit => {
                self.stop_daemon();
                self.stop_tray();
                if let Some(application) = self.application.upgrade() {
                    application.quit();
                }
            }
        }
    }

    /// Beendet den Daemon, wenn diese Shell ihn gestartet hat. Zweimal aufgerufen tut es beim
    /// zweiten Mal nichts.
    fn stop_daemon(&self) {
        if let Some(child) = self.daemon_child.borrow_mut().take() {
            crate::daemon::stop(child);
        }
    }

    /// Gibt den D-Bus-Namen und das exportierte Objekt des Trays geordnet frei, statt es dem
    /// Abbau des Prozesses zu überlassen. `wait()`, weil `shutdown()` allein nur die
    /// Beendigung anstößt — ohne zu warten wäre das Ende hier genauso ein Wettlauf mit
    /// `application.quit()` wie zuvor ganz ohne diesen Aufruf.
    fn stop_tray(&self) {
        if let Some(handle) = self.tray.borrow_mut().take() {
            handle.shutdown().wait();
        }
    }

    /// Öffnet die Shell wie jede andere Anwendung: niemand muss den Daemon vorher von Hand
    /// starten. Ein Fehlschlag ist nicht tödlich — `connect` meldet gleich danach denselben
    /// „nicht erreichbar", den es schon immer gemeldet hat, über die gewöhnliche Staffel.
    fn spawn_daemon_if_needed(self: &Rc<Self>) {
        let config_dir = paths::config_dir();
        match crate::daemon::launch_if_needed(&self.daemon_binary, &config_dir, &self.socket) {
            Ok(child) => *self.daemon_child.borrow_mut() = child,
            Err(error) => eprintln!("Daemon nicht gestartet: {error}"),
        }
    }

    /// Der Klick auf die Figur öffnet und schließt das Panel.
    ///
    /// Und er ist der Moment, in dem die erhobene Hand neu gerechnet wird: Der Mensch hat
    /// hingesehen. Der Mac rechnet an derselben Art von Stelle nach — nachdem eine Frage
    /// beantwortet wurde (`CompanionShell.clearQuestion`) —, und ausdrücklich nicht bei jeder
    /// eintreffenden Liste, sonst löschte die nächste Liste den Alarm eines Fehlerereignisses
    /// wieder weg.
    fn toggle_panel(self: &Rc<Self>) {
        self.figure.apply(FigureEvent::UserActivity);
        self.panel.toggle();
        if self.panel.is_open() {
            self.refresh_attention();
        }
    }

    fn refresh_attention(self: &Rc<Self>) {
        let open = mapping::attention_count(&self.sessions.borrow());
        self.figure.apply(if open > 0 {
            FigureEvent::AttentionRequired
        } else {
            FigureEvent::AttentionCleared
        });
    }

    // MARK: - Die Verbindung

    /// Verbindet sich mit dem Daemon und hält die beiden Fenster von dort aus versorgt.
    ///
    /// Ein Fehlschlag ist nicht das Ende: Die Figur bleibt auf dem Bildschirm, sagt warum, und
    /// die Staffel versucht es wieder. Eine Shell, die verschwindet, sobald der Daemon nicht
    /// läuft, lässt den Menschen ohne etwas zurück, worauf er klicken könnte, um das zu
    /// erfahren.
    fn connect(self: &Rc<Self>) {
        let token = match read_human_token(&paths::token_file_path()) {
            Ok(token) => token,
            Err(error) => {
                // Kein Token heißt: Der Daemon war hier noch nie. Das ist kein Abriss einer
                // Verbindung, sondern ein Zustand, den ein Start des Daemons behebt — also
                // wird auch das wieder versucht.
                self.fail(&error.to_string());
                self.schedule_reconnect();
                return;
            }
        };

        let (client, receiver) = match DaemonClient::connect(&self.socket, token) {
            Ok(pair) => pair,
            Err(error) => {
                self.fail(&error.to_string());
                self.schedule_reconnect();
                return;
            }
        };

        self.chat.borrow_mut().connection_changed();
        self.pending_chat.set(None);
        *self.client.borrow_mut() = Some(Rc::new(client));
        self.note(&format!("Verbinde mit {} …", self.socket.display()));
        self.render_chat();

        let _ = self.send(Request::list());

        let this = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok(incoming) = receiver.recv().await {
                let Some(shell) = this.upgrade() else {
                    return;
                };
                match incoming {
                    Incoming::Message(message) => shell.handle(*message),
                    Incoming::Ignored { .. } => {
                        // Gezählt statt befolgt, und angezeigt, damit ein Versionsversatz
                        // zwischen Shell und Daemon sichtbar ist statt still.
                        shell.ignored.set(shell.ignored.get() + 1);
                        shell.refresh_status();
                    }
                    Incoming::Closed { reason } => {
                        let reason =
                            reason.unwrap_or_else(|| "Der Daemon hat aufgelegt.".to_owned());
                        shell.fail(&reason);
                        shell.schedule_reconnect();
                        return;
                    }
                }
            }
        });
    }

    /// Räumt die tote Verbindung ab und sagt, was los ist.
    fn fail(self: &Rc<Self>, reason: &str) {
        if let Some(client) = self.client.borrow_mut().take() {
            client.shutdown();
        }
        self.pending_chat.set(None);
        self.connection.borrow_mut().clear();
        self.note(reason);
        self.panel.set_accepting_input(false);
        self.figure.apply(FigureEvent::AnswerFinished);
    }

    fn schedule_reconnect(self: &Rc<Self>) {
        let delay = self.schedule.borrow_mut().next_delay();
        let attempt = self.schedule.borrow().attempts();
        let note = format!(
            "{}\nNeuer Versuch in {} Sekunden (Versuch {attempt}).",
            self.note.borrow(),
            delay.as_secs()
        );
        self.panel.set_status(&note);

        let this = Rc::downgrade(self);
        glib::timeout_add_local_once(delay, move || {
            if let Some(shell) = this.upgrade() {
                shell.connect();
            }
        });
    }

    fn send(self: &Rc<Self>, request: Request) -> Option<RequestId> {
        let client = self.client.borrow().clone()?;
        match client.send(request) {
            Ok(id) => Some(id),
            Err(error) => {
                self.note(&error.to_string());
                self.refresh_status();
                None
            }
        }
    }

    // MARK: - Der Chat

    /// Eine Zeile, die der Mensch getippt hat.
    fn ask(self: &Rc<Self>, text: String) {
        self.figure.apply(FigureEvent::UserActivity);
        self.chat.borrow_mut().ask(&text);
        self.render_chat();

        let Some(id) = self.send(Request::ChatMessage { text, voice: false }) else {
            self.chat
                .borrow_mut()
                .system("Die Frage ging nicht hinaus.");
            self.render_chat();
            return;
        };
        self.pending_chat.set(Some(id));
        // Eine Frage zur Zeit: Der Daemon lehnt eine zweite `chat_message` ab, solange eine
        // Antwort geschrieben wird, also bietet die Shell sie gar nicht erst an.
        self.panel.set_accepting_input(false);
        self.figure.apply(FigureEvent::AnswerStarted);
    }

    /// Die Antwort ist durch, aus welchem Grund auch immer.
    fn end_answer(self: &Rc<Self>) {
        self.pending_chat.set(None);
        self.panel.set_accepting_input(true);
        self.figure.apply(FigureEvent::AnswerFinished);
    }

    fn render_chat(&self) {
        self.panel.set_chat(&self.chat.borrow().render());
    }

    fn note(&self, text: &str) {
        *self.note.borrow_mut() = text.to_owned();
        self.refresh_status();
    }

    fn refresh_status(&self) {
        let mut text = self.connection.borrow().clone();
        let note = self.note.borrow().clone();
        if !note.is_empty() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&note);
        }
        let ignored = self.ignored.get();
        if ignored > 0 {
            // Die Zahl, die der Plan einen Client anzeigen können lässt.
            text.push_str(&format!(
                "\n{ignored} Meldungen ignoriert — der Daemon ist neuer als diese Shell."
            ));
        }
        self.panel.set_status(&text);
    }

    // MARK: - Was der Daemon schickt

    fn handle(self: &Rc<Self>, message: ServerMessage) {
        match message {
            ServerMessage::Welcome(welcome) => {
                self.schedule.borrow_mut().reset();
                *self.connection.borrow_mut() = format!(
                    "Verbunden mit companion-daemon {} als {}. Protokoll {}.",
                    welcome.daemon_version,
                    match welcome.role {
                        ClientRole::Human => "Mensch",
                        ClientRole::Agent => "Agent",
                    },
                    welcome.protocol_version
                );
                self.note.borrow_mut().clear();
                self.refresh_status();
                self.panel.set_accepting_input(true);
            }
            ServerMessage::Rejected(error) => {
                // Ein abgelehntes Token wird beim nächsten Versuch wieder abgelehnt. Die
                // Staffel läuft trotzdem: Ein Daemon, der gerade neu startet, kann das Token
                // in der Zwischenzeit neu geschrieben haben.
                self.fail(&format!(
                    "Der Daemon hat die Anmeldung abgelehnt: {}",
                    error.message
                ));
                self.figure.apply(FigureEvent::AttentionRequired);
                self.schedule_reconnect();
            }
            ServerMessage::Response(response) => {
                let for_chat = self.pending_chat.get() == Some(response.id);
                match response.result {
                    // Nur `list` antwortet mit einer Sitzungsliste, also sagt der Rumpf ohne
                    // eine Tabelle offener Anfragen, wozu diese Antwort gehört.
                    ResponseResult::Ok(ResponseBody::Sessions {
                        sessions,
                        adapter_errors,
                    }) => {
                        self.panel.set_sessions(&sessions);
                        self.panel.set_adapter_errors(&adapter_errors);
                        self.figure.apply(if mapping::any_working(&sessions) {
                            FigureEvent::WorkStarted
                        } else {
                            FigureEvent::WorkFinished
                        });
                        *self.sessions.borrow_mut() = sessions;
                    }
                    ResponseResult::Ok(ResponseBody::Ack) if for_chat => {
                        // Die Antwort selbst kommt als Ereignisse. Hier ist nichts zu tun.
                    }
                    ResponseResult::Ok(body) if for_chat => {
                        self.chat
                            .borrow_mut()
                            .system(&format!("Unerwartete Antwort auf die Frage: {body:?}."));
                        self.render_chat();
                        self.end_answer();
                    }
                    ResponseResult::Ok(_) => {}
                    ResponseResult::Error(error) => {
                        self.note(&format!("Der Daemon meldet: {}", error.message));
                        if for_chat {
                            self.chat.borrow_mut().system(&error.message);
                            self.render_chat();
                            self.end_answer();
                        }
                    }
                }
            }
            ServerMessage::Event(envelope) => self.handle_event(envelope.event),
            ServerMessage::EventsDropped { missed, .. } => {
                self.note(&format!(
                    "{missed} Ereignisse verpasst, die Liste wird neu geholt."
                ));
                let _ = self.send(Request::list());
            }
            ServerMessage::Paired(_) => {
                // Kopplung gehört zum Netzport, und diese Shell spricht nur über den lokalen
                // Socket. Nichts zu tun, und nichts verloren, wenn das hier steht.
            }
        }
    }

    fn handle_event(self: &Rc<Self>, event: Event) {
        // Was das Ereignis mit der erhobenen Hand macht, entscheidet `mapping` — die eine
        // Stelle, die die Semantik der Mac-Shell trägt.
        if let Some(attention) = mapping::attention_event(&event) {
            self.figure.apply(attention);
        }

        if mapping::belongs_in_chat_history(event.kind()) {
            match event {
                Event::ChatDelta { text } => {
                    self.chat.borrow_mut().delta(&text);
                    self.render_chat();
                }
                Event::ChatTool { name, summary } => {
                    self.chat.borrow_mut().tool(&name, &summary);
                    self.render_chat();
                }
                Event::ChatDone { text, .. } => {
                    self.chat.borrow_mut().done(&text);
                    self.render_chat();
                    self.end_answer();
                }
                _ => unreachable!("only chat events may enter the chat history"),
            }
            return;
        }

        match event {
            // A world is presented in the notice log and at the figure. It never becomes a
            // chat line: that history is only the person's conversation with the companion.
            // `notice_shown` follows the log entry, exactly as on the Mac; an optional `ack`
            // still waits for the person to press its explicit button above.
            Event::ProactiveNotice {
                class: companion_protocol::ProactiveClass::WorldEvent,
                text,
                ack,
                notice_id,
                ..
            } => {
                let shell = Rc::downgrade(self);
                self.panel.add_notice(&text, ack.as_deref(), move |ack| {
                    if let Some(shell) = shell.upgrade() {
                        let _ = shell.send(Request::AcknowledgeNotice { ack });
                    }
                });
                self.figure.apply(FigureEvent::AttentionRequired);
                if let Some(notice_id) = notice_id {
                    let _ = self.send(Request::NoticeShown { notice_id });
                }
            }
            // Alles, was ändern kann, was die Liste zeigt: die Liste neu holen, statt eine
            // Kopie davon nachzupflegen, damit Shell und Daemon nicht auseinanderlaufen.
            Event::SessionStarted { .. }
            | Event::SessionEnded { .. }
            | Event::QuestionOpen { .. }
            | Event::WaitingForInput { .. }
            | Event::Busy
            | Event::Idle
            | Event::Done { .. }
            | Event::GateResult { .. }
            | Event::ContextLevel { .. }
            | Event::BudgetLevel { .. }
            | Event::Iteration { .. }
            | Event::Error { .. }
            | Event::EventsDropped { .. } => {
                let _ = self.send(Request::list());
            }
            // Sprache gehört zu einem späteren Schritt der Linux-Spur; die Ereignisse werden
            // angenommen und liegengelassen, statt als unbekannt gezählt zu werden, denn
            // dieser Bau kennt sie.
            Event::SttPartial { .. }
            | Event::SttFinal { .. }
            | Event::TtsChunk { .. }
            | Event::TtsDone { .. }
            | Event::SettingsChanged
            // Other proactive notices have no Linux presentation yet. They remain outside the
            // chat as well; this track only makes workbench worlds a listener.
            | Event::ProactiveNotice { .. } => {}
        }
    }
}

/// Wird die Anwendung beendet, fällt die Shell und mit ihr die Verbindung — und der Daemon,
/// falls sie ihn selbst gestartet hat.
///
/// Das Netz unter der Beenden-Aktion: Sie räumt schon selbst auf, aber die Shell kann auch auf
/// anderen Wegen enden, etwa wenn der Compositor die Anzeige unter ihr wegnimmt.
impl Drop for Shell {
    fn drop(&mut self) {
        if let Some(client) = self.client.borrow_mut().take() {
            client.shutdown();
        }
        if let Some(child) = self.daemon_child.borrow_mut().take() {
            crate::daemon::stop(child);
        }
    }
}
