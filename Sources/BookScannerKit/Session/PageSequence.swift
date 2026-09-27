import Foundation

/// Was an der Stelle einer Seite in der Folge der gedruckten Seitenzahlen auffällt.
public enum PageSequenceIssue: Sendable, Equatable {
    /// Vor dieser Seite fehlen vermutlich die Seiten `from…to`.
    case missing(from: Int, to: Int)
    /// Dieselbe Seitenzahl hat schon die Seite an Rasterposition `scan` (ab 1).
    case duplicate(scan: Int)
    /// Die Seitenzahl ist kleiner als die der Seite davor (`previous`).
    case outOfOrder(previous: Int)
}

/// Prüft die Folge der gedruckten Seitenzahlen: fehlende, doppelte und vertauschte Seiten.
///
/// Seiten ohne erkannte Zahl (Kapitelanfang, Bildtafel) zählen als Seiten mit, werden aber
/// nicht beanstandet. Eine ungeteilte Doppelseite trägt zwei Zahlen; wie viele Seiten ein
/// Scan hat, wird aus den Scans mit Zahl geschätzt. OCR verliest sich gelegentlich, etwa
/// „36" statt „38": Passt die nächste Zahl wieder zur vorherigen, war es ein Lesefehler
/// und keine Lücke.
public enum PageSequence {
    /// Größte Lücke, die ohne Bestätigung durch die Folgeseite gemeldet wird.
    public static let unconfirmedGapLimit = 30

    /// Gedruckte Seitenzahl oben oder unten auf der Seite; zwei bei einer Doppelseite.
    /// Unten nur eine reine Zahlenzeile, oben auch ein Kolumnentitel mit Zahl am Anfang
    /// oder Ende („24 Einleitung"). Unten wäre das zu oft eine Fußnote.
    public static func printedNumbers(in text: PageText) -> ClosedRange<Int>? {
        printedNumbers(in: text.lines.filter { !$0.text.isEmpty })?.numbers
    }

    /// Wie oben, dazu die Indizes der reinen Zahlenzeilen in `lines`: Die kann der Export
    /// weglassen. Kolumnentitel bleiben stehen, eine Kapitelüberschrift „2 Grundlagen“
    /// oben auf der Seite sähe genauso aus.
    static func printedNumbers(in lines: [RecognizedLine]) -> (numbers: ClosedRange<Int>, numberLines: [Int])? {
        guard let top = lines.map(\.box.midY).max(), let bottom = lines.map(\.box.midY).min() else {
            return nil
        }
        let band = 0.02
        var candidates: [(value: Int, x: CGFloat)] = []
        var numberLines: [Int] = []
        for (index, line) in lines.enumerated() {
            let atTop = line.box.midY >= top - band
            let atBottom = line.box.midY <= bottom + band
            guard atTop || atBottom else { continue }
            if let value = number(line.text) {
                candidates.append((value, line.box.midX))
                numberLines.append(index)
            } else if atTop, let value = headerNumber(line.text) {
                candidates.append((value, line.box.midX))
            }
        }
        // Dieselbe Zahl oben und unten zählt einmal.
        var seen: Set<Int> = []
        candidates = candidates.filter { seen.insert($0.value).inserted }
        switch candidates.count {
        case 1:
            return (candidates[0].value...candidates[0].value, numberLines)
        case 2:
            // Doppelseite: links die kleinere, rechts die nächste Zahl.
            let sorted = candidates.sorted { $0.x < $1.x }
            guard sorted[1].value == sorted[0].value + 1 else { return nil }
            return (sorted[0].value...sorted[1].value, numberLines)
        default:
            return nil
        }
    }

    /// Reine Zahl mit höchstens vier Ziffern, Striche drumherum erlaubt („– 12 –").
    static func number(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "-–— "))
        guard !trimmed.isEmpty, trimmed.count <= 4, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
              let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// Kolumnentitel mit Zahl vorn oder hinten und höchstens sechs Wörtern Text.
    static func headerNumber(_ text: String) -> Int? {
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 2, tokens.count <= 7 else { return nil }
        if let value = number(tokens[0]), tokens.dropFirst().contains(where: { $0.contains(where: \.isLetter) }) {
            return value
        }
        if let value = number(tokens[tokens.count - 1]), tokens.dropLast().contains(where: { $0.contains(where: \.isLetter) }) {
            return value
        }
        return nil
    }

    /// Auffälligkeiten nach Rasterposition (ab 0). `numbers` hat einen Eintrag je Seite.
    public static func check(_ numbers: [ClosedRange<Int>?]) -> [Int: PageSequenceIssue] {
        let spans = numbers.compactMap { $0?.count }.sorted()
        let pagesPerScan = spans.isEmpty ? 1 : spans[spans.count / 2]

        /// Erwartete erste Zahl auf Scan `index`, wenn Scan `anchor` verlässlich ist.
        func expected(at index: Int, after anchor: Int) -> Int {
            numbers[anchor]!.upperBound + 1 + (index - anchor - 1) * pagesPerScan
        }
        func nextNumbered(after index: Int) -> Int? {
            numbers.indices.dropFirst(index + 1).first { numbers[$0] != nil }
        }

        var issues: [Int: PageSequenceIssue] = [:]
        var reliable: [Int] = []
        /// Verlässliche Scans, die Teil einer lückenlosen Folge von mindestens zwei Seiten sind.
        var confirmed: Set<Int> = []
        for index in numbers.indices {
            guard let range = numbers[index] else { continue }
            if let earlier = reliable.last(where: { numbers[$0]!.overlaps(range) }) {
                issues[index] = .duplicate(scan: earlier + 1)
                continue
            }
            let next = nextNumbered(after: index)
            let nextConfirms = next.map { numbers[$0]!.lowerBound == expected(at: $0, after: index) } ?? false
            // Eine Zahl ohne Anschluss weicht einer Folge, die weitergeht: „insel taschenbuch
            // 1207“ auf der Titelseite ist keine Seitenzahl. Steht sie ganz vorn, auch ohne
            // Bestätigung, sonst piept es beim Scannen schon auf der ersten echten Seite.
            while let anchor = reliable.last, !confirmed.contains(anchor), nextConfirms || reliable.count == 1,
                  range.lowerBound < numbers[anchor]!.lowerBound {
                reliable.removeLast()
                issues[anchor] = nil
            }
            guard let anchor = reliable.last else { reliable.append(index); continue }
            let want = expected(at: index, after: anchor)
            if range.lowerBound == want { confirmed.formUnion([anchor, index]); reliable.append(index); continue }

            // Lesefehler? Dann passt die nächste Zahl zur vorherigen statt zu dieser.
            if let next, numbers[next]!.lowerBound == expected(at: next, after: anchor) { continue }

            if range.lowerBound < numbers[anchor]!.lowerBound {
                issues[index] = .outOfOrder(previous: numbers[anchor]!.upperBound)
                reliable.append(index)
            } else if range.lowerBound > want {
                if nextConfirms || range.lowerBound - want <= unconfirmedGapLimit {
                    issues[index] = .missing(from: want, to: range.lowerBound - 1)
                }
                reliable.append(index)
            } else {
                // Weniger weit als erwartet, aber vorwärts: Seiten ohne Zahl zählen anders,
                // etwa leere Vakatseiten, die nicht gescannt wurden. Kein Hinweis.
                reliable.append(index)
            }
        }

        // Später nachgescannte Seiten schließen die Lücke; es fehlt nur, was nirgends vorkommt.
        let covered = Set(numbers.compactMap { $0 }.flatMap { Array($0) })
        for (index, issue) in issues {
            guard case .missing(let from, let to) = issue else { continue }
            let absent = (from...to).filter { !covered.contains($0) }
            if let first = absent.first, let last = absent.last {
                issues[index] = .missing(from: first, to: last)
            } else {
                issues[index] = nil
            }
        }
        return issues
    }
}
