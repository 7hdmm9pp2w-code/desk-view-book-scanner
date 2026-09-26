import Foundation

/// Kennzahlen einer Session für die Übersicht, ohne die Session zu öffnen.
public struct SessionSummary: Sendable, Identifiable, Equatable {
    public var id: URL { directory }
    public let directory: URL
    public let title: String?
    public let createdAt: Date
    public let pageCount: Int
    public let trashedCount: Int
    public let archived: Bool
    /// Bytes der Seitenbilder, des Papierkorbs, der Exporte und insgesamt.
    public let imagesBytes: Int64
    public let trashBytes: Int64
    public let exportsBytes: Int64
    public let totalBytes: Int64
    /// Erste Seite, für ein Vorschaubild; `nil` ohne Seiten oder archiviert.
    public let firstPageURL: URL?
    /// Vorhandene Exporte im Session-Ordner, nach Endung („pdf", „md", „docx", „epub").
    public let exportExtensions: [String]

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return directory.lastPathComponent
    }
}

extension SessionStore {
    public static let exportExtensions: Set<String> = ["pdf", "md", "docx", "epub"]

    /// Übersicht aller Sessions unter `root`, neueste zuerst. Liest nur `session.json`
    /// und Dateigrößen; die Bilder werden nicht geöffnet.
    public static func summaries(in root: URL) -> [SessionSummary] {
        sessionDirectories(in: root).compactMap { summary(of: $0) }
    }

    public static func summary(of directory: URL) -> SessionSummary? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: directory.appending(path: documentFileName)),
              let document = try? decoder.decode(SessionDocument.self, from: data) else { return nil }

        func size(of url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var images: Int64 = 0, trash: Int64 = 0, exports: Int64 = 0, total: Int64 = 0
        var exportKinds: Set<String> = []
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let bytes = size(of: url)
                total += bytes
                let parent = url.deletingLastPathComponent().lastPathComponent
                let ext = url.pathExtension.lowercased()
                if parent == trashDirectoryName {
                    trash += bytes
                } else if parent == directory.lastPathComponent, exportExtensions.contains(ext) {
                    exports += bytes
                    exportKinds.insert(ext)
                } else if ext == imageFileExtension {
                    images += bytes
                }
            }
        }
        let first = document.orderedPages.first.map { directory.appending(path: $0.fileName) }
        let firstExists = first.map { fm.fileExists(atPath: $0.path) } ?? false
        return SessionSummary(
            directory: directory, title: document.title, createdAt: document.createdAt,
            pageCount: document.pageOrder.count, trashedCount: document.trashed.count, archived: document.archived,
            imagesBytes: images, trashBytes: trash, exportsBytes: exports, totalBytes: total,
            firstPageURL: firstExists ? first : nil,
            exportExtensions: ["pdf", "md", "docx", "epub"].filter { exportKinds.contains($0) }
        )
    }

    /// Ganze Session in den macOS-Papierkorb.
    public static func moveToSystemTrash(_ directory: URL) throws {
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }

    // MARK: Aufräumen innerhalb einer Session

    /// Papierkorb der Session in den macOS-Papierkorb; die Einträge verschwinden aus `trashed`.
    public func emptyTrash() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: trashDirectory.path) {
            try fm.trashItem(at: trashDirectory, resultingItemURL: nil)
        }
        document.trashed = []
        try save()
    }

    /// Bilder in den macOS-Papierkorb, OCR-Text und Exporte bleiben. Markdown, Word und
    /// EPUB gehen danach noch, PDF und Bildbefehle nicht mehr.
    public func archive() throws {
        let fm = FileManager.default
        for page in document.pages {
            let url = fileURL(for: page)
            if fm.fileExists(atPath: url.path) {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
        }
        if fm.fileExists(atPath: trashDirectory.path) {
            try fm.trashItem(at: trashDirectory, resultingItemURL: nil)
        }
        document.trashed = []
        document.archived = true
        try save()
    }

    public var isArchived: Bool { document.archived }
}
