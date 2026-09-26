import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import BookScannerKit

/// Weißes Bild mit gesetzten Textzeilen. Liefert die Zeilen samt Sollposition (normiert, unten links).
func renderTextImage(width: Int = 1600, height: Int = 1000, lines: [(text: String, size: CGFloat, y: CGFloat)]) -> (CGImage, [(text: String, box: CGRect)]) {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.textMatrix = .identity
    var boxes: [(String, CGRect)] = []
    for line in lines {
        let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
        let attributed = NSAttributedString(string: line.text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let x: CGFloat = 120
        context.textPosition = CGPoint(x: x, y: line.y)
        CTLineDraw(ctLine, context)
        let bounds = CTLineGetImageBounds(ctLine, context)  // bereits in Nutzerkoordinaten
        let box = CGRect(
            x: bounds.minX / CGFloat(width), y: bounds.minY / CGFloat(height),
            width: bounds.width / CGFloat(width), height: bounds.height / CGFloat(height)
        )
        boxes.append((line.text, box))
    }
    return (context.makeImage()!, boxes)
}

func line(_ text: String, x: CGFloat = 0.1, top: CGFloat, height: CGFloat = 0.02, width: CGFloat = 0.8, confidence: Float = 0.9) -> RecognizedLine {
    RecognizedLine(text: text, confidence: confidence, box: CGRect(x: x, y: top - height, width: width, height: height))
}

func pageText(_ lines: [RecognizedLine]) -> PageText {
    PageText(pageID: UUID(), pixelWidth: 1000, pixelHeight: 1000, languages: ["de-DE"], lines: lines)
}

@Suite struct OCRAndPDFTests {
    @Test func recognizedTextLandsInSearchablePDF() async throws {
        let (image, expected) = renderTextImage(lines: [
            ("Desk View Book Scanner", 64, 800),
            ("Seite eins der Handprobe", 44, 600),
            ("Zweite Zeile mit Wörtern und Umlauten", 44, 500),
        ])
        let lines = try await TextRecognizer().recognize(image)
        let joined = lines.map(\.text).joined(separator: "\n")
        #expect(joined.contains("Handprobe"))
        #expect(joined.contains("Umlauten"))
        #expect(lines.count == 3)
        // Boxen liegen dort, wo gezeichnet wurde (Toleranz: eine Zeilenhöhe).
        for (index, exp) in expected.enumerated() where index < lines.count {
            #expect(abs(lines[index].box.midY - exp.box.midY) < 0.03, "\(lines[index].text)")
        }

        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appending(path: "test.pdf")
        let text = PageText(pageID: UUID(), pixelWidth: image.width, pixelHeight: image.height, languages: ["de-DE"], lines: lines)
        try PDFExporter().export(to: pdfURL, title: "Handprobe", pageCount: 1, load: { _ in (image, text) })

        let document = try #require(PDFDocument(url: pdfURL))
        #expect(document.pageCount == 1)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Handprobe")
        let hits = document.findString("Handprobe", withOptions: [])
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        let page = try #require(hit.pages.first)
        let pageBounds = page.bounds(for: .mediaBox)
        let hitBounds = hit.bounds(for: page)
        // Der Treffer liegt vertikal dort, wo die Zeile im Bild steht.
        let expectedMidY = expected[1].box.midY * pageBounds.height
        #expect(abs(hitBounds.midY - expectedMidY) < pageBounds.height * 0.03)
        #expect(hitBounds.minX > pageBounds.width * 0.05 && hitBounds.maxX < pageBounds.width * 0.95)

        // JPEG eingebettet, nicht verlustfrei aufgebläht.
        let bytes = try Data(contentsOf: pdfURL)
        #expect(bytes.range(of: Data("DCTDecode".utf8)) != nil)
        #expect(bytes.count < 1_500_000)
    }

    @Test func readingOrderSortsRowsThenColumns() {
        let a = line("rechts oben", x: 0.6, top: 0.9, width: 0.3)
        let b = line("links oben", x: 0.1, top: 0.905, width: 0.3)
        let c = line("unten", x: 0.1, top: 0.5)
        #expect(TextRecognizer.readingOrder([c, a, b]).map(\.text) == ["links oben", "rechts oben", "unten"])
    }

    @Test func readingOrderSurvivesSkewedPage() {
        // Schiefe Seite: breite Zeilen mit Boxen, die dreimal so hoch sind wie der Zeilenabstand.
        var lines: [RecognizedLine] = []
        for i in 0..<12 {
            let top = 0.9 - CGFloat(i) * 0.03
            lines.append(line("Zeile \(i)", x: 0.1, top: top, height: 0.09, width: 0.8))
        }
        let shuffled = [lines[5], lines[0], lines[11], lines[3], lines[1], lines[2], lines[4], lines[7], lines[6], lines[9], lines[8], lines[10]]
        #expect(TextRecognizer.readingOrder(shuffled).map(\.text) == (0..<12).map { "Zeile \($0)" })
    }
}

@Suite struct DocumentStructurerTests {
    let checker = SetWordChecker(["Wörter", "Wörtern", "Handprobe"])

    @Test func headingsParagraphsAndHyphenation() {
        let page = pageText([
            line("GOTT UND", top: 0.95, height: 0.06, width: 0.5),
            line("DER STAAT", top: 0.88, height: 0.06, width: 0.5),
            line("Erster Absatz mit Wör-", top: 0.75, width: 0.8),
            line("tern und einem Desk-", top: 0.72, width: 0.8),
            line("View im Text.", top: 0.69, width: 0.4),
            line("Zweiter Absatz nach kurzer Zeile.", top: 0.66, width: 0.8),
            line("Er geht weiter.", top: 0.63, width: 0.8),
            line("Dritter Absatz nach großem Abstand.", top: 0.50, width: 0.8),
            line("Eingerückt beginnt der vierte.", x: 0.14, top: 0.47, width: 0.76),
        ])
        let blocks = DocumentStructurer(wordChecker: checker).structure(page: page)
        #expect(blocks == [
            .heading(level: 1, text: "GOTT UND DER STAAT"),
            .paragraph(text: "Erster Absatz mit Wörtern und einem Desk-View im Text."),
            .paragraph(text: "Zweiter Absatz nach kurzer Zeile. Er geht weiter."),
            .paragraph(text: "Dritter Absatz nach großem Abstand."),
            .paragraph(text: "Eingerückt beginnt der vierte."),
        ])
    }

    @Test func pagesGetBreaks() {
        let doc = DocumentStructurer().structure(pages: [
            (1, pageText([line("Eins", top: 0.9)])),
            (2, pageText([])),
            (3, pageText([line("Drei", top: 0.9)])),
        ], title: "Titel")
        #expect(doc.blocks == [.pageBreak(number: 1), .paragraph(text: "Eins"), .pageBreak(number: 2), .pageBreak(number: 3), .paragraph(text: "Drei")])
    }

    @Test func hyphenRules() {
        let words = SetWordChecker(["Wörter", "Reiches", "Territoriums", "Ein", "und", "Desk", "Vor", "Vorspiegelung"])
        // Bekanntes Ganzes: Strich fällt.
        #expect(DocumentStructurer.join(["Wör-", "ter"], wordChecker: words) == "Wörter")
        // Versalien werden über die Grundform erkannt.
        #expect(DocumentStructurer.join(["des REI-", "CHES jedoch"], wordChecker: words) == "des REICHES jedoch")
        // Großer zweiter Teil: echter Kompositum-Strich bleibt.
        #expect(DocumentStructurer.join(["Desk-", "View"], wordChecker: words) == "Desk-View")
        // Beide Teile eigene Wörter: Strich bleibt (Ergänzungsstrich).
        #expect(DocumentStructurer.join(["Ein-", "und"], wordChecker: words) == "Ein-und")
        // Unbekannte Bruchstücke: zusammenziehen.
        #expect(DocumentStructurer.join(["re-", "ferentielles"], wordChecker: words) == "referentielles")
        // Fehlender Strich im Scan: beide unbekannt, Ganzes bekannt.
        #expect(DocumentStructurer.join(["des Territo", "riums allmählich"], wordChecker: words) == "des Territoriums allmählich")
        // „Vor" ist ein Wort, also kein Zusammenziehen.
        #expect(DocumentStructurer.join(["die Vor", "spiegelung"], wordChecker: words) == "die Vor spiegelung")
        #expect(DocumentStructurer.join(["a", "", "b"], wordChecker: words) == "a b")
        // Ohne Wörterbuch bleibt alles, wie es ist.
        #expect(DocumentStructurer.join(["Wör-", "ter"], wordChecker: NoWordChecker()) == "Wör-ter")
        #expect(DocumentStructurer.join(["Territo", "riums"], wordChecker: NoWordChecker()) == "Territo riums")
    }

    @Test func hardParagraphRules() {
        let page = pageText([
            line("Die Karte ist dem Territorium vorgelagert, sondern in", top: 0.90, height: 0.03, width: 0.8),
            line("unserer Wüste, in der Wüste des Realen selbst.", top: 0.85, width: 0.5),
            line("Auch wenn man sie umkehrt, ist die Fabel heute um je-", top: 0.82, width: 0.8),
            line("den Preis zu retten und der Frage zu entgehen.", top: 0.75, width: 0.8),
        ])
        let blocks = DocumentStructurer().structure(page: page)
        // Zeile 2 beginnt klein: kein Absatzwechsel, obwohl Zeile 1 höher ist. Zeile 3 folgt
        // auf eine kurze Zeile: neuer Absatz. Zeile 4 folgt auf einen Bindestrich: kein
        // Wechsel, obwohl davor eine Lücke liegt.
        #expect(blocks == [
            .paragraph(text: "Die Karte ist dem Territorium vorgelagert, sondern in unserer Wüste, in der Wüste des Realen selbst."),
            .paragraph(text: "Auch wenn man sie umkehrt, ist die Fabel heute um je-den Preis zu retten und der Frage zu entgehen."),
        ])
    }

    @Test func hangingIndentStaysOneParagraph() {
        let page = pageText([
            line("Dissimulation (frz. dissimulation): die Verstellung, die Ver-", x: 0.10, top: 0.9, width: 0.8),
            line("stellungskunst, die Verheimlichung, die Verbergung,", x: 0.16, top: 0.87, width: 0.74),
            line("das Verhehlen, die Verschleierung.", x: 0.16, top: 0.84, width: 0.5),
            line("Simulakrum (frz. simulacre): das Trugbild, das Blendwerk,", x: 0.10, top: 0.81, width: 0.8),
            line("die Fassade, der Schein.", x: 0.16, top: 0.78, width: 0.4),
        ])
        let blocks = DocumentStructurer().structure(page: page)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .paragraph(text: "Dissimulation (frz. dissimulation): die Verstellung, die Ver-stellungskunst, die Verheimlichung, die Verbergung, das Verhehlen, die Verschleierung."))
        #expect(blocks[1] == .paragraph(text: "Simulakrum (frz. simulacre): das Trugbild, das Blendwerk, die Fassade, der Schein."))
    }

    @Test func listPagesKeepOneEntryPerLine() {
        let page = pageText([
            line("INHALT", top: 0.95, width: 0.2),
            line("7 DIE PRÄZESSION DER SIMULAKRA", top: 0.9, width: 0.6),
            line("10 Die göttliche Referenzlosigkeit der Bilder", top: 0.87, width: 0.7),
            line("16 Ramses oder die jungfräuliche Wiederauferstehung", top: 0.84, width: 0.8),
            line("24 Hyperreal und imaginär", top: 0.81, width: 0.5),
            line("Le Système des Objets, Paris 1968", top: 0.7, width: 0.6),
        ])
        let blocks = DocumentStructurer().structure(page: page)
        #expect(blocks == [
            .listItem(text: "INHALT"),
            .listItem(text: "7 DIE PRÄZESSION DER SIMULAKRA"),
            .listItem(text: "10 Die göttliche Referenzlosigkeit der Bilder"),
            .listItem(text: "16 Ramses oder die jungfräuliche Wiederauferstehung"),
            .listItem(text: "24 Hyperreal und imaginär"),
            .listItem(text: "Le Système des Objets, Paris 1968"),
        ])
    }

    @Test func tocTitlesBecomeHeadingsAndCapsHeadingsAreFound() {
        var body: [RecognizedLine] = []
        for i in 0..<12 {
            body.append(line("Fließtextzeile Nummer \(i) mit einigen Wörtern darin.", top: 0.8 - Double(i) * 0.03, width: 0.8))
        }
        let toc = pageText([
            line("INHALT", top: 0.95, width: 0.2),
            line("7 DIE PRÄZESSION DER SIMULAKRA", top: 0.9, width: 0.6),
            line("10 Die göttliche Referenzlosigkeit der Bilder", top: 0.87, width: 0.7),
            line("16 Ramses oder die jungfräuliche Wiederauferstehung", top: 0.84, width: 0.8),
            line("24 Hyperreal und imaginär", top: 0.81, width: 0.5),
            line("26 Der politische Zauber", top: 0.78, width: 0.5),
        ])
        let chapter = pageText([line("DIE PRÄZESSION DER SIMULAKRA", top: 0.95, width: 0.55)] + body)
        let section = pageText([line("Die göttliche Referenzlosigkeit der Bilder", top: 0.95, width: 0.6)] + body)
        let doc = DocumentStructurer().structure(pages: [(1, toc), (2, chapter), (3, section)])
        #expect(doc.blocks.contains(.heading(level: 1, text: "DIE PRÄZESSION DER SIMULAKRA")))
        #expect(doc.blocks.contains(.heading(level: 2, text: "Die göttliche Referenzlosigkeit der Bilder")))
        // Versalienzeile ohne Verzeichnis ist ebenfalls Überschrift.
        let alone = DocumentStructurer().structure(page: pageText([line("DER POLITISCHE ZAUBER", top: 0.95, width: 0.4)] + body))
        #expect(alone.first == .heading(level: 2, text: "DER POLITISCHE ZAUBER"))
    }

    @Test func pageNumbersFootnotesAndCrossPageParagraphs() {
        var body: [RecognizedLine] = []
        for i in 0..<10 {
            body.append(line("Zeile \(i) des Fließtextes, ganz normal gesetzt und lang.", top: 0.85 - Double(i) * 0.03, width: 0.8))
        }
        let pageA = pageText(body + [
            line("auch über-", top: 0.55, width: 0.3),
            line("*vgl. J.L. Borges, Von der Strenge der Wissenschaft", top: 0.30, height: 0.014, width: 0.7),
            line("Ffm-Berlin-Wien 1972, S. 71 (A.d. Ü.)", top: 0.28, height: 0.014, width: 0.5),
            line("7", top: 0.05, width: 0.02),
        ])
        let pageB = pageText([line("8", top: 0.98, width: 0.02)] + [
            line("lebt es sie nicht mehr. Von nun an ist es umgekehrt.", top: 0.85, width: 0.8),
        ] + body.dropFirst())
        let doc = DocumentStructurer().structure(pages: [(1, pageA), (2, pageB)])

        #expect(doc.blocks.first == .pageBreak(number: 1, printed: "7"))
        #expect(doc.blocks.contains(.footnote(text: "*vgl. J.L. Borges, Von der Strenge der Wissenschaft Ffm-Berlin-Wien 1972, S. 71 (A.d. Ü.)")))
        // Der Absatz läuft über die Seitengrenze, der Marker der Seite 8 folgt ihm.
        let joined = doc.blocks.first { if case .paragraph(let t) = $0 { return t.contains("über-lebt es sie") } else { return false } }
        #expect(joined != nil)
        let markerIndex = doc.blocks.firstIndex(of: .pageBreak(number: 2, printed: "8"))
        let joinedIndex = doc.blocks.firstIndex { $0 == joined }
        #expect(markerIndex != nil && joinedIndex != nil && markerIndex! > joinedIndex!)
        #expect(!doc.blocks.contains(.paragraph(text: "7")) && !doc.blocks.contains(.paragraph(text: "8")))
    }

    @Test func uncertainLinesGetANote() {
        let page = pageText([
            line("Geläufig ist, daß etwa die Zerstörung der", top: 0.9, width: 0.8),
            line("Bildröäre eines Fernsehgerätes deren Implosion", top: 0.87, width: 0.8, confidence: 0.3),
            line("zur Folge hat.", top: 0.84, width: 0.3),
        ])
        let blocks = DocumentStructurer().structure(page: page)
        #expect(blocks.first == .note(text: "unsicher: „Bildröäre eines Fernsehgerätes deren Implosion“"))
        #expect(blocks.count == 2)
    }

    @Test func titleFromTallestLines() {
        let page = pageText([
            line("Michail Bakunin", top: 0.9, height: 0.03),
            line("GOTT", top: 0.8, height: 0.08),
            line("UND DER", top: 0.7, height: 0.08),
            line("STAAT", top: 0.6, height: 0.08),
            line("Verlag", top: 0.2, height: 0.02),
        ])
        #expect(TitleSuggester.suggest(from: page) == "GOTT UND DER STAAT")
        #expect(TitleSuggester.suggest(from: pageText([])) == nil)
    }
}

@Suite struct RendererTests {
    let doc = StructuredDocument(title: "Titel & Co", blocks: [
        .pageBreak(number: 1), .heading(level: 1, text: "Kapitel <1>"), .paragraph(text: "Text."),
        .pageBreak(number: 2), .heading(level: 2, text: "Abschnitt"), .paragraph(text: "Mehr."),
    ])

    @Test func markdown() {
        let md = MarkdownRenderer.render(doc)
        #expect(md == "# Titel & Co\n\n<!-- Seite 1 -->\n\n## Kapitel <1>\n\nText.\n\n<!-- Seite 2 -->\n\n### Abschnitt\n\nMehr.\n")
        let extra = StructuredDocument(blocks: [
            .pageBreak(number: 3, printed: "12"), .listItem(text: "eins"), .listItem(text: "zwei"),
            .note(text: "unsicher: „x“"), .paragraph(text: "Absatz"), .footnote(text: "*Fußnote"),
        ])
        #expect(MarkdownRenderer.render(extra) == "<!-- Seite 12, Scan 3 -->\n\n- eins\n- zwei\n\n<!-- unsicher: „x“ -->\n\nAbsatz\n\n<small>*Fußnote</small>\n")
        #expect(PageMarker.restore(in: "@@SEITE 3 S12@@ und \\@@NOTIZ unsicher: „x“@@") == "<!-- Seite 12, Scan 3 --> und <!-- unsicher: „x“ -->")
    }

    @Test func html() {
        let html = HTMLRenderer.render(doc)
        #expect(html.contains("<title>Titel &amp; Co</title>"))
        #expect(html.contains("<h2>Kapitel &lt;1&gt;</h2>"))
        #expect(html.contains("<p>@@SEITE 2@@</p>"))
        #expect(PageMarker.restore(in: "x\n\n@@SEITE 12@@\n\ny \\@@SEITE 3@@") == "x\n\n<!-- Seite 12 -->\n\ny <!-- Seite 3 -->")
    }

    @Test func exportWithoutPandocWritesMarkdown() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "a.md")
        try TextExporter.export(doc, to: url, format: .markdown, pandoc: nil)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("# Titel & Co"))
        #expect(throws: ExportError.self) {
            try TextExporter.export(doc, to: root.appending(path: "a.docx"), format: .docx, pandoc: nil)
        }
    }

    @Test func exportWithPandocIfInstalled() throws {
        guard let pandoc = Pandoc.locate() else {
            print("Pandoc nicht installiert, Test übersprungen")
            return
        }
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let md = root.appending(path: "p.md")
        try TextExporter.export(doc, to: md, format: .markdown, pandoc: pandoc)
        let text = try String(contentsOf: md, encoding: .utf8)
        #expect(text.contains("## Kapitel \\<1\\>") || text.contains("## Kapitel <1>"))
        #expect(text.contains("<!-- Seite 1 -->") && text.contains("<!-- Seite 2 -->"))
        #expect(!text.contains("@@SEITE"))
        let docx = root.appending(path: "p.docx")
        try TextExporter.export(doc, to: docx, format: .docx, pandoc: pandoc)
        #expect(((try? Data(contentsOf: docx))?.count ?? 0) > 1000)
        #expect(pandoc.version()?.hasPrefix("pandoc") == true)
    }

    @Test func exportFileName() {
        let date = Date(timeIntervalSince1970: 1_790_420_502)  // 26.09.2026 13:01 Berlin
        let name = ExportNaming.fileName(createdAt: date, title: "Gott und der Staat", fileExtension: "pdf")
        #expect(name.hasPrefix("Buchscan 2026-09-26 ") && name.hasSuffix(" Gott und der Staat.pdf"))
        #expect(ExportNaming.fileName(createdAt: date, title: nil, fileExtension: "md").hasSuffix(".md"))
    }
}

@Suite struct SessionTextTests {
    @Test func textIsStoredNextToPageAndTrashedWithIt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let page = try await store.addPage(makeTestImage(width: 10, height: 10))
        #expect(try await store.loadText(for: page) == nil)

        let text = pageText([line("Hallo", top: 0.9)])
        try await store.saveText(text, for: page)
        #expect(try await store.loadText(for: page)?.lines.first?.text == "Hallo")
        #expect(await store.orderedPages.first?.ocrStatus == .done)
        #expect(FileManager.default.fileExists(atPath: await store.textDirectory.appending(path: "Aufnahme-0001.json").path))

        try await store.trash(pageIDs: [page.id])
        #expect(FileManager.default.fileExists(atPath: await store.trashDirectory.appending(path: "Aufnahme-0001.json").path))
    }

    @Test func oldTextFilesGetReorderedOnLoad() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let page = try await store.addPage(makeTestImage(width: 10, height: 10))
        var old = pageText([line("unten", top: 0.3, height: 0.09), line("oben", top: 0.9, height: 0.09)])
        old.version = 1
        try await store.saveText(old, for: page)

        let loaded = try #require(try await store.loadText(for: page))
        #expect(loaded.version == PageText.currentVersion)
        #expect(loaded.lines.map(\.text) == ["oben", "unten"])
        // Auf der Platte liegt jetzt die neue Fassung.
        let again = try #require(try await store.loadText(for: page))
        #expect(again == loaded)
    }

    @Test func processorRecognizesOnceAndCaches() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let (image, _) = renderTextImage(width: 800, height: 400, lines: [("Prozessor Test", 48, 200)])
        let page = try await store.addPage(image)
        let processor = PageProcessor()
        let first = try await processor.text(for: page, in: store)
        #expect(first.plainText.contains("Prozessor"))
        let second = try await processor.text(for: page, in: store)
        #expect(first == second)
    }
}
