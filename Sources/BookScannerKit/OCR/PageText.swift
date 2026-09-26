import Foundation
import CoreGraphics

/// Eine erkannte Textzeile mit ihrer Lage im Bild.
public struct RecognizedLine: Codable, Sendable, Equatable {
    public var text: String
    public var confidence: Float
    /// Normiert auf 0…1, Ursprung unten links (Vision-Konvention, passt direkt zum PDF).
    public var box: CGRect

    public init(text: String, confidence: Float, box: CGRect) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// OCR-Ergebnis einer Seite. Liegt als `OCR/<Aufnahme>.json` im Session-Ordner.
public struct PageText: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var pageID: UUID
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var languages: [String]
    public var recognizedAt: Date
    /// In Lesereihenfolge: oben nach unten, links nach rechts.
    public var lines: [RecognizedLine]

    public init(pageID: UUID, pixelWidth: Int, pixelHeight: Int, languages: [String], recognizedAt: Date = .now, lines: [RecognizedLine]) {
        self.version = Self.currentVersion
        self.pageID = pageID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.languages = languages
        self.recognizedAt = recognizedAt.roundedToMilliseconds
        self.lines = lines
    }

    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}
