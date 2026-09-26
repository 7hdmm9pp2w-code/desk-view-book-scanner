# Desk View Book Scanner — Konzept

Stand: 26.09.2026. Beschlossen vor der ersten Zeile Code.

## Was das Tool ist

Ein Fenster-Fotograf mit Nachbearbeitung, kein Kamera-Tool. Die Schreibtischansicht
(Desk View, `/System/Library/CoreServices/Applications/Desk View.app`) macht die
eigentliche Arbeit: Blick von oben, Entzerrung, Beleuchtung. Wir holen per
ScreenCaptureKit ab, was ihr Fenster zeigt, und machen daraus Seiten, OCR-Text und ein
durchsuchbares PDF.

Zielplattform ist das **aktuelle macOS** (derzeit 27) auf Apple Silicon. Keine
Rückwärtskompatibilität; `platforms: [.macOS(.v26)]` oder höher, sobald das SDK es hergibt.

## Die eine Einschränkung, die alles prägt

Wir bekommen nie mehr Pixel als das Desk-View-Fenster auf dem Bildschirm hat. Auf einem
14"-MacBook sind das im Vollbild rund 3000 × 1900 Pixel: gut für eine Einzelseite, knapp
für eine Doppelseite, zu wenig für ein kleines Fenster in der Ecke. Deshalb startet das
Tool Desk View **selbst** über `AVCaptureDeskViewApplication` (AVFoundation, seit macOS 13)
mit großem `mainWindowFrame` und `requiresSetUpModeCompletion = true`. Bedient wird über
Menüleiste und Hotkey; das Desk-View-Fenster darf den Bildschirm füllen.

## Architektur

```
DeskViewQuelle ──► Erfassung ──► Verarbeitung ──► Session ──► Export
 (finden,          (Screenshot,    (Zuschnitt,      (Seiten,     (PDF mit
  starten,          Auto-Auslöser)  Teilen, OCR)     Reihenfolge)  Textebene)
  Rechte prüfen)
```

### 1. DeskViewQuelle

- Findet das Fenster über `SCShareableContent`, gematcht an der **App** (Bundle von
  Desk View.app), nicht am Fenstertitel; der ist lokalisiert („Schreibtischansicht").
- Fehlt es: Start per `AVCaptureDeskViewApplication.present(launchConfiguration:)`.
- Rechte: `CGPreflightScreenCaptureAccess()` vorab; die Fehlermeldung öffnet
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
- Warnt, wenn das Fenster schmaler als etwa 1600 px ist.

### 2. Erfassung

- Einzelbild: `SCScreenshotManager.captureImage` mit `SCContentFilter` auf genau dieses
  Fenster, `width/height` = Fenstergröße in Punkten × Backing-Faktor (sonst liefert die
  API Punkte statt Pixel).
- Auto-Auslöser (Standard: **aus**): eigener `SCStream` mit 2–4 fps in niedriger
  Auflösung (~320 px breit). Daraus nur eine Kennzahl: mittlere Differenz zum Vorbild.
  Zustandsautomat: *Ruhe → Bewegung (Umblättern) → ruhig seit 1,5 s → unterscheidet sich
  deutlich von der zuletzt erfassten Seite → auslösen*. Das Vollbild kommt dann wieder
  über den Screenshot-Pfad, nicht aus dem Stream.

### 3. Verarbeitung (Actor, abseits des Main-Threads; jede Stufe abschaltbar)

- **Zuschnitt**: `VNDetectDocumentSegmentationRequest` → Viereck → `CIPerspectiveCorrection`.
  Desk View schaut schon von oben; die Stufe dient vor allem dem Zuschnitt aufs Buch.
  Ohne Treffer bleibt das Bild, wie es ist.
- **Teilen**: Spaltenprofil der Helligkeit, im mittleren Drittel das dunkelste Tal (der
  Falz ist schattig). Kein klares Tal → feste Mittellinie. Pro Session wählbar:
  automatisch / Mitte / nicht teilen.
- **OCR**: `VNRecognizeTextRequest`, `.accurate`, Sprachen `de-DE`, `en-US`,
  Sprachkorrektur an. Beobachtungen **mit Bounding Boxes** behalten, die braucht das PDF.

### 4. Session

- Ein Ordner auf der Platte, nicht nur Objekte im Speicher. Standard
  `~/Documents/Buchscans/<Datum-Uhrzeit>/`, beim ersten Start wählbar, später in den
  Einstellungen änderbar.
- Jede Aufnahme sofort als HEIC gespeichert; `session.json` hält Reihenfolge (Array von
  IDs), Einstellungen und OCR-Stand. 300 Seiten passen so nicht in den RAM, müssen sie
  auch nicht; ein Absturz bei Seite 280 kostet nichts.
- Löschen verschiebt in einen `Papierkorb`-Unterordner der Session. Nichts wird
  gelöscht.

### 5. Export

- CoreGraphics direkt, nicht PDFKit: pro Seite eine PDF-Seite in Bildgröße, Bild
  gezeichnet, dann per CoreText jede OCR-Zeile mit Textmodus `.invisible` in ihre
  Bounding Box, Schriftgröße so skaliert, dass die Zeile die Boxbreite füllt. Vorschau
  markiert und findet den Text dann genau dort, wo er im Bild steht.
- Dateiname `Buchscan 2026-09-26 14-03.pdf`, optional mit Session-Titel.
- **Markdown als Option.** Pandoc liest kein PDF (geprüft mit pandoc 3.11: kein
  PDF-Eingabeformat), darum läuft der Weg nicht über das fertige PDF, sondern über die
  OCR-Ergebnisse, die wir ohnehin haben. Aus den Beobachtungen bauen wir eine HTML-Datei
  mit Struktur: Absätze aus Zeilenabständen und Einzügen, Überschriften aus Zeilen mit
  deutlich größerer Boxhöhe, Seitenwechsel als Kommentar `<!-- Seite 12 -->`. Dieses HTML
  gibt es zwei Wege:
  - Pandoc vorhanden (`/opt/homebrew/bin/pandoc`, `/usr/local/bin/pandoc` oder Pfad in
    den Einstellungen): `pandoc -f html -t gfm --wrap=none`, und auf Wunsch gleich
    weiter nach `.docx` oder `.epub`, weil Pandoc das mitbringt.
  - Kein Pandoc: eigener, einfacher HTML→Markdown-Schreiber im Kit, damit die Option
    nie tot ist. Der Hinweis in der Oberfläche sagt dann, dass Pandoc bessere
    Ergebnisse liefert und wie man es installiert.
  Silbentrennung am Zeilenende (`Wör-` + `ter`) wird vor dem Export zusammengezogen,
  wenn das Ergebnis im Wörterbuch (`NSSpellChecker`) steht; sonst bleibt der Bindestrich.

### Oberfläche

- `MenuBarExtra` (Fensterstil): Status (gefunden / nicht gefunden / Rechte fehlen),
  großer Button „Seite erfassen", Schalter Auto-Auslöser, Seitenzähler, „Session öffnen".
- Session-Fenster: Thumbnail-Raster mit Drag-and-drop, Löschen per Taste, Detailansicht
  mit erkanntem Text daneben.
- Hinweise kontextabhängig statt Dauertext: „Seiten glatt halten, Hände raus" nur bei
  laufendem Auto-Auslöser ohne Ruhe; „Fenster größer ziehen" nur bei kleinem Fenster.
- Schrift ≥ 13 pt, hoher Kontrast, `accessibilityContrast` beachten.
- Sprachen: Deutsch und Englisch über String-Kataloge von Anfang an.
- Hotkey ⌥⌘S über Carbon `RegisterEventHotKey` — die einzige Variante ohne
  Bedienungshilfen-Freigabe.

## Projektform

Swift Package mit zwei Targets:

- `BookScannerKit`: Verarbeitung, Session, Export. Ohne UI, testbar.
- `DeskViewBookScanner`: App (SwiftUI, MenuBarExtra).

Dazu `build_app.sh`, das ein `.app`-Bundle mit `Info.plist` (`LSUIElement = true`,
`NSScreenCaptureUsageDescription`) baut und ad hoc signiert. Grund: die
Bildschirmaufnahme-Freigabe hängt an einer Bundle-ID; ein loses `swift build`-Binary erbt
sie vom Terminal und verliert sie beim Neubau. Kein Xcode-Projekt: bringt hier nichts,
was das Skript nicht kann, und ist schlechter im Git.

Tests gegen den Kit mit synthetischen Bildern: gerenderte Doppelseite mit bekanntem Falz
muss an der richtigen Stelle geteilt werden; gerendertes Textbild muss nach OCR und
PDF-Export wieder durchsuchbar sein. Screenshot und Desk View bleiben Handprobe.

## Reihenfolge der Umsetzung

1. Quelle + Screenshot + Session-Fenster: früh am echten Buch sehen, was die
   Auflösung hergibt.
2. Export mit OCR: PDF zuerst, Markdown (mit und ohne Pandoc) direkt danach, weil
   beide von denselben OCR-Beobachtungen leben.
3. Teilen und Zuschnitt.
4. Auto-Auslöser.

## Bekannte Risiken

1. Desk View blendet Overlays ein (Einrichtungstrapez, Hinweise). Beim Start hilft
   `requiresSetUpModeCompletion`, nicht aber bei späterer Neu-Einrichtung. Fenstergröße
   und Bildinhalt überwachen; bei Verdacht Warnung statt Aufnahme.
2. Fensterrand: `SCContentFilter` nimmt nur den Inhalt, aber abgerundete Ecken sind
   transparent. Der Zuschnitt schneidet das weg; ohne Zuschnitt fester Rand abziehen.
3. Falz-Erkennung bei hellen Büchern oder Spiralbindung ist unsicher, daher wählbar.
4. Vision-OCR bei Fraktur oder Fußnoten ist eine Grenze des Frameworks.
