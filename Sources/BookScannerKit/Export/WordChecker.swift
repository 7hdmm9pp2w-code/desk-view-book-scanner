import Foundation

/// Entscheidet, ob eine Zeichenkette ein Wort ist. Für die Silbentrennung.
public protocol WordChecker: Sendable {
    func isWord(_ word: String) -> Bool
    /// `false`, wenn gar kein Wörterbuch dahintersteht; dann bleiben Bindestriche stehen.
    var hasDictionary: Bool { get }
}

extension WordChecker {
    public var hasDictionary: Bool { true }
}

/// Kennt kein Wort; Bindestriche bleiben stehen.
public struct NoWordChecker: WordChecker {
    public init() {}
    public func isWord(_ word: String) -> Bool { false }
    public var hasDictionary: Bool { false }
}

/// Feste Wortliste, für Tests und Werkzeuge ohne AppKit.
public struct SetWordChecker: WordChecker {
    public let words: Set<String>
    public init(_ words: Set<String>) { self.words = words }
    public func isWord(_ word: String) -> Bool { words.contains(word) }
}

extension WordChecker {
    /// Wörterbuchabfrage unabhängig von Groß- und Kleinschreibung: „REICHES" → „Reiches".
    func knows(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        if isWord(word) { return true }
        let lower = word.lowercased()
        if lower != word, isWord(lower) { return true }
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        return capitalized != word && isWord(capitalized)
    }
}
