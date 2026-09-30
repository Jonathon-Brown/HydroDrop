import XCTest
@testable import HydroDrop

/// 1.8.1 kept the samples of edited drinks in a queue on the device that made the edit, so
/// an edit made where Health sync was off was corrected only when sync was turned on there.
/// 1.9 keeps a record of what Health holds on each synced drink instead, naming the device
/// that wrote the sample, and that device replaces the sample once the drink's figures no
/// longer match. These cover the record, the figures it keeps, and the rule that reads it.
final class HealthWrittenRecordTests: XCTestCase {
    private let sampleID = "5D2B3DBE-0000-4000-8000-000000000001"
    private let otherSampleID = "5D2B3DBE-0000-4000-8000-000000000002"
    private let phone = "PHONE-0000-4000-8000-000000000001"
    private let otherDevice = "IPAD-0000-4000-8000-000000000002"
    /// A time with a fraction of a millisecond, as `Date()` gives the device that logs it.
    private let loggedAt = Date(timeIntervalSince1970: 1_790_000_000.123_456_7)

    private func figures(_ amountML: Int = 250, type: String = "water", at date: Date? = nil) -> HealthFigures {
        HealthFigures(milliseconds: HealthFigures.milliseconds(of: date ?? loggedAt), amountML: amountML, drinkType: type)
    }

    private func written(_ figures: HealthFigures? = nil, sample: String? = nil, owner: String?? = .none, marked: Bool = false) -> HealthWrittenRecord {
        HealthWrittenRecord(
            state: .written,
            sampleUUID: sample ?? sampleID,
            syncIdentifier: "drink.water",
            syncVersion: 1_790_000_000_001,
            figures: figures ?? self.figures(),
            owner: owner ?? phone,
            editedSince: marked
        )
    }

    // MARK: - The format

    /// The string is what CloudKit keeps, and every version from 1.9 on has to read it.
    func testTheFormatIsTheOneTheDesignFixed() {
        XCTAssertEqual(
            written(marked: true).encoded,
            "1|w|\(sampleID)|drink.water|1790000000001|1790000000123|250|water|\(phone)|e"
        )
        XCTAssertEqual(
            HealthWrittenRecord(state: .stale, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: nil, owner: nil).encoded,
            "1|s|\(sampleID)||0|||||"
        )
    }

    func testEveryStateRoundTrips() {
        let records = [
            written(),
            written(marked: true),
            written(owner: .some(nil)),
            HealthWrittenRecord(state: .nothing, sampleUUID: nil, syncIdentifier: "drink.caffeine", syncVersion: 7, figures: figures(0, type: "coffee"), owner: otherDevice),
            HealthWrittenRecord(state: .stale, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: nil, owner: nil),
            HealthWrittenRecord(state: .written, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: figures(), owner: phone, editedSince: true),
        ]
        for record in records {
            XCTAssertEqual(HealthWrittenRecord(encoded: record.encoded), record, record.encoded)
        }
    }

    /// A record from a later version, or one damaged in transit, is left alone rather than
    /// guessed at, and so is Health.
    func testAnythingThisVersionCannotReadInFullIsForeign() {
        let unreadable = [
            "2|w|\(sampleID)|drink.water|1|1790000000123|250|water||",
            "1|w|\(sampleID)|drink.water|1|1790000000123|250|water|",
            "1|w|\(sampleID)|drink.water|1|1790000000123|250|water|||",
            "1|x|\(sampleID)|drink.water|1|1790000000123|250|water||",
            "1|w||drink.water|1|1790000000123|250|water||",
            "1|n|\(sampleID)|drink.water|1|1790000000123|250|water||",
            "1|s|\(sampleID)||0|1790000000123|250|water||",
            "1|w|\(sampleID)|drink.water|1|||||",
            "1|w|\(sampleID)|drink.water|-1|1790000000123|250|water||",
            "1|w|\(sampleID)|drink.water|1|1790000000123|250|water||x",
            "1|w|\(sampleID)|drink.water|1|soon|250|water||",
            "1|w|\(sampleID)|drink.water|1|-9223372036854775808|250|water||",
            "1|w|\(sampleID)|drink.water|1|9223372036854775807|250|water||",
            "not a record",
        ]
        for field in unreadable {
            XCTAssertEqual(HealthRecordReading(field), .foreign, field)
        }
    }

    func testAMissingOrEmptyFieldIsNoRecord() {
        XCTAssertEqual(HealthRecordReading(nil), .none)
        XCTAssertEqual(HealthRecordReading(""), .none)
    }

    // MARK: - Figures

    /// What was poured, not what Health counts: a release that changes how much of a coffee
    /// hydrates must not make every coffee look edited.
    func testFiguresAreTheDrinksOwnInputs() {
        let coffee = WaterEntry(amountML: 200, timestamp: loggedAt, drinkType: .coffee)
        XCTAssertEqual(HealthFigures(of: coffee), HealthFigures(milliseconds: 1_790_000_000_123, amountML: 200, drinkType: "coffee"))
    }

    func testADrinkFromBeforeDrinkTypesReadsAsWater() {
        let old = WaterEntry(amountML: 300, timestamp: loggedAt)
        old.drinkTypeRawValue = nil
        XCTAssertEqual(HealthFigures(of: old).drinkType, "water")
    }

    /// The device that logged a drink keeps a fraction of a millisecond, and every other
    /// device has what CloudKit gave back, cut or rounded. Either way it must still match,
    /// or two devices would rewrite the same drink forever.
    func testATimeMatchesHoweverAnotherDeviceWasGivenIt() {
        let exact = figures(at: loggedAt)
        let cut = Date(timeIntervalSince1970: (loggedAt.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        let rounded = Date(timeIntervalSince1970: (loggedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        let toTheSecond = Date(timeIntervalSince1970: loggedAt.timeIntervalSince1970.rounded(.down))
        for date in [cut, rounded, toTheSecond] {
            XCTAssertTrue(exact.matches(figures(at: date)), "\(date.timeIntervalSince1970)")
            XCTAssertTrue(figures(at: date).matches(exact), "\(date.timeIntervalSince1970)")
        }
    }

    /// No drink's time, however odd, can trap the conversion or overflow a comparison.
    func testExtremeTimesAreHeldWithinWhatFoundationCanExpress() {
        let past = HealthFigures(milliseconds: HealthFigures.milliseconds(of: .distantPast), amountML: 1, drinkType: "water")
        let future = HealthFigures(milliseconds: HealthFigures.milliseconds(of: .distantFuture), amountML: 1, drinkType: "water")
        XCTAssertTrue(HealthFigures.plausibleMilliseconds.contains(past.milliseconds))
        XCTAssertTrue(HealthFigures.plausibleMilliseconds.contains(future.milliseconds))
        XCTAssertFalse(past.matches(future))
        XCTAssertEqual(HealthFigures.milliseconds(of: Date(timeIntervalSince1970: 1e300)), HealthFigures.plausibleMilliseconds.upperBound)
        let record = HealthWrittenRecord(state: .written, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: past, owner: nil)
        XCTAssertEqual(HealthWrittenRecord(encoded: record.encoded), record, "a drink at the distant past still has a readable record")
    }

    /// The time picker moves a drink by at least a minute.
    func testAMovedDrinkDoesNotMatch() {
        XCTAssertFalse(figures(at: loggedAt).matches(figures(at: loggedAt.addingTimeInterval(60))))
        XCTAssertFalse(figures(at: loggedAt).matches(figures(at: loggedAt.addingTimeInterval(-1.5))))
    }

    func testAnAmountOrTypeChangeDoesNotMatch() {
        XCTAssertFalse(figures(250).matches(figures(300)))
        XCTAssertFalse(figures(type: "water").matches(figures(type: "coffee")))
    }

    // MARK: - Versions

    /// Health keeps the higher of two versions, lets an equal one replace, and silently
    /// drops a lower one (seen in Step 0), so each write goes above the last.
    func testTheNextVersionIsAboveTheLastAndNoEarlierThanNow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(HealthWrittenRecord.nextVersion(after: 0, now: now), 1_790_000_000_000)
        XCTAssertEqual(HealthWrittenRecord.nextVersion(after: 1_790_000_000_000, now: now), 1_790_000_000_001)
        // Another device's clock ran ahead: still above it.
        XCTAssertEqual(HealthWrittenRecord.nextVersion(after: 1_800_000_000_000, now: now), 1_800_000_000_001)
        // A damaged record at the very top doesn't crash the pass.
        XCTAssertEqual(HealthWrittenRecord.nextVersion(after: .max, now: now), .max)
    }

    // MARK: - Void

    /// A 1.8.1 device replaced the sample without writing a record, so the record describes
    /// a sample Health no longer holds.
    func testARecordOfAnotherSampleIsVoid() {
        XCTAssertFalse(written().isVoid(currentUUID: sampleID))
        XCTAssertTrue(written().isVoid(currentUUID: otherSampleID))
        XCTAssertTrue(written().isVoid(currentUUID: nil))
    }

    func testANothingRecordIsVoidOnceTheDrinkHasASample() {
        let nothing = HealthWrittenRecord(state: .nothing, sampleUUID: nil, syncIdentifier: nil, syncVersion: 0, figures: figures(), owner: phone)
        XCTAssertFalse(nothing.isVoid(currentUUID: nil))
        XCTAssertTrue(nothing.isVoid(currentUUID: sampleID))
    }

    // MARK: - What needs doing, and who does it

    private func decide(
        _ record: HealthWrittenRecord?,
        current: HealthFigures? = nil,
        sample: String?? = .none,
        awaiting: Bool = false,
        on device: String? = nil
    ) -> (work: HealthPendingWork, wait: HealthPendingWork.Wait) {
        HealthPendingWork.decide(
            reading: HealthRecordReading(record?.encoded),
            currentUUID: sample ?? sampleID,
            current: current ?? figures(),
            isAwaitingWrite: awaiting,
            device: device ?? phone
        )
    }

    func testADrinkThatMatchesItsRecordNeedsNothing() {
        XCTAssertEqual(decide(written()).work, .none)
        XCTAssertEqual(decide(written(marked: true)).work, .none, "edited back to what Health has")
    }

    /// The fix itself: an edit made on any device, with sync on there or not, shows up as
    /// figures that no longer match the record, and the sample's owner acts on it at once.
    func testTheOwnerReplacesAnEditedDrinkAtOnce() {
        let marked = decide(written(marked: true), current: figures(400))
        XCTAssertEqual(marked.work, .replace(sampleUUID: sampleID))
        XCTAssertEqual(marked.wait, .none)
    }

    /// No 1.9 edit marked it, so a device still on 1.8.1 made it. With sync on there, that
    /// device replaces the sample itself within the day, voiding the record.
    func testTheOwnerWaitsADayOnAnUnmarkedChange() {
        let unmarked = decide(written(), current: figures(400))
        XCTAssertEqual(unmarked.work, .replace(sampleUUID: sampleID))
        XCTAssertEqual(unmarked.wait, .aDay)
    }

    /// Whether Health merges two devices' samples of one drink across iCloud was never seen
    /// on two devices, so only the owner acts straight away. Another device takes over
    /// after a week, in case the owner is gone or has sync off.
    func testAnotherDeviceWaitsAWeek() {
        for record in [written(marked: true), written(), written(owner: .some(nil), marked: true)] {
            let decision = decide(record, current: figures(400), on: otherDevice)
            XCTAssertEqual(decision.work, .replace(sampleUUID: sampleID))
            XCTAssertEqual(decision.wait, .aWeek, record.encoded)
        }
    }

    func testTheWaitsAreADayAndAWeek() {
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(HealthPendingWork.isDue(.none, firstSeen: seen, now: seen))
        XCTAssertFalse(HealthPendingWork.isDue(.aDay, firstSeen: seen, now: seen.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(HealthPendingWork.isDue(.aDay, firstSeen: seen, now: seen.addingTimeInterval(24 * 3600)))
        XCTAssertFalse(HealthPendingWork.isDue(.aWeek, firstSeen: seen, now: seen.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertTrue(HealthPendingWork.isDue(.aWeek, firstSeen: seen, now: seen.addingTimeInterval(7 * 24 * 3600)))
    }

    /// A device whose identifier isn't known yet owns nothing, so it waits like any other.
    func testADeviceWithNoIdentifierOwnsNothing() {
        let decision = HealthPendingWork.decide(
            reading: HealthRecordReading(written(owner: .some(nil), marked: true).encoded),
            currentUUID: sampleID,
            current: figures(400),
            isAwaitingWrite: false,
            device: nil
        )
        XCTAssertEqual(decision.wait, .aWeek)
    }

    /// 1.8.1's queue moved onto the drink: at once by the device that moved it with sync on,
    /// after a week by anyone otherwise.
    func testAStaleSampleIsReplacedByItsClaimantAtOnceAndByOthersAfterAWeek() {
        let claimed = HealthWrittenRecord(state: .stale, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: nil, owner: phone)
        XCTAssertEqual(decide(claimed).work, .replace(sampleUUID: sampleID))
        XCTAssertEqual(decide(claimed).wait, .none)
        XCTAssertEqual(decide(claimed, on: otherDevice).wait, .aWeek)
        let unclaimed = HealthWrittenRecord(state: .stale, sampleUUID: sampleID, syncIdentifier: nil, syncVersion: 0, figures: nil, owner: nil)
        XCTAssertEqual(decide(unclaimed).wait, .aWeek)
    }

    /// Cleared because the drink stopped counting, then edited back: written again, even
    /// though the ordinary pass would skip a drink from before sync was turned on.
    func testADrinkHealthHoldsNothingForIsWrittenWhenItChanges() {
        let nothing = HealthWrittenRecord(state: .nothing, sampleUUID: nil, syncIdentifier: "drink.water", syncVersion: 5, figures: figures(type: "beer"), owner: phone, editedSince: true)
        XCTAssertEqual(decide(nothing, current: figures(type: "beer"), sample: .some(nil)).work, .none)
        let changed = decide(nothing, current: figures(type: "water"), sample: .some(nil))
        XCTAssertEqual(changed.work, .writeIfCounts)
        XCTAssertEqual(changed.wait, .none)
    }

    /// Something that writes no records changed the sample since. Nothing is known, unless
    /// a 1.9 edit came first, which makes whatever the drink points at out of date. Nobody
    /// owns that sample, so it waits a week.
    func testAVoidRecordIsLeftAloneUnlessAnEditMarkedIt() {
        XCTAssertEqual(decide(written(), current: figures(400), sample: .some(otherSampleID)).work, .none)
        let marked = decide(written(marked: true), current: figures(400), sample: .some(otherSampleID))
        XCTAssertEqual(marked.work, .replace(sampleUUID: otherSampleID))
        XCTAssertEqual(marked.wait, .aWeek)
        XCTAssertEqual(decide(written(marked: true), sample: .some(nil)).work, .none, "cleared since: nothing to replace")
    }

    /// This device took the sample out of its own Health and was stopped before writing it
    /// back. The mark wins over any record, and over who owns it.
    func testASampleThisDeviceMarkedIsAlwaysWrittenBack() {
        for record in [nil, written(), written(marked: true), written(owner: .some(otherDevice))] {
            let decision = decide(record, awaiting: true)
            XCTAssertEqual(decision.work, .replace(sampleUUID: sampleID))
            XCTAssertEqual(decision.wait, .none)
        }
    }

    func testNoRecordOrAForeignOneNeedsNothing() {
        XCTAssertEqual(decide(nil, current: figures(999)).work, .none)
        let foreign = HealthPendingWork.decide(
            reading: HealthRecordReading("2|w|future"),
            currentUUID: sampleID,
            current: figures(999),
            isAwaitingWrite: false,
            device: phone
        )
        XCTAssertEqual(foreign.work, .none)
    }

    /// The loop the review found: a record written from one device's time, read on another
    /// that only has CloudKit's copy, must not look edited.
    func testAnotherDevicesCopyOfTheTimeNeverLooksEdited() {
        let theirs = Date(timeIntervalSince1970: (loggedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        XCTAssertEqual(decide(written(figures(at: loggedAt)), current: figures(at: theirs)).work, .none)
        XCTAssertEqual(decide(written(figures(at: theirs)), current: figures(at: loggedAt)).work, .none)
    }
}

/// What a device remembers about pending replacements in its own defaults.
final class HealthPendingNotesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "HealthPendingNotesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheFirstSightingIsKept() {
        let notes = HealthPendingNotes(defaults: defaults)
        XCTAssertEqual(notes.firstSeen("a", now: now), now)
        XCTAssertEqual(notes.firstSeen("a", now: now.addingTimeInterval(3600)), now)
    }

    /// Health sync may only have been late in bringing the sample, and looking again is
    /// safe, so a let-go stands for a week.
    func testALetGoLastsAWeek() {
        let notes = HealthPendingNotes(defaults: defaults)
        notes.noteLetGo("a", now: now)
        XCTAssertTrue(notes.hasLetGo("a", now: now.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertFalse(notes.hasLetGo("a", now: now.addingTimeInterval(7 * 24 * 3600)))
        XCTAssertFalse(notes.hasLetGo("b", now: now))
    }

    /// A changed record, or a new sample, is a different key, so it is looked at afresh.
    func testTheKeyChangesWithTheRecordAndTheSample() {
        let key = HealthPendingNotes.key(kind: .water, currentUUID: "s", field: "1|w|s|||||||")
        XCTAssertNotEqual(key, HealthPendingNotes.key(kind: .water, currentUUID: "s", field: "1|w|s|||||||e"))
        XCTAssertNotEqual(key, HealthPendingNotes.key(kind: .water, currentUUID: "t", field: "1|w|s|||||||"))
        XCTAssertNotEqual(key, HealthPendingNotes.key(kind: .caffeine, currentUUID: "s", field: "1|w|s|||||||"))
    }

    func testPruningForgetsWhatIsNoLongerPending() {
        let notes = HealthPendingNotes(defaults: defaults)
        _ = notes.firstSeen("kept", now: now)
        _ = notes.firstSeen("gone", now: now)
        notes.noteLetGo("gone", now: now)
        notes.prune(keeping: ["kept"])
        XCTAssertEqual(notes.firstSeen("kept", now: now.addingTimeInterval(60)), now)
        XCTAssertEqual(notes.firstSeen("gone", now: now.addingTimeInterval(60)), now.addingTimeInterval(60))
        XCTAssertFalse(notes.hasLetGo("gone", now: now))
    }
}
