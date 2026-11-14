#if DUO_V2
import XCTest
@testable import HydroDrop

/// `Localizable.strings` holds every key a Duo push carries (final design §9.2) and nothing else:
/// the server sends keys and never words, so a key missing here would be shown to the person as
/// the key itself ("duo.nudge.sipWithMe").
final class DuoLocalizableTests: XCTestCase {
    /// The keys the server's `src/push/payload.ts` puts in a push, worked out from it: the three
    /// named titles and their `.unnamed` forms, goal met's two bodies, one body per nudge preset,
    /// the digest's body, joined, `ended` for each `ended_by` the contract has, and reconnected for
    /// each `who`. 26 in all.
    private static let serverKeys: Set<String> = {
        var keys: Set<String> = [
            "duo.goal_met.title", "duo.goal_met.title.unnamed", "duo.goal_met.body.both", "duo.goal_met.body.yourturn",
            "duo.nudge.title", "duo.nudge.title.unnamed",
            "duo.digest.title", "duo.digest.title.unnamed", "duo.digest.body",
            "duo.joined.body",
            "duo.reconnected.partner", "duo.reconnected.superseded",
        ]
        for preset in DuoNudgePreset.allCases { keys.insert("duo.nudge.\(preset.rawValue)") }
        // `unknown` is the client's own reading of an `ended_by` it does not know; the server never sends it.
        for endedBy in ["owner", "partner", "owner_deleted", "partner_deleted", "inactive", "demo_expired"] { keys.insert("duo.ended.\(endedBy)") }
        return keys
    }()

    /// Every line, word for word: FD §9.2's titles and bodies, 01 §5.1's nudge lines (DuoNudgePreset),
    /// §7.5's "Your duo has ended", §3.5's reconnect notices (approved 2026-10-02), and the four
    /// placeholders awaiting Jonathon's approval (the digest's unnamed title and body, the inactive
    /// and demo ends).
    private static let expected: [String: String] = {
        var lines: [String: String] = [
            "duo.goal_met.title": "%@ hit their goal",
            "duo.goal_met.title.unnamed": "Your partner hit their goal",
            "duo.goal_met.body.both": "You both made it today.",
            "duo.goal_met.body.yourturn": "Your turn. Keep the flame going.",
            "duo.nudge.title": "%@ nudged you",
            "duo.nudge.title.unnamed": "Your partner nudged you",
            "duo.digest.title": "%@ while you were away",
            "duo.digest.title.unnamed": "Your partner while you were away",
            "duo.digest.body": "%@ updates",
            "duo.joined.body": "Your partner joined your duo",
            "duo.reconnected.partner": "Your partner's new phone is connected.",
            "duo.reconnected.superseded": "Your duo was moved to another phone. Not you? Leave & block",
        ]
        for preset in DuoNudgePreset.allCases { lines["duo.nudge.\(preset.rawValue)"] = preset.text }
        for endedBy in ["owner", "partner", "owner_deleted", "partner_deleted", "inactive", "demo_expired"] {
            lines["duo.ended.\(endedBy)"] = "Your duo has ended"
        }
        return lines
    }()

    /// The keys that take the server's one argument.
    private static let withOneArgument: Set<String> = ["duo.goal_met.title", "duo.nudge.title", "duo.digest.title", "duo.digest.body"]

    private func table() throws -> [String: String] {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.jonathonbrown.HydroDrop", "the tests run inside the app, whose bundle this is")
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"),
                                 "Localizable.strings is in the app bundle's en.lproj")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    func testThereAreExactlyTheServersTwentySixKeys() throws {
        XCTAssertEqual(Self.serverKeys.count, 26)
        let keys = Set(try table().keys)
        XCTAssertEqual(keys, Self.serverKeys, "missing: \(Self.serverKeys.subtracting(keys).sorted()), extra: \(keys.subtracting(Self.serverKeys).sorted())")
    }

    func testEveryKeyResolvesToItsLineAndNotToItself() {
        let missing = "\u{0}missing"
        for key in Self.serverKeys.sorted() {
            let line = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
            XCTAssertNotEqual(line, missing, key)
            XCTAssertNotEqual(line, key, key)
            XCTAssertEqual(line, Self.expected[key], key)
        }
    }

    func testTheNudgeLinesAreThePresetsOwn() {
        for preset in DuoNudgePreset.allCases {
            XCTAssertEqual(Bundle.main.localizedString(forKey: "duo.nudge.\(preset.rawValue)", value: nil, table: nil), preset.text, preset.rawValue)
        }
    }

    /// A title the server sends a name with has exactly one `%@`; every other line has none, and no
    /// line has any other format, which iOS would read garbage into.
    func testTheArgumentsAreExactlyTheOnesTheServerSends() throws {
        for (key, line) in try table() {
            let placeholders = line.components(separatedBy: "%@").count - 1
            XCTAssertEqual(placeholders, Self.withOneArgument.contains(key) ? 1 : 0, key)
            XCTAssertEqual(line.filter { $0 == "%" }.count, placeholders, "\(key): only %@, and only where the server sends an argument")
        }
    }

    /// The names the server's push carries ride in the arguments only, and the name-free kinds are
    /// name-free here too (§9.2: membership pushes carry no name).
    func testTheMembershipLinesNameNobody() throws {
        let table = try table()
        for key in Self.serverKeys where key.hasPrefix("duo.joined.") || key.hasPrefix("duo.ended.") || key.hasPrefix("duo.reconnected.") {
            XCTAssertFalse(table[key, default: ""].contains("%"), key)
        }
    }
}
#endif
