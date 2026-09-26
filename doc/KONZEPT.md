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

## Quellen (ergänzt 26.09.2026, nach der Handprobe)

Desk View reicht für Umschläge, Überschriften und Großdruck, nicht für Fließtext: Der
Feed ist Video, grob 1080p aus dem Rand eines Ultraweitwinkels, das Fenster zeigt ihn
nur hochskaliert. Taschenbuchtext kam mit rund 8 px Zeilenhöhe an; Vision braucht etwa 20.
Ein iPhone-Scan aus Notizen desselben Buches (1713 × 2710 px, Zeilen rund 60 px) ging
fehlerfrei durch dieselbe Erkennung. Daraus folgt: Die Seite kommt aus dem iPhone, das
Tool macht Session, OCR, PDF und Markdown. Drei Quellen, alle liefern nur ein `CGImage`:

1. **Import** (gebaut): PDFs und Bilder aus Notizen, vFlat oder der Fotos-App. PDF-Seiten
   werden in der Auflösung ihres eingebetteten Bildes gerendert (aus dem größten
   Bild-XObject der Seite), EXIF-Ausrichtung wird angewandt. Menü Ablage ⇧⌘I, auch für
   den leeren Zustand des Fensters.
   - **Direkt vom iPhone** (gebaut): Apples Dokumentenscanner über Continuity Camera,
     auf dem SwiftUI-Weg: `ImportFromDevicesCommands()` in `.commands` bringt „Vom
     iPhone oder iPad importieren" ins Menü Ablage, `importsItemProviders` an der
     Fensteransicht nimmt PDF (Dokumentenscan) oder Foto entgegen; die Provider werden
     als Temp-Dateien geschrieben und laufen durch denselben Import. Der AppKit-Weg
     (`NSMenuItem.importFromDeviceIdentifier` mit `validRequestor` im Delegate oder
     einem First-Responder-Knopf) wurde versucht und verworfen: AppKit fragte in der
     SwiftUI-App nie nach einem Empfänger, das Item blieb versteckt.
   - **Später, Hotkey für den Scan:** Das Projekt continuity-capture zeigt, dass sich
     das System-Item ohne sichtbares Menü füllen (`submenu.update()`) und auslösen lässt.
     Damit könnte ⇧⌘S den Scan starten, ohne ins Menü zu gehen.
2. **Desk View** (gebaut): bleibt für Großdruck und als Schnellweg.
3. **Kamera über AVFoundation** (offen): das iPhone als Continuity-Kamera, Foto in voller
   Auflösung per `AVCapturePhotoOutput` mit `maxPhotoDimensions`, vom Mac ausgelöst, mit
   Vorschau im Fenster. Lohnt erst, wenn Import und Bedienung am Buch sitzen; dieselbe
   Quelle trüge später eine 4K-Kamera am Arm.

Fertige Apps, die den iPhone-Teil abdecken: Apples „Dokumente scannen" (Notizen,
Vorschau, Finder), Prizmo 5 für Mac (Continuity Camera, OCR, Glättung), vFlat auf dem
iPhone (Auto-Auslöser, Wölbungskorrektur). Keine davon macht Session-Ordner mit
OCR-JSON und Markdown, DOCX, EPUB mit Absatzstruktur; das bleibt der Kern hier.

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
- **Ordnername aus dem Titel** (beschlossen 26.09.2026, nach Schritt 1): Die erste
  Aufnahme zeigt in der Regel den Umschlag mit Titel und Autor, bei Zeitschriften
  Heftnummer und Jahr. Sobald die OCR aus Schritt 2 da ist, schlägt das Tool aus den
  Beobachtungen der ersten Seite einen Titel vor: die Zeilen mit der größten Boxhöhe,
  sortiert von oben nach unten, höchstens drei. Der Vorschlag erscheint im
  Session-Fenster als vorausgefülltes Titelfeld, nicht als Dialog; der Ordner wird erst
  umbenannt, wenn der Titel bestätigt oder geändert wird. Der Zeitstempel bleibt vorn
  (`2026-09-26 14-03 Der Zauberberg`), damit der Finder chronologisch sortiert. Das
  Umbenennen selbst (`setTitleAndRenameDirectory`) ist seit Schritt 1 im Kit.

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
  - Kein Pandoc: eigener, einfacher Markdown-Schreiber im Kit, damit die Option
    nie tot ist. Der Hinweis in der Oberfläche sagt dann, dass Pandoc bessere
    Ergebnisse liefert und wie man es installiert.
  - **Pandoc mitgeliefert** (beschlossen 26.09.2026): Das Build-Skript lädt eine
    festgenagelte Version mit geprüfter SHA-256 und legt sie als Hilfsprogramm unter
    `Contents/Helpers/pandoc` ab, Suchreihenfolge: Bundle, Einstellungspfad, Homebrew.
    Kein SwiftPM-Abhängigkeit, das kennt keine Laufzeit-Binaries. Lizenz: Pandoc ist
    GPL-2.0-or-later; als getrennt aufgerufener Prozess ist es Beigabe, kein
    abgeleitetes Werk, die App bleibt EUPL. Bedingungen: GPL-Text und Copyright im
    Bundle, Quell-Tarball der gebündelten Version zum Release anbieten. Nicht für den
    App Store geeignet, dessen Bedingungen vertragen sich nicht mit der GPL.
  Silbentrennung am Zeilenende (`Wör-` + `ter`) wird vor dem Export zusammengezogen,
  wenn das Ergebnis im Wörterbuch (`NSSpellChecker`) steht; sonst bleibt der Bindestrich.

### Oberfläche

- **Normale Fenster-App mit Dock-Symbol**, kein Menüleisten-Item (geändert 26.09.2026
  nach Schritt 1). Das ursprüngliche Argument für die Menüleiste war, dass Desk View
  den Bildschirm füllen soll und das Tool nicht im Weg sein darf. Mit zwei Bildschirmen
  liegt das Session-Fenster einfach auf dem anderen Display, und der globale Hotkey
  funktioniert in einer normalen App genauso. Eine normale App ist per Spotlight
  startbar, per ⌘Q beendbar und im Dock sichtbar; ein unsichtbares Status-Item kostet
  nur Fehlersuche.
- **Später als Option: Menüleisten-Modus** für den Betrieb mit einem Bildschirm, bei
  dem Desk View das ganze Display füllt und das Hauptfenster stört. Umschaltbar in den
  Einstellungen: dann zusätzlich ein Status-Item mit Status, „Seite erfassen" und
  Seitenzähler; das Hauptfenster bleibt über das Item erreichbar. Kein eigener
  Schritt, kommt nach Schritt 4, wenn die Bedienung am Buch klar ist.
- Hauptfenster (Stand 26.09.2026, nach drei Quellen gegliedert): **Quellenleiste** oben
  mit Segmentwahl „iPhone · Dateien · Desk View", daneben der Zustand der gewählten
  Quelle (nur Desk View braucht Erklärung: gefunden / nicht gefunden / Rechte fehlen,
  Pixelmaße), in der Mitte Fortschritt (Import, Texterkennung, Export, Warten aufs
  iPhone) oder Titelvorschlag, rechts Seitenzähler und der eine Hauptknopf der Quelle
  („Mit iPhone scannen" ⇧⌘S, „Bilder oder PDF importieren…" ⇧⌘I, „Seite erfassen"
  ⌥⌘S). Darunter Thumbnail-Raster mit Drag-and-drop, rechts Detailansicht mit
  erkanntem Text. Toolbar nur Seitenbefehle (teilen, drehen, löschen), Export, Finder.
  Titelfeld in der Toolbar benennt den Session-Ordner um. Der Leerzustand zeigt die
  gewählte Quelle mit ihrem Knopf.
- Menüs: „Ablage" mit Sessions und Export; „Aufnahme" in drei Abschnitten iPhone /
  Dateien / Desk View; „Seite" mit Teilen ⌘T, Drehen ⌘L/⌘R, Löschen ⌘⌫, Zurückholen
  ⇧⌘Z und den Session-Einstellungen Doppelseiten teilen und Aufrecht drehen.
- **Seitenleiste** (26.09.2026, macOS-Stil wie Notizen und Bücher, kein eigenes
  Fenster): alle Sessions unter dem Sessions-Ordner, je Zeile Vorschaubild der ersten
  Seite, Titel oder Datum, Seitenzahl, Größe auf der Platte, Marken für vorhandene
  Exporte, Kopfzeile mit Gesamtgröße. Auswahl wechselt die Session. Kontextmenü:
  Öffnen, Im Finder zeigen, Papierkorb leeren, Archivieren, Session in den
  Papierkorb legen. Ein- und ausklappbar mit dem Toolbar-Knopf.
- **Platz sparen**, drei Stufen: Papierkorb der Session leeren (Seiten in den
  macOS-Papierkorb, nichts endgültig). Archivieren: Bilder in den macOS-Papierkorb,
  OCR-Text und Exporte bleiben, Markdown/Word/EPUB gehen weiter, PDF und
  Bildbefehle sind dann aus. Beim Speichern längste Kante 3000 Pixel und
  HEIC-Qualität 0,8; iPhone-Scans (2710 px) bleiben unverändert, Importe aus
  600-dpi-PDFs schrumpfen. Das Löschen einer ganzen Session geht ebenfalls in den
  macOS-Papierkorb.
- Hinweise kontextabhängig statt Dauertext: „Seiten glatt halten, Hände raus" nur bei
  laufendem Auto-Auslöser ohne Ruhe; „Fenster größer ziehen" nur bei kleinem Fenster.
- Schrift ≥ 13 pt, hoher Kontrast, `accessibilityContrast` beachten.
- Sprachen: Deutsch und Englisch über String-Kataloge von Anfang an.
- Hotkey ⌥⌘S über Carbon `RegisterEventHotKey` — die einzige Variante ohne
  Bedienungshilfen-Freigabe; er greift auch, wenn Desk View vorn liegt.

## Projektform

Swift Package mit zwei Targets:

- `BookScannerKit`: Verarbeitung, Session, Export. Ohne UI, testbar.
- `DeskViewBookScanner`: App (SwiftUI, ein Hauptfenster).

Dazu `build_app.sh`, das ein `.app`-Bundle mit `Info.plist`
(`NSScreenCaptureUsageDescription`) baut und signiert, mit der Apple-Development-Identität
aus dem Schlüsselbund, sonst ad hoc. Grund: die Bildschirmaufnahme-Freigabe hängt an
Bundle-ID und Signatur; ein loses `swift build`-Binary erbt sie vom Terminal und verliert
sie beim Neubau, ein ad hoc signiertes Bundle wechselt mit jedem Build den Code-Hash. Kein Xcode-Projekt: bringt hier nichts,
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

## Stand der Umsetzung

Was gebaut ist, was dabei vom Konzept abwich und warum, steht mit Datum in
[UMSETZUNG.md](UMSETZUNG.md). Kurz: Schritt 1 bis 3 sind umgesetzt (Zuschnitt für
Desk View ausgenommen), die Quelle für Buchtext ist das iPhone, dazu Seitenleiste
mit Session-Verwaltung. Offen sind Auto-Auslöser, Kamera über AVFoundation und der
Menüleisten-Modus.

## Bekannte Risiken

1. Desk View blendet Overlays ein (Einrichtungstrapez, Hinweise). Beim Start hilft
   `requiresSetUpModeCompletion`, nicht aber bei späterer Neu-Einrichtung. Fenstergröße
   und Bildinhalt überwachen; bei Verdacht Warnung statt Aufnahme.
2. Fensterrand: `SCContentFilter` nimmt nur den Inhalt, aber abgerundete Ecken sind
   transparent. Der Zuschnitt schneidet das weg; ohne Zuschnitt fester Rand abziehen.
3. Falz-Erkennung bei hellen Büchern oder Spiralbindung ist unsicher, daher wählbar.
4. Vision-OCR bei Fraktur oder Fußnoten ist eine Grenze des Frameworks.
