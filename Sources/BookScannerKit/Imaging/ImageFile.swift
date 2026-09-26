import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageFileError: Error, LocalizedError {
    case cannotCreateDestination(URL)
    case cannotFinalize(URL)
    case cannotRead(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDestination(let url): return "Kann \(url.lastPathComponent) nicht anlegen"
        case .cannotFinalize(let url): return "Kann \(url.lastPathComponent) nicht schreiben"
        case .cannotRead(let url): return "Kann \(url.lastPathComponent) nicht lesen"
        }
    }
}

/// Lesen und Schreiben von Bilddateien über ImageIO. Ohne AppKit, damit der Kit
/// in Tests und Werkzeugen ohne UI läuft.
public enum ImageFile {
    public static let heicQuality: Double = 0.9

    public static func writeHEIC(_ image: CGImage, to url: URL, quality: Double = heicQuality) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw ImageFileError.cannotCreateDestination(url)
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageFileError.cannotFinalize(url)
        }
    }

    public static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageFileError.cannotRead(url)
        }
        return image
    }

    /// Verkleinerte Fassung, längste Kante höchstens `maxPixelSize`. ImageIO dekodiert
    /// dafür nicht das ganze Bild.
    public static func thumbnail(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageFileError.cannotRead(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageFileError.cannotRead(url)
        }
        return image
    }

    /// Pixelmaße ohne Dekodieren.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }
}
