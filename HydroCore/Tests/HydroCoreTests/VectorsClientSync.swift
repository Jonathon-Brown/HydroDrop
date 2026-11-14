import Foundation
@testable import HydroCore

// Stage C's client vectors: the sync engine's pure steps (final design §8.9's KV11, KV12 and
// KV14 rows and the client halves of X7, X8, X10 and X14). Each case's `in` holds every input the
// function reads, the time zone of its calendar included, and `spec` is the design's answer:
// KV11 as §8.9 restates it for the `base_ver` CAS (known ver 37 sends base_ver 37; a conflict
// with current ver 40 updates known and the next diff sends 40; a conflict with no current drops
// the day's ver; a first write before any read is refused by the plan), KV12 and KV14 as AND §15
// states them, and the X rows as the §8.9 table states them. Added to `syncCases()` only; the file
// stays out of `duo-vectors-v1.json` until the integration pass flips `Vectors.includesClientVectors`.
extension Vectors {
    static func syncCases() -> [Vector] {
        syncVerCases() + syncHandledCases() + syncTotalsCases() + syncReplayCases() + syncStampCases() + syncZoneCases() + syncDeliveredCases()
    }

    // MARK: Building blocks

    private static let syncDuoID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
    private static let syncNudgeID = "nudge-8F2A0000-0000-4000-8000-000000000002"

    private static func syncDuo(statuses: [DuoDayStatus] = [], vers: [String: Int64] = [:], cursor: Int64 = 410, syncedOnce: Bool = true,
                                nudges: [DuoNudge] = []) -> DuoState {
        DuoState(id: syncDuoID, myRole: .owner, createdAt: instant("2026-09-16T10:00:00Z"), ownerDisplayName: "Jo", partnerDisplayName: "Sam",
                 ownerSkin: "classic", partnerSkin: "forest", statuses: statuses, partnerHasJoined: true, nudges: nudges, cursor: cursor,
                 vers: vers, syncedOnce: syncedOnce)
    }

    private static func syncHeader(seq: Int64) -> DuoWireHeader {
        DuoWireHeader(id: syncDuoID.uuidString.lowercased(), myRole: .owner, state: .active, createdAt: instant("2026-09-16T10:00:00Z"),
                      joinedAt: instant("2026-09-17T10:00:00Z"), ownerDisplayName: "Jo", ownerSkin: "classic", partnerDisplayName: "Sam",
                      partnerSkin: "forest", seq: seq)
    }

    private static func syncDuoJSON(_ duo: DuoState) -> JSON {
        ["myRole": .string(duo.myRole.rawValue), "known": statusesJSON(duo.statuses), "vers": syncVersJSON(duo.vers),
         "cursor": .int(Int(duo.cursor)), "syncedOnce": .bool(duo.syncedOnce)]
    }

    private static func syncVersJSON(_ vers: [String: Int64]) -> JSON { .object(vers.mapValues { .int(Int($0)) }) }

    private static func syncRowJSON(_ row: DuoWireStatusRow) -> JSON {
        ["role": .string(row.role.rawValue), "day": .string(row.day), "goalMet": .bool(row.goalMet), "bucket": .int(row.progressBucket),
         "updatedAt": .string(iso(row.updatedAt)), "ver": .int(Int(row.ver))]
    }

    private static func syncRejectedJSON(_ rejected: [DuoWireRejected]) -> JSON {
        .array(rejected.map { ["day": .string($0.day), "reason": .string($0.reason.rawValue), "current": $0.current.map(syncRowJSON) ?? .null] })
    }

    private static func syncRequestJSON(_ write: DuoSyncPlan.Write?) -> JSON {
        guard let write else { return .null }
        return .array(write.request.statuses.map {
            ["day": .string($0.day), "goalMet": .bool($0.goalMet), "bucket": .int($0.progressBucket), "baseVer": .int(Int($0.baseVer))]
        })
    }

    private static func syncNudgeJSON(_ nudge: DuoWireNudge) -> JSON {
        ["id": .string(nudge.id), "fromRole": .string(nudge.fromRole.rawValue), "presetId": .string(nudge.presetId),
         "createdAt": .string(iso(nudge.createdAt))]
    }

    private static func syncSummary(_ totals: [String: Int]) -> DuoLogSummary {
        DuoLogSummary(totalsByDay: totals, goalML: 2000, earliestEntryDay: "2026-01-01")
    }

    private static func syncWrite(_ duo: DuoState, totals: [String: Int], myToday: String, now: String,
                                  outcome: DuoRebase.Outcome? = nil) -> DuoSyncPlan.Write? {
        DuoSyncPlan.write(for: duo, summary: syncSummary(totals), coverageStart: "2026-01-01", rejectedDays: outcome?.rejectedDays ?? DuoRejectedDays(),
                          holding: outcome?.heldRows ?? [], myToday: myToday, now: instant(now), calendar: utc).write
    }

    private static func syncAnswer(unchanged: [String] = [], rejected: [DuoWireRejected] = []) -> DuoWireChangesWithResult {
        DuoWireChangesWithResult(changes: DuoWireChanges(duo: syncHeader(seq: 411), full: false, statuses: [], nudges: [], handled: [], cursor: 411),
                                 accepted: [], unchanged: unchanged, rejected: rejected)
    }

    // MARK: KV11

    private static func syncVerCases() -> [Vector] {
        let today = "2026-09-24", now = "2026-09-24T18:00:00Z"
        let totals = [today: 1000]
        let known = syncDuo(statuses: [status(.owner, today, false, 25)], vers: ["owner-\(today)": 37])
        func input(_ duo: DuoState, rejected: [DuoWireRejected]? = nil) -> JSON {
            var members: [String: JSON] = ["duo": syncDuoJSON(duo), "totals": .object(totals.mapValues { .int($0) }), "goalML": 2000,
                                           "myToday": .string(today), "now": .string(now), "zone": "UTC", "coverageStart": "2026-01-01"]
            if let rejected { members["rejected"] = syncRejectedJSON(rejected) }
            return .object(members)
        }
        func rebased(_ rejected: [DuoWireRejected]) -> (DuoState, DuoRebase.Outcome) {
            let sent = syncWrite(known, totals: totals, myToday: today, now: now)!
            return DuoRebase.apply(syncAnswer(rejected: rejected), sent: sent.rows, to: known, rejectedDays: DuoRejectedDays())
        }
        let conflict = [DuoWireRejected(day: today, reason: .verConflict,
                                        current: DuoWireStatusRow(role: .owner, day: today, goalMet: false, progressBucket: 75,
                                                                  updatedAt: instant("2026-09-24T17:00:00Z"), ver: 40))]
        let (afterConflict, conflictOutcome) = rebased(conflict)
        let noCurrent = [DuoWireRejected(day: today, reason: .verConflict)]
        let (afterNoCurrent, noCurrentOutcome) = rebased(noCurrent)
        let unread = syncDuo(cursor: 0, syncedOnce: false)
        return [
            Vector(id: "KV11.baseVer", fn: "DuoSyncPlan.write", input: input(known),
                   expect: syncRequestJSON(syncWrite(known, totals: totals, myToday: today, now: now)),
                   spec: [["day": .string(today), "goalMet": false, "bucket": 50, "baseVer": 37]]),
            Vector(id: "KV11.conflictWithCurrent", fn: "DuoRebase.apply+DuoSyncPlan.write", input: input(known, rejected: conflict),
                   expect: ["vers": syncVersJSON(afterConflict.vers), "retry": .bool(conflictOutcome.needsRetry),
                            "next": syncRequestJSON(syncWrite(afterConflict, totals: totals, myToday: today, now: now, outcome: conflictOutcome))],
                   spec: ["vers": ["owner-\(today)": 40], "retry": true,
                          "next": [["day": .string(today), "goalMet": false, "bucket": 50, "baseVer": 40]]]),
            Vector(id: "KV11.conflictWithoutCurrent", fn: "DuoRebase.apply+DuoSyncPlan.write", input: input(known, rejected: noCurrent),
                   expect: ["vers": syncVersJSON(afterNoCurrent.vers), "known": untimed(afterNoCurrent.statuses), "retry": .bool(noCurrentOutcome.needsRetry),
                            "next": syncRequestJSON(syncWrite(afterNoCurrent, totals: totals, myToday: today, now: now, outcome: noCurrentOutcome))],
                   spec: ["vers": [:], "known": [], "retry": true,
                          "next": [["day": .string(today), "goalMet": false, "bucket": 50, "baseVer": 0]]]),
            Vector(id: "KV11.firstWriteBeforeAnyRead", fn: "DuoSyncPlan.write", input: input(unread),
                   expect: syncRequestJSON(syncWrite(unread, totals: totals, myToday: today, now: now)),
                   spec: .null),
        ]
    }

    // MARK: KV12

    private static func syncHandledCases() -> [Vector] {
        let today = "2026-09-21", now = "2026-09-21T15:00:00Z"
        let nudge = DuoWireNudge(id: syncNudgeID, fromRole: .partner, presetId: "sipWithMe", createdAt: instant("2026-09-21T14:00:00Z"))
        func run(_ id: String, handled: [DuoWireHandled], spec: JSON) -> Vector {
            let changes = DuoWireChanges(duo: syncHeader(seq: 9), full: false, statuses: [], nudges: [nudge], handled: handled, cursor: 9)
            let before = syncDuo(cursor: 5)
            let first = DuoSyncPlan.process(changes: changes, before: before, ledger: DuoLedger(), deliveredRemoteKeys: [], myToday: today,
                                            now: instant(now), calendar: utc)!
            // The same feed read again (a push and a refresh that both fetch), against what the first left.
            let again = DuoSyncPlan.process(changes: changes, before: first.duo, ledger: first.ledger, deliveredRemoteKeys: [], myToday: today,
                                            now: instant(now), calendar: utc)!
            return Vector(id: id, fn: "DuoSyncPlan.process",
                          input: ["before": syncDuoJSON(before), "nudges": .array([syncNudgeJSON(nudge)]),
                                  "handled": .array(handled.map { ["kind": .string($0.kind), "day": $0.day.map { JSON.string($0) } ?? .null,
                                                                   "id": $0.id.map { JSON.string($0) } ?? .null] }),
                                  "ledger": .array([]), "delivered": .array([]), "myToday": .string(today), "now": .string(now), "zone": "UTC"],
                          expect: ["announced": .array(first.announcements.map { .string($0.key) }), "seen": .array(first.ledger.seen.map { .string($0) }),
                                   "announcedAgain": .array(again.announcements.map { .string($0.key) })],
                          spec: spec)
        }
        return [
            run("KV12.handledThenPlan", handled: [DuoWireHandled(kind: "nudge", id: syncNudgeID)],
                spec: ["announced": [], "seen": [.string(syncNudgeID)], "announcedAgain": []]),
            run("KV12.notHandled", handled: [],
                spec: ["announced": [.string(syncNudgeID)], "seen": [.string(syncNudgeID)], "announcedAgain": []]),
        ]
    }

    // MARK: KV14

    private static func syncTotalsCases() -> [Vector] {
        func entriesJSON(_ entries: [DuoLogEntry]) -> JSON {
            .array(entries.map { ["timestamp": .string(iso($0.timestamp)), "hydratedML": .int($0.hydratedML), "source": .string($0.source)] })
        }
        let evening = [DuoLogEntry(timestamp: instant("2026-09-20T23:30:00-07:00"), hydratedML: 500, source: DuoLogEntry.hydroDropSource)]
        let mixed = [DuoLogEntry(timestamp: instant("2026-09-21T09:00:00Z"), hydratedML: 1500, source: DuoLogEntry.hydroDropSource),
                     DuoLogEntry(timestamp: instant("2026-09-21T10:00:00Z"), hydratedML: 600, source: "health_connect")]
        let mixedTotals = DuoLogTotals.totalsByDay(mixed, calendar: utc)
        let day = mixedTotals["2026-09-21"] ?? 0
        return [
            Vector(id: "KV14.zoneChange", fn: "DuoLogTotals.totalsByDay", input: ["entries": entriesJSON(evening), "zone": "Asia/Tokyo"],
                   expect: .object(DuoLogTotals.totalsByDay(evening, calendar: calendar("Asia/Tokyo")).mapValues { .int($0) }),
                   spec: ["2026-09-21": 500]),
            Vector(id: "KV14.healthConnectExcluded", fn: "DuoLogTotals.totalsByDay+DuoProgress",
                   input: ["entries": entriesJSON(mixed), "zone": "UTC", "goalML": 2000],
                   expect: ["totals": .object(mixedTotals.mapValues { .int($0) }), "bucket": .int(DuoProgress.bucket(totalML: day, goalML: 2000)),
                            "goalMet": .bool(DuoProgress.goalMet(totalML: day, goalML: 2000))],
                   spec: ["totals": ["2026-09-21": 1500], "bucket": 75, "goalMet": false]),
        ]
    }

    // MARK: X7

    private static func syncReplayCases() -> [Vector] {
        // The first write (base_ver 3) was accepted as ver 4 and its answer lost; the phone replays
        // the same rows, and the server answers with a conflict whose current is what was sent, or
        // with `unchanged`. Either way the re-diff is empty and there is no third request.
        let today = "2026-09-24", now = "2026-09-24T18:00:00Z"
        let totals = [today: 1000]
        let duo = syncDuo(statuses: [status(.owner, today, false, 25)], vers: ["owner-\(today)": 3])
        let sent = syncWrite(duo, totals: totals, myToday: today, now: now)!
        let current = DuoWireStatusRow(role: .owner, day: today, goalMet: false, progressBucket: 50, updatedAt: instant("2026-09-24T17:59:00Z"), ver: 4)
        func run(_ name: String, unchanged: [String], rejected: [DuoWireRejected]) -> Vector {
            let (after, outcome) = DuoRebase.apply(syncAnswer(unchanged: unchanged, rejected: rejected), sent: sent.rows, to: duo,
                                                   rejectedDays: DuoRejectedDays())
            return Vector(id: "X7.client.\(name)", fn: "DuoRebase.apply+DuoSyncPlan.write",
                          input: ["duo": syncDuoJSON(duo), "totals": .object(totals.mapValues { .int($0) }), "goalML": 2000, "myToday": .string(today),
                                  "now": .string(now), "zone": "UTC", "coverageStart": "2026-01-01", "sent": syncRequestJSON(sent),
                                  "unchanged": .array(unchanged.map { .string($0) }), "rejected": syncRejectedJSON(rejected)],
                          expect: ["next": syncRequestJSON(syncWrite(after, totals: totals, myToday: today, now: now, outcome: outcome))],
                          spec: ["next": .null])
        }
        return [
            run("conflictWithIdenticalCurrent", unchanged: [], rejected: [DuoWireRejected(day: today, reason: .verConflict, current: current)]),
            run("unchanged", unchanged: [today], rejected: []),
        ]
    }

    // MARK: X8

    private static func syncStampCases() -> [Vector] {
        // The phone's clock is three hours slow. What it knows of its own row afterwards carries
        // the server's time from the write's feed, never the time the phone sent it at (§8.2).
        let today = "2026-09-24", serverTime = "2026-09-24T18:00:00Z", phoneTime = "2026-09-24T15:00:00Z"
        let duo = syncDuo(statuses: [status(.owner, today, false, 25, instant("2026-09-24T12:00:00Z"))], vers: ["owner-\(today)": 3])
        let sent = syncWrite(duo, totals: [today: 1000], myToday: today, now: phoneTime)!
        let row = DuoWireStatusRow(role: .owner, day: today, goalMet: false, progressBucket: 50, updatedAt: instant(serverTime), ver: 4)
        let changes = DuoWireChanges(duo: syncHeader(seq: 411), full: false, statuses: [row], nudges: [], handled: [], cursor: 411)
        let fed = DuoSyncPlan.process(changes: changes, before: duo, ledger: DuoLedger(), deliveredRemoteKeys: [], myToday: today,
                                      now: instant(phoneTime), calendar: utc)!
        let (after, _) = DuoRebase.apply(DuoWireChangesWithResult(changes: changes, accepted: [today], unchanged: [], rejected: []),
                                         sent: sent.rows, to: fed.duo, rejectedDays: DuoRejectedDays())
        return [
            Vector(id: "X8.client", fn: "DuoSyncPlan.process+DuoRebase.apply",
                   input: ["duo": syncDuoJSON(duo), "sent": syncRequestJSON(sent), "phoneNow": .string(phoneTime), "feed": .array([syncRowJSON(row)]),
                           "accepted": [.string(today)], "myToday": .string(today), "zone": "UTC"],
                   expect: ["known": statusesJSON(after.statuses), "vers": syncVersJSON(after.vers)],
                   spec: ["known": [["role": "owner", "day": .string(today), "goalMet": false, "bucket": 50, "updatedAt": .string(serverTime)]],
                          "vers": ["owner-\(today)": 4]]),
        ]
    }

    // MARK: X10

    private static func syncZoneCases() -> [Vector] {
        // One drink at 03:00Z on the 29th: the 28th in Los Angeles, the 29th in Tokyo. The phone
        // published the 28th as met from Los Angeles and is now in Tokyo, where the last week is
        // judged again: the 29th is met and the 28th, now empty, is written as missed (§8.4).
        let drink = [DuoLogEntry(timestamp: instant("2026-09-29T03:00:00Z"), hydratedML: 2000, source: DuoLogEntry.hydroDropSource)]
        let la = DuoLogTotals.totalsByDay(drink, calendar: calendar("America/Los_Angeles"))
        let tokyo = DuoLogTotals.totalsByDay(drink, calendar: calendar("Asia/Tokyo"))
        let known = [status(.owner, "2026-09-28", true, 100)]
        let now = "2026-09-29T04:00:00Z"
        let unsent = DuoOutbox.unsent(role: .owner, totalsByDay: tokyo, goalML: 2000, known: known, myToday: "2026-09-29", now: instant(now),
                                      coverageStart: DuoOutbox.coveredForever, calendar: calendar("Asia/Tokyo"))
        return [
            Vector(id: "X10.client", fn: "DuoLogTotals.totalsByDay+DuoOutbox.unsent",
                   input: ["entries": [["timestamp": "2026-09-29T03:00:00Z", "hydratedML": 2000, "source": "hydrodrop"]], "goalML": 2000,
                           "known": statusesJSON(known), "myToday": "2026-09-29", "now": .string(now), "zone": "Asia/Tokyo",
                           "previousZone": "America/Los_Angeles", "coverageStart": .string(DuoOutbox.coveredForever)],
                   expect: ["losAngeles": .object(la.mapValues { .int($0) }), "tokyo": .object(tokyo.mapValues { .int($0) }), "unsent": untimed(unsent)],
                   spec: ["losAngeles": ["2026-09-28": 2000], "tokyo": ["2026-09-29": 2000],
                          "unsent": [["role": "owner", "day": "2026-09-29", "goalMet": true, "bucket": 100],
                                     ["role": "owner", "day": "2026-09-28", "goalMet": false, "bucket": 0]]]),
        ]
    }

    // MARK: X14

    private static func syncDeliveredCases() -> [Vector] {
        // The nudge's push row was sent and its `expires_at` has passed, so `handled` leaves it
        // out (§6.4's filter) and the plan decides alone: announced once, unless the remote
        // notification is still on this phone.
        let today = "2026-09-21", now = "2026-09-21T15:00:00Z"
        let nudge = DuoWireNudge(id: syncNudgeID, fromRole: .partner, presetId: "cheers", createdAt: instant("2026-09-21T08:00:00Z"))
        func run(_ name: String, delivered: Set<String>, spec: JSON) -> Vector {
            let changes = DuoWireChanges(duo: syncHeader(seq: 9), full: false, statuses: [], nudges: [nudge], handled: [], cursor: 9)
            let before = syncDuo(cursor: 5)
            let first = DuoSyncPlan.process(changes: changes, before: before, ledger: DuoLedger(), deliveredRemoteKeys: delivered, myToday: today,
                                            now: instant(now), calendar: utc)!
            let again = DuoSyncPlan.process(changes: changes, before: before, ledger: first.ledger, deliveredRemoteKeys: [], myToday: today,
                                            now: instant(now), calendar: utc)!
            return Vector(id: "X14.\(name)", fn: "DuoSyncPlan.process",
                          input: ["before": syncDuoJSON(before), "nudges": .array([syncNudgeJSON(nudge)]), "handled": .array([]),
                                  "delivered": .array(delivered.sorted().map { .string($0) }), "ledger": .array([]), "myToday": .string(today),
                                  "now": .string(now), "zone": "UTC"],
                          expect: ["announced": .array(first.announcements.map { .string($0.key) }), "seen": .array(first.ledger.seen.map { .string($0) }),
                                   "announcedAgain": .array(again.announcements.map { .string($0.key) })],
                          spec: spec)
        }
        return [
            run("expiredHandledNotDelivered", delivered: [], spec: ["announced": [.string(syncNudgeID)], "seen": [.string(syncNudgeID)], "announcedAgain": []]),
            run("expiredHandledDelivered", delivered: [syncNudgeID], spec: ["announced": [], "seen": [.string(syncNudgeID)], "announcedAgain": []]),
        ]
    }
}
