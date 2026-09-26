import AppKit
import Observation
import BookScannerKit

/// Zustand der App für Menüleiste, Session-Fenster und Einstellungen.
@MainActor
@Observable
final class AppModel {
    static let sessionRootDefaultsKey = "sessionRootPath"
    static let cellThumbnailSize = 480
    static let detailImageSize = 2000

    static var defaultSessionRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Buchscans", directoryHint: .isDirectory)
    }

    private let source = DeskViewSource()
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
    var lastError: String?
    var selectedPageID: UUID?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.sessionRootDefaultsKey), !path.isEmpty {
            sessionRoot = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            sessionRoot = Self.defaultSessionRoot
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
        imageCache = [:]
        selectedPageID = pages.last?.id
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
