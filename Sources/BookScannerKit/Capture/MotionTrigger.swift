import Foundation

/// Bewegungsmelder für den Auto-Auslöser: aus einer Folge stark verkleinerter Graubilder
/// der Moment, in dem nach einer Bewegung Ruhe eingekehrt ist.
///
/// Zustände: *ruhig* → *Bewegung* (Umblättern) → *ruhig seit `settleSeconds`* → melden.
/// Ohne vorherige Bewegung wird nie gemeldet, damit ein stilles Bild nicht laufend
/// erfasst wird. Ob wirklich umgeblättert wurde, entscheidet danach der `PageTurnJudge`.
/// Reine Logik, ohne Kamera, darum testbar.
///
/// Viele Bücher müssen mit den Händen aufgehalten werden; die Hände zittern und rutschen
/// ständig ein wenig. Deshalb zählt nicht die mittlere Änderung des ganzen Bildes,
/// sondern die in Kacheln: Bewegung heißt, ein großer Teil der Kacheln ändert sich, wie
/// beim Umblättern. Hände am Rand treffen nur wenige Kacheln und stören weder die
/// Bewegung noch die Ruhe.
public struct MotionTrigger: Sendable {
    public enum State: Sendable, Equatable { case idle, moving, settling }

    /// Mittlere Pixeldifferenz (0…255) einer Kachel zum Vorbild, ab der sie bewegt ist.
    public var motionThreshold: Double = 6
    /// Darunter gilt eine Kachel als ruhig.
    public var stillThreshold: Double = 2.5
    /// Anteil der Kacheln, der sich bewegen muss, damit das Bild als bewegt gilt; ebenso
    /// viele dürfen sich in der Ruhe noch rühren. Zwei haltende Hände bleiben darunter.
    public var movingShare = 0.25
    /// Kacheln je Zeile.
    public var tilesAcross = 16
    /// So lange muss Ruhe herrschen, bevor gemeldet wird.
    public var settleSeconds: TimeInterval = 1.5

    public private(set) var state: State = .idle
    private var previous: [UInt8]?
    private var stillSince: TimeInterval?

    public init() {}

    /// Nächstes Bild mit `width` Pixeln je Zeile; `true` heißt: Das Bild steht nach einer
    /// Bewegung still.
    public mutating func feed(_ frame: [UInt8], width: Int, at time: TimeInterval) -> Bool {
        defer { previous = frame }
        guard let previous, previous.count == frame.count else { return false }
        let diff = motionLevel(previous, frame, width: width)

        if diff > motionThreshold {
            state = .moving
            stillSince = nil
            return false
        }
        if diff > stillThreshold {
            // Zwischenbereich: weder klar bewegt noch ruhig; Ruhezeit läuft nicht.
            stillSince = nil
            return false
        }
        switch state {
        case .idle:
            return false
        case .moving:
            state = .settling
            stillSince = time
            return false
        case .settling:
            // Nach einem Zittern läuft die Ruhezeit neu an.
            guard let since = stillSince else { stillSince = time; return false }
            guard time - since >= settleSeconds else { return false }
            state = .idle
            stillSince = nil
            return true
        }
    }

    /// Nach einer Aufnahme: Bis zur nächsten Bewegung wird nichts mehr gemeldet.
    public mutating func didCapture() {
        state = .idle
        stillSince = nil
    }

    public mutating func reset() {
        state = .idle
        previous = nil
        stillSince = nil
    }

    /// Die Kacheldifferenz, die nur der bewegteste Anteil `movingShare` der Kacheln
    /// übersteigt. Ändert sich weniger als dieser Anteil, bleibt der Wert klein.
    func motionLevel(_ a: [UInt8], _ b: [UInt8], width: Int) -> Double {
        let height = width > 0 ? a.count / width : 0
        let tile = max(1, width / tilesAcross)
        guard height >= tile else { return Self.meanAbsoluteDifference(a, b) }
        var diffs: [Double] = []
        var ty = 0
        while ty + tile <= height {
            var tx = 0
            while tx + tile <= width {
                var sum = 0
                for y in ty..<(ty + tile) {
                    let row = y * width
                    for x in tx..<(tx + tile) { sum += abs(Int(a[row + x]) - Int(b[row + x])) }
                }
                diffs.append(Double(sum) / Double(tile * tile))
                tx += tile
            }
            ty += tile
        }
        diffs.sort()
        let index = min(diffs.count - 1, Int(Double(diffs.count) * (1 - movingShare)))
        return diffs[index]
    }

    public static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
