import Foundation
import CoreGraphics

/// Verarbeitung abseits des Main-Threads. Stufe 1: OCR. Zuschnitt und Teilen kommen
/// in Schritt 3 hier dazu.
public actor PageProcessor {
    private let recognizer: TextRecognizer
    private var inFlight: [UUID: Task<PageText, Error>] = [:]
    /// Erkennungen laufen nacheinander; Vision parallel auf 300 Seiten würde nur bremsen.
    private var chainTail: Task<Void, Never>?

    public init(recognizer: TextRecognizer = TextRecognizer()) {
        self.recognizer = recognizer
    }

    /// Vor dem Speichern: aufrecht drehen, Doppelseite teilen. Liefert eine oder zwei Seiten.
    public func prepare(_ image: CGImage, settings: SessionSettings) async -> [CGImage] {
        var upright = image
        var lines: [RecognizedLine] = []
        if settings.autoRotate || settings.splitMode != .none,
           let analysis = try? await OrientationDetector().analyze(image) {
            lines = analysis.lines
            if settings.autoRotate, analysis.quarterTurns != 0 {
                upright = ImageOps.rotated(image, quarterTurns: analysis.quarterTurns)
            } else if analysis.quarterTurns != 0 {
                // Nicht gedreht: Zeilen passen dann zum Originalbild, nicht zum aufgerichteten.
                lines = []
            }
        }
        return PageSplitter().split(upright, mode: settings.splitMode, lines: lines)
    }

    /// Liefert den gespeicherten Text oder erkennt ihn jetzt und speichert ihn.
    /// Mehrfache Anfragen für dieselbe Seite teilen sich eine Erkennung.
    public func text(for page: PageRecord, in store: SessionStore) async throws -> PageText {
        if let existing = try await store.loadText(for: page) {
            return existing
        }
        if let running = inFlight[page.id] {
            return try await running.value
        }
        let recognizer = self.recognizer
        let previous = chainTail
        let task = Task<PageText, Error> {
            _ = await previous?.value
            let url = await store.fileURL(for: page)
            do {
                let image = try ImageFile.read(url)
                let lines = try await recognizer.recognize(image)
                let text = PageText(
                    pageID: page.id, pixelWidth: image.width, pixelHeight: image.height,
                    languages: recognizer.languages, lines: lines
                )
                try await store.saveText(text, for: page)
                return text
            } catch {
                try? await store.updateOCRStatus(.failed, for: page.id)
                throw error
            }
        }
        inFlight[page.id] = task
        chainTail = Task { _ = try? await task.value }
        defer { inFlight[page.id] = nil }
        return try await task.value
    }
}
