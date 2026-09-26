import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
@testable import BookScannerKit

@Suite struct ImportTests {
    @Test func pdfPagesRenderAtEmbeddedResolution() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appending(path: "scan.pdf")
        let a = makeTestImage(width: 1713, height: 2710)
        let b = makeTestImage(width: 800, height: 600)
        try PDFExporter().export(to: pdf, title: nil, pageCount: 2, load: { $0 == 0 ? (a, nil) : (b, nil) })

        #expect(PageImporter.isSupported(pdf))
        #expect(try PageImporter.pageCount(of: pdf) == 2)
        let document = try #require(PDFDocument(url: pdf))
        let size = PageImporter.largestEmbeddedImageSize(in: document.page(at: 0)!)
        #expect(size?.width == 1713 && size?.height == 2710)

        var sizes: [(Int, Int)] = []
        try PageImporter.importPages(from: pdf) { sizes.append(($0.width, $0.height)) }
        #expect(sizes.count == 2)
        #expect(abs(sizes[0].0 - 1713) <= 2 && abs(sizes[0].1 - 2710) <= 2)
        #expect(abs(sizes[1].0 - 800) <= 2 && abs(sizes[1].1 - 600) <= 2)
    }

    @Test func imagesFollowEXIFOrientation() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "foto.jpg")
        let image = makeTestImage(width: 400, height: 200)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        // Orientation 6: um 90° gedreht gespeichert, also hochkant gemeint.
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        var sizes: [(Int, Int)] = []
        try PageImporter.importPages(from: url) { sizes.append(($0.width, $0.height)) }
        #expect(sizes.count == 1 && sizes[0].0 == 200 && sizes[0].1 == 400)
        #expect(try PageImporter.pageCount(of: url) == 1)
    }

    @Test func unsupportedFilesAreRejected() throws {
        let url = URL(filePath: "/tmp/x.docx")
        #expect(!PageImporter.isSupported(url))
        #expect(throws: ImportError.self) { try PageImporter.importPages(from: url) { _ in } }
    }

    /// Handprobe am echten Notizen-Scan, wenn er lokal liegt; sonst übersprungen.
    @Test func notesScanIfPresent() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/scans/kapitel1.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var sizes: [(Int, Int)] = []
        try PageImporter.importPages(from: url) { sizes.append(($0.width, $0.height)) }
        #expect(sizes.count == 2)
        #expect(sizes[0].0 >= 1700 && sizes[0].0 <= 1800)
    }
}
