import Foundation

/// Combines personal memory with the language model into one distribution,
/// instead of letting them compete as separate sources.
///
/// This is the piece the app was missing, and the reason its suggestions felt
/// arbitrary. Every tier invented a confidence on its own scale — the n-gram a
/// conditional language-model probability, the lexicon a hand-tuned rank prior,
/// snippets `0.35 + 0.06n` — and the ranker compared those numbers directly as
/// though they meant the same thing. They do not, and no amount of calibration
/// makes them commensurable, because the problem is not that the numbers are
/// mis-scaled: it is that two sources answering the same question were being
/// asked to argue rather than agree.
///
/// The fix is the one Gmail Smart Compose shipped for exactly this problem
/// (Chen et al., KDD 2019): a per-user n-gram interpolated with a global neural
/// model at a fixed weight,
///
///     P(word) = alpha * P_personal(word) + (1 - alpha) * P_global(word)
///
/// One distribution, one scale, one ranking. The personal model stops shouting
/// over the language model and starts steering it — which is what makes a
/// suggestion feel like *you* rather than like autocomplete.
///
/// ## What this does not do
///
/// Only the next-word question is fused, because it is the only one where both
/// halves answer the same event. Mid-word completion is passed through: the
/// n-gram is completing a prefix from your vocabulary while the model is
/// finishing a token, and averaging those would be arithmetic on unrelated
/// quantities. Snippets, identity and corrections stay separate sources too —
/// they are verbatim recall, not prediction, and a phrase you have typed
/// before is evidence of a different kind.
///
/// ## Rule 2 still holds
///
/// With no model attached this degrades to exactly the personal model's own
/// output, unchanged. Deleting the model costs you the global half of the
/// interpolation and nothing else; nothing personal lives inside it.
public final class Fusion: SuggestionSource {
    public let name = "Personal memory + model"

    /// How much of the final probability comes from personal memory.
    ///
    /// 0.4 is Smart Compose's tuned value for the same interpolation, and it is
    /// the right starting point rather than a guess: it was chosen offline
    /// against held-out user mail and produced a 6% relative gain in click-through
    /// and 10% in exact-match. Worth re-tuning here against `SavingsBenchmark`
    /// once there is enough of your own writing to hold out a test split, but not
    /// worth inventing a different number before that evidence exists.
    ///
    /// The asymmetry is deliberate and worth stating: the global model gets the
    /// larger share. Personal memory is sparse — it knows a few thousand words
    /// and almost no grammar — so it should adjust a fluent prediction, not
    /// replace one.
    public static let personalWeight = 0.4

    private let personal: PersonalModel
    /// Resolved per call rather than held, because the model is hot-swappable and
    /// a captured reference would keep a stopped process's object alive and
    /// answer from it.
    private let currentModel: () -> GGUFModel?

    public init(personal: PersonalModel, model: @escaping () -> GGUFModel?) {
        self.personal = personal
        self.currentModel = model
    }

    public func suggest(_ context: TypingContext) -> [Candidate] {
        // Mid-word: not the same question, so not fused. Both sources are asked
        // and both answers are returned for the ranker to weigh, which is the
        // behaviour that was already there and is correct for this case.
        guard context.currentWordPrefix.isEmpty else {
            return personal.suggest(context) + (currentModel()?.suggest(context) ?? [])
        }

        // One sighting is enough to matter here. See the parameter's own note:
        // the standalone bar exists to stop a single observation *being* a
        // suggestion, not to stop it informing one.
        let personalScores = personal.nextWordDistribution(for: context, minimumEvidence: 1)

        guard let model = currentModel(),
              let prompt = GGUFModel.prompt(for: context),
              let answer = model.complete(prompt: prompt),
              !answer.distribution.isEmpty else {
            // No model, or it did not answer inside its budget. Memory alone is a
            // working app, and a missing suggestion is a non-event.
            return personal.suggest(context)
        }

        let fused = Fusion.interpolate(personal: personalScores,
                                       global: answer.distribution,
                                       personalWeight: Fusion.personalWeight)

        return PersonalModel.candidates(
            from: fused,
            lead: PersonalModel.leadingSeparator(for: context.textBeforeCaret),
            capitalize: PersonalModel.startsSentence(context.textBeforeCaret),
            // Attributed to the model, because the model's fluency is what the
            // combined number mostly reflects and the savings report should not
            // credit the n-gram for it.
            origin: .model)
    }

    /// The interpolation itself, over the union of both vocabularies.
    ///
    /// The union, not the intersection, and this is the whole point. A word only
    /// personal memory knows — a name, a repo, a Hinglish spelling the model has
    /// never seen — keeps `alpha` times its personal probability and can still
    /// win. A word only the model knows keeps `1 - alpha` times its own and
    /// carries the sentence where memory has nothing to say. A word both propose
    /// gets both terms and beats either alone, which is the agreement bonus the
    /// old `boostAgreement` was approximating with a multiplier.
    ///
    /// Each side is normalised first. The n-gram's scores are discounted by
    /// backoff and do not sum to one; the model's top-k is a truncated tail of a
    /// distribution that does. Interpolating them unnormalised would weight
    /// whichever side happened to be less certain.
    public static func interpolate(personal: [String: Double],
                                   global: [String: Double],
                                   personalWeight alpha: Double) -> [String: Double] {
        let p = Fusion.normalized(personal)
        let g = Fusion.normalized(global)

        var out: [String: Double] = [:]
        for key in Set(p.keys).union(g.keys) {
            out[key] = alpha * (p[key] ?? 0) + (1 - alpha) * (g[key] ?? 0)
        }
        return out
    }

    /// Scales a set of scores to sum to one, or returns it untouched when there
    /// is nothing to scale.
    static func normalized(_ scores: [String: Double]) -> [String: Double] {
        let total = scores.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return scores.mapValues { $0 / total }
    }
}
