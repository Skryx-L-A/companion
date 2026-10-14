// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The panel behind the figure: the session list and the chat with the companion.
//!
//! The same scope as the early Mac shell — see what is running, and say something to the
//! companion. Driving a session, the job file, the approvals and voice all belong to later
//! steps of the Linux track and are deliberately not here.
//!
//! It is a second layer surface rather than an ordinary window, for the same reason as the
//! figure: an ordinary toplevel would show up in the taskbar and the window list, which
//! `DESIGN.md` § Figur und Overlay rules out for the shell. Unlike the figure it does take
//! the keyboard, but only on demand — the compositor gives it focus when the person clicks
//! into it and takes it back when they click away.

use std::collections::BTreeMap;

use companion_protocol::{AdapterId, SessionState, SessionStatus};
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib};
use gtk4_layer_shell::{KeyboardMode, Layer, LayerShell};

use crate::options::Options;

use super::overlay::anchor_to_corner;

/// Der Name der Beenden-Aktion an der Anwendung. Das Menü im Panel und die Tastenkombination
/// hängen beide daran, damit es nur einen Weg aus der Anwendung gibt und nicht zwei.
pub const QUIT_ACTION: &str = "beenden";

/// Der Name der Umschalten-Aktion an der Anwendung. GTK exportiert jede
/// `gio::SimpleAction` einer registrierten `Application` von sich aus über D-Bus
/// (`org.gtk.Actions`) — das ist der Tastaturweg zum Panel: `crate::remote` ruft genau
/// diesen Namen bei der laufenden Schale auf, statt selbst eine zweite Instanz zu öffnen.
pub const PANEL_TOGGLE_ACTION: &str = "panel-umschalten";

pub struct Panel {
    window: gtk4::ApplicationWindow,
    status: gtk4::Label,
    warning: gtk4::Label,
    notices: gtk4::ListBox,
    notice_scroll: gtk4::ScrolledWindow,
    sessions: gtk4::ListBox,
    session_note: gtk4::Label,
    chat: gtk4::TextView,
    chat_scroll: gtk4::ScrolledWindow,
    entry: gtk4::Entry,
    send: gtk4::Button,
}

impl Panel {
    pub fn new(
        application: &gtk4::Application,
        options: &Options,
        monitor: Option<&gtk4::gdk::Monitor>,
    ) -> Self {
        let window = gtk4::ApplicationWindow::builder()
            .application(application)
            .decorated(false)
            .resizable(false)
            .build();
        window.add_css_class("companion-panel");

        window.init_layer_shell();
        // `top` wie die Figur und aus demselben Grund: `overlay` gehört der Bildschirmsperre
        // und dem, was im Notfall sichtbar bleiben muss. Ein Panel ist ein Panel — dieselbe
        // Ebene, auf der auch die Bar des Systems liegt.
        window.set_layer(Layer::Top);
        window.set_namespace(Some("companion-panel"));
        window.set_keyboard_mode(KeyboardMode::OnDemand);
        window.set_exclusive_zone(0);
        // Derselbe Bildschirm wie die Figur, sonst stünde das Panel auf einem anderen.
        super::overlay::place_on_monitor(&window, monitor);
        // The same corner as the figure, moved along by the figure's width plus its margin,
        // so the two sit next to one another instead of on top of one another.
        anchor_to_corner(&window, options.corner, options.margin);
        let horizontal = if options.corner.is_left() {
            gtk4_layer_shell::Edge::Left
        } else {
            gtk4_layer_shell::Edge::Right
        };
        window.set_margin(horizontal, options.margin + options.size + 12);

        let body = gtk4::Box::builder()
            .orientation(gtk4::Orientation::Vertical)
            .spacing(8)
            .width_request(380)
            .build();
        body.add_css_class("panel-body");

        let title = gtk4::Label::builder()
            .label("companion")
            .xalign(0.0)
            .hexpand(true)
            .build();
        title.add_css_class("panel-title");

        // Der Weg aus der Anwendung heraus. Vorher gab es keinen: Wer die Shell startete,
        // konnte sie nur noch von außen abschießen, weil eine layer-shell-Fläche keinen
        // Fensterknopf hat und in keiner Fensterliste auftaucht.
        let menu_button = gtk4::MenuButton::builder()
            .icon_name("open-menu-symbolic")
            .menu_model(&quit_menu())
            .tooltip_text("Menü")
            .build();
        menu_button.update_property(&[gtk4::accessible::Property::Label("Menü")]);

        let header = gtk4::Box::builder()
            .orientation(gtk4::Orientation::Horizontal)
            .spacing(6)
            .build();
        header.append(&title);
        header.append(&menu_button);
        body.append(&header);

        let status = gtk4::Label::builder()
            .label("Nicht verbunden.")
            .xalign(0.0)
            .wrap(true)
            .build();
        status.add_css_class("panel-note");
        body.append(&status);

        let warning = gtk4::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .visible(false)
            .build();
        warning.add_css_class("panel-warning");
        body.append(&warning);

        let notices = gtk4::ListBox::new();
        notices.set_selection_mode(gtk4::SelectionMode::None);
        notices.update_property(&[gtk4::accessible::Property::Label(
            "Meldungen aus Welten und Sitzungen",
        )]);
        let notice_scroll = gtk4::ScrolledWindow::builder()
            .child(&notices)
            .max_content_height(180)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk4::PolicyType::Never)
            .visible(false)
            .build();
        body.append(&notice_scroll);

        let sessions = gtk4::ListBox::new();
        sessions.set_selection_mode(gtk4::SelectionMode::None);
        sessions.update_property(&[gtk4::accessible::Property::Label("Laufende Sitzungen")]);
        let session_scroll = gtk4::ScrolledWindow::builder()
            .child(&sessions)
            .max_content_height(260)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk4::PolicyType::Never)
            .build();
        body.append(&session_scroll);

        let session_note = gtk4::Label::builder()
            .label("Keine Sitzungen.")
            .xalign(0.0)
            .wrap(true)
            .build();
        session_note.add_css_class("panel-note");
        body.append(&session_note);

        body.append(&gtk4::Separator::new(gtk4::Orientation::Horizontal));

        let chat = gtk4::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .wrap_mode(gtk4::WrapMode::WordChar)
            .left_margin(4)
            .right_margin(4)
            .build();
        chat.update_property(&[gtk4::accessible::Property::Label(
            "Verlauf des Gesprächs mit dem Companion",
        )]);
        let chat_scroll = gtk4::ScrolledWindow::builder()
            .child(&chat)
            .min_content_height(120)
            .max_content_height(220)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk4::PolicyType::Never)
            .build();
        body.append(&chat_scroll);

        let row = gtk4::Box::builder()
            .orientation(gtk4::Orientation::Horizontal)
            .spacing(6)
            .build();
        let entry = gtk4::Entry::builder()
            .placeholder_text("Nachricht an den Companion")
            .hexpand(true)
            .build();
        entry.update_property(&[gtk4::accessible::Property::Label(
            "Nachricht an den Companion",
        )]);
        let send = gtk4::Button::with_label("Senden");
        row.append(&entry);
        row.append(&send);
        body.append(&row);

        window.set_child(Some(&body));
        close_on_escape(&window);

        Self {
            window,
            status,
            warning,
            notices,
            notice_scroll,
            sessions,
            session_note,
            chat,
            chat_scroll,
            entry,
            send,
        }
    }

    pub fn window(&self) -> &gtk4::ApplicationWindow {
        &self.window
    }

    pub fn is_open(&self) -> bool {
        self.window.is_visible()
    }

    pub fn toggle(&self) {
        if self.is_open() {
            self.window.set_visible(false);
        } else {
            self.window.present();
            self.entry.grab_focus();
        }
    }

    pub fn set_status(&self, text: &str) {
        self.status.set_label(text);
    }

    /// Shows the adapters that could not answer, so missing sessions are not read as
    /// "nothing is running" (the same reason the iOS app shows this).
    pub fn set_adapter_errors(&self, errors: &BTreeMap<AdapterId, String>) {
        if errors.is_empty() {
            self.warning.set_visible(false);
            return;
        }
        let text = errors
            .iter()
            .map(|(adapter, message)| format!("{adapter}: {message}"))
            .collect::<Vec<_>>()
            .join("\n");
        self.warning
            .set_label(&format!("Adapter ohne Antwort:\n{text}"));
        self.warning.set_visible(true);
    }

    /// Adds a proactive notice outside the conversation history.
    ///
    /// A world can attach an acknowledgement only when its full marked message fits in this
    /// notice. The button is deliberately the acknowledgement point: merely receiving a line
    /// does not prove that somebody read it.
    pub fn add_notice<F: Fn(String) + 'static>(&self, text: &str, ack: Option<&str>, confirm: F) {
        let row = gtk4::Box::builder()
            .orientation(gtk4::Orientation::Horizontal)
            .spacing(6)
            .margin_top(4)
            .margin_bottom(4)
            .build();
        let label = gtk4::Label::builder()
            .label(text)
            .xalign(0.0)
            .wrap(true)
            .hexpand(true)
            .build();
        label.add_css_class("panel-warning");
        row.append(&label);
        if let Some(ack) = ack.map(str::to_owned) {
            let button = gtk4::Button::with_label("Quittieren");
            button.update_property(&[gtk4::accessible::Property::Label("Meldung quittieren")]);
            button.connect_clicked(move |button| {
                button.set_sensitive(false);
                confirm(ack.clone());
            });
            row.append(&button);
        }
        self.notices.append(&row);
        self.notice_scroll.set_visible(true);
    }

    pub fn set_sessions(&self, sessions: &[SessionStatus]) {
        while let Some(child) = self.sessions.first_child() {
            self.sessions.remove(&child);
        }
        if sessions.is_empty() {
            self.session_note.set_label("Keine Sitzungen.");
            self.session_note.set_visible(true);
            return;
        }
        self.session_note.set_visible(false);
        for session in sessions {
            self.sessions.append(&session_row(session));
        }
    }

    /// Zeigt den Verlauf, wie [`crate::chat::ChatLog`] ihn gerade hat.
    ///
    /// Der ganze Text auf einmal statt Zeilen anhängen und ersetzen: Wer den Verlauf besitzt,
    /// ist das Modell, und das Panel zeichnet nur, was dort steht. Der Verlauf ist ein paar
    /// Blasen lang, das Neuzeichnen kostet also nichts.
    pub fn set_chat(&self, text: &str) {
        self.chat.buffer().set_text(text);
        // Dem neuesten Eintrag folgen, statt den Leser oben stehen zu lassen.
        let adjustment = self.chat_scroll.vadjustment();
        adjustment.set_value(adjustment.upper());
    }

    /// Wires the send button and the return key to the same action, and clears the entry.
    pub fn on_send<F: Fn(String) + Clone + 'static>(&self, action: F) {
        let entry = self.entry.clone();
        let submit = move |entry: &gtk4::Entry, action: &F| {
            let text = entry.text().trim().to_owned();
            if text.is_empty() {
                return;
            }
            entry.set_text("");
            action(text);
        };

        let by_button = action.clone();
        let entry_for_button = entry.clone();
        self.send
            .connect_clicked(move |_| submit(&entry_for_button, &by_button));

        let by_return = action;
        self.entry
            .connect_activate(move |entry| submit(entry, &by_return));
    }

    /// Blocks a second question while an answer is still being written: the daemon answers
    /// one message at a time and refuses the second one rather than interleaving it.
    pub fn set_accepting_input(&self, accepting: bool) {
        self.entry.set_sensitive(accepting);
        self.send.set_sensitive(accepting);
    }
}

fn session_row(session: &SessionStatus) -> gtk4::Box {
    let row = gtk4::Box::builder()
        .orientation(gtk4::Orientation::Vertical)
        .spacing(2)
        .margin_top(4)
        .margin_bottom(4)
        .build();

    let name = session
        .display_name
        .value()
        .cloned()
        .unwrap_or_else(|| session.id.to_string());
    let title = gtk4::Label::builder()
        .label(format!("{name} — {}", german_state(session.state)))
        .xalign(0.0)
        .wrap(true)
        .build();
    title.add_css_class("session-name");
    row.append(&title);

    let mut details = vec![
        format!("Adapter {}", session.adapter),
        format!("Maschine {}", session.machine),
    ];
    if let Some(project) = &session.project {
        details.push(format!("Projekt {project}"));
    }
    // An unknown field is shown as unknown, never as empty and never as zero.
    details.push(match session.model.value() {
        Some(model) => format!("Modell {model}"),
        None => "Modell unbekannt".to_owned(),
    });
    let detail = gtk4::Label::builder()
        .label(details.join(" · "))
        .xalign(0.0)
        .wrap(true)
        .build();
    detail.add_css_class("session-detail");
    row.append(&detail);

    if let Some(question) = &session.open_question {
        let open = gtk4::Label::builder()
            .label(format!("Offene Frage: {question}"))
            .xalign(0.0)
            .wrap(true)
            .build();
        open.add_css_class("panel-warning");
        row.append(&open);
    }
    row
}

/// Das Menü hinter dem Knopf in der Kopfzeile.
fn quit_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append(Some("Beenden"), Some(&format!("app.{QUIT_ACTION}")));
    menu
}

/// Esc schließt das Panel.
///
/// Die Abnahmeliste der GNOME HIG verlangt es für alles, was sich über den Inhalt legt, und
/// vorher gab es keine Taste, die das Panel wieder zumachte — nur einen zweiten Klick auf die
/// Figur. Die Fläche nimmt die Tastatur ohnehin schon entgegen (`KeyboardMode::OnDemand`),
/// also kostet das keine zusätzliche Etikette.
fn close_on_escape(window: &gtk4::ApplicationWindow) {
    let controller = gtk4::EventControllerKey::new();
    // Schwach: Das Fenster hält den Controller, der Controller hielte sonst das Fenster, und
    // beide kämen nie wieder weg.
    let weak = window.downgrade();
    controller.connect_key_pressed(move |_, key, _, _| {
        if key != gdk::Key::Escape {
            return glib::Propagation::Proceed;
        }
        if let Some(window) = weak.upgrade() {
            window.set_visible(false);
        }
        glib::Propagation::Stop
    });
    window.add_controller(controller);
}

/// The session states in German, for the list.
pub fn german_state(state: SessionState) -> &'static str {
    match state {
        SessionState::Busy => "arbeitet",
        SessionState::Idle => "wartet",
        SessionState::Waiting => "braucht Eingabe",
        SessionState::Done => "fertig",
        SessionState::Error => "Fehler",
        SessionState::Unknown => "unbekannt",
        SessionState::Lost => "verschwunden",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Das Menü nennt die Aktion voll qualifiziert. Ein `beenden` ohne `app.` fände GTK an
    /// keiner Stelle, und der Eintrag wäre grau, ohne dass irgendetwas sich beschwerte.
    #[test]
    fn the_menu_names_the_application_action() {
        let menu = quit_menu();
        assert_eq!(menu.n_items(), 1);
        let action = menu
            .item_attribute_value(0, "action", None)
            .and_then(|value| value.get::<String>())
            .expect("der Eintrag nennt eine Aktion");
        assert_eq!(action, format!("app.{QUIT_ACTION}"));
    }

    /// Seven states, seven different words: two states sharing one word would make the
    /// list say the same thing about a session that finished and one that vanished.
    #[test]
    fn every_session_state_has_a_german_word_of_its_own() {
        let states = [
            SessionState::Busy,
            SessionState::Idle,
            SessionState::Waiting,
            SessionState::Done,
            SessionState::Error,
            SessionState::Unknown,
            SessionState::Lost,
        ];
        let words: std::collections::BTreeSet<&str> =
            states.iter().map(|state| german_state(*state)).collect();
        assert_eq!(
            words.len(),
            states.len(),
            "two states share a word: {words:?}"
        );
        assert!(words.iter().all(|word| !word.is_empty()));
    }
}
