import AppKit
import Observation
import UniformTypeIdentifiers
import BookScannerKit

/// Zustand der App für Menüleiste, Session-Fenster und Einstellungen.
@MainActor
@Observable
final class AppModel {
    static let sessionRootDefaultsKey = "sessionRootPath"
    static let pandocPathDefaultsKey = "pandocPath"
    static let captureSourceDefaultsKey = "captureSource"

    /// Woher Seiten kommen. Bestimmt den Hauptknopf und den Leerzustand.
    enum CaptureSource: String, CaseIterable, Identifiable {
        case iPhone, files, deskView
        var id: String { rawValue }
    }
    static let cellThumbnailSize = 480
    static let detailImageSize = 2000

    static var defaultSessionRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Buchscans", directoryHint: .isDirectory)
    }

    private let source = DeskViewSource()
    private let processor = PageProcessor()
    private var hotKey: HotKey?
    private var monitorTask: Task<Void, Never>?
    private var imageCache: [String: CGImage] = [:]

    private(set) var status: DeskViewStatus = .notRunning
    private(set) var sessionRoot: URL
    private(set) var session: SessionStore?
    private(set) var sessionDirectory: URL?
    private(set) var sessionTitle: String = ""
    private(set) var pages: [PageRecord] = []
    private(set) var isCapturing = false
    private(set) var isLaunchingDeskView = false
    private(set) var hotKeyRegistered = false
    private(set) var texts: [UUID: PageText] = [:]
    private(set) var recognizingPageIDs: Set<UUID> = []
    /// Titel aus der ersten Seite, solange die Session keinen hat. Nur ein Vorschlag.
    private(set) var suggestedTitle: String?
    private(set) var exportStatus: ExportStatus?
    private(set) var pandocPath: String
    private(set) var iPhoneWaiting = false
    private(set) var sessionSettings = SessionSettings()
    private(set) var trashedCount = 0
    private(set) var captureSource: CaptureSource = .iPhone
    var lastError: String?
    var selectedPageID: UUID?

    enum ExportStatus: Equatable {
        case importing(done: Int, total: Int)
        case recognizing(done: Int, total: Int)
        case writing(done: Int, total: Int)
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.sessionRootDefaultsKey), !path.isEmpty {
            sessionRoot = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            sessionRoot = Self.defaultSessionRoot
        }
        pandocPath = UserDefaults.standard.string(forKey: Self.pandocPathDefaultsKey) ?? ""
        if let raw = UserDefaults.standard.string(forKey: Self.captureSourceDefaultsKey), let source = CaptureSource(rawValue: raw) {
            captureSource = source
        }
    }

    func setCaptureSource(_ source: CaptureSource) {
        captureSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.captureSourceDefaultsKey)
    }

    /// Der eine Knopf der gewählten Quelle.
    func performPrimaryAction() {
        switch captureSource {
        case .iPhone: scanWithiPhone(.scanDocuments)
        case .files: importFiles()
        case .deskView: capturePage()
        }
    }

    // MARK: Start

    func start() {
        if hotKey == nil {
            hotKey = HotKey(keyCode: HotKey.captureKeyCode, modifiers: HotKey.captureModifiers) { [weak self] in
                self?.capturePage()
            }
            hotKeyRegistered = hotKey != nil
        }
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshStatus() async {
        status = await source.status()
    }

    var canCapture: Bool {
        if case .found = status { return !isCapturing }
        return false
    }

    // MARK: Rechte und Desk View

    var permissionGranted: Bool { ScreenCapturePermission.isGranted }

    func requestPermission() {
        // Zeigt den Systemdialog nur beim allerersten Mal; danach hilft nur der Weg
        // über die Systemeinstellungen.
        if !ScreenCapturePermission.request() {
            openPermissionSettings()
        }
        Task { await refreshStatus() }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(ScreenCapturePermission.settingsURL)
    }

    func launchDeskView() {
        guard !isLaunchingDeskView else { return }
        isLaunchingDeskView = true
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1600, height: 1000)
        Task {
            defer { isLaunchingDeskView = false }
            do {
                try await source.launch(windowFrame: frame)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            await refreshStatus()
        }
    }

    // MARK: Sessions

    func setSessionRoot(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: Self.sessionRootDefaultsKey)
        sessionRoot = url ?? Self.defaultSessionRoot
    }

    var recentSessionDirectories: [URL] {
        SessionStore.sessionDirectories(in: sessionRoot)
    }

    func newSession() {
        Task {
            do {
                let store = try SessionStore.create(in: sessionRoot)
                await adopt(store)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openSession(at directory: URL) {
        Task {
            do {
                let store = try SessionStore.open(directory: directory)
                await adopt(store)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Ordner mit `session.json` auswählen und öffnen.
    func chooseAndOpenSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = sessionRoot
        panel.prompt = L("Öffnen")
        panel.message = L("Einen Session-Ordner wählen (enthält session.json).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSession(at: url)
    }

    private func adopt(_ store: SessionStore) async {
        session = store
        sessionDirectory = await store.directory
        sessionTitle = await store.document.title ?? ""
        pages = await store.orderedPages
        sessionSettings = await store.document.settings
        trashedCount = await store.document.trashed.count
        imageCache = [:]
        texts = [:]
        suggestedTitle = nil
        selectedPageID = pages.last?.id
        for page in pages where page.ocrStatus == .pending {
            recognizeText(for: page)
        }
    }

    private func ensureSession() async throws -> SessionStore {
        if let session { return session }
        let store = try SessionStore.create(in: sessionRoot)
        await adopt(store)
        return store
    }

    func setTitle(_ title: String) {
        guard let session else { return }
        Task {
            do {
                try await session.setTitleAndRenameDirectory(title)
                sessionDirectory = await session.directory
                sessionTitle = await session.document.title ?? ""
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func revealSessionInFinder() {
        guard let sessionDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
    }

    // MARK: Seiten

    func capturePage() {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let store = try await ensureSession()
                let result = try await source.captureImage()
                let settings = await store.document.settings
                var lastPage: PageRecord?
                for image in await processor.prepare(result.image, settings: settings) {
                    let page = try await store.addPage(image)
                    recognizeText(for: page)
                    lastPage = page
                }
                pages = await store.orderedPages
                selectedPageID = lastPage?.id
                lastError = nil
                NSSound(named: "Tink")?.play()
            } catch {
                lastError = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    func move(pageID: UUID, before target: UUID?) {
        guard let session else { return }
        Task {
            do {
                try await session.move(pageID: pageID, before: target)
                pages = await session.orderedPages
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func trashSelectedPage() {
        guard let id = selectedPageID else { return }
        trash(pageIDs: [id])
    }

    func trash(pageIDs: [UUID]) {
        guard let session, !pageIDs.isEmpty else { return }
        let index = pages.firstIndex { $0.id == pageIDs[0] } ?? 0
        Task {
            do {
                try await session.trash(pageIDs: pageIDs)
                pages = await session.orderedPages
                trashedCount = await session.document.trashed.count
                for id in pageIDs {
                    imageCache = imageCache.filter { !$0.key.hasPrefix(id.uuidString) }
                    texts[id] = nil
                }
                if pages.isEmpty {
                    selectedPageID = nil
                } else {
                    selectedPageID = pages[min(index, pages.count - 1)].id
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Verkleinertes Bild, längste Kante höchstens `maxPixelSize`, mit Cache.
    func image(for page: PageRecord, maxPixelSize: Int) async -> CGImage? {
        let key = "\(page.id.uuidString)-\(maxPixelSize)"
        if let cached = imageCache[key] { return cached }
        guard let session else { return nil }
        let url = await session.fileURL(for: page)
        let image = await Task.detached(priority: .userInitiated) {
            try? ImageFile.thumbnail(url, maxPixelSize: maxPixelSize)
        }.value
        if let image { imageCache[key] = image }
        return image
    }
}

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
                if sessionTitle.isEmpty, suggestedTitle == nil, pages.first?.id == page.id {
                    suggestedTitle = TitleSuggester.suggest(from: text)
                }
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
    }

    // MARK: Import

    /// Bilder und PDFs (Notizen, vFlat, Fotos) als Seiten anhängen.
    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PageImporter.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Bilder oder PDF-Scans wählen; die Seiten werden in dieser Reihenfolge angehängt.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        guard exportStatus == nil else { return }
        // Der Öffnen-Dialog liefert die Auswahlreihenfolge; Seiten gehören nach Dateinamen
        // sortiert, mit Zahlen numerisch („Aufnahme-9" vor „Aufnahme-10").
        let files = urls
            .filter { PageImporter.isSupported($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { return }
        Task {
            do {
                let store = try await ensureSession()
                var total = 0
                for url in files { total += try PageImporter.pageCount(of: url) }
                var done = 0
                exportStatus = .importing(done: 0, total: total)
                for url in files {
                    let count = try PageImporter.pageCount(of: url)
                    for index in 0..<count {
                        let image = try await Task.detached(priority: .userInitiated) {
                            try PageImporter.image(at: index, from: url)
                        }.value
                        let settings = await store.document.settings
                        for prepared in await processor.prepare(image, settings: settings) {
                            let page = try await store.addPage(prepared)
                            selectedPageID = page.id
                            recognizeText(for: page)
                        }
                        pages = await store.orderedPages
                        done += 1
                        exportStatus = .importing(done: done, total: total)
                    }
                }
                exportStatus = nil
                lastError = nil
            } catch {
                exportStatus = nil
                lastError = error.localizedDescription
            }
        }
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

    private func persistSettings() {
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

    private var selectedPage: PageRecord? {
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
                selectedPageID = page.id
                if page.ocrStatus != .done { recognizeText(for: page) }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func replaceSelectedPage(_ transform: @escaping @Sendable (CGImage) -> [CGImage]?) {
        replaceSelectedPageAsync { image in transform(image) }
    }

    private func replaceSelectedPageAsync(_ transform: @escaping @Sendable (CGImage) async -> [CGImage]?) {
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
                imageCache = imageCache.filter { !$0.key.hasPrefix(page.id.uuidString) }
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

    func exportPDF() {
        guard let session, canExport else { return }
        let createdAt = sessionCreatedAt
        Task {
            guard let url = savePanel(fileName: ExportNaming.fileName(createdAt: createdAt, title: sessionTitle, fileExtension: "pdf"), contentType: .pdf) else { return }
            do {
                let (urls, texts) = try await collectTexts(session: session)
                let title = sessionTitle
                let total = urls.count
                exportStatus = .writing(done: 0, total: total)
                let pdfTitle = title.isEmpty ? suggestedTitle : title
                try await Task.detached(priority: .userInitiated) { [self] in
                    try PDFExporter().export(
                        to: url, title: pdfTitle, pageCount: total,
                        load: { index in (try ImageFile.read(urls[index]), texts[index]) },
                        progress: { done in Task { @MainActor in self.exportStatus = .writing(done: done, total: total) } }
                    )
                }.value
                exportStatus = nil
                lastError = nil
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
            guard let url = savePanel(fileName: ExportNaming.fileName(createdAt: createdAt, title: sessionTitle, fileExtension: format.fileExtension), contentType: contentType) else { return }
            do {
                let (_, texts) = try await collectTexts(session: session)
                let numbered = texts.enumerated().compactMap { index, text in text.map { (number: index + 1, text: $0) } }
                let structurer = DocumentStructurer(wordChecker: SpellCheckerWordChecker(language: "de"))
                // Ohne gesetzten Titel nimmt der Export den Vorschlag vom Umschlag.
                let title = sessionTitle.isEmpty ? suggestedTitle : sessionTitle
                let document = structurer.structure(pages: numbered, title: title)
                exportStatus = .writing(done: 0, total: 1)
                try await Task.detached(priority: .userInitiated) {
                    try TextExporter.export(document, to: url, format: format, pandoc: pandoc)
                }.value
                exportStatus = nil
                lastError = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportStatus = nil
                lastError = error.localizedDescription
            }
        }
    }

    private var sessionCreatedAt: Date {
        sessionDirectory.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate } ?? .now
    }

    /// Text aller Seiten in Reihenfolge; erkennt, was noch fehlt.
    private func collectTexts(session: SessionStore) async throws -> (urls: [URL], texts: [PageText?]) {
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

    private func savePanel(fileName: String, contentType: UTType) -> URL? {
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
