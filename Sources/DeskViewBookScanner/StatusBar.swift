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
            Text(L("Scans aus Notizen, vFlat oder Fotos, PDF oder Bilder."))
                .foregroundStyle(.secondary)
        case .camera:
            HStack(spacing: 10) {
                cameraPicker
                if !model.cameraAuthorized {
                    Label(L("Kamerazugriff nicht freigegeben"), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button(L("Freigabe erteilen…")) { model.requestCameraAccess() }
                } else if let device = model.selectedCamera, model.cameraRunning {
                    Text(verbatim: "\(device.maxWidth) × \(device.maxHeight) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if model.cameraDevices.isEmpty {
                    Text(L("Keine Kamera gefunden")).foregroundStyle(.secondary)
                }
                Toggle(L("Auto-Auslöser"), isOn: Binding(get: { model.autoTrigger }, set: { model.setAutoTrigger($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.cameraRunning)
                    .help(L("Löst nach dem Umblättern aus, sobald das Bild 1,5 Sekunden ruhig liegt und sich von der letzten Seite unterscheidet."))
                if model.autoTrigger, model.motionState != .idle {
                    Label(L("Seiten glatt halten, Hände raus"), systemImage: "hand.raised")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

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
            Divider()
            Button(L("Kameras neu suchen")) { model.refreshCameraDevices() }
        } label: {
            Label(model.selectedCamera.map(deviceTitle) ?? L("Kamera wählen"), systemImage: "camera")
        }
        .fixedSize()
    }

    private func deviceTitle(_ device: CameraDeviceInfo) -> String {
        let size = String(format: "%.1f MP", device.megapixels)
        return "\(device.name) (\(size))"
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
        case .files: return L("Bilder oder PDF importieren…")
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
        case .iPhone: return L("Öffnet den Dokumentenscanner auf dem iPhone; die Seiten landen in dieser Session (⇧⌘S).")
        case .files: return L("Scans aus Notizen, vFlat oder Fotos als Seiten anhängen (⇧⌘I)")
        case .camera: return L("Bild aus der gewählten Kamera erfassen (\(HotKey.captureDisplayName), auch aus anderen Apps)")
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
