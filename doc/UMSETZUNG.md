# Umsetzung: Protokoll der Befunde

Ergänzt das [Konzept](KONZEPT.md). Jeder Eintrag nennt, was gebaut wurde, was dabei
vom Konzept abwich und den Grund. Neueste Einträge unten.

- **Schritt 1 fertig (26.09.2026):** Quelle, Screenshot, Session-Ordner, Menüleiste,
  Session-Fenster, Hotkey, Einstellungen, Build-Skript, String-Katalog de/en. Befunde
  aus dem SDK, die vom Konzept abweichen:
  - Desk View heißt intern `com.apple.DeskCam`; die App matcht daran.
  - ScreenCaptureKit hat seit macOS 26 `SCScreenshotConfiguration` mit
    `captureScreenshot(contentFilter:configuration:)`. Breite und Höhe sind dort Pixel;
    wir setzen sie trotzdem explizit aus Fenstergröße × Backing-Faktor, den wir über
    `CGDisplayCopyDisplayMode` (pixelWidth / width) des Bildschirms unter dem Fenster
    bestimmen.
  - Das Package-Manifest kennt `.macOS(.v26)`, aber kein `.v27`; wir bleiben bei `.v26`.
  - Der Auto-Auslöser-Schalter fehlt bewusst in der Oberfläche, bis Schritt 4 ihn
    füllt; ein toter Schalter wäre schlechter als keiner.
  - Erst als Menüleisten-App gebaut, dann auf ein normales Fenster umgestellt (siehe
    Oberfläche).
  - Zeitstempel in `session.json` sind ISO 8601 mit Millisekunden; Werte werden beim
    Anlegen durch dasselbe Format normalisiert, damit Speicher und Platte exakt gleich sind.

- **Schritt 2 fertig (26.09.2026):** OCR nach jeder Aufnahme im Hintergrund
  (`PageProcessor`), Text als `OCR/<Aufnahme>.json` neben dem Bild, PDF mit
  unsichtbarer Textebene, Markdown über Pandoc oder eigenen Schreiber, Word und EPUB
  über Pandoc, Titelvorschlag vom Umschlag ins Titelfeld. Befunde:
  - Vision hat seit macOS 15 eine Swift-API (`RecognizeTextRequest`), die wir statt
    `VNRecognizeTextRequest` nutzen. Der erste Lauf im Prozess dauert rund 25 s
    (Modell laden), danach unter einer Sekunde pro Seite.
  - Pandoc verschluckt HTML-Kommentare. Seitenwechsel gehen daher als Marker-Absatz
    `@@SEITE 12@@` durch Pandoc und werden danach zu `<!-- Seite 12 -->`.
  - Ein aus JPEG-Daten erzeugtes `CGImage` bettet CoreGraphics als DCTDecode ins PDF
    ein; so bleibt das PDF klein. Test prüft das am Bytestrom.
  - Struktur (Absätze, Überschriften) kommt aus einem gemeinsamen Blockmodell, aus dem
    HTML und Markdown gerendert werden; das ist derselbe Weg wie im Konzept, nur ohne
    den Umweg HTML→Markdown im Kit.

- **Schritt 3 teilweise (26.09.2026):** Drehen und Teilen sind gebaut, der Zuschnitt
  über `VNDetectDocumentSegmentationRequest` steht noch aus (iPhone-Scans kommen schon
  beschnitten). Befunde:
  - Visions genaue Erkennung liest gedrehten Text von sich aus und liefert das Viereck
    jeder Zeile. Die Richtung der Oberkante (`topLeft → topRight`) verrät die Lage;
    gewichtete Abstimmung über alle Zeilen ergibt die nötige Vierteldrehung. Der
    Umweg über vier Erkennungsläufe war unnötig, und die schnelle Erkennung
    unterscheidet 0° und 180° ohnehin nicht.
  - Falz: Erst die textfreie Lücke zwischen linkem und rechtem Textblock aus den
    OCR-Zeilen (die für die Drehung ohnehin da sind), dann darin das Helligkeitstal,
    sonst die Lückenmitte. Grund: Bei gewölbten Büchern liegt die dunkelste Spalte oft
    vor dem Falz, wo die Seite abtaucht, und der Schnitt kappte Buchstaben. Ohne
    Zeilen bleibt das Tal über 35 % bis 65 % der Breite, sonst Mitte. Kreuzt Text die
    Schnittlinie (Umschlag im Querformat), wird nicht geteilt. Ein Bild gilt ab
    Seitenverhältnis 1,15 als Doppelseite.
  - Beides läuft in `PageProcessor.prepare` vor dem Speichern, für Import, iPhone-Scan
    und Desk View gleichermaßen. Für vorhandene Seiten gibt es „Seite teilen" ⌘T und
    „Drehen" ⌘L/⌘R; `replacePage` setzt die neuen Seiten an dieselbe Stelle und legt
    die alte in den Papierkorb.
  - Lesereihenfolge der OCR: Zeilen bilden nur dann eine Reihe, wenn sie sich vertikal
    überlappen und horizontal nicht. Der frühere Vergleich über die Boxhöhe verschmolz
    bei schiefen Seiten Nachbarzeilen zu einer Reihe. Alte OCR-Dateien (Version 1)
    werden beim Laden neu sortiert.
- **iPhone-Scan per Hotkey (26.09.2026):** ⇧⌘S löst „Dokumente scannen" auf dem
  iPhone vom Mac aus. Mechanismus wie in continuity-capture: verstecktes `NSTextView`
  mit `importsGraphics` wird First Responder, `registerServicesMenuSendTypes` meldet
  die Typen, das System-Untermenü am Item von `ImportFromDevicesCommands` wird mit
  `update()` ohne Anzeige gefüllt und der Eintrag mit `performActionForItem` ausgelöst;
  der Scan kommt als `NSTextAttachment` und geht als Datei durch den Import. Der
  Menüeintrag selbst bleibt in der SwiftUI-App ausgegraut, weil SwiftUIs
  Hosting-View die Anfrage nach einem Empfänger nicht weiterreicht; das ist egal.

- **Strukturierung nach der ersten Markdown-Prüfung (26.09.2026, Baudrillard,
  „Agonie des Realen"):** Die OCR war gut, fast alle Fehler kamen aus der Strukturierung,
  und die meisten hatten eine Wurzel: Typografie pro Seite gemessen. Jetzt gilt:
  - Zeilenhöhe und Zeilenabstand als Median über das ganze Dokument (ab 20 Zeilen),
    pro Seite nur als Rückfall. Umschlag, Titelei und Inhalt haben zu wenig Zeilen.
  - Zwei harte Absatzregeln vor allen Heuristiken: Eine Zeile, die mit Bindestrich
    endet, beendet nie einen Absatz; eine Zeile, die mit Kleinbuchstaben beginnt,
    beginnt nie einen. Einzug ist nur Absatzbeginn, wenn die Zeile davor kurz war oder
    die Zeile danach an den Rand zurückkehrt (hängender Einzug im Glossar sonst).
  - Überschrift nur, wenn kurz oder freistehend, nicht klein beginnend, nicht mit
    Bindestrich endend, nicht mit Zahl beginnend. Zusätzlich: Versalienzeilen, und
    Zeilen, die einem Eintrag des Inhaltsverzeichnisses entsprechen (Seite mit
    „Inhalt" oder überwiegend nummerierten Zeilen; Ebene 1 bei Versalien).
  - Listenseiten (ab 40 % Zeilen mit Zahl am Anfang oder Ende): jede Zeile ein
    Listenpunkt. Trifft Inhalt, Bibliografie, Titelei.
  - Silbentrennung: Wörterbuch auch über Grundform („REICHES" → „Reiches"); Strich
    bleibt nur bei großem zweiten Teil („Desk-View") oder wenn beide Teile Wörter sind;
    unbekannte Bruchstücke werden zusammengezogen. Fehlt der Strich im Scan
    („Territo riums"), wird zusammengezogen, wenn beide Teile unbekannt und das Ganze
    bekannt ist.
  - Fußnoten: kleinere Zeilen am Seitenende unter normalem Text, als eigener Block.
  - Absatz über die Seitengrenze wird fortgesetzt (Bindestrich oder kein Satzende und
    kleiner Anfang); der Seitenmarker rückt hinter den fortgesetzten Absatz.
  - Gedruckte Seitenzahl (reine Ziffernzeile oben oder unten) wandert in den Marker:
    `<!-- Seite 12, Scan 10 -->`.
  - Zeilen unter Konfidenz 0,5 werden als Kommentar `<!-- unsicher: … -->` vor dem
    Absatz gemeldet; Pandoc-Weg über Marker wie bei den Seitenwechseln.
  - Ohne Session-Titel nimmt der Export den Titelvorschlag vom Umschlag.
  - Nicht heilbar in der Strukturierung: OCR-Fehler im Scan („Bildröäre", „Uberdruck")
    und fehlende Zeilen in Falznähe.
  - Zweite Runde nach dem Export des ganzen Buchs (114 Scans): Überschrift nie nach
    einer Bindestrich-Zeile oder einer offenen Zeile voller Breite, nie vor einer klein
    beginnenden Zeile, nie mit Zahl am Ende, Fußnotenmarke am Anfang oder Doppelpunkt
    am Ende; Versalien brauchen sechs Buchstaben und wenig Sonderzeichen. Fußnoten:
    Block kleiner Zeilen am Seitenende, beginnt mit Marke oder ist mindestens zwei
    Zeilen deutlich kleiner, beginnt nie klein; Ausgabe als Zitatblock, weil Pandoc
    `<small>` zu einem Span macht. Absatz über die Seitengrenze auch über leere Scans
    und Fußnoten hinweg. Doppelte Scans (Jaccard der Zeilen ≥ 0,6 zu einer der letzten
    drei Seiten) werden übersprungen und gemeldet. Listenseiten: jede Zeile ein Eintrag,
    außer nach Komma oder Bindestrich. Bindestriche mitten in der Zeile (aus von Vision
    zusammengelegten Zeilen, „el-ner") laufen durch dieselbe Silbenregel.
  - Dritte Runde, zwei Grundsatzkorrekturen: **Schriftgröße über die Zeichenbreite**
    (Boxbreite geteilt durch Zeichenzahl) statt über die Boxhöhe. Gemessen am
    Bakunin-Scan schwankt die Höhe von Fließtextzeilen derselben Schrift zwischen 0,62
    und 1,22 des Medians (Ober- und Unterlängen), die Zeichenbreite nur um ±5 %;
    Überschriften liegen bei 2,5- bis 3-facher Zeichenbreite. Gilt für Überschriften,
    Fußnoten und Titelvorschlag. Und **Silbentrennung ohne Wörterbuch**: Das
    Systemwörterbuch hält „el", „ner", „ie", „positivs" für Wörter, damit taugt es
    nicht für Bruchstücke. Am Zeilenende fällt der Strich immer, außer der zweite Teil
    beginnt groß („Desk-View") oder ist „und/oder" (Ergänzungsstrich, „Ein- und").
    Mitten in der Zeile fällt er, wenn das Ganze bekannt ist, ein Teil unter vier
    Buchstaben hat oder ein Teil unbekannt ist; „nichtig-kitschigen" bleibt.
    DOCX und EPUB bekommen Seitenmarker und Notizen als HTML-Kommentare, die Pandoc
    verschluckt; vorher standen die Platzhalter wörtlich im Buch. Umschlagzeilen, die
    im Dokumenttitel stecken oder Verlagszeilen sind, werden keine Überschriften.

- **Aufräumen und Code-Durchsicht (26.09.2026, abends):**
  - Tot: Menü „Letzte Sessions" (durch die Seitenleiste ersetzt), `DeskViewWindowInfo.title`,
    `ContinuityCamera.acceptedTypes`.
  - Desk View wurde alle zwei Sekunden über `SCShareableContent` abgefragt, auch wenn das
    iPhone die Quelle war; die Abfrage läuft jetzt nur bei gewählter Quelle Desk View.
  - Der Cache verkleinerter Seitenbilder wuchs unbegrenzt (bei 300 Seiten rund 150 MB);
    jetzt `BoundedCache` mit 240 Einträgen, älteste fliegen zuerst.
  - Dateien nach Zuständigkeit geteilt: `AppModel` in Kern, Export und Sessions;
    `DocumentStructure` in Strukturierer, `Hyphenation`, `Typography`, `TitleSuggester`,
    `WordChecker`; `SessionWindow` in Fenster, `StatusBar`, `ExportButtons`, `PageGrid`,
    `PageDetail`. Reine Verschiebungen, Tests unverändert grün.
  - Das Änderungsprotokoll ist aus dem Konzept hierher gewandert; das Konzept bleibt
    der Plan, diese Datei die Chronik.
- **Seite nachscannen (26.09.2026):** ⇧⌘R merkt sich die ausgewählte Seite; das nächste
  Ergebnis der gewählten Quelle (iPhone-Scan, Dateiimport, Desk-View-Aufnahme) ersetzt
  sie an Ort und Stelle über `replacePage`, die alte wandert in den Papierkorb der
  Session. Kommen mehrere Seiten (Doppelseite geteilt, mehrere Scans), rücken alle an
  die Stelle. Ein Abbruch (Dialog, iPhone-Timeout) verwirft das Ziel.
- **Kamera-Quelle über AVFoundation (26.09.2026, spät):** ersetzt den Screenshot des
  Desk-View-Fensters. Gemessen: die Desk-View-Kamera (Mac wie iPhone) bietet genau ein
  Format, 1920 × 1440, das Fenster skaliert nur hoch; das iPhone als Webcam ebenfalls
  maximal 1920 × 1440, auch als Foto; die Insta360 liefert 3840 × 2160. `CameraSource`
  listet alle Kameras (Desk View, Continuity, extern, eingebaut), wählt das größte
  Format und holt Einzelbilder aus dem Live-Feed; Live-Vorschau im Detail, Geräteauswahl
  in der Quellenleiste. **Auto-Auslöser** (Schritt 4) als testbarer Zustandsautomat
  `MotionTrigger`: Bewegung, dann 1,5 s Ruhe, dann Vergleich mit der zuletzt erfassten
  Seite; läuft mit rund vier Bildern pro Sekunde auf 160 px breiten Graubildern. Neue
  Freigabe: Kamera statt Bildschirmaufnahme; Info.plist braucht
  `NSCameraUseContinuityCameraDeviceType`, sonst fehlt das iPhone in der Liste.
  ScreenCaptureKit und `DeskViewSource` sind entfernt.
