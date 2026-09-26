import SwiftUI
import BookScannerKit

/// Inhalt des Menüleisten-Fensters.
struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            captureButton
            Divider()
            sessionSection
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(L("Einstellungen…")) { openSettings() }
                    .keyboardShortcut(",")
                Spacer()
                Button(L("Beenden")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
        .font(.system(size: 13))
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .permissionMissing:
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Bildschirmaufnahme nicht freigegeben"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(L("Nach der Freigabe die App einmal beenden und neu starten."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Freigabe erteilen…")) { model.requestPermission() }
            }
        case .notRunning:
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Desk View läuft nicht"), systemImage: "camera.slash")
                    .foregroundStyle(.secondary)
                if model.isLaunchingDeskView {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("Desk View wird gestartet, bitte Einrichtung abschließen…"))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button(L("Desk View starten")) { model.launchDeskView() }
                }
            }
        case .found(let window):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("Desk View gefunden"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text(verbatim: "\(window.pixelWidth) × \(window.pixelHeight) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if window.isTooSmall {
                    Label(L("Fenster größer ziehen: unter 1600 px Breite reicht die Auflösung nicht."),
                          systemImage: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var captureButton: some View {
        VStack(spacing: 4) {
            Button {
                model.capturePage()
            } label: {
                Label(model.isCapturing ? L("Wird erfasst…") : L("Seite erfassen"), systemImage: "camera.viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!model.canCapture)
            Text(verbatim: HotKey.captureDisplayName)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("\(model.pages.count) Seiten"))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                if let directory = model.sessionDirectory {
                    Text(directory.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if model.sessionDirectory == nil {
                Text(L("Noch keine Session. Die erste Aufnahme legt eine an in \(model.sessionRoot.path)."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Session öffnen")) { openSessionWindow() }
                    .disabled(model.sessionDirectory == nil)
                Button(L("Neue Session")) { model.newSession() }
                Menu(L("Letzte Sessions")) {
                    let recent = model.recentSessionDirectories.prefix(10)
                    if recent.isEmpty {
                        Text(L("Keine Sessions vorhanden"))
                    }
                    ForEach(Array(recent), id: \.self) { directory in
                        Button(directory.lastPathComponent) {
                            model.openSession(at: directory)
                            openSessionWindow()
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func openSessionWindow() {
        openWindow(id: "session")
        NSApp.activate()
    }
}
