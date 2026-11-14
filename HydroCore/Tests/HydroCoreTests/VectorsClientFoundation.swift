import XCTest
@testable import HydroCore

// The foundation's own client vectors: KV1 (invite codes and links), KV4 (RFC 3339), KV10
// (the outbox with refused days), KV16 (a null name and an unknown skin) and KV17 (the gap
// rule). Every case carries the answer the final design states as `spec`, and the export
// checks the computed answer against it.

extension Vectors {
    static func foundationCases() -> [Vector] {
        inviteCodeCases() + wireTimeCases() + rejectedDayCases() + displayCases() + sequenceCases()
    }

    // MARK: KV1

    private static func inviteCodeCases() -> [Vector] {
        let secret = "ABCDEFGHJKMNPQRSTVWXYZ0123"
        let rows: [(String, String, String?, String?)] = [
            ("typedLowercase", "h7k3-9qwx", "H7K39QWX", nil),
            ("typedWithSpace", "H7K3 9QWX", "H7K39QWX", nil),
            ("typedO", "H7KO-9QWX", "H7K09QWX", nil),
            ("typedIAndL", "H7KI-9QWL", "H7K19QW1", nil),
            ("typedU", "H7K3-9QWU", nil, nil),
            ("typedShort", "H7K39QW", nil, nil),
            ("link", "https://hydrodrop.us/duo#H7K39QWX", "H7K39QWX", nil),
            ("linkWithSecret", "https://hydrodrop.us/duo#h7k39qwx.\(secret)", "H7K39QWX", secret),
            ("linkHttp", "http://hydrodrop.us/duo#H7K39QWX.\(secret)", nil, nil),
            ("linkQuery", "https://hydrodrop.us/duo?c=H7K39QWX", nil, nil),
            ("linkOtherPath", "https://hydrodrop.us/tap#H7K39QWX", nil, nil),
            ("linkOtherHost", "https://example.com/duo#H7K39QWX", nil, nil),
            ("linkShortSecret", "https://hydrodrop.us/duo#H7K39QWX.SHORT", nil, nil),
            ("linkLowercaseSecret", "https://hydrodrop.us/duo#H7K39QWX.abcdefghjkmnpqrstvwxyz0123", nil, nil),
            ("typedSharpS", "\u{DF}\u{DF}\u{DF}\u{DF}\u{DF}\u{DF}\u{DF}\u{DF}", nil, nil),
            ("typedFullWidth", "H7K\u{FF13}9QWX", nil, nil),
        ]
        return rows.map { name, text, code, k in
            func answer(_ parsed: DuoParsedInvite?) -> JSON {
                guard let parsed else { return .null }
                return ["code": .string(parsed.code), "k": parsed.k.map { JSON.string($0) } ?? .null]
            }
            let spec: JSON = code.map { ["code": .string($0), "k": k.map { JSON.string($0) } ?? .null] } ?? .null
            return Vector(id: "KV1.\(name)", fn: "DuoInviteCode.parse(pasted:)", input: ["text": .string(text)],
                          expect: answer(DuoInviteCode.parse(pasted: text)), spec: spec)
        }
    }

    // MARK: KV4

    private static func wireTimeCases() -> [Vector] {
        let rows: [(String, String, Int?)] = [
            ("zulu", "2026-09-24T18:11:09Z", 1_790_273_469_000),
            ("fraction", "2026-09-24T18:11:09.123Z", 1_790_273_469_123),
            ("zeroOffset", "2026-09-24T18:11:09+00:00", 1_790_273_469_000),
            ("tokyo", "2026-09-25T03:11:09+09:00", 1_790_273_469_000),
            ("toronto", "2026-09-24T14:11:09-04:00", 1_790_273_469_000),
            ("noZone", "2026-09-24T18:11:09", nil),
            ("compactOffset", "2026-09-24T18:11:09+0900", nil),
            ("impossibleDay", "2026-02-30T00:00:00Z", nil),
            ("leapSecond", "2026-12-31T23:59:60Z", 1_798_761_599_000),
        ]
        let parses = rows.map { name, text, millis -> Vector in
            let computed = DuoWireTime.parse(text).map { JSON.int(Int(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null
            return Vector(id: "KV4.parse.\(name)", fn: "DuoWireTime.parse", input: ["text": .string(text)], expect: computed,
                          spec: millis.map { JSON.int($0) } ?? .null)
        }
        let formats: [(String, Int, String)] = [
            ("epoch", 0, "1970-01-01T00:00:00Z"),
            ("beforeEpoch", -1, "1969-12-31T23:59:59Z"),
            ("leapDay", 1_835_481_599, "2028-02-29T23:59:59Z"),
            ("now", 1_790_273_469, "2026-09-24T18:11:09Z"),
        ]
        let emits = formats.map { name, seconds, text in
            Vector(id: "KV4.format.\(name)", fn: "DuoWireTime.format", input: ["epochSeconds": .int(seconds)],
                   expect: .string(DuoWireTime.format(Date(timeIntervalSince1970: TimeInterval(seconds)))), spec: .string(text))
        }
        return parses + emits
    }

    // MARK: KV10

    private static func rejectedDayCases() -> [Vector] {
        let now = "2026-09-30T12:00:00Z", today = "2026-09-30"
        func run(_ id: String, totals: [String: Int], rejected: [DuoDayStatus], spec: [DuoDayStatus]) -> Vector {
            var refused = DuoRejectedDays()
            rejected.forEach { refused.record($0) }
            let result = DuoOutbox.unsent(role: .owner, totalsByDay: totals, goalML: 2000, known: [], myToday: today, now: instant(now),
                                          rejectedDays: refused, calendar: utc)
            return Vector(id: id, fn: "DuoOutbox.unsent+rejectedDays",
                          input: ["role": "owner", "totals": .object(totals.mapValues { .int($0) }), "goalML": 2000, "known": .array([]),
                                  "myToday": .string(today), "now": .string(now), "zone": "UTC", "coverageStart": "0000-01-01",
                                  "rejected": statusesJSON(rejected)],
                          expect: statusesJSON(result), spec: untimed(spec), specIgnoresTimes: true)
        }
        let refusedToday = status(.owner, today, false, 25)
        return [
            // The server refused today's row at bucket 25; the log still says 25, so nothing is sent.
            run("KV10.unchanged", totals: [today: 500], rejected: [refusedToday], spec: []),
            // The log now says 50: a change in what is wanted is sent.
            run("KV10.changed", totals: [today: 1000], rejected: [refusedToday], spec: [status(.owner, today, false, 50)]),
            // No refusal on file: today is sent as usual.
            run("KV10.noneOnFile", totals: [today: 500], rejected: [], spec: [status(.owner, today, false, 25)]),
        ]
    }

    // MARK: KV16

    private static func displayCases() -> [Vector] {
        let known = ["classic", "sunrise", "forest", "grape", "midnight"]
        let rows: [(String, String?, String, String, String)] = [
            ("nullNameUnknownSkin", nil, "aurora", "Your partner", "classic"),
            ("name", "Sam", "forest", "Sam", "forest"),
            ("emptyName", "", "grape", "Your partner", "grape"),
        ]
        return rows.map { name, partnerName, skin, shownName, shownSkin in
            let state = DuoState(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, myRole: .owner, createdAt: epoch,
                                 ownerDisplayName: "Jo", partnerDisplayName: partnerName ?? "", ownerSkin: "classic", partnerSkin: skin,
                                 statuses: [], partnerHasJoined: true)
            return Vector(id: "KV16.\(name)", fn: "DuoMapping.display",
                          input: ["partnerDisplayName": partnerName.map { JSON.string($0) } ?? .null, "partnerSkin": .string(skin),
                                  "knownSkins": .array(known.map { .string($0) })],
                          expect: ["name": .string(state.displayName(of: .partner)),
                                   "skin": .string(DuoMapping.resolvedSkin(state.partnerSkin, known: Set(known)))],
                          spec: ["name": .string(shownName), "skin": .string(shownSkin)])
        }
    }

    // MARK: KV17

    private static func sequenceCases() -> [Vector] {
        let rows: [(String, Int, Int?, Bool)] = [("ahead", 418, 419, true), ("level", 418, 418, false), ("behind", 418, 3, false), ("none", 418, nil, true)]
        return rows.map { name, cursor, seq, expected in
            Vector(id: "KV17.\(name)", fn: "DuoPushGate.shouldFetch",
                   input: ["cursor": .int(cursor), "seq": seq.map { JSON.int($0) } ?? .null],
                   expect: .bool(DuoPushGate.shouldFetch(cursor: Int64(cursor), seq: seq.map(Int64.init))), spec: .bool(expected))
        }
    }
}

/// Every client case, from the foundation and from each stage, agrees with the answer it
/// states, and no id is used twice. This runs whether or not the file carries them yet.
final class DuoClientVectorsTests: XCTestCase {
    func testEveryClientCaseAgreesWithItsStatedAnswer() {
        let client = Vectors.clientCases()
        XCTAssertFalse(client.isEmpty)
        let base = Set((Vectors.streak() + Vectors.progress() + Vectors.outbox() + Vectors.coalescer() + Vectors.nudges()
                        + Vectors.announcements() + Vectors.quietHours() + Vectors.names() + Vectors.dayKeys()).map(\.id))
        XCTAssertEqual(Set(client.map(\.id)).count, client.count, "every case needs its own id")
        XCTAssertTrue(base.isDisjoint(with: client.map(\.id)), "a client case may not reuse a case id of the file")
        for vector in client {
            guard let spec = vector.spec else { continue }
            let computed = vector.specIgnoresTimes ? Vectors.withoutTimes(vector.expect) : vector.expect
            XCTAssertEqual(computed.rendered, spec.rendered, "\(vector.id) differs from its stated answer")
        }
    }

    func testTheFileCarriesTheClientCasesOnlyOnceTheIntegrationPassSaysSo() {
        XCTAssertEqual(Vectors.all().count, (Vectors.includesClientVectors ? Vectors.clientCases().count : 0) + 192)
    }
}
