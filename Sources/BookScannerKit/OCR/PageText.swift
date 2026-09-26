import Foundation
import CoreGraphics

/// Eine erkannte Textzeile mit ihrer Lage im Bild.
public struct RecognizedLine: Codable, Sendable, Equatable {
    public var text: String
    public var confidence: Float
    /// Normiert auf 0…1, Ursprung unten links (Vision-Konvention, passt direkt zum PDF).
    public var box: CGRect
    /// Richtung der Grundlinie in Radiant, 0 = waagerecht von links nach rechts,
    /// positiv gegen den Uhrzeigersinn. Verrät, ob die Seite gedreht liegt.
    public var angle: Double

    public init(text: String, confidence: Float, box: CGRect, angle: Double = 0) {
        self.text = text
        self.confidence = confidence
        self.box = box
        self.angle = angle
    }

    /// Mittlere Zeichenbreite, normiert: das verlässlichste Maß für die Schriftgröße.
    /// Die Boxhöhe schwankt je nach Ober- und Unterlängen um bis zu 40 %.
    public var charWidth: CGFloat {
        box.width / CGFloat(max(text.count, 1))
    }

    enum CodingKeys: String, CodingKey { case text, confidence, box, angle }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Float.self, forKey: .confidence)
        box = try container.decode(CGRect.self, forKey: .box)
        angle = try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0
    }
}

/// OCR-Ergebnis einer Seite. Liegt als `OCR/<Aufnahme>.json` im Session-Ordner.
public struct PageText: Codable, Sendable, Equatable {
    /// 2: Lesereihenfolge über Überlappung statt Boxhöhe; ältere Dateien werden beim Laden neu sortiert.
    public static let currentVersion = 2

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
