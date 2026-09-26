import Foundation

/// HTML aus dem Blockmodell. Seitenwechsel als Marker-Absatz, weil Pandoc
/// HTML-Kommentare verschluckt; `PageMarker.restore` macht daraus Kommentare.
public enum HTMLRenderer {
    /// Wie Seitenmarker und Notizen ins HTML kommen: als Platzhalter-Absätze, die
    /// `PageMarker.restore` nach Pandoc zu Kommentaren macht (Markdown-Weg), oder als
    /// HTML-Kommentare, die Pandoc still verschluckt (DOCX, EPUB).
    public enum MarkerStyle: Sendable { case placeholders, comments }

    public static func render(_ document: StructuredDocument, language: String = "de", markers: MarkerStyle = .placeholders) -> String {
        var out = "<!DOCTYPE html>\n<html lang=\"\(language)\">\n<head>\n<meta charset=\"utf-8\">\n"
        if let title = document.title {
            out += "<title>\(escape(title))</title>\n"
        }
        out += "</head>\n<body>\n"
        if let title = document.title {
            out += "<h1>\(escape(title))</h1>\n"
        }
        var inList = false
        func closeList() {
            if inList { out += "</ul>\n"; inList = false }
        }
        for block in document.blocks {
            if case .listItem = block {} else { closeList() }
            switch block {
            case .pageBreak(let number, let printed):
                switch markers {
                case .placeholders: out += "<p>\(PageMarker.marker(for: number, printed: printed))</p>\n"
                case .comments: out += "\(PageMarker.comment(for: number, printed: printed))\n"
                }
            case .heading(let level, let text):
                let tag = "h\(min(level + 1, 6))"
                out += "<\(tag)>\(escape(text))</\(tag)>\n"
            case .paragraph(let text):
                out += "<p>\(escape(text))</p>\n"
            case .listItem(let text):
                if !inList { out += "<ul>\n"; inList = true }
                out += "<li>\(escape(text))</li>\n"
            case .footnote(let text):
                out += "<blockquote><p>\(escape(text))</p></blockquote>\n"
            case .note(let text):
                switch markers {
                case .placeholders: out += "<p>\(PageMarker.noteMarker(text))</p>\n"
                case .comments: out += "<!-- \(escape(text).replacingOccurrences(of: "--", with: "- -")) -->\n"
                }
            }
        }
        closeList()
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
        var listBuffer: [String] = []
        func flushList() {
            if !listBuffer.isEmpty {
                parts.append(listBuffer.map { "- \($0)" }.joined(separator: "\n"))
                listBuffer = []
            }
        }
        for block in document.blocks {
            if case .listItem = block {} else { flushList() }
            switch block {
            case .pageBreak(let number, let printed):
                parts.append(PageMarker.comment(for: number, printed: printed))
            case .heading(let level, let text):
                parts.append(String(repeating: "#", count: min(level + 1, 6)) + " " + text)
            case .paragraph(let text):
                parts.append(text)
            case .listItem(let text):
                listBuffer.append(text)
            case .footnote(let text):
                parts.append("> " + text)
            case .note(let text):
                parts.append("<!-- \(text) -->")
            }
        }
        flushList()
        return parts.joined(separator: "\n\n") + "\n"
    }
}

public enum PageMarker {
    static let prefix = "@@SEITE "
    static let suffix = "@@"
    static let notePrefix = "@@NOTIZ "

    public static func marker(for number: Int, printed: String? = nil) -> String {
        if let printed, !printed.isEmpty { return "\(prefix)\(number) S\(printed)\(suffix)" }
        return "\(prefix)\(number)\(suffix)"
    }

    public static func comment(for number: Int, printed: String? = nil) -> String {
        if let printed, !printed.isEmpty { return "<!-- Seite \(printed), Scan \(number) -->" }
        return "<!-- Seite \(number) -->"
    }

    static func noteMarker(_ text: String) -> String {
        "\(notePrefix)\(HTMLRenderer.escape(text))\(suffix)"
    }

    /// Ersetzt Marker in Pandoc-Ausgabe durch Kommentare.
    public static func restore(in text: String) -> String {
        var result = text
        if let pages = try? NSRegularExpression(pattern: "\\\\?@@SEITE (\\d+)(?: S(\\S+?))?@@") {
            let matches = pages.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result), let numberRange = Range(match.range(at: 1), in: result),
                      let number = Int(result[numberRange]) else { continue }
                let printed = Range(match.range(at: 2), in: result).map { String(result[$0]) }
                result.replaceSubrange(whole, with: comment(for: number, printed: printed))
            }
        }
        if let notes = try? NSRegularExpression(pattern: "\\\\?@@NOTIZ (.+?)@@") {
            let range = NSRange(result.startIndex..., in: result)
            result = notes.stringByReplacingMatches(in: result, range: range, withTemplate: "<!-- $1 -->")
        }
        return result
    }
}
