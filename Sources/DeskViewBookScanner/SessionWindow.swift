import SwiftUI
import BookScannerKit

/// Thumbnail-Raster links, Detail mit Bild und (später) erkanntem Text rechts.
struct SessionWindow: View {
    @Environment(AppModel.self) private var model
    @State private var titleDraft = ""

    var body: some View {
        HSplitView {
            PageGrid()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            PageDetail()
                .frame(minWidth: 340, idealWidth: 460, maxWidth: 640, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(windowTitle)
        .navigationSubtitle(model.sessionDirectory?.lastPathComponent ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                TextField(L("Titel"), text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { model.setTitle(titleDraft) }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.capturePage()
                } label: {
                    Label(L("Seite erfassen"), systemImage: "camera.viewfinder")
                }
                .disabled(!model.canCapture)
                Button {
                    model.trashSelectedPage()
                } label: {
                    Label(L("Seite löschen"), systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
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
    }

    private var windowTitle: String {
        if !model.sessionTitle.isEmpty { return model.sessionTitle }
        return model.sessionDirectory?.lastPathComponent ?? L("Session")
    }
}

struct PageGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12)]

    var body: some View {
        Group {
            if model.pages.isEmpty {
                ContentUnavailableView(
                    L("Noch keine Seiten"),
                    systemImage: "book.closed",
                    description: Text(L("⌥⌘S erfasst das Desk-View-Fenster als Seite."))
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(page: page, number: index + 1, isSelected: model.selectedPageID == page.id)
                                .onTapGesture { model.selectedPageID = page.id }
                                .draggable(page.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let dragged = items.first.flatMap(UUID.init(uuidString:)), dragged != page.id else {
                                        return false
                                    }
                                    model.move(pageID: dragged, before: page.id)
                                    return true
                                }
                        }
                    }
                    .padding(12)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.move(pageID: dragged, before: nil)
                    return true
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { model.trashSelectedPage() }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct PageCell: View {
    @Environment(AppModel.self) private var model
    let page: PageRecord
    let number: Int
    let isSelected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(CGFloat(page.pixelWidth) / CGFloat(max(page.pixelHeight, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            Text(verbatim: "\(number)")
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityLabel(L("Seite \(number)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: page.id) {
            thumbnail = await model.image(for: page, maxPixelSize: AppModel.cellThumbnailSize)
        }
    }
}

struct PageDetail: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?

    private var page: PageRecord? {
        model.pages.first { $0.id == model.selectedPageID }
    }

    var body: some View {
        if let page {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text(L("Aufgenommen")).foregroundStyle(.secondary)
                        Text(page.capturedAt, format: .dateTime.day().month().year().hour().minute().second())
                    }
                    GridRow {
                        Text(L("Größe")).foregroundStyle(.secondary)
                        Text(verbatim: "\(page.pixelWidth) × \(page.pixelHeight) px")
                    }
                    GridRow {
                        Text(L("Datei")).foregroundStyle(.secondary)
                        Text(page.fileName).textSelection(.enabled)
                    }
                }
                .font(.system(size: 13))
                .monospacedDigit()

                Divider()
                Text(L("Erkannter Text")).font(.headline)
                ScrollView {
                    Text(ocrText(for: page))
                        .foregroundStyle(page.ocrStatus == .done ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
            .padding(12)
            .task(id: page.id) {
                image = nil
                image = await model.image(for: page, maxPixelSize: AppModel.detailImageSize)
            }
        } else {
            ContentUnavailableView(L("Keine Seite ausgewählt"), systemImage: "doc.text.magnifyingglass")
        }
    }

    private func ocrText(for page: PageRecord) -> String {
        switch page.ocrStatus {
        case .pending: return L("Noch kein Text erkannt. Die Texterkennung kommt mit dem PDF-Export.")
        case .failed: return L("Texterkennung fehlgeschlagen.")
        case .done: return L("Text liegt vor, Anzeige folgt mit dem PDF-Export.")
        }
    }
}
