import Testing
import Foundation
@testable import BookScannerKit

@Suite struct MotionTriggerTests {
    func frame(_ value: UInt8, count: Int = 100) -> [UInt8] { [UInt8](repeating: value, count: count) }

    @Test func firesAfterMotionAndSettling() {
        var trigger = MotionTrigger()
        var t: TimeInterval = 0
        func step(_ f: [UInt8]) -> Bool { t += 0.25; return trigger.feed(f, width: 10, at: t) }
        // Ruhe am Anfang: nie auslösen.
        for _ in 0..<8 { #expect(!step(frame(100))) }
        #expect(trigger.state == .idle)
        // Umblättern: starke Änderungen.
        #expect(!step(frame(140)))
        #expect(!step(frame(90)))
        #expect(trigger.state == .moving)
        // Ruhe auf neuem Bild: erst nach 1,5 s melden.
        var fired = false
        for _ in 0..<5 { fired = step(frame(160)) || fired }
        #expect(!fired)
        for _ in 0..<3 { fired = step(frame(160)) || fired }
        #expect(fired)
        #expect(trigger.state == .idle)
        trigger.didCapture()
        // Wieder Ruhe ohne Bewegung: nichts.
        for _ in 0..<10 { #expect(!step(frame(160))) }
    }

    @Test func intermediateJitterRestartsTheClock() {
        var trigger = MotionTrigger()
        var t: TimeInterval = 0
        func step(_ f: [UInt8]) -> Bool { t += 0.25; return trigger.feed(f, width: 10, at: t) }
        _ = step(frame(100)); _ = step(frame(150))
        for _ in 0..<4 { _ = step(frame(150)) }
        _ = step(frame(154))   // Zittern, Differenz 4: weder Bewegung noch Ruhe
        var fired = false
        for _ in 0..<4 { fired = step(frame(154)) || fired }
        #expect(!fired)        // Uhr lief neu an
        for _ in 0..<3 { fired = step(frame(154)) || fired }
        #expect(fired)
    }

    /// 160 × 120, Seite in Grau, zwei Hände als helle Flecken am linken und rechten Rand.
    func book(page: UInt8, handOffset: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: page, count: 160 * 120)
        for y in 70..<110 {
            for x in 0..<160 where (x >= 2 + handOffset && x < 22 + handOffset) || (x >= 136 - handOffset && x < 156 - handOffset) {
                pixels[y * 160 + x] = 210
            }
        }
        return pixels
    }

    @Test func holdingHandsNeitherMoveNorBlockTheSettle() {
        var trigger = MotionTrigger()
        var t: TimeInterval = 0
        func step(_ f: [UInt8]) -> Bool { t += 0.25; return trigger.feed(f, width: 160, at: t) }
        // Hände zittern und rutschen, die Seite liegt: keine Bewegung.
        for i in 0..<12 { #expect(!step(book(page: 100, handOffset: i % 3 * 6))) }
        #expect(trigger.state == .idle)
        // Umblättern: die ganze Seite ändert sich.
        _ = step(book(page: 170, handOffset: 0))
        #expect(trigger.state == .moving)
        // Neue Seite liegt, die Hände zittern weiter: trotzdem nach 1,5 s melden.
        var fired = false
        for i in 0..<8 { fired = step(book(page: 60, handOffset: i % 3 * 6)) || fired }
        #expect(fired)
    }

    @Test func meanDifference() {
        #expect(abs(MotionTrigger.meanAbsoluteDifference([0, 10, 20], [10, 10, 30]) - 20.0 / 3) < 1e-9)
        #expect(MotionTrigger.meanAbsoluteDifference([], []) == 0)
        #expect(CameraSource.availableDevices().allSatisfy { !$0.name.isEmpty })
    }
}

/// Wie die Kamera eine Buchseite liefert: volle Auflösung, feine Schrift, Rauschen des
/// Sensors, und die Seite verrutscht einmal um ein Pixel.
@Suite struct MotionTriggerCameraTests {
    static let width = 960, height = 720

    /// Zufallszahlen mit festem Startwert, damit der Test immer gleich läuft.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        /// Ungefähr normalverteilt, Mittel 0, Streuung `sigma`.
        mutating func noise(_ sigma: Double) -> Int {
            var sum = 0.0
            for _ in 0..<4 { sum += Double(next() % 1000) / 1000 }
            return Int(((sum - 2) * 1.73 * sigma).rounded())
        }
    }

    /// Schriftbild einer Seite: Zeilen aus zufälligen, zwei Pixel breiten Strichen.
    static func text(seed: UInt64) -> [UInt8] {
        var random = Random(state: seed)
        var ink = [UInt8](repeating: 0, count: width * height)
        for y in stride(from: 40, to: height - 40, by: 14) {
            var x = width / 5
            while x < width * 4 / 5 {
                if random.next() % 3 != 0 {
                    for dy in 0..<8 { for dx in 0..<2 { ink[(y + dy) * width + x + dx] = 1 } }
                }
                x += 3
            }
        }
        return ink
    }

    /// Ein Kamerabild als BGRA: Seite in Hellgrau, Schrift dunkel, verschoben und verrauscht.
    static func cameraFrame(_ ink: [UInt8], shiftX: Int, shiftY: Int, random: inout Random) -> [UInt8] {
        var bgra = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sx = min(max(x - shiftX, 0), width - 1), sy = min(max(y - shiftY, 0), height - 1)
                let base = ink[sy * width + sx] == 1 ? 40 : 225
                let v = UInt8(min(255, max(0, base + random.noise(3))))
                let i = (y * width + x) * 4
                bgra[i] = v; bgra[i + 1] = v; bgra[i + 2] = v
            }
        }
        return bgra
    }

    static func thumbnail(_ bgra: [UInt8]) -> [UInt8] {
        bgra.withUnsafeBytes {
            CameraSource.grayThumbnail(bgra: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4, targetWidth: 160)
        }
    }

    /// Nur jedes n-te Pixel genommen, lag hier schon das Rauschen über der Ruheschwelle:
    /// Eine ruhig liegende Textseite galt als bewegt, der Auslöser kam nie.
    @Test func textPageSettlesDespiteNoise() {
        var trigger = MotionTrigger()
        var random = Random(state: 7)
        var t: TimeInterval = 0
        let thumbWidth = Self.width / (Self.width / 160)
        func step(_ ink: [UInt8], shiftY: Int = 0) -> Bool {
            t += 0.25
            let frame = Self.cameraFrame(ink, shiftX: 0, shiftY: shiftY, random: &random)
            return trigger.feed(Self.thumbnail(frame), width: thumbWidth, at: t)
        }
        let before = Self.text(seed: 1), after = Self.text(seed: 2)
        // Ruhig liegende Seite: keine Bewegung.
        for _ in 0..<6 { #expect(!step(before)) }
        #expect(trigger.state == .idle)
        // Umblättern: neue Schrift.
        _ = step(after)
        #expect(trigger.state == .moving)
        // Die neue Seite liegt und rauscht, verrutscht einmal: danach nach 1,5 s melden.
        var fired = false
        for _ in 0..<3 { fired = step(after) || fired }
        for _ in 0..<9 { fired = step(after, shiftY: 1) || fired }
        #expect(fired)
    }
}
