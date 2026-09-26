import SwiftUI
import BookScannerKit

/// Seitenleiste: alle Sessions unter dem Sessions-Ordner, mit Größe, Seitenzahl und
/// Exporten. Auswahl wechselt die Session; Aufräumen über das Kontextmenü.
struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: SessionSummary?
    @State private var pendingArchive: SessionSummary?
    @State private var pendingEmptyTrash: SessionSummary?

    private var selection: Binding<URL?> {
        Binding(
            get: { model.sessionDirectory },
            set: { url in if let url, url != model.sessionDirectory { model.openSession(at: url) } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var archivePresented: Binding<Bool> {
        Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } })
    }

    private var emptyTrashPresented: Binding<Bool> {
        Binding(get: { pendingEmptyTrash != nil }, set: { if !$0 { pendingEmptyTrash = nil } })
    }

    private func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    var body: some View {
        list
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .overlay { emptyOverlay }
            .task { model.refreshSummaries() }
            .confirmationDialog(deleteTitle, isPresented: deletePresented, titleVisibility: .visible) {
                Button(L("In den Papierkorb legen"), role: .destructive) {
                    if let summary = pendingDelete { model.deleteSession(summary) }
                    pendingDelete = nil
                }
            } message: {
                Text(L("Bilder, Text und Exporte wandern in den Papierkorb von macOS und lassen sich dort zurückholen."))
            }
            .confirmationDialog(archiveTitle, isPresented: archivePresented, titleVisibility: .visible) {
                Button(L("Archivieren"), role: .destructive) {
                    if let summary = pendingArchive { model.archiveSession(summary) }
                    pendingArchive = nil
                }
            } message: {
                Text(archiveMessage)
            }
            .confirmationDialog(L("Papierkorb der Session leeren?"), isPresented: emptyTrashPresented, titleVisibility: .visible) {
                Button(L("Leeren"), role: .destructive) {
                    if let summary = pendingEmptyTrash { model.emptyTrash(of: summary) }
                    pendingEmptyTrash = nil
                }
            } message: {
                Text(emptyTrashMessage)
            }
    }

    private var list: some View {
        List(selection: selection) {
            Section {
                ForEach(model.summaries) { summary in
                    SessionRow(summary: summary)
                        .tag(summary.directory)
                        .contextMenu { contextMenu(for: summary) }
                }
            } header: {
                header
            }
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

    private var deleteTitle: String {
        L("Session „\(pendingDelete?.displayName ?? "")“ in den Papierkorb legen?")
    }

    private var archiveTitle: String {
        L("Session „\(pendingArchive?.displayName ?? "")“ archivieren?")
    }

    private var archiveMessage: String {
        let size = bytes(pendingArchive?.imagesBytes ?? 0)
        return L("Die Seitenbilder (\(size)) wandern in den Papierkorb von macOS. Text und Exporte bleiben; Markdown, Word und EPUB gehen weiter, PDF nicht mehr.")
    }

    private var emptyTrashMessage: String {
        let count = pendingEmptyTrash?.trashedCount ?? 0
        let size = bytes(pendingEmptyTrash?.trashBytes ?? 0)
        return L("\(count) gelöschte Seiten, \(size), wandern in den Papierkorb von macOS.")
    }

    @ViewBuilder
    private func contextMenu(for summary: SessionSummary) -> some View {
        Button(L("Öffnen")) { model.openSession(at: summary.directory) }
        Button(L("Im Finder zeigen")) { model.revealSession(summary) }
        Divider()
        let trashSize = bytes(summary.trashBytes)
        Button(L("Papierkorb leeren (\(summary.trashedCount) Seiten, \(trashSize))")) {
            pendingEmptyTrash = summary
        }
        .disabled(summary.trashedCount == 0 && summary.trashBytes == 0)
        Button(L("Archivieren: Bilder entfernen, Text behalten…")) { pendingArchive = summary }
            .disabled(summary.archived || summary.pageCount == 0)
        Divider()
        Button(L("Session in den Papierkorb legen…"), role: .destructive) { pendingDelete = summary }
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
