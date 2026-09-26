import AppKit
import Observation
import UniformTypeIdentifiers
import BookScannerKit

// MARK: - Seitenleiste und Aufräumen

extension AppModel {
    var totalBytes: Int64 { summaries.reduce(0) { $0 + $1.totalBytes } }

    /// Übersicht neu einlesen; läuft abseits des Main-Threads, weil sie Dateigrößen summiert.
    func refreshSummaries() {
        let root = sessionRoot
        Task {
            let result = await Task.detached(priority: .utility) { SessionStore.summaries(in: root) }.value
            summaries = result
            let valid = Set(result.compactMap(\.firstPageURL))
            sidebarThumbnails = sidebarThumbnails.filter { valid.contains($0.key) }
        }
    }

    func sidebarThumbnail(for summary: SessionSummary) async -> CGImage? {
        guard let url = summary.firstPageURL else { return nil }
        if let cached = sidebarThumbnails[url] { return cached }
        let image = await Task.detached(priority: .utility) { try? ImageFile.thumbnail(url, maxPixelSize: 96) }.value
        if let image { sidebarThumbnails[url] = image }
        return image
    }

    func revealSession(_ summary: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([summary.directory])
    }

    func deleteSessions(_ summaries: [SessionSummary]) {
        for summary in summaries {
            do {
                try SessionStore.moveToSystemTrash(summary.directory)
                if summary.directory == sessionDirectory { closeSession() }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        refreshSummaries()
    }

    func deleteSession(_ summary: SessionSummary) { deleteSessions([summary]) }

    func closeSession() {
        session = nil
        sessionDirectory = nil
        sessionTitle = ""
        pages = []
        texts = [:]
        imageCache.removeAll()
        selectedPageID = nil
        suggestedTitle = nil
        sessionArchived = false
        trashedCount = 0
    }

    func store(for summary: SessionSummary) throws -> SessionStore {
        if let session, summary.directory == sessionDirectory { return session }
        return try SessionStore.open(directory: summary.directory)
    }

    func emptyTrash(of summaries: [SessionSummary]) {
        Task {
            for summary in summaries {
                do {
                    let store = try store(for: summary)
                    try await store.emptyTrash()
                    if summary.directory == sessionDirectory { trashedCount = 0 }
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                }
            }
            refreshSummaries()
        }
    }

    func emptyTrash(of summary: SessionSummary) { emptyTrash(of: [summary]) }

    func archiveSessions(_ summaries: [SessionSummary]) {
        Task {
            for summary in summaries where !summary.archived {
                do {
                    let store = try store(for: summary)
                    try await store.archive()
                    if summary.directory == sessionDirectory {
                        sessionArchived = true
                        trashedCount = 0
                        imageCache.removeAll()
                        pages = await store.orderedPages
                    }
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                }
            }
            refreshSummaries()
        }
    }

    func archiveSession(_ summary: SessionSummary) { archiveSessions([summary]) }
}
