import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

public enum VideoImportError: Error, LocalizedError {
    case noVideoTrack(URL)
    case cannotRead(URL, String?)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack(let url): return "\(url.lastPathComponent) enthält keine Videospur."
        case .cannotRead(let url, let reason):
            return "\(url.lastPathComponent) lässt sich nicht lesen" + (reason.map { ": \($0)" } ?? ".")
        }
    }
}

/// Was beim Lesen eines Videos herauskam, für die Rückmeldung nach dem Import.
public struct VideoImportReport: Sendable, Equatable {
    public var fileName: String
    /// Größe der Seitenbilder, aufrecht wie im Video gemeint.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: TimeInterval
    public var pages: Int
    /// So oft lag nach einer Bewegung eine Seite still, die schon erfasst war.
    public var skippedKnownPages: Int

    public init(fileName: String, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval, pages: Int, skippedKnownPages: Int) {
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.pages = pages
        self.skippedKnownPages = skippedKnownPages
    }

    /// Unter 4K: Für Fließtext zu grob, wie Continuity Camera und Desk View.
    public var isBelow4K: Bool { max(pixelWidth, pixelHeight) < 3000 }
}

/// Seiten aus einem Video, in dem umgeblättert wird, etwa mit dem iPhone in 4K von oben
/// gefilmt. Das iPhone liefert über Continuity Camera höchstens 1920 × 1440; in der
/// eigenen Kamera-App filmt es 3840 × 2160.
///
/// Dieselbe Logik wie der Auto-Auslöser der Live-Kamera: `MotionTrigger` findet die Ruhe
/// nach dem Umblättern, `PageTurnJudge` verwirft Seiten, die schon erfasst sind. Das Video
/// wird Bild für Bild dekodiert, geprüft werden rund vier Bilder pro Sekunde. Anders als
/// live gilt der Anfang des Videos als Ende einer Bewegung, damit die erste Seite nicht
/// verloren geht; am Ende zählt auch eine Ruhe, die noch nicht ganz abgelaufen ist.
public struct VideoPageExtractor: Sendable {
    public static let supportedTypes: [UTType] = [.movie]

    /// Abstand der geprüften Bilder in Sekunden Videozeit.
    public var sampleInterval: TimeInterval = 0.25
    /// Am Ende des Videos reicht so viel Ruhe für die letzte Seite.
    public var finalSettleSeconds: TimeInterval = 0.5
    public var trigger = MotionTrigger()
    public var judge = PageTurnJudge()
    /// Wie beim Auto-Auslöser: genau, ohne Sprachkorrektur.
    public var recognizer: TextRecognizer = {
        var recognizer = TextRecognizer()
        recognizer.usesLanguageCorrection = false
        return recognizer
    }()

    public init() {}

    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    /// Ruft `handler` für jede neue Seite auf, aufrecht wie im Video gemeint und in voller
    /// Auflösung. `progress` bekommt den Anteil der gelesenen Videozeit (0…1).
    @discardableResult
    public func extractPages(
        from url: URL,
        progress: @Sendable (Double) async -> Void = { _ in },
        handler: @Sendable (CGImage) async throws -> Void
    ) async throws -> VideoImportReport {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoImportError.noVideoTrack(url)
        }
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        let orientation = Self.orientation(of: try await track.load(.preferredTransform))
        let natural = try await track.load(.naturalSize)
        let sideways = [.left, .right].contains(orientation)
        var report = VideoImportReport(
            fileName: url.lastPathComponent,
            pixelWidth: Int(sideways ? natural.height : natural.width),
            pixelHeight: Int(sideways ? natural.width : natural.height),
            duration: duration, pages: 0, skippedKnownPages: 0)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            // Nativ aus dem Decoder: Die Helligkeitsebene reicht dem Auslöser, in Farbe
            // umgerechnet werden nur die Seiten. BGRA für jedes Bild kostete mehr als das Dekodieren.
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoImportError.cannotRead(url, nil) }
        reader.add(output)
        guard reader.startReading() else { throw VideoImportError.cannotRead(url, reader.error?.localizedDescription) }
        defer { reader.cancelReading() }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var trigger = self.trigger
        var judge = self.judge
        trigger.reset()
        trigger.assumeMotion()
        judge.reset()
        var nextSample = -Double.infinity
        var lastProgress = -1.0
        var stillSince: TimeInterval?
        var last: (buffer: CVPixelBuffer, time: TimeInterval)?

        /// Ein ruhiges Bild: neu gegen die zuletzt erfassten, dann übergeben.
        func take(_ buffer: CVPixelBuffer) async throws {
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            guard let page = context.createCGImage(image, from: image.extent) else { return }
            let lines = (try? await recognizer.recognize(page)) ?? []
            let snapshot = PageSnapshot(frame: Self.lumaFrame(buffer, targetWidth: 320), lines: lines.map(\.text))
            guard judge.isNewPage(snapshot) else { report.skippedKnownPages += 1; return }
            judge.remember(snapshot)
            try await handler(page)
            report.pages += 1
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard time >= nextSample else { continue }
            nextSample = time + sampleInterval
            last = (buffer, time)

            let gray = Self.lumaFrame(buffer, targetWidth: 160)
            let settled = trigger.feed(gray.pixels, width: gray.width, at: time)
            if trigger.state == .settling {
                if stillSince == nil { stillSince = time }
            } else {
                stillSince = nil
            }
            if settled {
                try await take(buffer)
                trigger.didCapture()
            }

            if duration > 0, time / duration - lastProgress >= 0.01 {
                lastProgress = time / duration
                await progress(min(1, lastProgress))
            }
        }
        if reader.status == .failed {
            throw VideoImportError.cannotRead(url, reader.error?.localizedDescription)
        }
        // Die letzte Seite, wenn die Aufnahme kurz nach dem Umblättern endet.
        if trigger.state == .settling, let since = stillSince, let last, last.time - since >= finalSettleSeconds {
            try await take(last.buffer)
        }
        await progress(1)
        return report
    }

    /// Verkleinertes Graubild aus der Helligkeitsebene, jeder Bildpunkt der Mittelwert
    /// seines Blocks wie bei `CameraSource.grayThumbnail`.
    static func lumaFrame(_ buffer: CVPixelBuffer, targetWidth: Int) -> GrayFrame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return GrayFrame(pixels: [], width: 0) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let step = max(1, width / targetWidth)
        let outW = width / step, outH = height / step
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: outW * outH)
        var sums = [Int](repeating: 0, count: outW)
        let area = step * step
        for y in 0..<outH {
            for i in 0..<outW { sums[i] = 0 }
            for dy in 0..<step {
                let row = luma + (y * step + dy) * stride
                for x in 0..<outW {
                    var sum = 0
                    let start = row + x * step
                    for i in 0..<step { sum += Int(start[i]) }
                    sums[x] += sum
                }
            }
            for x in 0..<outW { result[y * outW + x] = UInt8(sums[x] / area) }
        }
        return GrayFrame(pixels: result, width: outW)
    }

    /// Wie das Video gemeint ist: Das iPhone speichert hochkant gefilmte Bilder quer und
    /// vermerkt die Drehung in der Spur.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let degrees = (atan2(transform.b, transform.a) * 180 / .pi).rounded()
        switch degrees {
        case 90: return .right
        case -90: return .left
        case 180, -180: return .down
        default: return .up
        }
    }
}
