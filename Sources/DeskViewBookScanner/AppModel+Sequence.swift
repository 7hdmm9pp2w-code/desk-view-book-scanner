import AppKit
import BookScannerKit

// MARK: - Seitenfolge

extension AppModel {
    /// Seitenzahlen neu lesen und ihre Folge prüfen. Taucht an der eben erfassten Seite
    /// ein neuer Hinweis auf, gibt es bei der Kamera einen Ton: Man blickt aufs Buch.
    func refreshPageSequence() {
        var numbers: [UUID: ClosedRange<Int>] = [:]
        for page in pages {
            if let text = texts[page.id], let range = PageSequence.printedNumbers(in: text) {
                numbers[page.id] = range
            }
        }
        let byIndex = PageSequence.check(pages.map { numbers[$0.id] })
        var issues: [UUID: PageSequenceIssue] = [:]
        for (index, issue) in byIndex { issues[pages[index].id] = issue }

        // Nur für frische Aufnahmen, nicht beim Öffnen einer alten Session.
        if captureSource == .camera, let lastPage = pages.last, lastPage.capturedAt.timeIntervalSinceNow > -120,
           let issue = issues[lastPage.id], sequenceIssues[lastPage.id] != issue {
            NSSound(named: "Basso")?.play()
        }
        if numbers != printedNumbers { printedNumbers = numbers }
        if issues != sequenceIssues { sequenceIssues = issues }
    }

    /// Der Hinweis an der hintersten Seite, für die Leiste.
    var latestSequenceIssue: (page: PageRecord, issue: PageSequenceIssue)? {
        for page in pages.reversed() {
            if let issue = sequenceIssues[page.id] { return (page, issue) }
        }
        return nil
    }

    static func describe(_ issue: PageSequenceIssue) -> String {
        switch issue {
        case .missing(let from, let to) where from == to:
            return L("Seite \(String(from)) fehlt vermutlich")
        case .missing(let from, let to):
            return L("Seiten \(String(from))–\(String(to)) fehlen vermutlich")
        case .duplicate(let scan):
            return L("Doppelt: dieselbe Seitenzahl wie Seite \(scan)")
        case .outOfOrder(let previous):
            return L("Seitenzahl kleiner als davor (\(String(previous)))")
        }
    }

    static func describe(_ range: ClosedRange<Int>) -> String {
        range.count == 1 ? L("S. \(String(range.lowerBound))") : L("S. \(String(range.lowerBound))–\(String(range.upperBound))")
    }
}
