import Foundation

/// Keystrokes saved — the headline metric.
///
/// The whole app is judged on this number, so it is counted honestly: a Tab press
/// is a keystroke the user still had to make, and it is subtracted. Accepting a
/// two-character completion nets zero.
///
/// Phase 1 keeps this in memory and in UserDefaults; it moves into the SQLite
/// store alongside the feedback table in phase 2, where it also gains per-origin
/// attribution.
public final class SavingsCounter {
    private enum Key {
        static let total = "TypeAhead.savings.totalKeystrokes"
        static let accepted = "TypeAhead.savings.acceptedSuggestions"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public private(set) var sessionKeystrokesSaved = 0

    public var totalKeystrokesSaved: Int {
        defaults.integer(forKey: Key.total)
    }

    public var acceptedSuggestions: Int {
        defaults.integer(forKey: Key.accepted)
    }

    /// Records one acceptance. `insertedCharacters` is what actually landed in the
    /// document; the single Tab that triggered it is the cost.
    public func recordAcceptance(insertedCharacters: Int) {
        let net = max(0, insertedCharacters - 1)
        sessionKeystrokesSaved += net
        defaults.set(totalKeystrokesSaved + net, forKey: Key.total)
        defaults.set(acceptedSuggestions + 1, forKey: Key.accepted)
    }

    public func reset() {
        sessionKeystrokesSaved = 0
        defaults.removeObject(forKey: Key.total)
        defaults.removeObject(forKey: Key.accepted)
    }
}

/// Attaches to the signal bus rather than being called by the Coordinator, so the
/// metric can be swapped, disabled, or joined by other consumers without the
/// keystroke path knowing.
extension SavingsCounter: TypingObserver {
    public func observe(_ signal: TypingSignal) {
        guard case .suggestionAccepted(_, let characters) = signal else { return }
        recordAcceptance(insertedCharacters: characters)
    }
}
