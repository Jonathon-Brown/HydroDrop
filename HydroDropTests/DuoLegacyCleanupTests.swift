#if DUO_V2
import XCTest
@testable import HydroDrop

/// The iCloud Duo's cleanup runs its local half once per phone, so a phone whose iCloud half is still
/// owed (every Debug and simulator build, a phone signed out of iCloud) no longer cancels Duo v2's
/// background refresh and withdraws its `hydrodrop.duo.` announcements at every launch.
///
/// `LegacyDuoCleanup` works on the real defaults, the app's own and the App Group's, so every key it
/// reads or writes is saved before each test and put back after it.
final class DuoLegacyCleanupTests: XCTestCase {
    private static let ownKeys = ["legacyDuoCleanup.v1.done", "legacyDuoCleanup.v1.iCloudOwed", "legacyDuoCleanup.v1.localDone"]
    private static let signKeys = ["duo.subscriptionsSaved", "duo.states.v1", "duo.myDisplayName", "duo.ledger.v1",
                                   "duo.notificationsOff", "duoInviteMoment.dismissed"]

    private var saved: [(UserDefaults, String, Any?)] = []

    private var stores: [UserDefaults] { [AppGroup.defaults, UserDefaults.standard].compactMap { $0 } }

    override func setUp() {
        super.setUp()
        saved = []
        for store in stores {
            for key in Self.ownKeys + Self.signKeys { saved.append((store, key, store.object(forKey: key))) }
        }
        for store in stores {
            for key in Self.ownKeys + Self.signKeys { store.removeObject(forKey: key) }
        }
    }

    override func tearDown() {
        for (store, key, value) in saved {
            if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
        }
        saved = []
        super.tearDown()
    }

    private var own: UserDefaults { .standard }

    func testWithTheICloudHalfOwedTheLocalHalfRunsOnce() {
        own.set(true, forKey: "legacyDuoCleanup.v1.iCloudOwed")
        LegacyDuoCleanup.runOnce()
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.localDone"), "the first run sets the flag")
        XCTAssertFalse(own.bool(forKey: "legacyDuoCleanup.v1.done"), "a simulator build cannot reach Production CloudKit, so the iCloud half stays owed")
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.iCloudOwed"))
        // A legacy key back in place: if the local half ran again it would be removed.
        own.set(Data("[]".utf8), forKey: "duo.states.v1")
        LegacyDuoCleanup.runOnce()
        XCTAssertNotNil(own.object(forKey: "duo.states.v1"), "the local half did not run a second time")
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.iCloudOwed"), "the iCloud half is still owed, and still tried")
        XCTAssertFalse(own.bool(forKey: "legacyDuoCleanup.v1.done"))
    }

    func testAPhoneThatUsedTheICloudDuoIsClearedOnceAndOwesTheICloudHalf() {
        own.set(Data("[]".utf8), forKey: "duo.states.v1")
        own.set("Jo", forKey: "duo.myDisplayName")
        AppGroup.defaults?.set(true, forKey: "duo.subscriptionsSaved")
        LegacyDuoCleanup.runOnce()
        XCTAssertNil(own.object(forKey: "duo.states.v1"))
        XCTAssertNil(own.object(forKey: "duo.myDisplayName"))
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.iCloudOwed"), "a sign of the iCloud Duo was found")
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.localDone"))
        XCTAssertFalse(own.bool(forKey: "legacyDuoCleanup.v1.done"))
    }

    func testAPhoneThatNeverRanThoseBuildsEndsAtDoneAsBefore() {
        LegacyDuoCleanup.runOnce()
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.done"))
        XCTAssertTrue(own.bool(forKey: "legacyDuoCleanup.v1.localDone"))
        XCTAssertFalse(own.bool(forKey: "legacyDuoCleanup.v1.iCloudOwed"))
        // Done is done: nothing more runs, so a v2 key with a legacy-looking prefix is never touched.
        own.set(Data("[]".utf8), forKey: "duo.states.v1")
        LegacyDuoCleanup.runOnce()
        XCTAssertNotNil(own.object(forKey: "duo.states.v1"))
    }

    /// Duo v2's own keys are not the iCloud Duo's, so the cleanup never takes one.
    func testTheCleanupLeavesDuoV2sKeysAlone() throws {
        let group = try XCTUnwrap(AppGroup.defaults)
        let v2Keys = [DuoCache.statesKey, DuoCache.myDisplayNameKey, DuoCache.ledgerKey, DuoCache.notificationsOffKey, DuoCache.inviteMomentDismissedKey]
        var before: [String: Any?] = [:]
        for key in v2Keys { before[key] = group.object(forKey: key); group.set("kept", forKey: key) }
        defer { for key in v2Keys { if let value = before[key] ?? nil { group.set(value, forKey: key) } else { group.removeObject(forKey: key) } } }
        own.set(true, forKey: "legacyDuoCleanup.v1.iCloudOwed")
        LegacyDuoCleanup.runOnce()
        for key in v2Keys { XCTAssertEqual(group.string(forKey: key), "kept", key) }
    }
}
#endif
