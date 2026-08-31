import Foundation

/// The memory store: all four tiers in one SQLite file.
///
/// This is the thing rule 2 protects. Everything that makes the app *yours* lives
/// here and nowhere else — never in model weights — so a model can be swapped or
/// deleted without costing anything. It is also the thing that gets exported.
///
/// Tiers:
///   1. `identity` — name, emails, phone, addresses
///   2. `vocab`    — words, names, terms; `protected` guards them from correction
///   3. `snippet`  — repeated phrases, promoted automatically
///   4. `ngram`    — statistics, with a per-app context column
///
/// Plus `correction` (typo pairs learned from backspaces) and `feedback`
/// (acceptance rates, which tune the gate and feed the savings metric).
public final class Store {
    public static let schemaVersion = 2

    /// Context slot meaning "any word", as opposed to 0 which means "no word".
    ///
    /// Backoff needs to ask "how often does `next` follow `prev1`, whatever came
    /// before it" — a marginal over prev2. Overloading 0 for that cannot work,
    /// because 0 is already a real answer: it is what a word at the start of a
    /// sentence genuinely has behind it. Using the same key for both made a
    /// sentence-start observation and a marginal indistinguishable, so they
    /// summed into each other and every sentence-start word was counted three
    /// times. A separate sentinel keeps the two questions separate.
    public static let anyWord: Int64 = -1

    public let database: Database

    public init(path: String) throws {
        self.database = try Database(path: path)
        try migrate()
    }

    /// The default location: Application Support, not Documents, because this is
    /// app state rather than a user document. Export is how it becomes a file the
    /// user handles.
    public static func defaultPath() throws -> String {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
            .appendingPathComponent("TypeAhead", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("memory.sqlite").path
    }

    private func migrate() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS vocab (
                id          INTEGER PRIMARY KEY,
                word        TEXT    NOT NULL UNIQUE,
                kind        TEXT    NOT NULL DEFAULT 'word',
                count       INTEGER NOT NULL DEFAULT 0,
                protected   INTEGER NOT NULL DEFAULT 0,
                first_seen  REAL,
                last_seen   REAL
            )
            """)
        // Prefix completion is `word LIKE 'abc%'`, which uses this index only
        // because the pattern is a literal prefix with no leading wildcard.
        try database.execute("CREATE INDEX IF NOT EXISTS vocab_word ON vocab(word)")
        try database.execute("CREATE INDEX IF NOT EXISTS vocab_count ON vocab(count DESC)")

        // prev2/prev1 of 0 mean "no context", which is how unigrams and bigrams
        // share this table with trigrams instead of needing three of them.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS ngram (
                prev2   INTEGER NOT NULL DEFAULT 0,
                prev1   INTEGER NOT NULL DEFAULT 0,
                next_id INTEGER NOT NULL,
                app     TEXT    NOT NULL DEFAULT '',
                count   INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (prev2, prev1, next_id, app)
            )
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS ngram_context ON ngram(prev2, prev1, app, count DESC)")

        try database.execute("""
            CREATE TABLE IF NOT EXISTS snippet (
                id        INTEGER PRIMARY KEY,
                text      TEXT    NOT NULL UNIQUE,
                count     INTEGER NOT NULL DEFAULT 0,
                source    TEXT    NOT NULL DEFAULT 'auto',
                last_used REAL
            )
            """)

        // (key, value) is the primary key rather than (key): two laptops that
        // disagree about a phone number must both survive an import, flagged for
        // review, rather than one silently overwriting the other.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS identity (
                key       TEXT    NOT NULL,
                value     TEXT    NOT NULL,
                confirmed INTEGER NOT NULL DEFAULT 0,
                source    TEXT    NOT NULL DEFAULT 'manual',
                PRIMARY KEY (key, value)
            )
            """)

        try database.execute("""
            CREATE TABLE IF NOT EXISTS correction (
                wrong TEXT    NOT NULL,
                right TEXT    NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (wrong, right)
            )
            """)

        try database.execute("""
            CREATE TABLE IF NOT EXISTS feedback (
                origin      TEXT    NOT NULL,
                app         TEXT    NOT NULL DEFAULT '',
                shown       INTEGER NOT NULL DEFAULT 0,
                accepted    INTEGER NOT NULL DEFAULT 0,
                chars_saved INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (origin, app)
            )
            """)

        try database.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")

        try backfillNgramMarginals()
        try pruneSubPhraseSnippets()

        if database.userVersion < Store.schemaVersion {
            database.userVersion = Store.schemaVersion
        }
        if try metaValue(for: "machine") == nil {
            try setMeta("machine", Host.current().localizedName ?? "unknown")
        }
        if try metaValue(for: "created") == nil {
            try setMeta("created", ISO8601DateFormatter().string(from: Date()))
        }
    }

    /// Builds the bigram and unigram marginals for a store written before they
    /// existed (schema 1).
    ///
    /// Under schema 1 each word occurrence wrote exactly one row, whose shape
    /// depended only on how much history happened to be in the window. So the
    /// full set of observations is the sum over *all* rows — which is what makes
    /// the marginals recoverable without replaying anything. Summing rather than
    /// re-counting is also what makes this safe to run on a store that has
    /// already been migrated: the marginal rows use `anyWord`, and the query
    /// below deliberately skips them, so a second run reads the same source rows
    /// and produces the same totals rather than compounding them.
    private func backfillNgramMarginals() throws {
        guard database.userVersion < 2 else { return }

        // Bigram: how often `next` followed `prev1`, whatever preceded that.
        try database.execute("""
            INSERT INTO ngram (prev2, prev1, next_id, app, count)
            SELECT \(Store.anyWord), prev1, next_id, app, SUM(count)
            FROM ngram WHERE prev2 <> \(Store.anyWord) AND prev1 <> \(Store.anyWord)
            GROUP BY prev1, next_id, app
            ON CONFLICT(prev2, prev1, next_id, app) DO UPDATE SET count = excluded.count
            """)

        // Unigram: how often `next` occurred at all.
        try database.execute("""
            INSERT INTO ngram (prev2, prev1, next_id, app, count)
            SELECT \(Store.anyWord), \(Store.anyWord), next_id, app, SUM(count)
            FROM ngram WHERE prev2 <> \(Store.anyWord) AND prev1 <> \(Store.anyWord)
            GROUP BY next_id, app
            ON CONFLICT(prev2, prev1, next_id, app) DO UPDATE SET count = excluded.count
            """)
    }

    /// Removes mined snippets too short to be phrases.
    ///
    /// Written when the length floor rose from two words to three. Two-word
    /// "snippets" are bigrams the n-gram tier already holds with proper backoff,
    /// and leaving the old ones in place would keep a redundant copy competing
    /// with the original for the same slot. Only auto-mined rows are touched —
    /// anything the user added by hand is theirs, whatever its length.
    private func pruneSubPhraseSnippets() throws {
        guard database.userVersion < 2 else { return }
        try database.execute("""
            DELETE FROM snippet
            WHERE source = 'auto'
              AND length(trim(text)) - length(replace(trim(text), ' ', '')) < 2
            """)
    }

    // MARK: - Meta

    public func metaValue(for key: String) throws -> String? {
        try database.query("SELECT value FROM meta WHERE key = ?", [.text(key)])
            .first?.string("value")
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try database.execute(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    // MARK: - Tier 2: vocabulary

    @discardableResult
    public func recordWord(_ word: String, kind: String = "word") throws -> Int64 {
        let now = Date().timeIntervalSince1970
        try database.execute("""
            INSERT INTO vocab (word, kind, count, first_seen, last_seen)
            VALUES (?, ?, 1, ?, ?)
            ON CONFLICT(word) DO UPDATE SET
                count = count + 1,
                last_seen = excluded.last_seen
            """, [.text(word), .text(kind), .real(now), .real(now)])
        return try vocabID(for: word) ?? 0
    }

    public func vocabID(for word: String) throws -> Int64? {
        try database.query("SELECT id FROM vocab WHERE word = ?", [.text(word)]).first?.int("id")
    }

    public func wordCount(_ word: String) throws -> Int {
        Int(try database.query("SELECT count FROM vocab WHERE word = ?", [.text(word)])
            .first?.int("count") ?? 0)
    }

    public func totalWordCount() throws -> Int {
        Int(try database.query("SELECT COALESCE(SUM(count), 0) AS total FROM vocab")
            .first?.int("total") ?? 0)
    }

    public struct VocabEntry {
        public let word: String
        public let kind: String
        public let count: Int
        public let isProtected: Bool
    }

    /// Words starting with `prefix`, most-used first.
    public func completions(prefix: String, limit: Int = 8) throws -> [VocabEntry] {
        guard !prefix.isEmpty else { return [] }
        // Escape LIKE metacharacters so a literal % or _ in a prefix cannot turn
        // into a wildcard and match the entire vocabulary.
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        // 'unverified' words are counted but never offered — see WordHygiene.
        // Filtering in SQL rather than after the fact keeps the LIMIT meaningful,
        // so a pile of typos cannot crowd out the real completions.
        return try database.query("""
            SELECT word, kind, count, protected FROM vocab
            WHERE word LIKE ? ESCAPE '\\' AND word <> ?
              AND kind <> 'unverified'
            ORDER BY count DESC, word ASC
            LIMIT ?
            """, [.text(escaped + "%"), .text(prefix), .integer(Int64(limit))])
            .map {
                VocabEntry(word: $0.string("word") ?? "",
                           kind: $0.string("kind") ?? "word",
                           count: Int($0.int("count") ?? 0),
                           isProtected: ($0.int("protected") ?? 0) != 0)
            }
    }

    public func markProtected(_ word: String, _ isProtected: Bool = true) throws {
        try database.execute("UPDATE vocab SET protected = ? WHERE word = ?",
                             [.integer(isProtected ? 1 : 0), .text(word)])
    }

    public func isProtected(_ word: String) throws -> Bool {
        (try database.query("SELECT protected FROM vocab WHERE word = ?", [.text(word)])
            .first?.int("protected") ?? 0) != 0
    }

    public func setKind(_ word: String, _ kind: String) throws {
        try database.execute("UPDATE vocab SET kind = ? WHERE word = ?", [.text(kind), .text(word)])
    }

    public func allVocab() throws -> [VocabEntry] {
        try database.query("SELECT word, kind, count, protected FROM vocab ORDER BY count DESC")
            .map {
                VocabEntry(word: $0.string("word") ?? "",
                           kind: $0.string("kind") ?? "word",
                           count: Int($0.int("count") ?? 0),
                           isProtected: ($0.int("protected") ?? 0) != 0)
            }
    }

    // MARK: - Tier 4: statistics

    /// Records one observed continuation.
    ///
    /// Written twice: once tagged with the app, once with `''` for the global
    /// aggregate. Doubling the writes buys a single-row lookup at prediction time,
    /// which is the side that has a 40ms budget.
    /// Records one word occurrence at all three context depths.
    ///
    /// Three rows, not one. The previous version wrote only the trigram, which
    /// meant the bigram and unigram tiers the backoff walks down to were never
    /// populated — they matched only the handful of rows that happened to be
    /// written with a short window, right after a caret reset. In a real store
    /// that stranded ~80% of the evidence in the trigram tier, where it almost
    /// never matched, and the personal model ran on the remainder.
    ///
    /// The marginals use `anyWord` in the slots they generalise over, so they
    /// cannot collide with a genuine "nothing preceded this" observation.
    public func recordNgram(prev2: Int64, prev1: Int64, next: Int64, app: String) throws {
        let contexts: [(Int64, Int64)] = [
            (prev2, prev1),                 // trigram
            (Store.anyWord, prev1),         // bigram: marginal over prev2
            (Store.anyWord, Store.anyWord)  // unigram: marginal over both
        ]
        let keys = Set(contexts.map { ContextKey(prev2: $0.0, prev1: $0.1) })
        for scope in Set([app, ""]) {
            for key in keys {
                try database.execute("""
                    INSERT INTO ngram (prev2, prev1, next_id, app, count)
                    VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(prev2, prev1, next_id, app) DO UPDATE SET count = count + 1
                    """, [.integer(key.prev2), .integer(key.prev1), .integer(next), .text(scope)])
            }
        }
    }

    /// Deduplicates the three context depths, which coincide for a word typed
    /// with no history — writing that row three times would triple its weight.
    private struct ContextKey: Hashable {
        let prev2: Int64
        let prev1: Int64
    }

    public struct Continuation {
        public let word: String
        public let count: Int
        public let contextTotal: Int
    }

    /// Continuations for a context, most frequent first. `prev2`/`prev1` of 0 mean
    /// no context at that depth, which is how backoff walks down to unigrams.
    public func continuations(prev2: Int64,
                              prev1: Int64,
                              app: String,
                              limit: Int = 8) throws -> [Continuation] {
        let rows = try database.query("""
            SELECT v.word AS word, n.count AS count
            FROM ngram n JOIN vocab v ON v.id = n.next_id
            WHERE n.prev2 = ? AND n.prev1 = ? AND n.app = ?
            ORDER BY n.count DESC
            LIMIT ?
            """, [.integer(prev2), .integer(prev1), .text(app), .integer(Int64(limit))])

        let total = Int(try database.query("""
            SELECT COALESCE(SUM(count), 0) AS total FROM ngram
            WHERE prev2 = ? AND prev1 = ? AND app = ?
            """, [.integer(prev2), .integer(prev1), .text(app)])
            .first?.int("total") ?? 0)

        return rows.map {
            Continuation(word: $0.string("word") ?? "",
                         count: Int($0.int("count") ?? 0),
                         contextTotal: max(total, 1))
        }
    }

    // MARK: - Tier 3: snippets

    public struct Snippet {
        public let text: String
        public let count: Int
        public let source: String

        public init(text: String, count: Int, source: String) {
            self.text = text
            self.count = count
            self.source = source
        }
    }

    @discardableResult
    public func recordSnippet(_ text: String, source: String = "auto") throws -> Bool {
        let now = Date().timeIntervalSince1970
        try database.execute("""
            INSERT INTO snippet (text, count, source, last_used)
            VALUES (?, 1, ?, ?)
            ON CONFLICT(text) DO UPDATE SET count = count + 1, last_used = excluded.last_used
            """, [.text(text), .text(source), .real(now)])
        return true
    }

    public func snippets(startingWith prefix: String, limit: Int = 5) throws -> [Snippet] {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try database.query("""
            SELECT text, count, source FROM snippet
            WHERE text LIKE ? ESCAPE '\\' AND text <> ?
            ORDER BY count DESC, length(text) DESC
            LIMIT ?
            """, [.text(escaped + "%"), .text(prefix), .integer(Int64(limit))])
            .map {
                Snippet(text: $0.string("text") ?? "",
                        count: Int($0.int("count") ?? 0),
                        source: $0.string("source") ?? "auto")
            }
    }

    public func allSnippets() throws -> [Snippet] {
        try database.query("SELECT text, count, source FROM snippet ORDER BY count DESC")
            .map {
                Snippet(text: $0.string("text") ?? "",
                        count: Int($0.int("count") ?? 0),
                        source: $0.string("source") ?? "auto")
            }
    }

    public func deleteSnippet(_ text: String) throws {
        try database.execute("DELETE FROM snippet WHERE text = ?", [.text(text)])
    }

    // MARK: - Tier 1: identity

    public struct IdentityFact {
        public let key: String
        public let value: String
        public let confirmed: Bool
        public let source: String
    }

    public func setIdentity(_ key: String,
                            _ value: String,
                            confirmed: Bool = true,
                            source: String = "manual") throws {
        try database.execute("""
            INSERT INTO identity (key, value, confirmed, source)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(key, value) DO UPDATE SET
                confirmed = MAX(identity.confirmed, excluded.confirmed)
            """, [.text(key), .text(value), .integer(confirmed ? 1 : 0), .text(source)])
    }

    public func identityFacts(confirmedOnly: Bool = true) throws -> [IdentityFact] {
        let sql = confirmedOnly
            ? "SELECT key, value, confirmed, source FROM identity WHERE confirmed = 1 ORDER BY key"
            : "SELECT key, value, confirmed, source FROM identity ORDER BY key"
        return try database.query(sql).map {
            IdentityFact(key: $0.string("key") ?? "",
                         value: $0.string("value") ?? "",
                         confirmed: ($0.int("confirmed") ?? 0) != 0,
                         source: $0.string("source") ?? "manual")
        }
    }

    /// Keys holding more than one confirmed value — the conflicts an import
    /// deliberately preserves rather than resolving on the user's behalf.
    public func conflictingIdentityKeys() throws -> [String] {
        try database.query("""
            SELECT key FROM identity WHERE confirmed = 1
            GROUP BY key HAVING COUNT(*) > 1
            """).compactMap { $0.string("key") }
    }

    public func deleteIdentity(key: String, value: String) throws {
        try database.execute("DELETE FROM identity WHERE key = ? AND value = ?",
                             [.text(key), .text(value)])
    }

    // MARK: - Corrections

    public func recordCorrection(wrong: String, right: String) throws {
        try database.execute("""
            INSERT INTO correction (wrong, right, count) VALUES (?, ?, 1)
            ON CONFLICT(wrong, right) DO UPDATE SET count = count + 1
            """, [.text(wrong), .text(right)])
    }

    public struct CorrectionPair {
        public let wrong: String
        public let right: String
        public let count: Int
    }

    public func correction(for wrong: String) throws -> CorrectionPair? {
        try database.query("""
            SELECT wrong, right, count FROM correction
            WHERE wrong = ? ORDER BY count DESC LIMIT 1
            """, [.text(wrong)]).first.map {
                CorrectionPair(wrong: $0.string("wrong") ?? "",
                               right: $0.string("right") ?? "",
                               count: Int($0.int("count") ?? 0))
            }
    }

    public func allCorrections() throws -> [CorrectionPair] {
        try database.query("SELECT wrong, right, count FROM correction ORDER BY count DESC")
            .map {
                CorrectionPair(wrong: $0.string("wrong") ?? "",
                               right: $0.string("right") ?? "",
                               count: Int($0.int("count") ?? 0))
            }
    }

    // MARK: - Feedback

    public func recordShown(origin: CandidateOrigin, app: String) throws {
        try database.execute("""
            INSERT INTO feedback (origin, app, shown) VALUES (?, ?, 1)
            ON CONFLICT(origin, app) DO UPDATE SET shown = shown + 1
            """, [.text(origin.rawValue), .text(app)])
    }

    public func recordAccepted(origin: CandidateOrigin, app: String, charactersSaved: Int) throws {
        try database.execute("""
            INSERT INTO feedback (origin, app, shown, accepted, chars_saved)
            VALUES (?, ?, 0, 1, ?)
            ON CONFLICT(origin, app) DO UPDATE SET
                accepted = accepted + 1,
                chars_saved = chars_saved + excluded.chars_saved
            """, [.text(origin.rawValue), .text(app), .integer(Int64(charactersSaved))])
    }

    /// Observed acceptance rate for an origin, or nil when there is not enough
    /// evidence yet. Used to calibrate probabilities against reality instead of
    /// trusting each source's self-reported confidence forever.
    /// Shown and accepted counts for every origin, in one query.
    ///
    /// One round trip rather than one per source: this is read on the prediction
    /// path, where six separate queries per keystroke would be six chances to
    /// stall behind a write.
    public func acceptanceCounts() throws -> [CandidateOrigin: (shown: Int, accepted: Int)] {
        var result: [CandidateOrigin: (shown: Int, accepted: Int)] = [:]
        for row in try database.query("""
            SELECT origin, SUM(shown) AS shown, SUM(accepted) AS accepted
            FROM feedback GROUP BY origin
            """) {
            guard let name = row.string("origin"),
                  let origin = CandidateOrigin(rawValue: name) else { continue }
            result[origin] = (Int(row.int("shown") ?? 0), Int(row.int("accepted") ?? 0))
        }
        return result
    }

    public func acceptanceRate(origin: CandidateOrigin, app: String, minimumShown: Int = 20) throws -> Double? {
        let rows = try database.query("""
            SELECT COALESCE(SUM(shown), 0) AS shown, COALESCE(SUM(accepted), 0) AS accepted
            FROM feedback WHERE origin = ? AND (app = ? OR ? = '')
            """, [.text(origin.rawValue), .text(app), .text(app)])
        guard let row = rows.first else { return nil }
        let shown = Int(row.int("shown") ?? 0)
        let accepted = Int(row.int("accepted") ?? 0)
        guard shown >= minimumShown else { return nil }
        return Double(accepted) / Double(shown)
    }

    public func totalCharactersSaved() throws -> Int {
        Int(try database.query("SELECT COALESCE(SUM(chars_saved), 0) AS total FROM feedback")
            .first?.int("total") ?? 0)
    }

    // MARK: - Maintenance

    /// Removes words that never proved themselves — the typos and the fragments
    /// left by dropped keystrokes. Their n-grams go too, otherwise the statistics
    /// would still point at words that no longer exist.
    @discardableResult
    public func forgetUnverified(seenFewerThan threshold: Int) throws -> Int {
        let doomed = try database.query(
            "SELECT id FROM vocab WHERE kind = 'unverified' AND count < ?",
            [.integer(Int64(threshold))]).compactMap { $0.int("id") }
        guard !doomed.isEmpty else { return 0 }

        let list = doomed.map(String.init).joined(separator: ",")
        try database.execute(
            "DELETE FROM ngram WHERE next_id IN (\(list)) OR prev1 IN (\(list)) OR prev2 IN (\(list))")
        try database.execute("DELETE FROM vocab WHERE id IN (\(list))")
        return doomed.count
    }

    public func setCount(_ word: String, _ count: Int) throws {
        try database.execute("UPDATE vocab SET count = ? WHERE word = ?",
                             [.integer(Int64(count)), .text(word)])
    }

    public func wipe() throws {
        for table in ["vocab", "ngram", "snippet", "identity", "correction", "feedback"] {
            try database.execute("DELETE FROM \(table)")
        }
    }
}
