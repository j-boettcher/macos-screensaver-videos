# BC Video – Video-Bildschirmschoner für macOS

Ein Bildschirmschoner (`.saver`) für macOS 14 und neuer (getestet unter macOS 27), der eigene Videos abspielt.

## Funktionen

- Einzelne Videodateien **und** ganze Ordner (optional mit Unterordnern) als Quelle
- Stream- bzw. Download-URLs (`https://…/video.mp4`, HLS `.m3u8`)
- **Eigene Videos pro Bildschirm:** Unter „Quellen für“ lässt sich jedem angeschlossenen Bildschirm eine eigene Liste zuordnen. Bildschirme ohne eigene Liste (und die Vorschau) nutzen die Standardliste. Die Zuordnung erkennt Bildschirme an ihrer Display-UUID und bleibt beim Trennen und Wiederverbinden erhalten.
- **Zwischenspeicher für URL-Videos:** MP4/MOV-URLs werden im Hintergrund heruntergeladen (beim Klick auf „OK“ und beim Start der Wiedergabe) und danach lokal abgespielt, auch offline. Bis der Download fertig ist, wird gestreamt. HLS-Streams (`.m3u8`) laufen immer live. In den Optionen zeigt jede URL ihren Status (offline / lädt … % / Stream / Fehler). Belegter Speicher und „Leeren“ stehen unter dem Schalter. Beim Speichern werden Videos entfernt, die in keiner Liste mehr stehen.
- Zufällige oder alphabetische Reihenfolge, nahtloser Übergang zum nächsten Video
- Ein einzelnes Video wird lückenlos wiederholt
- Skalierung: Füllen (zuschneiden), Einpassen, Strecken
- Ton an/aus und Lautstärke (in der Vorschau ist der Ton immer aus)
- Defekte oder nicht unterstützte Dateien werden übersprungen
- Universal Binary (Apple Silicon + Intel)

Unterstützt werden alle Formate, die AVFoundation abspielen kann (MP4, MOV, M4V mit H.264/HEVC/ProRes …). MKV/WebM gehören nicht dazu. **AV1** wird nur auf Macs mit AV1-Hardware-Decoder (ab M3) abgespielt. Auf älteren Macs erscheint stattdessen ein Hinweis.

## Bauen & installieren

Benötigt werden nur die Xcode Command Line Tools.

```bash
./build.sh install
```

`./build.sh` ohne Argument baut nur nach `build/BC Video.saver`. Mit `install` wird das Bundle nach `~/Library/Screen Savers/` kopiert. Außerdem werden laufende `legacyScreenSaver`-Prozesse beendet, damit macOS die neue Version lädt.

Danach: **Systemeinstellungen → Bildschirmschoner → „BC Video“** auswählen und über **Optionen…** Videos oder Ordner hinzufügen.

## Aufbau

| Datei | Inhalt |
|---|---|
| `Sources/VideoSaverView.swift` | `ScreenSaverView`-Unterklasse, Wiedergabe mit `AVQueuePlayer`/`AVPlayerLooper` |
| `Sources/ConfigureSheetController.swift` | Optionen-Fenster (in Code aufgebaut, kein XIB) |
| `Sources/Preferences.swift` | Einstellungen (`ScreenSaverDefaults`), Quellen und Ordner-Scan |
| `Resources/Info.plist` | Bundle-Metadaten, `NSPrincipalClass = VideoSaverView` |

## Hinweise zu macOS 14+

- Bildschirmschoner laufen in der Sandbox von `legacyScreenSaver`. Ausgewählte Dateien und Ordner werden als Security-Scoped-Bookmark gespeichert. Die Einstellungen liegen deshalb im Container
  `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/`.
- macOS ruft `stopAnimation()` nicht mehr zuverlässig auf. Der Bildschirmschoner hört deshalb auf `com.apple.screensaver.willstop` und gibt dann die Vollbild-Wiedergabe frei. Den Prozess beendet er bewusst nicht selbst: Sonst kann auch die Vorschau in den Systemeinstellungen sterben, und „Optionen…“ bleibt gesperrt.
- Beim erneuten Öffnen der Systemeinstellungen ruft macOS für die Vorschau oft kein `startAnimation()` auf. Die Vorschau startet deshalb selbst, sobald sie angezeigt wird, und gibt ihre Ressourcen frei, wenn sie wieder verschwindet.
- Der Zwischenspeicher liegt im Container unter `Library/Caches/com.bc.VideoSaver/VideoCache/` (Dateiname = SHA-256 der URL). macOS darf diesen Ordner bei Platzmangel leeren; fehlende Videos werden dann automatisch neu geladen.
- Das Vorschaubild in der Bildschirmschoner-Liste (`Resources/thumbnail*.png`) erzeugt `swift Scripts/make-thumbnail.swift`.
- Das Optionen-Fenster wird wiederverwendet und öffnet keine weiteren Sheets darüber. Die URL wird direkt im Fenster eingegeben.
- Für Ordner unter *Schreibtisch*, *Dokumente* oder *Downloads* kann macOS einmalig nach einer Zugriffserlaubnis fragen. Am problemlosesten ist z. B. `~/Movies`.
- Debug-Ausgaben: In der *Konsole*-App nach `BCVideoSaver` filtern.

## Deinstallieren

```bash
rm -rf ~/Library/Screen\ Savers/BC\ Video.saver
```
