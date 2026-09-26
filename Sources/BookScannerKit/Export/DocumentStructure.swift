import Foundation
import CoreGraphics

public enum DocumentBlock: Equatable, Sendable {
    case pageBreak(number: Int)
    case heading(level: Int, text: String)
    case paragraph(text: String)
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
}

/// Kennt kein Wort; Bindestriche bleiben stehen.
public struct NoWordChecker: WordChecker {
    public init() {}
    public func isWord(_ word: String) -> Bool { false }
}

/// Feste Wortliste, für Tests und Werkzeuge ohne AppKit.
public struct SetWordChecker: WordChecker {
    public let words: Set<String>
    public init(_ words: Set<String>) { self.words = words }
    public func isWord(_ word: String) -> Bool { words.contains(word) }
}

/// Baut aus OCR-Zeilen Absätze und Überschriften. Nur Geometrie: Zeilenhöhe,
/// Abstand, Einzug, Zeilenende. Keine Sprachanalyse.
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

    public init(wordChecker: any WordChecker = NoWordChecker()) {
        self.wordChecker = wordChecker
    }

    public func structure(pages: [(number: Int, text: PageText)], title: String? = nil) -> StructuredDocument {
        var blocks: [DocumentBlock] = []
        for page in pages {
            blocks.append(.pageBreak(number: page.number))
            blocks.append(contentsOf: structure(page: page.text))
        }
        return StructuredDocument(title: title, blocks: blocks)
    }

    // MARK: Eine Seite

    private enum Kind { case heading(Int), body }

    public func structure(page: PageText) -> [DocumentBlock] {
        let lines = page.lines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return [] }

        let heights = lines.map(\.box.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let pitch = Self.typicalPitch(lines) ?? medianHeight * 1.3
        let lefts = lines.map(\.box.minX).sorted()
        let rights = lines.map(\.box.maxX).sorted()
        let leftEdge = lefts[lefts.count / 10]
        let rightEdge = rights[min(rights.count - 1, rights.count * 9 / 10)]
        let textWidth = max(rightEdge - leftEdge, 0.01)

        var blocks: [DocumentBlock] = []
        var currentKind: Kind?
        var currentLines: [String] = []

        func flush() {
            let text = Self.join(currentLines, wordChecker: wordChecker)
            if !text.isEmpty, let kind = currentKind {
                switch kind {
                case .heading(let level): blocks.append(.heading(level: level, text: text))
                case .body: blocks.append(.paragraph(text: text))
                }
            }
            currentLines = []
            currentKind = nil
        }

        var previous: RecognizedLine?
        for line in lines {
            let ratio = line.box.height / medianHeight
            let kind: Kind = ratio > majorHeadingRatio ? .heading(1) : ratio > headingRatio ? .heading(2) : .body

            var startsNew = false
            if let previous {
                switch (currentKind, kind) {
                case (.heading(let a)?, .heading(let b)):
                    // Mehrzeilige Titel bleiben zusammen, wenn der Abstand normal ist.
                    let gap = previous.box.minY - line.box.maxY
                    startsNew = a != b || gap > pitch * paragraphGapRatio
                case (.body?, .body):
                    let gap = previous.box.midY - line.box.midY
                    let indent = line.box.minX - previous.box.minX
                    let previousShort = (rightEdge - previous.box.maxX) > textWidth * shortLineRatio
                    startsNew = gap > pitch * paragraphGapRatio
                        || indent > medianHeight * indentRatio
                        || (previousShort && line.box.minX - leftEdge < medianHeight * 0.5)
                default:
                    startsNew = true
                }
            } else {
                startsNew = true
            }

            if startsNew { flush(); currentKind = kind }
            currentLines.append(line.text)
            previous = line
        }
        flush()
        return blocks
    }

    /// Üblicher Zeilenabstand: Median der positiven Abstände aufeinanderfolgender Zeilen.
    static func typicalPitch(_ lines: [RecognizedLine]) -> CGFloat? {
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) {
            let gap = a.box.midY - b.box.midY
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// Zeilen zu Fließtext. `Wör-` + `ter` wird `Wörter`, wenn das Wörterbuch es kennt;
    /// sonst bleibt der Bindestrich und die Teile werden ohne Leerzeichen verbunden.
    public static func join(_ lines: [String], wordChecker: any WordChecker) -> String {
        var result = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if result.isEmpty {
                result = line
                continue
            }
            if let last = result.last, last == "-" || last == "\u{2010}" {
                // Zeilenende mit Bindestrich: nie ein Leerzeichen dazwischen. Der Strich
                // fällt nur, wenn das zusammengesetzte Wort im Wörterbuch steht.
                let head = String(result.dropLast())
                let stem = head.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? head
                let tail = String(line.prefix { $0.isLetter })
                if let first = line.first, first.isLowercase, wordChecker.isWord(stem + tail) {
                    result = head + line
                } else {
                    result += line
                }
            } else {
                result += " " + line
            }
        }
        return result
    }
}

/// Titelvorschlag aus der ersten Seite: die höchsten Zeilen, oben nach unten, höchstens drei.
public enum TitleSuggester {
    public static let maxLines = 3
    public static let heightShare: CGFloat = 0.75
    public static let minimumConfidence: Float = 0.3

    public static func suggest(from page: PageText) -> String? {
        let lines = page.lines.filter { $0.confidence >= minimumConfidence && !$0.text.isEmpty }
        guard let tallest = lines.map(\.box.height).max(), tallest > 0 else { return nil }
        let candidates = lines
            .filter { $0.box.height >= tallest * heightShare }
            .sorted { $0.box.midY > $1.box.midY }
            .prefix(maxLines)
        let title = candidates.map(\.text).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return title.isEmpty ? nil : title
    }
}
