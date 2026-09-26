import Foundation

/// HTML aus dem Blockmodell. Seitenwechsel als Marker-Absatz, weil Pandoc
/// HTML-Kommentare verschluckt; `PageMarker.restore` macht daraus Kommentare.
public enum HTMLRenderer {
    public static func render(_ document: StructuredDocument, language: String = "de") -> String {
        var out = "<!DOCTYPE html>\n<html lang=\"\(language)\">\n<head>\n<meta charset=\"utf-8\">\n"
        if let title = document.title {
            out += "<title>\(escape(title))</title>\n"
        }
        out += "</head>\n<body>\n"
        if let title = document.title {
            out += "<h1>\(escape(title))</h1>\n"
        }
        for block in document.blocks {
            switch block {
            case .pageBreak(let number):
                out += "<p>\(PageMarker.marker(for: number))</p>\n"
            case .heading(let level, let text):
                let tag = "h\(min(level + 1, 6))"
                out += "<\(tag)>\(escape(text))</\(tag)>\n"
            case .paragraph(let text):
                out += "<p>\(escape(text))</p>\n"
            }
        }
        out += "</body>\n</html>\n"
        return out
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Markdown direkt aus dem Blockmodell; der Weg ohne Pandoc.
public enum MarkdownRenderer {
    public static func render(_ document: StructuredDocument) -> String {
        var parts: [String] = []
        if let title = document.title {
            parts.append("# \(title)")
        }
        for block in document.blocks {
            switch block {
            case .pageBreak(let number):
                parts.append(PageMarker.comment(for: number))
            case .heading(let level, let text):
                parts.append(String(repeating: "#", count: min(level + 1, 6)) + " " + text)
            case .paragraph(let text):
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

public enum PageMarker {
    static let prefix = "@@SEITE "
    static let suffix = "@@"

    public static func marker(for number: Int) -> String { "\(prefix)\(number)\(suffix)" }
    public static func comment(for number: Int) -> String { "<!-- Seite \(number) -->" }

    /// Ersetzt Marker in Pandoc-Ausgabe durch Kommentare.
    public static func restore(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\\\?@@SEITE (\\d+)@@") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<!-- Seite $1 -->")
    }
}
