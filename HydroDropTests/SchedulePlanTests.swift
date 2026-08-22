import XCTest
@testable import HydroDrop

final class SchedulePlanTests: XCTestCase {
    private func plan(from start: Int, to end: Int, every interval: Int) -> SchedulePlan? {
        SchedulePlan(startMinutes: start, endMinutes: end, intervalMinutes: interval)
    }

    func testOrdinaryWakingWindow() {
        let plan = plan(from: 8 * 60, to: 22 * 60, every: 20)
        XCTAssertEqual(plan?.windowLength, 840)
        XCTAssertEqual(plan?.slotOffsets.count, 42)
    }

    /// Regression: `end > start ? ... : ...` read a start equal to its own end as a
    /// wrap-around, producing a 1440-minute window — a mis-set picker turned into
    /// reminders around the clock.
    func testAStartEqualToItsEndProducesNoSchedule() {
        XCTAssertNil(plan(from: 8 * 60, to: 8 * 60, every: 20))
        XCTAssertNil(plan(from: 0, to: 0, every: 20))
    }

    func testOvernightWindowWraps() {
        let plan = plan(from: 22 * 60, to: 6 * 60, every: 120)
        XCTAssertEqual(plan?.windowLength, 480)
        XCTAssertEqual(plan?.slotOffsets, [0, 120, 240, 360])
    }

    /// Every slot of a wrapping window has to land back inside that window once the
    /// minute-of-day modulo is applied.
    func testWrappedSlotsStayInsideTheWindow() throws {
        let start = 22 * 60
        let plan = try XCTUnwrap(plan(from: start, to: 6 * 60, every: 120))
        let minutesOfDay = plan.slotOffsets.map { (start + $0) % SchedulePlan.minutesPerDay }
        XCTAssertEqual(minutesOfDay, [1320, 0, 120, 240])
        for minute in minutesOfDay {
            XCTAssertTrue(minute >= start || minute < 6 * 60, "\(minute) is outside 22:00–06:00")
        }
    }

    func testAnIntervalWiderThanTheWindowStillGivesOneSlot() {
        XCTAssertEqual(plan(from: 8 * 60, to: 9 * 60, every: 120)?.slotOffsets, [0])
    }

    func testIntervalHasAFloor() {
        // A zero interval would stride forever.
        XCTAssertEqual(plan(from: 8 * 60, to: 9 * 60, every: 0)?.slotOffsets.count, 12)
    }

    /// Regression: the 64-pending-request limit iOS enforces was only respected by the
    /// pace-aware path, and a window reachable from the two time pickers produces more
    /// slots than that.
    func testTheWidestReachableWindowExceedsTheSystemLimit() throws {
        let plan = try XCTUnwrap(plan(from: 7 * 60, to: 7 * 60 - 1, every: 20))
        XCTAssertEqual(plan.windowLength, 1439)
        XCTAssertEqual(plan.slotOffsets.count, 72)
        XCTAssertLessThan(
            ReminderManager.maxPendingRequests,
            plan.slotOffsets.count,
            "this window is exactly why the fixed schedule needs its own cap"
        )
        XCTAssertEqual(plan.slotOffsets.prefix(ReminderManager.maxPendingRequests).count, 60)
    }
}

final class PaceTests: XCTestCase {
    private let manager = ReminderManager.shared

    /// Regression: the expected fraction at the first slot is zero, and everyone has
    /// drunk at least nothing — so the opening nudge of the day was always suppressed.
    func testTheFirstSlotIsNotSuppressedForSomeoneWhoHasDrunkNothing() {
        XCTAssertFalse(
            manager.isAheadOfPace(slotOffset: 0, windowLength: 840, todayTotalML: 0, goalML: 2000)
        )
    }

    func testTheFirstSlotIsSuppressedOnceTheGoalIsAlreadyMet() {
        XCTAssertTrue(
            manager.isAheadOfPace(slotOffset: 0, windowLength: 840, todayTotalML: 2000, goalML: 2000)
        )
    }

    func testMidWindowSuppressionFollowsThePace() {
        // Halfway through the window, half the goal is on pace.
        XCTAssertTrue(
            manager.isAheadOfPace(slotOffset: 420, windowLength: 840, todayTotalML: 1000, goalML: 2000)
        )
        XCTAssertFalse(
            manager.isAheadOfPace(slotOffset: 420, windowLength: 840, todayTotalML: 999, goalML: 2000)
        )
    }

    func testDegenerateInputsNeverSuppress() {
        XCTAssertFalse(
            manager.isAheadOfPace(slotOffset: 100, windowLength: 0, todayTotalML: 5000, goalML: 2000)
        )
        XCTAssertFalse(
            manager.isAheadOfPace(slotOffset: 100, windowLength: 840, todayTotalML: 5000, goalML: 0)
        )
    }
}
