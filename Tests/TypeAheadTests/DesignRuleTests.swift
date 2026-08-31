import Foundation
import TypeAheadCore

/// Tests for the two design rules the rest of the app is built on.
///
/// These assert over the *source tree*, not over behaviour, because both rules are
/// architectural: they are claims about what code is allowed to exist. A
/// behavioural test would pass right up until someone adds a second call site.
func runDesignRuleTests(_ s: Suite) {
    s.report("Design rules")

    let coreDirectory = URL(fileURLWithPath: #filePath)  // .../Tests/TypeAheadTests/DesignRuleTests.swift
        .deletingLastPathComponent()                     // .../Tests/TypeAheadTests
        .deletingLastPathComponent()                     // .../Tests
        .deletingLastPathComponent()                     // .../TypeAhead
        .appendingPathComponent("Core")

    func swiftSources() -> [(path: String, contents: String)] {
        let enumerator = FileManager.default.enumerator(
            at: coreDirectory, includingPropertiesForKeys: nil)
        var results: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            results.append((url.lastPathComponent, contents))
        }
        return results
    }

    s.test("rule 1: text insertion has exactly one call site") {
        // The app never changes your text unless you press Tab. Enforced
        // structurally: `inserter.insert` is reachable only from the Coordinator's
        // accept path, which only an `.accept` outcome reaches, which only a Tab
        // key can produce.
        let sources = swiftSources()
        s.expect(!sources.isEmpty, "found Core sources to scan")

        // One writer. The inline ghost briefly typed suggestions so they could be
        // shown in React fields that revert Accessibility writes; that was
        // withdrawn after it corrupted live typing. Synthetic keystrokes sharing
        // the user's input stream is not a thing to have two of.
        let callSites = sources
            .filter { $0.path != "Inserter.swift" && $0.contents.contains("inserter.insert(") }
            .map(\.path)
            .sorted()
        s.expectEqual(callSites, ["Coordinator.swift"],
                      "rule 1 — insertion must have a single call site")

        let coordinator = sources.first { $0.path == "Coordinator.swift" }?.contents ?? ""
        let occurrences = coordinator.components(separatedBy: "inserter.insert(").count - 1
        s.expectEqual(occurrences, 1, "rule 1 — Coordinator must not gain a second insertion path")

    }

    s.test("rule 2: nothing fine-tunes") {
        // The memory owns you, the model is a commodity. Baking personalisation
        // into weights would trap the user's identity inside one model and make
        // swapping lossy.
        let banned = ["LoRA", "fineTune", "finetune", "trainAdapter"]
        for source in swiftSources() {
            for term in banned {
                s.expect(!source.contents.contains(term),
                         "rule 2 — \(source.path) references \(term)")
            }
        }
    }

    s.test("rule 2: models expose nothing but the SuggestionSource protocol") {
        // A model implementation must not reach into the memory store; if it did,
        // deleting the model could take user data with it.
        let sources = swiftSources()
        let modelFiles = sources.filter { $0.path.hasSuffix("Source.swift") || $0.path.contains("Model") }
        for file in modelFiles where file.path != "PersonalModel.swift" {
            s.expect(!file.contents.contains("Store("),
                     "rule 2 — \(file.path) must not construct the memory store")
        }
    }
}
