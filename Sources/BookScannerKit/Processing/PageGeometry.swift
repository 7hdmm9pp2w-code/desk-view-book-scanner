import Foundation
import CoreGraphics

/// Drehen, Beschneiden, Verkleinern über CoreGraphics. Keine Farbverwaltung, keine Filter.
public enum ImageOps {
    /// Dreht um Vielfache von 90°; positive Werte gegen den Uhrzeigersinn.
    public static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let width = image.width, height = image.height
        let (newWidth, newHeight) = turns % 2 == 0 ? (width, height) : (height, width)
        let context = makeContext(width: newWidth, height: newHeight)
        context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Dreht ein normiertes Rechteck (0…1, Ursprung unten links) mit dem Bild mit.
    public static func rotatedNormalizedRect(_ rect: CGRect, quarterTurns: Int) -> CGRect {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return rect }
        func map(_ p: CGPoint) -> CGPoint {
            switch turns {
            case 1: return CGPoint(x: 1 - p.y, y: p.x)
            case 2: return CGPoint(x: 1 - p.x, y: 1 - p.y)
            default: return CGPoint(x: p.y, y: 1 - p.x)
            }
        }
        let corners = [rect.origin, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map(map)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Ausschnitt in Pixeln, Ursprung oben links (CGImage-Konvention).
    public static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage {
        image.cropping(to: rect.integral) ?? image
    }

    /// Verkleinerte Kopie, längste Kante höchstens `maxPixelSize`.
    public static func downscaled(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize else { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let context = makeContext(width: width, height: height)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Helligkeit 0…255 je Pixel, zeilenweise von oben nach unten.
    public static func grayPixels(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (pixels, width, height)
    }

    static func makeContext(width: Int, height: Int) -> CGContext {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}

/// Findet heraus, wie das Bild gedreht werden muss, damit der Text aufrecht steht.
/// Visions genaue Erkennung liest auch gedrehten Text und liefert dazu das Viereck
/// jeder Zeile; die Richtung der Oberkante verrät die Lage. Gewichtete Abstimmung über
/// alle Zeilen, damit eine falsch gelesene Zeile nicht die Seite kippt.
public struct OrientationDetector: Sendable {
    public var maxPixelSize = 1600
    public var minimumConfidence: Float = 0.3
    public var languages = ["de-DE", "en-US"]

    public init() {}

    /// Vierteldrehungen gegen den Uhrzeigersinn, die das Bild aufrecht stellen (0…3).
    public func quarterTurns(for image: CGImage) async throws -> Int {
        try await analyze(image).quarterTurns
    }

    /// Erkennung auf der kleinen Kopie plus daraus abgeleitete Drehung. Die Zeilen sind
    /// bereits so gedreht, dass sie zum aufgerichteten Bild passen.
    public func analyze(_ image: CGImage) async throws -> (lines: [RecognizedLine], quarterTurns: Int) {
        let small = ImageOps.downscaled(image, maxPixelSize: maxPixelSize)
        var recognizer = TextRecognizer()
        recognizer.languages = languages
        recognizer.usesLanguageCorrection = false
        let lines = try await recognizer.recognize(small)
        let turns = Self.quarterTurns(for: lines, minimumConfidence: minimumConfidence)
        let rotated = lines.map { line in
            var copy = line
            copy.box = ImageOps.rotatedNormalizedRect(line.box, quarterTurns: turns)
            copy.angle = 0
            return copy
        }
        return (rotated, turns)
    }

    public static func quarterTurns(for lines: [RecognizedLine], minimumConfidence: Float = 0.3) -> Int {
        var votes = [Double](repeating: 0, count: 4)
        for line in lines where line.confidence >= minimumConfidence {
            // Grundlinie zeigt nach rechts (0), oben (+90°), links (±180°) oder unten (−90°).
            let quadrant = Int((line.angle / (.pi / 2)).rounded())
            let needed = ((-quadrant % 4) + 4) % 4
            votes[needed] += Double(line.confidence) * Double(max(line.text.count, 1))
        }
        guard let best = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[best] > 0 else { return 0 }
        return best
    }
}

/// Teilt Doppelseiten am Falz.
public struct PageSplitter: Sendable {
    /// Ab diesem Seitenverhältnis gilt ein Bild als Doppelseite.
    public var landscapeRatio = 1.15
    /// Suchbereich für das Tal, als Anteil der Breite.
    public var searchRange: ClosedRange<Double> = 0.35...0.65
    /// So viel dunkler als der Median muss das Tal sein (0…255), sonst gilt es nicht.
    public var minimumDepth = 20.0

    public init() {}

    public func isDoublePage(_ image: CGImage) -> Bool {
        Double(image.width) / Double(max(image.height, 1)) >= landscapeRatio
    }

    /// Kreuzt eine sichere Textzeile die Schnittlinie mit so viel Anteil auf beiden
    /// Seiten, ist es keine Doppelseite (Umschlag, Tabelle, Querformat-Text).
    public var crossingShare = 0.15
    public var crossingConfidence: Float = 0.5

    /// Zwei Hälften oder das Bild unverändert. `lines` (normiert, zum Bild passend)
    /// bestimmen die textfreie Lücke für den Schnitt und verhindern das Teilen, wenn
    /// Text über die Schnittlinie läuft.
    public func split(_ image: CGImage, mode: SplitMode, lines: [RecognizedLine] = []) -> [CGImage] {
        guard mode != .none, isDoublePage(image) else { return [image] }
        guard let fraction = cutFraction(for: image, mode: mode, lines: lines) else { return [image] }
        let cut = Int((Double(image.width) * fraction).rounded())
        let left = ImageOps.cropped(image, to: CGRect(x: 0, y: 0, width: cut, height: image.height))
        let right = ImageOps.cropped(image, to: CGRect(x: cut, y: 0, width: image.width - cut, height: image.height))
        return [left, right]
    }

    /// Wo geschnitten wird, als Anteil der Breite; `nil` heißt: nicht teilen.
    ///
    /// Automatik: Erst die textfreie Lücke zwischen linkem und rechtem Textblock aus den
    /// OCR-Zeilen, dann darin das Helligkeitstal, sonst die Lückenmitte. Ohne Zeilen
    /// bleibt nur das Tal über den ganzen Suchbereich. Bei gewölbten Büchern liegt die
    /// dunkelste Spalte oft vor dem Falz, wo die Seite abtaucht; die Lücke aus dem
    /// Text hält den Schnitt davon fern.
    public func cutFraction(for image: CGImage, mode: SplitMode, lines: [RecognizedLine]) -> Double? {
        let fraction: Double
        switch mode {
        case .none:
            return nil
        case .middle:
            fraction = 0.5
        case .automatic:
            if let gap = textFreeGap(in: lines) {
                fraction = gutterFraction(in: image, within: gap, minimumDepth: minimumDepth / 2) ?? (gap.lowerBound + gap.upperBound) / 2
            } else {
                fraction = gutterFraction(in: image, within: searchRange, minimumDepth: minimumDepth) ?? 0.5
            }
        }
        return textCrosses(cut: fraction, lines: lines) ? nil : fraction
    }

    /// Breiteste textfreie Lücke, deren Mitte im Suchbereich liegt und die links wie
    /// rechts Text hat. `nil` bei zu wenig Zeilen.
    public func textFreeGap(in lines: [RecognizedLine], resolution: Int = 1000) -> ClosedRange<Double>? {
        let usable = lines.filter { $0.confidence >= crossingConfidence && $0.box.width >= 0.05 }
        guard usable.count >= 4 else { return nil }
        var covered = [Bool](repeating: false, count: resolution)
        for line in usable {
            let lo = max(0, Int(Double(line.box.minX) * Double(resolution)))
            let hi = min(resolution - 1, Int(Double(line.box.maxX) * Double(resolution)))
            if lo <= hi { for i in lo...hi { covered[i] = true } }
        }
        var best: ClosedRange<Int>?
        var start: Int?
        for i in 0...resolution {
            let free = i < resolution && !covered[i]
            if free, start == nil { start = i }
            if !free, let s = start {
                let run = s...(i - 1)
                let center = Double(run.lowerBound + run.upperBound) / 2 / Double(resolution)
                let hasTextLeft = covered[..<run.lowerBound].contains(true)
                let hasTextRight = run.upperBound + 1 < resolution && covered[(run.upperBound + 1)...].contains(true)
                if searchRange.contains(center), hasTextLeft, hasTextRight, run.count > (best?.count ?? 0) {
                    best = run
                }
                start = nil
            }
        }
        guard let best, best.count >= resolution / 100 else { return nil }
        return (Double(best.lowerBound) / Double(resolution))...(Double(best.upperBound + 1) / Double(resolution))
    }

    public func textCrosses(cut: Double, lines: [RecognizedLine]) -> Bool {
        lines.contains { line in
            guard line.confidence >= crossingConfidence, line.box.width > 0 else { return false }
            let left = cut - Double(line.box.minX)
            let right = Double(line.box.maxX) - cut
            let minimum = Double(line.box.width) * crossingShare
            return left >= minimum && right >= minimum
        }
    }

    /// Lage des dunkelsten Tals im Suchbereich als Anteil der Breite, `nil` ohne klares Tal.
    public func gutterFraction(in image: CGImage) -> Double? {
        gutterFraction(in: image, within: searchRange, minimumDepth: minimumDepth)
    }

    public func gutterFraction(in image: CGImage, within range: ClosedRange<Double>, minimumDepth: Double) -> Double? {
        let small = ImageOps.downscaled(image, maxPixelSize: 600)
        let (pixels, width, height) = ImageOps.grayPixels(small)
        guard width > 10, height > 10 else { return nil }
        // Nur der mittlere Teil der Höhe, Ränder und Kopfzeilen stören.
        let rows = (height / 5)..<(height * 4 / 5)
        var profile = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var sum = 0
            for y in rows { sum += Int(pixels[y * width + x]) }
            profile[x] = Double(sum) / Double(rows.count)
        }
        // Glätten, Fenster 5.
        let smoothed = (0..<width).map { x -> Double in
            let lo = max(0, x - 2), hi = min(width - 1, x + 2)
            return smoothed(profile, lo...hi)
        }
        let median = smoothed.sorted()[width / 2]
        let lower = max(0, Int(Double(width) * range.lowerBound))
        let upper = min(width - 1, Int(Double(width) * range.upperBound))
        guard lower < upper else { return nil }
        var bestX = lower
        for x in lower...upper where smoothed[x] < smoothed[bestX] { bestX = x }
        guard median - smoothed[bestX] >= minimumDepth else { return nil }
        return Double(bestX) / Double(width)
    }

    private func smoothed(_ values: [Double], _ range: ClosedRange<Int>) -> Double {
        var sum = 0.0
        for i in range { sum += values[i] }
        return sum / Double(range.count)
    }
}
