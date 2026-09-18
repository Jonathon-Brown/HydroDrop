import XCTest
import SwiftData
@testable import HydroDrop

/// The migration moves a live user's entire history, so these drive the real thing
/// against real SwiftData stores in a temporary directory rather than a stand-in.
final class StoreMigrationTests: XCTestCase {
    private var workingDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = URL.temporaryDirectory.appending(path: "HydroDropMigration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: workingDirectory)
        try super.tearDownWithError()
    }

    private func makeStore(at url: URL, entries: Int) throws {
        let configuration = ModelConfiguration(
            schema: Schema([WaterEntry.self]),
            url: url,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: WaterEntry.self, configurations: configuration)
        let context = ModelContext(container)
        for index in 0..<entries {
            context.insert(WaterEntry(amountML: 100 + index, timestamp: Date().addingTimeInterval(Double(-index * 3600))))
        }
        try context.save()
    }

    func testCopiesEveryEntryAndLeavesTheOriginalAlone() throws {
        let legacy = workingDirectory.appending(path: "default.store")
        let target = workingDirectory.appending(path: "shared/HydroDrop.store")
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeStore(at: legacy, entries: 12)

        let result = StoreMigration.migrate(from: legacy, to: target, fileManager: fileManager)

        XCTAssertEqual(result, target)
        XCTAssertEqual(StoreMigration.entryCount(at: target), 12)
        XCTAssertTrue(
            fileManager.fileExists(atPath: legacy.path(percentEncoded: false)),
            "the original store must never be moved or deleted"
        )
        XCTAssertEqual(StoreMigration.entryCount(at: legacy), 12)
    }

    func testAnEmptyStoreMigratesCleanly() throws {
        let legacy = workingDirectory.appending(path: "default.store")
        let target = workingDirectory.appending(path: "shared/HydroDrop.store")
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeStore(at: legacy, entries: 0)

        XCTAssertEqual(StoreMigration.migrate(from: legacy, to: target, fileManager: fileManager), target)
        XCTAssertEqual(StoreMigration.entryCount(at: target), 0)
    }

    /// A copy that cannot be made has to leave nothing behind, or the next launch opens
    /// a half-written store and treats it as the real one.
    func testAFailedCopyLeavesNothingAtTheDestination() throws {
        let legacy = workingDirectory.appending(path: "default.store")
        try makeStore(at: legacy, entries: 3)
        // A destination directory that does not exist is the simplest real copy failure.
        let target = workingDirectory.appending(path: "missing/HydroDrop.store")

        XCTAssertNil(StoreMigration.migrate(from: legacy, to: target, fileManager: fileManager))
        for suffix in AppGroup.storeSidecarSuffixes {
            let file = StoreMigration.sidecar(of: target, suffix: suffix)
            XCTAssertFalse(fileManager.fileExists(atPath: file.path(percentEncoded: false)))
        }
        XCTAssertEqual(StoreMigration.entryCount(at: legacy), 3, "the original is untouched by a failure")
    }

    func testMigratingFromAStoreThatIsNotThereFails() {
        let legacy = workingDirectory.appending(path: "nothing-here.store")
        let target = workingDirectory.appending(path: "HydroDrop.store")
        XCTAssertNil(StoreMigration.migrate(from: legacy, to: target, fileManager: fileManager))
    }

    func testSidecarNaming() {
        let base = URL(filePath: "/tmp/HydroDrop.store")
        XCTAssertEqual(StoreMigration.sidecar(of: base, suffix: "").lastPathComponent, "HydroDrop.store")
        XCTAssertEqual(StoreMigration.sidecar(of: base, suffix: "-wal").lastPathComponent, "HydroDrop.store-wal")
        XCTAssertEqual(StoreMigration.sidecar(of: base, suffix: "-shm").lastPathComponent, "HydroDrop.store-shm")
    }

    /// SQLite keeps recent writes in the write-ahead log, so a copy of the main file
    /// alone can be missing the newest entries.
    func testTheWriteAheadLogIsCarriedAcross() throws {
        let legacy = workingDirectory.appending(path: "default.store")
        try makeStore(at: legacy, entries: 5)
        XCTAssertTrue(
            AppGroup.storeSidecarSuffixes.contains("-wal"),
            "the copy must include the write-ahead log"
        )
        XCTAssertTrue(
            AppGroup.storeSidecarSuffixes.contains("-shm"),
            "the copy must include the shared-memory file"
        )
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

    func testUnknownStoredValuesFallBackRatherThanFailing() {
        var snapshot = HydrationSnapshot.empty
        snapshot.measurementSystemRawValue = "furlongs"
        snapshot.mascotSkinRawValue = "chartreuse"
        XCTAssertEqual(snapshot.measurementSystem, .deviceDefault)
        XCTAssertEqual(snapshot.mascotSkin, .classic)
    }
}
