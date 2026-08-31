import Foundation

/// What the user has typed, as far as we can see it.
public struct TypingContext: Sendable, Equatable {
    /// Text immediately before the caret (capped; see ContextReader.maxContextChars).
    public let textBeforeCaret: String
    /// The partial word straddling the caret. Empty when the caret sits after a separator.
    public let currentWordPrefix: String
    /// Text immediately *after* the caret, capped the same way.
    ///
    /// Without this the app cannot tell "at the end of a half-typed word" from
    /// "in the middle of a finished one" — they look identical from before the
    /// caret. Completing into the second case corrupts the word: with the caret
    /// inside `recei|ving`, a completion of "ved" yields "receivedving".
    ///
    /// Empty when the context came from the shadow buffer, which is a log of
    /// keystrokes and so knows nothing about what lies ahead of the caret.
    public let textAfterCaret: String

    /// The remainder of the word the caret is sitting inside, empty at a word
    /// boundary. This is the part a completion has to reconcile itself with.
    public var currentWordSuffix: String {
        ContextReader.leadingWord(of: textAfterCaret)
    }
    /// Bundle id of the frontmost app, used as the per-app context dimension.
    public let appBundleID: String?
    /// True when the context came from the Accessibility API rather than the
    /// shadow keystroke buffer. Callers use it to decide how much to trust the text.
    public let isAuthoritative: Bool

    public init(textBeforeCaret: String,
                currentWordPrefix: String,
                appBundleID: String?,
                isAuthoritative: Bool,
                textAfterCaret: String = "") {
        self.textBeforeCaret = textBeforeCaret
        self.currentWordPrefix = currentWordPrefix
        self.appBundleID = appBundleID
        self.isAuthoritative = isAuthoritative
        self.textAfterCaret = textAfterCaret
    }
}

/// Where a candidate came from. Kept on the candidate so the ranker can apply
/// per-origin priors and so the savings metric can attribute credit per tier.
public enum CandidateOrigin: String, Sendable, Codable {
    case prefixTrie
    case ngram
    case snippet
    case identity
    case correction
    /// The system's own dictionary — general English, available from the first
    /// keystroke, deliberately outranked by anything personal.
    case lexicon
    case model
    case stub
}

/// One possible continuation.
///
/// `text` is the whole thing the candidate would insert; `firstWord` is the
/// word-sized bite that a single Tab takes. The two-stage Tab in the plan is
/// exactly "insert firstWord, then insert the rest of text".
public struct Candidate: Sendable, Equatable {
    public let text: String
    public let probability: Double
    public let origin: CandidateOrigin

    /// Characters before the caret this candidate replaces. Zero for ordinary
    /// completions, which only append.
    ///
    /// Corrections need it: fixing "recieve" means deleting what was typed, not
    /// adding to it. Rule 1 still holds — the deletion happens only inside the Tab
    /// handler, so the app still never touches your text unless you press Tab.
    public let replacesPreviousCharacters: Int

    public init(text: String,
                probability: Double,
                origin: CandidateOrigin,
                replacesPreviousCharacters: Int = 0,
                granularity: Granularity? = nil) {
        self.text = text
        self.probability = probability
        self.origin = origin
        self.replacesPreviousCharacters = replacesPreviousCharacters
        self.granularity = granularity ?? Candidate.defaultGranularity(for: origin)
    }

    /// Verbatim tiers are atomic; everything statistical or generative is taken a
    /// word at a time. A correction is atomic because it is a single edit — half
    /// a correction leaves the document worse than not correcting at all.
    public static func defaultGranularity(for origin: CandidateOrigin) -> Granularity {
        switch origin {
        case .identity, .correction: return .atomic
        case .prefixTrie, .ngram, .snippet, .lexicon, .model, .stub: return .wordwise
        }
    }

    /// How much of `text` a single Tab takes.
    ///
    /// A property of the candidate rather than a global rule, because the right
    /// answer depends on what kind of evidence produced it. A statistical guess
    /// is worth offering one word at a time — chaining an n-gram's predictions
    /// multiplies its error, and the second word is much less trustworthy than
    /// the first. A verbatim recall has no such decay: an email address seen
    /// three times is not four separate guesses, and making someone press Tab
    /// once per token of their own address would be absurd.
    ///
    /// Previously this was inferred by testing `text` for a space, which gave the
    /// right answer for an email only by accident — and the wrong one for any
    /// atomic fact containing one, such as a postal address.
    public enum Granularity: Sendable, Equatable {
        /// One Tab takes the whole thing. Verbatim recall: identity, corrections.
        case atomic
        /// One Tab takes one word, repeatably. Statistical or generative text.
        case wordwise
    }

    public let granularity: Granularity

    /// The successive bites a Tab takes, in order.
    ///
    /// Each keeps its trailing space, so accepting one leaves the caret ready for
    /// the next and the concatenation is exactly `text`.
    public var acceptanceUnits: [String] {
        guard granularity == .wordwise else { return [text] }
        var units: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " {
                units.append(current)
                current = ""
            }
        }
        if !current.isEmpty { units.append(current) }
        return units.isEmpty ? [text] : units
    }

    /// The first bite a Tab takes.
    public var firstWord: String { acceptanceUnits.first ?? text }

    public var isMultiWord: Bool { acceptanceUnits.count > 1 }
}

/// The only surface a model exposes to the rest of the app.
///
/// Rule 2 from the plan lives here: everything personal sits behind `TypingContext`
/// and the memory store, never inside an implementation of this protocol. That is
/// what makes a model swappable — and deletable — without touching the user's data.
public protocol SuggestionSource: AnyObject {
    /// Human-readable name, shown in the model picker.
    var name: String { get }
    /// Candidates for this context, best-effort. Must return quickly; the caller
    /// budgets roughly 30ms and will drop late results rather than block typing.
    func suggest(_ context: TypingContext) -> [Candidate]
}
