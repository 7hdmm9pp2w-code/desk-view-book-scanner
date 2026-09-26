import Foundation
import CoreGraphics

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
