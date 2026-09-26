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
            return RecognizedLine(text: text, confidence: best.confidence, box: box)
        }
        return Self.readingOrder(lines)
    }

    /// Lesereihenfolge: Zeilen, deren Mitten vertikal näher als eine halbe Zeilenhöhe
    /// beieinander liegen, bilden eine Reihe und werden nach x sortiert.
    public static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let byTop = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in byTop {
            if let reference = rows.last?.first,
               abs(reference.box.midY - line.box.midY) < min(reference.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }
}
