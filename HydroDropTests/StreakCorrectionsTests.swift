import XCTest
import SwiftData
@testable import HydroDrop

/// Fixed-clock regressions for the month charged by a freeze and the durable badge
/// changes that happen before a celebration. Every writable store is isolated.
final class StreakCorrectionsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    override func setUpWithError() throws {
        let temporary = try TemporaryStore.make(for: Schema([WaterEntry.self]))
        container = temporary.container
        directory = temporary.directory
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        TemporaryStore.remove(directory)
        directory = nil
        super.tearDown()
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func entries(_ days: [String], amount: Int = 2_000) -> [WaterEntry] {
        days.map { WaterEntry(amountML: amount, timestamp: date("\($0)T15:00:00Z")) }
    }

    /// Assert both public paths because Home's LogCache uses grouped totals while
    /// other consumers still provide entries directly.
    private func assertProtection(
        _ expected: String?, entries: [WaterEntry], frozen: [String], now: String,
        subscribed: Bool = true, zone: String = "UTC", file: StaticString = #filePath, line: UInt = #line
    ) {
        let cal = calendar(zone)
        let instant = date(now)
        XCTAssertEqual(StreakFreeze.dayToProtect(entries: entries, goalML: 2_000,
            frozenDayKeys: frozen, isSubscribed: subscribed, now: instant, calendar: cal), expected, file: file, line: line)
        XCTAssertEqual(StreakFreeze.dayToProtect(totals: StreakCalculator.totalsByDay(entries, calendar: cal),
            goalML: 2_000, frozenDayKeys: frozen, isSubscribed: subscribed,
            now: instant, calendar: cal), expected, file: file, line: line)
    }

    func testMonthRolloverCannotSpendAnotherFreezeFromTheProtectedMonth() {
        assertProtection(nil, entries: entries(["2026-08-30"]), frozen: ["2026-08-05"], now: "2026-09-01T18:00:00Z")
    }

    func testTheNextMonthsLedgerDoesNotBlockAnUnusedProtectedMonth() {
        // A restored ledger or a clock/zone change can make the next month's key
        // present. Its allowance is independent of the August day being protected.
        assertProtection("2026-08-31", entries: entries(["2026-08-30"]), frozen: ["2026-09-02"], now: "2026-09-01T18:00:00Z")
    }

    func testYearAndLeapMonthBoundariesUseTheMissedDaysAllowance() {
        let december = entries(["2026-12-30"])
        assertProtection(nil, entries: december, frozen: ["2026-12-05"], now: "2027-01-01T18:00:00Z")
        assertProtection("2026-12-31", entries: december, frozen: [], now: "2027-01-01T18:00:00Z")
        let february = entries(["2028-02-28"])
        assertProtection(nil, entries: february, frozen: ["2028-02-05"], now: "2028-03-01T18:00:00Z")
        assertProtection("2028-02-29", entries: february, frozen: [], now: "2028-03-01T18:00:00Z")
    }

    func testRepeatedReconciliationRetainsOneFreezeWithoutAddingAGoalDay() throws {
        let log = entries(["2026-08-29", "2026-08-30"])
        let now = date("2026-09-01T18:00:00Z")
        let protected = try XCTUnwrap(StreakFreeze.dayToProtect(entries: log, goalML: 2_000,
            frozenDayKeys: [], isSubscribed: true, now: now, calendar: calendar()))
        XCTAssertEqual(protected, "2026-08-31")
        assertProtection(nil, entries: log, frozen: [protected], now: "2026-09-01T18:00:00Z")
        XCTAssertEqual(StreakCalculator.currentStreak(entries: log, goalML: 2_000,
            frozenDayKeys: [protected], now: now, calendar: calendar()), 2)
        XCTAssertEqual(StreakFreeze.freezesRemaining(frozenDayKeys: [protected], now: now, calendar: calendar()), 1)
        assertProtection("2026-09-02", entries: entries(["2026-09-01"]), frozen: [protected], now: "2026-09-03T18:00:00Z")
    }

    func testTravelRetainsTheProtectedDayAndItsMonth() {
        let log = entries(["2026-08-29", "2026-08-30"])
        let frozen = ["2026-08-31"]
        for zone in ["America/New_York", "Europe/London"] {
            assertProtection(nil, entries: log, frozen: frozen, now: "2026-09-01T18:00:00Z", zone: zone)
            XCTAssertEqual(StreakCalculator.currentStreak(entries: log, goalML: 2_000,
                frozenDayKeys: frozen, now: date("2026-09-01T18:00:00Z"), calendar: calendar(zone)), 2)
            XCTAssertEqual(StreakFreeze.freezesRemaining(frozenDayKeys: frozen,
                now: date("2026-08-31T18:00:00Z"), calendar: calendar(zone)), 0)
        }
    }

    func testLapsePreventsNewSpendingButKeepsAnExistingBridge() {
        let log = entries(["2026-08-29", "2026-08-30"])
        assertProtection(nil, entries: log, frozen: [], now: "2026-09-01T18:00:00Z", subscribed: false)
        XCTAssertEqual(StreakCalculator.currentStreak(entries: log, goalML: 2_000,
            frozenDayKeys: ["2026-08-31"], now: date("2026-09-01T18:00:00Z"), calendar: calendar()), 2)
    }

    private func withSettings(
        _ body: (UserDefaults, CloudSettingsStore, AppSettings) throws -> Void
    ) throws {
        let name = "HydroDrop.StreakCorrectionsTests.\(UUID().uuidString)"
        let local = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { local.removePersistentDomain(forName: name) }
        let synced = CloudSettingsStore(localOnly: local)
        let settings = AppSettings(defaults: local, synced: synced)
        try body(local, synced, settings)
    }

    func testFortyDayJumpRecordsEveryThresholdBeforeTheHighestCelebration() throws {
        try withSettings { local, synced, settings in
            settings.seedMilestones(longestStreak: 0)
            let selected = try XCTUnwrap(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(settings.celebratedMilestones)))
            XCTAssertEqual(selected, .oneMonth)
            settings.recordMilestone(selected)
            XCTAssertEqual(settings.celebratedMilestones, [3, 7, 14, 30])
            XCTAssertNil(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(settings.celebratedMilestones)))
            XCTAssertEqual(local.array(forKey: "celebratedMilestones") as? [Int], [3, 7, 14, 30])
            XCTAssertTrue(local.bool(forKey: "hasSeededMilestones"))
            let reopened = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(reopened.celebratedMilestones, [3, 7, 14, 30])
            XCTAssertNil(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(reopened.celebratedMilestones)))
        }
    }

    func testRecordingAnAlreadyStoredHighestBadgeRepairsLowerGapsAndKeepsOtherAwards() throws {
        try withSettings { local, _, settings in
            settings.celebratedMilestones = [30, 365, 999]
            settings.recordMilestone(.oneMonth)
            XCTAssertEqual(settings.celebratedMilestones, [3, 7, 14, 30, 60, 100, 365, 999])
            settings.recordMilestone(.oneMonth)
            XCTAssertEqual(local.array(forKey: "celebratedMilestones") as? [Int], [3, 7, 14, 30, 60, 100, 365, 999])
        }
    }

    func testHistoricalSeedingIsSilentAndRunsOnlyOnceAcrossReinitialization() throws {
        try withSettings { local, synced, settings in
            settings.seedMilestones(longestStreak: 40)
            XCTAssertEqual(settings.celebratedMilestones, [3, 7, 14, 30])
            XCTAssertNil(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(settings.celebratedMilestones)))
            let reopened = AppSettings(defaults: local, synced: synced)
            XCTAssertTrue(reopened.hasSeededMilestones)
            reopened.seedMilestones(longestStreak: 500)
            XCTAssertEqual(reopened.celebratedMilestones, [3, 7, 14, 30])
        }
    }

    func testGoalIncreaseAndDrinkDeletionDoNotRevokePersistedAwards() throws {
        let log = entries(["2026-08-18", "2026-08-19", "2026-08-20"], amount: 1_800)
        for entry in log { context.insert(entry) }
        try context.save()
        try withSettings { local, synced, settings in
            settings.seedMilestones(longestStreak: StreakCalculator.longestStreak(entries: log, goalML: 1_800, calendar: calendar()))
            XCTAssertEqual(settings.celebratedMilestones, [3])
            XCTAssertEqual(StreakCalculator.longestStreak(entries: log, goalML: 2_000, calendar: calendar()), 0)
            settings.seedMilestones(longestStreak: 0)
            for entry in log { context.delete(entry) }
            try context.save()
            XCTAssertTrue(try context.fetch(FetchDescriptor<WaterEntry>()).isEmpty)
            let reopened = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(reopened.celebratedMilestones, [3])
            XCTAssertTrue(reopened.hasSeededMilestones)
        }
    }

    func testRemoteUnionPreservesLocalAwardsAndSeededTrue() throws {
        try withSettings { local, synced, settings in
            settings.seedMilestones(longestStreak: 7)
            settings.frozenStreakDayKeys = ["2026-08-12"]
            synced.set([30, 999], forKey: "celebratedMilestones")
            synced.set(false, forKey: "hasSeededMilestones")
            synced.set(["2026-08-05", "2026-09-03"], forKey: "frozenStreakDayKeys")
            settings.applyRemoteChanges(["celebratedMilestones", "hasSeededMilestones", "frozenStreakDayKeys"])
            XCTAssertTrue(settings.hasSeededMilestones)
            XCTAssertEqual(settings.celebratedMilestones, [3, 7, 14, 30, 999])
            XCTAssertEqual(settings.frozenStreakDayKeys, ["2026-08-05", "2026-09-03"])
            XCTAssertEqual(local.array(forKey: "celebratedMilestones") as? [Int], [3, 7, 14, 30, 999])
            XCTAssertTrue(local.bool(forKey: "hasSeededMilestones"))
            let reopened = AppSettings(defaults: local, synced: synced)
            XCTAssertTrue(reopened.hasSeededMilestones)
            XCTAssertEqual(reopened.celebratedMilestones, [3, 7, 14, 30, 999])
            XCTAssertEqual(reopened.frozenStreakDayKeys, ["2026-08-05", "2026-09-03"])
        }
    }

    func testSparseShelfIsNormalizedAndPersistedBeforeAnotherCelebrationIsSelected() throws {
        try withSettings { local, synced, _ in
            synced.set([30, 999], forKey: "celebratedMilestones")
            synced.set(true, forKey: "hasSeededMilestones")
            let loaded = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(loaded.celebratedMilestones, [3, 7, 14, 30, 999])
            XCTAssertEqual(local.array(forKey: "celebratedMilestones") as? [Int], [3, 7, 14, 30, 999])
            XCTAssertNil(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(loaded.celebratedMilestones)))
            let reopened = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(reopened.celebratedMilestones, loaded.celebratedMilestones)
        }
    }

    func testUnknownFutureAwardsArePreservedWithoutInventingKnownHistory() throws {
        XCTAssertEqual(StreakMilestone.normalizedAwards([999]), [999])
        XCTAssertEqual(StreakMilestone.normalizedAwards([999, 30, 30]), [3, 7, 14, 30, 999])
        try withSettings { local, synced, _ in
            synced.set([999], forKey: "celebratedMilestones")
            synced.set(true, forKey: "hasSeededMilestones")
            let loaded = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(loaded.celebratedMilestones, [999])
            XCTAssertEqual(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(loaded.celebratedMilestones)), .oneMonth)
            loaded.recordMilestone(.oneMonth)
            XCTAssertEqual(loaded.celebratedMilestones, [3, 7, 14, 30, 999])
        }
    }

    func testCombiningAnOlderPreferredShelfWithTheLocalMirrorKeepsTheHigherAward() {
        let preferred = [7]
        let local = [30, 999]
        XCTAssertEqual(StreakMilestone.normalizedAwards(preferred + local), [3, 7, 14, 30, 999])
        XCTAssertEqual(StreakMilestone.normalizedAwards(local + preferred), [3, 7, 14, 30, 999])
    }
}
