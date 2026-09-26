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
            // „Vom iPhone oder iPad importieren" im Menü Ablage; Empfang über importsItemProviders.
            ImportFromDevicesCommands()
            CommandGroup(replacing: .newItem) {
                Button(L("Neue Session")) { model.newSession() }
                    .keyboardShortcut("n")
                Button(L("Session-Ordner öffnen…")) { model.chooseAndOpenSession() }
                    .keyboardShortcut("o")
                Divider()
                Button(L("Als PDF exportieren…")) { model.exportPDF() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport || model.sessionArchived)
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
                Section(L("iPhone")) {
                    Button(L("Dokumente mit dem iPhone scannen")) { model.scanWithiPhone(.scanDocuments) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(model.iPhoneWaiting)
                    Button(L("Foto mit dem iPhone aufnehmen")) { model.scanWithiPhone(.takePhoto) }
                        .disabled(model.iPhoneWaiting)
                }
                Section(L("Dateien")) {
                    Button(L("Bilder oder PDF importieren…")) { model.importFiles() }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                }
                Section(L("Desk View")) {
                    Button(L("Seite erfassen")) { model.capturePage() }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                        .disabled(!model.canCapture)
                    Button(L("Desk View starten")) { model.launchDeskView() }
                        .disabled(model.isLaunchingDeskView)
                }
            }
            CommandMenu(L("Seite")) {
                Button(L("Seite teilen")) { model.splitSelectedPage() }
                    .keyboardShortcut("t")
                    .disabled(model.selectedPageID == nil || model.sessionArchived)
                Button(L("Nach links drehen")) { model.rotateSelectedPage(quarterTurns: 1) }
                    .keyboardShortcut("l")
                    .disabled(model.selectedPageID == nil || model.sessionArchived)
                Button(L("Nach rechts drehen")) { model.rotateSelectedPage(quarterTurns: -1) }
                    .keyboardShortcut("r")
                    .disabled(model.selectedPageID == nil || model.sessionArchived)
                Divider()
                Button(L("Seite nachscannen")) { model.rescanSelectedPage() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canRescan)
                Divider()
                Button(L("Seite löschen")) { model.trashSelectedPage() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selectedPageID == nil)
                Button(L("Zuletzt gelöschte Seite zurückholen")) { model.restoreLastTrashedPage() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRestoreTrashed)
                Divider()
                Picker(L("Doppelseiten teilen"), selection: Binding(
                    get: { model.sessionSettings.splitMode },
                    set: { model.setSplitMode($0) }
                )) {
                    Text(L("Automatisch am Falz")).tag(SplitMode.automatic)
                    Text(L("In der Mitte")).tag(SplitMode.middle)
                    Text(L("Nicht teilen")).tag(SplitMode.none)
                }
                Toggle(L("Aufrecht drehen"), isOn: Binding(
                    get: { model.sessionSettings.autoRotate },
                    set: { model.setAutoRotate($0) }
                ))
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
