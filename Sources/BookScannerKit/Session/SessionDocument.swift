import Foundation

/// Wie eine Aufnahme in Einzelseiten geteilt wird. Wird in Schritt 3 ausgewertet.
public enum SplitMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case middle
    case none
}

/// Stand der Texterkennung einer Seite. Wird in Schritt 2 gefüllt.
public enum OCRStatus: String, Codable, Sendable {
    case pending
    case done
    case failed
}

public struct SessionSettings: Codable, Sendable, Equatable {
    public var splitMode: SplitMode = .automatic
    public var cropEnabled: Bool = true
    /// Textlage erkennen und das Bild aufrecht drehen, bevor es gespeichert wird.
    public var autoRotate: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case splitMode, cropEnabled, autoRotate }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        splitMode = try container.decodeIfPresent(SplitMode.self, forKey: .splitMode) ?? .automatic
        cropEnabled = try container.decodeIfPresent(Bool.self, forKey: .cropEnabled) ?? true
        autoRotate = try container.decodeIfPresent(Bool.self, forKey: .autoRotate) ?? true
    }
}

/// Eine erfasste Aufnahme. Die Bilddatei liegt neben `session.json` im Session-Ordner.
public struct PageRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let fileName: String
    public let capturedAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public var ocrStatus: OCRStatus

    public init(id: UUID = UUID(), fileName: String, capturedAt: Date, pixelWidth: Int, pixelHeight: Int, ocrStatus: OCRStatus = .pending) {
        self.id = id
        self.fileName = fileName
        self.capturedAt = capturedAt.roundedToMilliseconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.ocrStatus = ocrStatus
    }
}

/// Inhalt von `session.json`. Reihenfolge und Seiten sind getrennt, damit Umsortieren
/// nur das Array der IDs anfasst.
public struct SessionDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public let id: UUID
    public let createdAt: Date
    public var title: String?
    public var settings: SessionSettings
    /// Laufende Nummer für Dateinamen; zählt auch über Löschungen hinweg weiter.
    public var captureCounter: Int
    public var pageOrder: [UUID]
    public var pages: [PageRecord]
    public var trashed: [PageRecord]

    public init(id: UUID = UUID(), createdAt: Date, title: String? = nil) {
        self.version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt.roundedToMilliseconds
        self.title = title
        self.settings = SessionSettings()
        self.captureCounter = 0
        self.pageOrder = []
        self.pages = []
        self.trashed = []
    }

    /// Seiten in Anzeigereihenfolge. IDs ohne Seite werden übersprungen.
    public var orderedPages: [PageRecord] {
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        return pageOrder.compactMap { byID[$0] }
    }

    public func page(withID id: UUID) -> PageRecord? {
        pages.first { $0.id == id }
    }
}

extension Date {
    /// Ganze Millisekunden seit 1970, gerundet. Die Einheit, in der `session.json` denkt.
    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    /// Auf ganze Millisekunden gerundet, damit der Wert im Speicher exakt dem auf der
    /// Platte entspricht. Idempotent: zweimal runden ändert nichts mehr.
    var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: Double(millisecondsSince1970) / 1000)
    }

    /// ISO 8601 in UTC mit genau drei Nachkommastellen, aus den ganzen Millisekunden
    /// gebaut. Der Systemformatter schneidet ab statt zu runden und macht aus `.883`
    /// je nach Gleitkomma-Laune `.882`.
    var sessionTimestamp: String {
        let ms = millisecondsSince1970
        let wholeSeconds = Date(timeIntervalSince1970: Double(ms.quotientAndRemainder(dividingBy: 1000).quotient))
        let base = wholeSeconds.formatted(.iso8601)          // "2026-09-26T11:01:42Z"
        let fraction = ms.quotientAndRemainder(dividingBy: 1000).remainder
        return String(base.dropLast()) + String(format: ".%03dZ", fraction)
    }

    /// Gegenstück zu `sessionTimestamp`; nimmt auch Werte ohne Bruchteile an.
    static func fromSessionTimestamp(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(text, strategy: withFraction) { return date.roundedToMilliseconds }
        if let date = try? Date(text, strategy: .iso8601) { return date.roundedToMilliseconds }
        return nil
    }
}
