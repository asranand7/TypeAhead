import Foundation

/// Corrects each source's self-reported confidence against whether its
/// suggestions are actually taken.
///
/// The ranker's objective is `P(accepted) x keystrokes_saved`, but until this
/// existed nothing produced a `P(accepted)`. Every source invented a number on
/// its own scale — the n-gram a conditional language-model probability, the
/// lexicon a hand-tuned rank prior, snippets `0.35 + 0.06n` — and the ranker
/// compared them directly as though they were commensurable. They are not, and
/// the store recorded exactly the data needed to find out: `Store.acceptanceRate`
/// was written, tested, and never called once.
///
/// ## Why it is a relative correction
///
/// The obvious scheme — replace the declared probability with the observed
/// acceptance rate — breaks the app. Overall acceptance is low in absolute terms,
/// so scaling every source by its own rate drives every candidate under
/// `Ranker.minimumExpectedSavings` and the app goes permanently silent. The gate
/// is an absolute threshold, so the calibration has to preserve the overall
/// scale and change only the *balance* between sources.
///
/// So each origin is scored against the average origin, not against certainty.
/// A source accepted twice as often as its peers has its confidence raised; one
/// accepted half as often has it cut. With no data at all every multiplier is
/// exactly 1 and nothing changes, which is what makes this safe to ship before
/// there is anything to learn from.
public final class Calibrator {
    /// Beta prior on acceptance, as pseudo-observations. `alpha` successes and
    /// `beta` failures, so a source starts life indistinguishable from one that
    /// was shown five times and taken once — enough inertia that a source cannot
    /// be written off by its first three misses.
    public static let alpha = 1.0
    public static let beta = 4.0

    /// How far a single source may be moved. Without a clamp, one origin with a
    /// handful of observations could swamp the ranking, and a source that is
    /// briefly unlucky would be suppressed so hard it never gets shown again —
    /// and never gets the chance to prove otherwise. Feedback loops that can
    /// silence their own inputs do not recover on their own.
    public static let minimumMultiplier = 0.25
    public static let maximumMultiplier = 2.0

    /// How long a computed set of multipliers is reused. Long enough that this
    /// costs nothing on the keystroke path; short enough that a session's own
    /// feedback starts to tell within minutes.
    private static let refreshInterval: TimeInterval = 60

    private let store: Store
    private let now: () -> Date
    private let lock = NSLock()
    private var multipliers: [CandidateOrigin: Double] = [:]
    private var refreshedAt: Date?

    public init(store: Store, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Rescales `candidate`'s probability by how often its origin is taken.
    public func calibrate(_ candidate: Candidate) -> Candidate {
        let multiplier = multiplier(for: candidate.origin)
        guard multiplier != 1.0 else { return candidate }
        return Candidate(
            text: candidate.text,
            probability: min(0.95, max(0.01, candidate.probability * multiplier)),
            origin: candidate.origin,
            replacesPreviousCharacters: candidate.replacesPreviousCharacters,
            granularity: candidate.granularity)
    }

    public func multiplier(for origin: CandidateOrigin) -> Double {
        refreshIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return multipliers[origin] ?? 1.0
    }

    /// Recomputes every multiplier from the feedback table.
    ///
    /// Exposed so the tests can drive it without waiting out the interval.
    public func refresh() {
        guard let counts = try? store.acceptanceCounts(), !counts.isEmpty else {
            lock.lock(); multipliers = [:]; refreshedAt = now(); lock.unlock()
            return
        }

        // Posterior mean acceptance for each origin under the Beta prior.
        var rates: [CandidateOrigin: Double] = [:]
        for (origin, count) in counts {
            rates[origin] = (Calibrator.alpha + Double(count.accepted))
                / (Calibrator.alpha + Calibrator.beta + Double(count.shown))
        }

        // The reference is the average origin. Dividing through by it is what
        // keeps this a redistribution rather than an across-the-board cut, so
        // the ranker's absolute savings gate keeps meaning what it meant.
        let reference = rates.values.reduce(0, +) / Double(rates.count)
        guard reference > 0 else { return }

        var computed: [CandidateOrigin: Double] = [:]
        for (origin, rate) in rates {
            computed[origin] = min(Calibrator.maximumMultiplier,
                                   max(Calibrator.minimumMultiplier, rate / reference))
        }

        lock.lock()
        multipliers = computed
        refreshedAt = now()
        lock.unlock()
    }

    private func refreshIfNeeded() {
        lock.lock()
        let due = refreshedAt.map { now().timeIntervalSince($0) >= Calibrator.refreshInterval }
            ?? true
        lock.unlock()
        if due { refresh() }
    }
}
