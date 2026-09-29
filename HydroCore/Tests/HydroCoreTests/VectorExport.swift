// CryptoKit is Apple-only. Guarded so the rule tests still build where it's missing, such
// as a Linux toolchain; only the hash check needs it.
#if canImport(CryptoKit)
import CryptoKit
#endif
import XCTest
@testable import HydroCore

/// Writes and checks `HydroCore/Tests/Vectors/duo-vectors-v1.json`, the worked examples
/// that the server and the Android app must also pass.
///
/// The Duo rules exist three times: here in Swift, in the server's TypeScript and in the
/// Android app's Kotlin. None of them can run the others' code, so they are held together
/// by this one file of inputs and answers. Every answer in it is computed by calling the
/// HydroCore function it names, so the file is exactly what the Swift rules do, and the
/// file's SHA-256 is recorded next to it so that each of the three repositories can check
/// it has the same copy.
///
/// To regenerate after a deliberate change to a rule:
///
///     HYDROCORE_WRITE_VECTORS=1 swift test --filter VectorExport
///
/// then commit both files. Without that variable the test only compares, so a rule that
/// changes by accident fails here before it can quietly disagree with the other two.
///
/// Every case also carries a stated answer (`spec`) that the computed one is checked
/// against, so the export doubles as a check that the rules still say what was meant:
/// the final design's answer where it gives one, and a hand-worked answer for the cases
/// HydroCore adds (ids starting HC, and the cases the Phase 1 errata add). The computed
/// answer used to differ from the design on purpose for X9b (erratum 1) and
/// X1.edge.unpruned (erratum 6), where the design was wrong; the errata have since been
/// folded into the design, which now gives the same answers.
///
/// `fn` names the Swift function that produced the answer. A port implements the same
/// rule under its own name; `in` holds every input the function reads, including the
/// time zone of any calendar it uses.
///
/// Some of the design's vectors can't be generated yet, because the function they pin
/// doesn't exist in Swift in the form Duo v2 needs: the invite-code and link parser (KV1),
/// the duo id's case in ledger keys (KV3, which changes when ids come from the server),
/// RFC 3339 handling (KV4), rejected days (KV10), `ver` handling
/// (KV11), `handled` (KV12, X14), FCM parsing (KV13), totals by day and the Health Connect
/// exclusion (KV14, X10), error mapping (KV15), null names and unknown skins (KV16),
/// sequence gaps (KV17), idempotent replays (KV20), and the server's own behaviour (X6,
/// X7, X8, X11, X13, X15). They will be added when Phase 2 and the server write those
/// functions.
final class VectorExport: XCTestCase {
    /// Where a regenerated file is written: the source checkout. Only used on the Mac.
    private static let sourceFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Vectors")

    /// What a normal run compares against: the copy built into the test bundle. Xcode
    /// Cloud runs tests on a machine that has the bundle but not the source checkout, so
    /// reading the file through its source path would fail there.
    private static func bundled(_ name: String, _ ext: String?) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Vectors"),
                      "Vectors/\(name) is missing from the test bundle")
    }

    func testTheVectorsFileIsUpToDate() throws {
        let cases = Vectors.all()
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "every case needs its own id")
        for vector in cases {
            guard let spec = vector.spec else { continue }
            let computed = vector.specIgnoresTimes ? Vectors.withoutTimes(vector.expect) : vector.expect
            XCTAssertEqual(computed.rendered, spec.rendered, "\(vector.id) differs from its stated answer")
        }
        let fresh = Data(Vectors.file(cases).utf8)

        if ProcessInfo.processInfo.environment["HYDROCORE_WRITE_VECTORS"] == "1" {
            // A file whose answers disagree with their stated ones would pass on to the
            // other two implementations as if it were right, so it isn't written.
            guard (testRun?.failureCount ?? 0) == 0 else { return }
            guard let hash = Self.sha256(fresh) else {
                return XCTFail("regenerate on a Mac: the file's SHA256 needs CryptoKit")
            }
            try FileManager.default.createDirectory(at: Self.sourceFolder, withIntermediateDirectories: true)
            try fresh.write(to: Self.sourceFolder.appendingPathComponent("duo-vectors-v1.json"))
            try Data("\(hash)  duo-vectors-v1.json\n".utf8).write(to: Self.sourceFolder.appendingPathComponent("SHA256"))
            return
        }
        let committed = try Data(contentsOf: Self.bundled("duo-vectors-v1", "json"))
        XCTAssertTrue(committed == fresh, """
            duo-vectors-v1.json no longer matches what the rules compute\(Self.firstDifference(committed, fresh)). \
            If the change is deliberate, run `HYDROCORE_WRITE_VECTORS=1 swift test --filter \
            VectorExport` in HydroCore and commit both files; the server and the Android app \
            must then take the new file too.
            """)
    }

    func testTheRecordedHashMatchesTheFile() throws {
        let committed = try Data(contentsOf: Self.bundled("duo-vectors-v1", "json"))
        guard let hash = Self.sha256(committed) else {
            throw XCTSkip("CryptoKit isn't available here, so the hash can't be checked")
        }
        let recorded = try String(contentsOf: Self.bundled("SHA256", nil), encoding: .utf8).split(separator: " ").first.map(String.init)
        XCTAssertEqual(recorded, hash, "SHA256 must be the hash of duo-vectors-v1.json")
    }

    private static func sha256(_ data: Data) -> String? {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// Where the committed file and the computed one first part, naming the case. Some
    /// answers depend on the runtime's time zone rules and Unicode tables as well as on
    /// HydroCore, so a red run on a new Xcode Cloud image has to say which case moved.
    private static func firstDifference(_ committed: Data, _ fresh: Data) -> String {
        let old = String(decoding: committed, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let new = String(decoding: fresh, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for (index, (was, now)) in zip(old, new).enumerated() where was != now {
            let id = now.range(of: "\"id\":\"").flatMap { start -> String? in
                let rest = now[start.upperBound...]
                return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
            }
            return " at line \(index + 1)" + (id.map { ", case \($0)" } ?? "")
        }
        return " (the file has \(old.count) lines, the rules give \(new.count))"
    }
}

// MARK: - The JSON the file is written in

/// A small JSON value that always renders the same bytes: object keys sorted, no spaces,
/// and every character outside printable ASCII written as a `\u` escape. The file's hash
/// is only stable if its bytes are, and Foundation's own encoder promises neither.
indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    var rendered: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .string(let value): return Self.quoted(value)
        case .array(let items): return "[" + items.map(\.rendered).joined(separator: ",") + "]"
        case .object(let members):
            let keys = members.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            return "{" + keys.map { Self.quoted($0) + ":" + members[$0]!.rendered }.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x20...0x7E: out.unicodeScalars.append(scalar)
            case 0x10000...:
                let value = scalar.value - 0x10000
                out += String(format: "\\u%04x\\u%04x", 0xD800 + (value >> 10), 0xDC00 + (value & 0x3FF))
            default: out += String(format: "\\u%04x", scalar.value)
            }
        }
        return out + "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(nilLiteral: ()) { self = .null }
}

// MARK: - The cases

struct Vector {
    var id: String
    var fn: String
    var input: JSON
    var expect: JSON
    /// The stated answer the computed one must match (see the header).
    var spec: JSON?
    /// The design's tables leave out statuses' times (the time a write is stamped with,
    /// or the times the input already had), so those answers are checked without them.
    /// The file still carries every time.
    var specIgnoresTimes = false

    var json: JSON { ["id": .string(id), "fn": .string(fn), "in": input, "expect": expect] }
}

enum Vectors {
    static func file(_ cases: [Vector]) -> String {
        "{\"cases\":[\n" + cases.map(\.json.rendered).joined(separator: ",\n") + "\n],\"version\":1}\n"
    }

    static func all() -> [Vector] {
        streak() + progress() + outbox() + coalescer() + nudges() + announcements() + quietHours() + names() + dayKeys()
    }

    // MARK: Building blocks

    static let epoch = Date(timeIntervalSince1970: 0)

    static func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    static func iso(_ date: Date) -> String {
        // The wire form has no fraction of a second (KV4), so neither may any case.
        precondition(date.timeIntervalSince1970.rounded() == date.timeIntervalSince1970, "vector instants are whole seconds")
        return ISO8601DateFormatter().string(from: date)
    }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static let utc = calendar("UTC")

    static func status(_ role: DuoRole, _ day: String, _ met: Bool, _ bucket: Int, _ updatedAt: Date = epoch) -> DuoDayStatus {
        DuoDayStatus(role: role, day: day, goalMet: met, progressBucket: bucket, updatedAt: updatedAt)
    }

    static func statusJSON(_ status: DuoDayStatus) -> JSON {
        ["role": .string(status.role.rawValue), "day": .string(status.day), "goalMet": .bool(status.goalMet),
         "bucket": .int(status.progressBucket), "updatedAt": .string(iso(status.updatedAt))]
    }

    static func statusesJSON(_ statuses: [DuoDayStatus]) -> JSON { .array(statuses.map(statusJSON)) }

    static func optionalStatusJSON(_ status: DuoDayStatus?) -> JSON { status.map(statusJSON) ?? .null }

    /// Statuses without their times, which is all the design's tables give.
    static func untimed(_ statuses: [DuoDayStatus]) -> JSON {
        .array(statuses.map { ["role": .string($0.role.rawValue), "day": .string($0.day), "goalMet": .bool($0.goalMet), "bucket": .int($0.progressBucket)] })
    }

    static func withoutTimes(_ json: JSON) -> JSON {
        guard case .array(let items) = json else { return json }
        return .array(items.map {
            guard case .object(var members) = $0 else { return $0 }
            members["updatedAt"] = nil
            return .object(members)
        })
    }

    /// Statuses in one order, by day and then role, so that inputs and a filter's output
    /// read the same way on every side.
    static func sorted(_ statuses: [DuoDayStatus]) -> [DuoDayStatus] {
        statuses.sorted { ($0.day, $0.role.rawValue) < ($1.day, $1.role.rawValue) }
    }

    static func bothMet(_ days: [String]) -> [DuoDayStatus] {
        days.flatMap { day in DuoRole.allCases.map { status($0, day, true, 100) } }
    }

    /// `count` day keys ending on `last`, oldest first.
    static func days(endingOn last: String, count: Int) -> [String] {
        let end = DayKey.date(from: last, calendar: utc)!
        return (0..<count).reversed().map { DayKey.key(for: utc.date(byAdding: .day, value: -$0, to: end)!, calendar: utc) }
    }

    static func days(from first: String, through last: String) -> [String] {
        var result: [String] = []
        var day = first
        while day <= last {
            result.append(day)
            day = DayKey.nextDayKey(after: day, calendar: utc)!
        }
        return result
    }

    // MARK: DuoStreak

    static func current(_ id: String, _ statuses: [DuoDayStatus], myRole: DuoRole, myToday: String, now: String, spec: Int? = nil) -> Vector {
        let statuses = sorted(statuses)
        let value = DuoStreak.current(statuses: statuses, myRole: myRole, myToday: myToday, now: instant(now))
        return Vector(id: id, fn: "DuoStreak.current",
                      input: ["statuses": statusesJSON(statuses), "myRole": .string(myRole.rawValue), "myToday": .string(myToday), "now": .string(now)],
                      expect: .int(value), spec: spec.map(JSON.int))
    }

    static func edge(_ id: String, _ statuses: [DuoDayStatus], myRole: DuoRole, myToday: String, now: String, spec: Bool) -> Vector {
        let statuses = sorted(statuses)
        let value = DuoStreak.reachedRetentionEdge(statuses: statuses, myRole: myRole, myToday: myToday, now: instant(now))
        return Vector(id: id, fn: "DuoStreak.reachedRetentionEdge",
                      input: ["statuses": statusesJSON(statuses), "myRole": .string(myRole.rawValue), "myToday": .string(myToday), "now": .string(now)],
                      expect: .bool(value), spec: .bool(spec))
    }

    static func pruned(_ id: String, _ statuses: [DuoDayStatus], myToday: String, now: String, specFirstDay: String? = nil) -> (Vector, [DuoDayStatus]) {
        let statuses = sorted(statuses)
        let kept = DuoStreak.pruned(statuses, myToday: myToday, now: instant(now))
        let spec = specFirstDay.map { first in untimed(statuses.filter { $0.day >= first }) }
        var vector = Vector(id: id, fn: "DuoStreak.pruned",
                            input: ["statuses": statusesJSON(statuses), "myToday": .string(myToday), "now": .string(now)],
                            expect: statusesJSON(kept), spec: spec)
        vector.specIgnoresTimes = true
        return (vector, kept)
    }

    static func currentStatus(_ id: String, of role: DuoRole, _ statuses: [DuoDayStatus], myRole: DuoRole, myToday: String, now: String, spec: JSON) -> Vector {
        let statuses = sorted(statuses)
        let value = DuoStreak.currentStatus(of: role, statuses: statuses, myRole: myRole, myToday: myToday, now: instant(now))
        return Vector(id: id, fn: "DuoStreak.currentStatus",
                      input: ["of": .string(role.rawValue), "statuses": statusesJSON(statuses), "myRole": .string(myRole.rawValue),
                              "myToday": .string(myToday), "now": .string(now)],
                      expect: optionalStatusJSON(value), spec: spec)
    }

    static func streak() -> [Vector] {
        var out: [Vector] = []
        out.append(current("V1", bothMet(["2026-09-18", "2026-09-19", "2026-09-20"]), myRole: .owner, myToday: "2026-09-20", now: "2026-09-20T22:00:00Z", spec: 3))
        out.append(current("V2", ["2026-09-18", "2026-09-19", "2026-09-20"].map { status(.owner, $0, true, 100) },
                           myRole: .owner, myToday: "2026-09-21", now: "2026-09-23T12:00:00Z", spec: 0))
        out.append(current("V3", bothMet(["2026-09-17", "2026-09-18", "2026-09-20"]) + [status(.owner, "2026-09-19", true, 100), status(.partner, "2026-09-19", false, 75)],
                           myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T15:00:00Z", spec: 1))
        out.append(current("V4.a", bothMet(["2026-09-19"]) + [status(.partner, "2026-09-20", true, 100)],
                           myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T01:00:00Z", spec: 0))
        out.append(current("V4.b", bothMet(["2026-09-19"]) + [status(.owner, "2026-09-20", true, 100)],
                           myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T01:00:00Z", spec: 1))
        out.append(current("V4.c", bothMet(["2026-09-19"]) + [status(.owner, "2026-09-20", true, 100)],
                           myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T12:00:00Z", spec: 0))
        out.append(current("V5", bothMet(["2026-09-19"]) + [status(.owner, "2026-09-20", true, 100), status(.partner, "2026-09-21", false, 0)],
                           myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T01:00:00Z", spec: 0))
        let v6 = bothMet(["2026-09-18", "2026-09-19"]) + [status(.owner, "2026-09-20", true, 100), status(.owner, "2026-09-21", false, 25), status(.partner, "2026-09-20", false, 75)]
        out.append(current("V6.a", v6, myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T02:00:00Z", spec: 2))
        out.append(current("V6.b", v6, myRole: .partner, myToday: "2026-09-20", now: "2026-09-21T02:00:00Z", spec: 2))
        out.append(current("V7.a", bothMet(["2026-09-20"]) + [status(.partner, "9999-12-31", true, 100)],
                           myRole: .owner, myToday: "2026-09-20", now: "2026-09-20T20:00:00Z", spec: 1))
        out.append(currentStatus("V7.b", of: .partner, [status(.partner, "9999-12-31", true, 100)],
                                 myRole: .owner, myToday: "2026-09-20", now: "2026-09-20T20:00:00Z", spec: .null))
        for (suffix, now, expected) in [("a", "2026-09-21T11:59:00Z", false), ("b", "2026-09-21T12:00:00Z", true)] {
            out.append(Vector(id: "V8.\(suffix)", fn: "DuoStreak.isOverEverywhere",
                              input: ["day": "2026-09-20", "now": .string(now)],
                              expect: .bool(DuoStreak.isOverEverywhere("2026-09-20", now: instant(now))), spec: .bool(expected)))
        }
        let fresh = status(.partner, "2026-09-20", false, 75, instant("2026-09-21T01:00:00Z"))
        out.append(currentStatus("V9.a", of: .partner, [fresh], myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T02:00:00Z", spec: statusJSON(fresh)))
        out.append(currentStatus("V9.b", of: .partner, [status(.partner, "2026-09-20", true, 100, instant("2026-09-20T19:00:00Z"))],
                                 myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T02:00:00Z", spec: .null))
        out.append(currentStatus("V9.c", of: .partner, [status(.partner, "2026-09-21", true, 100), status(.partner, "2026-09-22", false, 0)],
                                 myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T20:00:00Z", spec: statusJSON(status(.partner, "2026-09-22", false, 0))))

        // V14 (KV18): pruning, spelled out.
        let v14a = bothMet(["2026-09-03", "2026-09-04"]) + [status(.owner, "2026-09-05", true, 100)] + bothMet(days(from: "2026-09-06", through: "2026-09-20"))
        let (prunedA, keptA) = pruned("V14.a", v14a, myToday: "2026-09-21", now: "2026-09-21T12:00:00Z", specFirstDay: "2026-09-05")
        out.append(prunedA)
        out.append(current("V14.a.current", keptA, myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T12:00:00Z", spec: 15))
        out.append(current("V14.a.current.unpruned", v14a, myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T12:00:00Z", spec: 15))
        let (prunedB, keptB) = pruned("V14.b", bothMet(["2026-09-06", "2026-09-07", "2026-09-20"]), myToday: "2026-09-21", now: "2026-09-21T12:00:00Z",
                                      specFirstDay: "2026-09-20")
        out.append(prunedB)
        out.append(current("V14.b.current", keptB, myRole: .owner, myToday: "2026-09-21", now: "2026-09-21T12:00:00Z", spec: 1))
        out.append(pruned("V14.c", bothMet(days(from: "2026-09-01", through: "2026-09-20")), myToday: "2026-09-21", now: "2026-09-21T12:00:00Z",
                          specFirstDay: "2026-09-01").0)

        // X1 and KV18's 120-day case: the 100-day window.
        let long = bothMet(days(endingOn: "2026-09-25", count: 130))
        let (x1, keptLong) = pruned("X1.pruned", long, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", specFirstDay: "2026-06-18")
        out.append(x1)
        for role in DuoRole.allCases {
            out.append(current("X1.current.\(role.rawValue)", keptLong, myRole: role, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: 100))
            out.append(edge("X1.edge.\(role.rawValue)", keptLong, myRole: role, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: true))
        }
        // Erratum 6: `current` itself is uncapped (the 100 comes from pruning), and "100+"
        // means the walk reaches the window's first day unbroken, whatever lies before it.
        out.append(current("X1.current.unpruned", long, myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: 130))
        for role in DuoRole.allCases {
            out.append(edge("X1.edge.unpruned.\(role.rawValue)", long, myRole: role, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: true))
        }
        let oldBreak = long.filter { !($0.day == "2026-06-07" && $0.role == .partner) }
        out.append(current("HC.edge.oldBreak.current", oldBreak, myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: 110))
        out.append(edge("HC.edge.oldBreak", oldBreak, myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: true))
        let recentBreak = long.filter { !($0.day == "2026-08-01" && $0.role == .partner) }
        out.append(edge("HC.edge.breakInWindow", recentBreak, myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: false))
        // The window's first day is judged too: a break on it is inside the window, a
        // break the day before is not, and 99 unbroken days are not yet 100.
        out.append(edge("HC.edge.breakOnFirstDay", long.filter { !($0.day == "2026-06-18" && $0.role == .partner) },
                        myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: false))
        out.append(edge("HC.edge.breakTheDayBefore", long.filter { !($0.day == "2026-06-17" && $0.role == .partner) },
                        myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: true))
        out.append(edge("HC.edge.ninetyNineDays", bothMet(days(endingOn: "2026-09-25", count: 99)),
                        myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: false))
        let (kv18, kept120) = pruned("KV18.pruned", bothMet(days(endingOn: "2026-09-25", count: 120)), myToday: "2026-09-25", now: "2026-09-25T18:00:00Z",
                                     specFirstDay: "2026-06-18")
        out.append(kv18)
        out.append(current("KV18.current", kept120, myRole: .partner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: 100))
        out.append(edge("HC.edge.short", bothMet(days(endingOn: "2026-09-25", count: 20)), myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: false))
        // A cache last pruned the day before starts a day before the window, and a break
        // on that day is before the window: still "100+". Judging by the earliest status
        // instead would say false here (final design §8.5).
        let prunedYesterday = DuoStreak.pruned(bothMet(days(endingOn: "2026-09-24", count: 130)), myToday: "2026-09-24", now: instant("2026-09-24T18:00:00Z"))
        let staleCache = (prunedYesterday + bothMet(["2026-09-25"])).filter { !($0.day == "2026-06-17" && $0.role == .partner) }
        out.append(edge("HC.edge.staleCache", staleCache, myRole: .owner, myToday: "2026-09-25", now: "2026-09-25T18:00:00Z", spec: true))

        // X3: the server's daily prune, with the date in the last time zone on Earth.
        let x3now = "2026-09-25T12:05:00Z"
        out.append(Vector(id: "X3.myToday", fn: "DayKey.key", input: ["date": .string(x3now), "zone": "Etc/GMT+12"],
                          expect: .string(DayKey.key(for: instant(x3now), calendar: calendar("Etc/GMT+12"))), spec: "2026-09-25"))
        out.append(Vector(id: "X3.retentionStart", fn: "DuoStreak.retentionStart", input: ["myToday": "2026-09-25"],
                          expect: .string(DuoStreak.retentionStart(myToday: "2026-09-25")!), spec: "2026-06-18"))
        let brokenOnCutoff = bothMet(days(from: "2026-09-01", through: "2026-09-25")).filter { !($0.day == "2026-09-16" && $0.role == .partner) }
        out.append(pruned("X3.breakOnCutoff", brokenOnCutoff, myToday: "2026-09-25", now: x3now, specFirstDay: "2026-09-16").0)
        out.append(pruned("X3.cap", bothMet(days(from: "2026-06-10", through: "2026-09-25")), myToday: "2026-09-25", now: x3now, specFirstDay: "2026-06-18").0)

        // X2: the server's "partner already met" check for a Kiribati sender and a
        // Pago Pago partner, with the sender's day as myToday.
        out.append(currentStatus("X2", of: .partner, [status(.partner, "2026-09-27", true, 100, instant("2026-09-28T10:30:00Z"))],
                                 myRole: .owner, myToday: "2026-09-29", now: "2026-09-28T11:00:00Z", spec: .null))

        // KV9: nobody is more than two days ahead.
        let ahead = [status(.owner, "2026-09-23", false, 0), status(.owner, "2026-09-24", false, 0)]
        out.append(Vector(id: "KV9", fn: "DuoStreak.plausible", input: ["statuses": statusesJSON(ahead), "myToday": "2026-09-21"],
                          expect: statusesJSON(DuoStreak.plausible(ahead, myToday: "2026-09-21")), spec: statusesJSON([ahead[0]])))
        return out
    }

    // MARK: DuoProgress

    static func progress() -> [Vector] {
        let rows: [(Int, Int, Int, Bool)] = [(0, 2000, 0, false), (499, 2000, 0, false), (500, 2000, 25, false), (1000, 2000, 50, false),
                                             (1999, 2000, 75, false), (2000, 2000, 100, true), (9000, 2000, 100, true), (500, 0, 0, false)]
        return rows.enumerated().map { index, row in
            Vector(id: "V10.\(index + 1)", fn: "DuoProgress.bucket+goalMet", input: ["totalML": .int(row.0), "goalML": .int(row.1)],
                   expect: ["bucket": .int(DuoProgress.bucket(totalML: row.0, goalML: row.1)), "goalMet": .bool(DuoProgress.goalMet(totalML: row.0, goalML: row.1))],
                   spec: ["bucket": .int(row.2), "goalMet": .bool(row.3)])
        }
    }

    // MARK: DuoOutbox

    static func unsent(_ id: String, role: DuoRole, totals: [String: Int], goal: Int, known: [DuoDayStatus], myToday: String, now: String,
                       zone: String = "UTC", coverageStart: String = DuoOutbox.coveredForever, spec: [DuoDayStatus]) -> Vector {
        let known = sorted(known)
        let value = DuoOutbox.unsent(role: role, totalsByDay: totals, goalML: goal, known: known, myToday: myToday, now: instant(now),
                                     coverageStart: coverageStart, calendar: calendar(zone))
        let totalsJSON = JSON.object(Dictionary(uniqueKeysWithValues: totals.map { ($0.key, JSON.int($0.value)) }))
        var vector = Vector(id: id, fn: "DuoOutbox.unsent",
                            input: ["role": .string(role.rawValue), "totalsByDay": totalsJSON, "goalML": .int(goal), "known": statusesJSON(known),
                                    "myToday": .string(myToday), "now": .string(now), "zone": .string(zone), "coverageStart": .string(coverageStart)],
                            expect: statusesJSON(value), spec: untimed(spec))
        vector.specIgnoresTimes = true
        return vector
    }

    static func outbox() -> [Vector] {
        let now = "2026-09-21T12:00:00Z", today = "2026-09-21"
        let sixMet = (15...20).map { status(.owner, "2026-09-\($0)", true, 100) }
        return [
            unsent("V11.a", role: .owner, totals: [:], goal: 2000, known: [], myToday: today, now: now, spec: [status(.owner, today, false, 0)]),
            unsent("V11.b", role: .owner, totals: [today: 1400], goal: 2000, known: [status(.owner, today, false, 50)], myToday: today, now: now, spec: []),
            unsent("V11.c", role: .owner, totals: [today: 1500], goal: 2000, known: [status(.owner, today, false, 50)], myToday: today, now: now,
                   spec: [status(.owner, today, false, 75)]),
            unsent("V11.d", role: .owner, totals: ["2026-09-20": 2100], goal: 2000, known: [status(.owner, "2026-09-20", false, 75)], myToday: today, now: now,
                   spec: [status(.owner, today, false, 0), status(.owner, "2026-09-20", true, 100)]),
            unsent("V11.e", role: .owner, totals: ["2026-09-18": 900], goal: 2000,
                   known: [status(.owner, "2026-09-18", true, 100), status(.owner, today, false, 0)], myToday: today, now: now,
                   spec: [status(.owner, "2026-09-18", false, 25)]),
            unsent("V11.f", role: .owner, totals: ["2026-09-10": 0], goal: 2000,
                   known: [status(.owner, "2026-09-10", true, 100), status(.owner, today, false, 0)], myToday: today, now: now, spec: []),
            unsent("V11.g", role: .partner, totals: [today: 2500], goal: 2000, known: [status(.owner, today, true, 100)], myToday: today, now: now,
                   spec: [status(.partner, today, true, 100)]),
            // X4: a few minutes after midnight, with nothing logged yet.
            unsent("X4", role: .owner, totals: [:], goal: 2000, known: [], myToday: today, now: "2026-09-21T04:07:00Z", zone: "America/New_York",
                   spec: [status(.owner, today, false, 0)]),
            // X5: the last week is judged against the goal as it stands.
            unsent("X5.raised", role: .owner, totals: ["2026-09-18": 2100], goal: 2500,
                   known: [status(.owner, "2026-09-18", true, 100), status(.owner, today, false, 0)], myToday: today, now: now,
                   spec: [status(.owner, "2026-09-18", false, 75)]),
            unsent("X5.lowered", role: .owner, totals: ["2026-09-18": 2100], goal: 2000,
                   known: [status(.owner, "2026-09-18", true, 100), status(.owner, today, false, 0)], myToday: today, now: now, spec: []),
            // X12 and its companions: a reinstalled phone and its coverage start.
            unsent("X12", role: .owner, totals: [:], goal: 2000, known: sixMet, myToday: today, now: now, coverageStart: today,
                   spec: [status(.owner, today, false, 0)]),
            unsent("X12.todayKnown", role: .owner, totals: [:], goal: 2000, known: sixMet + [status(.owner, today, false, 25)],
                   myToday: today, now: now, coverageStart: today, spec: [status(.owner, today, false, 0)]),
            unsent("X12.wholeWeekCovered", role: .owner, totals: [:], goal: 2000, known: sixMet + [status(.owner, today, false, 25)],
                   myToday: today, now: now, coverageStart: "2026-09-15",
                   spec: [status(.owner, today, false, 0)] + (15...20).reversed().map { status(.owner, "2026-09-\($0)", false, 0) }),
            unsent("HC.coverage.upgrade", role: .owner, totals: ["2026-09-19": 1000], goal: 2000, known: [status(.owner, "2026-09-19", false, 25)],
                   myToday: today, now: now, coverageStart: today, spec: [status(.owner, today, false, 0), status(.owner, "2026-09-19", false, 50)]),
            unsent("HC.coverage.afterToday", role: .owner, totals: [:], goal: 2000, known: [status(.owner, today, false, 50)],
                   myToday: today, now: now, coverageStart: "2026-09-22", spec: [status(.owner, today, false, 0)]),
        ]
    }

    // MARK: DuoWriteCoalescer

    static func coalescer() -> [Vector] {
        func run(_ id: String, _ steps: [(String, Int)], spec: [JSON]) -> Vector {
            let start = instant("2026-09-21T12:00:00Z")
            var coalescer = DuoWriteCoalescer()
            var results: [JSON] = []
            for (event, offset) in steps {
                let at = start.addingTimeInterval(TimeInterval(offset))
                if event == "request" {
                    switch coalescer.request(now: at) {
                    case .writeNow: results.append("writeNow")
                    case .wait(let until): results.append(["wait": .string(iso(until))])
                    case .alreadyWaiting: results.append("alreadyWaiting")
                    }
                } else {
                    coalescer.waitEnded(now: at)
                    results.append(.null)
                }
            }
            let stepsJSON = JSON.array(steps.map { ["event": .string($0.0), "at": .string(iso(start.addingTimeInterval(TimeInterval($0.1))))] })
            return Vector(id: id, fn: "DuoWriteCoalescer", input: ["steps": stepsJSON], expect: .array(results), spec: .array(spec))
        }
        return [
            run("V12", [("request", 0), ("request", 5), ("request", 6), ("waitEnded", 30), ("request", 40), ("waitEnded", 60), ("request", 95)],
                spec: ["writeNow", ["wait": "2026-09-21T12:00:30Z"], "alreadyWaiting", nil, ["wait": "2026-09-21T12:01:00Z"], nil, "writeNow"]),
            run("KV19", [("request", 0), ("request", 5), ("request", 6), ("waitEnded", 95), ("request", 96)],
                spec: ["writeNow", ["wait": "2026-09-21T12:00:30Z"], "alreadyWaiting", nil, ["wait": "2026-09-21T12:02:05Z"]]),
        ]
    }

    // MARK: Nudges

    static let duoID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func duo(joined: Bool = true, ended: Bool = false, statuses: [DuoDayStatus] = [], nudges: [DuoNudge] = [],
                    partnerName: String = "Sam") -> DuoState {
        DuoState(id: duoID, zoneName: "Duo-\(duoID.uuidString)", zoneOwnerName: "owner", myRole: .owner, createdAt: epoch,
                 ownerDisplayName: "Jo", partnerDisplayName: partnerName, ownerSkin: "classic", partnerSkin: "forest",
                 statuses: sorted(statuses), shareURL: nil, partnerHasJoined: joined, endedAt: ended ? instant("2026-09-20T00:00:00Z") : nil,
                 changeToken: nil, nudges: nudges)
    }

    static func nudgeJSON(_ nudge: DuoNudge) -> JSON {
        ["id": .string(nudge.id), "fromRole": .string(nudge.fromRole.rawValue), "presetID": .string(nudge.presetID), "createdAt": .string(iso(nudge.createdAt))]
    }

    static func duoJSON(_ duo: DuoState) -> JSON {
        ["id": .string(duo.id.uuidString), "myRole": .string(duo.myRole.rawValue), "joined": .bool(duo.partnerHasJoined), "ended": .bool(duo.hasEnded),
         "ownerName": .string(duo.ownerDisplayName), "partnerName": .string(duo.partnerDisplayName),
         "statuses": statusesJSON(duo.statuses), "nudges": .array(duo.allNudges.map(nudgeJSON))]
    }

    static func nudge(_ id: String, _ role: DuoRole, _ preset: DuoNudgePreset, _ at: String) -> DuoNudge {
        DuoNudge(id: id, fromRole: role, presetID: preset.rawValue, createdAt: instant(at))
    }

    static func verdictJSON(_ verdict: DuoNudgeRules.Verdict) -> JSON {
        switch verdict {
        case .allowed(let remaining): return ["verdict": "allowed", "remaining": .int(remaining)]
        case .limitReached: return ["verdict": "limitReached"]
        case .partnerAlreadyMet: return ["verdict": "partnerAlreadyMet"]
        case .nobodyToNudge: return ["verdict": "nobodyToNudge"]
        }
    }

    static func verdict(_ id: String, _ duo: DuoState, partnerStatus: DuoDayStatus?, now: String, dailyLimit: Int = DuoNudgeRules.dailyLimit,
                        zone: String = "UTC", spec: JSON) -> Vector {
        let value = DuoNudgeRules.verdict(for: duo, partnerStatus: partnerStatus, now: instant(now), dailyLimit: dailyLimit, calendar: calendar(zone))
        return Vector(id: id, fn: "DuoNudgeRules.verdict",
                      input: ["duo": duoJSON(duo), "partnerStatus": optionalStatusJSON(partnerStatus), "now": .string(now),
                              "dailyLimit": .int(dailyLimit), "zone": .string(zone)],
                      expect: verdictJSON(value), spec: spec)
    }

    static func nudges() -> [Vector] {
        let now = "2026-09-21T15:00:00Z"
        let mine = ["09", "10", "11"].map { nudge("nudge-m\($0)", .owner, .waterBreak, "2026-09-21T\($0):00:00Z") }
        var out = [
            verdict("V13.verdict.a", duo(), partnerStatus: nil, now: now, spec: ["verdict": "allowed", "remaining": 3]),
            verdict("V13.verdict.b", duo(nudges: mine), partnerStatus: nil, now: now, spec: ["verdict": "limitReached"]),
            verdict("V13.verdict.c", duo(nudges: mine), partnerStatus: status(.partner, "2026-09-21", true, 100), now: now, spec: ["verdict": "partnerAlreadyMet"]),
            verdict("V13.verdict.d", duo(joined: false), partnerStatus: nil, now: now, spec: ["verdict": "nobodyToNudge"]),
            verdict("HC.verdict.lowerLimit", duo(nudges: [mine[0]]), partnerStatus: nil, now: now, dailyLimit: 1, spec: ["verdict": "limitReached"]),
        ]
        // KV8: a day is the sender's own day.
        let late = (1...3).map { nudge("nudge-k\($0)", .owner, .cheers, "2026-09-21T14:30:00Z") }
        for (suffix, at, expected) in [("a", "2026-09-21T14:30:00Z", 3), ("b", "2026-09-21T15:30:00Z", 0)] {
            out.append(Vector(id: "KV8.\(suffix)", fn: "DuoNudgeRules.sentToday",
                              input: ["by": "owner", "nudges": .array(late.map(nudgeJSON)), "now": .string(at), "zone": "Asia/Tokyo"],
                              expect: .int(DuoNudgeRules.sentToday(by: .owner, nudges: late, now: instant(at), calendar: calendar("Asia/Tokyo"))),
                              spec: .int(expected)))
        }
        // KV2: what counts as a nudge's id, which is the wire's pattern matched against the
        // whole id (final design §6.6), with no version or variant check.
        let uuid = "3B9E1C2A-0000-4000-8000-00000000ABCD"
        let ids: [(String, String, Bool)] = [
            ("upper", "nudge-\(uuid)", true), ("lower", "nudge-\(uuid.lowercased())", true),
            ("mixed", "nudge-3b9E1C2a-0000-4000-8000-00000000abCD", true), ("empty", "nudge-", false),
            ("notUUID", "nudge-not-a-uuid", false), ("prefixCase", "NUDGE-\(uuid)", false),
            ("nilUUID", "nudge-00000000-0000-0000-0000-000000000000", true),
            ("braces", "nudge-{\(uuid)}", false),
            ("noHyphens", "nudge-3B9E1C2A00004000800000000000ABCD", false),
            ("trailingNewline", "nudge-\(uuid)\n", false), ("trailingSpace", "nudge-\(uuid) ", false),
            ("trailingCRLF", "nudge-\(uuid)\r\n", false),
            // Something before the prefix, so a port whose pattern isn't anchored at the start
            // fails here rather than passing every case.
            ("leadingSpace", " nudge-\(uuid)", false), ("leadingLetter", "xnudge-\(uuid)", false),
            ("nul", "nudge-\(uuid)\u{0}", false),
            ("unicodeHyphen", "nudge-3B9E1C2A\u{2010}0000-4000-8000-00000000ABCD", false),
            ("fullwidthDigit", "nudge-3B9E1C2A-0000-4000-8000-00000000ABC\u{FF10}", false),
        ]
        for (suffix, name, expected) in ids {
            out.append(Vector(id: "KV2.\(suffix)", fn: "DuoNudge.isNudgeRecordName", input: ["name": .string(name)],
                              expect: .bool(DuoNudge.isNudgeRecordName(name)), spec: .bool(expected)))
        }
        return out
    }

    // MARK: DuoAnnouncements

    static func announcementsJSON(_ announcements: [DuoAnnouncement]) -> JSON {
        .array(announcements.map { ["key": .string($0.key), "title": .string($0.title), "body": .string($0.body), "actionable": .bool($0.isActionable)] })
    }

    static func plan(_ id: String, before: DuoState, after: DuoState, isFirstRead: Bool, ledger: [String], myToday: String, now: String,
                     spec: JSON, specLedger: [String]) -> (Vector, [String]) {
        var book = DuoLedger(seen: ledger)
        let value = DuoAnnouncements.plan(before: before, after: after, isFirstRead: isFirstRead, ledger: &book, myToday: myToday,
                                          now: instant(now), calendar: utc)
        return (Vector(id: id, fn: "DuoAnnouncements.plan",
                       input: ["before": duoJSON(before), "after": duoJSON(after), "isFirstRead": .bool(isFirstRead),
                               "ledger": .array(ledger.map(JSON.string)), "myToday": .string(myToday), "now": .string(now), "zone": "UTC"],
                       expect: ["announcements": announcementsJSON(value), "ledger": .array(book.seen.map(JSON.string))],
                       spec: ["announcements": spec, "ledger": .array(specLedger.map(JSON.string))]), book.seen)
    }

    static func announcements() -> [Vector] {
        var out: [Vector] = []
        let arrival = nudge("nudge-a", .partner, .sipWithMe, "2026-09-21T14:00:00Z")
        let (a, ledgerA) = plan("V13.plan.a", before: duo(), after: duo(nudges: [arrival]), isFirstRead: false, ledger: [],
                                myToday: "2026-09-21", now: "2026-09-21T15:00:00Z",
                                spec: [["key": "nudge-a", "title": "Sam nudged you", "body": "Sip with me?", "actionable": true]], specLedger: ["nudge-a"])
        out.append(a)
        out.append(plan("V13.plan.a.again", before: duo(), after: duo(nudges: [arrival]), isFirstRead: false, ledger: ledgerA,
                        myToday: "2026-09-21", now: "2026-09-21T15:00:00Z", spec: [], specLedger: ["nudge-a"]).0)

        let flood = (0...9).map { nudge("nudge-f\($0)", .partner, .waterBreak, String(format: "2026-09-21T10:%02d:00Z", $0)) }
        out.append(plan("V13.plan.b", before: duo(), after: duo(nudges: flood), isFirstRead: false, ledger: [],
                        myToday: "2026-09-21", now: "2026-09-21T11:00:00Z",
                        spec: .array((0...2).map { ["key": .string("nudge-f\($0)"), "title": "Sam nudged you", "body": "Water break?", "actionable": true] }),
                        specLedger: (0...9).map { "nudge-f\($0)" }).0)

        out.append(plan("V13.plan.c", before: duo(), after: duo(nudges: [nudge("nudge-late", .partner, .waterBreak, "2026-09-20T09:00:00Z")]),
                        isFirstRead: false, ledger: [], myToday: "2026-09-21", now: "2026-09-21T15:00:00Z", spec: [], specLedger: ["nudge-late"]).0)

        let beforeMet = duo(statuses: [status(.partner, "2026-09-21", false, 50, instant("2026-09-21T12:00:00Z"))])
        let afterMet = duo(statuses: [status(.partner, "2026-09-21", true, 100, instant("2026-09-21T15:00:00Z"))])
        let goalKey = "met|11111111-2222-4333-8444-555555555555|2026-09-21"
        let (d, ledgerD) = plan("V13.plan.d", before: beforeMet, after: afterMet, isFirstRead: false, ledger: [], myToday: "2026-09-21",
                                now: "2026-09-21T15:00:00Z",
                                spec: [["key": .string(goalKey), "title": "Sam hit their goal", "body": "Your turn. Keep the flame going.", "actionable": false]],
                                specLedger: [goalKey])
        out.append(d)
        out.append(plan("V13.plan.d.again", before: beforeMet, after: afterMet, isFirstRead: false, ledger: ledgerD, myToday: "2026-09-21",
                        now: "2026-09-21T15:00:00Z", spec: [], specLedger: [goalKey]).0)
        out.append(plan("V13.plan.e", before: beforeMet, after: afterMet, isFirstRead: true, ledger: [], myToday: "2026-09-21",
                        now: "2026-09-21T15:00:00Z", spec: [], specLedger: []).0)

        // The rest are on V13.plan.a's duo, read at the same moment.
        func sipWithMe(_ key: String, title: String = "Sam nudged you") -> JSON {
            ["key": .string(key), "title": .string(title), "body": "Sip with me?", "actionable": true]
        }
        func arrived(_ id: String, _ nudges: [DuoNudge], spec: JSON, specLedger: [String]) -> Vector {
            plan(id, before: duo(), after: duo(nudges: nudges), isFirstRead: false, ledger: [],
                 myToday: "2026-09-21", now: "2026-09-21T15:00:00Z", spec: spec, specLedger: specLedger).0
        }

        // New nudges are announced in the order they were sent, ties in the order `after`
        // lists them (a stable sort), and that order decides which ones the cap of three
        // passes over (final design §6.4).
        let tied = ["b", "a"].map { nudge("nudge-\($0)", .partner, .sipWithMe, "2026-09-21T14:00:00Z") }
        out.append(arrived("HC.plan.tie", tied, spec: [sipWithMe("nudge-b"), sipWithMe("nudge-a")], specLedger: ["nudge-b", "nudge-a"]))
        let tiedFour = ["d", "c", "b", "a"].map { nudge("nudge-\($0)", .partner, .sipWithMe, "2026-09-21T14:00:00Z") }
        out.append(arrived("HC.plan.tieCap", tiedFour, spec: [sipWithMe("nudge-d"), sipWithMe("nudge-c"), sipWithMe("nudge-b")],
                           specLedger: ["nudge-d", "nudge-c", "nudge-b", "nudge-a"]))

        // Both ends of the announce window count (final design §8.2): five minutes ahead
        // of this phone's clock and twelve hours old are announced, and a second past
        // either is only marked seen.
        let edges: [(String, String, Bool)] = [("HC.plan.skewEdge", "2026-09-21T15:05:00Z", true), ("HC.plan.skewPast", "2026-09-21T15:05:01Z", false),
                                               ("HC.plan.ageEdge", "2026-09-21T03:00:00Z", true), ("HC.plan.agePast", "2026-09-21T02:59:59Z", false)]
        for (id, sentAt, isAnnounced) in edges {
            out.append(arrived(id, [nudge("nudge-a", .partner, .sipWithMe, sentAt)],
                               spec: isAnnounced ? [sipWithMe("nudge-a")] : [], specLedger: ["nudge-a"]))
        }

        // The cap of three counts the partner's nudges from my today that were already
        // cached, announced or not (the ledger here has neither), and then each one
        // announced now (final design §9.2).
        let cached = [nudge("nudge-c1", .partner, .waterBreak, "2026-09-21T09:00:00Z"), nudge("nudge-c2", .partner, .waterBreak, "2026-09-21T10:00:00Z")]
        let newOnes = [nudge("nudge-n1", .partner, .waterBreak, "2026-09-21T14:00:00Z"), nudge("nudge-n2", .partner, .waterBreak, "2026-09-21T14:30:00Z")]
        out.append(plan("HC.plan.capCountsCached", before: duo(nudges: cached), after: duo(nudges: cached + newOnes), isFirstRead: false, ledger: [],
                        myToday: "2026-09-21", now: "2026-09-21T15:00:00Z",
                        spec: [["key": "nudge-n1", "title": "Sam nudged you", "body": "Water break?", "actionable": true]],
                        specLedger: ["nudge-n1", "nudge-n2"]).0)

        // A title uses the partner's name as it was given, without cleaning it again, since
        // the server's name is already clean, and an empty name reads "Your partner"
        // (final design §9.2).
        for (id, name, title) in [("HC.plan.nameAsCached", "Sam\u{200B}", "Sam\u{200B} nudged you"), ("HC.plan.nameEmpty", "", "Your partner nudged you")] {
            out.append(plan(id, before: duo(partnerName: name), after: duo(nudges: [arrival], partnerName: name), isFirstRead: false, ledger: [],
                            myToday: "2026-09-21", now: "2026-09-21T15:00:00Z", spec: [sipWithMe("nudge-a", title: title)], specLedger: ["nudge-a"]).0)
        }
        return out
    }

    // MARK: DuoQuietHours

    static func hold(_ id: String, _ at: String, start: Int, end: Int, zone: String, spec: String?) -> Vector {
        let value = DuoQuietHours.holdUntil(instant(at), startMinutes: start, endMinutes: end, calendar: calendar(zone))
        return Vector(id: id, fn: "DuoQuietHours.holdUntil",
                      input: ["date": .string(at), "startMinutes": .int(start), "endMinutes": .int(end), "zone": .string(zone)],
                      expect: value.map { .string(iso($0)) } ?? .null, spec: spec.map(JSON.string) ?? .null)
    }

    static func awake(_ id: String, _ at: String, start: Int, end: Int, zone: String, spec: Bool) -> Vector {
        Vector(id: id, fn: "DuoQuietHours.isAwake",
               input: ["date": .string(at), "startMinutes": .int(start), "endMinutes": .int(end), "zone": .string(zone)],
               expect: .bool(DuoQuietHours.isAwake(instant(at), startMinutes: start, endMinutes: end, calendar: calendar(zone))), spec: .bool(spec))
    }

    static func quietHours() -> [Vector] {
        [
            // V13: ordinary days.
            hold("V13.hold.a", "2026-09-21T09:00:00Z", start: 480, end: 1320, zone: "UTC", spec: nil),
            hold("V13.hold.b", "2026-09-21T08:00:00Z", start: 480, end: 1320, zone: "UTC", spec: nil),
            hold("V13.hold.c", "2026-09-21T23:30:00Z", start: 480, end: 1320, zone: "UTC", spec: "2026-09-22T08:00:00Z"),
            hold("V13.hold.d", "2026-09-21T22:00:00Z", start: 480, end: 1320, zone: "UTC", spec: "2026-09-22T08:00:00Z"),
            hold("V13.hold.e", "2026-09-21T03:00:00Z", start: 480, end: 1320, zone: "UTC", spec: "2026-09-21T08:00:00Z"),
            hold("V13.hold.f", "2026-09-21T23:00:00Z", start: 1320, end: 360, zone: "UTC", spec: nil),
            hold("V13.hold.g", "2026-09-21T02:00:00Z", start: 1320, end: 360, zone: "UTC", spec: nil),
            hold("V13.hold.h", "2026-09-21T12:00:00Z", start: 1320, end: 360, zone: "UTC", spec: "2026-09-21T22:00:00Z"),
            hold("V13.hold.i", "2026-09-21T03:00:00Z", start: 480, end: 480, zone: "UTC", spec: nil),
            // X9: New York. X9b opens when the gap ends, 07:00Z; the design's table used to
            // say 07:30Z, against its own rule, until Phase 1 erratum 1 corrected it. X9d and
            // X9e are a window of 02:30-03:00 that the gap swallows whole: the opening is
            // strictly after the arrival, so arriving on the jump waits for the next day,
            // and arriving the second before opens at the jump, once the window has closed.
            hold("X9a", "2027-03-14T06:30:00Z", start: 480, end: 1320, zone: "America/New_York", spec: "2027-03-14T12:00:00Z"),
            hold("X9b", "2027-03-14T06:30:00Z", start: 150, end: 1320, zone: "America/New_York", spec: "2027-03-14T07:00:00Z"),
            hold("X9c", "2026-11-01T04:30:00Z", start: 90, end: 1320, zone: "America/New_York", spec: "2026-11-01T05:30:00Z"),
            hold("X9d", "2027-03-14T07:00:00Z", start: 150, end: 180, zone: "America/New_York", spec: "2027-03-15T06:30:00Z"),
            hold("X9e", "2027-03-14T06:59:59Z", start: 150, end: 180, zone: "America/New_York", spec: "2027-03-14T07:00:00Z"),
            // KV7: Los Angeles and London on both clock changes, then the design's "KV7
            // (added)" row: changes that aren't an hour on the hour (Lord Howe's half hour,
            // Troll's two hours, Nuuk's gap that ends at midnight, the Chatham Islands'
            // change at 02:45) and arrivals in a repeated time after its first reading.
            hold("KV7.la.forward.before", "2026-03-08T09:30:00Z", start: 480, end: 1320, zone: "America/Los_Angeles", spec: "2026-03-08T15:00:00Z"),
            hold("KV7.la.forward.after", "2026-03-08T10:30:00Z", start: 480, end: 1320, zone: "America/Los_Angeles", spec: "2026-03-08T15:00:00Z"),
            hold("KV7.la.gap", "2026-03-08T09:00:00Z", start: 150, end: 1320, zone: "America/Los_Angeles", spec: "2026-03-08T10:00:00Z"),
            hold("KV7.la.twice", "2026-11-01T07:30:00Z", start: 90, end: 1320, zone: "America/Los_Angeles", spec: "2026-11-01T08:30:00Z"),
            hold("KV7.london.forward.before", "2026-03-29T00:30:00Z", start: 480, end: 1320, zone: "Europe/London", spec: "2026-03-29T07:00:00Z"),
            hold("KV7.london.forward.after", "2026-03-29T01:30:00Z", start: 480, end: 1320, zone: "Europe/London", spec: "2026-03-29T07:00:00Z"),
            hold("KV7.london.gap", "2026-03-29T00:30:00Z", start: 90, end: 1320, zone: "Europe/London", spec: "2026-03-29T01:00:00Z"),
            hold("KV7.london.twice", "2026-10-24T23:30:00Z", start: 90, end: 1320, zone: "Europe/London", spec: "2026-10-25T00:30:00Z"),
            // Phase 1 erratum 4, which that row now holds.
            hold("KV7.lordHowe.gap", "2026-10-03T12:30:00Z", start: 130, end: 1320, zone: "Australia/Lord_Howe", spec: "2026-10-03T15:30:00Z"),
            hold("KV7.troll.gap", "2026-03-28T23:30:00Z", start: 60, end: 1320, zone: "Antarctica/Troll", spec: "2026-03-29T01:00:00Z"),
            hold("KV7.nuuk.gap", "2026-03-28T20:00:00Z", start: 1390, end: 420, zone: "America/Nuuk", spec: "2026-03-29T01:00:00Z"),
            hold("KV7.chatham.gap", "2026-09-26T12:00:00Z", start: 180, end: 1320, zone: "Pacific/Chatham", spec: "2026-09-26T14:00:00Z"),
            hold("KV7.chatham.back", "2026-04-04T12:00:00Z", start: 230, end: 1320, zone: "Pacific/Chatham", spec: "2026-04-04T15:05:00Z"),
            hold("KV7.ny.secondReading", "2026-11-01T06:10:00Z", start: 90, end: 1320, zone: "America/New_York", spec: "2026-11-01T06:30:00Z"),
            hold("KV7.london.secondReading", "2026-10-25T01:10:00Z", start: 90, end: 1320, zone: "Europe/London", spec: "2026-10-25T01:30:00Z"),
            hold("KV7.lordHowe.secondReading", "2026-04-04T15:10:00Z", start: 110, end: 1320, zone: "Australia/Lord_Howe", spec: "2026-04-04T15:20:00Z"),
            hold("KV7.santiago.secondReading", "2026-04-05T03:13:53Z", start: 1439, end: 420, zone: "America/Santiago", spec: "2026-04-05T03:59:00Z"),
            awake("KV7.la.awake", "2026-03-08T10:30:00Z", start: 150, end: 1320, zone: "America/Los_Angeles", spec: true),
            awake("KV7.la.asleep", "2026-03-08T09:30:00Z", start: 150, end: 1320, zone: "America/Los_Angeles", spec: false),
        ]
    }

    // MARK: Names

    static func names() -> [Vector] {
        // Cleaning to nothing is written as null: no name, shown as "Your partner".
        func clean(_ id: String, _ raw: String, _ expected: String?) -> Vector {
            let value = DuoState.cleanedName(raw)
            return Vector(id: id, fn: "DuoState.cleanedName", input: ["name": .string(raw)],
                          expect: value.isEmpty ? .null : .string(value), spec: expected.map(JSON.string) ?? .null)
        }
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        return [
            clean("KV6.trim", "  Sam \n", "Sam"),
            clean("KV6.newline", "Sam\nJones", "Sam Jones"),
            clean("KV6.crlf", "a\r\nb", "a b"),
            clean("KV6.long", String(repeating: "a", count: 80), String(repeating: "a", count: 24)),
            clean("KV6.blank", "   ", nil),
            // The joiners between emoji spell nothing, so the families come apart and the
            // first 24 people are kept; the server rejects emoji in names anyway.
            clean("KV6.family", String(repeating: family, count: 30), String(repeating: "\u{1F468}\u{1F469}\u{1F467}\u{1F466}", count: 6)),
            clean("KV6.flags", String(repeating: "\u{1F1EC}\u{1F1E7}\u{1F1EC}\u{1F1E7}", count: 15), String(repeating: "\u{1F1EC}\u{1F1E7}", count: 24)),
            clean("KV6.accents", String(repeating: "e\u{0301}", count: 30), String(repeating: "\u{00E9}", count: 24)),
            clean("KV6.override", "\u{202E}abc", "abc"),
            clean("KV6.zeroWidth", "a\u{200B}b", "ab"),
            clean("KV6.ligature", "\u{FB01}sh", "\u{FB01}sh"),
            clean("KV6.tab", "a\tb", "a b"),
            // Phase 1 errata, 2, 3 and 5.
            clean("KV6.invisibleBesideSpace", "\u{200B} Sam", "Sam"),
            clean("KV6.overrideBetweenSpaces", "a \u{202E} b", "a b"),
            clean("KV6.accentRejoined", "e\u{200B}\u{0301}", "\u{00E9}"),
            clean("KV6.joinerAlone", " \u{200D} ", nil),
            clean("KV6.joinerAtEdge", "Sam\u{200D}", "Sam"),
            clean("KV6.joinersLeading", "\u{200C}\u{200C}Sam", "Sam"),
            clean("KV6.joinersDoubled", "a\u{200C}\u{200C}b", "a\u{200C}b"),
            clean("KV6.persian", "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}", "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"),
            clean("KV6.sinhala", "\u{0DC1}\u{0DCA}\u{200D}\u{0DBB}\u{0DD3}", "\u{0DC1}\u{0DCA}\u{200D}\u{0DBB}\u{0DD3}"),
            clean("KV6.subdivisionFlag", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", "\u{1F3F4}"),
            clean("KV6.hangulFinal", "\u{AC00}\u{11A8}", "\u{AC01}"),
            clean("KV6.kannada", "\u{0C95}\u{0CCA}\u{0CD5}", "\u{0C95}\u{0CCB}"),
            clean("KV6.oldHangul", "\u{1100}\u{1176}", "\u{1100}\u{1176}"),
            clean("KV6.oldHangulAfterAccent", "e\u{0301}\u{1100}\u{1176}", "\u{00E9}\u{1100}\u{1176}"),
            clean("KV6.nonBreakingSpaces", "Sam\u{00A0}\u{00A0}Jones", "Sam Jones"),
            clean("KV6.privateUse", "\u{E000}Sam", "Sam"),
            clean("KV6.cutBeforeAWord", String(repeating: "a", count: 23) + " bcd", String(repeating: "a", count: 23)),
            // A prepended character and the space after it are one character as a person
            // sees it, so the 24th can end in a space; trimming is by code point.
            clean("KV6.cutAfterAPrepend", String(repeating: "a", count: 23) + "\u{0D4E} x", String(repeating: "a", count: 23) + "\u{0D4E}"),
            // A joiner and the letter before it are one character as a person sees it, so
            // the 24th can end on a joiner whose next letter didn't fit; it goes, so that
            // cleaning a cleaned name changes nothing.
            clean("KV6.cutAfterAJoiner", String(repeating: "a", count: 23) + "b\u{200D}c", String(repeating: "a", count: 23) + "b"),
            // The same with U+200C, which also joins the letter before it into one cluster, so
            // a port that drops only a final U+200D fails here.
            clean("KV6.cutAfterANonJoiner", String(repeating: "a", count: 23) + "b\u{200C}c", String(repeating: "a", count: 23) + "b"),
            // Trimming is by code point, so a mark left first keeps no letter before it; the
            // server's check refuses such a name (§11.5).
            clean("KV6.leadingMark", " \u{0301}Sam", "\u{0301}Sam"),
            clean("KV6.unassigned", "\u{0378}Sam", "Sam"),
        ]
    }

    // MARK: Day keys

    static func dayKeys() -> [Vector] {
        // The last three are the year rule (final design §6.0): 2000 or later.
        let cases: [(String, Bool)] = [("2026-02-30", false), ("2026-02-29", false), ("2028-02-29", true), ("2026-9-1", false),
                                       ("+026-09-01", false), ("0000-01-01", false), ("\u{FF12}\u{FF10}\u{FF12}\u{FF16}-09-01", false), ("2026-09-01T00", false),
                                       ("1999-12-31", false), ("2000-01-01", true), ("0001-01-01", false)]
        return cases.enumerated().map { index, row in
            Vector(id: "KV5.\(index + 1)", fn: "DuoStreak.isDayKey", input: ["text": .string(row.0)],
                   expect: .bool(DuoStreak.isDayKey(row.0)), spec: .bool(row.1))
        }
    }
}
