# Desk View Book Scanner

**Ein Buch umblättern, fertig ist der Text.** Seite hinlegen, die App erfasst sie,
dreht sie gerade, teilt die Doppelseite und erkennt den Text in unter einer Sekunde,
noch bevor die nächste Seite liegt. Am Ende steht das Buch als durchsuchbares PDF,
Markdown, Word oder EPUB auf der Platte, mit Absätzen, Überschriften und Fußnoten.

- **Schnell.** iPhone-Scan per Tastendruck, die Seite ist sofort am Mac. Mit einer
  Kamera über dem Buch reicht Umblättern: Der Auto-Auslöser nimmt jede neue Seite
  von selbst.
- **Lokal.** Texterkennung von macOS, Deutsch und Englisch, keine Cloud, kein Konto.
  Nichts verlässt den Mac.
- **Ein Buch, kein Stapel Fotos.** Durchgehender Text über Seitengrenzen,
  aufgelöste Silbentrennung, Seitenmarker. Fehlende oder doppelte Seiten meldet die
  App schon beim Scannen.

![Auto-Auslöser mit Desk View: umblättern, die App erfasst die Seite von selbst](doc/media/demo.gif)

Im Video liefert **Desk View** die Bilder, auf Deutsch „Schreibtischansicht": Eine
Funktion von macOS, die mit der Kamera des Macs oder eines iPhones am Bildschirmrand
von oben auf den Tisch schaut. Kein Stativ, kein Umbau, das Buch liegt einfach vor der
Tastatur. Für kleinen Fließtext ist ihr Bild allerdings zu grob; dafür gibt es den
iPhone-Scan oder eine 4K-Kamera (siehe [Tipps](#tipps-für-gute-scans)).

Notizen oder Prizmo scannen auch gut, liefern aber kein Buch mit Absatzstruktur und
keinen Session-Ordner, in dem man später weitermacht.

English version: [README.md](README.md).

## Schnellstart

```bash
./build_app.sh --run
```

1. Quelle oben im Fenster wählen: iPhone, Kamera oder Dateien.
2. Scannen: ⇧⌘S (iPhone), Leertaste (Kamera) oder „Beim Umblättern auslösen" einschalten.
3. Exportieren: ⌘E für PDF, ⇧⌘E für Markdown, Word und EPUB im Menü Ablage.

Braucht macOS 27 auf Apple Silicon, für den iPhone-Scan ein iPhone mit derselben
Apple-ID (Continuity Camera). Bauen: siehe [Für Entwickler](#für-entwickler).

### Fertige App herunterladen

Unter [Releases](https://github.com/7hdmm9pp2w-code/desk-view-book-scanner/releases)
liegt die App als ZIP. Sie ist **nicht notarisiert**, weil kein bezahlter
Apple-Entwickler-Account dahintersteht. macOS blockiert sie deshalb beim ersten Start:

1. ZIP entpacken, die App in den Ordner Programme ziehen und einmal öffnen. macOS
   meldet, die App könne nicht geöffnet werden.
2. Systemeinstellungen → Datenschutz & Sicherheit → unten bei der Meldung zur App
   „Trotzdem öffnen" wählen und bestätigen.

Alternativ im Terminal: `xattr -dr com.apple.quarantine "/Applications/DeskViewBookScanner.app"`.
Wer der fertigen App nicht traut, baut sie selbst aus dem Quellcode.

## Ablauf

1. **Erfassen.** Jede Seite landet sofort in der Session, einem Ordner pro Buch. Die
   App dreht sie aufrecht und teilt Doppelseiten am Falz; der Text wird im Hintergrund
   erkannt, der Umschlag liefert den Titelvorschlag.
2. **Prüfen.** Aus den gedruckten Seitenzahlen erkennt die App fehlende, doppelte und
   vertauschte Seiten und markiert sie mit einem Dreieck, bei der Kamera zusätzlich mit
   einem Ton. Unscharfe Seiten nachscannen (⇧⌘R oder Knopf am Vorschaubild): Alte und
   neue Fassung stehen nebeneinander, die besser erkannte ist vorgeschlagen.
3. **Exportieren.**

| Format | Was man bekommt |
|---|---|
| PDF | Seitenbilder mit unsichtbarer Textebene, in Vorschau durchsuchbar und kopierbar |
| Markdown | durchgehender Text mit Überschriften, Fußnoten, `<!-- Seite 12, Scan 10 -->`-Markern und markierten unsicheren Zeilen |
| Word, EPUB | derselbe Text, zum Weiterschreiben oder für den E-Reader |

## Tipps für gute Scans

Die meisten Fehler im Export kommen nicht aus der Texterkennung, sondern aus zu wenig
Pixeln, einem gewölbten Falz oder Seiten ohne Anhalt.

**Die richtige Quelle.** Entscheidend ist die Zeilenhöhe im Bild: ab etwa 20 px ist
Fließtext zuverlässig, unter 12 px wird geraten. Gemessen, nicht geschätzt:

| Quelle | Echte Auflösung | Reicht für |
|---|---|---|
| iPhone-Dokumentenscanner | ca. 1700 × 2700 pro Seite | Fließtext, der empfohlene Weg |
| 4K-Kamera über dem Buch (z. B. Insta360 Link) | 3840 × 2160 | Fließtext, freihändig mit Auto-Auslöser |
| Desk View (Mac- oder iPhone-Kamera von oben), iPhone als Webcam | 1920 × 1440 | Umschläge, Überschriften, Großdruck |

- **Desk View: Buch an die Tastaturkante, Trapez eng ziehen.** Desk View entzerrt den
  Rand eines Weitwinkelbilds; der ferne Tischrand ist am unschärfsten, und jedes
  Stück Tisch im Trapez kostet Pixel am Buch.
- **Umschlag und Inhaltsverzeichnis zuerst.** Der Umschlag gibt den Titel, das
  Inhaltsverzeichnis hilft, Überschriften zu erkennen.
- **Seitenzahlen im Bild lassen.** Ohne sie keine Prüfung der Seitenfolge und keine
  Seitenmarker.
- **Buch flach drücken, am Rand halten.** Zeilen, die im gewölbten Falz fehlen, lassen
  sich nicht zurückholen. Hände am Rand stören den Auto-Auslöser nicht.
- **Nach dem Umblättern kurz stillhalten.** Der Auto-Auslöser wartet anderthalb
  Sekunden Ruhe. Beim ersten Einschalten lädt die Texterkennung bis zu 25 s.
- **Helle Bücher, Spiralbindung:** Falzsuche kann danebenliegen, dann unter Aufnahme >
  Doppelseiten teilen „In der Mitte" oder „Nicht teilen".
- **Nach `unsicher` im Markdown suchen.** Das sind die Kandidaten fürs Nachscannen.
  `scripts/ocr_stats.py` zeigt Zeilenhöhe und Sicherheit je Seite.

## Tastenkürzel

| | |
|---|---|
| ⇧⌘S | Mit dem iPhone scannen |
| ⌥⌘S | Seite mit der Kamera erfassen (im Seitenraster auch Leertaste) |
| ⇧⌘I | Bilder oder PDF importieren |
| ⇧⌘R | Seite nachscannen |
| ⌘T, ⌘L, ⌘R | Seite teilen, nach links, nach rechts drehen |
| ⌘⌫, ⇧⌘Z | Seite löschen, zuletzt gelöschte zurückholen |
| ⌘N, ⌘O | Neue Session, Session-Ordner öffnen |
| ⌘E, ⇧⌘E | Als PDF, als Markdown exportieren |

## Wo die Daten liegen

Jede Session ist ein Ordner unter `~/Documents/Buchscans/` (änderbar in den
Einstellungen): Seiten als HEIC, erkannter Text als JSON daneben, Reihenfolge in
`session.json`, gelöschte Seiten in `Papierkorb/`. Die Seitenleiste zeigt alle
Sessions; per Rechtsklick archivieren (Bilder weg, Text bleibt) oder löschen, immer
in den macOS-Papierkorb.

## Für Entwickler

Swift Package ohne Xcode-Projekt; Xcode oder die Command Line Tools reichen.

```bash
./build_app.sh --run
```

```bash
swift test
```

Das Build-Skript signiert mit der Apple-Development-Identität aus dem Schlüsselbund
(sonst ad hoc) und mit dem Kamera-Entitlement. Beim ersten Build lädt es Pandoc 3.11
(für Word, EPUB und besseres Markdown) samt Quell-Tarball nach `build/vendor/` und prüft
die SHA-256; `--without-pandoc` baut ohne.

- `BookScannerKit`: Aufnahme, Session, OCR, Drehen und Teilen, Strukturierung, Export.
  Ohne UI, voll getestet.
- `DeskViewBookScanner`: die SwiftUI-App.
- `scripts/`: Pandoc-Download, Icon, OCR-Statistik, Prüfung der Continuity-Fotogröße.

Wie die App innen entscheidet (Falzsuche, Auto-Auslöser, Absätze und Überschriften),
steht im [Konzept](doc/KONZEPT.md) und im [Umsetzungsprotokoll](doc/UMSETZUNG.md).

## Lizenz

[EUPL-1.2](LICENSE), amtliche Fassungen in allen EU-Sprachen unter
<https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12>.

Das Bundle enthält [Pandoc](https://github.com/jgm/pandoc) (© John MacFarlane,
GPL-2.0-or-later) als getrenntes Hilfsprogramm unter `Contents/Helpers/pandoc`; die App
ist kein abgeleitetes Werk. Lizenztext unter `Contents/Resources/Lizenzen/`, Quellcode
der gebündelten Version liegt jedem Release als `pandoc-<Version>-src.tar.gz` bei (beim
Bauen unter `build/vendor/`).

## Dank

Word, EPUB und das gute Markdown kommen von [Pandoc](https://pandoc.org). Danke an John
MacFarlane und alle, die an Pandoc mitarbeiten, für das Werkzeug und dafür, dass man es
frei mitgeben darf.
