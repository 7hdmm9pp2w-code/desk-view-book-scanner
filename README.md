# Desk View Book Scanner

Ein Menüleisten-Tool für macOS, das Buchseiten aus dem Fenster der Schreibtischansicht
(Desk View) fotografiert und daraus eine Session mit Seiten, später OCR-Text und ein
durchsuchbares PDF macht. Das Konzept steht in [doc/KONZEPT.md](doc/KONZEPT.md).

Zielplattform: aktuelles macOS (27) auf Apple Silicon, kein Xcode-Projekt, nur ein
Swift Package.

## Bauen und starten

```bash
./build_app.sh --run
```

Das Skript baut `build/DeskViewBookScanner.app`, signiert es ad hoc und startet es.
Beim ersten Start fragt macOS nach der Freigabe für Bildschirmaufnahme; danach die
App einmal beenden und neu starten.

Tests laufen gegen den Kit ohne UI:

```bash
swift test
```

## Bedienung

- Menüleisten-Symbol (Buch): Status, „Seite erfassen", Sessions.
- ⌥⌘S erfasst das Desk-View-Fenster als Seite, auch wenn Desk View vorn liegt.
- Sessions liegen unter `~/Documents/Buchscans/<Datum Uhrzeit>/`, änderbar in den
  Einstellungen. Jede Aufnahme ist sofort als HEIC auf der Platte; `session.json`
  hält Reihenfolge und Einstellungen. Gelöschte Seiten wandern in `Papierkorb/`.

## Lizenz

[EUPL-1.2](LICENSE) (European Union Public Licence). Amtliche Fassungen in allen
EU-Sprachen, darunter die deutsche, unter
<https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12>.
