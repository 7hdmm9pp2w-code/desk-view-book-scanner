# Desk View Book Scanner

Eine macOS-App, die Buchseiten aus dem Fenster der Schreibtischansicht
(Desk View) fotografiert und daraus eine Session mit Seiten, später OCR-Text und ein
durchsuchbares PDF macht. Das Konzept steht in [doc/KONZEPT.md](doc/KONZEPT.md).

Zielplattform: aktuelles macOS (27) auf Apple Silicon, kein Xcode-Projekt, nur ein
Swift Package.

## Bauen und starten

```bash
./build_app.sh --run
```

Das Skript baut `build/DeskViewBookScanner.app`, signiert es mit der
Apple-Development-Identität aus dem Schlüsselbund (sonst ad hoc) und startet es.
Beim ersten Start fragt macOS nach der Freigabe für Bildschirmaufnahme; danach die
App einmal beenden und neu starten.

Beim ersten Build lädt `scripts/fetch_pandoc.sh` Pandoc 3.11 für Apple Silicon
(40 MB Archiv, 181 MB ausgepackt) samt Quell-Tarball nach `build/vendor/` und prüft die
SHA-256. `./build_app.sh --without-pandoc` baut ohne, dann nutzt die App ein
installiertes Pandoc oder schreibt Markdown selbst.

Tests laufen gegen den Kit ohne UI:

```bash
swift test
```

## Bedienung

- Hauptfenster: Statusleiste mit „Desk View starten" und „Seite erfassen", darunter
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
