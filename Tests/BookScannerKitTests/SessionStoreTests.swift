import Testing
import Foundation
import CoreGraphics
@testable import BookScannerKit

/// Synthetisches Bild mit Farbverlauf, damit HEIC etwas zu kodieren hat.
func makeTestImage(width: Int = 640, height: Int = 480) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: width / 2 - 4, y: 0, width: 8, height: height))
    return context.makeImage()!
}

func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "BookScannerKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SessionStoreTests {
    @Test func createWritesDocumentToDisk() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let store = try SessionStore.create(in: root, title: "Testbuch", now: now)

        #expect(await store.directory.lastPathComponent == SessionStore.directoryName(for: now))
        #expect(FileManager.default.fileExists(atPath: await store.directory.appending(path: "session.json").path))
        #expect(SessionStore.sessionDirectories(in: root) == [await store.directory])
    }

    @Test func createAvoidsCollidingDirectories() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let first = try SessionStore.create(in: root, now: now)
        let second = try SessionStore.create(in: root, now: now)

        #expect(await first.directory != second.directory)
        #expect(await second.directory.lastPathComponent.hasSuffix("(2)"))
    }

    @Test func addPageWritesHEICAndSurvivesReopen() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)

        let page = try await store.addPage(makeTestImage(), capturedAt: .now)

        #expect(page.fileName == "Aufnahme-0001.heic")
        #expect(page.pixelWidth == 640 && page.pixelHeight == 480)
        let url = await store.fileURL(for: page)
        #expect(ImageFile.pixelSize(of: url)?.width == 640)
        let reread = try ImageFile.read(url)
        #expect(reread.width == 640 && reread.height == 480)
        let thumb = try ImageFile.thumbnail(url, maxPixelSize: 100)
        #expect(max(thumb.width, thumb.height) <= 100)

        let reopened = try SessionStore.open(directory: await store.directory)
        #expect(await reopened.orderedPages == [page])
    }

    @Test func moveReordersPages() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let a = try await store.addPage(makeTestImage(width: 10, height: 10))
        let b = try await store.addPage(makeTestImage(width: 10, height: 10))
        let c = try await store.addPage(makeTestImage(width: 10, height: 10))

        try await store.move(pageID: c.id, before: a.id)
        #expect(await store.orderedPages.map(\.id) == [c.id, a.id, b.id])

        try await store.move(pageID: c.id, before: nil)
        #expect(await store.orderedPages.map(\.id) == [a.id, b.id, c.id])

        try await store.setOrder([b.id, UUID(), a.id])
        #expect(await store.orderedPages.map(\.id) == [b.id, a.id, c.id])

        let reopened = try SessionStore.open(directory: await store.directory)
        #expect(await reopened.orderedPages.map(\.id) == [b.id, a.id, c.id])
    }

    @Test func trashMovesFileIntoPapierkorb() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root)
        let a = try await store.addPage(makeTestImage(width: 10, height: 10))
        let b = try await store.addPage(makeTestImage(width: 10, height: 10))

        try await store.trash(pageIDs: [a.id])

        #expect(await store.orderedPages == [b])
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: a).path))
        #expect(FileManager.default.fileExists(atPath: await store.trashDirectory.appending(path: a.fileName).path))
        #expect(await store.document.trashed.map(\.id) == [a.id])

        // Der Zähler läuft weiter, Dateinamen werden nie wiederverwendet.
        let c = try await store.addPage(makeTestImage(width: 10, height: 10))
        #expect(c.fileName == "Aufnahme-0003.heic")
    }

    @Test func openWithoutDocumentFails() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: SessionError.documentMissing(root)) {
            _ = try SessionStore.open(directory: root)
        }
    }
}

@Suite struct SessionTitleTests {
    @Test func renameAppendsTitleToDirectory() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = try SessionStore.create(in: root, now: now)
        let page = try await store.addPage(makeTestImage(width: 10, height: 10))

        try await store.setTitleAndRenameDirectory("Der Zauberberg: Roman / Band 1")

        let dir = await store.directory
        #expect(dir.lastPathComponent == SessionStore.directoryName(for: now) + " Der Zauberberg Roman Band 1")
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(for: page).path))
        let reopened = try SessionStore.open(directory: dir)
        #expect(await reopened.document.title == "Der Zauberberg: Roman / Band 1")

        // Titel leeren stellt den reinen Zeitstempel wieder her.
        try await store.setTitleAndRenameDirectory("")
        #expect(await store.directory.lastPathComponent == SessionStore.directoryName(for: now))
    }

    @Test func fileSystemSafeStripsAndTrims() {
        #expect(SessionStore.fileSystemSafe("  c't 12/2026 ") == "c't 12 2026")
        #expect(SessionStore.fileSystemSafe(String(repeating: "a", count: 100)).count == 80)
        #expect(SessionStore.fileSystemSafe("Ende.") == "Ende")
    }
}

@Suite struct SessionTimestampTests {
    @Test func timestampRoundTripIsExactForManyValues() {
        // Werte rund um die Millisekundengrenzen, wo der Systemformatter abschneidet.
        for i in 0..<2000 {
            let raw = Date(timeIntervalSince1970: 1_790_420_502 + Double(i) * 0.000_4997)
            let stored = raw.roundedToMilliseconds
            let text = stored.sessionTimestamp
            #expect(Date.fromSessionTimestamp(text) == stored, "\(text)")
            #expect(stored.roundedToMilliseconds == stored)
        }
    }

    @Test func timestampFormat() {
        let date = Date(timeIntervalSince1970: 1_790_420_502.883)
        #expect(date.sessionTimestamp == "2026-09-26T11:01:42.883Z")
        #expect(Date.fromSessionTimestamp("2026-09-26T11:01:42Z") == Date(timeIntervalSince1970: 1_790_420_502))
    }
}
