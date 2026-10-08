#if DUO_V2
import DeviceCheck
import Foundation

/// The three calls of `DCAppAttestService` Duo makes, and whether it can make them, behind a
/// protocol so a test can stand in for the Secure Enclave. The simulator reports unsupported,
/// and a real key can only ever be made and attested on a real iPhone.
protocol DCAppAttestServicing: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// The system's App Attest service. `DCAppAttestService.shared` is asked for at each call and
/// never kept, and nothing here runs until a call is made.
struct DuoSystemAppAttestService: DCAppAttestServicing {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// Why an attestation or an assertion could not be made. None of them carries a key id, a
/// hash or a token, so one can be recorded in Diagnostics as it stands.
enum DuoAttestationError: Error, Equatable {
    /// This phone cannot attest (the simulator, an older device, App Attest switched off): the
    /// request goes without a header, at the low tier (§11.2).
    case unsupported
    /// No key is stored for the device, so there is nothing to assert with. The API client
    /// attests a new key instead, which is also how the server learns the one it lacks.
    case noKey
    /// The system no longer has the stored key. App Attest keys do not outlive the app, while
    /// the Keychain item naming one does, so after a delete-and-reinstall the id still read
    /// back and every assertion failed. The stale id is forgotten, so the next attempt brings
    /// a new key and its attestation.
    case invalidKey
}

/// App Attest for Duo (final design §11.2): one key per identity, attested once over the bind
/// of the request that introduces it, then used for assertions.
///
/// A key can be attested only once, so nothing here ever attests a stored key again: a new
/// identity, and a retry after an `attest_invalid` that answered an assertion, each bring a
/// new key. A key id is useless on another phone, so it is kept `ThisDeviceOnly`.
///
/// Consent (§3.1): nothing in this file runs until the API client asks, which it does only for
/// an attested request, which a phone makes only after a Create, Join or Reconnect tap has
/// given it an identity (§3.1). No key is made at init and reading `isSupported` changes nothing.
final class DuoAppAttest: DuoAttesting, @unchecked Sendable {
    private let secrets: DuoSecrets
    private let service: DCAppAttestServicing

    convenience init(secrets: DuoSecrets) {
        self.init(secrets: secrets, service: DuoSystemAppAttestService())
    }

    init(secrets: DuoSecrets, service: DCAppAttestServicing) {
        self.secrets = secrets
        self.service = service
    }

    var isSupported: Bool { service.isSupported }

    func hasKey(forDevice deviceID: String) -> Bool {
        storedKeyID(account: DuoSecrets.attestKeyAccount(deviceID: deviceID)) != nil
    }

    /// Makes a key, attests it over `clientDataHash` and keeps its id as pending, for
    /// `adoptPendingKey` once the server has accepted it. The id is kept only after the
    /// attestation exists, so a failed attestation leaves no pending id behind; and if the id
    /// cannot be kept the call fails, since a token whose key this phone could not find again
    /// would raise the server's tier for one request and leave every later assertion keyless.
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        guard service.isSupported else { throw DuoAttestationError.unsupported }
        let keyID = try await service.generateKey()
        let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
        try secrets.store.write(Data(keyID.utf8), service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount,
                                accessibility: .afterFirstUnlockThisDeviceOnly)
        return DuoAttestationToken(token: Self.base64URL(attestation), keyID: keyID, kind: .attestation)
    }

    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        guard service.isSupported else { throw DuoAttestationError.unsupported }
        let account = DuoSecrets.attestKeyAccount(deviceID: deviceID)
        guard let keyID = storedKeyID(account: account) else { throw DuoAttestationError.noKey }
        do {
            let assertion = try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
            return DuoAttestationToken(token: Self.base64URL(assertion), keyID: keyID, kind: .assertion)
        } catch let error as DCError where error.code == .invalidKey {
            try? secrets.store.delete(service: DuoSecrets.service, account: account)
            throw DuoAttestationError.invalidKey
        }
    }

    /// Only the key that is pending is adopted: a pending id that differs belongs to a later
    /// attempt (a retry that re-keyed), and adopting the older one would leave this phone
    /// asserting with a key the server has since replaced.
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) {
        guard storedKeyID(account: DuoSecrets.pendingAttestKeyAccount) == keyID else { return }
        do {
            try secrets.store.write(Data(keyID.utf8), service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: deviceID),
                                    accessibility: .afterFirstUnlockThisDeviceOnly)
            try secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount)
        } catch {
            // Left pending: the next assertion finds no key and the API client attests a new
            // one, which replaces the server's copy. Nothing is lost but one request's tier.
        }
    }

    func forgetKeys(forDevice deviceID: String) {
        try? secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: deviceID))
        try? secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount)
    }

    // MARK: - Plumbing

    /// A key id, or nil for none. An item that cannot be read (before the first unlock) is
    /// none too: the worst that follows is a new key, which the server takes in place of the
    /// old one.
    private func storedKeyID(account: String) -> String? {
        guard let data = (try? secrets.store.read(service: DuoSecrets.service, account: account)) ?? nil,
              let keyID = String(data: data, encoding: .utf8), !keyID.isEmpty else { return nil }
        return keyID
    }

    /// Unpadded base64url, as `X-HD-Attest` carries a token (§11.2): the server refuses padded
    /// or non-canonical spellings as `attest_invalid`.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
