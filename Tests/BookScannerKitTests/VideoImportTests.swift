import Testing
import Foundation
import CoreGraphics
import CoreVideo
@preconcurrency import AVFoundation
@testable import BookScannerKit

/// Ein Abschnitt des Testvideos: eine ruhige Seite oder Umblättern als Rauschen.
private enum Segment {
    case page(seed: UInt64, seconds: Double)
    case motion(seconds: Double)
}

/// Zufallsfolge mit festem Startwert, damit eine Seite jedes Mal gleich aussieht.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Schreibt ein H.264-Video aus den Abschnitten. Seiten sind Blockmuster mit Struktur
/// in jeder Kachel, wie Text für den Kachelvergleich.
private func writeVideo(_ segments: [Segment], to url: URL, width: Int = 640, height: Int = 480,
                        fps: Int32 = 10, transform: CGAffineTransform = .identity) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    var frame: Int64 = 0
    var noise = SeededGenerator(state: 99)
    func append(fill: (inout SeededGenerator, Int, Int) -> UInt8, generator: inout SeededGenerator) throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let block = 8
        for by in 0..<(height / block) {
            for bx in 0..<(width / block) {
                let value = fill(&generator, bx, by)
                for y in (by * block)..<((by + 1) * block) {
                    let row = base + y * stride
                    for x in (bx * block)..<((bx + 1) * block) {
                        row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value; row[x * 4 + 3] = 255
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !input.isReadyForMoreMediaData { usleep(1000) }
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: frame, timescale: fps)))
        frame += 1
    }

    for segment in segments {
        switch segment {
        case .page(let seed, let seconds):
            for _ in 0..<Int(seconds * Double(fps)) {
                // Jedes Bild der Seite gleich: Startwert je Bild neu.
                var generator = SeededGenerator(state: seed)
                try append(fill: { g, _, _ in g.next() % 3 == 0 ? 30 : 230 }, generator: &generator)
            }
        case .motion(let seconds):
            for _ in 0..<Int(seconds * Double(fps)) {
                try append(fill: { g, _, _ in UInt8(truncatingIfNeeded: g.next() >> 56) }, generator: &noise)
            }
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

private final class Pages: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [(Int, Int)] = []
    func append(_ image: CGImage) { lock.withLock { sizes.append((image.width, image.height)) } }
    var all: [(Int, Int)] { lock.withLock { sizes } }
}

@Suite struct VideoImportTests {
    @Test func everyNewPageOnceIncludingFirstAndLast() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "buch.mov")
        // Erste Seite liegt schon zu Beginn still, die zweite wird nach einer Bewegung
        // noch einmal gezeigt (Hand umgesetzt), die letzte endet nach einer Sekunde Ruhe, vor Ablauf der Ruhezeit.
        try await writeVideo([
            .page(seed: 1, seconds: 2), .motion(seconds: 1),
            .page(seed: 2, seconds: 2.5), .motion(seconds: 1),
            .page(seed: 2, seconds: 2.5), .motion(seconds: 1),
            .page(seed: 3, seconds: 1.5),
        ], to: url)

        #expect(VideoPageExtractor.isSupported(url))
        #expect(!PageImporter.isSupported(url))
        let pages = Pages()
        let progress = Pages()
        try await VideoPageExtractor().extractPages(from: url, progress: { _ in progress.append(makeTestImage(width: 1, height: 1)) }) {
            pages.append($0)
        }
        #expect(pages.all.count == 3)
        #expect(pages.all.allSatisfy { $0 == (640, 480) })
        #expect(progress.all.count > 2)
    }

    @Test func portraitVideoComesOutUpright() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "hochkant.mov")
        // So speichert das iPhone ein hochkant gefilmtes Video: quer, mit Drehung um 90°.
        try await writeVideo([.page(seed: 5, seconds: 2)], to: url, transform: CGAffineTransform(rotationAngle: .pi / 2))

        let pages = Pages()
        try await VideoPageExtractor().extractPages(from: url) { pages.append($0) }
        #expect(pages.all.count == 1)
        #expect(pages.all.first.map { $0 == (480, 640) } == true)
    }

    @Test func orientationFromTrackTransform() {
        #expect(VideoPageExtractor.orientation(of: .identity) == .up)
        #expect(VideoPageExtractor.orientation(of: CGAffineTransform(rotationAngle: .pi / 2)) == .right)
        #expect(VideoPageExtractor.orientation(of: CGAffineTransform(rotationAngle: -.pi / 2)) == .left)
        #expect(VideoPageExtractor.orientation(of: CGAffineTransform(rotationAngle: .pi)) == .down)
    }

    @Test func startingStillCounts() {
        var trigger = MotionTrigger()
        trigger.settleSeconds = 1
        trigger.assumeMotion()
        let frame = [UInt8](repeating: 128, count: 32 * 32)
        var fired = false
        for step in 0..<8 { fired = trigger.feed(frame, width: 32, at: Double(step) * 0.25) || fired }
        #expect(fired)
    }
}
