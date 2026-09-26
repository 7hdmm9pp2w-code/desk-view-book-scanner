# Desk View Book Scanner

Digitize books on the Mac: scan page by page, let the text be recognized, and take
the result along as a searchable PDF, Markdown, Word or EPUB.

Deutsche Fassung: [README.de.md](README.de.md).

## What the app does

You leaf through a book and capture every page, ideally with the iPhone through
Apple's document scanner. The app collects the pages in a **session**, one folder per
book or chapter, and does the rest itself:

1. **Get pages.** Three ways, all ending up in the same session:
   - **iPhone scan** via Continuity Camera: trigger the scan on the iPhone, the page
     appears on the Mac right away. The recommended way for body text.
   - **Import** of existing PDFs and images, for example from Notes, vFlat or Photos.
   - **Camera**: any camera AVFoundation sees, in its largest format. A 4K camera
     above the book gives readable body text; Desk View is limited to 1920 × 1440 and
     is enough for covers, headings and large print. Auto capture takes a page after
     each turn.
2. **Prepare pages.** Every page is rotated upright, a double page is split at the
   gutter into two pages.
3. **Recognize text.** After every capture, macOS text recognition (Vision, German and
   English) runs in the background, entirely on device, no cloud. Paragraphs and
   headings are preserved, hyphenation at line ends is resolved. The app suggests a
   title from the cover.
4. **Export.**
   - **PDF** with the page images and an invisible text layer: searchable, selectable
     and copyable in Preview, exactly where the words are in the image.
   - **Markdown**, **Word** (.docx) and **EPUB** with continuous text across page
     boundaries, handy for further processing, quoting or reading on an e-reader. In
     Markdown a comment marks where each book page begins.

Everything lives as ordinary files on disk: page images as HEIC, recognized text as
JSON next to them, the order in `session.json`. Nothing leaves the Mac.

**Why not just Notes or Prizmo?** They scan well, but they do not give you a book with
paragraph structure as Markdown, Word or EPUB, nor a session folder to come back to
later. That is the core here.

Design notes and the implementation log are in German: [doc/KONZEPT.md](doc/KONZEPT.md),
[doc/UMSETZUNG.md](doc/UMSETZUNG.md).

## Requirements

- Current macOS (27) on Apple silicon
- For the iPhone scan: an iPhone signed in to the same Apple ID, Bluetooth and Wi-Fi
  on (Continuity Camera)
- To build: a Swift toolchain (Xcode or Command Line Tools). There is no Xcode
  project, just a Swift package.

## Details

- **Sources.** *iPhone* (⇧⌘S) opens Apple's document scanner on your iPhone via
  Continuity Camera; the scan lands in the session as pages. *Files* (⇧⌘I) imports PDFs
  and images, for example scans from Notes or vFlat, rendered at their embedded
  resolution. *Camera* (⌥⌘S) grabs a frame from any camera AVFoundation sees, in its
  largest format, with a live preview and an auto-capture mode.
- **Rescan** a page in place (⇧⌘R): the next result from the chosen source replaces
  the selected page; the old one goes to the session's trash.
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

## Camera and resolution

What text recognition needs is pixels per letter. Paperback body text is reliable
from about 20 pixels of line height; below 12 it becomes guesswork. Measured via
AVFoundation, not estimated:

| Source | Real resolution | Enough for |
|---|---|---|
| iPhone document scanner | about 1700 × 2700 per page | body text, the recommended way |
| 4K camera above the book (e.g. Insta360 Link) | 3840 × 2160 | body text, hands-free with auto capture |
| Desk View (Mac or iPhone) | 1920 × 1440, and no more | covers, headings, large print |
| iPhone as a webcam | 1920 × 1440 | same as Desk View |

The Desk View window shows more pixels than the feed has; that is upscaling. And the
feed is not equally sharp everywhere: Desk View crops the lower part of the
ultra-wide image and dewarps it into a top-down view. The far edge of the desk is
stretched the most and is the least sharp; the zone next to the keyboard is the
sharpest. Hence:

- **Put the book close to the Mac**, at the keyboard edge, not in the middle of the desk.
- **Pull the trapezoid tight around the book** in Desk View's setup so the 1920 pixels
  do not cover half the desk.
- **For whole books** use a 4K camera straight above the book, or the iPhone scan.
  Auto capture takes a page after each turn once the image has been still for one and
  a half seconds and differs from the last page.
- A blurry page does not need re-sorting: select it, ⇧⌘R, capture again.

`scripts/ocr_stats.py` prints line heights and confidences per page of a session.

## Build and run

```bash
./build_app.sh --run
```

The script builds `build/DeskViewBookScanner.app`, signs it with the Apple Development
identity in your keychain (ad hoc otherwise) and launches it. The camera source asks for camera
access on first use; the build script signs with the camera entitlement the hardened
runtime requires for that.

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
