import SwiftUI
import UniformTypeIdentifiers
import BookScannerKit

/// Anleitung „Buch mit dem iPhone filmen": vom Aufbau bis zum Import. Über Continuity
/// Camera gibt das iPhone nur 1920 × 1440 heraus, in der eigenen Kamera-App filmt es 4K;
/// das Video liest die App danach wie der Auto-Auslöser Seite für Seite.
struct VideoGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Buch mit dem iPhone filmen"))
                    .font(.title2.weight(.semibold))
                Text(L("Das iPhone filmt in 4K, doppelt so scharf wie als Webcam. Die App findet danach im Video jede neue Seite."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, icon: "iphone.rear.camera", title: L("iPhone über das Buch"),
                 text: L("In eine Halterung oder ein Stativ, die Kamera senkrecht nach unten. Die Doppelseite soll das Bild quer ausfüllen. Gleichmäßiges Licht, kein Schatten vom iPhone auf dem Buch."))
            step(2, icon: "4k.tv", title: L("4K einstellen"),
                 text: L("Kamera-App, Modus Video, oben rechts 4K und 24 oder 30 fps wählen. Lange auf das Buch tippen sperrt Schärfe und Belichtung."))
            step(3, icon: "book.pages", title: L("Filmen und umblättern"),
                 text: L("Jede Seite etwa zwei Sekunden ruhig zeigen, dann zügig umblättern. Hände am Rand stören nicht. Nach der letzten Seite eine Sekunde weiterfilmen."))
            step(4, icon: "airplayaudio", title: L("Video an den Mac"),
                 text: L("Per AirDrop, es landet im Ordner Downloads. 200 Seiten sind rund 7 Minuten und 1 GB; nach dem Import kann das Video weg."))

            dropZone

            HStack {
                Text(L("Fehlt eine Seite, mit ⇧⌘R nachscannen; die Prüfung der Seitenzahlen zeigt Lücken."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(L("Schließen")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Video importieren…")) {
                    dismiss()
                    model.importVideoFromGuide()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.exportStatus != nil || model.sessionArchived)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ number: Int, icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(number). \(title)").font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Ein Video aus dem Finder hierher ziehen statt es im Dialog zu suchen.
    private var dropZone: some View {
        Label(L("Oder das Video hierher ziehen"), systemImage: "film")
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            }
            .dropDestination(for: URL.self) { urls, _ in
                let videos = urls.filter(VideoPageExtractor.isSupported)
                guard !videos.isEmpty, model.exportStatus == nil, !model.sessionArchived else { return false }
                dismiss()
                model.importFiles(videos)
                return true
            } isTargeted: { dropTargeted = $0 }
    }
}
