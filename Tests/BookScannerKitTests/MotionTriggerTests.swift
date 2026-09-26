import Testing
import Foundation
@testable import BookScannerKit

@Suite struct MotionTriggerTests {
    func frame(_ value: UInt8, count: Int = 100) -> [UInt8] { [UInt8](repeating: value, count: count) }

    @Test func firesAfterMotionAndSettling() {
        var trigger = MotionTrigger()
        var t: TimeInterval = 0
        func step(_ f: [UInt8]) -> Bool { t += 0.25; return trigger.feed(f, at: t) }
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
        func step(_ f: [UInt8]) -> Bool { t += 0.25; return trigger.feed(f, at: t) }
        _ = step(frame(100)); _ = step(frame(150))
        for _ in 0..<4 { _ = step(frame(150)) }
        _ = step(frame(154))   // Zittern, Differenz 4: weder Bewegung noch Ruhe
        var fired = false
        for _ in 0..<4 { fired = step(frame(154)) || fired }
        #expect(!fired)        // Uhr lief neu an
        for _ in 0..<3 { fired = step(frame(154)) || fired }
        #expect(fired)
    }

    @Test func meanDifference() {
        #expect(abs(MotionTrigger.meanAbsoluteDifference([0, 10, 20], [10, 10, 30]) - 20.0 / 3) < 1e-9)
        #expect(MotionTrigger.meanAbsoluteDifference([], []) == 0)
        #expect(CameraSource.availableDevices().allSatisfy { !$0.name.isEmpty })
    }
}
