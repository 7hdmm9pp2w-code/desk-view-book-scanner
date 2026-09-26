import SwiftUI
import BookScannerKit

/// Hauptfenster: Statusleiste mit Aufnahme-Knopf oben, darunter Thumbnail-Raster
/// links und Detail mit Bild und (später) erkanntem Text rechts.
struct SessionWindow: View {
    @Environment(AppModel.self) private var model
    @State private var titleDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            HSplitView {
                PageGrid()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                PageDetail()
                    .frame(minWidth: 340, idealWidth: 460, maxWidth: 640, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
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
                Menu {
                    Button(L("Als PDF exportieren…")) { model.exportPDF() }
                    Button(L("Als Markdown exportieren…")) { model.exportText(format: .markdown) }
                    Button(L("Als Word (DOCX) exportieren…")) { model.exportText(format: .docx) }
                        .disabled(model.pandoc == nil)
                    Button(L("Als EPUB exportieren…")) { model.exportText(format: .epub) }
                        .disabled(model.pandoc == nil)
                } label: {
                    Label(L("Exportieren"), systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExport)
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

/// Zeile über dem Raster: Zustand von Desk View, Hinweise, großer Aufnahme-Knopf.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            statusView
            Spacer(minLength: 12)
            if let status = model.exportStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    switch status {
                    case .recognizing(let done, let total):
                        Text(L("Texterkennung \(done) von \(total)")).monospacedDigit()
                    case .writing(let done, let total):
                        Text(L("Export \(done) von \(total)")).monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
            } else if let suggestion = model.suggestedTitle, model.sessionTitle.isEmpty {
                HStack(spacing: 6) {
                    Text(L("Titelvorschlag vom Umschlag: „\(suggestion)“, ⏎ im Titelfeld übernimmt."))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L("Übernehmen")) { model.setTitle(suggestion); model.dismissSuggestedTitle() }
                        .controlSize(.small)
                }
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            captureButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .font(.system(size: 13))
        .background(.bar)
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .permissionMissing:
            HStack(spacing: 10) {
                Label(L("Bildschirmaufnahme nicht freigegeben"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Button(L("Freigabe erteilen…")) { model.requestPermission() }
                Text(L("Nach der Freigabe die App einmal beenden und neu starten."))
                    .foregroundStyle(.secondary)
            }
        case .notRunning:
            HStack(spacing: 10) {
                Label(L("Desk View läuft nicht"), systemImage: "camera.slash")
                    .foregroundStyle(.secondary)
                if model.isLaunchingDeskView {
                    ProgressView().controlSize(.small)
                    Text(L("Desk View wird gestartet, bitte Einrichtung abschließen…"))
                        .foregroundStyle(.secondary)
                } else {
                    Button(L("Desk View starten")) { model.launchDeskView() }
                }
            }
        case .found(let window):
            HStack(spacing: 10) {
                Label(L("Desk View gefunden"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(verbatim: "\(window.pixelWidth) × \(window.pixelHeight) px")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if window.isTooSmall {
                    Label(L("Fenster größer ziehen: unter 1600 px Breite reicht die Auflösung nicht."),
                          systemImage: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var captureButton: some View {
        HStack(spacing: 8) {
            Text(L("\(model.pages.count) Seiten"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                model.capturePage()
            } label: {
                Label(model.isCapturing ? L("Wird erfasst…") : L("Seite erfassen"), systemImage: "camera.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canCapture)
            .help(L("Tastenkürzel \(HotKey.captureDisplayName), auch wenn Desk View vorn liegt."))
        }
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
    @State private var text: PageText?

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
                HStack {
                    Text(L("Erkannter Text")).font(.headline)
                    Spacer()
                    if let text {
                        Text(L("\(text.lines.count) Zeilen")).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                ScrollView {
                    Text(text?.plainText ?? ocrText(for: page))
                        .foregroundStyle(text == nil ? .secondary : .primary)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
            .padding(12)
            .task(id: page.id) {
                image = nil
                text = nil
                image = await model.image(for: page, maxPixelSize: AppModel.detailImageSize)
                text = await model.text(for: page)
            }
            .onChange(of: model.texts[page.id]) { _, updated in
                if let updated { text = updated }
            }
        } else {
            ContentUnavailableView(L("Keine Seite ausgewählt"), systemImage: "doc.text.magnifyingglass")
        }
    }

    private func ocrText(for page: PageRecord) -> String {
        switch page.ocrStatus {
        case .pending: return L("Text wird erkannt…")
        case .failed: return L("Texterkennung fehlgeschlagen.")
        case .done: return L("Text wird geladen…")
        }
    }
}
