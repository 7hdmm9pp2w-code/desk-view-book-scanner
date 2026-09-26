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
    var lastError: String?
    var selectedPageID: UUID?

    enum ExportStatus: Equatable {
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
                let page = try await store.addPage(result.image)
                pages = await store.orderedPages
                selectedPageID = page.id
                lastError = nil
                NSSound(named: "Tink")?.play()
                recognizeText(for: page)
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
                try await Task.detached(priority: .userInitiated) { [self] in
                    try PDFExporter().export(
                        to: url, title: title.isEmpty ? nil : title, pageCount: total,
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
                let document = structurer.structure(pages: numbered, title: sessionTitle.isEmpty ? nil : sessionTitle)
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
        return panel.runModal() == .OK ? panel.url : nil
    }
}
