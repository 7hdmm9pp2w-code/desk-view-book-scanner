# Desk View Book Scanner

Bücher am Mac digitalisieren: Seite für Seite scannen, den Text erkennen lassen und
das Ergebnis als durchsuchbares PDF, Markdown, Word oder EPUB mitnehmen.

## Was die App macht

Du blätterst ein Buch durch und nimmst jede Seite auf, am besten mit dem iPhone über
Apples Dokumentenscanner. Die App sammelt die Seiten in einer **Session**, einem
Ordner pro Buch oder Kapitel, und erledigt den Rest selbst:

1. **Seiten holen.** Drei Wege, alle landen in derselben Session:
   - **iPhone-Scan** über Continuity Camera: Scan auf dem iPhone auslösen, die Seite
     erscheint sofort am Mac. Der empfohlene Weg für Fließtext.
   - **Import** vorhandener PDFs und Bilder, etwa aus Notizen, vFlat oder Fotos.
   - **Desk View** (Schreibtischansicht): ein Tastendruck fotografiert das
     Desk-View-Fenster. Reicht für Umschläge, Überschriften und Großdruck, für
     kleinen Buchtext ist die Auflösung zu gering.
2. **Seiten aufbereiten.** Jede Seite wird aufrecht gedreht, eine Doppelseite am Falz
   in zwei Seiten geteilt.
3. **Text erkennen.** Nach jeder Aufnahme läuft im Hintergrund die Texterkennung von
   macOS (Vision, Deutsch und Englisch), vollständig lokal, ohne Cloud. Absätze und
   Überschriften bleiben erhalten, Silbentrennungen am Zeilenende werden aufgelöst.
   Aus dem Umschlag schlägt die App einen Titel vor.
4. **Exportieren.**
   - **PDF** mit den Seitenbildern und einer unsichtbaren Textebene: in Vorschau
     durchsuchbar, markierbar und kopierbar, genau an der Stelle im Bild.
   - **Markdown**, **Word** (.docx) und **EPUB** mit durchgehendem Text über
     Seitengrenzen hinweg, bequem zum Weiterverarbeiten, Zitieren oder Lesen auf dem
     E-Reader. Im Markdown markiert ein Kommentar, wo jede Buchseite beginnt.

Alles liegt als normale Dateien auf der Platte: Seitenbilder als HEIC, erkannter Text
als JSON daneben, die Reihenfolge in `session.json`. Nichts verlässt den Mac.

**Warum nicht einfach Notizen oder Prizmo?** Die scannen gut, liefern aber kein
Buch mit Absatzstruktur als Markdown, Word oder EPUB und keinen Session-Ordner, in
dem man später weitermachen kann. Das ist der Kern hier.

Das Konzept steht in [doc/KONZEPT.md](doc/KONZEPT.md), die Befunde aus der Umsetzung
in [doc/UMSETZUNG.md](doc/UMSETZUNG.md).

## Voraussetzungen

- Aktuelles macOS (27) auf Apple Silicon
- Für den iPhone-Scan: ein iPhone mit derselben Apple-ID, Bluetooth und WLAN an
  (Continuity Camera)
- Zum Bauen: Swift-Toolchain (Xcode oder Command Line Tools). Es gibt kein
  Xcode-Projekt, nur ein Swift Package.

## Kamera und Auflösung

Was die Texterkennung braucht, ist Pixel pro Buchstabe. Ein Taschenbuchtext ist ab
etwa 20 Pixel Zeilenhöhe zuverlässig lesbar, unter 12 wird es Raten. Gemessen über
AVFoundation, nicht geschätzt:

| Quelle | Echte Auflösung | Reicht für |
|---|---|---|
| iPhone-Dokumentenscanner | ca. 1700 × 2700 pro Seite | Fließtext, der empfohlene Weg |
| 4K-Kamera über dem Buch (z. B. Insta360 Link) | 3840 × 2160 | Fließtext, freihändig mit Auto-Auslöser |
| Desk View (Mac oder iPhone) | 1920 × 1440, mehr gibt es nicht | Umschläge, Überschriften, Großdruck |
| iPhone als Webcam | 1920 × 1440 | wie Desk View |

Das Desk-View-Fenster zeigt mehr Pixel, als der Feed hat; das ist Hochskalierung.
Und der Feed ist nicht überall gleich scharf: Desk View schneidet den unteren Teil
des Ultraweitwinkel-Bildes aus und entzerrt ihn zu einer Draufsicht. Der ferne Rand
des Schreibtischs wird dabei am stärksten gestreckt und ist am unschärfsten, die
Zone an der Tastaturkante am schärfsten. Darum:

- **Buch nah ans Gerät**, an die Tastaturkante, nicht in die Tischmitte.
- **Trapez in der Desk-View-Einrichtung eng ums Buch ziehen**, damit die 1920 Pixel
  nicht den halben Tisch abdecken.
- **Für ganze Bücher** eine 4K-Kamera senkrecht über dem Buch oder der iPhone-Scan.
  Der Auto-Auslöser erfasst nach jedem Umblättern, sobald das Bild anderthalb
  Sekunden ruhig liegt und sich von der letzten Seite unterscheidet.
- Eine unscharfe Seite muss nicht neu einsortiert werden: auswählen, ⇧⌘R, neu erfassen.

`scripts/ocr_stats.py` zeigt je Aufnahme die Zeilenhöhen und Konfidenzen einer Session.

## Bauen und starten

```bash
./build_app.sh --run
```

Das Skript baut `build/DeskViewBookScanner.app`, signiert es mit der
Apple-Development-Identität aus dem Schlüsselbund (sonst ad hoc) und startet es.
Die Kamera-Quelle fragt beim ersten Start nach der Kamera-Freigabe.

Beim ersten Build lädt `scripts/fetch_pandoc.sh` Pandoc 3.11 für Apple Silicon
(40 MB Archiv, 181 MB ausgepackt) samt Quell-Tarball nach `build/vendor/` und prüft die
SHA-256. `./build_app.sh --without-pandoc` baut ohne, dann nutzt die App ein
installiertes Pandoc oder schreibt Markdown selbst.

Tests laufen gegen den Kit ohne UI:

```bash
swift test
```

## Bedienung

- Seiten kommen aus drei Quellen: **„Mit iPhone scannen"** ⇧⌘S öffnet Apples
  Dokumentenscanner auf dem iPhone (Continuity Camera), der Scan landet direkt in der
  Session; **Import** ⇧⌘I von PDFs und Bildern (Scans aus Notizen, vFlat, Fotos);
  **Kamera** ⌥⌘S holt ein Bild aus jeder Kamera, die AVFoundation sieht, im größten
  Format: eine 4K-Kamera über dem Buch liefert 3840 × 2160 und lesbaren Fließtext, Desk
  View bleibt bei 1920 × 1440. Der Auto-Auslöser erfasst nach jedem Umblättern.
- Vor dem Speichern wird jede Seite aufrecht gedreht und eine Doppelseite am Falz
  geteilt (Menü „Aufnahme": automatisch, Mitte oder gar nicht). Vorhandene Seiten:
  „Seite teilen" ⌘T, drehen ⌘L / ⌘R.
- Seitenleiste links mit allen Sessions, Größe und Exporten; Rechtsklick für
  Papierkorb leeren, Archivieren (Bilder weg, Text bleibt) und Löschen, alles in den
  macOS-Papierkorb.
- Hauptfenster: Quellenleiste mit dem Hauptknopf der gewählten Quelle, darunter
  die Seiten der Session; rechts die Detailansicht.
- ⌥⌘S erfasst das Desk-View-Fenster als Seite, auch wenn Desk View vorn liegt.
- Menü „Ablage": Neue Session ⌘N, Session-Ordner öffnen ⌘O, Letzte Sessions,
  Export als PDF ⌘E, Markdown ⇧⌘E, Word und EPUB.
- Texterkennung läuft nach jeder Aufnahme im Hintergrund (Vision, Deutsch und
  Englisch). Das PDF bekommt eine unsichtbare Textebene, Vorschau findet den Text
  genau dort, wo er im Bild steht. Die erste Aufnahme liefert einen Titelvorschlag.
- Sessions liegen unter `~/Documents/Buchscans/<Datum Uhrzeit>/`, änderbar in den
  Einstellungen. Jede Aufnahme ist sofort als HEIC auf der Platte; `session.json`
  hält Reihenfolge und Einstellungen. Gelöschte Seiten wandern in `Papierkorb/`.

## Lizenz

[EUPL-1.2](LICENSE) (European Union Public Licence). Amtliche Fassungen in allen
EU-Sprachen, darunter die deutsche, unter
<https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12>.

Das App-Bundle enthält [Pandoc](https://github.com/jgm/pandoc) als eigenständiges
Hilfsprogramm unter `Contents/Helpers/pandoc`. Pandoc ist © John MacFarlane und steht
unter der GPL-2.0-or-later; die App ruft es als getrennten Prozess auf und ist kein
abgeleitetes Werk. Lizenztext und Copyright liegen im Bundle unter
`Contents/Resources/Lizenzen/`, der Quellcode der gebündelten Version unter
`build/vendor/pandoc-<Version>-src.tar.gz` (bei einem Release mit anbieten).
