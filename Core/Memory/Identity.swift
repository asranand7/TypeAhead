import Foundation

/// Tier 1: the facts about you that are long, exact, and retyped constantly.
///
/// Highest savings per byte in the whole app — an email address is thirty
/// characters that never vary. Also the most sensitive tier, which is why
/// detection *never* stores anything silently: a candidate sits unconfirmed until
/// the user says yes, and the export review can drop the tier wholesale.
public final class IdentityDetector: TypingObserver {
    /// Times a fact must appear before the user is asked about it. Once is a
    /// mention; three times is a fact about them.
    public static let promptThreshold = 3

    public enum Kind: String, CaseIterable {
        case email
        case phone
        case url

        var pattern: String {
            switch self {
            case .email:
                return #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
            case .phone:
                // Deliberately conservative: 10+ digits with optional separators
                // and country code. Loose patterns here would harvest order
                // numbers and OTPs, which is exactly what must not happen.
                return #"(?:\+\d{1,3}[ -]?)?(?:\d[ -]?){9,14}\d"#
            case .url:
                return #"https?://[^\s]{4,}"#
            }
        }
    }

    private let store: Store
    private let lock = NSLock()
    private var sightings: [String: (kind: Kind, count: Int)] = [:]
    private var buffer = ""

    /// Called when a fact has been seen often enough to be worth asking about.
    /// The UI presents it; nothing is stored until the answer comes back.
    public var onCandidate: ((Kind, String) -> Void)?

    public init(store: Store) {
        self.store = store
    }

    public func observe(_ signal: TypingSignal) {
        switch signal {
        case .typed(let characters):
            accumulate(characters)
        case .caretMoved:
            lock.lock(); buffer = ""; lock.unlock()
        default:
            break
        }
    }

    private func accumulate(_ characters: String) {
        lock.lock()
        buffer += characters
        // Long enough to hold an email or an address line, short enough to scan
        // on every keystroke without being felt.
        if buffer.count > 120 { buffer.removeFirst(buffer.count - 120) }
        let snapshot = buffer
        lock.unlock()

        // Only scan when the user has just finished a token; scanning mid-word
        // would match prefixes of things that are not yet what they will become.
        guard let last = characters.unicodeScalars.last,
              !ContextReader.isWordCharacter(last) else { return }

        for kind in Kind.allCases {
            for match in IdentityDetector.matches(of: kind, in: snapshot) {
                note(kind: kind, value: match)
            }
        }
    }

    private func note(kind: Kind, value: String) {
        // Already known and confirmed: nothing to ask.
        if let existing = try? store.identityFacts(confirmedOnly: true),
           existing.contains(where: { $0.value == value }) {
            return
        }

        lock.lock()
        let count = (sightings[value]?.count ?? 0) + 1
        sightings[value] = (kind, count)
        let reached = count == IdentityDetector.promptThreshold
        lock.unlock()

        guard reached else { return }
        // Recorded unconfirmed so the prompt survives a restart, but it is
        // invisible to suggestions and to export until the user confirms.
        try? store.setIdentity(kind.rawValue, value, confirmed: false, source: "detected")
        onCandidate?(kind, value)
    }

    static func matches(of kind: Kind, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: kind.pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let value = String(text[matchRange]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    /// Confirms a detected fact, making it usable and exportable.
    public func confirm(kind: Kind, value: String) throws {
        try store.setIdentity(kind.rawValue, value, confirmed: true, source: "detected")
    }

    public func reject(kind: Kind, value: String) throws {
        try store.deleteIdentity(key: kind.rawValue, value: value)
    }
}

/// Offers identity values as completions.
///
/// Typing "asr" offers the rest of the email. These are the highest-value
/// suggestions in the app: thirty characters for one Tab.
public final class IdentitySource: SuggestionSource {
    public let name = "Identity"

    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    public func suggest(_ context: TypingContext) -> [Candidate] {
        let prefix = context.currentWordPrefix
        guard prefix.count >= 3 else { return [] }
        guard let facts = try? store.identityFacts(confirmedOnly: true) else { return [] }

        return facts.compactMap { fact in
            guard fact.value.count > prefix.count else { return nil }
            guard fact.value.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
            // Exact, user-confirmed, and unambiguous once three characters match —
            // about as certain as this app gets.
            return Candidate(text: String(fact.value.dropFirst(prefix.count)),
                             probability: 0.9,
                             origin: .identity)
        }
    }
}
