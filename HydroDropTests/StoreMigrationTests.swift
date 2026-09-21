import XCTest
import SwiftData
@testable import HydroDrop

/// The migration moves a live user's entire history, so these drive the real thing
/// against real SwiftData stores in a temporary directory rather than a stand-in.
///
/// The migration is a read-and-reinsert, not a file copy: rows are fetched out of the
/// legacy store and written afresh into the group store. That is why nothing here
/// asserts on sidecar files — there is no copy for a `-wal` to be missing from.
final class StoreMigrationTests: XCTestCase {
    private var workingDirectory: URL!
    private let fileManager = FileManager.default

    /// `migrate` and `deduplicateIfNeeded` record their progress in the App Group
    /// suite, which in a test run is the simulator's real one. Saved and put back so a
    /// test cannot leave the installed app thinking it has already migrated.
    private var savedDefaults: [String: Any?] = [:]
    private static let touchedKeys = [
        StoreMigration.migrationCompleteKey,
        StoreMigration.migrationAttemptsKey,
        StoreMigration.lastDedupeCountKey,
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = URL.temporaryDirectory.appending(path: "HydroDropMigration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        for key in Self.touchedKeys {
            savedDefaults[key] = AppGroup.defaults?.object(forKey: key)
            AppGroup.defaults?.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        for key in Self.touchedKeys {
            if let value = savedDefaults[key] ?? nil {
                AppGroup.defaults?.set(value, forKey: key)
            } else {
                AppGroup.defaults?.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        try? fileManager.removeItem(at: workingDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeStore(at url: URL, rows: [WaterEntry]) throws -> ModelContainer {
        let container = try openStore(at: url)
        let context = ModelContext(container)
        for row in rows {
            context.insert(row)
        }
        try context.save()
        return container
    }

    private func openStore(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema([WaterEntry.self]),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: WaterEntry.self, configurations: configuration)
    }

    /// A store's rows, read back through a fresh container so nothing is served from a
    /// context the test already had open.
    private func rowCount(at url: URL) throws -> Int {
        try StoreMigration.readRows(at: url).count
    }

    private func sampleRows(_ count: Int) -> [WaterEntry] {
        (0..<count).map { index in
            WaterEntry(
                amountML: 100 + index,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 3_600))
            )
        }
    }

    private func legacyURL() -> URL { workingDirectory.appending(path: "default.store") }

    private func targetURL() throws -> URL {
        let url = workingDirectory.appending(path: "shared/HydroDrop.store")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// A destination SwiftData genuinely cannot open.
    ///
    /// A merely missing directory is not one: `ModelContainer` creates intermediate
    /// directories itself, so a path under `missing/` migrates perfectly happily. What
    /// it cannot do is treat a regular file as a directory, which is what this builds.
    private func unwritableTargetURL() throws -> URL {
        let blocker = workingDirectory.appending(path: "blocked")
        try Data().write(to: blocker)
        return blocker.appending(path: "HydroDrop.store")
    }

    // MARK: - Reinsert

    func testEveryRowReachesTheTargetAndTheOriginalIsLeftAlone() throws {
        let legacy = legacyURL()
        let target = try targetURL()
        try makeStore(at: legacy, rows: sampleRows(12))

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target), target)

        XCTAssertEqual(try rowCount(at: target), 12)
        XCTAssertTrue(
            fileManager.fileExists(atPath: legacy.path(percentEncoded: false)),
            "the original store must never be moved or deleted"
        )
        XCTAssertEqual(try rowCount(at: legacy), 12, "the original still holds every row")
    }

    func testAnEmptyStoreMigratesCleanly() throws {
        let legacy = legacyURL()
        let target = try targetURL()
        try makeStore(at: legacy, rows: [])

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target), target)
        XCTAssertEqual(try rowCount(at: target), 0)
    }

    /// The reinsert builds brand-new objects, so anything it forgets to copy across is
    /// silently lost for every existing user.
    func testDrinkTypeAndHealthSampleSurviveTheReinsert() throws {
        let legacy = legacyURL()
        let target = try targetURL()
        let entry = WaterEntry(
            amountML: 330,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            drinkType: .coffee
        )
        entry.healthKitSampleUUID = "6B1E7F70-0000-4000-8000-00000000ABCD"
        try makeStore(at: legacy, rows: [entry])

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target), target)

        let migrated = try XCTUnwrap(StoreMigration.readRows(at: target).first)
        XCTAssertEqual(migrated.amountML, 330)
        XCTAssertEqual(migrated.drinkType, .coffee)
        XCTAssertEqual(migrated.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(migrated.healthKitSampleUUID, "6B1E7F70-0000-4000-8000-00000000ABCD")
    }

    /// An entry logged before drink types existed has no raw value at all, and must
    /// still read as water on the other side rather than becoming an "unknown".
    func testAnUntypedRowStaysUntyped() throws {
        let legacy = legacyURL()
        let target = try targetURL()
        let entry = WaterEntry(amountML: 250, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        entry.drinkTypeRawValue = nil
        try makeStore(at: legacy, rows: [entry])

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target), target)

        let migrated = try XCTUnwrap(StoreMigration.readRows(at: target).first)
        XCTAssertNil(migrated.drinkTypeRawValue)
        XCTAssertEqual(migrated.drinkType, .water)
    }

    func testReinsertReportsWhatTheTargetHolds() throws {
        let target = try targetURL()
        XCTAssertEqual(try StoreMigration.reinsert(sampleRows(4), into: target), 4)
    }

    /// `resolveStoreURL` creates the shared directory before any of this runs, but the
    /// reinsert does not depend on that having happened: SwiftData makes the
    /// intermediate directories itself. Worth pinning down, because the obvious way to
    /// write a "the destination is broken" test is to point at a missing folder, and
    /// that test would pass for the wrong reason.
    func testAMissingDestinationDirectoryIsCreatedRatherThanFailing() throws {
        let legacy = legacyURL()
        try makeStore(at: legacy, rows: sampleRows(2))
        let target = workingDirectory.appending(path: "not-yet/HydroDrop.store")

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target), target)
        XCTAssertEqual(try rowCount(at: target), 2)
    }

    // MARK: - Failure

    /// A reinsert that cannot be written leaves the app on its original store, and
    /// crucially does not record completion: the next launch has to be able to retry.
    func testAFailedReinsertLeavesTheAppOnTheOriginalStore() throws {
        let legacy = legacyURL()
        try makeStore(at: legacy, rows: sampleRows(3))
        let target = try unwritableTargetURL()

        XCTAssertNil(StoreMigration.migrate(from: legacy, to: target))

        XCTAssertNotEqual(
            AppGroup.defaults?.bool(forKey: StoreMigration.migrationCompleteKey), true,
            "a failure must never mark the migration complete"
        )
        XCTAssertEqual(try rowCount(at: legacy), 3, "the original is untouched by a failure")
    }

    func testEachFailureBumpsTheAttemptCounter() throws {
        let legacy = legacyURL()
        try makeStore(at: legacy, rows: sampleRows(2))
        let target = try unwritableTargetURL()

        XCTAssertNil(StoreMigration.migrate(from: legacy, to: target))
        XCTAssertEqual(AppGroup.defaults?.integer(forKey: StoreMigration.migrationAttemptsKey), 1)

        XCTAssertNil(StoreMigration.migrate(from: legacy, to: target))
        XCTAssertEqual(AppGroup.defaults?.integer(forKey: StoreMigration.migrationAttemptsKey), 2)
    }

    func testSuccessMarksTheMigrationComplete() throws {
        let legacy = legacyURL()
        let target = try targetURL()
        try makeStore(at: legacy, rows: sampleRows(1))

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target), target)
        XCTAssertEqual(AppGroup.defaults?.bool(forKey: StoreMigration.migrationCompleteKey), true)
    }

    // MARK: - Dedupe

    /// The reinserted copies and the CloudKit-mirrored originals are distinct objects
    /// with identical field values, which is exactly what the pass has to collapse.
    func testDuplicateRowsAreCollapsedToOne() throws {
        let url = try targetURL()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try makeStore(at: url, rows: [
            WaterEntry(amountML: 250, timestamp: timestamp),
            WaterEntry(amountML: 250, timestamp: timestamp),
            WaterEntry(amountML: 250, timestamp: timestamp),
        ])

        StoreMigration.deduplicateIfNeeded(in: container)

        XCTAssertEqual(try rowCount(at: url), 1)
    }

    /// Two drinks of different sizes at the same instant are two real drinks, and a
    /// pass that collapsed them would quietly delete the user's water.
    func testDrinksThatOnlyShareATimestampAreKept() throws {
        let url = try targetURL()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try makeStore(at: url, rows: [
            WaterEntry(amountML: 250, timestamp: timestamp),
            WaterEntry(amountML: 500, timestamp: timestamp),
            WaterEntry(amountML: 250, timestamp: timestamp, drinkType: .coffee),
        ])

        StoreMigration.deduplicateIfNeeded(in: container)

        XCTAssertEqual(try rowCount(at: url), 3)
    }

    func testDedupeRecordsTheSettledCountSoTheNextPassCanSkip() throws {
        let url = try targetURL()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try makeStore(at: url, rows: [
            WaterEntry(amountML: 250, timestamp: timestamp),
            WaterEntry(amountML: 250, timestamp: timestamp),
        ])

        StoreMigration.deduplicateIfNeeded(in: container)

        XCTAssertEqual(
            AppGroup.defaults?.object(forKey: StoreMigration.lastDedupeCountKey) as? Int, 1,
            "the count recorded must be what the store holds after the pass, not before"
        )
    }

    func testAStoreWithNothingToCollapseIsLeftAlone() throws {
        let url = try targetURL()
        let container = try makeStore(at: url, rows: sampleRows(5))

        StoreMigration.deduplicateIfNeeded(in: container)

        XCTAssertEqual(try rowCount(at: url), 5)
    }
}

final class HydrationSnapshotTests: XCTestCase {
    func testProgressIsTotalOverGoal() {
        var snapshot = HydrationSnapshot.empty
        snapshot.todayTotalML = 1_000
        snapshot.dailyGoalML = 2_000
        XCTAssertEqual(snapshot.progress, 0.5, accuracy: 0.0001)
    }

    func testAZeroGoalDoesNotDivideByZero() {
        var snapshot = HydrationSnapshot.empty
        snapshot.dailyGoalML = 0
        snapshot.todayTotalML = 500
        XCTAssertEqual(snapshot.progress, 0)
    }

    /// A widget can render long after the app last ran, and yesterday's intake shown as
    /// today's is worse than showing nothing.
    func testYesterdaysTotalReadsAsZeroToday() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        var snapshot = HydrationSnapshot.empty
        snapshot.dayKey = DayKey.key(for: yesterday)
        snapshot.todayTotalML = 1_800

        let resolved = snapshot.resolved(now: now)
        XCTAssertEqual(resolved.todayTotalML, 0)
        XCTAssertEqual(resolved.dayKey, DayKey.key(for: now))
    }

    func testTodaysTotalSurvivesResolution() {
        let now = Date()
        var snapshot = HydrationSnapshot.empty
        snapshot.dayKey = DayKey.key(for: now)
        snapshot.todayTotalML = 900
        XCTAssertEqual(snapshot.resolved(now: now), snapshot)
    }

    func testRoundTripsThroughJSON() throws {
        let snapshot = HydrationSnapshot.placeholder
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(HydrationSnapshot.self, from: data), snapshot)
    }

    /// A snapshot written by a build from before widgets were gated has no
    /// `isPlusActive` key at all. It has to decode as unlocked: the alternative is that
    /// updating locks a paying subscriber out of their own widgets until the next time
    /// they happen to open the app.
    func testASnapshotWrittenBeforeGatingDecodesAsUnlocked() throws {
        let encoded = try JSONEncoder().encode(HydrationSnapshot.placeholder)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isPlusActive")
        XCTAssertNil(object["isPlusActive"], "the fixture has to be missing the new field")

        let decoded = try JSONDecoder().decode(
            HydrationSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.isPlusActive, "an older snapshot must never read as locked")
        // The rest of the snapshot has to survive the custom decoder too.
        XCTAssertEqual(decoded.todayTotalML, HydrationSnapshot.placeholder.todayTotalML)
        XCTAssertEqual(decoded.dailyGoalML, HydrationSnapshot.placeholder.dailyGoalML)
        XCTAssertEqual(decoded.streak, HydrationSnapshot.placeholder.streak)
        XCTAssertEqual(decoded.quickAddPresetsML, HydrationSnapshot.placeholder.quickAddPresetsML)
        XCTAssertEqual(decoded.canLogFromExtensions, HydrationSnapshot.placeholder.canLogFromExtensions)
    }

    /// The lock only ever appears once the app has positively published "not
    /// subscribed", so that value has to survive the round trip.
    func testAnExplicitlyLockedSnapshotStaysLocked() throws {
        var snapshot = HydrationSnapshot.empty
        snapshot.isPlusActive = false
        let decoded = try JSONDecoder().decode(
            HydrationSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )
        XCTAssertFalse(decoded.isPlusActive)
        XCTAssertEqual(decoded, snapshot)
    }

    func testUnknownStoredValuesFallBackRatherThanFailing() {
        var snapshot = HydrationSnapshot.empty
        snapshot.measurementSystemRawValue = "furlongs"
        snapshot.mascotSkinRawValue = "chartreuse"
        XCTAssertEqual(snapshot.measurementSystem, .deviceDefault)
        XCTAssertEqual(snapshot.mascotSkin, .classic)
    }
}
