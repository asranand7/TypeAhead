import Contacts
import Foundation

/// Seeds the identity tier from the Mac's own "me" card.
///
/// The cold-start problem in its sharpest form. An email address is the highest
/// savings-per-byte string in the whole app — thirty exact characters that never
/// vary — and the detector will not offer one until it has watched the user type
/// it three times. That is three repetitions of precisely the work the app exists
/// to remove, to learn something the machine already knows: `CNContactStore` has
/// had the answer since the account was set up.
///
/// ## Consent is preserved, not bypassed
///
/// Seeded facts are written **unconfirmed**, exactly as detected ones are. They
/// are invisible to suggestions and to export until the user says yes, and they
/// arrive through the same review prompt. Reading the me card is not the same as
/// deciding on the user's behalf that their work address should be offered while
/// they are typing, and this tier is the one place where guessing wrong is
/// expensive.
///
/// Runs once. If the user rejects a seeded fact it must stay rejected, and
/// re-seeding on every launch would resurrect it.
public enum ContactSeed {
    private static let seededKey = "TypeAhead.identity.seededFromContacts"

    /// Whether the user has already been asked for Contacts access.
    ///
    /// Checked rather than assumed, so a first run never blocks on a permission
    /// dialog the user has not chosen to engage with.
    public static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Reads the me card and records what it finds as unconfirmed candidates.
    ///
    /// - Parameter ask: whether to request access if it has not been asked for.
    ///   The menu-bar item passes true; the first-run path passes false.
    /// - Returns: the facts recorded, for the caller to present for confirmation.
    @discardableResult
    public static func seed(into store: Store,
                            defaults: UserDefaults = .standard,
                            ask: Bool = false,
                            completion: (([(IdentityDetector.Kind, String)]) -> Void)? = nil)
        -> Bool {
        guard !defaults.bool(forKey: seededKey) else { return false }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            break
        case .notDetermined where ask:
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    _ = seed(into: store, defaults: defaults, ask: false, completion: completion)
                }
            }
            return false
        default:
            // Denied, restricted, or not yet asked. Not an error: the detector
            // still learns these facts the slow way.
            return false
        }

        guard let card = try? CNContactStore().unifiedMeContactWithKeys(toFetch: [
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]) else { return false }

        defaults.set(true, forKey: seededKey)

        var recorded: [(IdentityDetector.Kind, String)] = []
        for email in card.emailAddresses {
            let value = (email.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            try? store.setIdentity(IdentityDetector.Kind.email.rawValue, value,
                                   confirmed: false, source: "contacts")
            recorded.append((.email, value))
        }
        for phone in card.phoneNumbers {
            let value = phone.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            try? store.setIdentity(IdentityDetector.Kind.phone.rawValue, value,
                                   confirmed: false, source: "contacts")
            recorded.append((.phone, value))
        }

        guard !recorded.isEmpty else { return false }
        completion?(recorded)
        return true
    }
}
