# companion-linux

The Linux shell: a figure in a screen corner, a chat panel with a session list, and a tray
icon. GTK4 with wlr-layer-shell carries the two windows; the daemon does the actual work.

## Build and run

```sh
cd app/linux
cargo build          # debug binary
cargo test            # unit tests, no compositor needed
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

The binary needs a Wayland compositor with the layer-shell protocol — sway or Hyprland, not
XWayland. `--bilder <Verzeichnis>` renders every frame of every figure state to PNG and exits
without opening a window, which is how the figure gets checked on a machine with no
compositor at all. `--hilfe` lists every flag; `--socket` and `--daemon` point the shell at a
socket and a daemon binary other than the defaults, which is what the test scripts use so a
run never touches an installed copy's state.

## The keyboard's way to the panel

The figure never takes the keyboard, so a click is the only way to open the panel — until
`--panel-umschalten`. Run

```sh
companion-linux --panel-umschalten
```

against a shell that is already running, and it opens or closes that shell's panel, then
exits. Against no running shell it exits with a nonzero code and says so, rather than opening
a second window.

This works because a registered `gtk4::Application` exports every action added to it over
D-Bus, at the well-known name that is the application id — the same mechanism a desktop's
remote "Quit" menu entry uses on a running app. `--panel-umschalten` looks up that name on the
session bus, confirms it is owned, and calls `org.gtk.Actions.Activate` with
`panel-umschalten`, the action `Shell::install_panel_toggle_action` registers alongside the
existing `beenden` action. The whole thing was found by accident before it had a name: a
second `companion-linux` process re-triggered `activate` on the first one instead of opening
its own window, because the application was never told it may run more than once. `remote.rs`
gives that door a contract instead of leaving it a side effect.

Bind it to a key in Hyprland's `~/.config/hypr/bindings.lua` (see that file's own comments for
the syntax):

```lua
o.bind("SUPER + C", "Companion-Panel", "companion-linux --panel-umschalten")
```

## The tray

`org.kde.StatusNotifierItem` over D-Bus, drawn with the same code that draws the figure, at
rest. The menu has four entries: open/close the panel, show/hide the figure, a separator, and
quit — the same `beenden` path the panel's own menu and Ctrl+Q use. On Omarchy, Quickshell's
`omarchy.tray` bar widget picks it up through its own `StatusNotifierWatcher`; a first-time
item there lands in the collapsed drawer rather than pinned, which is the bar's default
classification for any item, not something this shell controls. Without a watcher on the bus
at all — a bare test compositor, or a session still starting up — the tray keeps its own
D-Bus name and its exported object regardless, and simply has nobody to tell.

`tray.rs` is built on `ksni` rather than a hand-rolled `zbus` client. Both end up depending on
the same D-Bus reactor crates (`ksni` adds 35 crates to this workspace with the `async-io` and
`blocking` features, a plain `zbus` client capable of the same blocking calls adds 52, since
its own "blocking-api" default pulls in `async-io` regardless), so raw `zbus` would not have
been the smaller dependency either. What it would have meant is hand-writing the
StatusNotifierItem interface and the `com.canonical.dbusmenu` protocol the menu rides on by
hand — a much larger, easier to get subtly wrong undertaking for what the four-item menu this
shell needs. `ksni` carries that weight and re-registers with the watcher on its own if one
appears after the tray already started, which is what `assume_sni_available(true)` in
`tray::spawn` asks for.

Since `ksni`'s tray callbacks run on its own background thread, never on the GTK thread, they
only ever send a `TrayCommand` down an `async_channel` and return; `Shell::spawn_tray` reads
that channel the same way `Shell::connect` already reads the daemon's messages.

## Structure

| Module | Contents |
|---|---|
| `figure` | the state machine, the Cairo drawing, the alpha mask for click-through |
| `ui::overlay` | the figure's layer-shell window |
| `ui::panel` | the session list and chat window, and the two application actions |
| `ui::mod` (`Shell`) | wires the daemon connection, the figure, the panel and the tray together |
| `client` | the daemon connection and its line protocol |
| `daemon` | starting and stopping a daemon this shell spawned itself |
| `tray` | the `org.kde.StatusNotifierItem` tray, its icon and its menu |
| `remote` | `--panel-umschalten`'s D-Bus call into a running shell |
| `theme` | reading the system's colours, and watching for a theme change |
| `mapping` | when the figure raises its hand, ported from the Mac shell's rules |
| `reconnect` | the 1/2/5/10/30 second reconnect schedule |
| `options` | the command line |
| `paths` | the XDG paths for the socket, the config directory and the token file |

## Tests

`cargo test` covers everything that needs no display: the state machine, the alpha mask, the
line protocol, the command line, the theme file, the tray's icon byte order and its menu, and
`remote`'s object path. `tests/linux/nested-shell.sh` runs the shell against its own headless
sway compositor for what a unit test cannot reach — the figure and panel on screen, click
passthrough, the chat over a real socket, reconnecting after the daemon dies, a theme change
while running, and the tray's D-Bus registration. It never touches the machine's own Wayland
session, D-Bus session bus or Hyprland config.
