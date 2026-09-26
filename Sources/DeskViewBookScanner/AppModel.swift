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
        case iPhone, files, camera
        var id: String { rawValue }
    }
    static let cellThumbnailSize = 480
    static let detailImageSize = 2000

    static var defaultSessionRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Buchscans", directoryHint: .isDirectory)
    }

    let camera = CameraSource()
    let processor = PageProcessor()
    var hotKey: HotKey?
    /// Verkleinerte Seitenbilder, begrenzt: 300 Einträge sind bei 480-px-Vorschauen rund 150 MB.
    var imageCache = BoundedCache<String, CGImage>(limit: 240)

    var cameraDevices: [CameraDeviceInfo] = []
    var selectedCameraID: String?
    var cameraRunning = false
    var autoTrigger = false
    var motionState: MotionTrigger.State = .idle
    var sessionRoot: URL
    var session: SessionStore?
    var sessionDirectory: URL?
    var sessionTitle: String = ""
    var pages: [PageRecord] = []
    var isCapturing = false
    var hotKeyRegistered = false
    var texts: [UUID: PageText] = [:]
    var recognizingPageIDs: Set<UUID> = []
    /// Titel aus der ersten Seite, solange die Session keinen hat. Nur ein Vorschlag.
    var suggestedTitle: String?
    var exportStatus: ExportStatus?
    var pandocPath: String
    var iPhoneWaiting = false
    var sessionSettings = SessionSettings()
    var trashedCount = 0
    var captureSource: CaptureSource = .iPhone
    /// Seite, die der nächste Scan, Import oder die nächste Aufnahme ersetzt statt anzuhängen.
    var rescanTargetID: UUID?
    var titleSuggestionDismissed = false
    var summaries: [SessionSummary] = []
    var sessionArchived = false
    var sidebarThumbnails: [URL: CGImage] = [:]
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
        if let raw = UserDefaults.standard.string(forKey: Self.captureSourceDefaultsKey) {
            // „deskView" aus älteren Versionen wird zur Kamera-Quelle.
            captureSource = CaptureSource(rawValue: raw) ?? (raw == "deskView" ? .camera : .iPhone)
        }
        selectedCameraID = UserDefaults.standard.string(forKey: Self.cameraDeviceDefaultsKey)
        autoTrigger = UserDefaults.standard.bool(forKey: Self.autoTriggerDefaultsKey)
    }

    func setCaptureSource(_ source: CaptureSource) {
        captureSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.captureSourceDefaultsKey)
        if source == .camera {
            refreshCameraDevices()
            Task { await startCamera() }
        } else {
            stopCamera()
        }
    }

    /// Der eine Knopf der gewählten Quelle.
    func performPrimaryAction() {
        switch captureSource {
        case .iPhone: scanWithiPhone(.scanDocuments)
        case .files: importFiles()
        case .camera: capturePage()
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
        wireCameraCallbacks()
        if captureSource == .camera {
            refreshCameraDevices()
            Task { await startCamera() }
        }
    }

    // MARK: Sessions

    func setSessionRoot(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: Self.sessionRootDefaultsKey)
        sessionRoot = url ?? Self.defaultSessionRoot
        refreshSummaries()
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

    func adopt(_ store: SessionStore) async {
        session = store
        sessionDirectory = await store.directory
        sessionTitle = await store.document.title ?? ""
        pages = await store.orderedPages
        sessionSettings = await store.document.settings
        trashedCount = await store.document.trashed.count
        sessionArchived = await store.isArchived
        imageCache.removeAll()
        texts = [:]
        suggestedTitle = nil
        titleSuggestionDismissed = false
        selectedPageID = pages.last?.id
        for page in pages where page.ocrStatus == .pending {
            recognizeText(for: page)
        }
        refreshSummaries()
        // Vorschlag aus schon erkannten ersten Seiten, ohne neue OCR.
        if sessionTitle.isEmpty {
            for page in pages.prefix(TitleSuggester.lookahead + 1) where page.ocrStatus == .done {
                _ = await text(for: page)
            }
            if let first = pages.first { updateTitleSuggestion(after: first) }
        }
    }

    func ensureSession() async throws -> SessionStore {
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
                refreshSummaries()
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
                let image = try await camera.captureImage()
                let settings = await store.document.settings
                let prepared = await processor.prepare(image, settings: settings)
                var lastPage: PageRecord?
                if let target = takeRescanTarget() {
                    let records = try await store.replacePage(target, with: prepared)
                    forgetPage(target)
                    for record in records { recognizeText(for: record) }
                    lastPage = records.first
                } else {
                    for image in prepared {
                        let page = try await store.addPage(image)
                        recognizeText(for: page)
                        lastPage = page
                    }
                }
                pages = await store.orderedPages
                selectedPageID = lastPage?.id
                lastError = nil
                NSSound(named: "Tink")?.play()
                refreshSummaries()
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
                refreshSummaries()
                for id in pageIDs {
                    imageCache.removeAll { $0.hasPrefix(id.uuidString) }
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

// MARK: - Nachscannen

extension AppModel {
    /// Ersetzt die ausgewählte Seite durch das nächste Ergebnis der gewählten Quelle:
    /// iPhone-Scan, Dateiimport oder Desk-View-Aufnahme. Kommen mehrere Seiten,
    /// rücken sie alle an die Stelle der alten.
    func rescanSelectedPage() {
        guard let page = selectedPage, canRescan else { return }
        rescanTargetID = page.id
        switch captureSource {
        case .iPhone: scanWithiPhone(.scanDocuments)
        case .files: importFiles()
        case .camera: capturePage()
        }
        // Ein abgebrochener Dateidialog lässt das Ziel nicht stehen.
        if captureSource == .files, exportStatus == nil { rescanTargetID = nil }
    }

    var canRescan: Bool {
        selectedPageID != nil && exportStatus == nil && !sessionArchived && !iPhoneWaiting
    }

    func takeRescanTarget() -> UUID? {
        defer { rescanTargetID = nil }
        return rescanTargetID
    }

    /// Cache und Text einer ersetzten Seite vergessen; sie liegt jetzt im Papierkorb.
    func forgetPage(_ id: UUID) {
        imageCache.removeAll { $0.hasPrefix(id.uuidString) }
        texts[id] = nil
        trashedCount += 1
    }
}
