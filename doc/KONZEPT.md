# Desk View Book Scanner — Konzept

Stand: 27.09.2026 (Version 0.1.0). Erste Fassung vom 26.09.2026, beschlossen vor der
ersten Zeile Code; seither an das angepasst, was der Bau gezeigt hat. Was wann gebaut
wurde, was vom Plan abwich und warum, steht mit Datum in [UMSETZUNG.md](UMSETZUNG.md).
Dieses Dokument ist der Plan, jene Datei die Chronik.

## Was das Tool ist

Ein Mac-Programm, das aus Buchseiten eine Session macht: Seiten in Reihenfolge, OCR-Text,
ein durchsuchbares PDF und Markdown, Word oder EPUB mit Absatzstruktur. Die Bilder kommen
aus drei Quellen: dem Dokumentenscanner des iPhones, aus Dateien oder von einer Kamera
über dem Buch, Desk View eingeschlossen.

Ursprünglich war es ein Fenster-Fotograf: Desk View entzerrt, das Tool holt per
ScreenCaptureKit ab, was das Desk-View-Fenster zeigt. Das ist aufgegeben (26.09.2026,
siehe Quellen); der Name ist geblieben.

Zielplattform ist das **aktuelle macOS** (derzeit 27) auf Apple Silicon. Keine
Rückwärtskompatibilität; `platforms: [.macOS(.v26)]`, weil das Manifest noch kein `.v27`
kennt.

## Quellen und Auflösung

Die Handprobe am 26.09.2026 hat die Richtung bestimmt: Desk View reicht für Umschläge,
Überschriften und Großdruck, nicht für Fließtext. Die Desk-View-Kamera (Mac wie iPhone)
bietet genau ein Videoformat, 1920 × 1440, aus dem Rand eines Ultraweitwinkels; das
Fenster skaliert nur hoch. Taschenbuchtext kam mit rund 8 px Zeilenhöhe an, Vision
braucht etwa 20. Ein iPhone-Scan desselben Buches (1713 × 2710 px, Zeilen rund 60 px)
ging fehlerfrei durch dieselbe Erkennung.

Daraus folgt: Für Fließtext kommt die Seite aus dem iPhone oder einer 4K-Kamera, das
Tool macht Session, OCR, PDF und Markdown. Drei Quellen, alle liefern nur ein `CGImage`,
in der Oberfläche als Segmentwahl „iPhone · Dateien · Kamera":

1. **iPhone** (gebaut): Apples Dokumentenscanner über Continuity Camera.
   `ImportFromDevicesCommands()` bringt „Vom iPhone oder iPad importieren" ins Menü
   Ablage, `importsItemProviders` an der Fensteransicht nimmt PDF oder Foto entgegen.
   ⇧⌘S löst den Scan ohne Menü aus, nach dem Muster von continuity-capture: ein
   verstecktes `NSTextView` wird First Responder, das System-Untermenü wird mit
   `update()` gefüllt und der Eintrag ausgelöst. Der AppKit-Weg über `validRequestor`
   ist verworfen, AppKit fragte in der SwiftUI-App nie nach einem Empfänger.
2. **Dateien** (gebaut): PDFs und Bilder aus Notizen, vFlat oder der Fotos-App, ⇧⌘I.
   PDF-Seiten werden in der Auflösung ihres größten eingebetteten Bildes gerendert,
   EXIF-Ausrichtung wird angewandt, Dateien werden natürlich nach Namen sortiert.
3. **Kamera** (gebaut, ersetzt den Screenshot des Desk-View-Fensters): jede Kamera, die
   AVFoundation sieht (Desk View, iPhone als Continuity-Kamera, extern, eingebaut), im
   größten Videoformat, Einzelbild aus dem Live-Feed. Desk View ist darin nur ein Gerät
   mit 1920 × 1440, eine 4K-Kamera über dem Buch liefert 3840 × 2160 und damit
   Fließtext. Foto in höherer Auflösung als das Video gibt es über AVFoundation von
   keinem der gemessenen Geräte, auch nicht vom iPhone. Hier sitzt der Auto-Auslöser.

ScreenCaptureKit, die Suche nach dem Desk-View-Fenster und der Start von Desk View über
`AVCaptureDeskViewApplication` sind entfernt. Damit entfällt auch die Freigabe für
Bildschirmaufnahme; gebraucht wird nur noch die Kamerafreigabe.

Fertige Apps, die den iPhone-Teil abdecken: Apples „Dokumente scannen" (Notizen,
Vorschau, Finder), Prizmo 5 für Mac (Continuity Camera, OCR, Glättung), vFlat auf dem
iPhone (Auto-Auslöser, Wölbungskorrektur). Keine davon macht Session-Ordner mit
OCR-JSON und Markdown, DOCX, EPUB mit Absatzstruktur; das bleibt der Kern hier.

## Architektur

```
Quelle ──────► Erfassung ─────► Verarbeitung ──► Session ─────────► Export
 (iPhone,       (Einzelbild,     (Drehen,         (Seiten,           (PDF mit Textebene,
  Dateien,       Auto-Auslöser,   Teilen, OCR)     Reihenfolge,       Markdown, Word,
  Kamera)        Leertaste)                        Seitenfolge)       EPUB)
```

### 1. Quelle Kamera

- `CameraSource` listet alle Kameras mit Art und größtem Format, die Auswahl steht in der
  Quellenleiste. Live-Vorschau im Detailbereich.
- Rechte: Kamerafreigabe beim ersten Start anfragen; Einstellungen zeigen den Stand und
  öffnen die Systemeinstellungen. `Info.plist` braucht `NSCameraUsageDescription` und
  `NSCameraUseContinuityCameraDeviceType`, sonst fehlt das iPhone in der Liste; die
  Hardened Runtime braucht das Entitlement `com.apple.security.device.camera`.

### 2. Erfassung

- Einzelbild: das nächste volle Bild aus dem Live-Feed. Auslöser ⌥⌘S global (Carbon
  `RegisterEventHotKey`, die einzige Variante ohne Bedienungshilfen-Freigabe; greift
  auch, wenn eine andere App vorn liegt) und die Leertaste im Seitenraster. Die
  Leertaste ist bewusst kein Menü-Kürzel, sonst schluckte sie auch das Titelfeld.
- **Auto-Auslöser** (Standard: **aus**, Schalter „Beim Umblättern auslösen" in der
  Quellenleiste), zwei getrennte, testbare Teile:
  - `MotionTrigger` meldet „nach Bewegung ruhig". Rund vier Bilder pro Sekunde als
    kleines Graubild aus Blockmitteln (einzelne Pixel rauschen auf Textseiten zu stark),
    Bewegung in 16 Kacheln je Zeile; zählt, was über das bewegteste Viertel hinausgeht.
    Umblättern bewegt mehr als ein Viertel der Kacheln, Hände, die das Buch halten,
    weniger. Dann 1,5 s Ruhe.
  - `PageTurnJudge` entscheidet, ob es eine neue Seite ist. Mit Text: genaue OCR ohne
    Sprachkorrektur (rund 100 ms, beim Einschalten vorgewärmt), Wörter fehlertolerant
    verglichen; ab 45 % gemeinsamer Wörter dieselbe Seite. Ohne Text: normierte
    320-px-Graubilder, bis ±4 px ausgerichtet, ab 40 % geänderter Kacheln neu.
    Verglichen wird mit den letzten drei erfassten Seiten, so löst Zurückblättern nicht
    aus. Bewegt sich während der Prüfung etwas, verfällt sie.
  - Die Wischbewegung über den Falz wird nicht ausgewertet: Bei vier Bildern pro Sekunde
    sieht man davon ein, zwei Bilder; der Vergleich der Seiteninhalte ist der härtere
    Beleg.

### 3. Verarbeitung (abseits des Main-Threads, vor dem Speichern, für alle Quellen)

- **Drehen**: Visions genaue Erkennung liest auch gedrehten Text und liefert das Viereck
  jeder Zeile; die Richtung der Oberkanten ergibt per gewichteter Abstimmung die nötige
  Vierteldrehung. Pro Session abschaltbar („Aufrecht drehen").
- **Teilen**: Ab Seitenverhältnis 1,15 gilt ein Bild als Doppelseite. Der Schnitt liegt in
  der textfreien Lücke zwischen linkem und rechtem Textblock, darin am Helligkeitstal,
  sonst in der Lückenmitte; ohne Zeilen das Tal zwischen 35 % und 65 % der Breite, sonst
  die Mitte. Kreuzt Text die Schnittlinie, wird nicht geteilt. Pro Session wählbar:
  automatisch / Mitte / nicht teilen.
- **Zuschnitt** (offen): `VNDetectDocumentSegmentationRequest` → Viereck →
  `CIPerspectiveCorrection`. iPhone-Scans kommen schon beschnitten, darum nachrangig;
  nützlich vor allem für Kamerabilder.
- **OCR**: Visions Swift-API `RecognizeTextRequest`, genau, Sprachen `de-DE` und `en-US`,
  Sprachkorrektur an. Beobachtungen **mit Bounding Boxes** behalten, die braucht das PDF.
  Text als `OCR/<Aufnahme>.json` neben dem Bild. Der erste Lauf im Prozess lädt das
  Modell (bis 25 s), danach unter einer Sekunde pro Seite.

### 4. Session

- Ein Ordner auf der Platte, nicht nur Objekte im Speicher. Standard
  `~/Documents/Buchscans/<Datum-Uhrzeit>/`, in den Einstellungen änderbar.
- Jede Aufnahme sofort als HEIC gespeichert, längste Kante höchstens 3000 px, Qualität
  0,8; `session.json` hält Reihenfolge (Array von IDs), Einstellungen und OCR-Stand.
  300 Seiten müssen nicht in den RAM; ein Absturz bei Seite 280 kostet nichts.
- Löschen verschiebt in einen `Papierkorb`-Unterordner der Session, ⇧⌘Z holt die zuletzt
  gelöschte Seite zurück. Nichts wird endgültig gelöscht.
- **Ordnername aus dem Titel**: Aus Umschlag und Titelei schlägt das Tool einen Titel vor
  (Zeilen mit hervorstechender Schriftgröße, gemessen über die Zeichenbreite). Der
  Vorschlag steht vorausgefüllt im Titelfeld der Toolbar, nicht als Dialog; umbenannt
  wird erst, wenn der Titel bestätigt oder geändert ist. Der Zeitstempel bleibt vorn
  (`2026-09-26 14-03 Der Zauberberg`), damit der Finder chronologisch sortiert.
- **Seitenfolge**: `PageSequence` liest die gedruckte Seitenzahl (reine Zahlenzeile oben
  oder unten, oben auch Kolumnentitel mit Zahl, bei Doppelseiten zwei aufeinander
  folgende) und meldet fehlende, doppelte und rückwärts laufende Seiten, mit Toleranz
  für Lesefehler. Anzeige am Vorschaubild und in der Quellenleiste, bei der Kamera ein
  Ton, wenn die eben erfasste Seite auffällt. Der Export liest die Seitenzahlen auf
  demselben Weg.
- **Nachscannen**: ⇧⌘R oder der Knopf, der beim Überfahren eines Vorschaubilds
  erscheint. Die nächste Aufnahme der gewählten Quelle ersetzt die Seite nicht sofort,
  sondern kommt dahinter; das Detail zeigt alte und neue Fassung nebeneinander.
  Vorgeschlagen (⏎) ist die Fassung mit mehr sicher erkannten Zeichen, sonst die neue;
  die verworfene geht in den Papierkorb der Session.
- **Platz sparen**, drei Stufen: Papierkorb der Session leeren (Seiten in den
  macOS-Papierkorb). Archivieren: Bilder in den macOS-Papierkorb, OCR-Text und Exporte
  bleiben, Markdown/Word/EPUB gehen weiter, PDF und Bildbefehle sind dann aus. Eine ganze
  Session löschen: ebenfalls in den macOS-Papierkorb.

### 5. Export

- **PDF**: CoreGraphics direkt, nicht PDFKit. Pro Seite eine PDF-Seite in Bildgröße, Bild
  gezeichnet (als JPEG eingebettet, damit das PDF klein bleibt), dann per CoreText jede
  OCR-Zeile mit Textmodus `.invisible` in ihre Bounding Box, Schriftgröße so skaliert,
  dass die Zeile die Boxbreite füllt, Leerzeichen am Zeilenende. Vorschau markiert und
  findet den Text dann genau dort, wo er im Bild steht.
- Dateiname aus dem Session-Titel, ohne Titel aus dem Titelvorschlag, sonst
  `Buchscan <Datum Uhrzeit>`.
- **Markdown, Word, EPUB**: Pandoc liest kein PDF, darum läuft der Weg über die
  OCR-Beobachtungen. Ein Blockmodell leitet Absätze, Überschriften, Listen und Fußnoten
  aus der Typografie des ganzen Dokuments ab (Zeichenbreite, Zeilenabstand, Einzug);
  daraus werden HTML und Markdown gerendert. Seitenwechsel als
  `<!-- Seite 12, Scan 10 -->`, unsichere Zeilen als Kommentar. Die Regeln im Einzelnen
  stehen in UMSETZUNG.md.
  - Mit Pandoc: HTML → `gfm`, `.docx` oder `.epub`. Kommentare überleben Pandoc nicht,
    darum laufen sie als Marker durch und werden danach ersetzt; in Word und EPUB
    fallen sie weg.
  - Ohne Pandoc: eigener Markdown-Schreiber im Kit, damit die Option nie tot ist; Word
    und EPUB sind dann aus. Die Einstellungen sagen, dass Pandoc bessere Ergebnisse
    liefert und wie man es installiert.
  - **Pandoc mitgeliefert** (beschlossen 26.09.2026): Das Build-Skript lädt eine
    festgenagelte Version mit geprüfter SHA-256 und legt sie als Hilfsprogramm unter
    `Contents/Helpers/pandoc` ab; `--without-pandoc` baut ohne. Suchreihenfolge: Bundle,
    Einstellungspfad, Homebrew. Keine SwiftPM-Abhängigkeit, das kennt keine
    Laufzeit-Binaries. Lizenz: Pandoc ist GPL-2.0-or-later; als getrennt aufgerufener
    Prozess ist es Beigabe, kein abgeleitetes Werk, die App bleibt EUPL. Bedingungen:
    GPL-Text und Copyright im Bundle, Quell-Tarball der gebündelten Version zum Release
    anbieten. Nicht für den App Store geeignet.
- **Silbentrennung** am Zeilenende wird ohne Wörterbuch aufgelöst: Das Systemwörterbuch
  hält Bruchstücke wie „el" oder „ner" für Wörter. Der Strich fällt, außer der zweite
  Teil beginnt groß („Desk-View") oder ist „und/oder" („Ein- und").

### Oberfläche

- **Normale Fenster-App mit Dock-Symbol**, kein Menüleisten-Item (geändert 26.09.2026
  nach Schritt 1). Das Argument für die Menüleiste war, dass Desk View den Bildschirm
  füllen soll. Mit zwei Bildschirmen liegt das Fenster auf dem anderen Display, und der
  globale Hotkey funktioniert in einer normalen App genauso. Eine normale App ist per
  Spotlight startbar, per ⌘Q beendbar und im Dock sichtbar.
- **Kein Menüleisten-Modus** (verworfen 27.09.2026). Geplant war ein zuschaltbares
  Status-Item für den Fall, dass Desk View den Bildschirm füllt und das Hauptfenster
  stört. Seit die Kamera statt des Desk-View-Fensters die Quelle ist, verdeckt nichts
  mehr das Hauptfenster, und ⌥⌘S löst auch aus, wenn eine andere App vorn liegt.
- **Quellenleiste** oben: Segmentwahl „iPhone · Dateien · Kamera", daneben eine Zeile zur
  Quelle, bei der Kamera Geräteauswahl und der Schalter für den Auto-Auslöser; in der
  Mitte Fortschritt (Import, Texterkennung, Export, Warten aufs iPhone) oder Hinweise zur
  Seitenfolge; rechts Seitenzähler und der eine Hauptknopf der Quelle („Mit iPhone
  scannen" ⇧⌘S, „Bilder oder PDF importieren…" ⇧⌘I, „Seite erfassen" ⌥⌘S). Der
  Leerzustand zeigt die gewählte Quelle mit ihrem Knopf.
- Darunter Thumbnail-Raster mit Drag-and-drop und Nachscannen-Knopf beim Überfahren,
  rechts Detailansicht mit erkanntem Text, Kamera-Vorschau oder Nachscan-Vergleich.
  Toolbar: Seitenbefehle (teilen, drehen, löschen), Titelfeld, Export, Finder.
- **Seitenleiste** (macOS-Stil wie Notizen und Bücher, ein- und ausklappbar): alle
  Sessions unter dem Sessions-Ordner, je Zeile Vorschaubild der ersten Seite, Titel oder
  Datum, Seitenzahl, Größe auf der Platte, Marken für vorhandene Exporte, Kopfzeile mit
  Gesamtgröße. Mehrfachauswahl, Doppelklick zeigt die Session im Finder, Knopf für eine
  neue Session. Kontextmenü: Öffnen, Im Finder zeigen, Papierkorb leeren, Archivieren,
  Session in den Papierkorb legen.
- Menüs: „Ablage" mit Sessions und Export (PDF ⌘E, Markdown ⇧⌘E, Word, EPUB);
  „Aufnahme" in drei Abschnitten iPhone / Dateien / Kamera; „Seite" mit Teilen ⌘T,
  Drehen ⌘L/⌘R, Nachscannen ⇧⌘R, Löschen ⌘⌫, Zurückholen ⇧⌘Z und den
  Session-Einstellungen Doppelseiten teilen und Aufrecht drehen.
- Einstellungen: Speicherort, Tastenkürzel (mit Warnung, wenn ⌥⌘S belegt ist), Pandoc
  (gefunden, mitgeliefert, eigener Pfad), Kamerafreigabe.
- Hinweise kontextabhängig statt Dauertext. „Hände raus" ist entfallen, seit Hände den
  Auto-Auslöser nicht mehr stören.
- Schrift ≥ 13 pt, hoher Kontrast, `accessibilityContrast` beachten.
- Sprachen: Deutsch und Englisch über String-Kataloge von Anfang an.

## Projektform

Swift Package mit zwei Targets:

- `BookScannerKit`: Erfassung (Kamera, Auslöser), Import, Verarbeitung, OCR, Session,
  Export. Ohne UI, testbar.
- `DeskViewBookScanner`: App (SwiftUI, ein Hauptfenster).

Dazu `build_app.sh`, das ein `.app`-Bundle mit `Info.plist` (Kamera-Schlüssel) baut, die
Version aus dem letzten Git-Tag `v*` nimmt, Pandoc beilegt und mit Hardened Runtime
signiert, mit der Apple-Development-Identität aus dem Schlüsselbund, sonst ad hoc. Grund:
Die Kamerafreigabe hängt an Bundle-ID und Signatur; ein loses `swift build`-Binary erbt
sie vom Terminal, ein ad hoc signiertes Bundle wechselt mit jedem Build den Code-Hash.
Kein Xcode-Projekt: bringt hier nichts, was das Skript nicht kann, und ist schlechter im
Git.

Tests gegen den Kit mit synthetischen Bildern und Fixtures: Geometrie (Drehen, Falz),
Import, Export (Textebene im PDF durchsuchbar, Struktur, Silbentrennung),
Session-Speicher und -Übersicht, Seitenfolge, Bewegungs- und Umblättererkennung.
Kamera, iPhone-Scan und das Verhalten am echten Buch bleiben Handprobe.

## Reihenfolge der Umsetzung

1. Quelle + Einzelbild + Session-Fenster: früh am echten Buch sehen, was die Auflösung
   hergibt. **Gebaut**, zuerst als Screenshot des Desk-View-Fensters, dann durch iPhone,
   Import und Kamera ersetzt.
2. Export mit OCR: PDF zuerst, Markdown (mit und ohne Pandoc) direkt danach, weil beide
   von denselben OCR-Beobachtungen leben. **Gebaut**, dazu Word und EPUB.
3. Drehen, Teilen und Zuschnitt. **Gebaut bis auf den Zuschnitt.**
4. Auto-Auslöser. **Gebaut**, mit Umblättererkennung und Prüfung der Seitenfolge.

## Offen

- Zuschnitt aufs Buch für Kamerabilder.

## Bekannte Risiken

1. Auflösung der Kamera: Desk View und das iPhone als Webcam liefern höchstens
   1920 × 1440, zu wenig für Fließtext kleiner Bücher. Die Kameraauswahl zeigt die
   Auflösung jedes Geräts, der Leerzustand empfiehlt 4K; für Buchtext iPhone-Scanner
   oder 4K-Kamera.
2. Auto-Auslöser: Licht, Schatten und Hände, die mehr als ein Viertel des Bildes
   bewegen, können fälschlich auslösen; Seiten mit wenig Text entscheidet der
   Kachelvergleich, der schwächer ist als der Wortvergleich. Die Prüfung der
   Seitenfolge fängt fehlende und doppelte Seiten danach ab.
3. Der Scan per ⇧⌘S nutzt, dass sich das System-Untermenü ohne Anzeige füllen und
   auslösen lässt. Das ist kein zugesagtes Verhalten und kann mit einem macOS-Update
   brechen; das Menü Ablage bleibt dann der Weg.
4. Falz-Erkennung bei hellen Büchern oder Spiralbindung ist unsicher, daher wählbar.
5. Vision-OCR bei Fraktur und fehlende Zeilen in Falznähe sind Grenzen des Frameworks
   und des Scans, nicht der Strukturierung.
