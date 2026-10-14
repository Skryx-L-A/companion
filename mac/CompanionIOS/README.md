# companion-ios

Der Companion auf dem iPhone: die Kopplung, die Sessionliste über alle gekoppelten Maschinen,
das Gespräch mit dem Companion in Schrift und in Sprache. Was die App anzeigt und entscheidet,
liegt nicht hier, sondern im Swift-Paket eine Ebene höher – `CompanionProtocol` für das
Protokoll und die Wege dorthin, `CompanionMobile` für die Modelle und den Sprach-Zug,
`CompanionFigure` für die Figur. Hier stehen nur die Ansichten und das, was ohne iOS nicht
geht: die Kamera für den QR-Code, das Mikrofon, der Lautsprecher und der Lebenszyklus der App.

## Warum ein eigenes Xcode-Projekt

SwiftPM baut Bibliotheken und Kommandozeilenprogramme, aber kein App-Bündel. Ohne Bündel gibt
es keine `Info.plist`, ohne `Info.plist` keine `NSCameraUsageDescription`, und ohne die beendet
iOS die App beim ersten Griff zur Kamera, statt zu fragen. Dazu kommt, dass ein Ziel im Paket
für iOS auch die Ziele der Mac-Shell für iOS bauen müsste, und die sind AppKit.

`project.yml` ist die Quelle. Das Projekt selbst wird daraus mit `xcodegen generate` erzeugt
und ist nicht im Repo – `.gitignore` schließt `*.xcodeproj/` aus, und daran wird hier nichts
geändert: eine erzeugte Datei im Repo läuft der Quelle davon und bringt Konflikte mit, die
niemand sinnvoll auflösen kann. Neu erzeugt wird nach jeder Änderung an `project.yml`; neue
Dateien unter `Sources/` werden ohne Zutun mitgenommen.

## Bauen und prüfen

```bash
cd app/mac/CompanionIOS
xcodegen generate
xcodebuild -project companion-ios.xcodeproj -scheme companion-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project companion-ios.xcodeproj -scheme companion-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`xcodegen` kommt aus Homebrew (`brew install xcodegen`).

Auf dieser Maschine ist nur die Simulator-Laufzeit iOS 27 installiert, und die zugehörige SDK
liegt im Xcode-Beta. Beide Befehle brauchen deshalb bis auf Weiteres ein vorangestelltes
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

Die Modelle prüft das Paket selbst, auf dem Mac und ohne Simulator:

```bash
cd app/mac && swift test
```

Der volle Weg gegen einen echten Daemon – Kopplung öffnen, Code über TLS einlösen, als
gekoppeltes Gerät verbinden – läuft über `tests/mac/ios-pairing-e2e.sh`, ein Skript im
privaten Teil des Repos; im öffentlichen Klon fehlt es, und der Weg bleibt ungeprüft.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `Sources/CompanionIOSApp.swift` | Einstieg, Registerleiste, Vordergrund-Wechsel |
| `Sources/Pairing/` | die drei Kopplungswege und die Kamera |
| `Sources/Sessions/` | Liste und Detailansicht einer Session |
| `Sources/Chat/` | das Gespräch mit dem Companion |
| `Sources/Machines/` | gekoppelte Maschinen, Heimat, Kopplung löschen |
| `Sources/Voice/` | Mikrofon und Lautsprecher über `AVAudioEngine`, Sprechtaste, Erklärbildschirm |
| `Sources/Companion/` | die Figur, gezeichnet aus `CompanionFigure` |
| `UITests/` | der eine Weg, den kein Paket-Test erreicht: von der Kopplung in die App |

## Sprache

Push-to-Talk: Taste halten, sprechen, loslassen. Aufgenommen wird über `AVAudioEngine`, weil
die dateibasierten Recorder nicht streamen können, und geschickt wird Opus, sobald das Gerät
den Systemcodec hat (`AVAudioConverter` mit `kAudioFormatOpus` – nichts davon liegt bei).
Hat es ihn nicht, handelt die App PCM16 aus, statt so zu tun; welches Format eine Verbindung
benutzt, entscheidet der Handschlag mit dem Daemon (`DESIGN.md` § Mobil, Voice am Handy).

Halbduplex: Während die Antwort spricht, ist die Sprechtaste aus. Barge-in braucht
Echokompensation und kommt erst, wenn die Strecke steht. Der Abbrechen-Knopf hält die
Wiedergabe an; dem Daemon das Sprechen abzustellen kennt das Protokoll noch nicht, die
restlichen Stücke kommen also an und werden weggeworfen.

Der Erklärbildschirm vor dem Mikrofon-Systemdialog ist derselbe Ablauf wie beim QR-Scan: erst
sagt die App, wann das Mikrofon läuft und wohin die Aufnahme geht, und nur ein bewusster Tipp
öffnet den Systemdialog. iOS zeigt ihn genau einmal.

Was nur auf einem Gerät zu prüfen ist – Mikrofon, Lautsprecher, Bluetooth-Route,
Unterbrechung durch einen Anruf – ist ungeprüft, solange kein Developer-Konto da ist. Der
Simulator sagt darüber nichts Belastbares.

## Signieren

Es gibt noch kein Apple-Developer-Konto (`DESIGN.md` § Mobil, Push und Store), deshalb ist das
Signieren im Projekt abgeschaltet und die App läuft nur im Simulator. Für einen Gerätelauf
werden `CODE_SIGNING_ALLOWED` und `CODE_SIGNING_REQUIRED` wieder eingeschaltet und ein Team
eingetragen.
