import Foundation
import TypeAheadCore

/// The feedback loop that was recorded for months and never read.
func runCalibrationTests(_ s: Suite) {
    s.report("Calibration")

    s.test("with no history every source is left exactly as it was") {
        // The property that makes this safe to ship before there is anything to
        // learn from: a brand-new install must behave identically to one with no
        // calibrator at all.
        let (store, _) = try makeTemporaryStore()
        let calibrator = Calibrator(store: store)
        calibrator.refresh()

        let candidate = Candidate(text: "ved", probability: 0.45, origin: .lexicon)
        s.expectClose(calibrator.calibrate(candidate).probability, 0.45,
                      "untouched without evidence")
    }

    s.test("a source that is never taken is demoted below one that is") {
        // The real numbers from a real store: snippets were the most-shown source
        // and had never once been accepted, while the lexicon was taken
        // occasionally. Nothing in the app noticed.
        let (store, _) = try makeTemporaryStore()
        for _ in 0..<262 { try store.recordShown(origin: .snippet, app: "") }
        for _ in 0..<199 { try store.recordShown(origin: .lexicon, app: "") }
        for _ in 0..<4 {
            try store.recordAccepted(origin: .lexicon, app: "", charactersSaved: 3)
        }

        let calibrator = Calibrator(store: store)
        calibrator.refresh()

        let snippet = calibrator.multiplier(for: .snippet)
        let lexicon = calibrator.multiplier(for: .lexicon)
        s.expect(snippet < lexicon, "never-accepted source ranks below an accepted one")
        s.expect(snippet < 1.0, "never-accepted source is demoted")
    }

    s.test("calibration redistributes rather than deflating") {
        // The failure mode that would silence the app. Overall acceptance is low
        // in absolute terms, so scaling each source by its own raw acceptance
        // rate drives every candidate under the ranker's absolute savings gate
        // and nothing is ever shown again. Multipliers must average about 1.
        let (store, _) = try makeTemporaryStore()
        for origin in [CandidateOrigin.snippet, .lexicon, .ngram, .prefixTrie] {
            for _ in 0..<100 { try store.recordShown(origin: origin, app: "") }
        }
        for _ in 0..<3 {
            try store.recordAccepted(origin: .lexicon, app: "", charactersSaved: 3)
        }

        let calibrator = Calibrator(store: store)
        calibrator.refresh()

        let all = [CandidateOrigin.snippet, .lexicon, .ngram, .prefixTrie]
            .map { calibrator.multiplier(for: $0) }
        let mean = all.reduce(0, +) / Double(all.count)
        s.expect(mean > 0.8 && mean < 1.25, "multipliers stay centred on 1 (got \(mean))")
    }

    s.test("no source can be silenced by a run of bad luck") {
        // A feedback loop that can suppress its own inputs never recovers: a
        // source shown zero times records no acceptances, which keeps it
        // suppressed. The clamp is what leaves the door open.
        let (store, _) = try makeTemporaryStore()
        for _ in 0..<5000 { try store.recordShown(origin: .snippet, app: "") }
        for _ in 0..<5000 {
            try store.recordAccepted(origin: .lexicon, app: "", charactersSaved: 4)
        }

        let calibrator = Calibrator(store: store)
        calibrator.refresh()
        s.expect(calibrator.multiplier(for: .snippet) >= Calibrator.minimumMultiplier,
                 "demotion is bounded")
        s.expect(calibrator.multiplier(for: .lexicon) <= Calibrator.maximumMultiplier,
                 "promotion is bounded")
    }
}
