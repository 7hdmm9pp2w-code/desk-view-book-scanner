import SwiftUI
import BookScannerKit

/// Seitenleiste: alle Sessions unter dem Sessions-Ordner, mit Größe, Seitenzahl und
/// Exporten. Auswahl wechselt die Session; Aufräumen über das Kontextmenü.
struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<URL> = []
    @State private var pendingDelete: [SessionSummary] = []
    @State private var pendingArchive: [SessionSummary] = []
    @State private var pendingEmptyTrash: [SessionSummary] = []

    private var deletePresented: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }

    private var archivePresented: Binding<Bool> {
        Binding(get: { !pendingArchive.isEmpty }, set: { if !$0 { pendingArchive = [] } })
    }

    private var emptyTrashPresented: Binding<Bool> {
        Binding(get: { !pendingEmptyTrash.isEmpty }, set: { if !$0 { pendingEmptyTrash = [] } })
    }

    private func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    private func summaries(for urls: Set<URL>) -> [SessionSummary] {
        model.summaries.filter { urls.contains($0.directory) }
    }

    /// Eine einzelne Auswahl öffnet die Session; eine Mehrfachauswahl nur markiert.
    private func selectionChanged(_ urls: Set<URL>) {
        guard urls.count == 1, let url = urls.first, url != model.sessionDirectory else { return }
        model.openSession(at: url)
    }

    var body: some View {
        list
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .overlay { emptyOverlay }
            .task { model.refreshSummaries() }
            .onChange(of: selection) { _, urls in selectionChanged(urls) }
            .onChange(of: model.sessionDirectory) { _, directory in
                if let directory, selection != [directory] { selection = [directory] }
            }
            .onDeleteCommand {
                let chosen = summaries(for: selection)
                if !chosen.isEmpty { pendingDelete = chosen }
            }
            .confirmationDialog(deleteTitle, isPresented: deletePresented, titleVisibility: .visible) {
                Button(L("In den Papierkorb legen"), role: .destructive) {
                    model.deleteSessions(pendingDelete)
                    pendingDelete = []
                }
            } message: {
                Text(deleteMessage)
            }
            .confirmationDialog(archiveTitle, isPresented: archivePresented, titleVisibility: .visible) {
                Button(L("Archivieren"), role: .destructive) {
                    model.archiveSessions(pendingArchive)
                    pendingArchive = []
                }
            } message: {
                Text(archiveMessage)
            }
            .confirmationDialog(emptyTrashTitle, isPresented: emptyTrashPresented, titleVisibility: .visible) {
                Button(L("Leeren"), role: .destructive) {
                    model.emptyTrash(of: pendingEmptyTrash)
                    pendingEmptyTrash = []
                }
            } message: {
                Text(emptyTrashMessage)
            }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                ForEach(model.summaries) { summary in
                    SessionRow(summary: summary)
                        .tag(summary.directory)
                }
            } header: {
                header
            }
        }
        // Rechtsklick wirkt auf die ganze Markierung; auf einer unmarkierten Zeile nur auf diese.
        .contextMenu(forSelectionType: URL.self) { urls in
            contextMenu(for: summaries(for: urls))
        }
    }

    private var header: some View {
        HStack {
            Text(L("Sessions"))
            Spacer()
            Text(bytes(model.totalBytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if model.summaries.isEmpty {
            ContentUnavailableView(L("Keine Sessions"), systemImage: "books.vertical", description: Text(L("Neue Session mit ⌘N, oder Seiten scannen.")))
        }
    }

    @ViewBuilder
    private func contextMenu(for chosen: [SessionSummary]) -> some View {
        let count = chosen.count
        if count == 1, let only = chosen.first {
            Button(L("Öffnen")) { model.openSession(at: only.directory) }
            Button(L("Im Finder zeigen")) { model.revealSession(only) }
            Divider()
        }
        let trashCount = chosen.reduce(0) { $0 + $1.trashedCount }
        let trashSize = bytes(chosen.reduce(0) { $0 + $1.trashBytes })
        Button(L("Papierkorb leeren (\(trashCount) Seiten, \(trashSize))")) { pendingEmptyTrash = chosen }
            .disabled(trashCount == 0)
        let archivable = chosen.filter { !$0.archived && $0.pageCount > 0 }
        Button(count == 1 ? L("Archivieren: Bilder entfernen, Text behalten…") : L("\(archivable.count) Sessions archivieren…")) { pendingArchive = archivable }
            .disabled(archivable.isEmpty)
        Divider()
        Button(count == 1 ? L("Session in den Papierkorb legen…") : L("\(count) Sessions in den Papierkorb legen…"), role: .destructive) { pendingDelete = chosen }
            .disabled(chosen.isEmpty)
    }

    private func names(_ chosen: [SessionSummary]) -> String {
        chosen.map { "„\($0.displayName)“" }.joined(separator: ", ")
    }

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? L("Session „\(pendingDelete.first?.displayName ?? "")“ in den Papierkorb legen?")
            : L("\(pendingDelete.count) Sessions in den Papierkorb legen?")
    }

    private var deleteMessage: String {
        let size = bytes(pendingDelete.reduce(0) { $0 + $1.totalBytes })
        return L("\(size) an Bildern, Text und Exporten wandern in den Papierkorb von macOS und lassen sich dort zurückholen.")
    }

    private var archiveTitle: String {
        pendingArchive.count == 1
            ? L("Session „\(pendingArchive.first?.displayName ?? "")“ archivieren?")
            : L("\(pendingArchive.count) Sessions archivieren?")
    }

    private var archiveMessage: String {
        let size = bytes(pendingArchive.reduce(0) { $0 + $1.imagesBytes })
        return L("Die Seitenbilder (\(size)) wandern in den Papierkorb von macOS. Text und Exporte bleiben; Markdown, Word und EPUB gehen weiter, PDF nicht mehr.")
    }

    private var emptyTrashTitle: String {
        pendingEmptyTrash.count == 1 ? L("Papierkorb der Session leeren?") : L("Papierkorb von \(pendingEmptyTrash.count) Sessions leeren?")
    }

    private var emptyTrashMessage: String {
        let count = pendingEmptyTrash.reduce(0) { $0 + $1.trashedCount }
        let size = bytes(pendingEmptyTrash.reduce(0) { $0 + $1.trashBytes })
        return L("\(count) gelöschte Seiten, \(size), wandern in den Papierkorb von macOS.")
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: summary.archived ? "archivebox" : "book.closed")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(L("\(summary.pageCount) Seiten"))
                    Text(verbatim: "·")
                    Text(summary.totalBytes.formatted(.byteCount(style: .file)))
                    if summary.archived {
                        Text(verbatim: "·")
                        Text(L("archiviert"))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if !summary.exportExtensions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(summary.exportExtensions, id: \.self) { ext in
                            Text(ext.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: summary.firstPageURL) {
            thumbnail = await model.sidebarThumbnail(for: summary)
        }
    }
}
