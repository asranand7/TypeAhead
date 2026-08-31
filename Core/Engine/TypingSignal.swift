import Foundation

/// Everything interesting that happens while the user types, as a stream of facts.
///
/// This is the app's main extension point. The Coordinator emits signals and knows
/// nothing about who consumes them; the learning store (phase 2), the correction
/// learner (phase 5) and the savings metric all attach here without the wiring
/// growing a branch for each. Adding a consumer means conforming to
/// `TypingObserver` and registering it — never editing the Coordinator.
public enum TypingSignal: Sendable {
    /// A printable character the user typed themselves.
    case typed(String)
    /// A word boundary was crossed; `word` is the token just completed.
    case wordCommitted(word: String, appBundleID: String?)
    /// The user deleted backwards. Feeds correction-pair learning in phase 5.
    case backspaced
    /// The caret moved somewhere we did not put it: click, arrow key, app switch.
    case caretMoved
    /// A suggestion was put on screen.
    case suggestionShown(Candidate)
    /// A suggestion was accepted. `characters` is what actually landed.
    case suggestionAccepted(Candidate, characters: Int)
    /// A suggestion was on screen and the user typed past or dismissed it.
    case suggestionRejected(Candidate)
}

/// Consumes typing signals. Implementations must be cheap: they are called from
/// the keystroke path, and slow work here is felt as input lag.
public protocol TypingObserver: AnyObject {
    func observe(_ signal: TypingSignal)
}

/// Fans one signal out to many observers, so the Coordinator holds exactly one
/// reference regardless of how many subsystems are listening.
public final class TypingSignalBus: TypingObserver {
    private var observers: [TypingObserver] = []

    public init() {}

    public func add(_ observer: TypingObserver) {
        observers.append(observer)
    }

    public func observe(_ signal: TypingSignal) {
        for observer in observers {
            observer.observe(signal)
        }
    }
}
