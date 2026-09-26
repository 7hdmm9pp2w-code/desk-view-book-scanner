# Desk View Book Scanner

A macOS app that turns book pages into a session of images, recognized text and
exports: a searchable PDF, Markdown, Word or EPUB. Pages come from the iPhone's
document scanner (triggered from the Mac), from imported PDFs and images, or from
Apple's Desk View camera.

Deutsche Fassung: [README.de.md](README.de.md). Design notes and the implementation
log are in German: [doc/KONZEPT.md](doc/KONZEPT.md), [doc/UMSETZUNG.md](doc/UMSETZUNG.md).

Target platform: current macOS (27) on Apple silicon. No Xcode project, just a Swift
package and a build script.

## What it does

- **Sources.** *iPhone* (⇧⌘S) opens Apple's document scanner on your iPhone via
  Continuity Camera; the scan lands in the session as pages. *Files* (⇧⌘I) imports PDFs
  and images, for example scans from Notes or vFlat, rendered at their embedded
  resolution. *Desk View* (⌥⌘S) captures the Desk View window; good enough for covers
  and large print, not for body text (the feed is 1920 × 1440).
- **Before saving**, every page is rotated upright (Vision reads the text direction) and
  double pages are split at the gutter, using the text-free gap between the two text
  blocks. Existing pages can be split (⌘T), rotated (⌘L/⌘R) or rescanned in place (⇧⌘R).
- **OCR** runs in the background after every page (Vision, German and English), keeping
  bounding boxes. The **PDF** gets an invisible text layer placed exactly where the words
  are in the image, so Preview finds and highlights them in place.
- **Markdown, Word, EPUB** are built from a block model: paragraphs from line spacing and
  indents, headings from the table of contents, uppercase lines and size, footnotes,
  page markers (`<!-- Seite 12, Scan 10 -->`), de-hyphenation, duplicate-scan detection,
  and notes for low-confidence lines. Pandoc is bundled for Word and EPUB and for better
  Markdown; without it the app writes Markdown itself.
- **Sessions** are folders on disk: every page is saved immediately as HEIC, `session.json`
  holds the order and settings, OCR results sit next to the images, deleted pages go to
  the session's own `Papierkorb` folder. The sidebar lists all sessions with size and
  exports; the context menu empties trashes, archives (removes images, keeps text) or
  deletes sessions, always into the macOS Trash.

## Build and run

```bash
./build_app.sh --run
```

The script builds `build/DeskViewBookScanner.app`, signs it with the Apple Development
identity in your keychain (ad hoc otherwise) and launches it. On first launch macOS asks
for screen-recording access (only needed for Desk View); quit and reopen the app once
after granting it.

The first build downloads Pandoc 3.11 for Apple silicon (40 MB archive, 181 MB unpacked)
plus its source tarball into `build/vendor/` and verifies the SHA-256. Use
`./build_app.sh --without-pandoc` for a smaller bundle; the app then uses an installed
Pandoc or falls back to its own Markdown writer.

Tests run against the kit, without UI:

```bash
swift test
```

## Layout

- `BookScannerKit`: capture, session store, OCR, page geometry (rotation, splitting),
  document structuring, exporters, importer. No UI, fully testable.
- `DeskViewBookScanner`: the SwiftUI app.
- `scripts/`: Pandoc fetcher, icon renderer, OCR statistics helper.

## License

[EUPL-1.2](LICENSE) (European Union Public Licence). Official versions in all EU
languages, including German, at
<https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12>.

The app bundle ships [Pandoc](https://github.com/jgm/pandoc) as a separate helper
executable under `Contents/Helpers/pandoc`. Pandoc is © John MacFarlane and licensed
GPL-2.0-or-later; the app runs it as a separate process and is not a derivative work.
Its license text and copyright notice are in the bundle under
`Contents/Resources/Lizenzen/`, and the source tarball of the bundled version is kept in
`build/vendor/pandoc-<version>-src.tar.gz` (offer it alongside any release).
