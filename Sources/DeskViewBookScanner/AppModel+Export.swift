import AppKit
import Observation
import UniformTypeIdentifiers
import BookScannerKit

// MARK: - Texterkennung und Export

extension AppModel {
    /// Erkennt den Text einer Seite im Hintergrund und merkt ihn sich.
    func recognizeText(for page: PageRecord) {
        guard let session, !recognizingPageIDs.contains(page.id), texts[page.id] == nil else { return }
        recognizingPageIDs.insert(page.id)
        Task {
            defer { recognizingPageIDs.remove(page.id) }
            do {
                let text = try await processor.text(for: page, in: session)
                texts[page.id] = text
                pages = await session.orderedPages
                updateTitleSuggestion(after: page)
            } catch {
                pages = await session.orderedPages
                lastError = error.localizedDescription
            }
        }
    }

    /// Gespeicherter Text einer Seite, aus dem Cache oder von der Platte.
    func text(for page: PageRecord) async -> PageText? {
        if let cached = texts[page.id] { return cached }
        guard let session, let text = try? await session.loadText(for: page) else { return nil }
        texts[page.id] = text
        return text
    }

    func dismissSuggestedTitle() {
        suggestedTitle = nil
        titleSuggestionDismissed = true
    }

    /// Vorschlag aus Umschlag und den folgenden Seiten, sobald deren Text vorliegt.
    func updateTitleSuggestion(after page: PageRecord) {
        guard sessionTitle.isEmpty, !titleSuggestionDismissed else { return }
        let first = Array(pages.prefix(TitleSuggester.lookahead + 1))
        guard first.contains(where: { $0.id == page.id }), let cover = first.first, let coverText = texts[cover.id] else { return }
        let following = first.dropFirst().compactMap { texts[$0.id] }
        suggestedTitle = TitleSuggester.suggest(cover: coverText, followingPages: following)
    }

    // MARK: Import

    /// Bilder und PDFs (Notizen, vFlat, Fotos) als Seiten anhängen, aus Videos die
    /// Seiten nach jedem Umblättern.
    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PageImporter.supportedTypes + VideoPageExtractor.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Bilder, PDF-Scans oder ein Video vom Umblättern wählen; die Seiten werden in dieser Reihenfolge angehängt.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    /// Aus der Anleitung: nur Videos, im Ordner Downloads, wo AirDrop sie ablegt.
    func importVideoFromGuide() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoPageExtractor.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = L("Video vom Umblättern wählen; mehrere werden nach Namen sortiert nacheinander angehängt.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        guard exportStatus == nil else { return }
        // Der Öffnen-Dialog liefert die Auswahlreihenfolge; Seiten gehören nach Dateinamen
        // sortiert, mit Zahlen numerisch („Aufnahme-9" vor „Aufnahme-10").
        let files = urls
            .filter { PageImporter.isSupported($0) || VideoPageExtractor.isSupported($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { return }
        Task {
            do {
                let store = try await ensureSession()
                // Ein Video verrät seine Seitenzahl erst beim Durchlesen; es hat eigenen Fortschritt.
                var total = 0
                for url in files where !VideoPageExtractor.isSupported(url) { total += try PageImporter.pageCount(of: url) }
                var done = 0
                exportStatus = total > 0 ? .importing(done: 0, total: total) : .importingVideo(percent: 0, pages: 0)
                let target = takeRescanTarget()
                var replacements: [CGImage] = []
                var reports: [VideoImportReport] = []

                /// Bereitet ein Bild auf und hängt es an, oder sammelt es fürs Nachscannen.
                @MainActor func add(_ image: CGImage) async throws {
                    let settings = await store.document.settings
                    let prepared = await processor.prepare(image, settings: settings)
                    if target != nil {
                        replacements.append(contentsOf: prepared)
                    } else {
                        for image in prepared {
                            let page = try await store.addPage(image)
                            selectedPageID = page.id
                            recognizeText(for: page)
                        }
                    }
                    pages = await store.orderedPages
                }

                for url in files {
                    if VideoPageExtractor.isSupported(url) {
                        reports.append(try await importVideo(url) { try await add($0) })
                        exportStatus = total > done ? .importing(done: done, total: total) : nil
                        continue
                    }
                    let count = try PageImporter.pageCount(of: url)
                    for index in 0..<count {
                        let image = try await Task.detached(priority: .userInitiated) {
                            try PageImporter.image(at: index, from: url)
                        }.value
                        try await add(image)
                        done += 1
                        exportStatus = .importing(done: done, total: total)
                    }
                }
                if let target, !replacements.isEmpty {
                    // Nachscannen: neue Seiten neben die alte, zum Vergleichen.
                    let records = try await stageRescan(of: target, with: replacements, in: store)
                    selectedPageID = records.first?.id
                }
                exportStatus = nil
                lastError = nil
                videoReports = reports
                refreshSummaries()
            } catch {
                exportStatus = nil
                lastError = error.localizedDescription
            }
        }
    }

    /// Liest das Video durch und gibt jede neue Seite an `add`, Fortschritt in der Leiste.
    private func importVideo(_ url: URL, add: @escaping @MainActor (CGImage) async throws -> Void) async throws -> VideoImportReport {
        final class Count: @unchecked Sendable { var pages = 0; var percent = 0 }
        let count = Count()
        exportStatus = .importingVideo(percent: 0, pages: 0)
        return try await VideoPageExtractor().extractPages(from: url, progress: { [weak self] share in
            await MainActor.run {
                count.percent = Int(share * 100)
                self?.exportStatus = .importingVideo(percent: count.percent, pages: count.pages)
            }
        }) { [weak self] image in
            try await add(image)
            await MainActor.run {
                count.pages += 1
                self?.exportStatus = .importingVideo(percent: count.percent, pages: count.pages)
            }
        }
    }

    /// Rückmeldung nach dem Videoimport: was gefunden wurde und was beim nächsten Mal hilft.
    static func describe(_ reports: [VideoImportReport]) -> String {
        reports.map { report in
            let minutes = Int(report.duration) / 60, seconds = Int(report.duration) % 60
            let length = String(format: "%d:%02d", minutes, seconds)
            var lines = [L("„\(report.fileName)“: \(report.pages) Seiten aus \(length) min Video, \(report.pixelWidth) × \(report.pixelHeight).")]
            if report.pages == 0 {
                lines.append(L("Keine ruhige Seite gefunden. iPhone fest montieren und nach dem Umblättern jeweils zwei Sekunden stillhalten."))
            }
            if report.isBelow4K {
                lines.append(L("Das Video ist kleiner als 4K; für Fließtext in der Kamera-App 4K wählen."))
            }
            if report.skippedKnownPages > 0 {
                lines.append(L("\(report.skippedKnownPages)-mal lag eine schon erfasste Seite still und wurde übersprungen. Fehlt doch eine, zeigt die Prüfung der Seitenzahlen die Lücke."))
            }
            return lines.joined(separator: " ")
        }
        .joined(separator: "\n\n")
    }

    // MARK: Seiten bearbeiten

    func setSplitMode(_ mode: SplitMode) {
        sessionSettings.splitMode = mode
        persistSettings()
    }

    func setAutoRotate(_ on: Bool) {
        sessionSettings.autoRotate = on
        persistSettings()
    }

    func persistSettings() {
        guard let session else { return }
        let settings = sessionSettings
        Task {
            do { try await session.updateSettings(settings) } catch { lastError = error.localizedDescription }
        }
    }

    /// Ausgewählte Doppelseite am Falz teilen (oder in der Mitte, je nach Einstellung).
    func splitSelectedPage() {
        let mode: SplitMode = sessionSettings.splitMode == .none ? .automatic : sessionSettings.splitMode
        let processor = self.processor
        replaceSelectedPageAsync { image in
            await processor.split(image, mode: mode)
        }
    }

    /// Ausgewählte Seite um 90° drehen; positive Werte gegen den Uhrzeigersinn.
    func rotateSelectedPage(quarterTurns: Int) {
        replaceSelectedPage { image in [ImageOps.rotated(image, quarterTurns: quarterTurns)] }
    }

    var selectedPage: PageRecord? {
        pages.first { $0.id == selectedPageID }
    }

    var canRestoreTrashed: Bool { trashedCount > 0 }

    /// Holt die zuletzt gelöschte Seite vor die ausgewählte Seite zurück (oder ans Ende).
    func restoreLastTrashedPage() {
        guard let session, exportStatus == nil else { return }
        Task {
            do {
                guard let page = try await session.restoreLastTrashed(before: selectedPageID) else { return }
                pages = await session.orderedPages
                trashedCount = await session.document.trashed.count
                refreshSummaries()
                selectedPageID = page.id
                if page.ocrStatus != .done { recognizeText(for: page) }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func replaceSelectedPage(_ transform: @escaping @Sendable (CGImage) -> [CGImage]?) {
        replaceSelectedPageAsync { image in transform(image) }
    }

    func replaceSelectedPageAsync(_ transform: @escaping @Sendable (CGImage) async -> [CGImage]?) {
        guard let session, let page = selectedPage, exportStatus == nil else { return }
        Task {
            do {
                let url = await session.fileURL(for: page)
                let images = try await Task.detached(priority: .userInitiated) { () -> [CGImage]? in
                    await transform(try ImageFile.read(url))
                }.value
                guard let images else {
                    lastError = L("Kein Schnitt gefunden: keine Doppelseite oder Text über der Schnittlinie.")
                    return
                }
                let records = try await session.replacePage(page.id, with: images)
                trashedCount = await session.document.trashed.count
                refreshSummaries()
                imageCache.removeAll { $0.hasPrefix(page.id.uuidString) }
                texts[page.id] = nil
                pages = await session.orderedPages
                selectedPageID = records.first?.id
                for record in records { recognizeText(for: record) }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: iPhone

    var isWaitingForiPhone: Bool { ContinuityCamera.shared.isWaiting }

    /// Löst „Dokumente scannen" oder „Foto aufnehmen" auf dem iPhone aus.
    func scanWithiPhone(_ kind: ContinuityCamera.Kind = .scanDocuments) {
        guard exportStatus == nil else { return }
        iPhoneWaiting = true
        ContinuityCamera.shared.start(kind) { [weak self] urls in
            guard let self else { return }
            self.iPhoneWaiting = false
            self.lastError = nil
            self.importFiles(urls)
        } failure: { [weak self] error in
            guard let self else { return }
            self.iPhoneWaiting = false
            self.rescanTargetID = nil
            self.lastError = error.localizedDescription
            NSSound.beep()
        }
    }

    // MARK: Pandoc

    var pandoc: Pandoc? {
        Pandoc.locate(preferredPath: pandocPath)
    }

    func setPandocPath(_ path: String) {
        pandocPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(pandocPath, forKey: Self.pandocPathDefaultsKey)
    }

    // MARK: Export

    var canExport: Bool {
        !pages.isEmpty && exportStatus == nil
    }

    /// Gesetzter Titel, sonst der Vorschlag vom Umschlag.
    var effectiveTitle: String? {
        sessionTitle.isEmpty ? suggestedTitle : sessionTitle
    }

    func exportPDF() {
        guard let session, canExport else { return }
        let createdAt = sessionCreatedAt
        Task {
            guard let url = savePanel(fileName: ExportNaming.fileName(createdAt: createdAt, title: effectiveTitle, fileExtension: "pdf"), contentType: .pdf) else { return }
            do {
                let (urls, texts) = try await collectTexts(session: session)
                let total = urls.count
                exportStatus = .writing(done: 0, total: total)
                let pdfTitle = effectiveTitle
                try await Task.detached(priority: .userInitiated) { [self] in
                    try PDFExporter().export(
                        to: url, title: pdfTitle, pageCount: total,
                        load: { index in (try ImageFile.read(urls[index]), texts[index]) },
                        progress: { done in Task { @MainActor in self.exportStatus = .writing(done: done, total: total) } }
                    )
                }.value
                exportStatus = nil
                lastError = nil
                refreshSummaries()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportStatus = nil
                lastError = error.localizedDescription
            }
        }
    }

    func exportText(format: Pandoc.Format) {
        guard let session, canExport else { return }
        let createdAt = sessionCreatedAt
        let pandoc = self.pandoc
        if pandoc == nil && format != .markdown {
            lastError = ExportError.pandocMissing.localizedDescription
            return
        }
        let contentType: UTType = switch format {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .docx: UTType(filenameExtension: "docx") ?? .data
        case .epub: .epub
        }
        Task {
            guard let url = savePanel(fileName: ExportNaming.fileName(createdAt: createdAt, title: effectiveTitle, fileExtension: format.fileExtension), contentType: contentType) else { return }
            do {
                let (_, texts) = try await collectTexts(session: session)
                let numbered = texts.enumerated().compactMap { index, text in text.map { (number: index + 1, text: $0) } }
                let structurer = DocumentStructurer(wordChecker: SpellCheckerWordChecker(language: "de"))
                let document = structurer.structure(pages: numbered, title: effectiveTitle)
                exportStatus = .writing(done: 0, total: 1)
                try await Task.detached(priority: .userInitiated) {
                    try TextExporter.export(document, to: url, format: format, pandoc: pandoc)
                }.value
                exportStatus = nil
                lastError = nil
                refreshSummaries()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportStatus = nil
                lastError = error.localizedDescription
            }
        }
    }

    var sessionCreatedAt: Date {
        sessionDirectory.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate } ?? .now
    }

    /// Text aller Seiten in Reihenfolge; erkennt, was noch fehlt.
    func collectTexts(session: SessionStore) async throws -> (urls: [URL], texts: [PageText?]) {
        let pages = self.pages
        var urls: [URL] = []
        var result: [PageText?] = []
        for (index, page) in pages.enumerated() {
            exportStatus = .recognizing(done: index, total: pages.count)
            urls.append(await session.fileURL(for: page))
            do {
                let text = try await processor.text(for: page, in: session)
                texts[page.id] = text
                result.append(text)
            } catch {
                result.append(nil)
            }
        }
        self.pages = await session.orderedPages
        return (urls, result)
    }

    func savePanel(fileName: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Standard: neben die Aufnahmen in den Session-Ordner.
        panel.directoryURL = sessionDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }
}
