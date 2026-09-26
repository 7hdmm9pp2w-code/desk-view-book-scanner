import SwiftUI
import BookScannerKit

@main
struct DeskViewBookScannerApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        model.start()
    }

    var body: some Scene {
        // Das erste Scene öffnet SwiftUI beim Start; ein einzelnes Fenster, kein Dokument-Modell.
        Window(L("Desk View Book Scanner"), id: "main") {
            SessionWindow().environment(model)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Neue Session")) { model.newSession() }
                    .keyboardShortcut("n")
                Button(L("Session-Ordner öffnen…")) { model.chooseAndOpenSession() }
                    .keyboardShortcut("o")
                Menu(L("Letzte Sessions")) {
                    let recent = model.recentSessionDirectories.prefix(10)
                    if recent.isEmpty {
                        Text(L("Keine Sessions vorhanden"))
                    }
                    ForEach(Array(recent), id: \.self) { directory in
                        Button(directory.lastPathComponent) { model.openSession(at: directory) }
                    }
                }
                Divider()
                Button(L("Als PDF exportieren…")) { model.exportPDF() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
                Button(L("Als Markdown exportieren…")) { model.exportText(format: .markdown) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExport)
                Button(L("Als Word (DOCX) exportieren…")) { model.exportText(format: .docx) }
                    .disabled(!model.canExport || model.pandoc == nil)
                Button(L("Als EPUB exportieren…")) { model.exportText(format: .epub) }
                    .disabled(!model.canExport || model.pandoc == nil)
                Divider()
                Button(L("Im Finder zeigen")) { model.revealSessionInFinder() }
                    .disabled(model.sessionDirectory == nil)
            }
            CommandMenu(L("Aufnahme")) {
                Button(L("Seite erfassen")) { model.capturePage() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.canCapture)
                Button(L("Desk View starten")) { model.launchDeskView() }
                    .disabled(model.isLaunchingDeskView)
                Divider()
                Button(L("Seite löschen")) { model.trashSelectedPage() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedPageID == nil)
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
