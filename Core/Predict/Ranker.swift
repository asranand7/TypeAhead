import Foundation

/// The objective function: suggestions are ranked by expected keystrokes saved,
/// not by probability.
///
///     score = P(accepted) x keystrokes_saved
///
/// This is what makes a 15-character phrase at 40% confidence beat a 3-character
/// word at 90% — the phrase saves more on average. Ranking by probability alone
/// would systematically prefer the short, safe, nearly worthless suggestion.
public struct Ranker: Sendable {
    /// A candidate must clear this expected-savings bar to be shown at all.
    /// Below it, the ghost text costs more attention than it saves keystrokes.
    public var minimumExpectedSavings: Double

    /// - Parameter minimumExpectedSavings: was 1.0, which silently suppressed
    ///   every short completion — "recei" → "ved" scores 0.9 and never appeared.
    ///   Three saved keystrokes at even moderate confidence is worth offering,
    ///   especially inline where an unwanted suggestion costs only the next
    ///   keystroke to dismiss.
    /// What one Tab press costs, in keystrokes.
    ///
    /// Half, not one. A whole keystroke is the right arithmetic for a net count
    /// but the wrong measure of effort: Tab is a single fixed key already under
    /// the finger, not a specific letter that has to be found. Charging it in
    /// full made a one-character completion worth exactly zero by definition, so
    /// the most confident prediction the system can make — "I will conside" to
    /// "consider", at p=0.95 — could never reach the screen at any confidence.
    public static let tabCost = 0.5

    /// A candidate this certain is shown whatever it saves.
    ///
    /// The savings gate exists to stop marginal suggestions costing more
    /// attention than they return. That reasoning does not hold at the top of the
    /// range: a suggestion that is right nineteen times in twenty is nearly free
    /// to accept and nearly free to ignore, and withholding a single character
    /// the user is about to type anyway is not a saving.
    public static let alwaysShowConfidence = 0.85

    public init(minimumExpectedSavings: Double = 0.6) {
        self.minimumExpectedSavings = minimumExpectedSavings
    }

    /// Whether a candidate is worth showing at all.
    private func clears(_ candidate: Candidate) -> Bool {
        let savings = Ranker.expectedSavings(candidate)
        // Nothing to insert is never worth a slot, however certain.
        guard savings > 0 else { return false }
        return savings >= minimumExpectedSavings
            || candidate.probability >= Ranker.alwaysShowConfidence
    }

    /// Odds that a user who took word *i* of a phrase also takes word *i+1*.
    ///
    /// This is the number that stops long suggestions winning by default. A
    /// phrase is not accepted atomically — the user takes a prefix and stops
    /// where it stops being right — so its value is not `p x length` but the sum
    /// over its words of the chance of getting that far. At 0.6 the weights run
    /// 1, .6, .36, .22, .13 and total at most 2.5, so a phrase can never be worth
    /// more than two and a half single words however long it is.
    ///
    /// Without this a six-word snippet scored six times a one-word completion on
    /// raw length alone, which is exactly what it did: in a real store the
    /// snippet tier was shown 262 times and accepted zero.
    /// How likely the next word is to be taken too, by evidence type.
    ///
    /// A verbatim repeat and a chained statistical guess decay at completely
    /// different rates, and using one number for both is what let the ranker be
    /// gamed by length. A snippet is a phrase the user has already typed end to
    /// end, so having taken one word of it they very likely want the next. An
    /// n-gram chain is a different word predicted afresh at each step, and its
    /// error compounds; two words in, it is mostly guessing.
    ///
    /// The sum of the weights is `1 / (1 - q)`, which is the real cap on how much
    /// a phrase can ever be worth: 5 single words for a snippet, under 2 for an
    /// n-gram chain. Before this it was the phrase's raw character count, with no
    /// cap at all.
    public static func continuation(for origin: CandidateOrigin) -> Double {
        switch origin {
        case .snippet:   return 0.8   // you have typed this exact phrase before
        case .model:     return 0.6   // generative, but coherent across words
        case .ngram:     return 0.45  // chained predictions; error compounds
        // The rest emit a single unit, so the rate never applies.
        case .prefixTrie, .lexicon, .identity, .correction, .stub: return 0.6
        }
    }

    /// Keystrokes saved by accepting the whole of `candidate`: everything the
    /// user would otherwise type, less one Tab per bite it takes.
    ///
    /// For a correction that includes the deletions — fixing "recieve" by hand is
    /// seven backspaces *and* seven characters, which is why corrections rank
    /// highly despite being short.
    public static func keystrokesSaved(_ candidate: Candidate) -> Int {
        let taps = candidate.acceptanceUnits.count
        return max(0, candidate.replacesPreviousCharacters + candidate.text.count - taps)
    }

    /// Expected savings, discounting each word of a phrase by the chance the user
    /// gets that far:
    ///
    ///     sum over i of  P x continuation^(i-1) x (length_i - 1)
    ///
    /// A strict generalisation of the old `P x (length - 1)`: for a single-word
    /// candidate the sum has one term and reduces to exactly that, so nothing
    /// about short completions changes.
    public static func expectedSavings(_ candidate: Candidate) -> Double {
        var total = 0.0
        var weight = candidate.probability
        for (index, unit) in candidate.acceptanceUnits.enumerated() {
            // Deletions are paid for once, by the Tab that starts the insertion.
            let replaced = index == 0 ? candidate.replacesPreviousCharacters : 0
            total += weight * max(0, Double(replaced + unit.count) - Ranker.tabCost)
            weight *= Ranker.continuation(for: candidate.origin)
        }
        return total
    }

    /// Best candidate by expected savings, or nil if none clears the gate.
    ///
    /// Ties break toward the higher probability: when two candidates are worth the
    /// same on average, show the one more likely to be right, so the user's trust
    /// in the ghost text stays calibrated.
    public func best(_ candidates: [Candidate]) -> Candidate? {
        candidates
            .filter(clears)
            .max { a, b in
                let sa = Ranker.expectedSavings(a)
                let sb = Ranker.expectedSavings(b)
                if sa == sb { return a.probability < b.probability }
                return sa < sb
            }
    }

    /// Full ordering, best first. Used by compare mode and the tests.
    public func ranked(_ candidates: [Candidate]) -> [Candidate] {
        candidates
            .filter(clears)
            .sorted { a, b in
                let sa = Ranker.expectedSavings(a)
                let sb = Ranker.expectedSavings(b)
                if sa == sb { return a.probability > b.probability }
                return sa > sb
            }
    }
}
