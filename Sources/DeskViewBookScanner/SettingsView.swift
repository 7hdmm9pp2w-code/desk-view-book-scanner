import SwiftUI
import BookScannerKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pandocDraft = ""

    var body: some View {
        Form {
            Section(L("Speicherort")) {
                LabeledContent(L("Sessions-Ordner")) {
                    Text(model.sessionRoot.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button(L("Ordner wählen…")) { chooseFolder() }
                    Button(L("Standard")) { model.setSessionRoot(nil) }
                        .disabled(model.sessionRoot == AppModel.defaultSessionRoot)
                }
            }
            Section(L("Tastenkürzel")) {
                LabeledContent(L("Seite erfassen"), value: HotKey.captureDisplayName)
                if !model.hotKeyRegistered {
                    Text(L("Das Tastenkürzel konnte nicht registriert werden, vermutlich belegt es eine andere App."))
                        .foregroundStyle(.orange)
                }
            }
            Section(L("Pandoc")) {
                if let pandoc = model.pandoc {
                    LabeledContent(L("Gefunden"), value: pandoc.version() ?? pandoc.executable.path)
                    LabeledContent(L("Pfad"), value: pandoc.isBundled ? L("Mitgeliefert im App-Bundle") : pandoc.executable.path)
                } else {
                    LabeledContent(L("Gefunden"), value: L("Nein"))
                    Text(L("Ohne Pandoc schreibt die App Markdown selbst, mit einfacherer Struktur. Pandoc liefert bessere Ergebnisse und zusätzlich Word und EPUB. Installation: brew install pandoc"))
                        .foregroundStyle(.secondary)
                }
                TextField(L("Eigener Pfad zu pandoc"), text: $pandocDraft)
                    .onSubmit { model.setPandocPath(pandocDraft) }
            }
            Section(L("Bildschirmaufnahme")) {
                LabeledContent(L("Freigabe"), value: model.permissionGranted ? L("Erteilt") : L("Nicht erteilt"))
                Button(L("Systemeinstellungen öffnen")) { model.openPermissionSettings() }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 13))
        .frame(width: 520)
        .onAppear { pandocDraft = model.pandocPath }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.sessionRoot
        panel.prompt = L("Wählen")
        if panel.runModal() == .OK, let url = panel.url {
            model.setSessionRoot(url)
        }
    }
}
