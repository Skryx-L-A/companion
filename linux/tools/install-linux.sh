#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Baut Daemon und Shell im Release-Profil und installiert companion auf dieser Maschine, so
# dass es sich wie jede andere Anwendung öffnen lässt: ein Eintrag im Anwendungsstarter, kein
# Terminal, kein Handgriff, der den Daemon vorher selbst anwirft — das übernimmt die Shell
# jetzt selbst (`daemon::launch_if_needed`), sobald ihr Socket tot ist.
#
#   app/linux/tools/install-linux.sh [Zielverzeichnis für Binaries, Vorgabe ~/.local/bin]

set -euo pipefail

INSTALL_DIR="${1:-$HOME/.local/bin}"
LINUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$(cd "$LINUX_DIR/../.." && pwd)/app"
DESKTOP_DIR="$HOME/.local/share/applications"

echo "Baue companion-daemon, companion-hook und companion (Release)."
# companion-hook ist das, was Claude Code fuer Stop, SubagentStop und Notification aufruft,
# und companion traegt es ein; beide werden mit absolutem Pfad in die Einstellungen
# geschrieben, also muessen sie neben dem Daemon liegen und nicht im Bauverzeichnis.
( cd "$CORE_DIR" && cargo build -p companion-daemon -p companion-cli --release )
echo "Baue companion-linux (Release)."
( cd "$LINUX_DIR" && cargo build --release )

DAEMON_BUILT="$CORE_DIR/target/release/companion-daemon"
HOOK_BUILT="$CORE_DIR/target/release/companion-hook"
CLI_BUILT="$CORE_DIR/target/release/companion"
SHELL_BUILT="$LINUX_DIR/target/release/companion-linux"
for BUILT in "$DAEMON_BUILT" "$HOOK_BUILT" "$CLI_BUILT" "$SHELL_BUILT"; do
    [ -x "$BUILT" ] || { echo "$BUILT wurde nicht gebaut." >&2; exit 1; }
done

mkdir -p "$INSTALL_DIR" "$DESKTOP_DIR"
install -m 755 "$DAEMON_BUILT" "$INSTALL_DIR/companion-daemon"
install -m 755 "$HOOK_BUILT" "$INSTALL_DIR/companion-hook"
install -m 755 "$CLI_BUILT" "$INSTALL_DIR/companion"
install -m 755 "$SHELL_BUILT" "$INSTALL_DIR/companion-linux"
echo "Binaries installiert nach $INSTALL_DIR."

# `--daemon` benennt das Binary ausdrücklich, statt sich auf die Vorgabesuche von
# `daemon::locate_binary` zu verlassen (neben dem eigenen Binary, sonst PATH) — die träfe hier
# zwar ebenfalls zu, weil beide Binaries im selben Verzeichnis landen, aber der Wrapper soll
# auch dann noch richtig zeigen, wenn jemand ihn an einen anderen Ort kopiert. Den Socketpfad
# selbst muss der Wrapper nicht setzen: `companion-linux` löst ihn ohne `--socket` schon über
# `$XDG_RUNTIME_DIR` auf (`app/linux/src/paths.rs`, `socket_path`), und derselbe Pfad geht beim
# Selbststart als `COMPANION_SOCKET` an den Daemon weiter (`daemon::launch_if_needed`) — beide
# Seiten stimmen also von selbst überein, ganz ohne dass dieser Wrapper etwas berechnen muss.
cat > "$INSTALL_DIR/companion-start" <<WRAPPER
#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Von app/linux/tools/install-linux.sh erzeugt. Startet die Figur; die Shell selbst spawnt
# den Daemon, wenn sein Socket tot ist.
set -euo pipefail
exec "$INSTALL_DIR/companion-linux" --daemon "$INSTALL_DIR/companion-daemon" "\$@"
WRAPPER
chmod 755 "$INSTALL_DIR/companion-start"
echo "Wrapper geschrieben: $INSTALL_DIR/companion-start"

# Nach Desktop-Entry-Spezifikation gequotet: die Vorgabe `$HOME/.local/bin` bräuchte das
# nicht, aber ein selbst gewähltes Zielverzeichnis (Argument 1 dieses Skripts) mit einem
# Leerzeichen darin bräche die Exec=-Zeile sonst. Innerhalb der Anführungszeichen verlangt die
# Spezifikation, Backslash, Backtick, Dollarzeichen und das Anführungszeichen selbst mit
# Backslash zu maskieren — in dieser Reihenfolge, damit eine Maskierung nicht die nächste
# noch einmal maskiert.
EXEC_PATH="$INSTALL_DIR/companion-start"
EXEC_QUOTED="${EXEC_PATH//\\/\\\\}"
EXEC_QUOTED="${EXEC_QUOTED//\`/\\\`}"
EXEC_QUOTED="${EXEC_QUOTED//\$/\\\$}"
EXEC_QUOTED="${EXEC_QUOTED//\"/\\\"}"

cat > "$DESKTOP_DIR/companion.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=companion
Comment=Bildschirmfigur, die laufende Coding-Agent-Sessions zeigt und bedient
Exec="$EXEC_QUOTED"
Terminal=false
Categories=Utility;
DESKTOP
echo "Starter-Eintrag geschrieben: $DESKTOP_DIR/companion.desktop"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "HINWEIS: $INSTALL_DIR steht nicht im PATH dieser Shell — companion-start direkt aufrufen oder PATH ergänzen." ;;
esac

echo "Installiert. Start über den Anwendungsstarter (companion) oder $INSTALL_DIR/companion-start."
