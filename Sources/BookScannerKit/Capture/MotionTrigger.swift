import Foundation

/// Bewegungsmelder für den Auto-Auslöser: aus einer Folge stark verkleinerter Graubilder
/// der Moment, in dem nach einer Bewegung Ruhe eingekehrt ist.
///
/// Zustände: *ruhig* → *Bewegung* (Umblättern, Hand im Bild) → *ruhig seit
/// `settleSeconds`* → melden. Ohne vorherige Bewegung wird nie gemeldet, damit ein
/// stilles Bild nicht laufend erfasst wird. Ob wirklich umgeblättert wurde, entscheidet
/// danach der `PageTurnJudge`. Reine Logik, ohne Kamera, darum testbar.
public struct MotionTrigger: Sendable {
    public enum State: Sendable, Equatable { case idle, moving, settling }

    /// Mittlere Pixeldifferenz (0…255) zum Vorbild, ab der Bewegung gilt.
    public var motionThreshold: Double = 6
    /// Darunter gilt das Bild als ruhig.
    public var stillThreshold: Double = 2.5
    /// So lange muss Ruhe herrschen, bevor gemeldet wird.
    public var settleSeconds: TimeInterval = 1.5

    public private(set) var state: State = .idle
    private var previous: [UInt8]?
    private var stillSince: TimeInterval?

    public init() {}

    /// Nächstes Bild; `true` heißt: Das Bild steht nach einer Bewegung still.
    public mutating func feed(_ frame: [UInt8], at time: TimeInterval) -> Bool {
        defer { previous = frame }
        guard let previous, previous.count == frame.count else { return false }
        let diff = Self.meanAbsoluteDifference(previous, frame)

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

    public static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
