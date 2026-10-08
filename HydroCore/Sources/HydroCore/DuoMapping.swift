import Foundation

// Wire to domain: what the server's answers become in `DuoState` and its neighbours. Every
// part of the app that reads a header, a status or a nudge off the wire reads it through
// here, so a null name, an unknown skin, an invalid day and a header-only view mean the
// same thing everywhere (final design §6.4, §8.4, §8.8; vectors KV16).

public enum DuoMapping {
    /// A day's status, or nil if the row is not one this build can hold: a day that is not a
    /// real day key (§8.4: "a client drops a received row whose `day` fails `isDayKey`"), or
    /// a bucket outside the five quarters.
    public static func status(_ row: DuoWireStatusRow) -> DuoDayStatus? {
        guard DuoStreak.isDayKey(row.day), DuoProgress.buckets.contains(row.progressBucket) else { return nil }
        return DuoDayStatus(role: row.role, day: row.day, goalMet: row.goalMet, progressBucket: row.progressBucket, updatedAt: row.updatedAt)
    }

    /// A nudge, or nil if its id is not the wire's pattern (§6.6) or its preset is longer
    /// than 40 characters. The id is kept exactly as received: apps compare ids byte for byte.
    public static func nudge(_ wire: DuoWireNudge) -> DuoNudge? {
        guard DuoNudge.isNudgeRecordName(wire.id), wire.presetId.count <= 40 else { return nil }
        return DuoNudge(id: wire.id, fromRole: wire.fromRole, presetID: wire.presetId, createdAt: wire.createdAt)
    }

    public static func invite(_ wire: DuoWireInvite) -> DuoInvite {
        DuoInvite(code: wire.code, display: wire.display, expiresAt: wire.expiresAt)
    }

    public static func peek(_ wire: DuoWirePeekResponse) -> DuoPeek {
        DuoPeek(purpose: DuoPeek.Purpose(rawValue: wire.purpose) ?? .unknown, inviterName: wire.inviterDisplayName,
                inviterSkin: wire.inviterSkin, targetName: wire.targetDisplayName, expiresAt: wire.expiresAt)
    }

    public static func member(_ response: DuoWireGetMeResponse, now: Date) -> DuoMemberInfo {
        DuoMemberInfo(
            memberID: response.member.id,
            displayName: response.member.displayName,
            skin: response.member.skin,
            supportID: response.member.supportId,
            tier: response.member.tier,
            termsVersion: response.member.termsVersion,
            nudgesPerDay: response.limits.nudgesPerDay,
            maxActiveDuos: response.limits.maxActiveDuos,
            devices: response.devices.map {
                DuoDeviceInfo(id: $0.id, platform: $0.platform, createdAt: $0.createdAt, thisDevice: $0.thisDevice, superseded: $0.superseded)
            },
            minClientIOS: response.minClient.ios,
            updatedAt: now
        )
    }

    /// The duo a header describes: a new one when `previous` is nil, otherwise `previous` with
    /// the header's facts applied. Nil if the header's id is not a UUID.
    ///
    /// - A header-only view (a caller who left, was blocked or is superseded) carries six
    ///   fields. Everything else is then left as it was: the cache keeps what it had.
    /// - A null name or skin on a live duo is the server's answer: no name, shown as "Your
    ///   partner". On an ended one it is the server masking a departed member's name, and
    ///   the survivor's cache keeps its copy (§5.2, §7.5).
    /// - A duo never comes back from ended here. An offline Leave marks the card ended
    ///   before the server hears, and a refresh in between must not undo it.
    /// - `partnerHasJoined` is true once the duo has been active, and for an ended duo whose
    ///   header says it was joined; a duo that ended unjoined stays "never joined".
    public static func duo(from header: DuoWireHeader, previous: DuoState?, now: Date) -> DuoState? {
        guard let id = UUID(uuidString: header.id) else { return nil }
        var duo = previous ?? DuoState(
            id: id, myRole: header.myRole, createdAt: header.createdAt ?? now,
            ownerDisplayName: "", partnerDisplayName: "", ownerSkin: "", partnerSkin: "",
            statuses: [], partnerHasJoined: false
        )
        duo.myRole = header.myRole
        let isEnded = header.state == .ended

        if header.isFull {
            if let created = header.createdAt { duo.createdAt = created }
            duo.joinedAt = header.joinedAt
            func name(_ incoming: String?, _ current: String) -> String {
                if let incoming { return incoming }
                return isEnded ? current : ""
            }
            duo.ownerDisplayName = name(header.ownerDisplayName, duo.ownerDisplayName)
            duo.partnerDisplayName = name(header.partnerDisplayName, duo.partnerDisplayName)
            duo.ownerSkin = name(header.ownerSkin, duo.ownerSkin)
            duo.partnerSkin = name(header.partnerSkin, duo.partnerSkin)
            duo.partnerLastWriteDay = header.partnerLastWriteDay
            duo.partnerIsDemo = header.partnerIsDemo ?? false
            if header.state == .active {
                duo.partnerHasJoined = true
            } else {
                duo.partnerHasJoined = header.joinedAt != nil
            }
        } else if header.state == .active {
            duo.partnerHasJoined = true
        }

        if isEnded {
            if duo.endedAt == nil { duo.endedAt = header.endedAt ?? now }
            duo.endedBy = header.endedBy ?? duo.endedBy ?? .unknown
            duo.invite = nil
            duo.openInviteExpiresAt = nil
        } else if header.isFull {
            duo.openInviteExpiresAt = header.state == .pending && header.invite?.hasOpenInvite == true ? header.invite?.expiresAt : nil
            if header.state != .pending || duo.openInviteExpiresAt == nil { duo.invite = nil }
        }
        return duo
    }

    /// A duo this phone already holds, handed back to it by a reconnect. `duo(from:previous:now:)`
    /// keeps what the cache had, `syncedOnce` included, which is right for a refresh but wrong
    /// here: the identity is now another phone's, the rows this phone holds were read by an
    /// older one, and writing before reading again could downgrade a day the other phone has
    /// moved on (§10.3, vector KV11). So it must be read whole before anything is written.
    public static func reseated(_ duo: DuoState) -> DuoState {
        var reseated = duo
        reseated.syncedOnce = false
        reseated.cursor = 0
        return reseated
    }

    /// The skin to draw for an id the server sent: one this build knows, else the fallback.
    /// A newer app's skin shows as the classic droplet here rather than as nothing (KV16).
    public static func resolvedSkin(_ raw: String?, known: Set<String>, fallback: String = "classic") -> String {
        guard let raw, known.contains(raw) else { return fallback }
        return raw
    }
}

/// The rule that decides whether a push is worth a fetch: it is when it is ahead of what
/// this phone has read (§6.8, vector KV17). A push with no `seq` is always worth one.
public enum DuoPushGate {
    public static func shouldFetch(cursor: Int64, seq: Int64?) -> Bool {
        guard let seq else { return true }
        return seq > cursor
    }
}

public enum DuoAPNsEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

/// What a remote Duo notification says (§9.2), read from the payload iOS hands the app or
/// from the all-strings data map the Android app receives (vector KV13). The words are never
/// in it: iOS shows loc-keys the app's `Localizable.strings` turns into text, so nothing the
/// payload says is ever rendered as it stands.
public struct DuoPushPayload: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case goalMet(day: String, iHaveToo: Bool)
        case nudge(id: String, preset: String?)
        case joined
        case ended(DuoEndedBy)
        /// `partner` or `superseded`.
        case reconnected(who: String)
        case digest(kinds: [String], days: [String], nudgeIDs: [String], preset: String?, count: Int?)
        /// A kind this build has never heard of: fetch, announce nothing.
        case unknown(String)
    }

    public var duoID: UUID
    public var seq: Int64?
    /// Android's `from_name`; iOS carries the name only in the notification's loc-args.
    public var fromName: String?
    public var kind: Kind

    public init(duoID: UUID, seq: Int64?, fromName: String? = nil, kind: Kind) {
        self.duoID = duoID
        self.seq = seq
        self.fromName = fromName
        self.kind = kind
    }

    /// The payload of an APNs notification: `v`, `t`, `duo`, `seq` and, by kind, `id`, `day`
    /// and `kinds`, beside the `aps` dictionary. Nil if it is not a Duo push.
    public static func parse(userInfo: [AnyHashable: Any]) -> DuoPushPayload? {
        var data: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, key != "aps" else { continue }
            if let text = value as? String {
                data[key] = text
            } else if let number = value as? NSNumber {
                data[key] = number.stringValue
            } else if let list = value as? [String] {
                data[key] = list.joined(separator: ",")
            }
        }
        return parse(data: data)
    }

    /// The same, from a map of strings (Android's data message, and the common form both read).
    public static func parse(data: [String: String]) -> DuoPushPayload? {
        guard let t = data["t"], let duoText = data["duo"], let duoID = UUID(uuidString: duoText) else { return nil }
        let seq = data["seq"].flatMap { Int64($0) }
        func list(_ key: String) -> [String] {
            (data[key] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        let kind: Kind
        switch t {
        case "goal_met":
            guard let day = data["day"], DuoStreak.isDayKey(day) else { return nil }
            kind = .goalMet(day: day, iHaveToo: data["i_have_too"] == "1")
        case "nudge":
            guard let id = data["id"], DuoNudge.isNudgeRecordName(id) else { return nil }
            kind = .nudge(id: id, preset: data["preset"])
        case "joined":
            kind = .joined
        case "ended":
            kind = .ended(data["ended_by"].flatMap { DuoEndedBy(rawValue: $0) } ?? .unknown)
        case "reconnected":
            // The iOS payload carries who in its `loc-key` (`duo.reconnected.partner` or
            // `.superseded`) and not in the data, so an absent field says nothing: reading it as
            // "partner" labelled a superseded phone's "Not you? Leave & block" push as a partner's.
            kind = .reconnected(who: data["who"] ?? "unknown")
        case "digest":
            kind = .digest(kinds: list("kinds"), days: list("days"), nudgeIDs: list("nudge_ids"), preset: data["preset"],
                           count: data["count"].flatMap { Int($0) })
        default:
            kind = .unknown(t)
        }
        return DuoPushPayload(duoID: duoID, seq: seq, fromName: data["from_name"], kind: kind)
    }

    /// The ledger keys of the events this push announces, so each is marked seen once,
    /// whether the push or the app's own fetch gets there first (§9.5).
    public var ledgerKeys: [String] {
        switch kind {
        case .goalMet(let day, _): return [DuoLedger.goalKey(duoID: duoID, day: day)]
        case .nudge(let id, _): return [id]
        case .digest(_, let days, let nudgeIDs, _, _):
            return days.map { DuoLedger.goalKey(duoID: duoID, day: $0) } + nudgeIDs
        case .joined, .ended, .reconnected, .unknown: return []
        }
    }
}
