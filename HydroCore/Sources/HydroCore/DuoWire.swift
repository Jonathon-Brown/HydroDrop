import Foundation

// The Duo v2 wire contract, version 1.0.0, frozen at the server's tag `contract-v1`
// (`openapi.json`). One Swift type per schema, in the contract's field names and with the
// contract's required and optional fields exactly: a field the schema lists as required is
// not optional here, and a field it leaves out of `required` is optional here, which is how
// a header-only view (six fields) and a full one decode into the same type.
//
// Keys are snake_case on the wire and camelCase here; `DuoWireCoding` converts. A property
// whose wire name ends in `_id` is spelled `...Id` here (not `...ID`), because that is what
// the conversion produces and a mismatch would decode to nothing without an error.
//
// Timestamps are `Date` here and `YYYY-MM-DDTHH:MM:SSZ` on the wire (`DuoWireTime`). Days
// stay `String`: a day key is a calendar day, never an instant.

// MARK: - Coding

public enum DuoWireCoding {
    /// Every request body is written by this encoder and no other: sorted keys, snake_case,
    /// no spaces. Encoding the same value twice gives the same bytes, which is what an
    /// idempotent replay and an attestation's body hash both depend on (§6.0, §11.2).
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    /// Every 2xx body is read by this decoder. An error body is not: it is read by
    /// `DuoWireErrorEnvelope.decode`, because through this one its keys would be converted to
    /// camel case and `retry_after_s`, `request_id` and every key of `details` would be
    /// dropped without a word.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = DuoWireTime.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 date-time"))
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}

/// RFC 3339 date-times. The server emits exactly `YYYY-MM-DDTHH:MM:SSZ`, and clients send
/// the same; any RFC 3339 is read (a fraction, an offset) and every one of them to the same
/// instant (vector KV4). No `DateFormatter`: it is the same on every runtime, thread-safe,
/// and cannot be made to depend on the phone's locale or calendar.
public enum DuoWireTime {
    public static func format(_ date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        var days = seconds / 86_400
        var rest = seconds % 86_400
        if rest < 0 { rest += 86_400; days -= 1 }
        let (year, month, day) = civil(fromDays: days)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, rest / 3600, (rest % 3600) / 60, rest % 60)
    }

    /// Nil for anything that is not a real RFC 3339 date-time. A leap second (`:60`) is read
    /// as `:59`, as `java.time` reads it.
    public static func parse(_ text: String) -> Date? {
        let chars = Array(text.utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= chars.count else { return nil }
            var value = 0
            for index in start..<(start + count) {
                guard chars[index] >= 48, chars[index] <= 57 else { return nil }
                value = value * 10 + Int(chars[index] - 48)
            }
            return value
        }
        guard chars.count >= 20, chars[4] == 45, chars[7] == 45, chars[10] == 84 || chars[10] == 116,
              chars[13] == 58, chars[16] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), var second = digits(17, 2) else { return nil }
        guard (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second <= 60 else { return nil }
        if second == 60 { second = 59 }

        var index = 19
        var fraction = 0.0
        if index < chars.count, chars[index] == 46 {
            index += 1
            var scale = 0.1
            let start = index
            while index < chars.count, chars[index] >= 48, chars[index] <= 57 {
                fraction += Double(chars[index] - 48) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        var offset = 0
        guard index < chars.count else { return nil }
        if chars[index] == 90 || chars[index] == 122 {
            index += 1
        } else if chars[index] == 43 || chars[index] == 45 {
            let sign = chars[index] == 43 ? 1 : -1
            guard index + 6 == chars.count, chars[index + 3] == 58,
                  let offsetHour = digits(index + 1, 2), let offsetMinute = digits(index + 4, 2),
                  offsetHour < 24, offsetMinute < 60 else { return nil }
            offset = sign * (offsetHour * 3600 + offsetMinute * 60)
            index += 6
        } else {
            return nil
        }
        guard index == chars.count else { return nil }

        let days = Int64(daysFromCivil(year: year, month: month, day: day))
        let seconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offset)
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays days: Int64) -> (Int, Int, Int) {
        let z = Int(days) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

/// A field a request may leave out, send as `null`, or send with a value. `PATCH /me` needs
/// all three: absent leaves the name alone, `null` clears it (§6.2).
public enum DuoWireField<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
    case absent
    case null
    case value(Value)
}

private extension KeyedEncodingContainer {
    /// A required field whose value may be null: always written, as `null` when empty.
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    mutating func encodeField<V: Codable & Equatable & Sendable>(_ field: DuoWireField<V>, forKey key: Key) throws {
        switch field {
        case .absent: break
        case .null: try encodeNil(forKey: key)
        case .value(let value): try encode(value, forKey: key)
        }
    }
}

// MARK: - Requests

public struct DuoWireEmptyRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct DuoWireStatusIn: Codable, Equatable, Sendable {
    public var day: String
    public var goalMet: Bool
    public var progressBucket: Int
    public var baseVer: Int64

    public init(day: String, goalMet: Bool, progressBucket: Int, baseVer: Int64) {
        self.day = day
        self.goalMet = goalMet
        self.progressBucket = progressBucket
        self.baseVer = baseVer
    }
}

public struct DuoWireCreateDeviceRequest: Codable, Equatable, Sendable {
    /// "ios".
    public var platform: String
    /// Like "2.0 (57)".
    public var appVersion: String
    public var termsVersion: Int
    public var deviceCheckToken: String?

    public init(platform: String = "ios", appVersion: String, termsVersion: Int, deviceCheckToken: String? = nil) {
        self.platform = platform
        self.appVersion = appVersion
        self.termsVersion = termsVersion
        self.deviceCheckToken = deviceCheckToken
    }
}

public struct DuoWireUpdateMeRequest: Codable, Equatable, Sendable {
    public var displayName: DuoWireField<String>
    public var skin: DuoWireField<String>
    public var termsVersion: DuoWireField<Int>

    public init(displayName: DuoWireField<String> = .absent, skin: DuoWireField<String> = .absent, termsVersion: DuoWireField<Int> = .absent) {
        self.displayName = displayName
        self.skin = skin
        self.termsVersion = termsVersion
    }

    private enum CodingKeys: String, CodingKey { case displayName, skin, termsVersion }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeField(displayName, forKey: .displayName)
        // contract-v1 declares only `display_name` nullable on this request (null clears the
        // name). `skin` and `terms_version` are not, and the server refuses a `null` for either
        // with `400 schema`, so a `.null` for them is written as nothing rather than sent.
        if case .value(let skinValue) = skin { try container.encode(skinValue, forKey: .skin) }
        if case .value(let version) = termsVersion { try container.encode(version, forKey: .termsVersion) }
    }

    /// Read back so the op queue can replay a queued `PATCH /me` through the typed transport
    /// and write the very same bytes: absent, `null` and a value each come back as themselves.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try Self.field(String.self, container, .displayName)
        skin = try Self.field(String.self, container, .skin)
        termsVersion = try Self.field(Int.self, container, .termsVersion)
    }

    private static func field<V: Codable & Equatable & Sendable>(_ type: V.Type, _ container: KeyedDecodingContainer<CodingKeys>,
                                                                  _ key: CodingKeys) throws -> DuoWireField<V> {
        guard container.contains(key) else { return .absent }
        if try container.decodeNil(forKey: key) { return .null }
        return .value(try container.decode(V.self, forKey: key))
    }
}

public struct DuoWireDeleteMeRequest: Codable, Equatable, Sendable {
    public var deviceCheckToken: String?

    public init(deviceCheckToken: String? = nil) {
        self.deviceCheckToken = deviceCheckToken
    }
}

public struct DuoWireRegisterPushRequest: Codable, Equatable, Sendable {
    /// "apns".
    public var platform: String
    /// "apns".
    public var tokenKind: String
    public var token: String
    /// "sandbox" or "production" (APNs only).
    public var apnsEnv: String?
    /// An IANA zone. Sent whichever way `notificationsEnabled` is (D36).
    public var tz: String?
    /// Minutes after midnight, 0 to 1439. Sent only with notifications on.
    public var wakeStartMin: Int?
    public var wakeEndMin: Int?
    public var notificationsEnabled: Bool

    public init(token: String, apnsEnv: String?, tz: String?, wakeStartMin: Int?, wakeEndMin: Int?, notificationsEnabled: Bool) {
        self.platform = "apns"
        self.tokenKind = "apns"
        self.token = token
        self.apnsEnv = apnsEnv
        self.tz = tz
        self.wakeStartMin = wakeStartMin
        self.wakeEndMin = wakeEndMin
        self.notificationsEnabled = notificationsEnabled
    }
}

public struct DuoWireCreateDuoRequest: Encodable, Equatable, Sendable {
    /// Always sent, as `null` when there is no name.
    public var displayName: String?
    public var skin: String
    public var myToday: String
    public var e2eeCapable: Bool
    public var statuses: [DuoWireStatusIn]

    public init(displayName: String?, skin: String, myToday: String, e2eeCapable: Bool, statuses: [DuoWireStatusIn]) {
        self.displayName = displayName
        self.skin = skin
        self.myToday = myToday
        self.e2eeCapable = e2eeCapable
        self.statuses = statuses
    }

    private enum CodingKeys: String, CodingKey { case displayName, skin, myToday, e2eeCapable, statuses }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(displayName, forKey: .displayName)
        try container.encode(skin, forKey: .skin)
        try container.encode(myToday, forKey: .myToday)
        try container.encode(e2eeCapable, forKey: .e2eeCapable)
        try container.encode(statuses, forKey: .statuses)
    }
}

public enum DuoWireInvitePurpose: String, Codable, Equatable, Sendable {
    case invite
    case reconnect
    case linkDevice = "link_device"
}

public struct DuoWireCreateInviteRequest: Codable, Equatable, Sendable {
    public var purpose: DuoWireInvitePurpose

    public init(purpose: DuoWireInvitePurpose) {
        self.purpose = purpose
    }
}

public struct DuoWirePeekRequest: Codable, Equatable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public struct DuoWireRedeemRequest: Encodable, Equatable, Sendable {
    public var code: String
    /// Always sent, as `null` when there is no name.
    public var displayName: String?
    public var skin: String
    public var myToday: String
    public var e2eeCapable: Bool
    public var statuses: [DuoWireStatusIn]
    public var deviceCheckToken: String?

    public init(code: String, displayName: String?, skin: String, myToday: String, e2eeCapable: Bool,
                statuses: [DuoWireStatusIn], deviceCheckToken: String? = nil) {
        self.code = code
        self.displayName = displayName
        self.skin = skin
        self.myToday = myToday
        self.e2eeCapable = e2eeCapable
        self.statuses = statuses
        self.deviceCheckToken = deviceCheckToken
    }

    private enum CodingKeys: String, CodingKey { case code, displayName, skin, myToday, e2eeCapable, statuses, deviceCheckToken }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encodeNullable(displayName, forKey: .displayName)
        try container.encode(skin, forKey: .skin)
        try container.encode(myToday, forKey: .myToday)
        try container.encode(e2eeCapable, forKey: .e2eeCapable)
        try container.encode(statuses, forKey: .statuses)
        try container.encodeIfPresent(deviceCheckToken, forKey: .deviceCheckToken)
    }
}

public struct DuoWireReconnectRequest: Codable, Equatable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

public struct DuoWirePutStatusesRequest: Codable, Equatable, Sendable {
    public var myToday: String
    /// The client's cursor for this duo, so the answer is the change feed since it.
    public var since: Int64
    public var statuses: [DuoWireStatusIn]

    public init(myToday: String, since: Int64, statuses: [DuoWireStatusIn]) {
        self.myToday = myToday
        self.since = since
        self.statuses = statuses
    }
}

public struct DuoWireSendNudgeRequest: Codable, Equatable, Sendable {
    /// `nudge-` and a UUID, in the case this phone wrote it (iOS: upper case).
    public var id: String
    public var presetId: String
    /// The sender's local day.
    public var senderDay: String

    public init(id: String, presetId: String, senderDay: String) {
        self.id = id
        self.presetId = presetId
        self.senderDay = senderDay
    }
}

// MARK: - Responses

public struct DuoWireCreateDeviceResponse: Codable, Equatable, Sendable {
    public var memberId: String
    public var deviceId: String
    public var deviceSecret: String
    public var tier: DuoTier
    public var supportId: String

    public init(memberId: String, deviceId: String, deviceSecret: String, tier: DuoTier, supportId: String) {
        self.memberId = memberId
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
        self.tier = tier
        self.supportId = supportId
    }
}

public struct DuoWireAttestChallenge: Codable, Equatable, Sendable {
    public var challengeId: String
    /// 32 random bytes, base64url without padding.
    public var challenge: String
    public var expiresAt: Date

    public init(challengeId: String, challenge: String, expiresAt: Date) {
        self.challengeId = challengeId
        self.challenge = challenge
        self.expiresAt = expiresAt
    }
}

public struct DuoWireRotateResponse: Codable, Equatable, Sendable {
    public var deviceSecret: String
    public var secretVersion: Int

    public init(deviceSecret: String, secretVersion: Int) {
        self.deviceSecret = deviceSecret
        self.secretVersion = secretVersion
    }
}

public struct DuoWireMember: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String?
    public var skin: String?
    public var supportId: String
    public var tier: DuoTier
    public var termsVersion: Int

    public init(id: String, displayName: String? = nil, skin: String? = nil, supportId: String, tier: DuoTier, termsVersion: Int) {
        self.id = id
        self.displayName = displayName
        self.skin = skin
        self.supportId = supportId
        self.tier = tier
        self.termsVersion = termsVersion
    }
}

public struct DuoWireDevice: Codable, Equatable, Sendable {
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

public struct DuoWireLimits: Codable, Equatable, Sendable {
    public var nudgesPerDay: Int
    public var maxActiveDuos: Int

    public init(nudgesPerDay: Int, maxActiveDuos: Int) {
        self.nudgesPerDay = nudgesPerDay
        self.maxActiveDuos = maxActiveDuos
    }
}

public struct DuoWireMinClient: Codable, Equatable, Sendable {
    public var ios: String
    public var android: String

    public init(ios: String, android: String) {
        self.ios = ios
        self.android = android
    }
}

public enum DuoWireDuoState: String, Codable, Equatable, Sendable {
    case pending
    case active
    case ended
}

public struct DuoWireHeaderInvite: Codable, Equatable, Sendable {
    public var hasOpenInvite: Bool
    public var expiresAt: Date?

    public init(hasOpenInvite: Bool, expiresAt: Date? = nil) {
        self.hasOpenInvite = hasOpenInvite
        self.expiresAt = expiresAt
    }
}

/// A duo's header. A caller who left, was blocked or is superseded gets only `id`, `myRole`,
/// `state`, `endedAt`, `endedBy` and `seq`; every other field is then absent (§5.2).
public struct DuoWireHeader: Codable, Equatable, Sendable {
    public var id: String
    public var myRole: DuoRole
    public var state: DuoWireDuoState
    public var createdAt: Date?
    public var joinedAt: Date?
    public var endedAt: Date?
    public var endedBy: DuoEndedBy?
    public var ownerDisplayName: String?
    public var ownerSkin: String?
    public var partnerDisplayName: String?
    public var partnerSkin: String?
    public var partnerLastWriteDay: String?
    public var partnerIsDemo: Bool?
    public var invite: DuoWireHeaderInvite?
    public var seq: Int64

    /// Whether the header carries the full set of fields, which is how a client tells a
    /// header-only view from a live one.
    public var isFull: Bool { createdAt != nil }

    public init(id: String, myRole: DuoRole, state: DuoWireDuoState, createdAt: Date? = nil, joinedAt: Date? = nil, endedAt: Date? = nil, endedBy: DuoEndedBy? = nil, ownerDisplayName: String? = nil, ownerSkin: String? = nil, partnerDisplayName: String? = nil, partnerSkin: String? = nil, partnerLastWriteDay: String? = nil, partnerIsDemo: Bool? = nil, invite: DuoWireHeaderInvite? = nil, seq: Int64) {
        self.id = id
        self.myRole = myRole
        self.state = state
        self.createdAt = createdAt
        self.joinedAt = joinedAt
        self.endedAt = endedAt
        self.endedBy = endedBy
        self.ownerDisplayName = ownerDisplayName
        self.ownerSkin = ownerSkin
        self.partnerDisplayName = partnerDisplayName
        self.partnerSkin = partnerSkin
        self.partnerLastWriteDay = partnerLastWriteDay
        self.partnerIsDemo = partnerIsDemo
        self.invite = invite
        self.seq = seq
    }
}

public struct DuoWireGetMeResponse: Codable, Equatable, Sendable {
    public var member: DuoWireMember
    public var limits: DuoWireLimits
    public var devices: [DuoWireDevice]
    public var duos: [DuoWireHeader]
    public var minClient: DuoWireMinClient

    public init(member: DuoWireMember, limits: DuoWireLimits, devices: [DuoWireDevice], duos: [DuoWireHeader], minClient: DuoWireMinClient) {
        self.member = member
        self.limits = limits
        self.devices = devices
        self.duos = duos
        self.minClient = minClient
    }
}

public struct DuoWireStatusRow: Codable, Equatable, Sendable {
    public var role: DuoRole
    public var day: String
    public var goalMet: Bool
    public var progressBucket: Int
    public var updatedAt: Date
    public var ver: Int64

    public init(role: DuoRole, day: String, goalMet: Bool, progressBucket: Int, updatedAt: Date, ver: Int64) {
        self.role = role
        self.day = day
        self.goalMet = goalMet
        self.progressBucket = progressBucket
        self.updatedAt = updatedAt
        self.ver = ver
    }
}

public struct DuoWireNudge: Codable, Equatable, Sendable {
    public var id: String
    public var fromRole: DuoRole
    public var presetId: String
    public var createdAt: Date

    public init(id: String, fromRole: DuoRole, presetId: String, createdAt: Date) {
        self.id = id
        self.fromRole = fromRole
        self.presetId = presetId
        self.createdAt = createdAt
    }
}

/// A push this device was already sent: `kind` is `goal_met` (with `day`) or `nudge` (with
/// `id`); any other kind is ignored (§6.4).
public struct DuoWireHandled: Codable, Equatable, Sendable {
    public var kind: String
    public var day: String?
    public var id: String?

    public init(kind: String, day: String? = nil, id: String? = nil) {
        self.kind = kind
        self.day = day
        self.id = id
    }
}

public struct DuoWireChanges: Codable, Equatable, Sendable {
    public var duo: DuoWireHeader
    /// True when `statuses` holds every retained row: replace, don't merge.
    public var full: Bool
    public var statuses: [DuoWireStatusRow]
    public var nudges: [DuoWireNudge]
    public var handled: [DuoWireHandled]
    public var cursor: Int64

    public init(duo: DuoWireHeader, full: Bool, statuses: [DuoWireStatusRow], nudges: [DuoWireNudge], handled: [DuoWireHandled], cursor: Int64) {
        self.duo = duo
        self.full = full
        self.statuses = statuses
        self.nudges = nudges
        self.handled = handled
        self.cursor = cursor
    }
}

public enum DuoWireRejectReason: String, Codable, Equatable, Sendable {
    case dayOutOfRange = "day_out_of_range"
    case dayAfterToday = "day_after_today"
    case statusInconsistent = "status_inconsistent"
    case verConflict = "ver_conflict"
    case downgradeRefused = "downgrade_refused"
    /// A reason a newer server sends that this build has never heard of.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DuoWireRejectReason(rawValue: raw) ?? .unknown
    }
}

/// A row the server did not store. Row problems never fail a request (§6.5).
public struct DuoWireRejected: Codable, Equatable, Sendable {
    public var day: String
    public var reason: DuoWireRejectReason
    /// With `verConflict` and `downgradeRefused`: the row as the server holds it. Absent on a
    /// `verConflict` for a day the server holds no row of, whose `ver` is then 0 (§10.3).
    public var current: DuoWireStatusRow?

    public init(day: String, reason: DuoWireRejectReason, current: DuoWireStatusRow? = nil) {
        self.day = day
        self.reason = reason
        self.current = current
    }
}

/// The change feed after a write, plus what happened to each row sent (§6.5). The feed's
/// fields and the result's are one JSON object.
public struct DuoWireChangesWithResult: Codable, Equatable, Sendable {
    public var changes: DuoWireChanges
    public var accepted: [String]
    public var unchanged: [String]
    public var rejected: [DuoWireRejected]

    private enum CodingKeys: String, CodingKey { case accepted, unchanged, rejected }

    public init(changes: DuoWireChanges, accepted: [String], unchanged: [String], rejected: [DuoWireRejected]) {
        self.changes = changes
        self.accepted = accepted
        self.unchanged = unchanged
        self.rejected = rejected
    }

    public init(from decoder: Decoder) throws {
        changes = try DuoWireChanges(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decode([String].self, forKey: .accepted)
        unchanged = try container.decode([String].self, forKey: .unchanged)
        rejected = try container.decode([DuoWireRejected].self, forKey: .rejected)
    }

    public func encode(to encoder: Encoder) throws {
        try changes.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accepted, forKey: .accepted)
        try container.encode(unchanged, forKey: .unchanged)
        try container.encode(rejected, forKey: .rejected)
    }
}

public struct DuoWireInvite: Codable, Equatable, Sendable {
    public var code: String
    public var display: String
    public var expiresAt: Date
    /// `reconnect` and `link_device` only.
    public var targetDisplayName: String?

    public init(code: String, display: String, expiresAt: Date, targetDisplayName: String? = nil) {
        self.code = code
        self.display = display
        self.expiresAt = expiresAt
        self.targetDisplayName = targetDisplayName
    }
}

public struct DuoWireCreateDuoResponse: Codable, Equatable, Sendable {
    public var duo: DuoWireHeader
    public var invite: DuoWireInvite
    public var accepted: [String]
    public var unchanged: [String]
    public var rejected: [DuoWireRejected]

    public init(duo: DuoWireHeader, invite: DuoWireInvite, accepted: [String], unchanged: [String], rejected: [DuoWireRejected]) {
        self.duo = duo
        self.invite = invite
        self.accepted = accepted
        self.unchanged = unchanged
        self.rejected = rejected
    }
}

public struct DuoWirePeekResponse: Codable, Equatable, Sendable {
    public var purpose: String
    /// Always "open".
    public var state: String
    public var expiresAt: Date?
    public var inviterDisplayName: String?
    public var inviterSkin: String?
    public var targetDisplayName: String?

    public init(purpose: String, state: String, expiresAt: Date? = nil, inviterDisplayName: String? = nil, inviterSkin: String? = nil, targetDisplayName: String? = nil) {
        self.purpose = purpose
        self.state = state
        self.expiresAt = expiresAt
        self.inviterDisplayName = inviterDisplayName
        self.inviterSkin = inviterSkin
        self.targetDisplayName = targetDisplayName
    }
}

public struct DuoWireReconnectResponse: Codable, Equatable, Sendable {
    public var memberId: String
    public var supportId: String
    public var duos: [DuoWireHeader]
    public var supersededDevices: Int

    public init(memberId: String, supportId: String, duos: [DuoWireHeader], supersededDevices: Int) {
        self.memberId = memberId
        self.supportId = supportId
        self.duos = duos
        self.supersededDevices = supersededDevices
    }
}

public struct DuoWireLeaveResponse: Codable, Equatable, Sendable {
    /// Always "ended".
    public var state: String
    public var endedBy: DuoEndedBy
    public var endedAt: Date

    public init(state: String, endedBy: DuoEndedBy, endedAt: Date) {
        self.state = state
        self.endedBy = endedBy
        self.endedAt = endedAt
    }
}

public struct DuoWireSendNudgeResponse: Codable, Equatable, Sendable {
    public var nudge: DuoWireNudge
    public var remainingToday: Int

    public init(nudge: DuoWireNudge, remainingToday: Int) {
        self.nudge = nudge
        self.remainingToday = remainingToday
    }
}

/// A nudge's answer, with whether it was a retry the server already had: 201 for a new one,
/// 200 for the stored row of one this device had sent (§6.6).
public struct DuoWireSendNudgeResult: Equatable, Sendable {
    public var response: DuoWireSendNudgeResponse
    public var wasAlreadySent: Bool

    public init(response: DuoWireSendNudgeResponse, wasAlreadySent: Bool) {
        self.response = response
        self.wasAlreadySent = wasAlreadySent
    }
}

// MARK: - Errors

/// The `details` an error may carry. Every key is optional and read leniently: a value of
/// the wrong type is simply absent, never a decoding failure, because a failure here would
/// hide the error itself.
public struct DuoWireErrorDetails: Equatable, Sendable {
    /// `device_limit` (5) and `duo_limit` (5).
    public var max: Int?
    /// `duo_limit`.
    public var activeDuos: Int?
    /// `nudge_limit`.
    public var limit: Int?
    public var remaining: Int?
    /// `pending_exists`: the duo to adopt instead of creating another.
    public var duoId: String?
    /// `upgrade_required`.
    public var minVersion: String?
    /// `attest_required`.
    public var retryable: Bool?
    /// `terms_required`: the version to accept.
    public var termsVersion: Int?
    /// `name_rejected` and `schema`: for logs and support, never shown.
    public var reason: String?
    public var field: String?

    public init(max: Int? = nil, activeDuos: Int? = nil, limit: Int? = nil, remaining: Int? = nil, duoId: String? = nil,
                minVersion: String? = nil, retryable: Bool? = nil, termsVersion: Int? = nil, reason: String? = nil, field: String? = nil) {
        self.max = max
        self.activeDuos = activeDuos
        self.limit = limit
        self.remaining = remaining
        self.duoId = duoId
        self.minVersion = minVersion
        self.retryable = retryable
        self.termsVersion = termsVersion
        self.reason = reason
        self.field = field
    }
}

extension DuoWireErrorDetails: Decodable {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        func int(_ key: String) -> Int? { AnyKey(stringValue: key).flatMap { try? container.decode(Int.self, forKey: $0) } }
        func string(_ key: String) -> String? { AnyKey(stringValue: key).flatMap { try? container.decode(String.self, forKey: $0) } }
        func bool(_ key: String) -> Bool? { AnyKey(stringValue: key).flatMap { try? container.decode(Bool.self, forKey: $0) } }
        self.init(max: int("max"), activeDuos: int("active_duos"), limit: int("limit"), remaining: int("remaining"),
                  duoId: string("duo_id"), minVersion: string("min_version"), retryable: bool("retryable"),
                  termsVersion: int("terms_version"), reason: string("reason"), field: string("field"))
    }
}

/// `{"error": {"code", "message", "details"?, "retry_after_s"?, "request_id"}}` (§6.0). It is
/// read with a plain decoder (no key conversion), because its keys are not all convertible
/// and the nested `details` has keys of its own.
public struct DuoWireErrorEnvelope: Decodable, Equatable, Sendable {
    public struct Body: Decodable, Equatable, Sendable {
        public var code: String
        public var message: String?
        public var details: DuoWireErrorDetails?
        public var retryAfterS: Int?
        public var requestId: String?

        private enum CodingKeys: String, CodingKey {
            case code, message, details
            case retryAfterS = "retry_after_s"
            case requestId = "request_id"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            message = try? container.decode(String.self, forKey: .message)
            details = try? container.decode(DuoWireErrorDetails.self, forKey: .details)
            retryAfterS = try? container.decode(Int.self, forKey: .retryAfterS)
            requestId = try? container.decode(String.self, forKey: .requestId)
        }
    }

    public var error: Body

    /// The envelope an error response carries, or nil if the bytes are not one. The one way
    /// to read it: with a plain decoder, for the reason above. A `409 pending_exists` read
    /// any other way loses its `duo_id` and the client cannot adopt the duo a lost answer left
    /// behind; `duo_limit` loses `active_duos` and says the wrong number.
    public static func decode(_ data: Data) -> DuoWireErrorEnvelope? {
        try? JSONDecoder().decode(DuoWireErrorEnvelope.self, from: data)
    }
}
