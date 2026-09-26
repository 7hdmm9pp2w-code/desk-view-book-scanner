import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum ImportError: Error, LocalizedError {
    case unsupportedFile(URL)
    case cannotOpenPDF(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): return "\(url.lastPathComponent) ist weder Bild noch PDF."
        case .cannotOpenPDF(let url): return "\(url.lastPathComponent) lässt sich nicht als PDF öffnen."
        }
    }
}

/// Bilder und PDFs als Seiten. Für Scans aus Notizen, vFlat oder der Fotos-App.
public enum PageImporter {
    public static let supportedTypes: [UTType] = [.pdf, .image]
    /// Wenn ein PDF keine eingebetteten Bilder verrät, wird mit dieser Auflösung gerendert.
    public static let fallbackDotsPerInch: CGFloat = 300
    public static let maximumDotsPerInch: CGFloat = 600

    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    /// Anzahl Seiten, die `url` liefern wird (Bild: 1, PDF: Seitenzahl).
    public static func pageCount(of url: URL) throws -> Int {
        guard let type = UTType(filenameExtension: url.pathExtension) else { throw ImportError.unsupportedFile(url) }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw ImportError.cannotOpenPDF(url) }
            return document.pageCount
        }
        if type.conforms(to: .image) { return 1 }
        throw ImportError.unsupportedFile(url)
    }

    /// Ruft `handler` pro Seite auf, damit nie mehr als ein Bild im Speicher liegt.
    public static func importPages(from url: URL, handler: (CGImage) throws -> Void) throws {
        guard let type = UTType(filenameExtension: url.pathExtension) else { throw ImportError.unsupportedFile(url) }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw ImportError.cannotOpenPDF(url) }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                try handler(render(page))
            }
        } else if type.conforms(to: .image) {
            try handler(try ImageFile.readOriented(url))
        } else {
            throw ImportError.unsupportedFile(url)
        }
    }

    /// Eine einzelne Seite, für Importe, die zwischen den Seiten speichern wollen.
    public static func image(at index: Int, from url: URL) throws -> CGImage {
        guard let type = UTType(filenameExtension: url.pathExtension) else { throw ImportError.unsupportedFile(url) }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw ImportError.cannotOpenPDF(url) }
            guard let page = document.page(at: index) else { throw ImportError.cannotOpenPDF(url) }
            return render(page)
        }
        if type.conforms(to: .image), index == 0 {
            return try ImageFile.readOriented(url)
        }
        throw ImportError.unsupportedFile(url)
    }

    /// Rendert die Seite in der Auflösung ihres größten eingebetteten Bildes, damit ein
    /// Scan-PDF weder hoch- noch heruntergerechnet wird.
    public static func render(_ page: PDFPage) -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        var dpi = fallbackDotsPerInch
        if let image = largestEmbeddedImageSize(in: page), bounds.width > 0 {
            let rotated = page.rotation % 180 != 0
            let widthPoints = rotated ? bounds.height : bounds.width
            dpi = min(maximumDotsPerInch, max(72, CGFloat(image.width) / widthPoints * 72))
        }
        let rotated = page.rotation % 180 != 0
        let width = Int(((rotated ? bounds.height : bounds.width) * dpi / 72).rounded())
        let height = Int(((rotated ? bounds.width : bounds.height) * dpi / 72).rounded())
        let context = CGContext(
            data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: dpi / 72, y: dpi / 72)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()!
    }

    /// Größtes Bild-XObject der Seite in Pixeln, über CGPDF.
    public static func largestEmbeddedImageSize(in page: PDFPage) -> (width: Int, height: Int)? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return nil }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }

        final class Best { var size: (Int, Int)? }
        let best = Best()
        CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
            let best = Unmanaged<Best>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image" else { return true }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(streamDictionary, "Width", &width),
                  CGPDFDictionaryGetInteger(streamDictionary, "Height", &height) else { return true }
            if let current = best.size, current.0 * current.1 >= Int(width) * Int(height) { return true }
            best.size = (Int(width), Int(height))
            return true
        }, Unmanaged.passUnretained(best).toOpaque())
        return best.size.map { (width: $0.0, height: $0.1) }
    }
}
