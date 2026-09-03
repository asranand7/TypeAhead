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
    /// A word boundary was crossed; `word` is the token just completed and
    /// `boundary` classifies the separator that ended it.
    case wordCommitted(word: String, boundary: TextBoundary, appBundleID: String?)
    /// A sentence- or paragraph-ending separator was typed with no word pending,
    /// because the word before it was already closed by a weaker separator.
    ///
    /// "Hi John,\n\n" is the case that makes this necessary, and it is the most
    /// common opening in written English: the comma closes "John", so the two
    /// newlines arrive with nothing to attach to and the paragraph break would
    /// otherwise be invisible. Only ever emitted for boundaries that end a
    /// sentence — a trailing space carries no information worth a signal.
    case boundaryCrossed(TextBoundary)
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

/// What kind of separator ended a word.
///
/// The single most consequential thing the app was throwing away. `accumulate`
/// used to see the character that ended a token and discard it, so a space, a
/// comma, a full stop and a Return were the same event — "word over". Nothing
/// downstream could tell a clause break from a sentence end, which is why
/// snippets were mined straight through paragraph boundaries and the n-gram
/// recorded bigrams across full stops.
///
/// Classified from the *first* separator character rather than the whole run.
/// That is deliberate: waiting for the run to finish would delay every commit by
/// a keystroke, and the first character already carries the distinction that
/// matters. The exact run ("." versus ". " versus ".  ") is not worth knowing —
/// `separatorText` canonicalises it on the way back out, which also folds
/// "Thanks ,Anand" and "Thanks, Anand" into one snippet instead of two.
public enum TextBoundary: String, Sendable, Codable, Equatable {
    /// No separator was seen: the word was flushed by a caret move or a focus
    /// change, so what follows it is unknown.
    case none
    /// Space or tab. The clause continues.
    case space
    /// Comma, semicolon, colon, dash. A break inside a sentence.
    case clause
    /// Full stop, question mark, exclamation mark. The sentence ends.
    case sentence
    /// Newline or carriage return. The paragraph ends.
    ///
    /// Carriage return matters as much as newline: the Accessibility API reports
    /// "\n" but the Return key delivers "\r", so a rule written for one alone is
    /// blind in exactly the apps that fall back to the shadow buffer.
    case paragraph
    /// Brackets, quotes, slashes, anything else. Structural rather than prose;
    /// treated as a plain gap.
    case other

    public init(separator: Character) {
        switch separator {
        case " ", "\t":                 self = .space
        case ",", ";", ":", "\u{2014}", "\u{2013}": self = .clause
        case ".", "!", "?", "\u{2026}": self = .sentence
        case "\n", "\r", "\u{2028}", "\u{2029}": self = .paragraph
        default:                        self = .other
        }
    }

    /// How much of a break this is, for picking a winner within a run of
    /// separators. A full stop followed by two newlines is one paragraph break,
    /// not a sentence break followed by two paragraph breaks, so a run collapses
    /// to its strongest member.
    public var rank: Int {
        switch self {
        case .none:      return 0
        case .space:     return 1
        case .other:     return 2
        case .clause:    return 3
        case .sentence:  return 4
        case .paragraph: return 5
        }
    }

    /// The stronger of two boundaries seen in the same separator run.
    public static func strongest(_ a: TextBoundary, _ b: TextBoundary) -> TextBoundary {
        a.rank >= b.rank ? a : b
    }

    /// Whether this boundary ends the sentence the words before it belonged to.
    ///
    /// The test every consumer actually wants: it is what decides whether an
    /// n-gram window is still valid and whether two words were ever adjacent in
    /// the same phrase.
    public var endsSentence: Bool {
        self == .sentence || self == .paragraph
    }

    /// The canonical text this boundary renders as when a phrase is rebuilt.
    ///
    /// Canonical, not verbatim, so that every way of typing the same break
    /// produces the same stored phrase. `.none` renders as nothing at all: the
    /// word was flushed without a separator, so inventing one would put a space
    /// into a phrase the user never separated.
    public var separatorText: String {
        switch self {
        case .none:      return ""
        case .space:     return " "
        case .clause:    return ", "
        case .sentence:  return ". "
        case .paragraph: return "\n"
        case .other:     return " "
        }
    }
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
