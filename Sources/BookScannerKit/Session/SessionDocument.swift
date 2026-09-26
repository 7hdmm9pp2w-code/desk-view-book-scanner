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

    public init() {}
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
    /// Das Format, in dem `session.json` Zeitstempel speichert.
    static let sessionFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Einmal durch das Dateiformat und zurück, damit der Wert im Speicher exakt dem
    /// auf der Platte entspricht (Gleitkomma macht `.883` sonst zu `.882`).
    var roundedToMilliseconds: Date {
        (try? Date(formatted(Self.sessionFormat), strategy: Self.sessionFormat)) ?? self
    }
}
