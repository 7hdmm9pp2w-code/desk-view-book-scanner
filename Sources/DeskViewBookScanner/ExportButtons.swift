import SwiftUI
import BookScannerKit

/// Vier beschriftete Export-Knöpfe statt eines Menüs: man sieht, was man bekommt.
struct ExportButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ControlGroup {
            Button {
                model.exportPDF()
            } label: {
                Label("PDF", systemImage: "doc.richtext")
            }
            .help(model.sessionArchived ? L("Archivierte Session: die Bilder für das PDF sind entfernt.") : L("PDF mit den Seitenbildern und durchsuchbarer Textebene (⌘E)"))
            .disabled(model.sessionArchived)
            Button {
                model.exportText(format: .markdown)
            } label: {
                Label("Markdown", systemImage: "text.alignleft")
            }
            .help(pandocHelp(L("Markdown mit Absätzen, Überschriften und Seitenmarkern (⇧⌘E)")))
            Button {
                model.exportText(format: .docx)
            } label: {
                Label("Word", systemImage: "doc.text")
            }
            .help(pandocHelp(L("Word-Dokument (DOCX) mit Absätzen und Überschriften")))
            .disabled(model.pandoc == nil)
            Button {
                model.exportText(format: .epub)
            } label: {
                Label("EPUB", systemImage: "book")
            }
            .help(pandocHelp(L("E-Book (EPUB) für Bücher-App und Reader")))
            .disabled(model.pandoc == nil)
        } label: {
            Label(L("Exportieren"), systemImage: "square.and.arrow.up")
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.titleAndIcon)
        .disabled(!model.canExport)
    }

    private func pandocHelp(_ text: String) -> String {
        model.pandoc == nil ? text + " " + L("(braucht Pandoc, siehe Einstellungen)") : text
    }
}
