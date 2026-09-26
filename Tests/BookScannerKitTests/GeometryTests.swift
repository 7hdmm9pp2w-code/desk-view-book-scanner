import Testing
import Foundation
import CoreGraphics
@testable import BookScannerKit

/// Doppelseite: weiß, mit dunklem Falz an `gutter` (Anteil der Breite) und Textblöcken.
func makeDoublePage(width: Int = 1600, height: Int = 1000, gutter: Double? = 0.52) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1))
    // Textzeilen als graue Balken links und rechts.
    for y in stride(from: 100, to: height - 100, by: 40) {
        context.fill(CGRect(x: 80, y: y, width: Int(Double(width) * 0.36), height: 12))
        context.fill(CGRect(x: Int(Double(width) * 0.58), y: y, width: Int(Double(width) * 0.36), height: 12))
    }
    if let gutter {
        context.setFillColor(CGColor(red: 0.35, green: 0.33, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: Int(Double(width) * gutter) - 12, y: 0, width: 24, height: height))
    }
    return context.makeImage()!
}

@Suite struct GeometryTests {
    @Test func rotationRoundTrip() {
        let image = makeTestImage(width: 300, height: 200)
        let once = ImageOps.rotated(image, quarterTurns: 1)
        #expect(once.width == 200 && once.height == 300)
        let back = ImageOps.rotated(once, quarterTurns: -1)
        #expect(back.width == 300 && back.height == 200)
        #expect(ImageOps.rotated(image, quarterTurns: 4).width == 300)
    }

    @Test func orientationDetectorFindsUpright() async throws {
        let (image, _) = renderTextImage(width: 1400, height: 900, lines: [
            ("Nicht fünfzig, sondern fast 120 Jahre trennen uns", 44, 700),
            ("heute von Bakunins Tod, und dementsprechend", 44, 600),
            ("vieles hat sich verändert seit jener Zeit.", 44, 500),
        ])
        let detector = OrientationDetector()
        #expect(try await detector.quarterTurns(for: image) == 0)
        // Um 90° gedreht gespeichert: der Detektor liefert die Drehung zurück, die es aufrichtet.
        for turns in 1...3 {
            let rotated = ImageOps.rotated(image, quarterTurns: turns)
            let needed = try await detector.quarterTurns(for: rotated)
            #expect((turns + needed) % 4 == 0, "gedreht um \(turns), Detektor sagt \(needed)")
        }
    }

    @Test func gutterIsFoundAndSplitProducesTwoPages() {
        let image = makeDoublePage(gutter: 0.52)
        let splitter = PageSplitter()
        #expect(splitter.isDoublePage(image))
        let fraction = try! #require(splitter.gutterFraction(in: image))
        #expect(abs(fraction - 0.52) < 0.02)
        let halves = splitter.split(image, mode: .automatic)
        #expect(halves.count == 2)
        #expect(abs(Double(halves[0].width) / Double(image.width) - 0.52) < 0.02)
        #expect(halves[0].width + halves[1].width == image.width)
    }

    @Test func noGutterFallsBackToMiddleAndPortraitStaysWhole() {
        let plain = makeDoublePage(gutter: nil)
        let splitter = PageSplitter()
        #expect(splitter.gutterFraction(in: plain) == nil)
        let halves = splitter.split(plain, mode: .automatic)
        #expect(halves.count == 2 && halves[0].width == plain.width / 2)
        #expect(splitter.split(plain, mode: .none).count == 1)
        let portrait = makeTestImage(width: 800, height: 1200)
        #expect(splitter.split(portrait, mode: .automatic).count == 1)
    }

    @Test func replacePageKeepsOrderAndTrashesOriginal() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let a = try await store.addPage(makeTestImage(width: 10, height: 10))
        let b = try await store.addPage(makeTestImage(width: 10, height: 10))
        let c = try await store.addPage(makeTestImage(width: 10, height: 10))

        let halves = try await store.replacePage(b.id, with: [makeTestImage(width: 5, height: 10), makeTestImage(width: 5, height: 10)])

        let order = await store.orderedPages.map(\.id)
        #expect(order == [a.id, halves[0].id, halves[1].id, c.id])
        #expect(await store.document.trashed.map(\.id) == [b.id])
        #expect(FileManager.default.fileExists(atPath: await store.trashDirectory.appending(path: b.fileName).path))
    }

    @Test func textAcrossTheCutPreventsSplitting() {
        let image = makeDoublePage(gutter: 0.52)
        let splitter = PageSplitter()
        let title = line("Jean Baudrillard Agonie des Realen", x: 0.2, top: 0.7, width: 0.6, confidence: 0.9)
        #expect(splitter.split(image, mode: .automatic, lines: [title]).count == 1)
        #expect(splitter.split(image, mode: .middle, lines: [title]).count == 1)
        // Zeilen, die vor dem Falz enden oder danach beginnen, stören nicht.
        let leftText = line("links", x: 0.05, top: 0.7, width: 0.4, confidence: 0.9)
        let rightText = line("rechts", x: 0.58, top: 0.7, width: 0.4, confidence: 0.9)
        #expect(splitter.split(image, mode: .automatic, lines: [leftText, rightText]).count == 2)
        // Unsichere Zeilen zählen nicht.
        let noise = line("???", x: 0.2, top: 0.7, width: 0.6, confidence: 0.2)
        #expect(splitter.split(image, mode: .automatic, lines: [noise]).count == 2)
    }

    @Test func cutStaysInsideTheTextFreeGap() {
        // Dunkle Spalte bei 40 %, mitten im linken Textblock (Seite taucht in den Falz ab);
        // Text links bis 45 %, rechts ab 55 %. Der Schnitt muss in die Lücke.
        let image = makeDoublePage(gutter: 0.40)
        var lines: [RecognizedLine] = []
        for i in 0..<6 {
            lines.append(line("links \(i)", x: 0.05, top: 0.9 - Double(i) * 0.05, width: 0.40, confidence: 0.9))
            lines.append(line("rechts \(i)", x: 0.55, top: 0.9 - Double(i) * 0.05, width: 0.40, confidence: 0.9))
        }
        let splitter = PageSplitter()
        let gap = try! #require(splitter.textFreeGap(in: lines))
        #expect(abs(gap.lowerBound - 0.45) < 0.01 && abs(gap.upperBound - 0.55) < 0.01)
        let cut = try! #require(splitter.cutFraction(for: image, mode: .automatic, lines: lines))
        #expect(cut >= 0.45 && cut <= 0.55)
        // Ohne Zeilen greift das Tal bei 40 % (altes Verhalten als Rückfall).
        let blind = try! #require(splitter.cutFraction(for: image, mode: .automatic, lines: []))
        #expect(abs(blind - 0.40) < 0.02)
        // Zu wenig Zeilen: keine Lücke.
        #expect(splitter.textFreeGap(in: Array(lines.prefix(2))) == nil)
    }

    @Test func normalizedRectRotatesWithImage() {
        // Rechts-Mitte wandert bei einer Vierteldrehung nach oben-Mitte.
        let rect = CGRect(x: 0.8, y: 0.45, width: 0.2, height: 0.1)
        let once = ImageOps.rotatedNormalizedRect(rect, quarterTurns: 1)
        #expect(abs(once.midX - 0.5) < 1e-9 && abs(once.midY - 0.9) < 1e-9)
        #expect(abs(once.width - 0.1) < 1e-9 && abs(once.height - 0.2) < 1e-9)
        let full = ImageOps.rotatedNormalizedRect(rect, quarterTurns: 4)
        #expect(full == rect)
        let twice = ImageOps.rotatedNormalizedRect(rect, quarterTurns: 2)
        #expect(abs(twice.midX - 0.1) < 1e-9 && abs(twice.midY - 0.5) < 1e-9)
    }

    @Test func analyzeReturnsLinesMatchingTheUprightImage() async throws {
        let (image, _) = renderTextImage(width: 1400, height: 900, lines: [
            ("Nicht fünfzig, sondern fast 120 Jahre trennen uns", 44, 700),
        ])
        let rotated = ImageOps.rotated(image, quarterTurns: 1)
        let analysis = try await OrientationDetector().analyze(rotated)
        #expect(analysis.quarterTurns == 3)
        let box = try #require(analysis.lines.first?.box)
        // Im aufgerichteten Bild ist die Zeile breit und liegt oben.
        #expect(box.width > box.height * 3)
        #expect(box.midY > 0.6)
    }

    @Test func restoreLastTrashedPutsPageBack() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let a = try await store.addPage(makeTestImage(width: 10, height: 10))
        let b = try await store.addPage(makeTestImage(width: 10, height: 10))
        try await store.trash(pageIDs: [a.id])
        #expect(await store.orderedPages.map(\.id) == [b.id])

        let restored = try await store.restoreLastTrashed(before: b.id)
        #expect(restored?.id == a.id)
        #expect(await store.orderedPages.map(\.id) == [a.id, b.id])
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(for: a).path))
        #expect(await store.document.trashed.isEmpty)
        #expect(try await store.restoreLastTrashed() == nil)
    }

    @Test func settingsDecodeWithoutNewKeys() throws {
        let json = #"{"splitMode":"middle","cropEnabled":false}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(SessionSettings.self, from: json)
        #expect(settings.splitMode == .middle && settings.cropEnabled == false && settings.autoRotate == true)
    }
}
