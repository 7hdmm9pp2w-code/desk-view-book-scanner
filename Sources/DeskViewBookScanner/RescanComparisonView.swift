import SwiftUI
import BookScannerKit

/// Alte und neue Fassung einer nachgescannten Seite nebeneinander. Die verworfene
/// wandert in den Papierkorb; vorgeschlagen ist die, in der mehr Text sicher erkannt wurde.
struct RescanComparisonView: View {
    @Environment(AppModel.self) private var model
    let comparison: AppModel.RescanComparison
    @State private var oldImage: CGImage?
    @State private var newImage: CGImage?

    /// Unter drei Prozent Unterschied gilt keiner als besser.
    private static let margin = 0.03

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Welcher Scan bleibt?")).font(.headline)
            HStack(alignment: .top, spacing: 10) {
                side(L("Bisher"), image: oldImage, texts: oldTexts, pageCount: 1, better: verdict == .old)
                side(L("Neu"), image: newImage, texts: newTexts, pageCount: comparison.newIDs.count, better: verdict == .new)
            }
            .frame(maxHeight: .infinity)
            HStack {
                keepButton(L("Bisherigen behalten"), keepNew: false)
                Spacer()
                keepButton(L("Neuen behalten"), keepNew: true)
            }
            Text(L("Der andere Scan wandert in den Papierkorb der Session."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .task(id: comparison) {
            oldImage = nil
            newImage = nil
            if let old = page(comparison.oldID) {
                oldImage = await model.image(for: old, maxPixelSize: AppModel.detailImageSize)
                _ = await model.text(for: old)
            }
            if let new = comparison.newIDs.first.flatMap(page) {
                newImage = await model.image(for: new, maxPixelSize: AppModel.detailImageSize)
            }
        }
    }

    private enum Verdict { case old, new, undecided }

    private var oldTexts: [PageText]? { texts(for: [comparison.oldID]) }
    private var newTexts: [PageText]? { texts(for: comparison.newIDs) }

    private var verdict: Verdict {
        guard let oldTexts, let newTexts else { return .undecided }
        let old = oldTexts.reduce(0) { $0 + $1.confidentCharacters }
        let new = newTexts.reduce(0) { $0 + $1.confidentCharacters }
        if new > old * (1 + Self.margin) { return .new }
        if old > new * (1 + Self.margin) { return .old }
        return .undecided
    }

    /// `nil`, solange eine der Seiten noch keinen Text hat.
    private func texts(for ids: [UUID]) -> [PageText]? {
        let found = ids.compactMap { model.texts[$0] }
        return found.count == ids.count ? found : nil
    }

    private func page(_ id: UUID) -> PageRecord? {
        model.pages.first { $0.id == id }
    }

    private func side(_ title: String, image: CGImage?, texts: [PageText]?, pageCount: Int, better: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if pageCount > 1 {
                    Text(L("\(pageCount) Seiten")).foregroundStyle(.secondary)
                }
                Spacer()
                if better {
                    Label(L("Besser erkannt"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption.weight(.medium))
                }
            }
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
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(better ? Color.green : Color.clear, lineWidth: 2)
            }
            Group {
                if let texts {
                    let characters = texts.reduce(0) { $0 + $1.characterCount }
                    let confident = texts.reduce(0) { $0 + $1.confidentCharacters }
                    let share = characters > 0 ? confident / Double(characters) : 0
                    Text(L("\(characters) Zeichen, davon \(share.formatted(.percent.precision(.fractionLength(0)))) sicher"))
                } else {
                    Text(L("Text wird erkannt…"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    /// Der vorgeschlagene Knopf reagiert auf ⏎; ohne Urteil ist es der neue Scan.
    @ViewBuilder
    private func keepButton(_ title: String, keepNew: Bool) -> some View {
        let isDefault = keepNew ? verdict != .old : verdict == .old
        if isDefault {
            Button(title) { model.resolveRescan(keepNew: keepNew) }
                .keyboardShortcut(.defaultAction)
        } else {
            Button(title) { model.resolveRescan(keepNew: keepNew) }
        }
    }
}
