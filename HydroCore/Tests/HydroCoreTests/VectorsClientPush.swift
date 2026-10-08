@testable import HydroCore

// Stage F's client vectors: KV13, the push payload as the data map both apps read (final design
// §9.2; AND §15's KV13 row: "one map per kind incl. digest; missing from_name; unknown t;
// unknown preset → typed events; 'Your partner'; fetch-only; fallback text"), and X15 as a client
// sees it (one digest for one duo naming both kinds, D53). Android receives this map as FCM data;
// iOS reads its APNs payload into the same map (`DuoPushPayload.parse(userInfo:)`), so one set of
// cases holds both.
//
// Each case's `in` is the map as sent, every value a string. `expect` is what
// `DuoPushPayload.parse(data:)` makes of it, or null when it is not a Duo push this build can act
// on: the duo (lowercase), `seq`, `fromName` as sent (null when absent, which a port shows as "Your
// partner"), the ledger keys the push marks seen (none for a kind that only says "fetch"), and the
// kind's own fields. A nudge's `line` is what `DuoNudgePreset.text(forID:)` shows for its preset,
// the fallback for one this build does not know. `spec` is written out by hand from §9.2's table
// and the rules beneath it.
extension Vectors {
    static func pushCases() -> [Vector] {
        let duo = "6d2a0000-0000-4000-8000-000000000001"
        let nudgeID = "nudge-8F2A0000-0000-4000-8000-000000000002"
        let laterNudgeID = "nudge-8F2A0000-0000-4000-8000-000000000003"
        let goalKey = "met|\(duo)|2026-09-24"

        func common(_ t: String, seq: String? = "419", fromName: String? = nil, _ extra: [String: String] = [:]) -> [String: String] {
            var map = ["v": "1", "t": t, "duo": duo]
            if let seq { map["seq"] = seq }
            if let fromName { map["from_name"] = fromName }
            return map.merging(extra) { $1 }
        }
        // (id, the map, the stated answer)
        let rows: [(String, [String: String], JSON)] = [
            ("goalMet", common("goal_met", fromName: "Alex", ["day": "2026-09-24", "i_have_too": "1"]),
             ["duo": .string(duo), "seq": 419, "fromName": "Alex", "ledgerKeys": [.string(goalKey)],
              "kind": "goal_met", "day": "2026-09-24", "iHaveToo": true]),
            ("goalMetYourTurn", common("goal_met", fromName: "Alex", ["day": "2026-09-24", "i_have_too": "0"]),
             ["duo": .string(duo), "seq": 419, "fromName": "Alex", "ledgerKeys": [.string(goalKey)],
              "kind": "goal_met", "day": "2026-09-24", "iHaveToo": false]),
            ("nudge", common("nudge", fromName: "Alex", ["id": nudgeID, "preset": "sipWithMe"]),
             ["duo": .string(duo), "seq": 419, "fromName": "Alex", "ledgerKeys": [.string(nudgeID)],
              "kind": "nudge", "id": .string(nudgeID), "preset": "sipWithMe", "line": "Sip with me?"]),
            // §9.2: a missing `from_name` is "Your partner", which is the reader's to show; the
            // payload says only that there is no name.
            ("nudgeNoName", common("nudge", ["id": nudgeID, "preset": "cheers"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [.string(nudgeID)],
              "kind": "nudge", "id": .string(nudgeID), "preset": "cheers", "line": "Cheers! I just had a glass."]),
            // A preset from a newer app is still a nudge, shown with the fallback line (01 §5.2).
            ("nudgeUnknownPreset", common("nudge", fromName: "Alex", ["id": nudgeID, "preset": "stretchBreak"]),
             ["duo": .string(duo), "seq": 419, "fromName": "Alex", "ledgerKeys": [.string(nudgeID)],
              "kind": "nudge", "id": .string(nudgeID), "preset": "stretchBreak", "line": "Time for some water?"]),
            ("joined", common("joined"),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "joined"]),
            ("endedOwner", common("ended", ["ended_by": "owner"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "owner"]),
            ("endedPartner", common("ended", ["ended_by": "partner"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "partner"]),
            ("endedOwnerDeleted", common("ended", ["ended_by": "owner_deleted"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "owner_deleted"]),
            ("endedPartnerDeleted", common("ended", ["ended_by": "partner_deleted"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "partner_deleted"]),
            ("endedInactive", common("ended", ["ended_by": "inactive"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "inactive"]),
            ("endedDemoExpired", common("ended", ["ended_by": "demo_expired"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "demo_expired"]),
            // An `ended_by` from a newer server is the client's own `unknown` (the foundation's
            // reading of §6.7), and so is none at all, which is what an APNs payload carries: iOS
            // gets the reason only in its loc-key.
            ("endedByANewerServer", common("ended", ["ended_by": "admin_end"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "unknown"]),
            ("endedWithNoReason", common("ended"),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "ended", "endedBy": "unknown"]),
            ("reconnectedPartner", common("reconnected", ["who": "partner"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "reconnected", "who": "partner"]),
            ("reconnectedSuperseded", common("reconnected", ["who": "superseded"]),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "reconnected", "who": "superseded"]),
            // An APNs payload carries `who` only in its loc-key, so an absent one says nothing:
            // read as "partner" it labelled a superseded phone's push as a partner's (69edd06).
            ("reconnectedWithNoWho", common("reconnected"),
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "reconnected", "who": "unknown"]),
            // Every field the digest can carry, a count among them, and two of each event.
            ("digest", common("digest", fromName: "Alex", ["kinds": "goal_met,nudge", "days": "2026-09-23,2026-09-24",
                                                           "nudge_ids": "\(nudgeID),\(laterNudgeID)", "preset": "soClose", "count": "4"]),
             ["duo": .string(duo), "seq": 419, "fromName": "Alex",
              "ledgerKeys": [.string("met|\(duo)|2026-09-23"), .string(goalKey), .string(nudgeID), .string(laterNudgeID)],
              "kind": "digest", "kinds": ["goal_met", "nudge"], "days": ["2026-09-23", "2026-09-24"],
              "nudgeIds": [.string(nudgeID), .string(laterNudgeID)], "preset": "soClose", "count": 4]),
            // §9.2: an unknown `t` is a reason to fetch and nothing more, so it marks nothing seen.
            ("unknownKind", common("streak_frozen", fromName: "Alex"),
             ["duo": .string(duo), "seq": 419, "fromName": "Alex", "ledgerKeys": [], "kind": "unknown", "t": "streak_frozen"]),
            // No `seq`: always worth a fetch (KV17).
            ("noSeq", common("joined", seq: nil),
             ["duo": .string(duo), "seq": nil, "fromName": nil, "ledgerKeys": [], "kind": "joined"]),
            // An uppercase duo id is the same duo, written the server's way (D25).
            ("uppercaseDuo", ["v": "1", "t": "joined", "duo": duo.uppercased(), "seq": "419"],
             ["duo": .string(duo), "seq": 419, "fromName": nil, "ledgerKeys": [], "kind": "joined"]),
            ("badDuoID", common("joined").merging(["duo": "6d2a0000-0000-4000-8000"]) { $1 }, nil),
            ("missingDuo", ["v": "1", "t": "joined", "seq": "419"], nil),
            ("missingKind", ["v": "1", "duo": duo, "seq": "419"], nil),
            // The nudge id is matched whole, as the server and Android match it (§6.6).
            ("badNudgeID", common("nudge", fromName: "Alex", ["id": "nudge-8F2A", "preset": "cheers"]), nil),
            ("nudgeIDWithATail", common("nudge", fromName: "Alex", ["id": nudgeID + "\n", "preset": "cheers"]), nil),
            ("badGoalDay", common("goal_met", fromName: "Alex", ["day": "2026-02-30", "i_have_too": "1"]), nil),
        ]
        let kv13 = rows.map { name, map, spec in
            Vector(id: "KV13.\(name)", fn: "DuoPushPayload.parse(data:)", input: .object(map.mapValues { .string($0) }),
                   expect: pushPayloadJSON(DuoPushPayload.parse(data: map)), spec: spec)
        }
        // X15 as the client sees it: two events of one duo held for one device until the same
        // instant arrive as one digest for that duo, naming both kinds, goal_met first (§9.4, D53).
        // The map is exactly what the server's `fcmData` writes for it, which carries no count.
        let x15Map = common("digest", seq: "421", fromName: "Alex", ["kinds": "goal_met,nudge", "days": "2026-09-24",
                                                                      "nudge_ids": nudgeID, "preset": "keepTheFlame"])
        let x15 = Vector(id: "X15.digestOfOneDuo", fn: "DuoPushPayload.parse(data:)", input: .object(x15Map.mapValues { .string($0) }),
                         expect: pushPayloadJSON(DuoPushPayload.parse(data: x15Map)),
                         spec: ["duo": .string(duo), "seq": 421, "fromName": "Alex", "ledgerKeys": [.string(goalKey), .string(nudgeID)],
                                "kind": "digest", "kinds": ["goal_met", "nudge"], "days": ["2026-09-24"], "nudgeIds": [.string(nudgeID)],
                                "preset": "keepTheFlame", "count": nil])
        return kv13 + [x15]
    }

    /// A parsed payload as a port can spell it. Named for this stage, since `Vectors` is shared
    /// by every stage's provider.
    static func pushPayloadJSON(_ payload: DuoPushPayload?) -> JSON {
        guard let payload else { return .null }
        var fields: [String: JSON] = [
            "duo": .string(payload.duoID.uuidString.lowercased()),
            "seq": payload.seq.map { JSON.int(Int($0)) } ?? .null,
            "fromName": payload.fromName.map { JSON.string($0) } ?? .null,
            "ledgerKeys": .array(payload.ledgerKeys.map { .string($0) }),
        ]
        func strings(_ list: [String]) -> JSON { .array(list.map { .string($0) }) }
        switch payload.kind {
        case .goalMet(let day, let iHaveToo):
            fields["kind"] = "goal_met"
            fields["day"] = .string(day)
            fields["iHaveToo"] = .bool(iHaveToo)
        case .nudge(let id, let preset):
            fields["kind"] = "nudge"
            fields["id"] = .string(id)
            fields["preset"] = preset.map { JSON.string($0) } ?? .null
            fields["line"] = .string(DuoNudgePreset.text(forID: preset ?? ""))
        case .joined:
            fields["kind"] = "joined"
        case .ended(let endedBy):
            fields["kind"] = "ended"
            fields["endedBy"] = .string(endedBy.rawValue)
        case .reconnected(let who):
            fields["kind"] = "reconnected"
            fields["who"] = .string(who)
        case .digest(let kinds, let days, let nudgeIDs, let preset, let count):
            fields["kind"] = "digest"
            fields["kinds"] = strings(kinds)
            fields["days"] = strings(days)
            fields["nudgeIds"] = strings(nudgeIDs)
            fields["preset"] = preset.map { JSON.string($0) } ?? .null
            fields["count"] = count.map { JSON.int($0) } ?? .null
        case .unknown(let t):
            fields["kind"] = "unknown"
            fields["t"] = .string(t)
        }
        return .object(fields)
    }
}
