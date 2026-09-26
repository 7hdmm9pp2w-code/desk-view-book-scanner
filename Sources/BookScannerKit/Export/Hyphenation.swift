import Foundation
import CoreGraphics

/// Zeilen zusammenfügen und Silbentrennung auflösen.
extension DocumentStructurer {
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
