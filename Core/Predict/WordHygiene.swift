import AppKit
import Foundation

/// Decides whether a word is worth learning.
///
/// Without this the store fills with typos and fragments — "anhting", "workig",
/// "kjddithistyp" — and then offers them back, which is worse than offering
/// nothing. But a plain dictionary filter is the wrong fix: it would throw away
/// every name, every piece of jargon, and all Hinglish, which is most of what
/// makes the app worth having.
///
/// **Frequency is what separates a typo from a word.** A typo happens once. A
/// name, a repo, "chaudhary" happen constantly. So an unrecognised word is not
/// rejected — it is held back until it proves itself by recurring, then admitted
/// permanently.
///
/// The dictionary is only ever a *positive* signal, never a veto, because it is
/// untrustworthy in both directions: on this machine it runs as `en_IN` and
/// happily accepts "nahi" and "bhai" (useful) along with "teh" and every
/// two-letter fragment (not). Real typos it waves through are caught by
/// `Corrector` instead, which learns them from your own backspaces.
public final class WordHygiene {
    /// Sightings before an unrecognised word is treated as real. Higher than the
    /// bar for dictionary words, because the evidence has to carry more weight.
    public static let unknownWordThreshold = 4

    /// Anything shorter is a fragment unless the dictionary knows it. Catches the
    /// debris left by dropped keystrokes and mid-word interruptions.
    private static let shortWordLimit = 3

    public enum Verdict: String {
        /// The dictionary knows it. Learn and offer it normally.
        case known = "word"
        /// Unrecognised and not yet frequent. Count it, never offer it.
        case unverified
        /// Unrecognised but frequent — a name, jargon, or another language.
        case term
    }

    private var cache: [String: Bool] = [:]
    private let lock = NSLock()

    public init() {}

    /// Whether the system dictionary recognises this word.
    ///
    /// Cached: spell checking is far too slow to run on every keystroke, and the
    /// answer for a given word never changes within a session.
    public func isSpelledCorrectly(_ word: String) -> Bool {
        lock.lock()
        if let cached = cache[word] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0)
        let correct = range.location == NSNotFound

        lock.lock()
        cache[word] = correct
        lock.unlock()
        return correct
    }

    /// Classifies a word given how often it has now been seen.
    public func verdict(for word: String, seenCount: Int) -> Verdict {
        // Length first, unconditionally. The system checker accepts "yi", "ot",
        // "f" and "d" as words, so asking it about fragments lets every scrap of
        // keystroke debris through. Nothing this short is worth suggesting anyway:
        // finishing it could never beat the Tab that takes it.
        guard word.count >= WordHygiene.shortWordLimit else { return .unverified }

        if isSpelledCorrectly(word) {
            return .known
        }
        return seenCount >= WordHygiene.unknownWordThreshold ? .term : .unverified
    }

    /// Whether a word may ever be offered as a suggestion.
    ///
    /// Deliberately stricter than the rule for learning: counting something costs
    /// nothing and might later prove it real, but suggesting a typo actively
    /// wastes the user's attention and teaches them to distrust the ghost text.
    public static func isOfferable(kind: String, count: Int) -> Bool {
        switch kind {
        case Verdict.known.rawValue: return count >= 2
        case Verdict.term.rawValue: return count >= unknownWordThreshold
        default: return false
        }
    }
}
