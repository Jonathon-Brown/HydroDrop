#if DUO_V2
import Foundation

// STUB (foundation). Stage B replaces this whole file with the DCAppAttestService wrapper.

final class DuoAppAttest: DuoAttesting, @unchecked Sendable {
    init(secrets: DuoSecrets) {}
    var isSupported: Bool { false }
    func hasKey(forDevice deviceID: String) -> Bool { false }
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken { throw DuoTransportError.offline }
    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken { throw DuoTransportError.offline }
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) {}
    func forgetKeys(forDevice deviceID: String) {}
}
#endif
