import Foundation
import CoreGraphics
import CoreImage
import OSLog
@preconcurrency import AVFoundation

private let triggerLog = Logger(subsystem: "org.crushkilldestroy.DeskViewBookScanner", category: "Auslöser")

/// Eine Kamera, wie sie AVFoundation sieht: Desk View (Mac oder iPhone), das iPhone
/// als Continuity-Kamera, externe Kameras wie eine 4K-Webcam, die eingebaute Kamera.
public struct CameraDeviceInfo: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable { case deskView, continuity, external, builtIn }

    public let id: String
    public let name: String
    public let kind: Kind
    /// Größtes Videoformat in Pixeln.
    public let maxWidth: Int
    public let maxHeight: Int

    public var megapixels: Double { Double(maxWidth * maxHeight) / 1_000_000 }
}

public enum CameraError: Error, LocalizedError {
    case permissionDenied
    case deviceNotFound
    case noFrame
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Kamerazugriff ist für diese App nicht freigegeben."
        case .deviceNotFound: return "Die gewählte Kamera ist nicht mehr da."
        case .noFrame: return "Die Kamera liefert kein Bild."
        case .notRunning: return "Die Kamera läuft nicht."
        }
    }
}

/// Live-Feed einer Kamera im größten Format, Einzelbilder daraus, optional der
/// Auto-Auslöser. AVFoundation-Objekte sind nicht Sendable; alles läuft auf einer
/// eigenen seriellen Queue, nach außen gibt es nur Sendable-Werte.
public final class CameraSource: NSObject, @unchecked Sendable {
    public static let deviceTypes: [AVCaptureDevice.DeviceType] = [.deskViewCamera, .continuityCamera, .external, .builtInWideAngleCamera]

    private let queue = DispatchQueue(label: "org.crushkilldestroy.camera")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var latestBuffer: CVPixelBuffer?
    private var pendingCaptures: [CheckedContinuation<CGImage, Error>] = []
    private var frameCounter = 0
    private var trigger = MotionTrigger()
    private var judge = PageTurnJudge()
    private var autoTriggerEnabled = false
    /// Läuft gerade die Prüfung einer ruhig liegenden Seite?
    private var judging = false
    /// Zählt Bewegungen; eine Prüfung, während der sich wieder etwas bewegt hat, verfällt.
    private var motionEpisode = 0
    /// Genaue Erkennung, aber ohne Sprachkorrektur: Die schnelle liest die kleine Schrift
    /// eines ganzen Kamerabilds nicht (0 Wörter auf voll bedruckten Seiten), die genaue
    /// braucht dafür rund 100 ms.
    private let quickRecognizer: TextRecognizer = {
        var recognizer = TextRecognizer()
        recognizer.usesLanguageCorrection = false
        return recognizer
    }()
    /// Wird auf der Kamera-Queue gerufen, wenn der Auto-Auslöser feuert.
    public var onAutoTrigger: (@Sendable () -> Void)?
    /// Bewegung im Bild, für den Hinweis in der Quellenleiste.
    public var onMotionState: (@Sendable (MotionTrigger.State) -> Void)?

    public private(set) var activeDevice: CameraDeviceInfo?

    public override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    // MARK: Geräte und Rechte

    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Noch nie gefragt: dann zeigt macOS den Dialog und führt die App erst danach in
    /// den Einstellungen unter „Kamera".
    public static var isUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public static func availableDevices() -> [CameraDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        return discovery.devices.map { device in
            let best = bestFormat(of: device)
            let dims = best.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
            let kind: CameraDeviceInfo.Kind
            switch device.deviceType {
            case .deskViewCamera: kind = .deskView
            case .continuityCamera: kind = .continuity
            case .external: kind = device.isContinuityCamera ? .continuity : .external
            default: kind = .builtIn
            }
            return CameraDeviceInfo(id: device.uniqueID, name: device.localizedName, kind: kind,
                                    maxWidth: Int(dims?.width ?? 0), maxHeight: Int(dims?.height ?? 0))
        }
        .sorted { $0.megapixels > $1.megapixels }
    }

    /// Größte Fläche bei mindestens 10 Bildern pro Sekunde.
    static func bestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 10 } }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
    }

    /// Zum Anzeigen in der Oberfläche; `AVCaptureVideoPreviewLayer(session:)` damit bauen.
    public var captureSession: AVCaptureSession { session }

    // MARK: Start und Stopp

    public func start(deviceID: String) async throws {
        guard Self.isAuthorized else { throw CameraError.permissionDenied }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: Self.deviceTypes, mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) else { throw CameraError.deviceNotFound }
        let info = Self.availableDevices().first { $0.id == deviceID }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    session.beginConfiguration()
                    for input in session.inputs { session.removeInput(input) }
                    if session.outputs.isEmpty { session.addOutput(output) }
                    // Auf macOS gilt das activeFormat des Geräts; ein Preset gibt es hier nicht.
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw CameraError.deviceNotFound }
                    session.addInput(input)
                    if let format = Self.bestFormat(of: device) {
                        try device.lockForConfiguration()
                        device.activeFormat = format
                        device.unlockForConfiguration()
                    }
                    session.commitConfiguration()
                    latestBuffer = nil
                    trigger.reset()
                    judge.reset()
                    session.startRunning()
                    activeDevice = info
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            latestBuffer = nil
            activeDevice = nil
            for pending in pendingCaptures { pending.resume(throwing: CameraError.notRunning) }
            pendingCaptures = []
        }
    }

    public var isRunning: Bool { session.isRunning }

    // MARK: Einzelbild

    /// Das nächste frische Bild aus dem Feed, in voller Formatgröße.
    public func captureImage() async throws -> CGImage {
        guard session.isRunning else { throw CameraError.notRunning }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in pendingCaptures.append(continuation) }
        }
    }

    // MARK: Auto-Auslöser

    public func setAutoTrigger(_ enabled: Bool) {
        queue.async { [self] in
            autoTriggerEnabled = enabled
            trigger.reset()
        }
        if enabled { warmUpRecognizer() }
    }

    /// Die genaue Erkennung lädt beim ersten Mal ihr Modell, das dauert bis zu einer halben
    /// Minute. Vorab an einem leeren Bild, damit die erste umgeblätterte Seite nicht wartet.
    private func warmUpRecognizer() {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let blank = context.makeImage() else { return }
        let recognizer = quickRecognizer
        Task.detached(priority: .utility) { _ = try? await recognizer.recognize(blank) }
    }

    /// Vergisst die erfassten Seiten, etwa bei einer neuen Session.
    public func forgetCapturedPages() {
        queue.async { [self] in judge.reset() }
    }

    /// Graubild und schnelle Texterkennung einer Aufnahme, zum Vergleich mit der nächsten.
    private func snapshot(of image: CGImage, frame: GrayFrame) async -> PageSnapshot {
        let lines = (try? await quickRecognizer.recognize(image)) ?? []
        return PageSnapshot(frame: frame, lines: lines.map(\.text))
    }

    /// Nach einer Aufnahme: Die Seite merken, damit der Auslöser sie nicht noch einmal nimmt.
    private func rememberCapture(_ image: CGImage, frame: GrayFrame) {
        Task.detached(priority: .utility) { [self] in
            let snapshot = await snapshot(of: image, frame: frame)
            queue.async { [self] in judge.remember(snapshot) }
        }
    }

    /// Das Bild steht nach einer Bewegung still: Liegt eine neue Seite da?
    private func judgeSettledFrame(_ buffer: CVPixelBuffer) {
        guard !judging, let image = makeImage(buffer) else { return }
        judging = true
        let episode = motionEpisode
        let frame = Self.comparisonFrame(buffer)
        Task.detached(priority: .userInitiated) { [self] in
            let snapshot = await snapshot(of: image, frame: frame)
            queue.async { [self] in
                judging = false
                let isNew = judge.isNewPage(snapshot)
                triggerLog.notice("Seite ruhig: \(snapshot.words.count) Wörter, neu \(isNew), überholt \(episode != self.motionEpisode)")
                guard autoTriggerEnabled, episode == motionEpisode, isNew else { return }
                judge.remember(snapshot)
                onAutoTrigger?()
            }
        }
    }

    // MARK: Umwandlung

    private func makeImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// Graubild mit rund 320 px Breite zum Vergleich ruhig liegender Seiten.
    static func comparisonFrame(_ buffer: CVPixelBuffer) -> GrayFrame {
        let width = CVPixelBufferGetWidth(buffer)
        let pixels = downsampledGray(buffer, targetWidth: 320)
        return GrayFrame(pixels: pixels, width: width / max(1, width / 320))
    }

    /// Graubild mit rund 160 px Breite für den Auslöser, direkt aus dem BGRA-Puffer.
    static func downsampledGray(_ buffer: CVPixelBuffer, targetWidth: Int = 160) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        return grayThumbnail(
            bgra: base,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            targetWidth: targetWidth
        )
    }

    /// Verkleinertes Graubild aus BGRA-Pixeln, jeder Bildpunkt der Mittelwert seines Blocks.
    ///
    /// Nur jedes n-te Pixel zu nehmen reicht nicht: Auf einer Textseite springt so ein
    /// Pixel beim kleinsten Zittern zwischen Schrift und Papier, dazu kommt das Rauschen
    /// des Sensors. Der Auslöser sähe eine ruhig liegende Textseite dann als bewegt.
    static func grayThumbnail(bgra base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow stride: Int, targetWidth: Int) -> [UInt8] {
        let step = max(1, width / targetWidth)
        let outW = width / step, outH = height / step
        var result = [UInt8](repeating: 0, count: outW * outH)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var blue = [Int](repeating: 0, count: outW), green = blue, red = blue
        let area = step * step
        for y in 0..<outH {
            for i in 0..<outW { blue[i] = 0; green[i] = 0; red[i] = 0 }
            for dy in 0..<step {
                let row = pixels + (y * step + dy) * stride
                for x in 0..<outW {
                    var p = row + x * step * 4
                    var b = 0, g = 0, r = 0
                    for _ in 0..<step {
                        b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                        p += 4
                    }
                    blue[x] += b; green[x] += g; red[x] += r
                }
            }
            for x in 0..<outW {
                // BGRA: Luma aus B, G, R
                let luma = (blue[x] * 29 + green[x] * 150 + red[x] * 77) / (area << 8)
                result[y * outW + x] = UInt8(min(255, luma))
            }
        }
        return result
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestBuffer = buffer
        frameCounter += 1

        if !pendingCaptures.isEmpty, let image = makeImage(buffer) {
            let waiting = pendingCaptures
            pendingCaptures = []
            for continuation in waiting { continuation.resume(returning: image) }
            trigger.didCapture()
            if autoTriggerEnabled { rememberCapture(image, frame: Self.comparisonFrame(buffer)) }
        }

        // Auslöser mit rund 4 Bildern pro Sekunde, das reicht für Umblättern und Ruhe.
        guard autoTriggerEnabled, frameCounter % 8 == 0 else { return }
        let gray = Self.downsampledGray(buffer)
        let grayWidth = CVPixelBufferGetWidth(buffer) / max(1, CVPixelBufferGetWidth(buffer) / 160)
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let stateBefore = trigger.state
        let settled = trigger.feed(gray, width: grayWidth, at: time)
        triggerLog.debug("Bewegung \(self.trigger.lastLevel, format: .fixed(precision: 2)), Zustand \(String(describing: self.trigger.state), privacy: .public)")
        if trigger.state != stateBefore {
            if trigger.state == .moving { motionEpisode += 1 }
            onMotionState?(trigger.state)
        }
        if settled { judgeSettledFrame(buffer) }
    }
}
