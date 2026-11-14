#if DUO_V2
import SwiftData
import XCTest
@testable import HydroDrop

/// The one reader of the SwiftData log for Duo (final design §8.7, §10.5, §10.6). Over a real
/// store, not an in-memory one: saving into an in-memory store raises an Objective-C exception on
/// iOS 27 that no test can catch (`TemporaryStore`).
@MainActor
final class DuoLogReaderTests: XCTestCase {
    private var directory: URL?
    private var container: ModelContainer!
    /// 2026-09-29T12:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_790_683_200)

    override func setUp() async throws {
        let store = try TemporaryStore.make(for: Schema([WaterEntry.self]))
        container = store.container
        directory = store.directory
    }

    override func tearDown() async throws {
        container = nil
        TemporaryStore.remove(directory)
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func add(_ ml: Int, hoursAgo: Double, _ type: DrinkType = .water) {
        container.mainContext.insert(WaterEntry(amountML: ml, timestamp: now.addingTimeInterval(-hoursAgo * 3600), drinkType: type))
    }

    private func reader(goal: Int = 2000, zone: String = "UTC") -> SwiftDataDuoLogReader {
        let calendar = calendar(zone)
        return SwiftDataDuoLogReader(container: container, isTheSharedStore: true, goalML: { goal }, calendar: { calendar })
    }

    private func allEntries() throws -> [WaterEntry] { try container.mainContext.fetch(FetchDescriptor<WaterEntry>()) }

    func testTheLastNineDaysAreTotalledTheWayTheSoloStreakTotalsThem() throws {
        add(500, hoursAgo: 1)
        add(250, hoursAgo: 2, .coffee)
        add(400, hoursAgo: 30, .juice)
        add(1000, hoursAgo: 24 * 6)
        add(700, hoursAgo: 24 * 8.9)
        add(900, hoursAgo: 24 * 12)
        try container.mainContext.save()
        let summary = reader().read(now: now)
        let horizon = now.addingTimeInterval(-9 * 86_400)
        let expected = StreakCalculator.totalsByDay(try allEntries().filter { $0.timestamp >= horizon }, calendar: calendar("UTC"))
        XCTAssertEqual(summary.totalsByDay, expected, "the duo and the person's own ring count a drink the same")
        XCTAssertFalse(summary.totalsByDay.keys.contains("2026-09-17"), "a drink older than the window is not in the totals")
        XCTAssertLessThan(summary.totalsByDay["2026-09-29"] ?? 0, 750, "a coffee counts for what it hydrates, not what was poured")
        XCTAssertEqual(summary.earliestEntryDay, "2026-09-17", "but it is the oldest drink in the log")
        XCTAssertEqual(summary.goalML, 2000)
    }

    func testTheReaderAgreesWithWhatTheStoreWorksOutFromTheSameLog() throws {
        add(600, hoursAgo: 3)
        add(300, hoursAgo: 50, .blackTea)
        add(800, hoursAgo: 24 * 20)
        try container.mainContext.save()
        let store = DuoStore(cache: DuoCache(defaults: ReaderMemoryDefaults()), usesServer: false, reloadWidget: {})
        store.logChanged(entries: try allEntries(), goalML: 2400, now: now)
        // The store groups in the phone's calendar, so the reader is given the same one here.
        let read = SwiftDataDuoLogReader(container: container, isTheSharedStore: true, goalML: { 2400 }, calendar: { Calendar.current }).read(now: now)
        XCTAssertEqual(read, store.latest)
    }

    func testTheDayADrinkFallsOnIsReadInThePhonesCalendarNow() throws {
        // X10: 03:00Z on the 29th is the 28th in Los Angeles and the 29th in Tokyo.
        container.mainContext.insert(WaterEntry(amountML: 2000, timestamp: ISO8601DateFormatter().date(from: "2026-09-29T03:00:00Z")!))
        try container.mainContext.save()
        XCTAssertEqual(reader(zone: "America/Los_Angeles").read(now: now).totalsByDay, ["2026-09-28": 2000])
        XCTAssertEqual(reader(zone: "Asia/Tokyo").read(now: now).totalsByDay, ["2026-09-29": 2000])
        XCTAssertEqual(reader(zone: "Asia/Tokyo").read(now: now).earliestEntryDay, "2026-09-29")
    }

    func testARowStillCarryingTheModelsDefaultTimeIsNotTheOldestDrink() throws {
        let placeholder = WaterEntry(amountML: 300, timestamp: Date.distantPast)
        container.mainContext.insert(placeholder)
        add(500, hoursAgo: 24 * 40)
        add(500, hoursAgo: 1)
        try container.mainContext.save()
        XCTAssertEqual(reader().read(now: now).earliestEntryDay, "2026-08-20",
                       "a year-1 day would have made the whole log covered and let any past day be lowered")
    }

    func testAnEmptyLogHasNoDaysAndNoOldestDrinkButStillItsGoal() {
        let summary = reader(goal: 2600).read(now: now)
        XCTAssertEqual(summary, DuoLogSummary(totalsByDay: [:], goalML: 2600, earliestEntryDay: nil))
    }

    // MARK: C24, a store that is not the shared one, and a read that fails

    func testTheAppsReaderReadsNoLogFromAStoreThatIsNotTheSharedOne() throws {
        // `SharedModelContainer.makeForApp` falls back to SwiftData's default location when the App
        // Group's store will not open: an empty or an old log, which read with the real goal would
        // be a week of missed days. This test's store is not the shared one either.
        add(500, hoursAgo: 1)
        try container.mainContext.save()
        let reader = SwiftDataDuoLogReader(container: container)
        XCTAssertFalse(reader.readsThePersonsLog)
        XCTAssertEqual(reader.read(now: now), .empty, "no log at all, as a failed read is: no goal, so nothing is published")
        let told = SwiftDataDuoLogReader(container: container, isTheSharedStore: false, goalML: { 2000 }, calendar: { Calendar.current })
        XCTAssertEqual(told.read(now: now).goalML, 0)
    }

    func testAReadThatFailsIsNoLogNotAnEmptyOne() {
        struct Unreadable: Error {}
        let failing = SwiftDataDuoLogReader(readsThePersonsLog: true, goalML: { 2000 }, calendar: { Calendar.current },
                                            fetch: { _, _ in throw Unreadable() })
        let summary = failing.read(now: now)
        XCTAssertEqual(summary, .empty)
        XCTAssertEqual(summary.goalML, 0, "an empty log with the goal would be sent as a week of missed days")
    }

    func testTheFetchIsGivenTheNineDayHorizonAndTheFirstPlausibleDrink() {
        var asked: [(Date, Date)] = []
        let reader = SwiftDataDuoLogReader(readsThePersonsLog: true, goalML: { 2000 }, calendar: { Calendar.current },
                                           fetch: { horizon, floor in asked.append((horizon, floor)); return .init(recent: [], oldest: nil) })
        XCTAssertEqual(reader.read(now: now), DuoLogSummary(totalsByDay: [:], goalML: 2000, earliestEntryDay: nil))
        XCTAssertEqual(asked.first?.0, now.addingTimeInterval(-9 * 86_400))
        XCTAssertEqual(asked.first?.1, Date(timeIntervalSince1970: 946_684_800))
    }
}

/// Defaults in memory, so no test here writes a preference file.
private final class ReaderMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Any] = [:]
    init() { super.init(suiteName: "DuoLogReaderTests.memory")! }
    override func object(forKey defaultName: String) -> Any? { lock.lock(); defer { lock.unlock() }; return items[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { lock.lock(); items[defaultName] = value; lock.unlock() }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { lock.lock(); items[defaultName] = nil; lock.unlock() }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? Bool) ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? Int) ?? 0 }
    override func dictionaryRepresentation() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return items }
    override func removePersistentDomain(forName domainName: String) { lock.lock(); items = [:]; lock.unlock() }
}
#endif
