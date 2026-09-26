import Foundation
import AppKit

/// Wörterbuch des Systems über `NSSpellChecker`. Der Checker ist nicht thread-sicher,
/// darum läuft die Abfrage immer auf dem Main-Thread.
public struct SpellCheckerWordChecker: WordChecker {
    public let language: String

    public init(language: String = "de") {
        self.language = language
    }

    public func isWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let language = self.language
        let check: () -> Bool = {
            let checker = NSSpellChecker.shared
            let range = checker.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            )
            return range.location == NSNotFound
        }
        if Thread.isMainThread {
            return check()
        }
        return DispatchQueue.main.sync(execute: check)
    }
}
