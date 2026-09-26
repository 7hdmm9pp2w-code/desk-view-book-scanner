import SwiftUI
import BookScannerKit

struct PageGrid: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12)]

    private var emptyDescription: String {
        switch model.captureSource {
        case .iPhone: return L("Der Dokumentenscanner des iPhones liefert die Seiten, ausgelöst vom Mac. Quelle oben wechseln für Dateien oder Desk View.")
        case .files: return L("PDFs und Bilder aus Notizen, vFlat oder Fotos werden Seiten dieser Session.")
        case .deskView: return L("Desk View fotografiert das Buch von oben. Die Kameraauflösung reicht heute für Umschläge und Großdruck, nicht für Fließtext.")
        }
    }

    private var emptyButtonTitle: String {
        switch model.captureSource {
        case .iPhone: return L("Mit iPhone scannen")
        case .files: return L("Bilder oder PDF importieren…")
        case .deskView: return L("Seite erfassen")
        }
    }

    private var emptyButtonIcon: String {
        switch model.captureSource {
        case .iPhone: return "iphone.and.arrow.forward"
        case .files: return "square.and.arrow.down"
        case .deskView: return "camera.viewfinder"
        }
    }

    var body: some View {
        Group {
            if model.pages.isEmpty {
                ContentUnavailableView {
                    Label(L("Noch keine Seiten"), systemImage: "book.closed")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button {
                        model.performPrimaryAction()
                    } label: {
                        Label(emptyButtonTitle, systemImage: emptyButtonIcon)
                            .frame(width: 240)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.iPhoneWaiting || model.exportStatus != nil)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
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
                } else if model.sessionArchived {
                    Image(systemName: "doc.text").font(.system(size: 28)).foregroundStyle(.secondary)
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
