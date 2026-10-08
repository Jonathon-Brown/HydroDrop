#if DUO_V2
import Foundation

// STUB (foundation). Stage B replaces this whole file with the Security-framework store.

final class KeychainDuoSecretStore: DuoSecretStore, @unchecked Sendable {
    private let memory = DuoMemorySecretStore()
    init() {}
    func read(service: String, account: String) throws -> Data? { try memory.read(service: service, account: account) }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}
#endif
