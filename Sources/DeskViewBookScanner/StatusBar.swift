import SwiftUI
import BookScannerKit

/// Quellenleiste über dem Raster: Wahl der Quelle, Fortschritt, der eine Hauptknopf.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker(L("Quelle"), selection: Binding(
                get: { model.captureSource },
                set: { model.setCaptureSource($0) }
            )) {
                Label(L("iPhone"), systemImage: "iphone").tag(AppModel.CaptureSource.iPhone)
                Label(L("Dateien"), systemImage: "doc.on.doc").tag(AppModel.CaptureSource.files)
                Label(L("Kamera"), systemImage: "camera").tag(AppModel.CaptureSource.camera)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            sourceStatus
            Spacer(minLength: 12)
            activity
            sequenceHint
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("\(model.pages.count) Seiten"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            primaryButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .font(.system(size: 13))
        .background(.bar)
    }

    /// Nur Desk View hat einen Zustand, der Erklärung braucht.
    @ViewBuilder
    private var sourceStatus: some View {
        switch model.captureSource {
        case .iPhone:
            Text(L("Dokumentenscanner auf dem iPhone, vom Mac ausgelöst."))
                .foregroundStyle(.secondary)
        case .files:
            HStack(spacing: 10) {
                Text(L("PDF, Bilder oder ein Video vom Umblättern."))
                    .foregroundStyle(.secondary)
                Button(L("Buch mit dem iPhone filmen…")) { model.videoGuidePresented = true }
                    .buttonStyle(.link)
                    .help(L("Anleitung: das Buch in 4K filmen und das Video importieren"))
            }
            .lineLimit(1)
        case .camera:
            HStack(spacing: 10) {
                cameraPicker
                Toggle(isOn: Binding(get: { model.autoTrigger }, set: { model.setAutoTrigger($0) })) {
                    Text(L("Beim Umblättern auslösen"))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.cameraRunning)
                .help(L("Erfasst jede neue Seite von selbst, sobald nach dem Umblättern Ruhe ist. Dieselbe Seite, eine Hand im Bild oder Zurückblättern lösen nicht aus."))
                if !model.cameraAuthorized {
                    Button {
                        model.requestCameraAccess()
                    } label: {
                        Label(L("Kamera freigeben…"), systemImage: "xmark.octagon.fill")
                    }
                    .foregroundStyle(.red)
                    .help(L("Kamerazugriff nicht freigegeben"))
                } else if model.cameraRunning, model.autoTrigger, model.motionState != .idle {
                    Label(L("Umblättern erkannt, Buch kurz ruhig halten"), systemImage: "book.pages")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if model.cameraRunning, model.autoTrigger, model.skippedKnownPage {
                    Label(L("Nicht ausgelöst: Seite schien schon erfasst"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(L("Der Text sah aus wie auf einer der zuletzt erfassten Seiten. Ist es doch eine neue Seite, mit ⌥⌘S erfassen."))
                } else if model.cameraDevices.isEmpty {
                    Text(L("Keine Kamera gefunden")).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    /// Kameramenü: Geräte mit Auflösung.
    private var cameraPicker: some View {
        Menu {
            ForEach(model.cameraDevices) { device in
                Button {
                    model.selectCamera(device.id)
                } label: {
                    if device.id == model.selectedCameraID {
                        Label(deviceTitle(device), systemImage: "checkmark")
                    } else {
                        Text(deviceTitle(device))
                    }
                }
            }
            Button(L("Kameras neu suchen")) { model.refreshCameraDevices() }
        } label: {
            Label(model.selectedCamera.map(shortTitle) ?? L("Kamera wählen"), systemImage: "camera")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func deviceTitle(_ device: CameraDeviceInfo) -> String {
        "\(device.name) · \(device.maxWidth) × \(device.maxHeight)"
    }

    /// Kurzname für die Leiste: „Desk View (MacBook Pro)" statt des Systemnamens.
    private func shortTitle(_ device: CameraDeviceInfo) -> String {
        var name = device.name
        for prefix in ["Schreibtischansicht-Kamera von ", "Desk View Camera of ", "Kamera von ", "Camera of "] {
            if name.hasPrefix(prefix) {
                let rest = name.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "„“\" "))
                name = device.kind == .deskView ? "Desk View (\(rest))" : rest
                break
            }
        }
        return "\(name) · \(String(format: "%.1f MP", device.megapixels))"
    }

    @ViewBuilder
    private var activity: some View {
        if model.sessionArchived {
            Label(L("Archiviert: nur Text, keine Bilder. Neue Session mit ⌘N."), systemImage: "archivebox")
                .foregroundStyle(.secondary)
        } else if model.iPhoneWaiting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Warte auf das iPhone…")).foregroundStyle(.secondary)
            }
        } else if let status = model.exportStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                switch status {
                case .importing(let done, let total):
                    Text(L("Import \(done) von \(total)")).monospacedDigit()
                case .importingVideo(let percent, let pages):
                    Text(L("Video \(percent) Prozent, \(pages) Seiten")).monospacedDigit()
                case .recognizing(let done, let total):
                    Text(L("Texterkennung \(done) von \(total)")).monospacedDigit()
                case .writing(let done, let total):
                    Text(L("Export \(done) von \(total)")).monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
        } else if let suggestion = model.suggestedTitle, model.sessionTitle.isEmpty {
            HStack(spacing: 6) {
                Text(L("Titelvorschlag: „\(suggestion)“"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(L("Übernehmen")) { model.setTitle(suggestion); model.dismissSuggestedTitle() }
                    .controlSize(.small)
            }
        }
    }

    /// Hinweis an der hintersten auffälligen Seite; ein Klick wählt sie aus.
    @ViewBuilder
    private var sequenceHint: some View {
        if let latest = model.latestSequenceIssue {
            Button {
                model.selectedPageID = latest.page.id
            } label: {
                Label(AppModel.describe(latest.issue), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(L("Nach den gedruckten Seitenzahlen. Klicken zeigt die Seite."))
        }
    }

    private var primaryButton: some View {
        Button {
            model.performPrimaryAction()
        } label: {
            Label(primaryTitle, systemImage: primaryIcon)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!primaryEnabled)
        .help(primaryHelp)
    }

    private var primaryTitle: String {
        switch model.captureSource {
        case .iPhone: return model.iPhoneWaiting ? L("Warte auf das iPhone…") : L("Mit iPhone scannen")
        case .files: return L("Bilder, PDF oder Video importieren…")
        case .camera: return model.isCapturing ? L("Wird erfasst…") : L("Seite erfassen")
        }
    }

    private var primaryIcon: String {
        switch model.captureSource {
        case .iPhone: return "iphone.and.arrow.forward"
        case .files: return "square.and.arrow.down"
        case .camera: return "camera.viewfinder"
        }
    }

    private var primaryHelp: String {
        switch model.captureSource {
        case .iPhone: return L("Öffnet den Dokumentenscanner auf dem iPhone; die Seiten landen in dieser Session (Leertaste oder ⇧⌘S).")
        case .files: return L("Scans aus Notizen, vFlat oder Fotos oder ein Video vom Umblättern als Seiten anhängen (⇧⌘I)")
        case .camera: return L("Bild aus der gewählten Kamera erfassen (Leertaste; \(HotKey.captureDisplayName) auch aus anderen Apps)")
        }
    }

    private var primaryEnabled: Bool {
        if model.sessionArchived { return false }
        switch model.captureSource {
        case .iPhone: return !model.iPhoneWaiting && model.exportStatus == nil
        case .files: return model.exportStatus == nil
        case .camera: return model.canCapture
        }
    }
}
