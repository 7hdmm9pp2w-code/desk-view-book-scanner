import Foundation
import CoreGraphics
import Vision

/// Texterkennung über Vision. Behält die Bounding Boxes, das PDF braucht sie.
public struct TextRecognizer: Sendable {
    public var languages: [String] = ["de-DE", "en-US"]
    public var accurate = true
    public var usesLanguageCorrection = true

    public init() {}

    public func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = false

        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { observation -> RecognizedLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox.toImageCoordinates(CGSize(width: 1, height: 1), origin: .lowerLeft)
            let unit = CGSize(width: 1, height: 1)
            let start = observation.topLeft.toImageCoordinates(unit, origin: .lowerLeft)
            let end = observation.topRight.toImageCoordinates(unit, origin: .lowerLeft)
            let angle = atan2(Double(end.y - start.y), Double(end.x - start.x))
            return RecognizedLine(text: text, confidence: best.confidence, box: box, angle: angle)
        }
        return Self.readingOrder(lines)
    }

    /// Lesereihenfolge: oben nach unten, innerhalb einer Reihe links nach rechts.
    /// Zwei Zeilen bilden nur dann eine Reihe, wenn sie sich vertikal deutlich überlappen
    /// und horizontal nicht (Spalten). Der Vergleich über die Boxhöhe allein trügt: Bei
    /// einer leicht schiefen Seite ist die Box einer breiten Zeile ein Vielfaches höher
    /// als die Zeile selbst, und Nachbarzeilen würden zu einer Reihe verschmelzen.
    public static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let byTop = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in byTop {
            if let row = rows.last, row.allSatisfy({ sameRow($0, line) }) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    static func sameRow(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        let verticalOverlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
        let horizontalOverlap = min(a.box.maxX, b.box.maxX) - max(a.box.minX, b.box.minX)
        let minHeight = min(a.box.height, b.box.height)
        let minWidth = min(a.box.width, b.box.width)
        return verticalOverlap > minHeight * 0.5 && horizontalOverlap < minWidth * 0.2
    }
}
