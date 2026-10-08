#if DUO_V2
import Foundation
import Security

/// Duo's secrets in the Keychain (final design §3.2, §4.1, §11.2): generic password items keyed
/// by service and account, which is all `DuoSecrets` asks of a store.
///
/// - Never synchronizable. An iCloud Keychain copy of the credential would make two phones one
///   member and bring back the iCloud dependency v2 exists to drop; the restore path (§3.4) is
///   built on the credential arriving by backup or Quick Start without its marker, never by sync.
/// - No access group, no access control and no biometrics: the items are the app's own, read
///   by the app at launch and in the background, after the first unlock.
/// - The accessibility is the caller's: `afterFirstUnlock` for the credential and the link
///   secrets, which must come back with a restore, and `afterFirstUnlockThisDeviceOnly` for the
///   install marker, the attestation key ids and the age refusal, which never move to another
///   phone (an encrypted backup restored onto the same phone does bring them back).
final class KeychainDuoSecretStore: DuoSecretStore, @unchecked Sendable {
    init() {}

    func read(service: String, account: String) throws -> Data? {
        var query = Self.itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // An item with no data reads as the empty value it is, not as a missing one.
            return (result as? Data) ?? Data()
        case errSecItemNotFound:
            return nil
        default:
            // Anything else (`errSecInteractionNotAllowed` before the first unlock after a
            // restart, above all) is not "absent": a caller that took it for absent would mint a
            // second identity, or take a phone with a credential for a restored one.
            throw DuoKeychainError(status: status)
        }
    }

    /// Adds the item, or replaces the data and accessibility of the one already there. An
    /// update rather than a delete and an add, so a crash in between can never leave the
    /// credential gone.
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        var attributes = Self.itemQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = Self.accessibleAttribute(accessibility)
        let added = SecItemAdd(attributes as CFDictionary, nil)
        switch added {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let changes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: Self.accessibleAttribute(accessibility),
            ]
            let updated = SecItemUpdate(Self.itemQuery(service: service, account: account) as CFDictionary, changes as CFDictionary)
            guard updated == errSecSuccess else { throw DuoKeychainError(status: updated) }
        default:
            throw DuoKeychainError(status: added)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DuoKeychainError(status: status) }
    }

    /// Removes every item whose service is exactly `service`. The Keychain matches
    /// `kSecAttrService` as a whole value, never as a prefix, and that is what keeps the age
    /// refusal (`us.hydrodrop.duo.age`) alive through Delete my Duo data and "Start fresh",
    /// which end with `deleteAll(service: "us.hydrodrop.duo")` (SC §3.6 item 5, D60). On iOS
    /// one `SecItemDelete` removes every match. Synchronizable items are matched too, though
    /// this store never writes one, so a wipe leaves nothing under the name whatever made it.
    func deleteAll(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DuoKeychainError(status: status) }
    }

    // MARK: - Plumbing

    /// One item: a generic password under exactly this service and account, never synchronizable.
    /// Saying `false` in every query, not leaving it out, is what keeps an add from ever making a
    /// synchronizable item and a read from ever finding one.
    static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static func accessibleAttribute(_ accessibility: DuoSecretAccessibility) -> CFString {
        switch accessibility {
        case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// A Keychain call that failed, with its `OSStatus` and nothing else: no service, account or
/// data, so the error can be recorded or shown without saying what the item held.
struct DuoKeychainError: Error, Equatable {
    let status: OSStatus
}
#endif
