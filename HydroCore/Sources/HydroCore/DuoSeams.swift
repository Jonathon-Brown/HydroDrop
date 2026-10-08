import Foundation

// The few things Duo's logic must be able to swap for a fake in a test: what time it is,
// where random numbers come from, and where secrets are kept. Everything else Duo needs is
// either a value or one of the protocols in `DuoTransport.swift` and the app's
// `DuoServices.swift`.

public protocol DuoClock: Sendable {
    var now: Date { get }
    /// The calendar a day key is read in. Always the device's own (§8.4): "today" is
    /// evaluated at each call, never cached across midnight.
    var calendar: Calendar { get }
}

public extension DuoClock {
    /// Today's day key in `calendar`.
    var today: String { DayKey.key(for: now, calendar: calendar) }
}

public struct DuoSystemClock: DuoClock {
    public init() {}
    public var now: Date { Date() }
    public var calendar: Calendar { Calendar.current }
}

public protocol DuoRandom: Sendable {
    func bytes(_ count: Int) -> [UInt8]
    func uuid() -> UUID
}

public struct DuoSystemRandom: DuoRandom {
    public init() {}

    public func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    public func uuid() -> UUID { UUID() }
}

/// How a secret is kept: after the first unlock, and either free to move to another phone
/// in a backup or not. The credential survives a restore (so a reinstall can notice it);
/// the install marker never does, which is how a restore is told from a normal launch (§3.2).
public enum DuoSecretAccessibility: Sendable {
    case afterFirstUnlock
    case afterFirstUnlockThisDeviceOnly
}

/// A small keyed store for secrets: the Keychain in the app, a dictionary in a test. Never
/// synchronizable, so an iCloud Keychain clone cannot make two devices one member (§3.2).
public protocol DuoSecretStore: AnyObject, Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws
    func delete(service: String, account: String) throws
    /// Removes every item kept under `service`, whatever its account. Delete my Duo data and
    /// "Start fresh" end with this, so an item for a duo that left the cache by another route,
    /// or an attestation key under another device's id, cannot outlive the wipe.
    func deleteAll(service: String) throws
}

public final class DuoMemorySecretStore: DuoSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items["\(service)/\(account)"]
    }

    public func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        lock.lock(); defer { lock.unlock() }
        items["\(service)/\(account)"] = data
    }

    public func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items["\(service)/\(account)"] = nil
    }

    public func deleteAll(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        items = items.filter { !$0.key.hasPrefix("\(service)/") }
    }

    /// The accounts held under `service`, for a test that checks a wipe left nothing behind.
    public func accounts(service: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(service)/"
        return items.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }
}

/// The names Duo keeps its secrets under, and the typed way to read and write them. One
/// Keychain service, `us.hydrodrop.duo`, with one account per item (§3.2).
public struct DuoSecrets: Sendable {
    public static let service = "us.hydrodrop.duo"
    public static let deviceAccount = "device"
    public static let installMarkerAccount = "install-marker"
    /// One link secret per duo, `k.<lowercase duo id>` (§4.1).
    public static func linkSecretAccount(duoID: UUID) -> String { "k.\(duoID.uuidString.lowercased())" }
    /// One App Attest key id per device, `attest.<device id>`; and the key waiting for the
    /// identity it was made for, `attest.pending` (§11.2).
    public static func attestKeyAccount(deviceID: String) -> String { "attest.\(deviceID)" }
    public static let pendingAttestKeyAccount = "attest.pending"
    /// The refusal of the birth-year screen, kept apart from everything above: a separate
    /// Keychain service, so `deleteEverything` (Delete my Duo data, "Start fresh") leaves it.
    /// The App Group's defaults go with the app when it is deleted, and a refusal that deleting
    /// and reinstalling undoes is no refusal (SC §3.6 item 5, D60: the age gate is what stops a
    /// restart). The Keychain outlives a reinstall on the same phone, as the credential does
    /// (§3.2), and is `ThisDeviceOnly`, so it never moves to another phone in a backup.
    public static let ageService = "us.hydrodrop.duo.age"
    public static let ageRefusedAccount = "refused"

    public let store: DuoSecretStore

    public init(store: DuoSecretStore) {
        self.store = store
    }

    public func credential() -> DuoCredential? {
        guard let data = try? store.read(service: Self.service, account: Self.deviceAccount) else { return nil }
        return try? JSONDecoder().decode(DuoCredential.self, from: data)
    }

    /// Kept after first unlock and not tied to this device, so it comes back with a restore.
    public func save(_ credential: DuoCredential) throws {
        try store.write(try JSONEncoder().encode(credential), service: Self.service, account: Self.deviceAccount,
                        accessibility: .afterFirstUnlock)
    }

    public func deleteCredential() throws {
        try store.delete(service: Self.service, account: Self.deviceAccount)
    }

    public func hasInstallMarker() -> Bool {
        ((try? store.read(service: Self.service, account: Self.installMarkerAccount)) ?? nil) != nil
    }

    /// Random bytes that only this phone ever has, so a credential found without them came
    /// from somewhere else.
    public func writeInstallMarker(random: DuoRandom) throws {
        try store.write(Data(random.bytes(16)), service: Self.service, account: Self.installMarkerAccount,
                        accessibility: .afterFirstUnlockThisDeviceOnly)
    }

    public func linkSecret(forDuo duoID: UUID) -> String? {
        guard let data = (try? store.read(service: Self.service, account: Self.linkSecretAccount(duoID: duoID))) ?? nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveLinkSecret(_ k: String, forDuo duoID: UUID) throws {
        try store.write(Data(k.utf8), service: Self.service, account: Self.linkSecretAccount(duoID: duoID), accessibility: .afterFirstUnlock)
    }

    public func deleteLinkSecret(forDuo duoID: UUID) throws {
        try store.delete(service: Self.service, account: Self.linkSecretAccount(duoID: duoID))
    }

    /// Everything Duo keeps in the Keychain: the credential, the install marker, every link
    /// secret and every attestation key. Not the age refusal, which is another service.
    public func deleteEverything() throws {
        try store.deleteAll(service: Self.service)
    }

    public func isAgeRefused() -> Bool {
        ((try? store.read(service: Self.ageService, account: Self.ageRefusedAccount)) ?? nil) != nil
    }

    /// Only the fact, never the year: a single byte.
    public func markAgeRefused() throws {
        try store.write(Data([1]), service: Self.ageService, account: Self.ageRefusedAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
    }
}

/// What this build says about itself in `X-HD-Client` and `app_version` (§6.0): the client
/// header matches `^(ios|android)/[0-9]+(\.[0-9]+){1,2} \([0-9]+\)$`, and a value that does
/// not parse is never refused but cannot tell the server its version either.
public struct DuoClientInfo: Equatable, Sendable {
    public var marketingVersion: String
    public var build: String

    public init(marketingVersion: String, build: String) {
        self.marketingVersion = marketingVersion
        self.build = build
    }

    /// `ios/2.0 (57)`.
    public var clientHeader: String { "ios/\(marketingVersion) (\(build))" }
    /// `2.0 (57)`, the body's `app_version`.
    public var appVersion: String { "\(marketingVersion) (\(build))" }
}
