import Foundation
import CoreGraphics

public enum SessionError: Error, LocalizedError, Equatable {
    case documentMissing(URL)
    case unknownPage(UUID)

    public var errorDescription: String? {
        switch self {
        case .documentMissing(let url):
            return "Keine session.json in \(url.path)"
        case .unknownPage(let id):
            return "Unbekannte Seite \(id.uuidString)"
        }
    }
}

/// Eine Session ist ein Ordner auf der Platte. Jede Änderung wird sofort in
/// `session.json` geschrieben; Bilder liegen als HEIC daneben. Gelöschte Seiten
/// wandern in den Unterordner `Papierkorb`.
public actor SessionStore {
    public static let documentFileName = "session.json"
    public static let trashDirectoryName = "Papierkorb"
    public static let textDirectoryName = "OCR"
    public static let imageFileExtension = "heic"

    public private(set) var directory: URL
    public internal(set) var document: SessionDocument

    private init(directory: URL, document: SessionDocument) {
        self.directory = directory
        self.document = document
    }

    // MARK: Anlegen und Öffnen

    /// Legt `<root>/<Datum Uhrzeit>/` an, bei Kollision mit Suffix.
    public static func create(in rootDirectory: URL, title: String? = nil, now: Date = .now) throws -> SessionStore {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let base = Self.directoryName(for: now)
        var directory = rootDirectory.appending(path: base, directoryHint: .isDirectory)
        var suffix = 2
        while fm.fileExists(atPath: directory.path) {
            directory = rootDirectory.appending(path: "\(base) (\(suffix))", directoryHint: .isDirectory)
            suffix += 1
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)

        let document = SessionDocument(createdAt: now, title: title)
        try write(document, to: directory)
        return SessionStore(directory: directory, document: document)
    }

    public static func open(directory: URL) throws -> SessionStore {
        let url = directory.appending(path: documentFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionError.documentMissing(directory)
        }
        let data = try Data(contentsOf: url)
        let document = try Self.decoder.decode(SessionDocument.self, from: data)
        return SessionStore(directory: directory, document: document)
    }

    /// Alle Session-Ordner unter `root`, neueste zuerst.
    public static func sessionDirectories(in root: URL) -> [URL] {
        let fm = FileManager.default
        // Über Namen statt URLs, damit der Aufrufer sein Präfix behält
        // (contentsOfDirectory(at:) löst /var nach /private/var auf).
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return names
            .map { root.appending(path: $0, directoryHint: .isDirectory) }
            .filter { fm.fileExists(atPath: $0.appending(path: documentFileName).path) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }

    public static func directoryName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    // MARK: Seiten

    public var orderedPages: [PageRecord] { document.orderedPages }
    public var pageCount: Int { document.pageOrder.count }

    public func fileURL(for page: PageRecord) -> URL {
        directory.appending(path: page.fileName)
    }

    public var trashDirectory: URL {
        directory.appending(path: Self.trashDirectoryName, directoryHint: .isDirectory)
    }

    public var textDirectory: URL {
        directory.appending(path: Self.textDirectoryName, directoryHint: .isDirectory)
    }

    /// `OCR/Aufnahme-0001.json` zu `Aufnahme-0001.heic`.
    public func textFileURL(for page: PageRecord) -> URL {
        let base = (page.fileName as NSString).deletingPathExtension
        return textDirectory.appending(path: base + ".json")
    }

    // MARK: OCR-Text

    public func saveText(_ text: PageText, for page: PageRecord) throws {
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(text)
        try data.write(to: textFileURL(for: page), options: .atomic)
        try updateOCRStatus(.done, for: page.id)
    }

    /// `nil`, wenn noch kein Text erkannt wurde.
    public func loadText(for page: PageRecord) throws -> PageText? {
        let url = textFileURL(for: page)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        var text = try Self.decoder.decode(PageText.self, from: data)
        if text.version < PageText.currentVersion {
            text.lines = TextRecognizer.readingOrder(text.lines)
            text.version = PageText.currentVersion
            try Self.encoder.encode(text).write(to: url, options: .atomic)
        }
        return text
    }

    /// Schreibt das Bild als HEIC in den Session-Ordner und hängt die Seite ans Ende.
    @discardableResult
    public func addPage(_ image: CGImage, capturedAt: Date = .now) throws -> PageRecord {
        document.captureCounter += 1
        let fileName = String(format: "Aufnahme-%04d.%@", document.captureCounter, Self.imageFileExtension)
        let url = directory.appending(path: fileName)
        try ImageFile.writeHEIC(image, to: url)
        let stored = ImageFile.pixelSize(of: url) ?? (image.width, image.height)

        let page = PageRecord(fileName: fileName, capturedAt: capturedAt, pixelWidth: stored.width, pixelHeight: stored.height)
        document.pages.append(page)
        document.pageOrder.append(page.id)
        try save()
        return page
    }

    /// Ersetzt eine Seite an Ort und Stelle durch ein oder mehrere Bilder (Teilen,
    /// Drehen). Die alte Seite wandert in den Papierkorb.
    @discardableResult
    public func replacePage(_ id: UUID, with images: [CGImage], capturedAt: Date = .now) throws -> [PageRecord] {
        guard let index = document.pageOrder.firstIndex(of: id), !images.isEmpty else {
            throw SessionError.unknownPage(id)
        }
        var records: [PageRecord] = []
        for image in images {
            document.captureCounter += 1
            let fileName = String(format: "Aufnahme-%04d.%@", document.captureCounter, Self.imageFileExtension)
            let url = directory.appending(path: fileName)
            try ImageFile.writeHEIC(image, to: url)
            let stored = ImageFile.pixelSize(of: url) ?? (image.width, image.height)
            let record = PageRecord(fileName: fileName, capturedAt: capturedAt, pixelWidth: stored.width, pixelHeight: stored.height)
            document.pages.append(record)
            records.append(record)
        }
        document.pageOrder.replaceSubrange(index...index, with: records.map(\.id))
        try trash(pageIDs: [id])
        return records
    }

    /// Verschiebt eine Seite vor `targetID`; `nil` heißt ans Ende.
    public func move(pageID: UUID, before targetID: UUID?) throws {
        guard let from = document.pageOrder.firstIndex(of: pageID) else { throw SessionError.unknownPage(pageID) }
        if let targetID, targetID == pageID { return }
        document.pageOrder.remove(at: from)
        if let targetID, let to = document.pageOrder.firstIndex(of: targetID) {
            document.pageOrder.insert(pageID, at: to)
        } else {
            document.pageOrder.append(pageID)
        }
        try save()
    }

    public func setOrder(_ order: [UUID]) throws {
        let known = Set(document.pageOrder)
        var seen = Set<UUID>()
        var next: [UUID] = []
        for id in order where known.contains(id) && !seen.contains(id) {
            next.append(id)
            seen.insert(id)
        }
        for id in document.pageOrder where !seen.contains(id) {
            next.append(id)
        }
        document.pageOrder = next
        try save()
    }

    /// Verschiebt Bilddateien in den Papierkorb der Session; nichts wird gelöscht.
    public func trash(pageIDs: [UUID]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        for id in pageIDs {
            guard let index = document.pages.firstIndex(where: { $0.id == id }) else { continue }
            let page = document.pages[index]
            let source = fileURL(for: page)
            let target = trashDirectory.appending(path: page.fileName)
            if fm.fileExists(atPath: source.path) {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: source, to: target)
            }
            let textSource = textFileURL(for: page)
            if fm.fileExists(atPath: textSource.path) {
                let textTarget = trashDirectory.appending(path: textSource.lastPathComponent)
                if fm.fileExists(atPath: textTarget.path) { try fm.removeItem(at: textTarget) }
                try fm.moveItem(at: textSource, to: textTarget)
            }
            document.pages.remove(at: index)
            document.pageOrder.removeAll { $0 == id }
            document.trashed.append(page)
        }
        try save()
    }

    /// Holt die zuletzt gelöschte Seite zurück, vor `targetID` oder ans Ende.
    @discardableResult
    public func restoreLastTrashed(before targetID: UUID? = nil) throws -> PageRecord? {
        guard let page = document.trashed.popLast() else { return nil }
        let fm = FileManager.default
        let source = trashDirectory.appending(path: page.fileName)
        if fm.fileExists(atPath: source.path) {
            try fm.moveItem(at: source, to: fileURL(for: page))
        }
        let textSource = trashDirectory.appending(path: textFileURL(for: page).lastPathComponent)
        if fm.fileExists(atPath: textSource.path) {
            try fm.createDirectory(at: textDirectory, withIntermediateDirectories: true)
            try fm.moveItem(at: textSource, to: textFileURL(for: page))
        }
        document.pages.append(page)
        if let targetID, let index = document.pageOrder.firstIndex(of: targetID) {
            document.pageOrder.insert(page.id, at: index)
        } else {
            document.pageOrder.append(page.id)
        }
        try save()
        return page
    }

    public func updateOCRStatus(_ status: OCRStatus, for pageID: UUID) throws {
        guard let index = document.pages.firstIndex(where: { $0.id == pageID }) else { throw SessionError.unknownPage(pageID) }
        document.pages[index].ocrStatus = status
        try save()
    }

    public func setTitle(_ title: String?) throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        document.title = trimmed?.isEmpty == true ? nil : trimmed
        try save()
    }

    /// Setzt den Titel und benennt den Ordner nach ihm um, z. B.
    /// `2026-09-26 12-55-03` → `2026-09-26 12-55-03 Der Zauberberg`. Der Zeitstempel
    /// bleibt vorn, damit die Sortierung im Finder erhalten bleibt.
    public func setTitleAndRenameDirectory(_ title: String?) throws {
        try setTitle(title)
        let stamp = Self.directoryName(for: document.createdAt)
        var name = stamp
        if let title = document.title {
            name += " " + Self.fileSystemSafe(title)
        }
        guard name != directory.lastPathComponent else { return }
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        var target = parent.appending(path: name, directoryHint: .isDirectory)
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            target = parent.appending(path: "\(name) (\(suffix))", directoryHint: .isDirectory)
            suffix += 1
        }
        try fm.moveItem(at: directory, to: target)
        directory = target
    }

    /// Entfernt Zeichen, die in Dateinamen stören, und kürzt auf eine sinnvolle Länge.
    public static func fileSystemSafe(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?*|\"<>")
        let cleaned = title.unicodeScalars
            .map { forbidden.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    public func updateSettings(_ settings: SessionSettings) throws {
        document.settings = settings
        try save()
    }

    // MARK: Speichern

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.sessionTimestamp)
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = Date.fromSessionTimestamp(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Kein Datum: \(text)"))
        }
        return d
    }()

    func save() throws {
        try Self.write(document, to: directory)
    }

    private static func write(_ document: SessionDocument, to directory: URL) throws {
        let data = try encoder.encode(document)
        try data.write(to: directory.appending(path: documentFileName), options: .atomic)
    }
}
