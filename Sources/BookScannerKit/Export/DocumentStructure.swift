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
    public var headingRatio = 1.4
    /// Darüber Überschrift 1. Ebene statt 2.
    public var majorHeadingRatio = 1.9
    /// Abstand zwischen Zeilen über diesem Vielfachen des üblichen Zeilenabstands trennt Absätze.
    public var paragraphGapRatio = 1.6
    /// Einzug der ersten Zeile über diesem Vielfachen der Zeilenhöhe beginnt einen Absatz.
    public var indentRatio = 1.0
    /// Endet eine Zeile deutlich vor dem rechten Rand (Anteil der Textbreite), endet der Absatz.
    public var shortLineRatio = 0.15
    /// Zeilen am Seitenende mit Zeichenbreite unter diesem Anteil des Medians sind Fußnoten.
    public var footnoteRatio = 0.85
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
        var recentPages: [(number: Int, keys: Set<String>)] = []
        for page in pages {
            // Doppelter Scan: fast dieselben Zeilen wie eine der letzten Seiten.
            let keys = Set(page.text.lines.filter { $0.confidence >= 0.5 }.map { Self.normalized($0.text) }.filter { $0.count >= 12 })
            if keys.count >= 6, let twin = recentPages.first(where: { Self.jaccard($0.keys, keys) >= duplicateThreshold }) {
                blocks.append(.pageBreak(number: page.number, printed: nil))
                blocks.append(.note(text: "Scan \(page.number) ist ein Duplikat von Scan \(twin.number) und wurde übersprungen"))
                continue
            }
            recentPages.append((page.number, keys))
            if recentPages.count > 3 { recentPages.removeFirst() }

            var analysis = analyze(page: page.text, stats: stats, tocTitles: tocTitles)
            if page.number == pages.first?.number, let title {
                analysis.blocks = Self.demoteCoverHeadings(analysis.blocks, title: title)
            }
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
            } else if firstIndex < pageBlocks.endIndex,
                      case .paragraph(let first) = pageBlocks[firstIndex],
                      let lastIndex = Self.lastFootnoteIndex(in: blocks),
                      case .footnote(let previous) = blocks[lastIndex],
                      Self.continues(previous, with: first) {
                // Fußnote läuft auf der nächsten Seite weiter.
                blocks[lastIndex] = .footnote(text: Self.join([previous, first], wordChecker: wordChecker))
                pageBlocks.remove(at: firstIndex)
                blocks.append(marker)
            } else {
                blocks.append(marker)
            }
            blocks.append(contentsOf: pageBlocks)
        }
        return StructuredDocument(title: title, blocks: blocks)
    }

    /// Umschlag: Überschriften, die im Dokumenttitel stecken oder Verlagszeilen sind,
    /// werden Absätze; der Titel steht schon über allem.
    static func demoteCoverHeadings(_ blocks: [DocumentBlock], title: String) -> [DocumentBlock] {
        let titleKey = normalized(title)
        return blocks.map { block in
            guard case .heading(_, let text) = block else { return block }
            let key = normalized(text)
            if titleKey.contains(key) || key.contains(titleKey) || TitleSuggester.isExcluded(text) {
                return .paragraph(text: text)
            }
            return block
        }
    }

    /// Ab dieser Ähnlichkeit der Zeilen gilt eine Seite als Duplikat einer der letzten drei.
    public var duplicateThreshold = 0.6

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// Letzte Fußnote am Ende der bisherigen Blöcke (Notizen und Marker dazwischen erlaubt).
    static func lastFootnoteIndex(in blocks: [DocumentBlock]) -> Int? {
        var index = blocks.count - 1
        while index >= 0 {
            switch blocks[index] {
            case .note, .pageBreak: index -= 1
            case .footnote: return index
            default: return nil
            }
        }
        return nil
    }

    /// Letzter Absatz, hinter dem nur noch Fußnoten, Notizen oder Marker leerer Seiten stehen.
    static func lastOpenParagraphIndex(in blocks: [DocumentBlock]) -> Int? {
        var index = blocks.count - 1
        while index >= 0 {
            switch blocks[index] {
            case .footnote, .note, .pageBreak: index -= 1
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
        // Schriftgröße über die Zeichenbreite; Höhe nur, wenn es keine langen Zeilen gibt.
        let medianSize = stats.medianCharWidth ?? pageStats.medianCharWidth ?? medianHeight * 0.55
        func size(_ line: RecognizedLine) -> CGFloat { line.charWidth }
        let lefts = lines.map(\.box.minX).sorted()
        let rights = lines.map(\.box.maxX).sorted()
        let leftEdge = lefts[lefts.count / 10]
        let rightEdge = rights[min(rights.count - 1, rights.count * 9 / 10)]
        let textWidth = max(rightEdge - leftEdge, 0.01)
        let isListPage = Self.isListPage(lines)

        // Fußnoten: kleinere Zeilen am Seitenende unter normal großem Text. Der Block
        // beginnt mit einer Fußnotenmarke oder ist mindestens zwei Zeilen deutlich kleiner;
        // er beginnt nie mit einem Kleinbuchstaben (das wäre ein Absatzende).
        var footnoteStart = lines.count
        if !isListPage {
            // Kleinere Schrift am Seitenende (viele Bücher).
            var i = lines.count - 1
            while i > 0, size(lines[i]) < medianSize * 0.92 { i -= 1 }
            let start = i + 1
            if start < lines.count, lines[..<start].contains(where: { size($0) >= medianSize * 0.92 }) {
                let block = lines[start...]
                let sizes = block.map { size($0) }.sorted()
                let blockMedian = sizes[sizes.count / 2]
                let first = block.first!
                let startsLower = first.text.first.map { $0.isLetter && $0.isLowercase } ?? false
                if !startsLower, Self.startsWithFootnoteMarker(first.text) || (block.count >= 2 && blockMedian < medianSize * footnoteRatio) {
                    footnoteStart = start
                }
            }
            // Gleiche Schrift, nur mit Marke (Merve): oberste Markenzeile im unteren
            // Drittel des Textblocks eröffnet die Fußnoten, alles darunter gehört dazu.
            if lines.count >= 4, let top = lines.first?.box.midY, let bottom = lines.last?.box.midY, top > bottom {
                let zone = bottom + (top - bottom) * 0.38
                if let markerIndex = lines.indices.first(where: { lines[$0].box.midY <= zone && Self.startsWithFootnoteMarker(lines[$0].text) && $0 > 0 }) {
                    footnoteStart = min(footnoteStart, markerIndex)
                }
            }
        }

        // Zeilenarten
        var kinds: [Kind] = []
        for (index, line) in lines.enumerated() {
            if index >= footnoteStart { kinds.append(.footnote); continue }
            if isListPage { kinds.append(.listItem); continue }
            let ratio = size(line) / medianSize
            let startsLower = line.text.first.map { $0.isLetter && $0.isLowercase } ?? false
            let endsHyphen = line.text.last == "-" || line.text.last == "\u{2010}"
            let short = line.box.width < textWidth * 0.7
            let gapBefore = index > 0 ? lines[index - 1].box.midY - line.box.midY : 0
            let gapAfter = index + 1 < lines.count ? line.box.midY - lines[index + 1].box.midY : 0
            let spaced = gapBefore > pitch * 1.5 || gapAfter > pitch * 1.5
            let matchesToc = tocTitles.contains(Self.normalized(line.text))
            let allCaps = Self.isAllCaps(line.text)
            let previous = index > 0 ? lines[index - 1] : nil
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            // Nach einer Zeile mit Bindestrich oder ohne Satzende (und voller Breite) folgt
            // Fließtext, keine Überschrift; ebenso vor einer Zeile, die klein beginnt.
            let afterHyphen = previous?.text.last.map { $0 == "-" || $0 == "\u{2010}" } ?? false
            let afterOpenLine = previous.map { line in
                let short = (rightEdge - line.box.maxX) > textWidth * shortLineRatio
                let closed = line.text.last.map { ".!?:".contains($0) || "\"\u{201C}\u{201D})".contains($0) } ?? false
                return !short && !closed && gapBefore < pitch * 1.5
            } ?? false
            let beforeLowercase = next?.text.first.map { $0.isLetter && $0.isLowercase } ?? false
            let endsOpen = line.text.last.map { ":,;".contains($0) } ?? false
            let eligible = !startsLower && !endsHyphen && !endsOpen && !afterHyphen && !afterOpenLine && !beforeLowercase
                && !Self.startsWithNumber(line.text) && !Self.endsWithNumber(line.text) && !Self.startsWithFootnoteMarker(line.text)

            // Mindestens zwei Wörter oder acht Buchstaben, sonst ist es eher
            // Kolumnentitel-Schrott („BOROPE /") als Überschrift.
            let words = line.text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter } }.count
            let substantial = words >= 2 || line.text.filter(\.isLetter).count >= 8
            if eligible, substantial {
                if matchesToc {
                    kinds.append(.heading(allCaps ? 1 : 2)); continue
                }
                if ratio > majorHeadingRatio, short || spaced {
                    kinds.append(.heading(1)); continue
                }
                if ratio > headingRatio, short || spaced {
                    kinds.append(.heading(2)); continue
                }
                if allCaps, short {
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
                    // Neue Fußnote beginnt mit einer Marke oder nach Lücke; eine Jahreszahl
                    // am Zeilenanfang („1975 (A.d. R.)") ist Fortsetzung.
                    startsNew = Self.startsWithFootnoteMarker(line.text) || previous.box.midY - line.box.midY > pitch * paragraphGapRatio
                case (.listItem, .listItem):
                    // Jede Zeile ein Eintrag, außer sie setzt die vorige fort.
                    let continuation = (previous.text.last.map { $0 == "-" || $0 == "," } ?? false)
                        || (line.text.first.map { $0.isLetter && $0.isLowercase } ?? false)
                    startsNew = !continuation
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
        let nonLetters = text.filter { !$0.isLetter && !$0.isWhitespace }.count
        guard Double(nonLetters) <= Double(text.count) * 0.4 else { return false }
        // Versalien mit vielen Ziffern („AE000 1 2H0N0 S0NY RE") sind Kolumnenschrott.
        guard text.filter(\.isNumber).count <= 2 else { return false }
        let upper = letters.filter(\.isUppercase).count
        return Double(upper) >= Double(letters.count) * 0.8
    }

    /// „*", „**", „(1)", „1)" oder eine Ziffer direkt vor Text.
    static func startsWithFootnoteMarker(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if first == "*" || first == "†" { return true }
        if first == "(" { return text.dropFirst().first?.isNumber ?? false }
        if first.isNumber {
            let digits = text.prefix { $0.isNumber }
            let rest = text.dropFirst(digits.count)
            return rest.first == ")" || (rest.first?.isLetter ?? false)
        }
        return false
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
            if let last = result.last, last == "-" || last == "\u{2010}", tail.isEmpty {
                // Bindestrich, dann eine Zeile, die nicht mit Buchstaben beginnt (Marke,
                // Klammer, Zahl): nichts zusammenziehen.
                result += " " + line
            } else if let last = result.last, last == "-" || last == "\u{2010}" {
                let head = String(result.dropLast())
                let startsUpper = line.first.map { $0.isUppercase } ?? false
                if !wordChecker.hasDictionary {
                    result += line                      // Strich bleibt, nichts dazwischen
                } else if startsUpper, Self.isAllCapsWord(head), Self.isAllCapsWord(tail) {
                    result = head + line                // „UN-" + „TERWELT": Versalien getrennt
                } else if startsUpper {
                    result += line                      // „Desk-" + „View": Kompositum
                } else if Self.conjunctions.contains(tail.lowercased()) {
                    result += " " + line                // „Ein-" + „und": Ergänzungsstrich
                } else {
                    result = head + line                // Silbentrennung; das Wörterbuch ist
                }                                       // für Bruchstücke nicht zu gebrauchen
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
        return repairInlineHyphens(in: result, wordChecker: wordChecker)
    }

    /// Letztes Wort (bzw. der ganze Text) nur aus Großbuchstaben, mindestens zwei.
    static func isAllCapsWord(_ text: String) -> Bool {
        let word = text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? text
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// Wörter, die nach einem Ergänzungsstrich folgen: „Ein- und Zusammenbruch".
    static let conjunctions: Set<String> = ["und", "oder", "bzw", "sowie", "beziehungsweise", "and", "or"]

    /// Bindestriche mitten in einer Zeile, die aus zusammengelegten Zeilen stammen:
    /// „el-ner", „Theo-rie". Vorsichtiger als am Zeilenende, weil hier echte Komposita
    /// stehen können („nichtig-kitschigen"): Der Strich fällt, wenn das Ganze bekannt ist
    /// oder ein Teil zu kurz für ein eigenes Wort ist (unter vier Buchstaben) oder das
    /// Wörterbuch einen Teil nicht kennt.
    static func repairInlineHyphens(in text: String, wordChecker: any WordChecker) -> String {
        guard wordChecker.hasDictionary, text.contains("-") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "(\\p{L}{2,})-(\\p{Ll}\\p{L}{1,})") else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result),
                  let stemRange = Range(match.range(at: 1), in: result),
                  let tailRange = Range(match.range(at: 2), in: result) else { continue }
            let stem = String(result[stemRange]), tail = String(result[tailRange])
            if conjunctions.contains(tail.lowercased()) { continue }
            if wordChecker.knows(stem + tail) {
                result.replaceSubrange(whole, with: stem + tail)
            } else if stem.count < 4 || tail.count < 4 || !(wordChecker.knows(stem) && wordChecker.knows(tail)) {
                result.replaceSubrange(whole, with: stem + tail)
            }
        }
        return result
    }
}

/// Zeilenhöhe und Zeilenabstand als Median über alle Seiten.
struct Typography {
    var medianHeight: CGFloat?
    var medianCharWidth: CGFloat?
    var pitch: CGFloat?

    init(pages: [PageText], minimumLines: Int) {
        var heights: [CGFloat] = []
        var charWidths: [CGFloat] = []
        var gaps: [CGFloat] = []
        for page in pages {
            let lines = page.lines.filter { !$0.text.isEmpty && $0.confidence >= 0.3 }
            heights.append(contentsOf: lines.map(\.box.height))
            charWidths.append(contentsOf: lines.filter { $0.text.count >= 8 }.map(\.charWidth))
            for (a, b) in zip(lines, lines.dropFirst()) {
                let gap = a.box.midY - b.box.midY
                if gap > 0 { gaps.append(gap) }
            }
        }
        guard heights.count >= minimumLines else { return }
        medianHeight = heights.sorted()[heights.count / 2]
        if !charWidths.isEmpty { medianCharWidth = charWidths.sorted()[charWidths.count / 2] }
        if !gaps.isEmpty { pitch = gaps.sorted()[gaps.count / 2] }
    }
}

/// Titelvorschlag aus Umschlag und Titelei.
///
/// Umschlag: die höchsten Zeilen, ohne Verlagszeilen. Kehrt eine Umschlagzeile auf
/// einer der nächsten Seiten wieder (Titelseite, Schmutztitel), ist sie ein eigener
/// Teil, Autor oder Titel; die Teile werden mit Gedankenstrich verbunden. Zeilen, die
/// nirgends wiederkehren, gelten als Teile eines mehrzeiligen Titels und bleiben
/// zusammen. Kleinere Umschlagzeilen, die wiederkehren, sind meist der Autor und
/// kommen dazu.
public enum TitleSuggester {
    public static let maxLines = 3
    public static let heightShare: CGFloat = 0.6
    public static let minimumConfidence: Float = 0.3
    /// Die höchste Zeile muss so viel höher sein als das untere Viertel der Seite;
    /// sonst ist es eine Textseite, kein Umschlag.
    public static let minimumProminence: CGFloat = 1.5
    /// So viele Seiten nach dem Umschlag werden auf Wiederholungen durchsucht.
    public static let lookahead = 6

    static let publisherWords = [
        "verlag", "verlags", "press", "publishing", "publishers", "publisher", "editions", "éditions", "editore",
        "editorial", "gmbh", "ltd", "inc", "isbn", "©", "copyright", "übersetzt", "translated", "herausgegeben",
        "edited", "aus dem", "printed",
    ]

    public static func suggest(from page: PageText) -> String? {
        suggest(cover: page, followingPages: [])
    }

    public static func suggest(cover: PageText, followingPages: [PageText]) -> String? {
        let lines = cover.lines.filter { $0.confidence >= minimumConfidence && !$0.text.isEmpty && !isExcluded($0.text) }
        guard let tallest = lines.map(\.charWidth).max(), tallest > 0 else { return nil }
        let allSizes = cover.lines.filter { !$0.text.isEmpty }.map(\.charWidth).sorted()
        if allSizes.count >= 4 {
            guard tallest >= allSizes[allSizes.count / 4] * minimumProminence else { return nil }
        }

        // Normalisierte Zeilen der folgenden Seiten, für die Wiederholungssuche.
        var seenElsewhere: Set<String> = []
        for other in followingPages.prefix(lookahead) {
            for line in other.lines where line.confidence >= minimumConfidence {
                seenElsewhere.insert(DocumentStructurer.normalized(line.text))
            }
        }
        func recurs(_ line: RecognizedLine) -> Bool {
            let key = DocumentStructurer.normalized(line.text)
            return key.count >= 4 && seenElsewhere.contains(key)
        }

        let ordered = lines.sorted { $0.box.midY > $1.box.midY }
        let big = ordered.filter { $0.charWidth >= tallest * heightShare }.prefix(maxLines)
        guard !big.isEmpty else { return nil }

        // Teile bilden: wiederkehrende Zeilen einzeln, alle anderen zusammen.
        var parts: [String] = []
        var run: [String] = []
        for line in big {
            if recurs(line) {
                if !run.isEmpty { parts.append(run.joined(separator: " ")); run = [] }
                parts.append(line.text)
            } else {
                run.append(line.text)
            }
        }
        if !run.isEmpty { parts.append(run.joined(separator: " ")) }

        // Kleinere wiederkehrende Zeilen (Autor) davor oder danach, je nach Lage.
        let bigIDs = Set(big.map { DocumentStructurer.normalized($0.text) })
        let topOfBig = big.map(\.box.midY).max() ?? 0
        let smallRecurring = ordered.filter { !bigIDs.contains(DocumentStructurer.normalized($0.text)) && recurs($0) }
        for line in smallRecurring.prefix(1) {
            if line.box.midY > topOfBig { parts.insert(line.text, at: 0) } else { parts.append(line.text) }
        }

        let title = parts
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " – ")
        return title.isEmpty ? nil : title
    }

    /// Verlag, Rechte, Übersetzer, Jahreszahlen, ISBN: nie Teil des Titels.
    static func isExcluded(_ text: String) -> Bool {
        let lower = text.lowercased()
        if publisherWords.contains(where: { lower.contains($0) }) { return true }
        if lower.range(of: #"\b(1[5-9]|20)\d\d\b"#, options: .regularExpression) != nil { return true }
        let letters = text.filter(\.isLetter).count
        return letters < 2
    }
}
