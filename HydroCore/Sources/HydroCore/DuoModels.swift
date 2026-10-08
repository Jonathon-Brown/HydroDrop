import Foundation

// The small value types Duo v2's client shares between its parts: what a duo's header says
// about how it ended, the invite a person made or was sent, the queued request that must
// survive a relaunch, and the states the Duo screen is drawn from. Value types only, so
// every one of them can be tested without a network or a device. Final design §14.

/// Who or what ended a duo (the contract's `ended_by`, plus `unknown`).
///
/// `unknown` is the client's own: a request that answered `duo_unknown` for a duo this phone
/// has cached means the server no longer has it, so the card says it ended and nothing else
/// (§6.7: "mark ended locally (`ended_by = unknown`), no alert"). It is also what any value a
/// newer server sends that this build has never heard of decodes to.
public enum DuoEndedBy: String, Codable, Equatable, Sendable {
    case owner
    case partner
    case ownerDeleted = "owner_deleted"
    case partnerDeleted = "partner_deleted"
    case inactive
    case demoExpired = "demo_expired"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DuoEndedBy(rawValue: raw) ?? .unknown
    }
}

/// An invite this phone made and still holds, so the owner can show the code and the QR
/// again. The server never gives a code back (§6.4, SEC F9), so a reinstalled owner has
/// none and sees "Make a new code". The link's secret `k` is not here: it lives in the
/// Keychain, one item per duo (`DuoSecrets`), never sent to the server (§4.1).
public struct DuoInvite: Codable, Equatable, Sendable {
    /// Canonical: eight characters of `0-9A-HJKMNP-TV-Z`.
    public var code: String
    /// The same, shown as `H7K3-9QWX`.
    public var display: String
    public var expiresAt: Date

    public init(code: String, display: String, expiresAt: Date) {
        self.code = code
        self.display = display
        self.expiresAt = expiresAt
    }

    public func isOpen(now: Date) -> Bool { expiresAt > now }
}

/// A leave or block that is queued and not yet sent. An offline Leave shows the ended card
/// at once with this set (§10.1).
public enum DuoPendingOp: String, Codable, Equatable, Sendable {
    case leave
    case block
}

/// Days the server refused for a reason that will not change by itself, per duo.
///
/// `unsent` skips a day whose wanted status says the same as the row the server refused, so
/// a day out of range, after today or inconsistent is not sent on every flush for ever. A
/// change in the wanted status clears the entry; entries older than nine days are dropped.
/// Never used for `ver_conflict` or `downgrade_refused`, which carry `current` and are
/// settled by re-basing (§10.2, §10.3, vector KV10).
public struct DuoRejectedDays: Codable, Equatable, Sendable {
    public static let keepDays = 9

    /// Day to the row that was refused.
    public private(set) var rows: [String: DuoDayStatus]

    public init(rows: [String: DuoDayStatus] = [:]) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }

    public mutating func record(_ refused: DuoDayStatus) {
        rows[refused.day] = refused
    }

    /// Whether `wanted` is the very row the server already refused.
    public func blocks(_ wanted: DuoDayStatus) -> Bool {
        guard let refused = rows[wanted.day] else { return false }
        return refused.saysTheSame(as: wanted)
    }

    /// Forgets every entry whose day now wants something else, and every entry too old to
    /// matter. `wanted` is what the log says each recent day should be right now.
    public mutating func settle(against wanted: [DuoDayStatus], myToday: String) {
        let wantedByDay = Dictionary(wanted.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let oldest = DayKey.date(from: myToday, calendar: Self.utc)
            .flatMap { Self.utc.date(byAdding: .day, value: -Self.keepDays, to: $0) }
            .map { DayKey.key(for: $0, calendar: Self.utc) }
        rows = rows.filter { day, refused in
            if let oldest, day < oldest { return false }
            guard let now = wantedByDay[day] else { return true }
            return refused.saysTheSame(as: now)
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

/// A device's credential, the three things a bearer is made of (§3.1).
public struct DuoCredential: Codable, Equatable, Sendable {
    public var memberID: String
    public var deviceID: String
    public var deviceSecret: String
    public var secretVersion: Int

    public init(memberID: String, deviceID: String, deviceSecret: String, secretVersion: Int = 1) {
        self.memberID = memberID
        self.deviceID = deviceID
        self.deviceSecret = deviceSecret
        self.secretVersion = secretVersion
    }

    /// `Authorization: Bearer <device_id>.<device_secret>`, split at the first `.` by the server.
    public var bearer: String { "\(deviceID).\(deviceSecret)" }
}

public enum DuoTier: String, Codable, Equatable, Sendable {
    case attested
    case low

    /// A tier this client does not know (a newer server's) reads as the conservative one. It
    /// used to fail the whole `GET /me` and `POST /devices` decode, which made every refresh
    /// fail as unreadable for a field that only picks a nudge limit.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DuoTier(rawValue: raw) ?? .low
    }
}

/// One device of the member, as `GET /me` lists them (§3.5, D45).
public struct DuoDeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var platform: String
    public var createdAt: Date
    public var thisDevice: Bool
    public var superseded: Bool

    public init(id: String, platform: String, createdAt: Date, thisDevice: Bool, superseded: Bool) {
        self.id = id
        self.platform = platform
        self.createdAt = createdAt
        self.thisDevice = thisDevice
        self.superseded = superseded
    }
}

/// What `GET /me` last said about this person. Cached so the Duo screen can show the
/// Support ID and the limits before the next fetch, and so the app can tell when a new
/// device has appeared (D45).
public struct DuoMemberInfo: Codable, Equatable, Sendable {
    public var memberID: String
    public var displayName: String?
    public var skin: String?
    public var supportID: String
    public var tier: DuoTier
    public var termsVersion: Int
    public var nudgesPerDay: Int
    public var maxActiveDuos: Int
    public var devices: [DuoDeviceInfo]
    public var minClientIOS: String?
    public var updatedAt: Date

    public init(memberID: String, displayName: String?, skin: String?, supportID: String, tier: DuoTier, termsVersion: Int,
                nudgesPerDay: Int, maxActiveDuos: Int, devices: [DuoDeviceInfo], minClientIOS: String?, updatedAt: Date) {
        self.memberID = memberID
        self.displayName = displayName
        self.skin = skin
        self.supportID = supportID
        self.tier = tier
        self.termsVersion = termsVersion
        self.nudgesPerDay = nudgesPerDay
        self.maxActiveDuos = maxActiveDuos
        self.devices = devices
        self.minClientIOS = minClientIOS
        self.updatedAt = updatedAt
    }

    /// `XXXX-XXXX-XXXX`, as Diagnostics and the report mail show it (§3.7).
    public var supportIDDisplay: String {
        let id = supportID
        guard id.count == 12 else { return id }
        let chunks = stride(from: 0, to: 12, by: 4).map { start -> String in
            let begin = id.index(id.startIndex, offsetBy: start)
            return String(id[begin..<id.index(begin, offsetBy: 4)])
        }
        return chunks.joined(separator: "-")
    }
}

/// An invite this phone was sent (a link, a QR code or a typed code) and has not joined
/// yet. Persisted before the join sheet opens and dropped after 48 hours or on redeem, so
/// a kill during onboarding loses nothing (§4.1, §4.3).
public struct DuoPendingInvite: Codable, Equatable, Sendable, Identifiable {
    public static let lifetime: TimeInterval = 48 * 60 * 60

    public var code: String
    /// The link's secret, kept verbatim and never sent to the server. Nil for a typed code.
    /// It lives in memory only: it is not encoded, so it never reaches the App Group defaults,
    /// which the widget can read and which an unencrypted backup carries, and §4.1 keeps `k` in
    /// the Keychain, where the join saves it at the tap. A kill before that tap leaves a
    /// pending invite without it, which joins as a typed code does (`e2ee_capable` false).
    public var k: String?
    public var receivedAt: Date

    private enum CodingKeys: String, CodingKey { case code, receivedAt }

    public var id: String { code }

    public init(code: String, k: String?, receivedAt: Date) {
        self.code = code
        self.k = k
        self.receivedAt = receivedAt
    }

    public func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) >= Self.lifetime
    }
}

/// What a peek told this phone about an invite, for the join sheet to show.
public struct DuoPeek: Equatable, Sendable {
    public enum Purpose: String, Equatable, Sendable {
        case invite
        case reconnect
        case linkDevice = "link_device"
        case demo
        case unknown
    }

    public var purpose: Purpose
    public var inviterName: String?
    public var inviterSkin: String?
    public var targetName: String?
    public var expiresAt: Date?

    public init(purpose: Purpose, inviterName: String?, inviterSkin: String?, targetName: String?, expiresAt: Date?) {
        self.purpose = purpose
        self.inviterName = inviterName
        self.inviterSkin = inviterSkin
        self.targetName = targetName
        self.expiresAt = expiresAt
    }
}

/// The last week of the water log, boiled down to what Duo needs: how much counted on each
/// recent day, the goal they are judged against, and the day of the oldest drink anywhere
/// in the log (for `coverageStart`, §10.5). It carries no drinks, no times and no amounts
/// beyond the per-day totals, and nothing in it is ever sent as it stands.
public struct DuoLogSummary: Equatable, Sendable {
    public var totalsByDay: [String: Int]
    public var goalML: Int
    public var earliestEntryDay: String?

    public init(totalsByDay: [String: Int], goalML: Int, earliestEntryDay: String?) {
        self.totalsByDay = totalsByDay
        self.goalML = goalML
        self.earliestEntryDay = earliestEntryDay
    }

    public static let empty = DuoLogSummary(totalsByDay: [:], goalML: 0, earliestEntryDay: nil)
}

/// What kind of request a queued entry is.
public enum DuoOpKind: String, Codable, Equatable, Sendable {
    case leave
    case block
    case updateMe
    case registerPush
    case unregisterPush
}

/// A request that must reach the server even if the app is closed first: the op queue of
/// §10.1. It holds the exact bytes to send, so a replay under the same `Idempotency-Key` is
/// provably the same request (vector KV20).
public struct DuoQueuedOp: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var kind: DuoOpKind
    public var method: String
    /// Relative to the base URL, such as `/duos/<id>/leave`.
    public var path: String
    public var body: Data
    public var createdAt: Date
    /// Lowercase duo id, for a leave or a block.
    public var duoID: String?
    /// True for the first upload of a token by this device, which is attested (§6.2).
    public var attestsFirstUpload: Bool

    public var id: String { key }

    public init(key: String, kind: DuoOpKind, method: String, path: String, body: Data, createdAt: Date,
                duoID: String? = nil, attestsFirstUpload: Bool = false) {
        self.key = key
        self.kind = kind
        self.method = method
        self.path = path
        self.body = body
        self.createdAt = createdAt
        self.duoID = duoID
        self.attestsFirstUpload = attestsFirstUpload
    }

    /// Leave and block carry an `Idempotency-Key`; the other three are naturally idempotent.
    public var sendsIdempotencyKey: Bool { kind == .leave || kind == .block }

    public static func leave(duoID: UUID, key: String, now: Date) throws -> DuoQueuedOp {
        let id = duoID.uuidString.lowercased()
        return DuoQueuedOp(key: key, kind: .leave, method: "POST", path: "/duos/\(id)/leave",
                           body: try DuoWireCoding.encode(DuoWireEmptyRequest()), createdAt: now, duoID: id)
    }

    public static func block(duoID: UUID, key: String, now: Date) throws -> DuoQueuedOp {
        let id = duoID.uuidString.lowercased()
        return DuoQueuedOp(key: key, kind: .block, method: "POST", path: "/duos/\(id)/block",
                           body: try DuoWireCoding.encode(DuoWireEmptyRequest()), createdAt: now, duoID: id)
    }

    public static func updateMe(_ request: DuoWireUpdateMeRequest, key: String, now: Date) throws -> DuoQueuedOp {
        DuoQueuedOp(key: key, kind: .updateMe, method: "PATCH", path: "/me", body: try DuoWireCoding.encode(request), createdAt: now)
    }

    public static func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool, key: String, now: Date) throws -> DuoQueuedOp {
        DuoQueuedOp(key: key, kind: .registerPush, method: "PUT", path: "/devices/me/push", body: try DuoWireCoding.encode(request),
                    createdAt: now, attestsFirstUpload: firstUpload)
    }

    public static func unregisterPush(key: String, now: Date) -> DuoQueuedOp {
        DuoQueuedOp(key: key, kind: .unregisterPush, method: "DELETE", path: "/devices/me/push", body: Data(), createdAt: now)
    }
}

/// What the Duo screen says about the service, and whether writes are allowed (§6.7, §3.4).
public enum DuoAvailability: Equatable, Sendable {
    /// Nothing has been tried yet this launch.
    case unknown
    case available
    /// A 503, a WAF page or a 5xx: "not available right now", the duo catches up later.
    case maintenance
    /// A 426: writes are off, the card stays.
    case upgradeRequired
    /// A 401 `device_revoked`: another phone took this identity over.
    case disconnected
    /// A 403 `banned`.
    case banned
    /// The Keychain held a credential but the install marker was missing (a reinstall, a
    /// restore, a Quick Start): the person decides before anything else is sent (§3.4).
    case needsRestoreChoice(DuoRestorePrompt)

    /// The line the Duo screen's banner shows, or nil for none. Offline is not a banner:
    /// the app stays usable from the log and the cache (§10.7).
    public var bannerMessage: String? {
        switch self {
        case .unknown, .available, .needsRestoreChoice: return nil
        case .maintenance: return "HydroDrop's duo service is not available right now. Your duo will catch up when it is."
        case .upgradeRequired: return "Update HydroDrop to keep using Duo Streaks."
        case .disconnected: return "This phone was disconnected from the duo"
        case .banned: return "Duo Streaks are not available for this device. Contact support@hydrodrop.us."
        }
    }

    /// Whether the app may start, join, nudge or publish.
    public var allowsWrites: Bool {
        switch self {
        case .unknown, .available, .maintenance: return true
        case .upgradeRequired, .disconnected, .banned, .needsRestoreChoice: return false
        }
    }

    /// Whether the Reconnect button may send. A disconnected phone is the one that needs it
    /// ("I had a duo", §3.4), yet `allowsWrites` is false for it, so keying the button on that
    /// would leave the card's only way back disabled. The service then lets go of the
    /// revoked credential and starts from a fresh identity (§3.5: a reconnect needs a member
    /// with no duos and one device). Everything else a disconnected phone could do stays off.
    public var allowsReconnect: Bool {
        allowsWrites || self == .disconnected
    }
}

/// "This phone was connected to a duo with <partner>. Continue as <name>?" (§3.4).
public struct DuoRestorePrompt: Equatable, Sendable {
    public var partnerName: String?
    public var myName: String?

    public init(partnerName: String?, myName: String?) {
        self.partnerName = partnerName
        self.myName = myName
    }
}

/// Whether the person has said they are old enough, kept on this phone only and never
/// sent anywhere (§12.6: the contract has no age field, `additionalProperties: false`).
public enum DuoAgeStatus: String, Codable, Equatable, Sendable {
    case unknown
    case allowed
    case refused
}

public enum DuoAgeGate {
    public static let minimumAge = 13
    /// No clock is believed to be earlier than the year this rule shipped in. A phone whose date
    /// is wrong or unset (2001, say) made a person born in 1990 "refused", and a refusal is final
    /// and kept in the Keychain, so an adult was locked out for good by a clock they could have
    /// fixed in a minute. A clock set later than the truth can still admit a child; that cannot
    /// be told apart on a phone with a neutral screen, and the screen is not age assurance.
    public static let earliestPlausibleYear = 2026

    /// A neutral birth-year screen can only compare years, so this is the plain reading:
    /// old enough once the year is `minimumAge` years back or more. Policy, not copy, and
    /// Jonathon's to confirm (it admits someone who turns 13 later this year).
    public static func decide(birthYear: Int, now: Date, calendar: Calendar) -> DuoAgeStatus {
        // The current year is read in the Gregorian calendar whatever calendar the caller holds,
        // keeping only its time zone: the birth-year screen offers Gregorian years, and under a
        // Buddhist calendar `now` is 2569, which let a seven-year-old through, while under a
        // Japanese one it is 8, which no year passes and so locked those people out for good.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let year = max(gregorian.component(.year, from: now), earliestPlausibleYear)
        guard birthYear >= 1900, birthYear <= year else { return .unknown }
        return year - birthYear >= minimumAge ? .allowed : .refused
    }
}

/// The record of an idempotent request a person's tap started, kept before it is sent
/// (final design §6.0): "the client persists `{key, method, path, body_bytes}` before sending
/// and replays those exact bytes". A create, a join, a reconnect, a new code and a delete are
/// interactive, so the person may tap again after a lost answer; a second tap that builds the
/// very same request must reuse the key, and one that builds a different one must not.
public struct DuoInflightJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The request's method and path, with every id in the path (`POST /duos/<id>/invites`):
        /// the server judges a replay by method, path and body together, and the same body is
        /// sent for every duo's invite, so a name that left the duo out would replay one duo's
        /// key on another's path and be refused `422 idempotency_mismatch`.
        public var operation: String
        public var key: DuoIdempotencyKey
        public var body: Data
        public var createdAt: Date
        /// Only for a request whose bytes carry something that is new on every attempt, which
        /// today is the DeviceCheck token a redeem holds (§11.2): that request with the field
        /// left out, so two attempts can be told to be the same request. Nil for every other.
        public var identity: Data?
    }

    /// Under the server's 24 hours, so a replay is never judged by a record about to expire.
    public static let lifetime: TimeInterval = 23 * 60 * 60

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The key to send `body` under for `operation`: the one already recorded when it is the
    /// same operation with the same bytes and under `lifetime` old, else a new one, recorded
    /// now. Persist the journal before the request goes out.
    public mutating func key(for operation: String, body: Data, now: Date, random: DuoRandom) -> DuoIdempotencyKey {
        prune(now: now)
        if let existing = entries.first(where: { $0.operation == operation && $0.body == body }) { return existing.key }
        entries.removeAll { $0.operation == operation }
        let key = DuoIdempotencyKey.make(random: random)
        entries.append(Entry(operation: operation, key: key, body: body, createdAt: now, identity: nil))
        return key
    }

    /// The key and the exact bytes to send for a request with a field that changes on every
    /// attempt (a redeem's DeviceCheck token: per-request, never stored by the server, and kept
    /// here only until the request is answered or the journal's lifetime ends, D62).
    /// `key(for:body:)` would give such a request a new key each time, because its bytes never
    /// match, and the server's replay of a lost answer (§6.0) would never happen on a phone;
    /// worse, sending the old key with new bytes is `422 idempotency_mismatch`. `identity` is
    /// the same request with that field left out. An entry for this operation with the same
    /// identity is replayed whole: its recorded bytes, old token and all, under its recorded
    /// key. Anything else is a new request, recorded now. Persist the journal before sending.
    public mutating func replayable(for operation: String, identity: Data, body: Data, now: Date,
                                    random: DuoRandom) -> (key: DuoIdempotencyKey, body: Data) {
        prune(now: now)
        if let existing = entries.first(where: { $0.operation == operation && $0.identity == identity }) {
            return (existing.key, existing.body)
        }
        entries.removeAll { $0.operation == operation }
        let key = DuoIdempotencyKey.make(random: random)
        entries.append(Entry(operation: operation, key: key, body: body, createdAt: now, identity: identity))
        return (key, body)
    }

    /// The request got a definite answer, success or a refusal that a retry would repeat.
    public mutating func clear(operation: String) {
        entries.removeAll { $0.operation == operation }
    }

    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.createdAt) >= Self.lifetime }
    }

    public mutating func removeAll() {
        entries = []
    }
}

/// The duos this person cleared from the screen, so that `GET /me` does not bring them back.
///
/// The server lists every duo that has not ended and every ended one for 30 days (§12.1), and a
/// Clear is local only (§12.2), so without this a cleared duo comes back as an ended card at
/// the next hourly `GET /me`, for up to 30 days. Keyed by the lowercase duo id; an entry is
/// kept for as long as the server could still list the duo, then dropped.
public struct DuoClearedSet: Codable, Equatable, Sendable {
    public private(set) var clearedAt: [String: Date]

    public init(clearedAt: [String: Date] = [:]) {
        self.clearedAt = clearedAt
    }

    public mutating func mark(_ id: UUID, now: Date) {
        clearedAt[id.uuidString.lowercased()] = now
        prune(now: now)
    }

    public func contains(_ id: UUID) -> Bool {
        clearedAt[id.uuidString.lowercased()] != nil
    }

    public mutating func prune(now: Date) {
        clearedAt = clearedAt.filter { now.timeIntervalSince($0.value) < DuoProtocolConstants.endedDuoLifetime }
    }
}
