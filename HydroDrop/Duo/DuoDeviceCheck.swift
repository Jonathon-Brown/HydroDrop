#if DUO_V2
import Foundation

// STUB (foundation). Stage B replaces this whole file with the DCDevice wrapper.

final class DuoDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    init() {}
    var isSupported: Bool { false }
    func token() async -> String? { nil }
}
#endif
