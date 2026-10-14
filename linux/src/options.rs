// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! What the shell was asked to do on the command line.

use std::path::PathBuf;

/// Which corner the figure sits in. `DESIGN.md` § Figur und Overlay: "Ecke wählbar."
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Corner {
    TopLeft,
    TopRight,
    #[default]
    BottomRight,
    BottomLeft,
}

impl Corner {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "top-left" | "oben-links" => Some(Self::TopLeft),
            "top-right" | "oben-rechts" => Some(Self::TopRight),
            "bottom-right" | "unten-rechts" => Some(Self::BottomRight),
            "bottom-left" | "unten-links" => Some(Self::BottomLeft),
            _ => None,
        }
    }

    pub fn is_top(self) -> bool {
        matches!(self, Self::TopLeft | Self::TopRight)
    }

    pub fn is_left(self) -> bool {
        matches!(self, Self::TopLeft | Self::BottomLeft)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    pub corner: Corner,
    /// Edge length of the figure in logical pixels.
    pub size: i32,
    /// Distance from the two edges of the chosen corner.
    pub margin: i32,
    /// Anschlussname des Bildschirms, auf dem die Figur sitzt, etwa `DP-1`. `None` heißt:
    /// der Compositor entscheidet, und das ist bei ihm der gerade aktive Bildschirm.
    pub monitor: Option<String>,
    /// Socket to connect to. `None` means the usual place.
    pub socket: Option<PathBuf>,
    /// Where the daemon binary is, for the self-start when the socket is dead
    /// (`daemon::launch_if_needed`). `None` means next to this executable, or `PATH`.
    pub daemon_binary: Option<PathBuf>,
    /// Render every frame of every state into this directory and exit, without a display.
    /// This is how the figure is checked on a machine that has no compositor to show it on.
    pub render_to: Option<PathBuf>,
    /// Don't start a shell at all: find the running one over the session bus, ask it to open
    /// or close its panel, and exit. See `crate::remote`.
    pub toggle_panel: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            corner: Corner::default(),
            size: 128,
            margin: 24,
            monitor: None,
            socket: None,
            daemon_binary: None,
            render_to: None,
            toggle_panel: false,
        }
    }
}

pub const USAGE: &str = "\
companion-linux - die Figur als Overlay, die Sitzungsliste und der Chat.

Aufrufe:
  companion-linux [Optionen]

Optionen:
  --ecke <oben-links|oben-rechts|unten-links|unten-rechts>
                        Wo die Figur sitzt. Vorgabe: unten-rechts.
  --groesse <Pixel>     Kantenlänge der Figur. Vorgabe: 128.
  --abstand <Pixel>     Abstand zu den beiden Bildschirmkanten. Vorgabe: 24.
  --bildschirm <Name>   Anschlussname des Bildschirms, etwa DP-1 oder HDMI-A-1.
                        Ohne Angabe entscheidet der Compositor.
  --socket <Pfad>       Socket des Daemons. Vorgabe: $XDG_RUNTIME_DIR/companion/companion.sock.
  --daemon <Pfad>       Daemon-Binary, das gestartet wird, wenn der Socket tot ist.
                        Vorgabe: neben diesem Binary, sonst PATH.
  --bilder <Verzeichnis>
                        Zeichnet jedes Bild jedes Zustands als PNG dorthin und endet.
                        Braucht keinen Compositor.
  --panel-umschalten    Öffnet oder schließt das Panel der laufenden Schale und endet.
                        Ohne laufende Schale: Fehlermeldung, Austrittscode ungleich null.
  --hilfe               Diese Übersicht.
";

#[derive(Debug, PartialEq, Eq)]
pub enum Parsed {
    Run(Box<Options>),
    Help,
    Error(String),
}

/// Parses the arguments after the program name.
pub fn parse<I, S>(arguments: I) -> Parsed
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut options = Options::default();
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
        let argument = argument.as_ref();
        let mut value = || arguments.next().map(|next| next.as_ref().to_owned());
        match argument {
            "--hilfe" | "--help" | "-h" => return Parsed::Help,
            "--ecke" | "--corner" => match value().as_deref().map(Corner::parse) {
                Some(Some(corner)) => options.corner = corner,
                Some(None) => return Parsed::Error("Unbekannte Ecke.".to_owned()),
                None => return Parsed::Error("--ecke braucht einen Wert.".to_owned()),
            },
            "--groesse" | "--size" => match value().as_deref().map(str::parse::<i32>) {
                Some(Ok(size)) if (32..=1024).contains(&size) => options.size = size,
                Some(_) => {
                    return Parsed::Error(
                        "--groesse braucht eine Zahl von 32 bis 1024.".to_owned(),
                    );
                }
                None => return Parsed::Error("--groesse braucht einen Wert.".to_owned()),
            },
            "--abstand" | "--margin" => match value().as_deref().map(str::parse::<i32>) {
                Some(Ok(margin)) if (0..=1024).contains(&margin) => options.margin = margin,
                Some(_) => {
                    return Parsed::Error("--abstand braucht eine Zahl von 0 bis 1024.".to_owned());
                }
                None => return Parsed::Error("--abstand braucht einen Wert.".to_owned()),
            },
            "--bildschirm" | "--monitor" => match value() {
                Some(name) if !name.is_empty() => options.monitor = Some(name),
                _ => return Parsed::Error("--bildschirm braucht einen Namen.".to_owned()),
            },
            "--socket" => match value() {
                Some(path) => options.socket = Some(PathBuf::from(path)),
                None => return Parsed::Error("--socket braucht einen Pfad.".to_owned()),
            },
            "--daemon" => match value() {
                Some(path) => options.daemon_binary = Some(PathBuf::from(path)),
                None => return Parsed::Error("--daemon braucht einen Pfad.".to_owned()),
            },
            "--bilder" | "--render" => match value() {
                Some(path) => options.render_to = Some(PathBuf::from(path)),
                None => return Parsed::Error("--bilder braucht ein Verzeichnis.".to_owned()),
            },
            "--panel-umschalten" => options.toggle_panel = true,
            other => return Parsed::Error(format!("Unbekannte Option: {other}")),
        }
    }
    Parsed::Run(Box::new(options))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(arguments: &[&str]) -> Options {
        match parse(arguments) {
            Parsed::Run(options) => *options,
            other => panic!("expected a run, got {other:?}"),
        }
    }

    #[test]
    fn the_defaults_put_the_figure_in_the_bottom_right_corner() {
        let options = run(&[]);
        assert_eq!(options.corner, Corner::BottomRight);
        assert_eq!(options.size, 128);
        assert!(options.socket.is_none());
        assert!(options.monitor.is_none());
    }

    #[test]
    fn every_corner_can_be_named_in_either_language() {
        assert_eq!(run(&["--ecke", "oben-links"]).corner, Corner::TopLeft);
        assert_eq!(run(&["--corner", "top-right"]).corner, Corner::TopRight);
        assert_eq!(run(&["--ecke", "unten-links"]).corner, Corner::BottomLeft);
        assert_eq!(run(&["--ecke", "unten-rechts"]).corner, Corner::BottomRight);
    }

    #[test]
    fn the_corners_agree_on_which_edges_they_touch() {
        assert!(Corner::TopLeft.is_top() && Corner::TopLeft.is_left());
        assert!(!Corner::BottomRight.is_top() && !Corner::BottomRight.is_left());
    }

    #[test]
    fn the_screen_is_named_by_its_connector() {
        assert_eq!(
            run(&["--bildschirm", "DP-1"]).monitor.as_deref(),
            Some("DP-1")
        );
        assert_eq!(
            run(&["--monitor", "HDMI-A-1"]).monitor.as_deref(),
            Some("HDMI-A-1")
        );
        assert!(matches!(parse(["--bildschirm"]), Parsed::Error(_)));
    }

    #[test]
    fn the_daemon_binary_is_a_plain_path() {
        assert_eq!(
            run(&["--daemon", "/opt/companion/companion-daemon"]).daemon_binary,
            Some(PathBuf::from("/opt/companion/companion-daemon"))
        );
        assert!(matches!(parse(["--daemon"]), Parsed::Error(_)));
    }

    #[test]
    fn a_nonsense_value_is_refused_by_name_rather_than_ignored() {
        assert!(matches!(parse(["--ecke", "mitte"]), Parsed::Error(_)));
        assert!(matches!(parse(["--groesse", "2"]), Parsed::Error(_)));
        assert!(matches!(parse(["--groesse"]), Parsed::Error(_)));
        assert!(matches!(parse(["--was-auch-immer"]), Parsed::Error(_)));
    }

    #[test]
    fn help_wins_over_whatever_comes_after_it() {
        assert_eq!(parse(["--hilfe", "--ecke", "mitte"]), Parsed::Help);
    }

    #[test]
    fn panel_umschalten_is_off_unless_asked_for() {
        assert!(!run(&[]).toggle_panel);
        assert!(run(&["--panel-umschalten"]).toggle_panel);
    }
}
