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

        // Zeilen bleiben bei der Textextraktion getrennt: kein „HandprobeZweite".
        let extracted = document.page(at: 0)?.string ?? ""
        #expect(extracted.contains("Handprobe"))
        #expect(!extracted.contains("HandprobeZweite"))
        #expect(document.findString("Zweite Zeile", withOptions: []).count == 1)

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
        // Breiten wie im Buch: Fließtext rund 0,012 je Zeichen, Titelzeilen fünfmal so viel.
        let page = pageText([
            line("GOTT UND", top: 0.95, height: 0.06, width: 0.5),
            line("DER STAAT", top: 0.88, height: 0.06, width: 0.5),
            line("Erster Absatz mit Wörtern über die ganze Breite der Seite, Wör-", top: 0.75, width: 0.8),
            line("tern und einem Bindestrich am Zeilenende wie bei Desk-", top: 0.72, width: 0.7),
            line("View im Text.", top: 0.69, width: 0.16),
            line("Zweiter Absatz nach kurzer Zeile, der über die ganze Breite geht.", top: 0.66, width: 0.8),
            line("Er geht weiter und weiter bis zum Ende der Zeile, ja bis dahin.", top: 0.63, width: 0.8),
            line("Dritter Absatz nach großem Abstand, ebenfalls über die ganze Breite.", top: 0.50, width: 0.8),
            line("Eingerückt beginnt der vierte Absatz und läuft bis zum Rand.", x: 0.14, top: 0.47, width: 0.76),
        ])
        let blocks = DocumentStructurer(wordChecker: checker).structure(page: page)
        #expect(blocks == [
            .heading(level: 1, text: "GOTT UND DER STAAT"),
            .paragraph(text: "Erster Absatz mit Wörtern über die ganze Breite der Seite, Wörtern und einem Bindestrich am Zeilenende wie bei Desk-View im Text."),
            .paragraph(text: "Zweiter Absatz nach kurzer Zeile, der über die ganze Breite geht. Er geht weiter und weiter bis zum Ende der Zeile, ja bis dahin."),
            .paragraph(text: "Dritter Absatz nach großem Abstand, ebenfalls über die ganze Breite."),
            .paragraph(text: "Eingerückt beginnt der vierte Absatz und läuft bis zum Rand."),
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
        // Silbentrennung: der Strich fällt, ohne Wörterbuch zu fragen.
        #expect(DocumentStructurer.join(["Wör-", "ter"], wordChecker: words) == "Wörter")
        #expect(DocumentStructurer.join(["Unbe-", "kannt"], wordChecker: words) == "Unbekannt")
        // Versalien getrennt: „REI-" + „CHES", „UN-" + „TERWELT" werden ein Wort.
        #expect(DocumentStructurer.join(["des REI-", "CHES jedoch"], wordChecker: words) == "des REICHES jedoch")
        #expect(DocumentStructurer.join(["zurück in die UN-", "TERWELT."], wordChecker: words) == "zurück in die UNTERWELT.")
        // Großer zweiter Teil: echter Kompositum-Strich bleibt.
        #expect(DocumentStructurer.join(["Desk-", "View"], wordChecker: words) == "Desk-View")
        // Ergänzungsstrich vor „und": Strich bleibt, Leerzeichen dazu.
        #expect(DocumentStructurer.join(["Ein-", "und Zusammenbruch"], wordChecker: words) == "Ein- und Zusammenbruch")
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

    /// Fließtextzeilen mit eigenem Wortlaut je Seite, damit die Duplikat-Erkennung nicht anspringt.
    func bodyLines(_ tag: String, count: Int = 12, top: CGFloat = 0.8) -> [RecognizedLine] {
        (0..<count).map { i in
            line("\(tag), Zeile \(i) des Fließtextes mit genügend Zeichen für den Vergleich.", top: top - CGFloat(i) * 0.03, width: 0.8)
        }
    }

    @Test func tocTitlesBecomeHeadingsAndCapsHeadingsAreFound() {
        let toc = pageText([
            line("INHALT", top: 0.95, width: 0.2),
            line("7 DIE PRÄZESSION DER SIMULAKRA", top: 0.9, width: 0.6),
            line("10 Die göttliche Referenzlosigkeit der Bilder", top: 0.87, width: 0.7),
            line("16 Ramses oder die jungfräuliche Wiederauferstehung", top: 0.84, width: 0.8),
            line("24 Hyperreal und imaginär", top: 0.81, width: 0.5),
            line("26 Der politische Zauber", top: 0.78, width: 0.5),
        ])
        let chapter = pageText([line("DIE PRÄZESSION DER SIMULAKRA", top: 0.95, width: 0.55)] + bodyLines("Kapitel"))
        let section = pageText([line("Die göttliche Referenzlosigkeit der Bilder", top: 0.95, width: 0.6)] + bodyLines("Abschnitt"))
        let doc = DocumentStructurer().structure(pages: [(1, toc), (2, chapter), (3, section)])
        #expect(doc.blocks.contains(.heading(level: 1, text: "DIE PRÄZESSION DER SIMULAKRA")))
        #expect(doc.blocks.contains(.heading(level: 2, text: "Die göttliche Referenzlosigkeit der Bilder")))
        // Versalienzeile ohne Verzeichnis ist ebenfalls Überschrift; Schrott wie „BOROPE /" nicht.
        let alone = DocumentStructurer().structure(page: pageText([line("DER POLITISCHE ZAUBER", top: 0.95, width: 0.4)] + bodyLines("Allein")))
        #expect(alone.first == .heading(level: 2, text: "DER POLITISCHE ZAUBER"))
        let junk = DocumentStructurer().structure(page: pageText([line("BOROPE /", top: 0.95, width: 0.15)] + bodyLines("Schrott")))
        #expect(junk.first == .paragraph(text: "BOROPE /"))
        let digits = DocumentStructurer().structure(page: pageText([line("AE000 1 2H0N0 S0NY RE", top: 0.95, width: 0.3)] + bodyLines("Ziffern")))
        #expect(digits.first == .paragraph(text: "AE000 1 2H0N0 S0NY RE"))
    }

    @Test func pageNumbersFootnotesAndCrossPageParagraphs() {
        let pageA = pageText(bodyLines("Seite sieben", count: 10, top: 0.85) + [
            line("auch über-", top: 0.55, width: 0.12),
            line("*vgl. J.L. Borges, Von der Strenge der Wissenschaft", top: 0.30, height: 0.014, width: 0.4),
            line("Ffm-Berlin-Wien 1972, S. 71 (A.d. Ü.)", top: 0.28, height: 0.014, width: 0.28),
            line("7", top: 0.05, width: 0.02),
        ])
        let pageB = pageText([line("8", top: 0.98, width: 0.02)] + [
            line("lebt es sie nicht mehr. Von nun an ist es umgekehrt.", top: 0.85, width: 0.8),
        ] + bodyLines("Seite acht", count: 9, top: 0.82))
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

    @Test func falseHeadingsAndFootnotesFromTheBook() {
        let body = bodyLines("Buch", count: 10, top: 0.9)
        // Zeile nach Bindestrich, Versalien, kurz: trotzdem Fließtext („UN-" / „TERWELT.").
        let page1 = pageText(body + [
            line("Wissenschaft stets zu früh um und kehrt zurück in die UN-", top: 0.6, width: 0.8),
            line("TERWELT.", top: 0.57, height: 0.03, width: 0.15),
            line("Die Ethnologen wollten dieser Hölle entgehen.", top: 0.54, width: 0.8),
        ])
        let blocks1 = DocumentStructurer().structure(page: page1)
        #expect(!blocks1.contains { if case .heading = $0 { return true } else { return false } })
        // Hohe Zeile, aber die nächste beginnt klein: Fließtext.
        let page2 = pageText(body + [
            line("Wenig später machen es die Jesuiten genauso: sie", top: 0.6, height: 0.03, width: 0.7),
            line("begründen ihre Politik auf dem Verschwinden GOTTES.", top: 0.57, width: 0.8),
        ])
        #expect(!DocumentStructurer().structure(page: page2).contains { if case .heading = $0 { return true } else { return false } })
        // Fußnote mit Marke ist kleiner und steht unten; ein kleines Absatzende bleibt Absatz.
        let page3 = pageText(body + [
            line("auch über-", top: 0.6, width: 0.3),
            line("*vgl. J.L. Borges, Von der Strenge der Wissenschaft, in:", top: 0.3, height: 0.017, width: 0.5),
            line("Universalgeschichte der Niedertracht, Ffm 1972, S. 71", top: 0.28, height: 0.017, width: 0.45),
        ])
        let blocks3 = DocumentStructurer().structure(page: page3)
        #expect(blocks3.last == .footnote(text: "*vgl. J.L. Borges, Von der Strenge der Wissenschaft, in: Universalgeschichte der Niedertracht, Ffm 1972, S. 71"))
        #expect(blocks3.count == 2)
        let page4 = pageText(body + [line("stellen?", top: 0.6, height: 0.016, width: 0.1)])
        #expect(!DocumentStructurer().structure(page: page4).contains { if case .footnote = $0 { return true } else { return false } })
    }

    @Test func sameSizeFootnotesAreFoundByMarkerAndPosition() {
        // Merve: Fußnote in Fließtextgröße, nur „*" und Lage am Seitenende verraten sie.
        let body = bodyLines("Sieben", count: 12, top: 0.9)
        let page = pageText(body + [
            line("ist der Karte nicht mehr vorgelagert, auch über-", top: 0.54, width: 0.6),
            line("*vgl, J. L. Borges, Von der Strenge der Wissenschaft,", top: 0.50, width: 0.66),
            line("in: Universalgeschichte der Niedertracht und andere", top: 0.47, width: 0.64),
            line("Prosastücke, Ffm-Berlin-Wien 1972, S. 71 (A.d. Ü.)", top: 0.44, width: 0.62),
        ])
        let blocks = DocumentStructurer().structure(page: page)
        #expect(blocks.last == .footnote(text: "*vgl, J. L. Borges, Von der Strenge der Wissenschaft, in: Universalgeschichte der Niedertracht und andere Prosastücke, Ffm-Berlin-Wien 1972, S. 71 (A.d. Ü.)"))
        #expect(blocks.contains { if case .paragraph(let t) = $0 { return t.hasSuffix("auch über-") } else { return false } })
        // Dieselbe Marke oben auf der Seite ist keine Fußnote.
        let top = pageText([line("*Arbeitslose sind hier gemeint, nicht Beschäftigte.", top: 0.95, width: 0.7)] + bodyLines("Oben", count: 12, top: 0.9))
        #expect(!DocumentStructurer().structure(page: top).contains { if case .footnote = $0 { return true } else { return false } })
        // Und der Absatz läuft über die Seitengrenze, an der Fußnote vorbei.
        let next = pageText([line("lebt es sie nicht mehr. Von nun an ist es umgekehrt.", top: 0.9, width: 0.8)] + bodyLines("Acht", count: 10, top: 0.87))
        let doc = DocumentStructurer().structure(pages: [(7, page), (8, next)])
        #expect(doc.blocks.contains { if case .paragraph(let t) = $0 { return t.contains("auch über-lebt es sie") || t.contains("auch überlebt es sie") } else { return false } })
    }

    @Test func footnoteContinuationLinesAndPages() {
        let page = pageText(bodyLines("Sechzehn", count: 12, top: 0.9) + [
            line("* in: John Nance, \"The Gentle Tasadays\", London", top: 0.50, width: 0.62),
            line("1975 (A.d. R.)", top: 0.47, width: 0.18),
        ])
        let blocks = DocumentStructurer().structure(page: page)
        #expect(blocks.last == .footnote(text: "* in: John Nance, \"The Gentle Tasadays\", London 1975 (A.d. R.)"))
        #expect(blocks.filter { if case .footnote = $0 { return true } else { return false } }.count == 1)

        // Fußnote (1) endet offen und geht auf der nächsten Seite klein weiter.
        let pageA = pageText(bodyLines("Zweiundachtzig", count: 12, top: 0.9) + [
            line("(1) Die Dinge liegen natürlich anders, denn das Proletariat hat sich von", top: 0.50, width: 0.8),
        ])
        let pageB = pageText([line("nun an den Kommunisten die Ausübung der Politik verboten.", top: 0.9, width: 0.7)] + bodyLines("Dreiundachtzig", count: 10, top: 0.75))
        let doc = DocumentStructurer().structure(pages: [(82, pageA), (83, pageB)])
        #expect(doc.blocks.contains(.footnote(text: "(1) Die Dinge liegen natürlich anders, denn das Proletariat hat sich von nun an den Kommunisten die Ausübung der Politik verboten.")))
        #expect(!doc.blocks.contains { if case .paragraph(let t) = $0 { return t.hasPrefix("nun an") } else { return false } })
    }

    @Test func duplicateScansAreSkippedAndContinuationCrossesEmptyPages() {
        let pageA = pageText(bodyLines("Elf", top: 0.9) + [line("sein eigenes Simu-", top: 0.5, width: 0.3)])
        let empty = pageText([])
        let pageB = pageText([line("lakrum existiert hat. Von daher ihre Wut.", top: 0.9, width: 0.8)] + bodyLines("Dreizehn", count: 11, top: 0.87))
        let doc = DocumentStructurer().structure(pages: [(1, pageA), (2, empty), (3, pageB), (4, pageB)])
        #expect(doc.blocks.contains { if case .paragraph(let t) = $0 { return t.contains("Simu-lakrum existiert") } else { return false } })
        #expect(doc.blocks.contains(.note(text: "Scan 4 ist ein Duplikat von Scan 3 und wurde übersprungen")))
        #expect(doc.blocks.filter { if case .paragraph(let t) = $0 { return t.contains("Von daher ihre Wut") } else { return false } }.count == 1)
    }

    @Test func inlineHyphensAreRepaired() {
        let words = SetWordChecker(["einer", "Theorie", "Theo", "Immo", "ral", "nichtig", "kitschigen", "Stammes", "und", "el", "ner"])
        // Kurze Teile zählen nicht als Wörter, auch wenn das Wörterbuch sie „kennt".
        #expect(DocumentStructurer.repairInlineHyphens(in: "Effekts, el-ner Energie und der Theo-rie", wordChecker: words) == "Effekts, elner Energie und der Theorie")
        #expect(DocumentStructurer.repairInlineHyphens(in: "der Immo-ral, der nichtig-kitschigen Stammes-und", wordChecker: words) == "der Immoral, der nichtig-kitschigen Stammes-und")
        #expect(DocumentStructurer.repairInlineHyphens(in: "Desk-View bleibt", wordChecker: words) == "Desk-View bleibt")
        #expect(DocumentStructurer.repairInlineHyphens(in: "el-ner", wordChecker: NoWordChecker()) == "el-ner")
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
            line("Michail Bakunin", top: 0.9, height: 0.03, width: 0.45),
            line("GOTT", top: 0.8, height: 0.08, width: 0.32),
            line("UND DER", top: 0.7, height: 0.08, width: 0.56),
            line("STAAT", top: 0.6, height: 0.08, width: 0.4),
            line("Verlag", top: 0.2, height: 0.02, width: 0.12),
        ])
        #expect(TitleSuggester.suggest(from: page) == "GOTT UND DER STAAT")
        #expect(TitleSuggester.suggest(from: pageText([])) == nil)
        // Textseite: alle Zeilen gleich hoch, kein Vorschlag.
        let body = pageText((0..<8).map { line("die aufgrund von objektiven Tatsachen \($0)", top: 0.9 - Double($0) * 0.04) })
        #expect(TitleSuggester.suggest(from: body) == nil)
        // Titelseite wiederholt den Autor: er kommt davor.
        let titlePage = pageText([line("Michail Bakunin", top: 0.9), line("Gott und der Staat", top: 0.8), line("Merve Verlag Berlin", top: 0.3)])
        #expect(TitleSuggester.suggest(cover: page, followingPages: [titlePage]) == "Michail Bakunin – GOTT UND DER STAAT")
    }

    @Test func titleIgnoresPublisherAndSplitsRecurringLines() {
        // Baudrillard-Umschlag: Verlag ist die größte Zeile.
        let cover = pageText([
            line("Jean Baudrillard", top: 0.75, height: 0.05, width: 0.5),
            line("Agonie des Realen", top: 0.69, height: 0.05, width: 0.5),
            line("Merve Verlag Berlin", top: 0.25, height: 0.07, width: 0.6),
        ])
        #expect(TitleSuggester.suggest(from: cover) == "Jean Baudrillard Agonie des Realen")
        let titlePage = pageText([
            line("Jean Baudrillard", top: 0.9), line("Agonie des Realen", top: 0.86),
            line("Aus dem Französischen übersetzt von", top: 0.8), line("Merve Verlag Berlin", top: 0.7),
        ])
        let bio = pageText([line("Jean Baudrillard, 1929 in Reims geboren, ist Professor", top: 0.9)])
        #expect(TitleSuggester.suggest(cover: cover, followingPages: [bio, titlePage]) == "Jean Baudrillard – Agonie des Realen")
        #expect(TitleSuggester.isExcluded("© 1978 by Merve Verlag GmbH"))
        #expect(TitleSuggester.isExcluded("Paris 1968"))
        #expect(!TitleSuggester.isExcluded("Agonie des Realen"))
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
        #expect(MarkdownRenderer.render(extra) == "<!-- Seite 12, Scan 3 -->\n\n- eins\n- zwei\n\n<!-- unsicher: „x“ -->\n\nAbsatz\n\n> *Fußnote\n")
        #expect(PageMarker.restore(in: "@@SEITE 3 S12@@ und \\@@NOTIZ unsicher: „x“@@") == "<!-- Seite 12, Scan 3 --> und <!-- unsicher: „x“ -->")
    }

    @Test func html() {
        let html = HTMLRenderer.render(doc)
        #expect(html.contains("<title>Titel &amp; Co</title>"))
        #expect(html.contains("<h2>Kapitel &lt;1&gt;</h2>"))
        #expect(html.contains("<p>@@SEITE 2@@</p>"))
        #expect(PageMarker.restore(in: "x\n\n@@SEITE 12@@\n\ny \\@@SEITE 3@@") == "x\n\n<!-- Seite 12 -->\n\ny <!-- Seite 3 -->")
    }

    @Test func commentsMarkerStyleForDocxAndEpub() {
        let html = HTMLRenderer.render(doc, markers: .comments)
        #expect(!html.contains("@@SEITE"))
        #expect(html.contains("<!-- Seite 1 -->"))
        let withNote = StructuredDocument(blocks: [.note(text: "unsicher: „x“")])
        #expect(HTMLRenderer.render(withNote, markers: .comments).contains("<!-- unsicher: „x“ -->"))
        #expect(!HTMLRenderer.render(withNote, markers: .comments).contains("@@NOTIZ"))
    }

    @Test func coverHeadingsAreDemotedWhenTheyRepeatTheTitle() {
        let cover = pageText([
            line("Jean Baudrillard", top: 0.75, height: 0.05, width: 0.5),
            line("Agonie des Realen", top: 0.69, height: 0.05, width: 0.5),
            line("Merve Verlag Berlin", top: 0.25, height: 0.09, width: 0.6),
            line("Klein gesetzte Zeile eins mit vielen Zeichen darin, ja.", top: 0.15, height: 0.02, width: 0.6),
            line("Klein gesetzte Zeile zwei mit vielen Zeichen darin, ja.", top: 0.12, height: 0.02, width: 0.6),
            line("Klein gesetzte Zeile drei mit vielen Zeichen darin, ja.", top: 0.09, height: 0.02, width: 0.6),
            line("Klein gesetzte Zeile vier mit vielen Zeichen darin, ja.", top: 0.06, height: 0.02, width: 0.6),
        ])
        let doc = DocumentStructurer().structure(pages: [(1, cover)], title: "Jean Baudrillard – Agonie des Realen")
        #expect(!doc.blocks.contains { if case .heading = $0 { return true } else { return false } })
        let untitled = DocumentStructurer().structure(pages: [(1, cover)], title: nil)
        #expect(untitled.blocks.contains { if case .heading = $0 { return true } else { return false } })
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
        #expect(ExportNaming.fileName(createdAt: date, title: "Jean Baudrillard – Agonie des Realen", fileExtension: "pdf") == "Jean Baudrillard – Agonie des Realen.pdf")
        let plain = ExportNaming.fileName(createdAt: date, title: nil, fileExtension: "md")
        #expect(plain.hasPrefix("Buchscan 2026-09-26 ") && plain.hasSuffix(".md"))
        #expect(ExportNaming.fileName(createdAt: date, title: "  ", fileExtension: "md") == plain)
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
