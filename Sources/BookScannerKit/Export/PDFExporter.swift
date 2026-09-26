import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error, LocalizedError {
    case cannotCreatePDF(URL)
    case pandocMissing
    case pandocFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreatePDF(let url): return "Kann \(url.lastPathComponent) nicht anlegen."
        case .pandocMissing: return "Pandoc wurde nicht gefunden."
        case .pandocFailed(let message): return "Pandoc meldet: \(message)"
        }
    }
}

/// PDF direkt über CoreGraphics: pro Seite eine PDF-Seite in Bildgröße, das Bild
/// als JPEG eingebettet, darüber jede OCR-Zeile unsichtbar in ihre Bounding Box.
public struct PDFExporter: Sendable {
    /// Nominale Auflösung, aus der die Seitengröße in Punkten folgt.
    public var dotsPerInch: Double = 150
    public var jpegQuality: Double = 0.85
    public var fontName = "Helvetica"

    public init() {}

    public typealias PageLoader = @Sendable (Int) throws -> (image: CGImage, text: PageText?)

    /// `load` wird pro Seite aufgerufen, damit nie mehr als ein Bild im Speicher ist.
    public func export(to url: URL, title: String?, pageCount: Int, load: PageLoader, progress: @Sendable (Int) -> Void = { _ in }) throws {
        var metadata: [CFString: Any] = [kCGPDFContextCreator: "Desk View Book Scanner"]
        if let title, !title.isEmpty { metadata[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: nil, metadata as CFDictionary) else {
            throw ExportError.cannotCreatePDF(url)
        }
        let scale = 72.0 / dotsPerInch
        for index in 0..<pageCount {
            let (image, text) = try load(index)
            var mediaBox = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
            ]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.interpolationQuality = .high
            context.draw(Self.jpegBacked(image, quality: jpegQuality) ?? image, in: mediaBox)
            if let text {
                drawTextLayer(text, in: mediaBox, context: context)
            }
            context.endPDFPage()
            progress(index + 1)
        }
        context.closePDF()
    }

    /// Unsichtbarer Text (Textmodus 3), Schriftgröße so, dass die Zeile die Boxbreite füllt.
    func drawTextLayer(_ text: PageText, in mediaBox: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        let unitFont = CTFontCreateWithName(fontName as CFString, 1, nil)

        for line in text.lines where !line.text.isEmpty {
            let box = CGRect(
                x: line.box.minX * mediaBox.width, y: line.box.minY * mediaBox.height,
                width: line.box.width * mediaBox.width, height: line.box.height * mediaBox.height
            )
            guard box.width > 0, box.height > 0 else { continue }
            let unitWidth = Self.width(of: line.text, font: unitFont)
            guard unitWidth > 0 else { continue }
            let fontSize = box.width / unitWidth
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: box.minX, y: box.minY + CTFontGetDescent(font))
            CTLineDraw(ctLine, context)
        }
    }

    static func width(of text: String, font: CTFont) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// Ein CGImage, das aus JPEG-Daten stammt, bettet CoreGraphics als JPEG ins PDF
    /// ein (DCTDecode) statt es verlustfrei und riesig neu zu kodieren.
    static func jpegBacked(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return jpeg
    }
}

/// Dateinamen für Exporte: `Buchscan 2026-09-26 14-03 Titel.pdf`.
public enum ExportNaming {
    public static func fileName(createdAt: Date, title: String?, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        var name = "Buchscan " + formatter.string(from: createdAt)
        if let title, !title.isEmpty {
            name += " " + SessionStore.fileSystemSafe(title)
        }
        return name + "." + fileExtension
    }
}
