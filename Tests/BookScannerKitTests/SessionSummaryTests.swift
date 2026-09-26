import Testing
import Foundation
@testable import BookScannerKit

@Suite struct SessionSummaryTests {
    @Test func summaryCountsPagesTrashAndExports() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root, title: "Testbuch")
        let a = try await store.addPage(makeTestImage(width: 400, height: 600))
        _ = try await store.addPage(makeTestImage(width: 400, height: 600))
        try await store.trash(pageIDs: [a.id])
        let dir = await store.directory
        try Data(repeating: 1, count: 5000).write(to: dir.appending(path: "Testbuch.pdf"))
        try "# x".write(to: dir.appending(path: "Testbuch.md"), atomically: true, encoding: .utf8)

        let summaries = SessionStore.summaries(in: root)
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.displayName == "Testbuch")
        #expect(summary.pageCount == 1 && summary.trashedCount == 1)
        #expect(summary.imagesBytes > 0 && summary.trashBytes > 0)
        #expect(summary.exportsBytes >= 5000)
        #expect(summary.totalBytes >= summary.imagesBytes + summary.trashBytes + summary.exportsBytes)
        #expect(summary.exportExtensions == ["pdf", "md"])
        #expect(summary.firstPageURL != nil && !summary.archived)
    }

    @Test func emptyTrashAndArchive() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let a = try await store.addPage(makeTestImage(width: 400, height: 600))
        let b = try await store.addPage(makeTestImage(width: 400, height: 600))
        try await store.saveText(pageText([line("Hallo", top: 0.9)]), for: b)
        try await store.trash(pageIDs: [a.id])

        try await store.emptyTrash()
        #expect(await store.document.trashed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: await store.trashDirectory.path))

        try await store.archive()
        #expect(await store.isArchived)
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: b).path))
        #expect(try await store.loadText(for: b)?.lines.first?.text == "Hallo")
        let reopened = try SessionStore.open(directory: await store.directory)
        #expect(await reopened.isArchived)
        #expect(await reopened.orderedPages.count == 1)
        #expect(SessionStore.summary(of: await store.directory)?.archived == true)
    }

    @Test func storedImagesAreCapped() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let page = try await store.addPage(makeTestImage(width: 4000, height: 6000))
        #expect(page.pixelHeight == 3000 && page.pixelWidth == 2000)
        #expect(ImageFile.pixelSize(of: await store.fileURL(for: page))?.height == 3000)
        let small = try await store.addPage(makeTestImage(width: 1713, height: 2710))
        #expect(small.pixelWidth == 1713 && small.pixelHeight == 2710)
    }

    @Test func oldDocumentsWithoutArchivedFieldDecode() throws {
        let json = #"{"version":1,"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","createdAt":"2026-09-26T11:01:42.883Z","captureCounter":0,"pageOrder":[],"pages":[],"trashed":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in Date.fromSessionTimestamp(try d.singleValueContainer().decode(String.self)) ?? .now }
        let doc = try decoder.decode(SessionDocument.self, from: json.data(using: .utf8)!)
        #expect(doc.archived == false && doc.settings.splitMode == .automatic)
    }
}
