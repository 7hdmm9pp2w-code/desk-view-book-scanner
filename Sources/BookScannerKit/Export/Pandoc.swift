import Foundation

/// Pandoc als externes Programm. Suchreihenfolge: mitgeliefert im App-Bundle,
/// Pfad aus den Einstellungen, Homebrew, /usr/local.
public struct Pandoc: Sendable {
    public static let defaultSearchPaths = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
    /// Relativ zum App-Bundle; das Build-Skript legt Pandoc dort ab.
    public static let bundledRelativePath = "Contents/Helpers/pandoc"

    public enum Format: String, CaseIterable, Sendable {
        case markdown, docx, epub

        public var pandocName: String {
            switch self {
            case .markdown: return "gfm"
            case .docx: return "docx"
            case .epub: return "epub3"
            }
        }

        public var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .docx: return "docx"
            case .epub: return "epub"
            }
        }
    }

    public let executable: URL
    public let isBundled: Bool

    public init(executable: URL, isBundled: Bool = false) {
        self.executable = executable
        self.isBundled = isBundled
    }

    /// Erstes ausführbares Pandoc entlang der Suchreihenfolge, sonst `nil`.
    public static func locate(preferredPath: String? = nil, bundle: Bundle = .main) -> Pandoc? {
        let fm = FileManager.default
        let bundled = bundle.bundleURL.appending(path: bundledRelativePath)
        if fm.isExecutableFile(atPath: bundled.path) {
            return Pandoc(executable: bundled, isBundled: true)
        }
        var paths: [String] = []
        if let preferredPath, !preferredPath.isEmpty { paths.append(preferredPath) }
        paths.append(contentsOf: defaultSearchPaths)
        for path in paths where fm.isExecutableFile(atPath: path) {
            return Pandoc(executable: URL(filePath: path))
        }
        return nil
    }

    public func version() -> String? {
        guard let output = try? run(arguments: ["--version"]) else { return nil }
        return output.split(separator: "\n").first.map(String.init)
    }

    /// `pandoc -f html -t <format> --wrap=none -o <output> <html>`
    public func convert(html: URL, to output: URL, format: Format, title: String?) throws {
        var arguments = ["-f", "html", "-t", format.pandocName, "--wrap=none", "-o", output.path]
        if let title, !title.isEmpty {
            arguments += ["--metadata", "title=\(title)"]
        }
        arguments.append(html.path)
        _ = try run(arguments: arguments)
    }

    @discardableResult
    func run(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ExportError.pandocFailed(error.localizedDescription)
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError.pandocFailed(message.isEmpty ? "Exit \(process.terminationStatus)" : message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

/// Markdown, DOCX, EPUB aus dem Blockmodell. Markdown geht auch ohne Pandoc.
public enum TextExporter {
    public static func export(_ document: StructuredDocument, to url: URL, format: Pandoc.Format, pandoc: Pandoc?) throws {
        guard let pandoc else {
            guard format == .markdown else { throw ExportError.pandocMissing }
            try MarkdownRenderer.render(document).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let html = HTMLRenderer.render(document, markers: format == .markdown ? .placeholders : .comments)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "Buchscan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let htmlURL = tempDirectory.appending(path: "export.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        if format == .markdown {
            let rawURL = tempDirectory.appending(path: "export.md")
            try pandoc.convert(html: htmlURL, to: rawURL, format: format, title: document.title)
            let raw = try String(contentsOf: rawURL, encoding: .utf8)
            try PageMarker.restore(in: raw).write(to: url, atomically: true, encoding: .utf8)
        } else {
            try pandoc.convert(html: htmlURL, to: url, format: format, title: document.title)
        }
    }
}
