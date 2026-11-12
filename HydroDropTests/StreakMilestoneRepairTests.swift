import XCTest
import SwiftData
@testable import HydroDrop

/// The durable badge changes that happen before a celebration: a restored streak that
/// jumps several thresholds, a sparse shelf left by an older save, and a stale iCloud
/// value meeting locally earned badges. Every store a test writes is its own, so no
/// test touches the signed-in person's preferences or iCloud.
///
/// Taken from the milestone half of StreakCorrectionsTests on the Duo branch, under its
/// own name so that branch's file still merges cleanly.
final class StreakMilestoneRepairTests: XCTestCase {
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

    private func withSettings(
        _ body: (UserDefaults, CloudSettingsStore, AppSettings) throws -> Void
    ) throws {
        let name = "HydroDrop.StreakMilestoneRepairTests.\(UUID().uuidString)"
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

    /// iCloud as the launch sees it: whatever this device's cache holds, plus a record
    /// of every key written to it.
    private final class StandInCloud: NSUbiquitousKeyValueStore {
        var values: [String: Any] = [:]
        var writtenKeys: [String] = []
        override func object(forKey aKey: String) -> Any? { values[aKey] }
        override func set(_ anObject: Any?, forKey aKey: String) {
            values[aKey] = anObject
            writtenKeys.append(aKey)
        }
        override func removeObject(forKey aKey: String) {
            values[aKey] = nil
            writtenKeys.append(aKey)
        }
    }

    private func withStaleCloud(
        _ body: (UserDefaults, StandInCloud, CloudSettingsStore) throws -> Void
    ) throws {
        let name = "HydroDrop.StreakMilestoneRepairTests.\(UUID().uuidString)"
        let local = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { local.removePersistentDomain(forName: name) }
        let cloud = StandInCloud()
        try body(local, cloud, CloudSettingsStore(local: local, cloud: cloud))
    }

    func testAStaleICloudShelfDoesNotHideBadgesEarnedOnThisDevice() throws {
        try withStaleCloud { local, cloud, synced in
            cloud.values["celebratedMilestones"] = [7]
            local.set([30, 999], forKey: "celebratedMilestones")
            let loaded = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(loaded.celebratedMilestones, [3, 7, 14, 30, 999])
            XCTAssertEqual(cloud.values["celebratedMilestones"] as? [Int], [3, 7, 14, 30, 999])
            XCTAssertEqual(local.array(forKey: "celebratedMilestones") as? [Int], [3, 7, 14, 30, 999])
            XCTAssertNil(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: Set(loaded.celebratedMilestones)))
        }
    }

    func testALaggingLocalMirrorIsRefreshedWithoutReuploadingWhatICloudHolds() throws {
        // Re-uploading the cached shelf could replace a newer one from another device.
        try withStaleCloud { local, cloud, synced in
            cloud.values["celebratedMilestones"] = [3, 7, 14, 30]
            local.set([3, 7], forKey: "celebratedMilestones")
            let loaded = AppSettings(defaults: local, synced: synced)
            XCTAssertEqual(loaded.celebratedMilestones, [3, 7, 14, 30])
            XCTAssertEqual(local.array(forKey: "celebratedMilestones") as? [Int], [3, 7, 14, 30])
            XCTAssertFalse(cloud.writtenKeys.contains("celebratedMilestones"))
        }
    }

    func testASeededShelfOnThisDeviceOutlivesAStaleICloudFalse() throws {
        try withStaleCloud { local, cloud, synced in
            cloud.values["hasSeededMilestones"] = false
            local.set(true, forKey: "hasSeededMilestones")
            let loaded = AppSettings(defaults: local, synced: synced)
            XCTAssertTrue(loaded.hasSeededMilestones)
            XCTAssertEqual(cloud.values["hasSeededMilestones"] as? Bool, true)
        }
    }

    func testAnAgreeingShelfIsNotWrittenAtLaunch() throws {
        try withStaleCloud { local, cloud, synced in
            cloud.values["celebratedMilestones"] = [3, 7]
            cloud.values["hasSeededMilestones"] = true
            local.set([3, 7], forKey: "celebratedMilestones")
            local.set(true, forKey: "hasSeededMilestones")
            _ = AppSettings(defaults: local, synced: synced)
            XCTAssertFalse(cloud.writtenKeys.contains("celebratedMilestones"))
            XCTAssertFalse(cloud.writtenKeys.contains("hasSeededMilestones"))
        }
    }

    func testCombiningAnOlderPreferredShelfWithTheLocalMirrorKeepsTheHigherAward() {
        let preferred = [7]
        let local = [30, 999]
        XCTAssertEqual(StreakMilestone.normalizedAwards(preferred + local), [3, 7, 14, 30, 999])
        XCTAssertEqual(StreakMilestone.normalizedAwards(local + preferred), [3, 7, 14, 30, 999])
    }
}
