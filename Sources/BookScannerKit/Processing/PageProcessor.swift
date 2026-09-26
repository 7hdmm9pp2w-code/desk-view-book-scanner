import Foundation
import CoreGraphics

/// Verarbeitung abseits des Main-Threads. Stufe 1: OCR. Zuschnitt und Teilen kommen
/// in Schritt 3 hier dazu.
public actor PageProcessor {
    private let recognizer: TextRecognizer
    private var inFlight: [UUID: Task<PageText, Error>] = [:]

    public init(recognizer: TextRecognizer = TextRecognizer()) {
        self.recognizer = recognizer
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
        let task = Task<PageText, Error> {
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
        defer { inFlight[page.id] = nil }
        return try await task.value
    }
}
