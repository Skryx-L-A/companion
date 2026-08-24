# companion-mac

The macOS shell: a figure in a screen corner, a chat panel, a session list, and a menu bar
item. The daemon does the work; this package only shows it and takes input.

## Build and run

The package builds from the command line; Xcode is not required.

```sh
cd app/mac
./Scripts/build-wakeword.sh      # the Rust wakeword library — see below, run this first
swift build                      # debug binary
swift test                       # unit tests
./Scripts/make-app-bundle.sh     # companion.app with Info.plist and LSUIElement
```

`Scripts/build-wakeword.sh` builds `app/crates/companion-wakeword-ffi` with cargo and copies
the archive into `Vendor/`. SwiftPM cannot build Rust, so without that step the link fails
with `library not found for -lcompanion_wakeword_ffi`. `make-app-bundle.sh` and the scripts
in `tests/mac/` run it themselves; a bare `swift build` does not. The archive is build output
and stays out of git.

The binary runs without a bundle. `--demo` fills the panels with sample content and skips the
daemon, which is the quickest way to see the overlay:

```sh
.build/debug/companion-mac --demo
```

`--help` lists the rest. `--defaults-suite <name>` writes settings into a throwaway domain;
the test scripts use it so a run never touches the settings of an installed copy.
`--config-dir <pfad>` points the shell at another configuration directory, which is where it
finds the socket and the token, and `--onboarding skip|force` decides whether the quick start
appears. `--dump-sessions <pfad>` and `--snapshot <pfad>` write what the shell knows about the
sessions as JSON and as a picture, both on the way out, which is what
`tests/mac/e2e-daemon.sh` reads.

## Structure

| Target | Contents |
|---|---|
| `CompanionProtocol` | the wire types of `app/protocol/schema`, the socket and the client |
| `CWakeword` | module map over the C header of `app/crates/companion-wakeword-ffi` |
| `CompanionWakeword` | Swift over that ABI: the detector, training, where models are kept |
| `CompanionUI` | overlay panel, figure, the panels, menu bar item, settings, quick start |
| `CompanionMac` | the executable and its command line |

Inside `CompanionUI`, `Overlay` holds the window and the layout, `Figure` the sprites and the
state machine, `Panels` the SwiftUI panels, `Models` the session, settings and quick-start
types.

## How the session list stays current

The list is read once with `list` after the handshake and then kept current by events. The
shell reads it again whenever it has reason to doubt that it saw everything: after a
reconnect, when the daemon reports that this connection lost events, when a sequence number
skips, and when an event arrives about a session the list does not have. Nothing is repaired
by guessing; the daemon is the source of truth.

The chat panel sends to the session that is selected in the list, and a question a session
asks appears above the input with its own answer field. The answer goes back through the same
`send`, addressed to the session that asked.

## The two decisions worth knowing

**The window never activates the app.** It is an `NSPanel` with `nonactivatingPanel`, and the
process runs as an accessory, so there is no Dock icon and no menu of its own. The chat field
still takes keystrokes: the panel becomes key while it is typed into, which does not make the
app frontmost. That is what DESIGN.md means by never taking focus — the application, not the
text field.

**Clicks are decided per pixel.** A borderless transparent window would otherwise swallow
every click in its empty area. The controller follows the pointer and switches
`ignoresMouseEvents` depending on whether the point falls on an open panel or on a covered
pixel of the current sprite frame, tested against the frame's alpha mask. Drawing and hit
testing read the same rectangles from `OverlayLayout`; if they came from two places, a click
would eventually land in the wrong application and nothing on screen would say why.

## Sprites

The figure ships as drawn vector shapes, not as image files. A sprite folder replaces them
without a code change:

```
~/Library/Application Support/companion/sprites/
  idle/frame-000.png
  thinking/frame-000.png … frame-011.png
  sleeping.png
```

States without a folder keep the drawn placeholder, so a partial set works.

## Tests

`swift test` covers the state machine, the alpha hit test, the layout, the wire types against
the fixtures and the schema files, the session display and the quick-start settings, the
wakeword across its C ABI, and it renders the panels to PNG files for review. Four scripts in
the repository root exercise what a unit test cannot: `tests/mac/ui-smoke.sh` starts the
window and checks that the frontmost application never changes, `tests/mac/e2e-daemon.sh`
runs the shell against a real daemon on a throwaway configuration directory,
`tests/mac/ruhelast.sh` measures idle CPU and memory, and `tests/mac/wakeword-ffi.sh` runs the
wakeword path from the Rust library up into the Swift tests, against recorded speech when the
fixtures of `tests/wakeword` are there.

No test opens a microphone. Everything that touches audio hardware sits behind
`AudioCapturing`, `SpeechPlaying` and `MicrophoneAuthorizing`, and the tests hand in fakes.
