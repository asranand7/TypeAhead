import Foundation
import TypeAheadCore

/// Tests for the cross-laptop feature. The merge tests are the ones that matter:
/// an export that loses data is recoverable, but an import that *overwrites* the
/// receiving machine destroys weeks of learning with no way to notice.
func runPortabilityTests(_ s: Suite) {
    s.report("Export / import")

    func archiveURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeahead-test-\(UUID().uuidString).\(Portability.fileExtension)")
    }

    s.test("round trip: export, wipe, import restores every tier") {
        let (store, _) = try makeTemporaryStore()
        try store.setIdentity("email", "testuser@example.com")
        for _ in 0..<5 { try store.recordWord("chaudhary") }
        for _ in 0..<SnippetMiner.promotionThreshold {
            try store.recordSnippet("let me know if that works")
        }
        try store.recordCorrection(wrong: "recieve", right: "receive")

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        let portability = Portability(store: store)
        try portability.export(to: archive)

        try store.wipe()
        s.expectEqual(try store.wordCount("chaudhary"), 0, "wiped")

        try portability.importMemory(from: archive)

        s.expectEqual(try store.wordCount("chaudhary"), 5, "vocabulary restored with counts")
        s.expectEqual(try store.identityFacts().first?.value, "testuser@example.com",
                      "identity restored")
        s.expect(try store.allSnippets().contains { $0.text == "let me know if that works" },
                 "snippet restored")
        s.expectEqual(try store.correction(for: "recieve")?.right, "receive",
                      "correction restored")
    }

    s.test("import MERGES counts rather than overwriting them") {
        // The headline guarantee. Laptop B must not lose what B already learned.
        let (source, _) = try makeTemporaryStore()
        for _ in 0..<3 { try source.recordWord("shreya") }

        let (destination, _) = try makeTemporaryStore()
        for _ in 0..<4 { try destination.recordWord("shreya") }
        for _ in 0..<2 { try destination.recordWord("anand") }

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        try Portability(store: source).export(to: archive)
        try Portability(store: destination).importMemory(from: archive)

        s.expectEqual(try destination.wordCount("shreya"), 7, "counts summed, not replaced")
        s.expectEqual(try destination.wordCount("anand"), 2, "the receiving machine keeps its own")
    }

    s.test("n-gram statistics survive the id remapping") {
        // Vocabulary ids are local to the database that made them. A straight
        // table copy would silently point rows at the wrong words.
        let (source, _) = try makeTemporaryStore()
        let sourceModel = PersonalModel(store: source)
        for _ in 0..<4 {
            sourceModel.observe(.caretMoved)
            sourceModel.observe(.wordCommitted(word: "please", boundary: .space, appBundleID: nil))
            sourceModel.observe(.wordCommitted(word: "find", boundary: .space, appBundleID: nil))
            sourceModel.observe(.wordCommitted(word: "attached", boundary: .space, appBundleID: nil))
        }

        // Give the destination a different vocabulary first, so ids cannot line up.
        let (destination, _) = try makeTemporaryStore()
        for word in ["zebra", "yak", "xylophone", "walrus"] {
            for _ in 0..<2 { try destination.recordWord(word) }
        }

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        try Portability(store: source).export(to: archive)
        try Portability(store: destination).importMemory(from: archive)

        let model = PersonalModel(store: destination)
        let candidates = model.suggest(TypingContext(textBeforeCaret: "please find ",
                                                     currentWordPrefix: "",
                                                     appBundleID: nil,
                                                     isAuthoritative: true))
        s.expect(candidates.contains { $0.text.trimmingCharacters(in: .whitespaces) == "attached" },
                 "imported statistics predict correctly — got \(candidates.map(\.text))")
    }

    s.test("conflicting identity values are BOTH kept and flagged") {
        // The one place merging does not simply combine. Silently picking a winner
        // is the only outcome the user cannot detect or undo.
        let (source, _) = try makeTemporaryStore()
        try source.setIdentity("phone", "+91 90000 00001")

        let (destination, _) = try makeTemporaryStore()
        try destination.setIdentity("phone", "+91 90000 00002")

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        try Portability(store: source).export(to: archive)
        let summary = try Portability(store: destination).importMemory(from: archive)

        let phones = try destination.identityFacts().filter { $0.key == "phone" }
        s.expectEqual(phones.count, 2, "both numbers survive")
        s.expect(summary.conflictingKeys.contains("phone"), "conflict reported to the user")
    }

    s.test("the export contains nothing model-specific") {
        // Rule 2 in file form: an export from a machine running one model must
        // import on a machine running another, or none.
        let (store, _) = try makeTemporaryStore()
        for _ in 0..<2 { try store.recordWord("portable") }

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        try Portability(store: store).export(to: archive)

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Portability.unzip(archive: archive, to: staging)

        let names = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
        s.expectEqual(names,
                      ["corrections.json", "identity.json", "manifest.json",
                       "snippets.json", "stats.sqlite", "vocab.json"],
                      "exactly the documented contents")
        s.expect(!names.contains { $0.hasSuffix(".gguf") || $0.contains("model") },
                 "no weights, no model metadata")
    }

    s.test("the readable tiers really are readable") {
        // The file is meant to answer "what does this thing know about me?".
        let (store, _) = try makeTemporaryStore()
        try store.setIdentity("email", "testuser@example.com")

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        try Portability(store: store).export(to: archive)

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Portability.unzip(archive: archive, to: staging)

        let json = try String(contentsOf: staging.appendingPathComponent("identity.json"),
                              encoding: .utf8)
        s.expect(json.contains("testuser@example.com"), "plain text, greppable")
    }

    s.test("dropping the identity tier actually drops it") {
        let (store, _) = try makeTemporaryStore()
        try store.setIdentity("email", "testuser@example.com")
        for _ in 0..<2 { try store.recordWord("kept") }

        let archive = archiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }
        try Portability(store: store).export(
            to: archive,
            options: Portability.ExportOptions(includeIdentity: false))

        let (destination, _) = try makeTemporaryStore()
        try Portability(store: destination).importMemory(from: archive)

        s.expect(try destination.identityFacts().isEmpty, "identity withheld")
        s.expectEqual(try destination.wordCount("kept"), 2, "the rest still exported")
    }
}
