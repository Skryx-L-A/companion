// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Der Verlauf im Chatfenster: eine Liste von Nachrichten, kein Textpuffer.
//!
//! Ein Port von `app/mac/Sources/CompanionUI/Models/ChatController.swift`, auf den Teil
//! beschränkt, den diese Shell hat: die Blasen. Sprache, Satztrenner und die Frage an eine
//! Sitzung gehören dort dazu und hier noch nicht.
//!
//! Die frühere Fassung hielt den Verlauf als eine Zeichenkette und ersetzte beim Eintreffen
//! eines Stücks alles hinter dem letzten Zeilenumbruch. Das ging bei jeder einzeiligen
//! Antwort gut und bei jeder mehrzeiligen kaputt: Sobald die Antwort selbst einen Umbruch
//! enthielt, lag der letzte Umbruch innerhalb der Antwort, und das nächste Stück hängte die
//! ganze Antwort noch einmal an. Eine Nachrichtenliste kennt dieses Problem nicht, weil eine
//! Blase eine Blase bleibt, egal wie viele Zeilen in ihr stehen.

/// Wer die Nachricht geschrieben hat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatAuthor {
    /// Der Mensch.
    Human,
    /// Der Companion selbst.
    Companion,
    /// Ein Werkzeug, das der Companion benutzt hat.
    Tool,
    /// Die Shell über den Companion, etwa wenn eine Frage gar nicht hinausging.
    System,
}

impl ChatAuthor {
    /// Was vor der Nachricht steht. Werkzeug- und Systemzeilen tragen ihren Namen schon im
    /// Text und bekommen deshalb keinen zweiten davor.
    fn prefix(self) -> &'static str {
        match self {
            Self::Human => "Du: ",
            Self::Companion => "companion: ",
            Self::Tool | Self::System => "",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub author: ChatAuthor,
    pub text: String,
}

/// Der ganze Verlauf plus der Zustand der Antwort, die gerade geschrieben wird.
#[derive(Debug, Default)]
pub struct ChatLog {
    messages: Vec<ChatMessage>,
    /// Die Blase, in die die Stücke laufen. `None` zwischen zwei Antworten.
    ///
    /// Ein Index, kein Schlüssel: Eine Blase wird immer am Ende angehängt und geschlossen,
    /// bevor irgendetwas anderes angehängt wird, also zeigt der Index stets auf das letzte
    /// Element. `debug_assert` in [`Self::open_bubble`] hält das fest.
    streaming: Option<usize>,
    /// Alles, was die Stücke dieser Antwort bisher getragen haben, über alle Blasen hinweg.
    streamed: String,
    /// Was in der aktuellen Blase steht. Eigene Zeichenkette, weil eine Werkzeugzeile mitten
    /// in einer Antwort eine neue Blase beginnt und die danach leer anfängt.
    bubble: String,
    /// Wahr, sobald eine Werkzeugzeile diese Antwort auf mehr als eine Blase verteilt hat.
    split: bool,
}

impl ChatLog {
    pub fn messages(&self) -> &[ChatMessage] {
        &self.messages
    }

    /// Wahr, solange eine Antwort geschrieben wird.
    pub fn is_streaming(&self) -> bool {
        self.streaming.is_some()
    }

    /// Eine neue Frage des Menschen. Beendet, was von der alten Antwort noch offen war.
    pub fn ask(&mut self, text: &str) {
        self.close_bubble();
        self.reset_answer();
        self.push(ChatAuthor::Human, text.to_owned());
    }

    /// Ein Stück der Antwort, in der Reihenfolge, in der es geschrieben wurde.
    pub fn delta(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        self.streamed.push_str(text);
        self.bubble.push_str(text);
        let index = match self.streaming {
            Some(index) => index,
            None => self.open_bubble(),
        };
        self.messages[index].text.clone_from(&self.bubble);
    }

    /// Eine Werkzeugzeile. Sie steht unter dem, was bisher gesagt wurde, und was danach kommt,
    /// beginnt eine neue Blase: Ein Werkzeug mitten im Satz stünde sonst über dessen zweiter
    /// Hälfte.
    pub fn tool(&mut self, name: &str, summary: &str) {
        if self.streaming.is_some() && !self.bubble.is_empty() {
            self.split = true;
        }
        self.close_bubble();
        let tool = if name.trim().is_empty() {
            "Werkzeug"
        } else {
            name.trim()
        };
        let detail = summary.trim();
        let line = if detail.is_empty() {
            tool.to_owned()
        } else {
            format!("{tool}: {detail}")
        };
        self.push(ChatAuthor::Tool, line);
    }

    /// Die Antwort ist vollständig.
    ///
    /// Der ganze Text, wie der Daemon ihn hat, gewinnt über das, was die Stücke getragen
    /// haben — so wird auch ein Daemon angezeigt, der nichts streamt und am Ende alles
    /// schickt. Nur nicht, wenn eine Werkzeugzeile die Antwort geteilt hat: Der Gesamttext in
    /// der letzten Blase würde dann die erste Hälfte der Antwort ein zweites Mal drucken.
    pub fn done(&mut self, text: &str) {
        if !text.is_empty() && !self.split {
            match self.streaming {
                Some(index) => self.messages[index].text = text.to_owned(),
                None => self.push(ChatAuthor::Companion, text.to_owned()),
            }
        }
        self.reset_answer();
    }

    /// Eine Zeile der Shell über den Companion.
    pub fn system(&mut self, text: &str) {
        self.close_bubble();
        self.reset_answer();
        self.push(ChatAuthor::System, text.to_owned());
    }

    /// Eine neue Verbindung heißt ein neuer Daemon. Der Verlauf bleibt stehen, die halbe
    /// Antwort darin nicht.
    pub fn connection_changed(&mut self) {
        self.close_bubble();
        self.reset_answer();
    }

    /// Der Verlauf als Text, eine Nachricht je Zeile.
    pub fn render(&self) -> String {
        self.messages
            .iter()
            .map(|message| format!("{}{}", message.author.prefix(), message.text))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn push(&mut self, author: ChatAuthor, text: String) {
        self.messages.push(ChatMessage { author, text });
    }

    fn open_bubble(&mut self) -> usize {
        self.push(ChatAuthor::Companion, String::new());
        let index = self.messages.len() - 1;
        self.streaming = Some(index);
        debug_assert_eq!(index, self.messages.len() - 1);
        index
    }

    /// Hört auf, in die aktuelle Blase zu schreiben. Eine leere wird wieder herausgenommen,
    /// statt als Companion stehenzubleiben, der nichts gesagt hat.
    fn close_bubble(&mut self) {
        self.bubble.clear();
        let Some(index) = self.streaming.take() else {
            return;
        };
        if self
            .messages
            .get(index)
            .is_some_and(|message| message.text.is_empty())
        {
            self.messages.remove(index);
        }
    }

    fn reset_answer(&mut self) {
        self.streamed.clear();
        self.bubble.clear();
        self.split = false;
        self.streaming = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(log: &ChatLog) -> Vec<String> {
        log.render().lines().map(str::to_owned).collect()
    }

    #[test]
    fn eine_frage_und_eine_einzeilige_antwort() {
        let mut log = ChatLog::default();
        log.ask("Was läuft gerade?");
        log.delta("Nichts");
        log.done("Nichts");
        assert_eq!(lines(&log), ["Du: Was läuft gerade?", "companion: Nichts"]);
    }

    /// Der Befund, an dem die alte Fassung zerbrach: Sobald die Antwort selbst einen Umbruch
    /// enthält, hängte die Zeilenersetzung sie noch einmal an.
    #[test]
    fn eine_mehrzeilige_antwort_steht_genau_einmal_da() {
        let mut log = ChatLog::default();
        log.ask("Was läuft?");
        log.delta("Zeile eins");
        log.delta("\n");
        log.delta("Zeile zwei");
        assert_eq!(
            log.render(),
            "Du: Was läuft?\ncompanion: Zeile eins\nZeile zwei"
        );

        log.done("Zeile eins\nZeile zwei");
        assert_eq!(
            log.render(),
            "Du: Was läuft?\ncompanion: Zeile eins\nZeile zwei"
        );
    }

    /// Der zweite Befund: Eine Werkzeugzeile druckte die erste Hälfte der Antwort noch einmal.
    #[test]
    fn eine_werkzeugzeile_teilt_die_antwort_ohne_sie_zu_verdoppeln() {
        let mut log = ChatLog::default();
        log.ask("Und?");
        log.delta("Ich sehe nach.");
        log.tool("sessions", "vier Sitzungen gelesen");
        log.delta("Es laufen vier.");
        log.done("Ich sehe nach.Es laufen vier.");
        assert_eq!(
            lines(&log),
            [
                "Du: Und?",
                "companion: Ich sehe nach.",
                "sessions: vier Sitzungen gelesen",
                "companion: Es laufen vier.",
            ]
        );
    }

    #[test]
    fn ein_werkzeug_vor_dem_ersten_wort_teilt_nichts() {
        let mut log = ChatLog::default();
        log.ask("Und?");
        log.tool("sessions", "vier Sitzungen gelesen");
        log.delta("Es laufen vier.");
        log.done("Es laufen vier.");
        assert_eq!(
            lines(&log),
            [
                "Du: Und?",
                "sessions: vier Sitzungen gelesen",
                "companion: Es laufen vier."
            ]
        );
    }

    /// Ein Daemon, der nichts streamt und am Ende alles schickt.
    #[test]
    fn eine_antwort_ganz_am_ende_wird_trotzdem_angezeigt() {
        let mut log = ChatLog::default();
        log.ask("Und?");
        log.done("Alles auf einmal.");
        assert_eq!(lines(&log), ["Du: Und?", "companion: Alles auf einmal."]);
    }

    #[test]
    fn eine_blase_ohne_inhalt_bleibt_nicht_stehen() {
        let mut log = ChatLog::default();
        log.ask("Eins");
        log.delta("");
        log.ask("Zwei");
        assert_eq!(lines(&log), ["Du: Eins", "Du: Zwei"]);
    }

    #[test]
    fn eine_abgelehnte_frage_bekommt_ihre_zeile_und_keine_leere_blase() {
        let mut log = ChatLog::default();
        log.ask("Und?");
        log.system("Der Daemon meldet: no endpoint is configured for role chat_llm");
        assert_eq!(
            lines(&log),
            [
                "Du: Und?",
                "Der Daemon meldet: no endpoint is configured for role chat_llm",
            ]
        );
    }

    #[test]
    fn ein_verbindungswechsel_laesst_den_verlauf_stehen_und_die_halbe_antwort_nicht() {
        let mut log = ChatLog::default();
        log.ask("Und?");
        log.delta("Ich sehe na");
        log.connection_changed();
        assert!(!log.is_streaming());
        assert_eq!(lines(&log), ["Du: Und?", "companion: Ich sehe na"]);

        log.delta("Jetzt wieder da.");
        assert_eq!(
            lines(&log),
            [
                "Du: Und?",
                "companion: Ich sehe na",
                "companion: Jetzt wieder da."
            ]
        );
    }

    #[test]
    fn ein_werkzeug_ohne_namen_heisst_werkzeug() {
        let mut log = ChatLog::default();
        log.tool("  ", "  ");
        assert_eq!(lines(&log), ["Werkzeug"]);
    }

    #[test]
    fn zwei_runden_hintereinander_bleiben_getrennt() {
        let mut log = ChatLog::default();
        log.ask("Eins");
        log.delta("Erste\nAntwort");
        log.done("Erste\nAntwort");
        log.ask("Zwei");
        log.delta("Zweite\nAntwort");
        log.done("Zweite\nAntwort");
        assert_eq!(
            log.render(),
            "Du: Eins\ncompanion: Erste\nAntwort\nDu: Zwei\ncompanion: Zweite\nAntwort"
        );
        assert_eq!(log.messages().len(), 4);
    }
}
