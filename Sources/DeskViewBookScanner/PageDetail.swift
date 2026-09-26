import SwiftUI
import BookScannerKit

struct PageDetail: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?
    @State private var text: PageText?

    private var page: PageRecord? {
        model.pages.first { $0.id == model.selectedPageID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.captureSource == .camera, model.cameraRunning {
                CameraPreview(session: model.camera.captureSession)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(12)
                Divider()
            }
            pageContent
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let page {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if model.sessionArchived {
                        Label(L("Bild archiviert"), systemImage: "archivebox").foregroundStyle(.secondary)
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
