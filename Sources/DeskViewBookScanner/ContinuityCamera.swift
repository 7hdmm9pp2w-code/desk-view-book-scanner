import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import OSLog
import BookScannerKit

let continuityLog = Logger(subsystem: "org.crushkilldestroy.DeskViewBookScanner", category: "ContinuityCamera")

/// Continuity Camera, vom Mac aus ausgelöst.
///
/// AppKit hängt an das Menü-Item mit `importFromDeviceIdentifier` (hier von SwiftUIs
/// `ImportFromDevicesCommands` erzeugt) ein Untermenü mit den Geräten und „Foto
/// aufnehmen / Dokumente scannen". Die Einträge sind nur aktiv, wenn der First
/// Responder des Key-Fensters Bilddaten annimmt; ein `NSTextView` mit
/// `importsGraphics` tut das von Haus aus. Darum: verstecktes Textfeld kurz zum First
/// Responder machen, Untermenü mit `update()` ohne Anzeige füllen, Eintrag per
/// `performActionForItem` auslösen. Der Scan kommt als `NSTextAttachment` im Textfeld an
/// und wird als Datei durch den normalen Import geschickt. Nach dem Vorbild von
/// github.com/techjuicelab/continuity-capture.
@MainActor
final class ContinuityCamera {
    static let shared = ContinuityCamera()

    enum Kind: Sendable {
        case scanDocuments, takePhoto

        /// Titel des Systemeintrags in den Sprachen, die die App kennt.
        var menuTitles: [String] {
            switch self {
            case .scanDocuments: return ["Dokumente scannen", "Scan Documents"]
            case .takePhoto: return ["Foto aufnehmen", "Take Photo"]
            }
        }
    }

    enum Failure: Error, LocalizedError {
        case noReceiver, noDevice, timeout

        var errorDescription: String? {
            switch self {
            case .noReceiver: return L("Das Fenster ist nicht bereit für den iPhone-Scan.")
            case .noDevice: return L("Kein iPhone gefunden. Gleiche Apple-ID, Bluetooth und WLAN an, iPhone entsperrt und in der Nähe?")
            case .timeout: return L("Vom iPhone kam nichts an.")
            }
        }
    }

    static let acceptedTypes: [UTType] = [.pdf, .jpeg, .heic, .png, .tiff, .image]

    private(set) var isWaiting = false
    private var receiver: ReceiverTextView?
    private var previousResponder: NSResponder?
    private var completion: (([URL]) -> Void)?
    private var failure: ((Error) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var typesRegistered = false

    private init() {}

    // MARK: Empfänger

    func attach(_ view: ReceiverTextView) {
        receiver = view
        view.onAttachment = { [weak self] data in self?.received(data) }
    }

    /// Meldet AppKit die Typen, die die App annimmt. Ohne das bleibt das Untermenü leer.
    func registerTypesIfNeeded() {
        guard !typesRegistered else { return }
        typesRegistered = true
        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) } + [.pdf]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)
    }

    // MARK: Auslösen

    func start(_ kind: Kind, completion: @escaping ([URL]) -> Void, failure: @escaping (Error) -> Void) {
        guard !isWaiting else { return }
        registerTypesIfNeeded()
        guard let receiver, let window = receiver.window else {
            failure(Failure.noReceiver)
            return
        }
        self.completion = completion
        self.failure = failure
        isWaiting = true
        previousResponder = window.firstResponder
        receiver.string = ""
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(receiver)
        continuityLog.notice("Scan angefordert: \(String(describing: kind), privacy: .public), firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }), privacy: .public)")
        trigger(kind, attempt: 0)
    }

    private func trigger(_ kind: Kind, attempt: Int) {
        if let (menu, index) = findAction(kind) {
            continuityLog.notice("Löse aus: '\(menu.items[index].title, privacy: .public)' nach \(attempt) Versuchen")
            menu.performActionForItem(at: index)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard let self, self.isWaiting else { return }
                self.finish(with: .failure(Failure.timeout))
            }
            return
        }
        if attempt < 15 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                self?.trigger(kind, attempt: attempt + 1)
            }
        } else {
            continuityLog.notice("Kein passender Eintrag im Untermenü: \(self.describeFileMenu(), privacy: .public)")
            finish(with: .failure(Failure.noDevice))
        }
    }

    /// Sucht in allen Untermenüs von „Ablage" den aktiven Eintrag mit passendem Titel.
    private func findAction(_ kind: Kind) -> (NSMenu, Int)? {
        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu else { return nil }
        for item in fileMenu.items {
            guard let submenu = item.submenu else { continue }
            submenu.update()
            for (index, candidate) in submenu.items.enumerated()
            where !candidate.isSeparatorItem && candidate.isEnabled && kind.menuTitles.contains(candidate.title) {
                return (submenu, index)
            }
            // Untermenüs pro Gerät, falls das System sie so aufbaut.
            for (_, deviceItem) in submenu.items.enumerated() {
                guard let deviceMenu = deviceItem.submenu else { continue }
                deviceMenu.update()
                for (index, candidate) in deviceMenu.items.enumerated()
                where !candidate.isSeparatorItem && candidate.isEnabled && kind.menuTitles.contains(candidate.title) {
                    return (deviceMenu, index)
                }
            }
        }
        return nil
    }

    private func describeFileMenu() -> String {
        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu else { return "kein Ablage-Menü" }
        return fileMenu.items.map { item in
            var text = "'\(item.title)'"
            if let sub = item.submenu {
                text += "[" + sub.items.map { "'\($0.title)'\($0.isEnabled ? "" : "(aus)")" }.joined(separator: ",") + "]"
            }
            return text
        }.joined(separator: " ")
    }

    // MARK: Ergebnis

    private func received(_ data: Data) {
        guard isWaiting else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ContinuityCamera-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "iPhone-Scan.\(Self.fileExtension(for: data))")
            try data.write(to: url)
            continuityLog.notice("Empfangen: \(data.count) Bytes als \(url.lastPathComponent, privacy: .public)")
            finish(with: .success([url]))
        } catch {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<[URL], Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isWaiting = false
        receiver?.string = ""
        if let window = receiver?.window {
            window.makeFirstResponder(previousResponder)
        }
        previousResponder = nil
        let completion = self.completion
        let failure = self.failure
        self.completion = nil
        self.failure = nil
        switch result {
        case .success(let urls): completion?(urls)
        case .failure(let error): failure?(error)
        }
    }

    /// Endung aus den Magic Bytes; ImageIO kennt die Bildformate, PDF beginnt mit %PDF.
    static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let uti = CGImageSourceGetType(source),
           let type = UTType(uti as String),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        return "bin"
    }

    // MARK: Empfänger-Textansicht

    final class ReceiverTextView: NSTextView {
        var onAttachment: ((Data) -> Void)?
        private var observer: NSObjectProtocol?

        func startObserving() {
            guard observer == nil, let storage = textStorage else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.extractAttachments() }
            }
        }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
            if let returnType, NSImage.imageTypes.contains(returnType.rawValue) || returnType == .pdf {
                return self
            }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        private func extractAttachments() {
            guard let storage = textStorage, storage.length > 0 else { return }
            var found: Data?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                guard let attachment = value as? NSTextAttachment else { return }
                if let wrapper = attachment.fileWrapper, wrapper.isRegularFile, let data = wrapper.regularFileContents, !data.isEmpty {
                    found = data
                } else if let data = attachment.contents, !data.isEmpty {
                    found = data
                }
                if found != nil { stop.pointee = true }
            }
            if let found {
                DispatchQueue.main.async { [weak self] in self?.onAttachment?(found) }
            }
        }
    }
}

/// Unsichtbares Textfeld im Fenster; nur Empfänger, nie zu sehen.
struct ContinuityCameraReceiver: NSViewRepresentable {
    func makeNSView(context: Context) -> ContinuityCamera.ReceiverTextView {
        let view = ContinuityCamera.ReceiverTextView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        view.isRichText = true
        view.isEditable = true
        view.importsGraphics = true
        view.allowsImageEditing = false
        view.drawsBackground = false
        view.isHidden = false
        view.alphaValue = 0.01
        view.startObserving()
        ContinuityCamera.shared.attach(view)
        return view
    }

    func updateNSView(_ view: ContinuityCamera.ReceiverTextView, context: Context) {}
}
