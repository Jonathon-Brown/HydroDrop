import Foundation
@testable import HydroCore

// Stage E's client vectors: KV20, the idempotent op replay (AND §15's KV20 row: "same key + same
// bytes -> replay; same key + a re-serialised body with a new updated_at -> must not happen (the
// client replays bytes)"), and the op queue's disposition table (final design §10.1). They stay
// out of `duo-vectors-v1.json` until the integration pass flips `Vectors.includesClientVectors`.
//
// Three functions:
//
// - `DuoQueuedOp.replayBytes`: a queued request holds the exact bytes it is sent with, and the
//   typed call it is replayed through writes those very bytes again (`DuoWireCoding.encode` of
//   `DuoWireCoding.decode` of the body), for a leave, a block, a `PATCH /me` with its name absent,
//   null and given, and a push upload with the Duo toggle on and off. `spec` is the body the
//   contract's schemas and §6.2 state (sorted snake_case keys, no spaces, an absent name left out
//   and a cleared one written as `null`), so a port that orders or spells a key otherwise fails.
// - `DuoInflightJournal.key`: two requests in turn for one operation, and whether the second is
//   sent under the first one's key. Same operation and same bytes inside 23 hours: the same key
//   (a replay the server answers from its record). New bytes, a new key: the server would refuse
//   an old key with new bytes (`422 idempotency_mismatch`), so a body rebuilt with a fresh
//   timestamp is a new request, and a client that means to repeat a request must replay the bytes
//   it recorded. An entry 23 hours old is not replayed (the server's record lasts 24). The journal
//   compares bytes and nothing else, so these bodies need not be any endpoint's.
// - `DuoOpQueue.disposition`: what one answer does to a queued entry, from the response as the
//   classifier reads it (or no response at all), to `done`, `drop`, `hold`, `discardAll` or
//   `wait:<seconds>`. `spec` is §10.1's rule and §6.7's delays, with the client outcomes the
//   reviews added: the client's own "no credential" and no response at all hold, and a 2xx that
//   cannot be read is done at the endpoint's own success status (it said it succeeded) and waits
//   at any other (a filter's page, never the server's answer).
// - `DuoOpQueue.next`: which entry a drain sends next when some groups must wait (D74: first in,
//   first out within the exits, the profile and the push token, and no group holds back another).
extension Vectors {
    static func exitCases() -> [Vector] {
        replayCases() + journalCases() + dispositionCases() + orderCases()
    }

    // MARK: Replay bytes

    private static func replayCases() -> [Vector] {
        let duo = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
        let at = instant("2026-10-08T09:00:00Z")
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        func vector(_ name: String, _ input: JSON, _ op: DuoQueuedOp, replayed: Data, spec: (method: String, path: String, body: String)) -> Vector {
            Vector(id: "KV20.replay.\(name)", fn: "DuoQueuedOp.replayBytes", input: input,
                   expect: ["method": .string(op.method), "path": .string(op.path), "body": .string(text(op.body)), "replayed": .string(text(replayed))],
                   spec: ["method": .string(spec.method), "path": .string(spec.path), "body": .string(spec.body), "replayed": .string(spec.body)])
        }
        func reencoded<T: Codable>(_ type: T.Type, _ op: DuoQueuedOp) -> Data {
            (try? DuoWireCoding.encode(try DuoWireCoding.decode(type, from: op.body))) ?? Data("<did not decode>".utf8)
        }
        var cases: [Vector] = []
        let path = "/duos/\(duo.uuidString.lowercased())"
        if let leave = try? DuoQueuedOp.leave(duoID: duo, key: "k", now: at) {
            cases.append(vector("leave", ["kind": "leave", "duoId": .string(duo.uuidString.lowercased())], leave,
                                replayed: reencoded(DuoWireEmptyRequest.self, leave), spec: ("POST", "\(path)/leave", "{}")))
        }
        if let block = try? DuoQueuedOp.block(duoID: duo, key: "k", now: at) {
            cases.append(vector("block", ["kind": "block", "duoId": .string(duo.uuidString.lowercased())], block,
                                replayed: reencoded(DuoWireEmptyRequest.self, block), spec: ("POST", "\(path)/block", "{}")))
        }
        let renames: [(String, DuoWireField<String>, JSON, String)] = [
            ("updateMe.nameAbsent", .absent, "absent", #"{"skin":"forest"}"#),
            ("updateMe.nameNull", .null, .null, #"{"display_name":null,"skin":"forest"}"#),
            ("updateMe.nameValue", .value("Jo"), "Jo", #"{"display_name":"Jo","skin":"forest"}"#),
        ]
        for (name, field, shown, body) in renames {
            guard let op = try? DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: field, skin: .value("forest")), key: "k", now: at) else { continue }
            cases.append(vector(name, ["kind": "updateMe", "displayName": shown, "skin": "forest"], op,
                                replayed: reencoded(DuoWireUpdateMeRequest.self, op), spec: ("PATCH", "/me", body)))
        }
        let uploads: [(String, DuoWireRegisterPushRequest, String)] = [
            ("registerPush.toggleOn",
             DuoWireRegisterPushRequest(token: "ab12", apnsEnv: "sandbox", tz: "Europe/London", wakeStartMin: 480, wakeEndMin: 1320,
                                        notificationsEnabled: true),
             #"{"apns_env":"sandbox","notifications_enabled":true,"platform":"apns","token":"ab12","token_kind":"apns","tz":"Europe/London","wake_end_min":1320,"wake_start_min":480}"#),
            // D36: the zone goes whichever way the toggle is, the window only with it on.
            ("registerPush.toggleOff",
             DuoWireRegisterPushRequest(token: "ab12", apnsEnv: "production", tz: "America/Los_Angeles", wakeStartMin: nil, wakeEndMin: nil,
                                        notificationsEnabled: false),
             #"{"apns_env":"production","notifications_enabled":false,"platform":"apns","token":"ab12","token_kind":"apns","tz":"America/Los_Angeles"}"#),
        ]
        for (name, request, body) in uploads {
            guard let op = try? DuoQueuedOp.registerPush(request, firstUpload: false, key: "k", now: at) else { continue }
            cases.append(vector(name, ["kind": "registerPush", "token": .string(request.token), "apnsEnv": request.apnsEnv.map { JSON.string($0) } ?? .null,
                                       "tz": request.tz.map { JSON.string($0) } ?? .null,
                                       "wakeStartMin": request.wakeStartMin.map { JSON.int($0) } ?? .null,
                                       "wakeEndMin": request.wakeEndMin.map { JSON.int($0) } ?? .null,
                                       "notificationsEnabled": .bool(request.notificationsEnabled)],
                                op, replayed: reencoded(DuoWireRegisterPushRequest.self, op), spec: ("PUT", "/devices/me/push", body)))
        }
        return cases
    }

    // MARK: The in-flight journal

    private static func journalCases() -> [Vector] {
        let invites = "POST /duos/6d2a0000-0000-4000-8000-000000000001/invites"
        let otherInvites = "POST /duos/6d2a0000-0000-4000-8000-000000000002/invites"
        let statuses = "PUT /duos/6d2a0000-0000-4000-8000-000000000001/statuses"
        let invite = #"{"purpose":"invite"}"#
        let reconnect = #"{"purpose":"reconnect"}"#
        let stamped = #"{"day":"2026-10-07","goal_met":true,"updated_at":"2026-10-07T21:00:00Z"}"#
        let restamped = #"{"day":"2026-10-07","goal_met":true,"updated_at":"2026-10-07T21:00:05Z"}"#
        // (id, first operation, first body, second operation, second body, seconds between,
        //  stated: the second is sent under the first's key, stated: entries kept)
        let rows: [(String, String, String, String, String, Int, Bool, Int)] = [
            ("sameBytes", invites, invite, invites, invite, 3_600, true, 1),
            ("differentBytes", invites, invite, invites, reconnect, 60, false, 1),
            ("reserialisedWithANewUpdatedAt", statuses, stamped, statuses, restamped, 5, false, 1),
            ("sameBytesOnAnotherDuosPath", invites, invite, otherInvites, invite, 60, false, 2),
            ("justUnderTheLifetime", invites, invite, invites, invite, 23 * 3_600 - 1, true, 1),
            ("atTheLifetime", invites, invite, invites, invite, 23 * 3_600, false, 1),
        ]
        let first = instant("2026-10-08T09:00:00Z")
        return rows.map { name, firstOperation, firstBody, secondOperation, secondBody, gap, sameKey, entries in
            var journal = DuoInflightJournal()
            let random = SequentialRandom()
            let second = first.addingTimeInterval(TimeInterval(gap))
            let one = journal.key(for: firstOperation, body: Data(firstBody.utf8), now: first, random: random)
            let two = journal.key(for: secondOperation, body: Data(secondBody.utf8), now: second, random: random)
            return Vector(id: "KV20.journal.\(name)", fn: "DuoInflightJournal.key",
                          input: ["first": ["operation": .string(firstOperation), "body": .string(firstBody), "at": .string(iso(first))],
                                  "second": ["operation": .string(secondOperation), "body": .string(secondBody), "at": .string(iso(second))]],
                          expect: ["sameKey": .bool(one == two), "entries": .int(journal.entries.count)],
                          spec: ["sameKey": .bool(sameKey), "entries": .int(entries)])
        }
    }

    // MARK: The disposition table

    private enum ExitAnswer {
        case success
        case offline
        case noCredential
        case unreadable(Int)
        case response(status: Int, contentType: String, retryAfter: String?, body: String)
    }

    private static func dispositionCases() -> [Vector] {
        let json = "application/json"
        let html = "text/html; charset=UTF-8"
        func envelope(_ code: String) -> String { #"{"error":{"code":"\#(code)","message":"m","request_id":"9b1c2d3e4f5a6b7c-LHR"}}"# }
        func coded(_ status: Int, _ code: String, retryAfter: String? = nil) -> ExitAnswer {
            .response(status: status, contentType: json, retryAfter: retryAfter, body: envelope(code))
        }
        // (id, kind, answer, stated disposition)
        let rows: [(String, DuoOpKind, ExitAnswer, String)] = [
            ("leaveDone", .leave, .success, "done"),
            ("leaveDuoUnknown", .leave, coded(404, "duo_unknown"), "done"),
            ("blockDuoUnknown", .block, coded(404, "duo_unknown"), "done"),
            ("leaveDuoEnded", .leave, coded(409, "duo_ended"), "done"),
            ("leaveUnauthenticated", .leave, coded(401, "unauthenticated"), "discardAll"),
            ("leaveNoCredential", .leave, .noCredential, "hold"),
            ("leaveDeviceRevoked", .leave, coded(401, "device_revoked"), "drop"),
            // D33: a banned member keeps `DELETE /me` alone, so a queued leave is refused for good.
            ("leaveBanned", .leave, coded(403, "banned"), "drop"),
            ("blockBanned", .block, coded(403, "banned"), "drop"),
            ("leaveWafForbidden", .leave, .response(status: 403, contentType: html, retryAfter: nil, body: "<html>blocked</html>"), "wait:60"),
            // D63: a 401 without the envelope is a captive portal or a proxy, never a gone identity.
            ("leaveBare401", .leave, .response(status: 401, contentType: html, retryAfter: nil, body: "<html>log in to the Wi-Fi</html>"), "wait:60"),
            ("leaveRateLimitedShort", .leave, coded(429, "rate_limited", retryAfter: "5"), "wait:30"),
            ("leaveRateLimitedLong", .leave, coded(429, "rate_limited", retryAfter: "120"), "wait:120"),
            ("leaveMaintenance", .leave, coded(503, "maintenance"), "wait:60"),
            ("leaveBadGateway", .leave, .response(status: 502, contentType: html, retryAfter: nil, body: "<html>502</html>"), "wait:60"),
            ("leaveOffline", .leave, .offline, "wait:60"),
            ("leaveUnreadable2xx", .leave, .unreadable(200), "done"),
            ("leaveNoResponse", .leave, .unreadable(0), "hold"),
            ("registerPushUnreadable2xx", .registerPush, .unreadable(200), "wait:60"),
            ("blockAnswered200ByAFilter", .block, .unreadable(200), "wait:60"),
            ("updateMeUnreadable2xx", .updateMe, .unreadable(200), "done"),
            ("leaveUnknownCode404", .leave, coded(404, "duo_frozen"), "drop"),
            ("leaveUnknownCode401", .leave, coded(401, "session_frozen"), "wait:60"),
            ("updateMeNameRejected", .updateMe, coded(422, "name_rejected"), "drop"),
            ("updateMeUpgradeRequired", .updateMe, coded(426, "upgrade_required"), "drop"),
            ("updateMeDeviceRevoked", .updateMe, coded(401, "device_revoked"), "drop"),
            ("updateMeOffline", .updateMe, .offline, "wait:60"),
            ("registerPushAttestInvalid", .registerPush, coded(403, "attest_invalid"), "drop"),
            ("registerPushDuoUnknown", .registerPush, coded(404, "duo_unknown"), "drop"),
            ("registerPushNoCredential", .registerPush, .noCredential, "hold"),
            ("unregisterPushDone", .unregisterPush, .success, "done"),
            ("unregisterPushUnauthenticated", .unregisterPush, coded(401, "unauthenticated"), "discardAll"),
        ]
        let duo = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
        let at = instant("2026-10-08T09:00:00Z")
        return rows.compactMap { name, kind, answer, stated in
            let op: DuoQueuedOp?
            switch kind {
            case .leave: op = try? DuoQueuedOp.leave(duoID: duo, key: "k", now: at)
            case .block: op = try? DuoQueuedOp.block(duoID: duo, key: "k", now: at)
            case .updateMe: op = try? DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value("Jo")), key: "k", now: at)
            case .registerPush:
                op = try? DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "ab12", apnsEnv: "sandbox", tz: "UTC", wakeStartMin: nil,
                                                                              wakeEndMin: nil, notificationsEnabled: false),
                                                   firstUpload: true, key: "k", now: at)
            case .unregisterPush: op = DuoQueuedOp.unregisterPush(key: "k", now: at)
            }
            guard let op else { return nil }
            let error: Error?
            var input: [String: JSON] = ["kind": .string(kind.rawValue)]
            switch answer {
            case .success:
                error = nil
                input["outcome"] = "success"
            case .offline:
                error = DuoTransportError.offline
                input["outcome"] = "offline"
            case .noCredential:
                error = DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0))
                input["outcome"] = "noCredential"
            case .unreadable(let status):
                error = DuoTransportError.unreadable(httpStatus: status, requestID: nil)
                input["outcome"] = "unreadable"
                input["status"] = .int(status)
            case .response(let status, let contentType, let retryAfter, let body):
                error = DuoErrorClassifier.classify(status: status, contentType: contentType, retryAfter: retryAfter, requestID: nil,
                                                    body: Data(body.utf8))
                input["outcome"] = "response"
                input["status"] = .int(status)
                input["contentType"] = .string(contentType)
                input["retryAfter"] = retryAfter.map { JSON.string($0) } ?? .null
                input["body"] = .string(body)
            }
            return Vector(id: "KV20.disposition.\(name)", fn: "DuoOpQueue.disposition", input: .object(input),
                          expect: .string(exitDispositionName(DuoOpQueue.disposition(for: op, error: error))), spec: .string(stated))
        }
    }

    // MARK: Order (D74)

    private static func orderCases() -> [Vector] {
        let at = instant("2026-10-08T09:00:00Z")
        let duoA = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
        let duoB = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
        func op(_ kind: DuoOpKind, _ key: String) -> DuoQueuedOp? {
            switch kind {
            case .leave: return try? DuoQueuedOp.leave(duoID: key.hasSuffix("b") ? duoB : duoA, key: key, now: at)
            case .block: return try? DuoQueuedOp.block(duoID: key.hasSuffix("b") ? duoB : duoA, key: key, now: at)
            case .updateMe: return try? DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value(key)), key: key, now: at)
            case .registerPush:
                return try? DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: key, apnsEnv: "sandbox", tz: "UTC", wakeStartMin: nil,
                                                                                wakeEndMin: nil, notificationsEnabled: false),
                                                     firstUpload: false, key: key, now: at)
            case .unregisterPush: return DuoQueuedOp.unregisterPush(key: key, now: at)
            }
        }
        // (id, the queue oldest first, the groups that must wait, stated next key or nil)
        let rows: [(String, [(DuoOpKind, String)], [DuoOpQueue.Group], String?)] = [
            ("nothingWaits", [(.updateMe, "rename"), (.block, "block")], [], "rename"),
            ("aWaitingRenameDoesNotHoldABlock", [(.updateMe, "rename"), (.block, "block")], [.profile], "block"),
            ("aWaitingBlockHoldsTheLeaveBehindIt", [(.block, "block"), (.leave, "leave-b"), (.updateMe, "rename")], [.exits], "rename"),
            ("aRemovalNeverOvertakesItsUpload", [(.registerPush, "upload"), (.unregisterPush, "removal")], [.push], nil),
            ("everyGroupWaits", [(.leave, "leave"), (.updateMe, "rename"), (.registerPush, "upload")], [.exits, .profile, .push], nil),
        ]
        return rows.compactMap { name, entries, blocked, stated in
            let ops = entries.compactMap { op($0.0, $0.1) }
            guard ops.count == entries.count else { return nil }
            let next = DuoOpQueue(ops).next(skipping: Set(blocked))
            return Vector(id: "KV20.order.\(name)", fn: "DuoOpQueue.next",
                          input: ["queue": .array(entries.map { ["kind": .string($0.0.rawValue), "key": .string($0.1)] }),
                                  "waiting": .array(blocked.map { .string($0.rawValue) })],
                          expect: next.map { JSON.string($0.key) } ?? .null, spec: stated.map { JSON.string($0) } ?? .null)
        }
    }

    /// A disposition as a port can spell it, a wait with its delay in whole seconds. Named for this
    /// stage, since `Vectors` is shared by every stage's provider.
    static func exitDispositionName(_ disposition: DuoOpQueue.Disposition) -> String {
        switch disposition {
        case .done: return "done"
        case .drop: return "drop"
        case .hold: return "hold"
        case .discardAll: return "discardAll"
        case .wait(let after): return "wait:\(Int(after))"
        }
    }
}
