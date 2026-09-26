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
                Label(L("Desk View"), systemImage: "camera.macro").tag(AppModel.CaptureSource.deskView)
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
        case .deskView:
            switch model.status {
            case .permissionMissing:
                HStack(spacing: 8) {
                    Label(L("Bildschirmaufnahme nicht freigegeben"), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button(L("Freigabe erteilen…")) { model.requestPermission() }
                }
            case .notRunning:
                HStack(spacing: 8) {
                    Label(L("Desk View läuft nicht"), systemImage: "camera.slash")
                        .foregroundStyle(.secondary)
                    if model.isLaunchingDeskView {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("Desk View starten")) { model.launchDeskView() }
                    }
                }
            case .found(let window):
                HStack(spacing: 8) {
                    Label(L("Desk View gefunden"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(verbatim: "\(window.pixelWidth) × \(window.pixelHeight) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if window.isTooSmall {
                        Label(L("Fenster größer ziehen"), systemImage: "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
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
        case .deskView: return model.isCapturing ? L("Wird erfasst…") : L("Seite erfassen")
        }
    }

    private var primaryIcon: String {
        switch model.captureSource {
        case .iPhone: return "iphone.and.arrow.forward"
        case .files: return "square.and.arrow.down"
        case .deskView: return "camera.viewfinder"
        }
    }

    private var primaryHelp: String {
        switch model.captureSource {
        case .iPhone: return L("Öffnet den Dokumentenscanner auf dem iPhone; die Seiten landen in dieser Session (⇧⌘S).")
        case .files: return L("Scans aus Notizen, vFlat oder Fotos als Seiten anhängen (⇧⌘I)")
        case .deskView: return L("Tastenkürzel \(HotKey.captureDisplayName), auch wenn Desk View vorn liegt.")
        }
    }

    private var primaryEnabled: Bool {
        if model.sessionArchived { return false }
        switch model.captureSource {
        case .iPhone: return !model.iPhoneWaiting && model.exportStatus == nil
        case .files: return model.exportStatus == nil
        case .deskView: return model.canCapture
        }
    }
}
