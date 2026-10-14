// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! Die Farben des Systems statt eigener Farben.
//!
//! Eine Oberfläche mit fest eingetragenen Farben sieht auf genau einem Theme richtig aus.
//! Von den 22 Themes, die Omarchy 4 mitliefert, sind fünf hell (`catppuccin-latte`,
//! `flexoki-light`, `lupine`, `rose-pine`, `white`) — eine fest eingetragene dunkle Fläche
//! ist damit auf knapp einem Viertel aller Themes verkehrt.
//!
//! Also liest die Shell das aktive Theme: `~/.local/state/omarchy/current/theme/colors.toml`,
//! am liebsten über `omarchy-theme-color --all`, weil dieser Befehl dieselbe Alias- und
//! Rückfallkette auflöst wie alles andere auf der Maschine und die Shell so keinen
//! TOML-Parser mitschleppen muss. Fehlt der Befehl, liest sie die Datei selbst; fehlt auch
//! die, gelten die dokumentierten libadwaita-Werte, und die Shell sieht auf jedem anderen
//! Linux genauso richtig aus.
//!
//! Die Figur bleibt davon unberührt. Ihre Palette ist bewusst ihre eigene, damit sie auf
//! jedem Hintergrund dieselbe Figur ist — die Begründung steht bei ihr in
//! `figure/render.rs`.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use gtk4::{gdk, gio, glib};

/// Zeigt auf eine `colors.toml`, die statt der des Systems gelesen wird.
///
/// Nur dafür da, dass ein Test ein eigenes Theme vorlegen kann, ohne die Omarchy-Konfiguration
/// des Menschen anzufassen — es gibt keinen anderen Weg, den Theme-Wechsel zu prüfen, ohne
/// das Theme der laufenden Sitzung wirklich umzustellen.
pub const THEME_FILE_ENV: &str = "COMPANION_THEME_FILE";

/// Wie durchsichtig die Panelfläche ist.
///
/// Kein Farbwert, sondern eine Entscheidung über die Fläche: Das Panel schwebt über dem
/// Desktop, statt ein Fenster zu sein, und darf durchscheinen lassen, worüber es liegt.
const PANEL_ALPHA: f64 = 0.94;

/// Der Befehl, der das aktive Theme auflöst. Ohne Pfad, damit `PATH` entscheidet.
const THEME_COLOR_COMMAND: &str = "omarchy-theme-color";

/// Wie lange der Theme-Befehl höchstens laufen darf, bevor die Shell ihn abbricht und die
/// Datei selbst liest.
///
/// Zwei Sekunden sind großzügig für ein Skript, das eine Datei liest und ein paar Zeilen
/// ausgibt; auf peer gemessen bleibt es deutlich unter einer Zehntelsekunde. Sie sind zugleich
/// die Obergrenze dafür, wie lange der Start der Shell daran hängen kann.
const COMMAND_DEADLINE: Duration = Duration::from_secs(2);

/// Wie oft nachgesehen wird, ob der Befehl fertig ist.
const COMMAND_POLL: Duration = Duration::from_millis(20);

/// Deckkraft einer Trennlinie, aus libadwaitas `--border-opacity` (15 Prozent normal).
const BORDER_ALPHA: f64 = 0.15;

/// Deckkraft blasser Schrift, aus libadwaitas `--dim-opacity` (55 Prozent normal). Das ist
/// der Wert hinter der Stilklasse `.dimmed`.
///
/// Blasse Schrift wird daraus gerechnet statt aus dem Schlüssel `muted` des Themes. `muted`
/// ist in Omarchy eine Farbe für Beiwerk, nicht für Text: Auf Everforest steht dort `#475258`
/// neben dem Hintergrund `#2d353b`, und eine Zeile in dieser Farbe ist auf dem Bildschirm
/// kaum noch zu lesen. Auf 55 Prozent abgeblendeter Vordergrund bleibt dagegen in jedem Theme
/// lesbar, weil er aus der Farbe kommt, die dort ohnehin für Text gedacht ist.
const DIM_ALPHA: f64 = 0.55;

/// Hell oder dunkel, wie das Theme es sagt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Light,
    Dark,
}

/// Woher die Farben kommen — steht in der Statuszeile nicht, aber im Test und im Protokoll.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// Aus dieser `colors.toml`.
    Omarchy(PathBuf),
    /// Von keiner Maschine mit Omarchy: die dokumentierten libadwaita-Werte.
    Libadwaita,
}

/// Ein Farbwert mit drei Kanälen. Alpha kommt erst beim Schreiben der Regel dazu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl Rgb {
    /// `#rrggbb`, mit oder ohne Raute. Alles andere ist keine Farbe.
    pub fn parse(value: &str) -> Option<Self> {
        let digits = value.trim().trim_start_matches('#');
        if digits.len() != 6 || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        let channel = |from: usize| u8::from_str_radix(&digits[from..from + 2], 16).ok();
        Some(Self {
            red: channel(0)?,
            green: channel(2)?,
            blue: channel(4)?,
        })
    }

    /// Die Summe der drei Kanäle. Über 382 gilt als hell — dieselbe Schwelle, die
    /// `omarchy-theme-color` benutzt, wenn ein Theme seinen Modus nicht selbst nennt.
    fn brightness(self) -> u16 {
        u16::from(self.red) + u16::from(self.green) + u16::from(self.blue)
    }

    fn css(self, alpha: f64) -> String {
        format!("rgba({}, {}, {}, {alpha})", self.red, self.green, self.blue)
    }
}

/// Die fünf Farben, die die Shell braucht, und ihr Modus.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Palette {
    pub mode: Mode,
    pub background: Rgb,
    pub foreground: Rgb,
    pub muted: Rgb,
    pub accent: Rgb,
    pub warning: Rgb,
    pub source: Source,
}

impl Palette {
    /// Das aktive Theme, oder der Rückfall.
    ///
    /// `prefer_dark` entscheidet nur im Rückfall, welche der beiden dokumentierten
    /// libadwaita-Paletten gilt; es kommt aus den GTK-Einstellungen und wird hier
    /// hereingereicht, damit diese Funktion ohne Anzeige prüfbar bleibt.
    pub fn detect(prefer_dark: bool) -> Self {
        match theme_file() {
            Some(path) => Self::from_theme_file(&path).unwrap_or_else(|| {
                Self::libadwaita(if prefer_dark { Mode::Dark } else { Mode::Light })
            }),
            None => Self::libadwaita(if prefer_dark { Mode::Dark } else { Mode::Light }),
        }
    }

    /// Erst der ausgelieferte Befehl, dann die Datei selbst.
    ///
    /// Der Befehl ist der bessere Weg, weil er die Aliasse auflöst und den Modus nach
    /// derselben Kette bestimmt wie der Rest des Systems. Fehlt er — jede Maschine ohne
    /// Omarchy —, bleibt die Datei, und die reicht für die fünf Schlüssel hier.
    fn from_theme_file(path: &Path) -> Option<Self> {
        let values = read_via_command(path).or_else(|| read_file(path))?;
        Self::from_values(&values, Source::Omarchy(path.to_path_buf()))
    }

    fn from_values(values: &BTreeMap<String, String>, source: Source) -> Option<Self> {
        let color = |key: &str| values.get(key).and_then(|value| Rgb::parse(value));
        let background = color("background").or_else(|| color("bg"))?;
        let foreground = color("foreground").or_else(|| color("fg"))?;
        Some(Self {
            mode: mode_of(values, background),
            background,
            foreground,
            // `dark_foreground` ist in Omarchy 4 der blasse Vordergrund; ohne beide bleibt
            // der gewöhnliche Vordergrund, blass ist besser als unsichtbar.
            muted: color("muted")
                .or_else(|| color("dark_foreground"))
                .unwrap_or(foreground),
            accent: color("accent")
                .or_else(|| color("blue"))
                .unwrap_or(foreground),
            // Die Warnfarbe des Themes, nicht ein selbst gewählter Bernsteinton. `orange`
            // fehlt in dreien der mitgelieferten Themes, `yellow` in keinem.
            warning: color("yellow")
                .or_else(|| color("orange"))
                .unwrap_or(foreground),
            source,
        })
    }

    /// Die dokumentierten libadwaita-Vorgaben, abgerufen am 25.08.2026 von
    /// `https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1-latest/css-variables.html`.
    ///
    /// Hier stehen ausnahmsweise feste Werte, und das ist der eine Fall, in dem das richtig
    /// ist: Ohne Omarchy gibt es kein Theme zu lesen, und die Shell bindet libadwaita nicht
    /// ein, könnte `var(--window-bg-color)` also gar nicht auflösen. Die Werte sind
    /// abgeschrieben, nicht erfunden — `--window-bg-color`, `--window-fg-color`,
    /// `--accent-color`, `--warning-color`, jeweils hell und dunkel. Einzige Abweichung: Der
    /// helle Vordergrund ist dort mit 80 Prozent Deckkraft angegeben; die Shell nimmt ihn
    /// voll, das ist mehr Kontrast und nicht weniger.
    pub fn libadwaita(mode: Mode) -> Self {
        let hex = |value: &str| Rgb::parse(value).expect("eine hier notierte Farbe ist gültig");
        match mode {
            Mode::Light => Self {
                mode,
                background: hex("#fafafb"),
                foreground: hex("#000006"),
                muted: hex("#5e5c64"),
                accent: hex("#0461be"),
                warning: hex("#905400"),
                source: Source::Libadwaita,
            },
            Mode::Dark => Self {
                mode,
                background: hex("#222226"),
                foreground: hex("#ffffff"),
                muted: hex("#9a9996"),
                accent: hex("#81d0ff"),
                warning: hex("#ffc252"),
                source: Source::Libadwaita,
            },
        }
    }

    /// Das Stylesheet der Shell, aus dieser Palette.
    ///
    /// Keine Schriftgröße: Die GNOME HIG sagt wörtlich „Don't hard-code font styles or sizes,
    /// since this can interfere with accessibility features." Wer im System große Schrift
    /// eingestellt hat, hat sie hier also auch.
    pub fn stylesheet(&self) -> String {
        format!(
            "window.companion-figure {{ background-color: transparent; }}\n\
             window.companion-panel {{ background-color: transparent; }}\n\
             .panel-body {{\n\
             \x20 background-color: {body};\n\
             \x20 color: {text};\n\
             \x20 border: 1px solid {border};\n\
             \x20 border-radius: 12px;\n\
             \x20 padding: 12px;\n\
             }}\n\
             .panel-body textview,\n\
             .panel-body textview text {{ background-color: transparent; color: {text}; }}\n\
             .panel-body scrolledwindow,\n\
             .panel-body list,\n\
             .panel-body list > row {{ background-color: transparent; color: {text}; }}\n\
             .panel-body separator {{ background-color: {muted}; }}\n\
             .panel-title {{ font-weight: bold; color: {accent}; }}\n\
             .panel-note {{ color: {dim}; }}\n\
             .panel-warning {{ color: {warning}; }}\n\
             .session-name {{ font-weight: bold; }}\n\
             .session-detail {{ color: {dim}; }}\n",
            body = self.background.css(PANEL_ALPHA),
            text = self.foreground.css(1.0),
            border = self.foreground.css(BORDER_ALPHA),
            dim = self.foreground.css(DIM_ALPHA),
            accent = self.accent.css(1.0),
            muted = self.muted.css(1.0),
            warning = self.warning.css(1.0),
        )
    }
}

/// Der Modus nach derselben Kette wie `omarchy-theme-color`: erst `mode`, dann das alte
/// `theme_type`, sonst die Helligkeit der Hintergrundfarbe.
fn mode_of(values: &BTreeMap<String, String>, background: Rgb) -> Mode {
    for key in ["mode", "theme_type"] {
        match values
            .get(key)
            .map(|value| value.trim().to_ascii_lowercase())
        {
            Some(value) if value == "light" => return Mode::Light,
            Some(value) if value == "dark" => return Mode::Dark,
            _ => {}
        }
    }
    if background.brightness() > 382 {
        Mode::Light
    } else {
        Mode::Dark
    }
}

fn env(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|value| !value.is_empty())
}

/// Die `colors.toml`, die gilt — oder nichts, wenn diese Maschine kein Omarchy hat.
pub fn theme_file() -> Option<PathBuf> {
    let path = match env(THEME_FILE_ENV) {
        Some(path) => PathBuf::from(path),
        None => state_dir()?.join("omarchy/current/theme/colors.toml"),
    };
    path.is_file().then_some(path)
}

fn state_dir() -> Option<PathBuf> {
    if let Some(state) = env("XDG_STATE_HOME") {
        return Some(PathBuf::from(state));
    }
    Some(PathBuf::from(env("HOME")?).join(".local/state"))
}

/// Die Datei, die Omarchy beim Theme-Wechsel neu schreibt. Sie zu beobachten ist billiger,
/// als ein Skript in den Hook-Ordner des Menschen zu legen.
fn theme_name_file() -> Option<PathBuf> {
    if env(THEME_FILE_ENV).is_some() {
        return None;
    }
    Some(state_dir()?.join("omarchy/current/theme.name"))
}

/// `omarchy-theme-color --file <pfad> --all`: eine Zeile je Schlüssel, Tabulator, Wert.
fn read_via_command(path: &Path) -> Option<BTreeMap<String, String>> {
    read_via(THEME_COLOR_COMMAND.as_ref(), path)
}

/// Derselbe Aufruf, aber mit dem Programm als Argument, damit ein Test einen Stellvertreter
/// vorlegen kann, ohne den `PATH` des Prozesses anzufassen.
///
/// Zwei Dinge machen den Aufruf gutmütig, und beide fehlten vorher. Der Kindprozess bekommt
/// eine leere Standardeingabe statt der geerbten: Ein Skript, das aus Versehen liest, wartete
/// sonst auf eine Eingabe, die niemand macht. Und er bekommt eine Frist. Ohne sie hinge
/// `Styles::install` für immer, und weil das synchron in `Shell::new` läuft, käme die ganze
/// Shell nie auf den Bildschirm, ohne Meldung und ohne Abbruch. Läuft der Befehl in die Frist,
/// wird er beendet, und die Shell liest die Datei selbst ([`read_file`]).
fn read_via(program: &Path, path: &Path) -> Option<BTreeMap<String, String>> {
    let mut child = Command::new(program)
        .arg("--file")
        .arg(path)
        .arg("--all")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let deadline = Instant::now() + COMMAND_DEADLINE;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return None,
            Ok(None) if Instant::now() >= deadline => {
                eprintln!(
                    "{} hat nach {} Sekunden nicht geantwortet. Die Farben kommen jetzt direkt aus {}.",
                    program.display(),
                    COMMAND_DEADLINE.as_secs(),
                    path.display()
                );
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(COMMAND_POLL),
            Err(_) => return None,
        }
    }

    // Erst nach dem Ende gelesen, denn dann steht alles im Puffer der Röhre. Schriebe ein
    // ersetzter Befehl mehr hinein, als dort hineinpasst, bliebe er beim Schreiben stehen,
    // liefe in die Frist und wäre oben schon abgeräumt. Die echte Ausgabe ist gut ein
    // Kilobyte lang.
    let mut text = String::new();
    child.stdout.take()?.read_to_string(&mut text).ok()?;
    let values = parse_tabular(&text);
    (!values.is_empty()).then_some(values)
}

/// Die Datei selbst, wenn der Befehl fehlt.
fn read_file(path: &Path) -> Option<BTreeMap<String, String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let values = parse_toml(&text);
    (!values.is_empty()).then_some(values)
}

/// Was `--all` ausgibt: `schlüssel\twert`, leere Werte übersprungen.
fn parse_tabular(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| line.split_once('\t'))
        .filter(|(_, value)| !value.trim().is_empty())
        .map(|(key, value)| (key.trim().to_owned(), value.trim().to_owned()))
        .collect()
}

/// Gerade so viel TOML, wie eine `colors.toml` braucht: `schlüssel = "wert"`, ein Paar je
/// Zeile, Kommentare mit `#`. Kein Parser, keine Abhängigkeit — und wenn dort je etwas
/// Verschachteltes stünde, greift der Weg über den Befehl darüber.
fn parse_toml(text: &str) -> BTreeMap<String, String> {
    let mut values = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') || line.starts_with('[') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        // Der Kommentar wird erst nach dem Wert abgeschnitten, nie davor: Eine Farbe fängt
        // selbst mit einer Raute an, und `#7fbbb3  # der Akzent` am Zeichen `#` zu trennen
        // ließe genau nichts übrig.
        let value = value.trim();
        let value = match value.strip_prefix('"') {
            Some(rest) => rest.split('"').next().unwrap_or(""),
            None => match value.strip_prefix('\'') {
                Some(rest) => rest.split('\'').next().unwrap_or(""),
                None => value.split(" #").next().unwrap_or("").trim(),
            },
        };
        if !value.is_empty() {
            values.insert(key.trim().to_owned(), value.to_owned());
        }
    }
    values
}

/// Der Stilanbieter der Shell, und die Beobachter, die ihn aktuell halten.
///
/// Beim Neuladen wird der ganze Anbieter ersetzt und nicht eine Regel nachgeschoben: Sonst
/// bliebe die alte Farbe unter der neuen liegen und entschiede überall dort, wo die neue
/// nichts sagt.
pub struct Styles {
    display: gdk::Display,
    provider: RefCell<gtk4::CssProvider>,
    palette: RefCell<Palette>,
    /// Nur zum Festhalten: Ein fallengelassener `FileMonitor` beobachtet nichts mehr.
    monitors: RefCell<Vec<gio::FileMonitor>>,
    /// Ob schon ein Neuladen ansteht. Ein Theme-Wechsel schreibt mehrere Dateien und löst
    /// mehrere Ereignisse aus; ohne diesen Merker liefe das Einlesen fünfmal statt einmal.
    pending: RefCell<bool>,
}

impl Styles {
    /// Liest das Theme und hängt das Stylesheet an die Anzeige.
    pub fn install(display: &gdk::Display) -> Rc<Self> {
        announce_override();
        let palette = Palette::detect(prefers_dark());
        let provider = gtk4::CssProvider::new();
        provider.load_from_string(&palette.stylesheet());
        gtk4::style_context_add_provider_for_display(
            display,
            &provider,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        follow_mode(palette.mode);

        Rc::new(Self {
            display: display.clone(),
            provider: RefCell::new(provider),
            palette: RefCell::new(palette),
            monitors: RefCell::new(Vec::new()),
            pending: RefCell::new(false),
        })
    }

    pub fn palette(&self) -> Palette {
        self.palette.borrow().clone()
    }

    /// Beobachtet das aktive Theme, damit ein Wechsel im laufenden Betrieb ankommt.
    ///
    /// Beide Dateien: `theme.name` schreibt Omarchy bei jedem Wechsel neu, und die
    /// `colors.toml` wird dabei ersetzt. Welche der beiden zuerst meldet, ist gleichgültig —
    /// der Merker unten fasst die Meldungen zu einem Neuladen zusammen.
    pub fn watch(self: &Rc<Self>) {
        let paths: Vec<PathBuf> = [theme_file(), theme_name_file()]
            .into_iter()
            .flatten()
            .collect();
        for path in paths {
            let file = gio::File::for_path(&path);
            let Ok(monitor) =
                file.monitor_file(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE)
            else {
                continue;
            };
            let this = Rc::downgrade(self);
            monitor.connect_changed(move |_, _, _, _| {
                if let Some(styles) = this.upgrade() {
                    styles.reload_soon();
                }
            });
            self.monitors.borrow_mut().push(monitor);
        }
    }

    /// Sammelt die Ereignisse eines Theme-Wechsels ein und lädt danach einmal neu.
    fn reload_soon(self: &Rc<Self>) {
        if std::mem::replace(&mut *self.pending.borrow_mut(), true) {
            return;
        }
        let this = Rc::downgrade(self);
        glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
            if let Some(styles) = this.upgrade() {
                *styles.pending.borrow_mut() = false;
                styles.reload();
            }
        });
    }

    /// Liest das Theme neu und ersetzt den Anbieter.
    pub fn reload(&self) {
        let palette = Palette::detect(prefers_dark());
        if palette == *self.palette.borrow() {
            return;
        }
        let provider = gtk4::CssProvider::new();
        provider.load_from_string(&palette.stylesheet());
        gtk4::style_context_remove_provider_for_display(&self.display, &*self.provider.borrow());
        gtk4::style_context_add_provider_for_display(
            &self.display,
            &provider,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        follow_mode(palette.mode);
        *self.provider.borrow_mut() = provider;
        *self.palette.borrow_mut() = palette;
    }
}

/// Sagt es laut, wenn die Testtür offen steht.
///
/// `COMPANION_THEME_FILE` schiebt eine andere Datei an die Stelle des Systemthemes. Bleibt so
/// eine Zeile in einer Shell stehen, aus der jemand die Anwendung später startet, zeigt sie
/// dauerhaft die falschen Farben, und ohne diese Meldung stünde nirgends, warum.
fn announce_override() {
    let Some(path) = env(THEME_FILE_ENV) else {
        return;
    };
    let path = PathBuf::from(path);
    if path.is_file() {
        eprintln!(
            "{THEME_FILE_ENV} ist gesetzt: Die Farben kommen aus {}, nicht aus dem Theme des Systems.",
            path.display()
        );
    } else {
        eprintln!(
            "{THEME_FILE_ENV} zeigt auf {}, und dort liegt keine Datei. Es gelten die \
             libadwaita-Vorgaben statt der Farben eines Themes.",
            path.display()
        );
    }
}

/// Ob GTK gerade dunkel eingestellt ist. Entscheidet nur, welche libadwaita-Palette der
/// Rückfall nimmt, wenn es gar kein Theme zu lesen gibt.
fn prefers_dark() -> bool {
    let Some(settings) = gtk4::Settings::default() else {
        return true;
    };
    settings.is_gtk_application_prefer_dark_theme()
        || settings
            .gtk_theme_name()
            .is_some_and(|name| name.to_lowercase().contains("dark"))
}

/// Stellt GTK auf denselben Modus wie das Theme.
///
/// Ohne das behielten Eingabefeld, Knopf und Bildlaufleiste die Farben des GTK-Themes,
/// während die Fläche darum herum die des Omarchy-Themes trägt — ein helles Eingabefeld in
/// einem dunklen Panel. Das ist keine eigene Entscheidung gegen die des Menschen, sondern
/// dieselbe: Omarchy setzt beim Theme-Wechsel ohnehin `color-scheme` mit.
fn follow_mode(mode: Mode) {
    let Some(settings) = gtk4::Settings::default() else {
        return;
    };
    let dark = mode == Mode::Dark;
    settings.set_gtk_application_prefer_dark_theme(dark);
    // Heißt das GTK-Theme `Adwaita-dark`, ist die Einstellung darueber wirkungslos: Der Name
    // nennt die dunkle Fassung schon, und GTK lädt sie unabhängig davon. Dann muss der Name
    // mit. Ein selbst gewähltes GTK-Theme bleibt dagegen unangetastet — es wäre seine
    // Entscheidung, nicht unsere.
    let name = settings.gtk_theme_name().map(|name| name.to_string());
    if matches!(name.as_deref(), Some("Adwaita") | Some("Adwaita-dark")) {
        settings.set_gtk_theme_name(Some(if dark { "Adwaita-dark" } else { "Adwaita" }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect()
    }

    #[test]
    fn a_colour_is_six_hex_digits_and_nothing_else() {
        assert_eq!(
            Rgb::parse("#2d353b"),
            Some(Rgb {
                red: 0x2d,
                green: 0x35,
                blue: 0x3b
            })
        );
        assert_eq!(Rgb::parse("2d353b"), Rgb::parse("#2d353b"));
        assert!(Rgb::parse("").is_none());
        assert!(Rgb::parse("#fff").is_none());
        assert!(Rgb::parse("rebeccapurple").is_none());
        assert!(Rgb::parse("#gggggg").is_none());
    }

    /// Die Ausgabe von `omarchy-theme-color --all`, wie sie am 25.08.2026 auf peer gemessen
    /// wurde: eine Zeile je Schlüssel, Tabulator dazwischen, leere Werte kommen vor.
    #[test]
    fn the_tabular_output_is_read_and_empty_values_are_dropped() {
        let read = parse_tabular("accent\t#7fbbb3\nbackground\t#2d353b\nblue\t\nmode\tdark\n");
        assert_eq!(read.get("accent").map(String::as_str), Some("#7fbbb3"));
        assert_eq!(read.get("mode").map(String::as_str), Some("dark"));
        assert!(!read.contains_key("blue"));
    }

    #[test]
    fn the_file_itself_is_read_when_the_command_is_missing() {
        let read = parse_toml(
            "# Everforest\nmode = \"dark\"\naccent = \"#7fbbb3\"  # der Akzent\n\
             background = '#2d353b'\n[extra]\nleer =\n",
        );
        assert_eq!(read.get("mode").map(String::as_str), Some("dark"));
        assert_eq!(read.get("accent").map(String::as_str), Some("#7fbbb3"));
        assert_eq!(read.get("background").map(String::as_str), Some("#2d353b"));
        assert!(!read.contains_key("leer"));
    }

    #[test]
    fn the_mode_comes_from_the_theme_before_it_is_guessed() {
        let dark_background = Rgb::parse("#2d353b").unwrap();
        assert_eq!(
            mode_of(&values(&[("mode", "light")]), dark_background),
            Mode::Light
        );
        assert_eq!(
            mode_of(&values(&[("theme_type", "light")]), dark_background),
            Mode::Light
        );
        assert_eq!(mode_of(&values(&[]), dark_background), Mode::Dark);
        assert_eq!(
            mode_of(&values(&[]), Rgb::parse("#fafafb").unwrap()),
            Mode::Light
        );
    }

    #[test]
    fn a_palette_needs_a_background_and_a_foreground_and_nothing_more() {
        let bare = Palette::from_values(
            &values(&[("background", "#2d353b"), ("foreground", "#d3c6aa")]),
            Source::Libadwaita,
        )
        .expect("zwei Schlüssel reichen");
        // Was fehlt, wird zum Vordergrund statt zu nichts: blass ist besser als unsichtbar.
        assert_eq!(bare.muted, bare.foreground);
        assert_eq!(bare.warning, bare.foreground);

        assert!(
            Palette::from_values(&values(&[("foreground", "#d3c6aa")]), Source::Libadwaita)
                .is_none()
        );
    }

    #[test]
    fn the_old_aliases_still_answer() {
        let aliased = Palette::from_values(
            &values(&[("bg", "#2d353b"), ("fg", "#d3c6aa")]),
            Source::Libadwaita,
        )
        .expect("bg und fg sind die alten Namen");
        assert_eq!(aliased.background, Rgb::parse("#2d353b").unwrap());
    }

    #[test]
    fn the_warning_falls_back_from_yellow_to_orange() {
        let with_orange = Palette::from_values(
            &values(&[
                ("background", "#2d353b"),
                ("foreground", "#d3c6aa"),
                ("orange", "#e69875"),
            ]),
            Source::Libadwaita,
        )
        .unwrap();
        assert_eq!(with_orange.warning, Rgb::parse("#e69875").unwrap());
    }

    /// Der Befund aus dem Review: Weder eine feste Farbe noch eine feste Schriftgröße darf
    /// im Stylesheet stehen. Beides ist hier belegbar, weil das Stylesheet erzeugt wird.
    #[test]
    fn the_stylesheet_carries_the_theme_and_no_fixed_value() {
        let palette = Palette::from_values(
            &values(&[
                ("background", "#2d353b"),
                ("foreground", "#d3c6aa"),
                ("muted", "#475258"),
                ("accent", "#7fbbb3"),
                ("yellow", "#dbbc7f"),
            ]),
            Source::Libadwaita,
        )
        .unwrap();
        let css = palette.stylesheet();

        assert!(css.contains("rgba(45, 53, 59, 0.94)"), "{css}");
        assert!(css.contains("rgba(127, 187, 179, 1)"), "{css}");
        assert!(css.contains("rgba(219, 188, 127, 1)"), "{css}");
        // Blasse Schrift kommt vom Vordergrund, nicht von `muted`: Der Schlüssel des Themes
        // trägt hier die Trennlinie, weil er dafür gedacht ist und für Text zu dunkel wäre.
        assert!(css.contains("rgba(211, 198, 170, 0.55)"), "{css}");
        assert!(
            css.contains("separator { background-color: rgba(71, 82, 88, 1)"),
            "{css}"
        );
        assert!(!css.contains("font-size"), "{css}");
        assert!(!css.contains('#'), "{css}");
        // Der Bernsteinton aus der alten Fassung, der nur auf einem Theme richtig war.
        assert!(!css.contains("e8a33d"), "{css}");
    }

    /// Legt ein ausführbares Skript an und gibt seinen Pfad zurück.
    ///
    /// Ein Stellvertreter im eigenen Testordner, nie das echte `omarchy-theme-color`: Der
    /// Test soll die Frist prüfen, nicht das System, und er soll auf einer Maschine ohne
    /// Omarchy genauso laufen.
    fn stand_in(name: &str, body: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "companion-theme-test-{}-{name}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let script = directory.join("omarchy-theme-color");
        std::fs::write(&script, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        script
    }

    fn a_theme_file(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "companion-theme-test-{}-{name}.toml",
            std::process::id()
        ));
        std::fs::write(&path, "mode = \"dark\"\nbackground = \"#2d353b\"\n").unwrap();
        path
    }

    /// Der Befund M1 aus dem Review: Ein hängender Theme-Befehl darf den Start der Shell
    /// nicht aufhalten. `Command::output` wartete ohne Frist, und weil das synchron vor dem
    /// ersten `present()` läuft, käme die Shell nie auf den Bildschirm.
    #[test]
    fn a_hanging_command_gives_up_at_the_deadline() {
        let script = stand_in("haengt", "sleep 30");
        let theme = a_theme_file("haengt");

        let started = Instant::now();
        let read = read_via(&script, &theme);
        let dauer = started.elapsed();

        assert!(read.is_none(), "ein abgebrochener Befehl liefert nichts");
        assert!(
            dauer >= COMMAND_DEADLINE,
            "vor der Frist aufgegeben: {dauer:?}"
        );
        assert!(
            dauer < COMMAND_DEADLINE + Duration::from_secs(2),
            "die Frist hat nicht gegriffen: {dauer:?}"
        );
        // Und der Rückfall trägt: Was der Befehl nicht sagen konnte, steht in der Datei.
        assert!(read_file(&theme).is_some());

        let _ = std::fs::remove_dir_all(script.parent().unwrap());
        let _ = std::fs::remove_file(&theme);
    }

    /// Die Gegenprobe: Ein Befehl, der antwortet, wird gelesen wie zuvor.
    #[test]
    fn a_command_that_answers_is_read() {
        let script = stand_in("antwortet", "printf 'accent\\t#7fbbb3\\nmode\\tdark\\n'");
        let theme = a_theme_file("antwortet");

        let read = read_via(&script, &theme).expect("der Stellvertreter antwortet");
        assert_eq!(read.get("accent").map(String::as_str), Some("#7fbbb3"));
        assert_eq!(read.get("mode").map(String::as_str), Some("dark"));

        let _ = std::fs::remove_dir_all(script.parent().unwrap());
        let _ = std::fs::remove_file(&theme);
    }

    /// Ein Befehl, der mit einem Fehler endet, gilt als nicht vorhanden. Sonst stünde eine
    /// halbe Ausgabe in der Palette.
    #[test]
    fn a_command_that_fails_counts_as_missing() {
        let script = stand_in("scheitert", "echo 'accent\t#7fbbb3'; exit 1");
        let theme = a_theme_file("scheitert");

        assert!(read_via(&script, &theme).is_none());

        let _ = std::fs::remove_dir_all(script.parent().unwrap());
        let _ = std::fs::remove_file(&theme);
    }

    #[test]
    fn the_two_documented_fallbacks_are_not_the_same_palette() {
        let light = Palette::libadwaita(Mode::Light);
        let dark = Palette::libadwaita(Mode::Dark);
        assert_eq!(light.source, Source::Libadwaita);
        assert!(light.background.brightness() > dark.background.brightness());
        assert_eq!(mode_of(&values(&[]), light.background), Mode::Light);
        assert_eq!(mode_of(&values(&[]), dark.background), Mode::Dark);
    }
}
