import Foundation

/// Verkleinertes Graubild, Zeile für Zeile.
public struct GrayFrame: Sendable, Equatable {
    public var pixels: [UInt8]
    public var width: Int

    public init(pixels: [UInt8], width: Int) {
        self.pixels = pixels
        self.width = width
    }

    public var height: Int { width > 0 ? pixels.count / width : 0 }
}

/// Was von einer ruhig liegenden Seite zum Vergleich bleibt: ein Graubild und die
/// Wörter einer schnellen Texterkennung.
public struct PageSnapshot: Sendable, Equatable {
    public var frame: GrayFrame
    public var words: [String]

    public init(frame: GrayFrame, words: [String]) {
        self.frame = frame
        self.words = words
    }

    /// Kleingeschrieben, ohne Satzzeichen, erst ab vier Zeichen: Kurze Wörter wie
    /// „der" oder „und" stehen auf jeder Seite und verwischen den Vergleich.
    public init(frame: GrayFrame, lines: [String]) {
        let words = lines
            .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .filter { $0.count >= 4 }
            .map(String.init)
        self.init(frame: frame, words: words)
    }
}

/// Entscheidet, ob nach einer Bewegung eine neue Seite daliegt oder noch eine schon
/// erfasste: dieselbe Seite, eine Hand darauf, das Buch verrutscht, das Licht anders
/// oder zurückgeblättert.
///
/// Mit genug Text zählen die Wörter. Die sind gegen Licht, Verschieben und eine Hand
/// am Rand unempfindlich. Eine halb verdeckte Seite hat weniger Wörter, aber fast nur
/// alte. Ohne Text (Bildtafel, leere Seite) werden Kacheln verglichen: jedes Bild auf
/// Mittelwert und Kontrast normiert, dann um ein paar Pixel gegeneinander verschoben,
/// bis sie am besten passen. Neu ist die Seite, wenn sich ein großer Teil der Kacheln
/// mit Struktur geändert hat. Eine Hand trifft nur wenige Kacheln.
public struct PageTurnJudge: Sendable {
    /// Ab so vielen Wörtern auf beiden Seiten entscheidet der Text.
    public var minWords = 12
    /// Anteil gemeinsamer Wörter, ab dem es dieselbe Seite ist, bezogen auf die kürzere.
    public var sameTextShare = 0.5
    /// Anteil geänderter Kacheln mit Struktur, ab dem die Seite neu ist.
    public var changedTileShare = 0.4
    /// Mittlere normierte Differenz einer Kachel, ab der sie als geändert gilt.
    public var tileChangeThreshold: Float = 0.3
    /// Streuung einer Kachel, ab der sie Struktur hat.
    public var textureThreshold: Float = 0.25
    /// Größte Verschiebung beim Ausrichten, in Pixeln des Graubilds.
    public var maxShift = 4
    public var tileSize = 16
    /// So viele zuletzt erfasste Seiten werden verglichen, damit Zurückblättern auffällt.
    public var memory = 3

    public private(set) var recent: [PageSnapshot] = []

    public init() {}

    /// Neu, wenn sich die Seite von allen zuletzt erfassten unterscheidet.
    public func isNewPage(_ snapshot: PageSnapshot) -> Bool {
        recent.allSatisfy { !isSamePage(snapshot, $0) }
    }

    /// Merkt sich eine erfasste Seite. Dieselbe Seite noch einmal ersetzt den Eintrag.
    public mutating func remember(_ snapshot: PageSnapshot) {
        if let last = recent.last, isSamePage(snapshot, last) {
            recent[recent.count - 1] = snapshot
        } else {
            recent.append(snapshot)
            if recent.count > memory { recent.removeFirst(recent.count - memory) }
        }
    }

    public mutating func reset() {
        recent = []
    }

    public func isSamePage(_ a: PageSnapshot, _ b: PageSnapshot) -> Bool {
        if a.words.count >= minWords, b.words.count >= minWords {
            return Self.sharedWordShare(a.words, b.words) >= sameTextShare
        }
        return changedShare(a.frame, b.frame) < changedTileShare
    }

    /// Gemeinsame Wörter (mit Vielfachheit) im Verhältnis zur kürzeren Liste.
    public static func sharedWordShare(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for word in a { counts[word, default: 0] += 1 }
        var shared = 0
        for word in b {
            if let n = counts[word], n > 0 {
                shared += 1
                counts[word] = n - 1
            }
        }
        return Double(shared) / Double(min(a.count, b.count))
    }

    /// Anteil der Kacheln mit Struktur, die sich nach bester Ausrichtung geändert haben.
    public func changedShare(_ a: GrayFrame, _ b: GrayFrame) -> Double {
        let w = a.width, h = a.height
        guard w == b.width, h == b.height, w > 2 * maxShift + tileSize, h > 2 * maxShift + tileSize else {
            return 1
        }
        let na = Self.normalized(a), nb = Self.normalized(b)
        let m = maxShift

        // Beste Verschiebung von b gegen a, über den inneren Ausschnitt: grob auf jedem
        // zweiten Pixel, dann fein um den Treffer. Grob allein kann zwischen Nachbarn nicht
        // unterscheiden, wenn Zeilen zwei Pixel dick sind.
        func cost(_ dx: Int, _ dy: Int, step: Int) -> Float {
            var sum: Float = 0
            for y in stride(from: m, to: h - m, by: step) {
                let rowA = y * w, rowB = (y + dy) * w + dx
                for x in stride(from: m, to: w - m, by: step) { sum += abs(na[rowA + x] - nb[rowB + x]) }
            }
            return sum
        }
        var coarse = (dx: 0, dy: 0, cost: Float.infinity)
        for dy in -m...m {
            for dx in -m...m {
                let c = cost(dx, dy, step: 2)
                if c < coarse.cost { coarse = (dx, dy, c) }
            }
        }
        var best = (dx: 0, dy: 0, cost: Float.infinity)
        for dy in max(-m, coarse.dy - 1)...min(m, coarse.dy + 1) {
            for dx in max(-m, coarse.dx - 1)...min(m, coarse.dx + 1) {
                let c = cost(dx, dy, step: 1)
                if c < best.cost { best = (dx, dy, c) }
            }
        }

        var textured = 0, changed = 0
        var ty = m
        while ty + tileSize <= h - m {
            var tx = m
            while tx + tileSize <= w - m {
                var diff: Float = 0
                var sumA: Float = 0, sumA2: Float = 0, sumB: Float = 0, sumB2: Float = 0
                for y in ty..<(ty + tileSize) {
                    let rowA = y * w, rowB = (y + best.dy) * w + best.dx
                    for x in tx..<(tx + tileSize) {
                        let va = na[rowA + x], vb = nb[rowB + x]
                        diff += abs(va - vb)
                        sumA += va; sumA2 += va * va
                        sumB += vb; sumB2 += vb * vb
                    }
                }
                let n = Float(tileSize * tileSize)
                let stdA = (max(0, sumA2 / n - (sumA / n) * (sumA / n))).squareRoot()
                let stdB = (max(0, sumB2 / n - (sumB / n) * (sumB / n))).squareRoot()
                if max(stdA, stdB) >= textureThreshold {
                    textured += 1
                    if diff / n >= tileChangeThreshold { changed += 1 }
                }
                tx += tileSize
            }
            ty += tileSize
        }
        guard textured > 0 else { return 0 }
        return Double(changed) / Double(textured)
    }

    /// Auf Mittelwert 0 und Streuung 1; hebt Helligkeit und Kontrast des Lichts auf.
    static func normalized(_ frame: GrayFrame) -> [Float] {
        let n = Float(max(frame.pixels.count, 1))
        var sum: Float = 0, sum2: Float = 0
        for p in frame.pixels { let v = Float(p); sum += v; sum2 += v * v }
        let mean = sum / n
        // Untergrenze, damit ein fast leeres Bild nicht sein Rauschen aufbläst.
        let std = max((max(0, sum2 / n - mean * mean)).squareRoot(), 8)
        return frame.pixels.map { (Float($0) - mean) / std }
    }
}
