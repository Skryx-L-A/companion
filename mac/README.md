# companion-mac

The macOS shell: a figure in a screen corner, a chat panel, a session list, and a menu bar
item. The daemon does the work; this package only shows it and takes input.

## Build and run

The package builds from the command line; Xcode is not required.

```sh
cd app/mac
swift build                      # debug binary
swift test                       # unit tests
./Scripts/make-app-bundle.sh     # companion.app with Info.plist and LSUIElement
```

The binary runs without a bundle. `--demo` fills the panels with sample content and skips the
daemon, which is the quickest way to see the overlay:

```sh
.build/debug/companion-mac --demo
```

`--help` lists the rest. `--defaults-suite <name>` writes settings into a throwaway domain;
the test scripts use it so a run never touches the settings of an installed copy.

## Structure

| Target | Contents |
|---|---|
| `CompanionProtocol` | socket client and wire envelope, placeholder until the schema is final |
| `CompanionUI` | overlay panel, figure, both panels, menu bar item, settings |
| `CompanionMac` | the executable and its command line |

Inside `CompanionUI`, `Overlay` holds the window and the layout, `Figure` the sprites and the
state machine, `Panels` the two SwiftUI panels, `Models` the session and settings types.

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

`swift test` covers the state machine, the alpha hit test, the layout, the payload decoding
and the protocol module, and renders the panels to PNG files for review. The window itself is
exercised by `tests/mac/ui-smoke.sh` in the repository root, which also checks that the
frontmost application never changes; `tests/mac/ruhelast.sh` measures idle CPU and memory.
