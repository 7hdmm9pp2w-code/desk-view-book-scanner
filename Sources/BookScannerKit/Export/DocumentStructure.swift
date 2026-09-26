import Foundation
import CoreGraphics

public enum DocumentBlock: Equatable, Sendable {
    /// `number` ist die Scan-Nummer, `printed` die im Buch gedruckte Seitenzahl, falls erkannt.
    case pageBreak(number: Int, printed: String? = nil)
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case listItem(text: String)
    case footnote(text: String)
    /// Hinweis für den Leser der Quelle, etwa unsichere OCR-Zeilen.
    case note(text: String)
}

public struct StructuredDocument: Equatable, Sendable {
    public var title: String?
    public var blocks: [DocumentBlock]

    public init(title: String? = nil, blocks: [DocumentBlock] = []) {
        self.title = title
        self.blocks = blocks
    }
}

/// Entscheidet, ob eine Zeichenkette ein Wort ist. Für die Silbentrennung.
public protocol WordChecker: Sendable {
    func isWord(_ word: String) -> Bool
    /// `false`, wenn gar kein Wörterbuch dahintersteht; dann bleiben Bindestriche stehen.
    var hasDictionary: Bool { get }
}

extension WordChecker {
    public var hasDictionary: Bool { true }
}

/// Kennt kein Wort; Bindestriche bleiben stehen.
public struct NoWordChecker: WordChecker {
    public init() {}
    public func isWord(_ word: String) -> Bool { false }
    public var hasDictionary: Bool { false }
}

/// Feste Wortliste, für Tests und Werkzeuge ohne AppKit.
public struct SetWordChecker: WordChecker {
    public let words: Set<String>
    public init(_ words: Set<String>) { self.words = words }
    public func isWord(_ word: String) -> Bool { words.contains(word) }
}

extension WordChecker {
    /// Wörterbuchabfrage unabhängig von Groß- und Kleinschreibung: „REICHES" → „Reiches".
    func knows(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        if isWord(word) { return true }
        let lower = word.lowercased()
        if lower != word, isWord(lower) { return true }
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        return capitalized != word && isWord(capitalized)
    }
}

/// Baut aus OCR-Zeilen Absätze, Überschriften, Listen und Fußnoten. Nur Geometrie
/// und einfache Textmerkmale, keine Sprachanalyse. Typografie (Zeilenhöhe,
/// Zeilenabstand) wird über das ganze Dokument gemessen, weil einzelne Seiten wie
/// Umschlag oder Inhaltsverzeichnis zu wenig Zeilen für eine eigene Statistik haben.
public struct DocumentStructurer: Sendable {
    public var wordChecker: any WordChecker
    /// Zeilen mit Boxhöhe über diesem Vielfachen der mittleren Höhe sind Überschriften.
    public var headingRatio = 1.45
    /// Darüber Überschrift 1. Ebene statt 2.
    public var majorHeadingRatio = 2.2
    /// Abstand zwischen Zeilen über diesem Vielfachen des üblichen Zeilenabstands trennt Absätze.
    public var paragraphGapRatio = 1.6
    /// Einzug der ersten Zeile über diesem Vielfachen der Zeilenhöhe beginnt einen Absatz.
    public var indentRatio = 1.0
    /// Endet eine Zeile deutlich vor dem rechten Rand (Anteil der Textbreite), endet der Absatz.
    public var shortLineRatio = 0.15
    /// Zeilen am Seitenende, deren Höhe unter diesem Anteil der mittleren Höhe liegt, sind Fußnoten.
    public var footnoteRatio = 0.82
    /// Zeilen unter dieser Konfidenz werden als unsicher gemeldet.
    public var uncertainConfidence: Float = 0.5
    /// Ab so vielen Zeilen taugt die Dokumentstatistik; sonst pro Seite.
    public var minimumLinesForDocumentStats = 20

    public init(wordChecker: any WordChecker = NoWordChecker()) {
        self.wordChecker = wordChecker
    }

    // MARK: Dokument

    public func structure(pages: [(number: Int, text: PageText)], title: String? = nil) -> StructuredDocument {
        let stats = Typography(pages: pages.map(\.text), minimumLines: minimumLinesForDocumentStats)
        let tocTitles = tableOfContentsTitles(pages: pages.map(\.text))

        var blocks: [DocumentBlock] = []
        for page in pages {
            let analysis = analyze(page: page.text, stats: stats, tocTitles: tocTitles)
            let marker = DocumentBlock.pageBreak(number: page.number, printed: analysis.printedNumber)

            var pageBlocks = analysis.blocks
            // Absatz über die Seitengrenze fortsetzen (Fußnoten der alten Seite dürfen
            // dazwischen stehen): der Marker rückt dann hinter den fortgesetzten Absatz.
            let firstIndex = pageBlocks.firstIndex { if case .note = $0 { return false } else { return true } } ?? pageBlocks.endIndex
            if firstIndex < pageBlocks.endIndex,
               case .paragraph(let first) = pageBlocks[firstIndex],
               let lastIndex = Self.lastOpenParagraphIndex(in: blocks),
               case .paragraph(let previous) = blocks[lastIndex],
               Self.continues(previous, with: first) {
                blocks[lastIndex] = .paragraph(text: Self.join([previous, first], wordChecker: wordChecker))
                pageBlocks.remove(at: firstIndex)
                blocks.append(marker)
            } else {
                blocks.append(marker)
            }
            blocks.append(contentsOf: pageBlocks)
        }
        return StructuredDocument(title: title, blocks: blocks)
    }

    /// Letzter Absatz, hinter dem nur noch Fußnoten oder Notizen stehen.
    static func lastOpenParagraphIndex(in blocks: [DocumentBlock]) -> Int? {
        var index = blocks.count - 1
        while index >= 0 {
            switch blocks[index] {
            case .footnote, .note: index -= 1
            case .paragraph: return index
            default: return nil
            }
        }
        return nil
    }

    /// Endet ein Absatz offen (Bindestrich oder kein Satzende) und beginnt der nächste klein?
    static func continues(_ previous: String, with next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        if last == "-" || last == "\u{2010}" { return true }
        let sentenceEnd: Set<Character> = [".", "!", "?", ":", "\u{201C}", "\u{201D}", "\"", "'", ")", "\u{2019}"]
        return !sentenceEnd.contains(last) && first.isLowercase
    }

    // MARK: Eine Seite

    private enum Kind: Equatable { case heading(Int), body, listItem, footnote }

    struct PageAnalysis {
        var blocks: [DocumentBlock]
        var printedNumber: String?
    }

    public func structure(page: PageText) -> [DocumentBlock] {
        let stats = Typography(pages: [page], minimumLines: minimumLinesForDocumentStats)
        return analyze(page: page, stats: stats, tocTitles: []).blocks
    }

    func analyze(page: PageText, stats: Typography, tocTitles: Set<String>) -> PageAnalysis {
        var lines = page.lines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return PageAnalysis(blocks: [], printedNumber: nil) }

        // Gedruckte Seitenzahl: reine Ziffernzeile ganz oben oder ganz unten.
        var printed: String?
        if let index = Self.pageNumberIndex(in: lines) {
            printed = lines[index].text.trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
            lines.remove(at: index)
        }
        guard !lines.isEmpty else { return PageAnalysis(blocks: [], printedNumber: printed) }

        let pageStats = Typography(pages: [page], minimumLines: 1)
        let medianHeight = stats.medianHeight ?? pageStats.medianHeight ?? 0.02
        let pitch = stats.pitch ?? pageStats.pitch ?? medianHeight * 1.3
        let lefts = lines.map(\.box.minX).sorted()
        let rights = lines.map(\.box.maxX).sorted()
        let leftEdge = lefts[lefts.count / 10]
        let rightEdge = rights[min(rights.count - 1, rights.count * 9 / 10)]
        let textWidth = max(rightEdge - leftEdge, 0.01)
        let isListPage = Self.isListPage(lines)

        // Fußnoten: kleinere Zeilen am Seitenende unter normal großem Text.
        var footnoteStart = lines.count
        if !isListPage {
            var i = lines.count - 1
            while i > 0, lines[i].box.height < medianHeight * footnoteRatio { i -= 1 }
            if i < lines.count - 1, lines[..<(i + 1)].contains(where: { $0.box.height >= medianHeight * 0.9 }) {
                footnoteStart = i + 1
            }
        }

        // Zeilenarten
        var kinds: [Kind] = []
        for (index, line) in lines.enumerated() {
            if index >= footnoteStart { kinds.append(.footnote); continue }
            if isListPage { kinds.append(.listItem); continue }
            let ratio = line.box.height / medianHeight
            let startsLower = line.text.first.map { $0.isLetter && $0.isLowercase } ?? false
            let endsHyphen = line.text.last == "-" || line.text.last == "\u{2010}"
            let short = line.box.width < textWidth * 0.7
            let gapBefore = index > 0 ? lines[index - 1].box.midY - line.box.midY : 0
            let gapAfter = index + 1 < lines.count ? line.box.midY - lines[index + 1].box.midY : 0
            let spaced = gapBefore > pitch * 1.5 || gapAfter > pitch * 1.5
            let matchesToc = tocTitles.contains(Self.normalized(line.text))
            let allCaps = Self.isAllCaps(line.text)

            if !startsLower, !endsHyphen, !Self.startsWithNumber(line.text) {
                if ratio > majorHeadingRatio, short || spaced {
                    kinds.append(.heading(1)); continue
                }
                if ratio > headingRatio, short || spaced {
                    kinds.append(.heading(2)); continue
                }
                if matchesToc {
                    kinds.append(.heading(allCaps ? 1 : 2)); continue
                }
                if allCaps, short, line.text.count >= 4 {
                    kinds.append(.heading(2)); continue
                }
            }
            kinds.append(.body)
        }

        // Mehrzeilige Überschriften aus dem Inhaltsverzeichnis: zwei kurze Zeilen zusammen.
        if !tocTitles.isEmpty {
            for index in 0..<(lines.count - 1) where kinds[index] == .body && kinds[index + 1] == .body {
                let combined = Self.normalized(lines[index].text + " " + lines[index + 1].text)
                if tocTitles.contains(combined) {
                    let level = Self.isAllCaps(lines[index].text) ? 1 : 2
                    kinds[index] = .heading(level)
                    kinds[index + 1] = .heading(level)
                }
            }
        }

        // Blöcke
        var blocks: [DocumentBlock] = []
        var currentKind: Kind?
        var currentLines: [RecognizedLine] = []

        func flush() {
            let text = Self.join(currentLines.map(\.text), wordChecker: wordChecker)
            if !text.isEmpty, let kind = currentKind {
                let uncertain = currentLines.filter { $0.confidence < uncertainConfidence }.map(\.text)
                if !uncertain.isEmpty {
                    blocks.append(.note(text: "unsicher: " + uncertain.map { "„\($0)“" }.joined(separator: ", ")))
                }
                switch kind {
                case .heading(let level): blocks.append(.heading(level: level, text: text))
                case .body: blocks.append(.paragraph(text: text))
                case .listItem: blocks.append(.listItem(text: text))
                case .footnote: blocks.append(.footnote(text: text))
                }
            }
            currentLines = []
            currentKind = nil
        }

        for (index, line) in lines.enumerated() {
            let kind = kinds[index]
            var startsNew = true
            if let previous = currentLines.last, let current = currentKind {
                switch (current, kind) {
                case (.heading(let a), .heading(let b)):
                    let gap = previous.box.minY - line.box.maxY
                    startsNew = a != b || gap > pitch * paragraphGapRatio
                case (.body, .body):
                    startsNew = Self.paragraphBreak(
                        previous: previous, current: line, next: index + 1 < lines.count ? lines[index + 1] : nil,
                        pitch: pitch, medianHeight: medianHeight, leftEdge: leftEdge, rightEdge: rightEdge, textWidth: textWidth,
                        paragraphGapRatio: paragraphGapRatio, indentRatio: indentRatio, shortLineRatio: shortLineRatio
                    )
                case (.footnote, .footnote):
                    // Neue Fußnote beginnt mit Marker (*, Ziffer, Klammer) oder nach Lücke.
                    let marker = line.text.first.map { $0 == "*" || $0.isNumber || $0 == "(" } ?? false
                    startsNew = marker || previous.box.midY - line.box.midY > pitch * paragraphGapRatio
                case (.listItem, .listItem):
                    // Listenzeile ohne Zahl am Anfang oder Ende hängt an der vorigen.
                    startsNew = Self.startsWithNumber(line.text) || Self.endsWithNumber(line.text) || Self.endsWithNumber(previous.text)
                default:
                    startsNew = true
                }
            }
            if startsNew { flush(); currentKind = kind }
            currentLines.append(line)
        }
        flush()
        return PageAnalysis(blocks: blocks, printedNumber: printed)
    }

    /// Zwei harte Regeln zuerst: Bindestrich am Zeilenende beendet nie einen Absatz,
    /// Kleinbuchstabe am Zeilenanfang beginnt nie einen. Danach Abstand, Einzug, kurze Zeile.
    static func paragraphBreak(
        previous: RecognizedLine, current: RecognizedLine, next: RecognizedLine?,
        pitch: CGFloat, medianHeight: CGFloat, leftEdge: CGFloat, rightEdge: CGFloat, textWidth: CGFloat,
        paragraphGapRatio: Double, indentRatio: Double, shortLineRatio: Double
    ) -> Bool {
        if let last = previous.text.last, last == "-" || last == "\u{2010}" { return false }
        if let first = current.text.first, first.isLetter, first.isLowercase { return false }

        let gap = previous.box.midY - current.box.midY
        if gap > pitch * paragraphGapRatio { return true }

        let previousShort = (rightEdge - previous.box.maxX) > textWidth * shortLineRatio
        let indent = current.box.minX - previous.box.minX
        if indent > medianHeight * indentRatio {
            // Erstzeileneinzug: die vorige Zeile war kurz, oder die nächste kehrt an den Rand
            // zurück. Hängender Einzug (Glossar): die Folgezeile bleibt eingerückt, kein Absatz.
            if previousShort { return true }
            if let next { return next.box.minX - leftEdge < medianHeight * 0.5 }
            // Letzte Zeile: nach einem Satzende ist der Einzug ein Absatzbeginn, nach
            // Komma oder offenem Satz die Fortsetzung eines hängenden Einzugs.
            let sentenceEnd: Set<Character> = [".", "!", "?", ":"]
            return previous.text.last.map { sentenceEnd.contains($0) } ?? false
        }
        return previousShort && current.box.minX - leftEdge < medianHeight * 0.5
    }

    // MARK: Hilfen

    static func pageNumberIndex(in lines: [RecognizedLine]) -> Int? {
        func isNumber(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
            return !trimmed.isEmpty && trimmed.count <= 4 && trimmed.allSatisfy(\.isNumber)
        }
        let tops = lines.map(\.box.midY)
        guard let top = tops.max(), let bottom = tops.min() else { return nil }
        for (index, line) in lines.enumerated() where isNumber(line.text) {
            let atEdge = line.box.midY >= top - 0.001 || line.box.midY <= bottom + 0.001
            if atEdge { return index }
        }
        return nil
    }

    static func isListPage(_ lines: [RecognizedLine]) -> Bool {
        guard lines.count >= 4 else { return false }
        let numbered = lines.filter { startsWithNumber($0.text) || endsWithNumber($0.text) }.count
        return Double(numbered) >= Double(lines.count) * 0.4
    }

    static func startsWithNumber(_ text: String) -> Bool {
        guard let first = text.first, first.isNumber else { return false }
        return text.prefix { $0.isNumber }.count <= 4
    }

    static func endsWithNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ".) "))
        guard let last = trimmed.last, last.isNumber else { return false }
        let digits = trimmed.reversed().prefix { $0.isNumber }.count
        return digits <= 4 && trimmed.count > digits
    }

    static func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 4 else { return false }
        let upper = letters.filter(\.isUppercase).count
        return Double(upper) >= Double(letters.count) * 0.8
    }

    /// Vergleichsform für Inhaltsverzeichnis und Überschriften: klein, ohne Satzzeichen, Leerraum gebündelt.
    static func normalized(_ text: String) -> String {
        let cleaned = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        return String(cleaned).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Titel aus einem Inhaltsverzeichnis: Seite mit „Inhalt"/„Contents" oder überwiegend
    /// nummerierten Zeilen; Einträge „12 Titel" oder „Titel 12".
    func tableOfContentsTitles(pages: [PageText]) -> Set<String> {
        var titles: Set<String> = []
        for page in pages {
            let lines = page.lines.filter { !$0.text.isEmpty }
            let heading = lines.prefix(3).contains { ["inhalt", "inhaltsverzeichnis", "contents", "table of contents"].contains(Self.normalized($0.text)) }
            guard heading || Self.isListPage(lines) else { continue }
            guard heading || lines.count >= 6 else { continue }
            for line in lines {
                var text = line.text
                if Self.startsWithNumber(text) {
                    text = String(text.drop { $0.isNumber || $0 == "." || $0 == " " })
                }
                if Self.endsWithNumber(text) {
                    text = String(text.reversed().drop { $0.isNumber || $0 == "." || $0 == " " }.reversed())
                }
                let normalized = Self.normalized(text)
                if normalized.count >= 6 { titles.insert(normalized) }
            }
        }
        return titles
    }

    /// Zeilen zu Fließtext.
    ///
    /// Bindestrich am Zeilenende: „Wör-" + „ter" wird „Wörter", wenn das Wörterbuch das
    /// Ganze kennt (auch als „REICHES" → „Reiches"). Sonst bleibt der Strich nur, wenn
    /// der zweite Teil groß beginnt („Desk-View") oder beide Teile eigene Wörter sind;
    /// unbekannte Bruchstücke werden zusammengezogen („re-" + „ferentielles").
    /// Ohne Bindestrich: sind beide Randwörter unbekannt und ihre Verbindung bekannt,
    /// fehlte der Strich im Scan („Territo" + „riums").
    public static func join(_ lines: [String], wordChecker: any WordChecker) -> String {
        var result = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if result.isEmpty {
                result = line
                continue
            }
            let tail = String(line.prefix { $0.isLetter })
            if let last = result.last, last == "-" || last == "\u{2010}" {
                let head = String(result.dropLast())
                let stem = head.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? head
                let stemLetters = String(stem.reversed().prefix { $0.isLetter }.reversed())
                let startsUpper = line.first.map { $0.isUppercase } ?? false
                if !wordChecker.hasDictionary {
                    result += line                      // Strich bleibt, nichts dazwischen
                } else if wordChecker.knows(stemLetters + tail) {
                    result = head + line                // „Wör-" + „ter", „REI-" + „CHES"
                } else if startsUpper || (wordChecker.knows(stemLetters) && wordChecker.knows(tail)) {
                    result += line                      // „Desk-View", Ergänzungsstrich
                } else {
                    result = head + line                // unbekannte Bruchstücke
                }
            } else {
                let headWord = String(result.reversed().prefix { $0.isLetter }.reversed())
                if wordChecker.hasDictionary, headWord.count >= 2, tail.count >= 2, line.first?.isLowercase == true,
                   !wordChecker.knows(headWord), !wordChecker.knows(tail), wordChecker.knows(headWord + tail) {
                    result += line
                } else {
                    result += " " + line
                }
            }
        }
        return result
    }
}

/// Zeilenhöhe und Zeilenabstand als Median über alle Seiten.
struct Typography {
    var medianHeight: CGFloat?
    var pitch: CGFloat?

    init(pages: [PageText], minimumLines: Int) {
        var heights: [CGFloat] = []
        var gaps: [CGFloat] = []
        for page in pages {
            let lines = page.lines.filter { !$0.text.isEmpty && $0.confidence >= 0.3 }
            heights.append(contentsOf: lines.map(\.box.height))
            for (a, b) in zip(lines, lines.dropFirst()) {
                let gap = a.box.midY - b.box.midY
                if gap > 0 { gaps.append(gap) }
            }
        }
        guard heights.count >= minimumLines else { return }
        medianHeight = heights.sorted()[heights.count / 2]
        if !gaps.isEmpty { pitch = gaps.sorted()[gaps.count / 2] }
    }
}

/// Titelvorschlag aus der ersten Seite: die höchsten Zeilen, oben nach unten, höchstens drei.
public enum TitleSuggester {
    public static let maxLines = 3
    public static let heightShare: CGFloat = 0.75
    public static let minimumConfidence: Float = 0.3

    /// Die höchste Zeile muss so viel höher sein als der Median der Seite; sonst ist es
    /// eine Textseite, kein Umschlag, und es gibt keinen Vorschlag.
    public static let minimumProminence: CGFloat = 1.5

    public static func suggest(from page: PageText) -> String? {
        let lines = page.lines.filter { $0.confidence >= minimumConfidence && !$0.text.isEmpty }
        guard let tallest = lines.map(\.box.height).max(), tallest > 0 else { return nil }
        if lines.count >= 4 {
            // Unteres Viertel statt Median: auf einem Umschlag sind die meisten Zeilen Titel.
            let small = lines.map(\.box.height).sorted()[lines.count / 4]
            guard tallest >= small * minimumProminence else { return nil }
        }
        let candidates = lines
            .filter { $0.box.height >= tallest * heightShare }
            .sorted { $0.box.midY > $1.box.midY }
            .prefix(maxLines)
        let title = candidates.map(\.text).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return title.isEmpty ? nil : title
    }
}
