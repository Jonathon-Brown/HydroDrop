#if DUO_V2
import DeviceCheck
import Foundation

/// The one call of `DCDevice` Duo makes, behind a protocol so a test can stand in for it. The
/// simulator reports unsupported; a real token comes only from a real iPhone.
protocol DCDeviceProviding: Sendable {
    var isSupported: Bool { get }
    func generateToken() async throws -> Data
}

/// The system's DeviceCheck. `DCDevice.current` is asked for at each call and never kept.
struct DuoSystemDevice: DCDeviceProviding {
    var isSupported: Bool { DCDevice.current.isSupported }

    func generateToken() async throws -> Data {
        try await DCDevice.current.generateToken()
    }
}

/// DeviceCheck for Duo (final design §11.2): a fresh `DCDevice` token for the body of the
/// requests the server queries the two bits from, `POST /devices`, `DELETE /me` and optionally
/// `POST /invites/redeem`. The joining and exit services ask for one at the moment the body is
/// built, after the tap that started the request, and never before (§3.1).
///
/// A token is per request, and nothing here keeps, logs or shows one. The phone holds it only
/// inside the in-flight record of a request still waiting for its answer, at most 23 hours
/// (D62), which is the journal's business, not this file's; it is never in Diagnostics.
final class DuoDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    private let device: DCDeviceProviding

    convenience init() {
        self.init(device: DuoSystemDevice())
    }

    init(device: DCDeviceProviding) {
        self.device = device
    }

    var isSupported: Bool { device.isSupported }

    /// Standard base64 with its padding, which is what the contract's pattern
    /// `^[A-Za-z0-9+/]+={0,2}$` asks for (not the base64url of an App Attest token). Nil where
    /// DeviceCheck is unsupported or fails, and the request then goes without one: the field is
    /// optional, and a phone that cannot prove itself is not refused for it.
    func token() async -> String? {
        guard device.isSupported else { return nil }
        guard let data = try? await device.generateToken(), !data.isEmpty else { return nil }
        return data.base64EncodedString()
    }
}
#endif
