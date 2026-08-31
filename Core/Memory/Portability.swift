import Foundation

/// Export and import of the memory store — the feature that lets a second laptop
/// inherit everything the first one learned.
///
/// The file is a zip so it is one thing to copy, but unzippable and readable:
///
///     identity.json      readable    name, emails, phone, addresses
///     vocab.json         readable    names, terms, protected words
///     snippets.json      readable    your repeated phrases
///     corrections.json   readable    your typo pairs
///     stats.sqlite       opaque      n-gram counts
///     manifest.json                  schema version, machine, date, totals
///
/// The JSON files are *authoritative* on import, so editing them by hand does
/// what you would expect. `stats.sqlite` contributes only the n-grams, whose ids
/// are meaningless outside the database that produced them.
///
/// No model weights, no tokenizer ids, no embeddings — rule 2 in file form. An
/// export taken from a machine running one model imports cleanly on a machine
/// running another, or none.
public final class Portability {
    public struct Manifest: Codable {
        public var schemaVersion: Int
        public var machine: String
        public var exportedAt: String
        public var wordCount: Int
        public var snippetCount: Int
        public var identityCount: Int
        public var correctionCount: Int
    }

    struct VocabRecord: Codable {
        let word: String
        let kind: String
        let count: Int
        let isProtected: Bool
    }

    struct SnippetRecord: Codable {
        let text: String
        let count: Int
        let source: String
    }

    struct IdentityRecord: Codable {
        let key: String
        let value: String
        let source: String
    }

    struct CorrectionRecord: Codable {
        let wrong: String
        let right: String
        let count: Int
    }

    /// What the export review window controls. Defaults include everything except
    /// nothing — the user opts *out*, item by item or a whole tier at a time.
    public struct ExportOptions {
        public var includeIdentity: Bool
        public var includeVocabulary: Bool
        public var includeSnippets: Bool
        public var includeCorrections: Bool
        public var includeStatistics: Bool
        /// Individual values held back, by exact string.
        public var excludedValues: Set<String>

        public init(includeIdentity: Bool = true,
                    includeVocabulary: Bool = true,
                    includeSnippets: Bool = true,
                    includeCorrections: Bool = true,
                    includeStatistics: Bool = true,
                    excludedValues: Set<String> = []) {
            self.includeIdentity = includeIdentity
            self.includeVocabulary = includeVocabulary
            self.includeSnippets = includeSnippets
            self.includeCorrections = includeCorrections
            self.includeStatistics = includeStatistics
            self.excludedValues = excludedValues
        }
    }

    public struct ImportSummary {
        public var wordsAdded = 0
        public var wordsMerged = 0
        public var snippetsMerged = 0
        public var identityFactsMerged = 0
        public var correctionsMerged = 0
        public var ngramsMerged = 0
        /// Identity keys that now hold more than one value, e.g. two phone
        /// numbers. Deliberately kept rather than resolved — see `importMemory`.
        public var conflictingKeys: [String] = []
    }

    public enum Failure: Error, CustomStringConvertible {
        case archiveFailed(String)
        case notAnArchive(String)
        case incompatibleSchema(found: Int, supported: Int)

        public var description: String {
            switch self {
            case .archiveFailed(let message): return "archive step failed: \(message)"
            case .notAnArchive(let path): return "not a TypeAhead memory file: \(path)"
            case .incompatibleSchema(let found, let supported):
                return "memory file uses schema \(found); this build supports \(supported)"
            }
        }
    }

    public static let fileExtension = "tamem"

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    // MARK: - Export

    @discardableResult
    public func export(to destination: URL, options: ExportOptions = ExportOptions()) throws -> Manifest {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeahead-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let vocabulary = options.includeVocabulary
            ? try store.allVocab()
                .filter { !options.excludedValues.contains($0.word) }
                .map { VocabRecord(word: $0.word, kind: $0.kind, count: $0.count, isProtected: $0.isProtected) }
            : []

        let snippets = options.includeSnippets
            ? try store.allSnippets()
                .filter { $0.source == "manual" || $0.count >= SnippetMiner.promotionThreshold }
                .filter { !options.excludedValues.contains($0.text) }
                .map { SnippetRecord(text: $0.text, count: $0.count, source: $0.source) }
            : []

        let identity = options.includeIdentity
            ? try store.identityFacts(confirmedOnly: true)
                .filter { !options.excludedValues.contains($0.value) }
                .map { IdentityRecord(key: $0.key, value: $0.value, source: $0.source) }
            : []

        let corrections = options.includeCorrections
            ? try store.allCorrections()
                .filter { !options.excludedValues.contains($0.wrong) }
                .map { CorrectionRecord(wrong: $0.wrong, right: $0.right, count: $0.count) }
            : []

        try encoder.encode(vocabulary).write(to: staging.appendingPathComponent("vocab.json"))
        try encoder.encode(snippets).write(to: staging.appendingPathComponent("snippets.json"))
        try encoder.encode(identity).write(to: staging.appendingPathComponent("identity.json"))
        try encoder.encode(corrections).write(to: staging.appendingPathComponent("corrections.json"))

        if options.includeStatistics {
            try store.database.vacuum(into: staging.appendingPathComponent("stats.sqlite").path)
        }

        let manifest = Manifest(
            schemaVersion: Store.schemaVersion,
            machine: (try? store.metaValue(for: "machine")) as? String ?? "unknown",
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            wordCount: vocabulary.count,
            snippetCount: snippets.count,
            identityCount: identity.count,
            correctionCount: corrections.count)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try Portability.zip(directory: staging, to: destination)
        return manifest
    }

    // MARK: - Import

    /// Merges another machine's memory into this one.
    ///
    /// **Merges, never overwrites.** Counts are summed, vocabularies unioned. This
    /// is what makes the feature safe to use in both directions: carrying memory to
    /// laptop B must not erase what B already learned, and syncing back must not
    /// erase A. Overwrite semantics would quietly destroy weeks of learning.
    ///
    /// Identity is the deliberate exception. If the two machines disagree about a
    /// phone number, both are kept and the key is reported in
    /// `ImportSummary.conflictingKeys` — picking a winner silently is the one
    /// outcome the user cannot detect or undo.
    @discardableResult
    public func importMemory(from archive: URL) throws -> ImportSummary {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeahead-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try Portability.unzip(archive: archive, to: staging)

        let decoder = JSONDecoder()
        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(Manifest.self, from: manifestData) else {
            throw Failure.notAnArchive(archive.path)
        }
        guard manifest.schemaVersion <= Store.schemaVersion else {
            throw Failure.incompatibleSchema(found: manifest.schemaVersion,
                                             supported: Store.schemaVersion)
        }

        var summary = ImportSummary()

        // One transaction for the whole merge: a half-merged store would be worse
        // than a failed import, because the user would have no way to tell.
        try store.database.transaction {
            if let data = try? Data(contentsOf: staging.appendingPathComponent("vocab.json")),
               let records = try? decoder.decode([VocabRecord].self, from: data) {
                for record in records {
                    let existing = try store.database.queryInTransaction(
                        "SELECT count FROM vocab WHERE word = ?", [.text(record.word)])
                    if existing.isEmpty { summary.wordsAdded += 1 } else { summary.wordsMerged += 1 }

                    try store.database.executeInTransaction("""
                        INSERT INTO vocab (word, kind, count, protected, first_seen, last_seen)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(word) DO UPDATE SET
                            count = count + excluded.count,
                            protected = MAX(vocab.protected, excluded.protected)
                        """, [.text(record.word), .text(record.kind),
                              .integer(Int64(record.count)),
                              .integer(record.isProtected ? 1 : 0),
                              .real(Date().timeIntervalSince1970),
                              .real(Date().timeIntervalSince1970)])
                }
            }

            if let data = try? Data(contentsOf: staging.appendingPathComponent("snippets.json")),
               let records = try? decoder.decode([SnippetRecord].self, from: data) {
                for record in records {
                    try store.database.executeInTransaction("""
                        INSERT INTO snippet (text, count, source, last_used)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(text) DO UPDATE SET count = count + excluded.count
                        """, [.text(record.text), .integer(Int64(record.count)),
                              .text(record.source), .real(Date().timeIntervalSince1970)])
                    summary.snippetsMerged += 1
                }
            }

            if let data = try? Data(contentsOf: staging.appendingPathComponent("identity.json")),
               let records = try? decoder.decode([IdentityRecord].self, from: data) {
                for record in records {
                    // (key, value) primary key: a differing value for the same key
                    // lands as a second row rather than replacing the first.
                    try store.database.executeInTransaction("""
                        INSERT INTO identity (key, value, confirmed, source)
                        VALUES (?, ?, 1, ?)
                        ON CONFLICT(key, value) DO UPDATE SET confirmed = 1
                        """, [.text(record.key), .text(record.value), .text(record.source)])
                    summary.identityFactsMerged += 1
                }
            }

            if let data = try? Data(contentsOf: staging.appendingPathComponent("corrections.json")),
               let records = try? decoder.decode([CorrectionRecord].self, from: data) {
                for record in records {
                    try store.database.executeInTransaction("""
                        INSERT INTO correction (wrong, right, count) VALUES (?, ?, ?)
                        ON CONFLICT(wrong, right) DO UPDATE SET count = count + excluded.count
                        """, [.text(record.wrong), .text(record.right),
                              .integer(Int64(record.count))])
                    summary.correctionsMerged += 1
                }
            }

            let statsPath = staging.appendingPathComponent("stats.sqlite").path
            if FileManager.default.fileExists(atPath: statsPath) {
                summary.ngramsMerged = try mergeStatistics(from: statsPath)
            }
        }

        summary.conflictingKeys = try store.conflictingIdentityKeys()
        return summary
    }

    /// N-gram ids are local to the database that produced them, so rows are
    /// re-pointed through the *word* they name. Everything the incoming file knows
    /// as id 47 is looked up by its spelling and rewritten to whatever this store
    /// calls it — which is why a straight table copy would silently corrupt the
    /// statistics rather than merge them.
    private func mergeStatistics(from path: String) throws -> Int {
        try store.database.executeInTransaction("ATTACH DATABASE ? AS incoming", [.text(path)])
        defer { try? store.database.executeInTransaction("DETACH DATABASE incoming") }

        let before = try store.database.queryInTransaction(
            "SELECT COALESCE(SUM(count), 0) AS total FROM ngram").first?.int("total") ?? 0

        try store.database.executeInTransaction("""
            INSERT INTO ngram (prev2, prev1, next_id, app, count)
            SELECT CASE WHEN n.prev2 < 0 THEN n.prev2 ELSE COALESCE(m2.id, 0) END,
                   CASE WHEN n.prev1 < 0 THEN n.prev1 ELSE COALESCE(m1.id, 0) END,
                   mn.id, n.app, n.count
            FROM incoming.ngram n
            JOIN incoming.vocab sn ON sn.id = n.next_id
            JOIN main.vocab     mn ON mn.word = sn.word
            LEFT JOIN incoming.vocab s1 ON s1.id = n.prev1
            LEFT JOIN main.vocab     m1 ON m1.word = s1.word
            LEFT JOIN incoming.vocab s2 ON s2.id = n.prev2
            LEFT JOIN main.vocab     m2 ON m2.word = s2.word
            WHERE (n.prev1 <= 0 OR m1.id IS NOT NULL)
              AND (n.prev2 <= 0 OR m2.id IS NOT NULL)
            ON CONFLICT(prev2, prev1, next_id, app) DO UPDATE SET
                count = count + excluded.count
            """)

        let after = try store.database.queryInTransaction(
            "SELECT COALESCE(SUM(count), 0) AS total FROM ngram").first?.int("total") ?? 0
        return Int(after - before)
    }

    // MARK: - Archive plumbing

    /// `zip`/`unzip` rather than a compression library: both ship with macOS, the
    /// result is a zip any user can open in Finder, and it keeps a third-party
    /// dependency out of a file format the user is meant to trust.
    public static func zip(directory: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "-X", destination.path, "."]
        process.currentDirectoryURL = directory

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "unknown"
            throw Failure.archiveFailed(message)
        }
    }

    public static func unzip(archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", directory.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "unknown"
            throw Failure.archiveFailed(message)
        }
    }
}
