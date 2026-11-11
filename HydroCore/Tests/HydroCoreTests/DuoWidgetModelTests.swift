import XCTest
@testable import HydroCore

final class DuoWidgetModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1791547200)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }
    private var today: String { DayKey.key(for: now, calendar: calendar) }
    private func duo(_ name: String = "Sam", joined: Bool = true) -> DuoState {
        DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jo", partnerDisplayName: name,
                 ownerSkin: "classic", partnerSkin: "forest", statuses: [], partnerHasJoined: joined)
    }
    private func model(_ duos: [DuoState], day: String = "", total: Int = 0) -> DuoWidgetModel {
        .make(duos: duos, ageStatus: .allowed, ageCheckUnavailable: false, now: now, snapshotDay: day, snapshotTotalML: total, snapshotGoalML: 2000, calendar: calendar)
    }
    func testJoinedLiveDuoWinsOverPendingAndEnded() {
        var ended = duo("Ended"); ended.endedAt = now
        let result = model([ended, duo("Pending", joined: false), duo("First"), duo("Last")])
        XCTAssertEqual(result.state, .running)
        XCTAssertEqual(result.partnerName, "First")
    }
    func testPendingBeatsEmptyAndQueuedLeaveIsNeverDrawn() {
        var leaving = duo(); leaving.pendingOp = .leave
        XCTAssertEqual(model([leaving]).state, .empty)
        XCTAssertEqual(model([leaving, duo(joined: false)]).state, .pending)
        XCTAssertEqual(model([]).accessibilityLabel, "No duo yet. Start one in HydroDrop, under Settings.")
    }
    func testTodaysSnapshotOverridesOwnStatusButOldSnapshotDoesNot() {
        var d = duo()
        d.statuses = [.init(role: .owner, day: today, goalMet: false, progressBucket: 25, updatedAt: now)]
        XCTAssertEqual(model([d], day: today, total: 1500).myBucket, 75)
        XCTAssertEqual(model([d], day: "1999-01-01", total: 1500).myBucket, 25)
    }
    func testStalePartnerDayIsHidden() {
        var d = duo()
        d.statuses = [.init(role: .partner, day: "1999-01-01", goalMet: true, progressBucket: 100, updatedAt: now)]
        XCTAssertEqual(model([d]).partnerBucket, 0)
    }
    func testNicknamePlainTextAndSampleReachBothVisibleAndSpokenCopy() {
        var d = duo("Server"); d.partnerNickname = "<b>**Sam**</b>"; d.partnerIsDemo = true
        let result = model([d])
        XCTAssertEqual(result.partnerName, "<b>**Sam**</b>")
        XCTAssertEqual(result.sampleBadge, "Sample")
        XCTAssertTrue(result.accessibilityLabel.contains("<b>**Sam**</b>"))
        XCTAssertTrue(result.accessibilityLabel.hasSuffix("Sample."))
    }
    func testPendingAccessibilityAndUnknownSkinsRemainPlainValues() {
        var d = duo(joined: false); d.ownerSkin = "future"
        XCTAssertEqual(model([d]).accessibilityLabel, "Duo streak. Waiting for your partner to accept the invite.")
        XCTAssertEqual(model([d]).mySkin, "future")
    }
    func testRetentionEdgeSays100PlusDays() {
        var d = duo()
        for offset in 0..<100 {
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            for role in DuoRole.allCases {
                d.statuses.append(.init(role: role, day: DayKey.key(for: date, calendar: calendar), goalMet: true, progressBucket: 100, updatedAt: now))
            }
        }
        XCTAssertEqual(model([d]).streakText, "100+ days")
        XCTAssertTrue(model([d]).accessibilityLabel.contains("100+ days together"))
    }
    func testPartnerRoleUsesOwnersNameAndSkins() {
        var d = duo(); d.myRole = .partner
        let result = model([d])
        XCTAssertEqual(result.partnerName, "Jo")
        XCTAssertEqual(result.mySkin, "forest")
        XCTAssertEqual(result.partnerSkin, "classic")
    }
    func testEmptyNameAndMissingOrFarFutureStatusesAreSafe() {
        var d = duo("")
        d.statuses = [.init(role: .partner, day: "2099-01-01", goalMet: true, progressBucket: 100, updatedAt: now)]
        let result = model([d])
        XCTAssertEqual(result.partnerName, "Your partner")
        XCTAssertEqual(result.partnerBucket, 0)
        XCTAssertEqual(result.streakDays, 0)
    }
    func testRefusedAndUnknownAgeNeverExposeRetainedDuo() {
        for age in [DuoAgeStatus.refused, .unknown] {
            let result = DuoWidgetModel.make(duos: [duo()], ageStatus: age, ageCheckUnavailable: false, now: now,
                snapshotDay: today, snapshotTotalML: 1500, snapshotGoalML: 2000, calendar: calendar)
            XCTAssertEqual(result.state, .empty)
            XCTAssertEqual(result.partnerName, "")
        }
    }
    func testTemporarilyUnreadableRefusalHidesPreviouslyAllowedDuo() {
        let result = DuoWidgetModel.make(duos: [duo()], ageStatus: .allowed, ageCheckUnavailable: true, now: now,
            snapshotDay: today, snapshotTotalML: 1500, snapshotGoalML: 2000, calendar: calendar)
        XCTAssertEqual(result.state, .empty)
        XCTAssertEqual(result.partnerName, "")
    }
    func testPendingDuoNeverReusesRetainedPartnerProgressOrStreak() {
        var d = duo(joined: false)
        for role in DuoRole.allCases {
            d.statuses.append(.init(role: role, day: today, goalMet: true, progressBucket: 100, updatedAt: now))
        }
        let result = model([d])
        XCTAssertEqual(result.partnerBucket, 0)
        XCTAssertEqual(result.streakDays, 0)
        XCTAssertEqual(result.streakText, "0")
    }
    func testNamesAreIsolatedInsideSentencesAndPreservedAsPlainValues() {
        for name in ["ليلى", "\u{202E}Sam\u{202C}"] {
            let result = model([duo(name)])
            let isolated = "\u{2068}\(name)\u{2069}"
            XCTAssertEqual(result.partnerName, name)
            XCTAssertEqual(result.partnerLine, "with \(isolated)")
            XCTAssertTrue(result.accessibilityLabel.hasPrefix("Duo streak with \(isolated)."))
            XCTAssertTrue(result.accessibilityLabel.contains(" \(isolated): "))
        }
    }
    func testFreeDuoNeedsNoPurchaseInput() {
        XCTAssertEqual(model([duo()]).state, .running)
    }
}
