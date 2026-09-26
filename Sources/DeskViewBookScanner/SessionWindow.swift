import SwiftUI
import BookScannerKit

/// Hauptfenster: Statusleiste mit Aufnahme-Knopf oben, darunter Thumbnail-Raster
/// links und Detail mit Bild und (später) erkanntem Text rechts.
struct SessionWindow: View {
    @Environment(AppModel.self) private var model
    @State private var titleDraft = ""

    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionSidebar()
        } detail: {
            VStack(spacing: 0) {
                StatusBar()
                    .background(alignment: .bottomLeading) {
                        ContinuityCameraReceiver().frame(width: 2, height: 2)
                    }
                Divider()
                HSplitView {
                    PageGrid()
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    PageDetail()
                        .frame(minWidth: 340, idealWidth: 460, maxWidth: 640, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 620)
        .navigationTitle(windowTitle)
        .navigationSubtitle(model.sessionDirectory?.lastPathComponent ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                TextField(L("Titel"), text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { model.setTitle(titleDraft) }
                    .disabled(model.sessionDirectory == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ExportButtons()
                Button {
                    model.splitSelectedPage()
                } label: {
                    Label(L("Seite teilen"), systemImage: "rectangle.split.2x1")
                }
                .help(L("Doppelseite am Falz in zwei Seiten teilen (⌘T)"))
                .disabled(model.selectedPageID == nil || model.sessionArchived)
                Button {
                    model.rotateSelectedPage(quarterTurns: 1)
                } label: {
                    Label(L("Nach links drehen"), systemImage: "rotate.left")
                }
                .help(L("Seite um 90° drehen (⌘L / ⌘R)"))
                .disabled(model.selectedPageID == nil || model.sessionArchived)
                Button {
                    model.trashSelectedPage()
                } label: {
                    Label(L("Seite löschen"), systemImage: "trash")
                }
                .disabled(model.selectedPageID == nil)
                .help(L("Gelöschte Seiten wandern in den Ordner „Papierkorb“ der Session."))
                Button {
                    model.revealSessionInFinder()
                } label: {
                    Label(L("Im Finder zeigen"), systemImage: "folder")
                }
                .disabled(model.sessionDirectory == nil)
            }
        }
        .onAppear { titleDraft = model.sessionTitle }
        .onChange(of: model.sessionTitle) { _, title in titleDraft = title }
        .onChange(of: model.suggestedTitle) { _, suggestion in
            // Vorschlag vom Umschlag landet im Feld; erst ⏎ benennt den Ordner um.
            if let suggestion, titleDraft.isEmpty { titleDraft = suggestion }
        }
    }

    private var windowTitle: String {
        if !model.sessionTitle.isEmpty { return model.sessionTitle }
        return model.sessionDirectory?.lastPathComponent ?? L("Desk View Book Scanner")
    }
}
