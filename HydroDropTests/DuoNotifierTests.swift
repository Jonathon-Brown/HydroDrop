#if DUO_V2
import UserNotifications
import XCTest
@testable import HydroDrop

/// A notification centre that keeps what it is given, refuses what it is told to, and holds
/// delivered notifications a test puts there (a real `UNNotification` cannot be made in a test).
@MainActor
private final class FCenter: DuoNotificationCentering {
    private(set) var added: [UNNotificationRequest] = []
    var pending: [DuoNotificationRecord] = []
    var delivered: [DuoNotificationRecord] = []
    var refuse: Set<String> = []
    var onAdd: ((UNNotificationRequest) -> Void)?
    /// Holds the next `pendingRecords()` open until the test lets it go, so a removal can be caught
    /// halfway.
    var holdNextPendingRead = false
    private(set) var heldRead: CheckedContinuation<Void, Never>?
    func releaseHeldRead() { heldRead?.resume(); heldRead = nil }
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    func add(_ request: UNNotificationRequest) async throws {
        if refuse.contains(request.identifier) { throw NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue) }
        added.append(request)
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(DuoNotificationRecord(identifier: request.identifier, threadIdentifier: request.content.threadIdentifier,
                                             userInfo: request.content.userInfo))
        onAdd?(request)
    }
    func pendingRecords() async -> [DuoNotificationRecord] {
        if holdNextPendingRead {
            holdNextPendingRead = false
            await withCheckedContinuation { heldRead = $0 }
        }
        return pending
    }
    func deliveredRecords() async -> [DuoNotificationRecord] { delivered }
    func removePending(withIdentifiers identifiers: [String]) {
        removedPending += identifiers
        pending.removeAll { identifiers.contains($0.identifier) }
    }
    func removeDelivered(withIdentifiers identifiers: [String]) {
        removedDelivered += identifiers
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}

/// Duo's local notifications (final design §9.2, §9.4, §9.5, §12.2, §12.3, vector X14).
@MainActor
final class DuoNotifierTests: XCTestCase {
    private let duoID = DuoFixtures.duoID
    private let otherDuo = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000099")!
    private let nudgeID = "nudge-8F2A0000-0000-4000-8000-000000000002"

    private func rig(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> (DuoTestKit, FCenter, DuoNotifier) {
        let kit = DuoTestKit(now: now)
        let center = FCenter()
        let notifier = DuoNotifier(dependencies: kit.dependencies, center: center)
        kit.dependencies.announcer = notifier
        return (kit, center, notifier)
    }

    private func nudge(_ id: String? = nil, duo: UUID? = nil, preset: String = "sipWithMe", name: String = "Sam") -> DuoAnnouncement {
        DuoAnnouncement(key: id ?? nudgeID, duoID: duo ?? duoID, partnerName: name, kind: .nudge(presetID: preset))
    }

    private func goal(day: String = "2026-09-21", mine: Bool = false, duo: UUID? = nil) -> DuoAnnouncement {
        let id = duo ?? duoID
        return DuoAnnouncement(key: DuoLedger.goalKey(duoID: id, day: day), duoID: id, partnerName: "Sam", kind: .partnerMetGoal(iHaveToo: mine))
    }

    private func remote(_ fields: [String: Any], thread: String? = nil, identifier: String = UUID().uuidString) -> DuoNotificationRecord {
        var info: [AnyHashable: Any] = ["aps": ["alert": ["loc-key": "x"], "thread-id": thread ?? DuoNotifier.threadIdentifier(for: duoID)]]
        for (key, value) in fields { info[key] = value }
        return DuoNotificationRecord(identifier: identifier, threadIdentifier: thread ?? DuoNotifier.threadIdentifier(for: duoID), userInfo: info)
    }

    // MARK: - What is posted

    func testANudgeIsPostedOnTheDuosThreadWithTheRemindersButtons() async throws {
        let (kit, center, notifier) = rig()
        let refused = await notifier.deliver([nudge()], now: kit.clock.now)
        XCTAssertEqual(refused, [])
        let request = try XCTUnwrap(center.added.first)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(request.identifier, "hydrodrop.duo.\(nudgeID)", "named after its ledger key, so the same news twice is one request")
        XCTAssertEqual(request.content.title, "Sam nudged you")
        XCTAssertEqual(request.content.body, "Sip with me?")
        XCTAssertNotNil(request.content.sound, "with the default sound, as a push has")
        XCTAssertEqual(request.content.threadIdentifier, "hydrodrop.duo.6d2a0000-0000-4000-8000-000000000001",
                       "the server's thread-id, lowercase, so remote and local are found together")
        XCTAssertEqual(request.content.categoryIdentifier, ReminderManager.reminderCategoryIdentifier)
        XCTAssertEqual(request.content.categoryIdentifier, "HYDRO_REMINDER")
    }

    func testAGoalMetCarriesNoButtons() async throws {
        let (kit, center, notifier) = rig()
        _ = await notifier.deliver([goal(mine: true)], now: kit.clock.now)
        let request = try XCTUnwrap(center.added.first)
        XCTAssertEqual(request.identifier, "hydrodrop.duo.met|6d2a0000-0000-4000-8000-000000000001|2026-09-21")
        XCTAssertEqual(request.content.title, "Sam hit their goal")
        XCTAssertEqual(request.content.body, "You both made it today.")
        XCTAssertEqual(request.content.categoryIdentifier, "", "goal_met carries no category (§9.2)")
        XCTAssertEqual(request.content.threadIdentifier, DuoNotifier.threadIdentifier(for: duoID))
    }

    /// A local one is read exactly like a remote one, so a tap on either goes through one parser.
    func testALocalNotificationsUserInfoIsShapedLikeARemotePayload() async throws {
        let (kit, center, notifier) = rig()
        _ = await notifier.deliver([nudge(), goal(day: "2026-09-20")], now: kit.clock.now)
        let nudgeInfo = try XCTUnwrap(center.added.first?.content.userInfo)
        XCTAssertEqual(nudgeInfo["v"] as? Int, 1)
        XCTAssertEqual(nudgeInfo["t"] as? String, "nudge")
        XCTAssertEqual(nudgeInfo["duo"] as? String, "6d2a0000-0000-4000-8000-000000000001")
        XCTAssertEqual(nudgeInfo["id"] as? String, nudgeID)
        XCTAssertNil(nudgeInfo["seq"], "a local announcement has no seq, so a tap always fetches")
        XCTAssertNil(nudgeInfo["from_name"], "and no name: the title already has it")
        let parsedNudge = try XCTUnwrap(DuoPushPayload.parse(userInfo: nudgeInfo))
        XCTAssertEqual(parsedNudge, DuoPushPayload(duoID: duoID, seq: nil, kind: .nudge(id: nudgeID, preset: nil)))
        XCTAssertEqual(parsedNudge.ledgerKeys, [nudgeID])
        let goalInfo = try XCTUnwrap(center.added.last?.content.userInfo)
        let parsedGoal = try XCTUnwrap(DuoPushPayload.parse(userInfo: goalInfo))
        XCTAssertEqual(parsedGoal.kind, .goalMet(day: "2026-09-20", iHaveToo: false))
        XCTAssertEqual(parsedGoal.ledgerKeys, [DuoLedger.goalKey(duoID: duoID, day: "2026-09-20")])
        XCTAssertEqual(Set(goalInfo.keys.compactMap { $0 as? String }), ["v", "t", "duo", "day"])
    }

    func testAnUnknownPresetIsTheFallbackLine() async throws {
        let (kit, center, notifier) = rig()
        _ = await notifier.deliver([nudge(preset: "fromTheFuture")], now: kit.clock.now)
        XCTAssertEqual(center.added.first?.content.body, DuoNudgePreset.fallbackText)
    }

    // MARK: - Quiet hours

    func testInsideTheWakingWindowItIsShownAtOnce() async throws {
        let (kit, center, notifier) = rig()
        kit.dependencies.wakingWindow = { (480, 1320) } // 14:13 UTC is inside
        _ = await notifier.deliver([nudge()], now: kit.clock.now)
        XCTAssertNil(try XCTUnwrap(center.added.first).trigger)
    }

    func testOutsideTheWakingWindowItIsHeldUntilItOpens() async throws {
        let (kit, center, notifier) = rig()
        kit.dependencies.wakingWindow = { (1380, 420) } // awake 23:00 to 07:00; 14:13:20 is outside
        _ = await notifier.deliver([nudge(), goal()], now: kit.clock.now)
        for request in center.added {
            let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger, "\(request.identifier) is held")
            XCTAssertEqual(trigger.timeInterval, 31_600, "held until 23:00 UTC, 8 h 46 min 40 s later")
            XCTAssertFalse(trigger.repeats)
        }
        let opening = try XCTUnwrap(DuoQuietHours.holdUntil(kit.clock.now, startMinutes: 1380, endMinutes: 420, calendar: kit.clock.calendar))
        XCTAssertEqual(opening.timeIntervalSince(kit.clock.now), 31_600)
    }

    func testAHoldAFractionOfASecondLongIsHeldForASecond() async throws {
        // Half a second before 08:00 UTC.
        let (kit, center, notifier) = rig(now: Date(timeIntervalSince1970: 1_789_977_600 - 0.5))
        kit.dependencies.wakingWindow = { (480, 1320) }
        _ = await notifier.deliver([nudge()], now: kit.clock.now)
        let trigger = try XCTUnwrap(center.added.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 1)
    }

    // MARK: - Refused, turned off, wiped

    func testTheKeysIOSRefusedAreHandedBack() async {
        let (kit, center, notifier) = rig()
        center.refuse = ["hydrodrop.duo.\(nudgeID)"]
        let goalAnnouncement = goal()
        let refused = await notifier.deliver([nudge(), goalAnnouncement], now: kit.clock.now)
        XCTAssertEqual(refused, [nudgeID])
        XCTAssertEqual(center.added.map(\.identifier), ["hydrodrop.duo.\(goalAnnouncement.key)"])
    }

    func testWithDuosNotificationsOffNothingIsPostedAndNothingIsRefused() async {
        let (kit, center, notifier) = rig()
        kit.store.notificationsEnabled = false
        let refused = await notifier.deliver([nudge(), goal()], now: kit.clock.now)
        XCTAssertEqual(refused, [], "turned off is an answer, not a refusal")
        XCTAssertTrue(center.added.isEmpty)
    }

    /// A wipe while announcements were going in took the duo and its partner's name: nothing more
    /// goes on screen, and the one that went in as the wipe ran is taken out again.
    func testAWipeWhileAnnouncingStopsAndTakesBackWhatWentIn() async {
        let (kit, center, notifier) = rig()
        center.onAdd = { _ in kit.store.resetLocalState() }
        _ = await notifier.deliver([nudge(), goal()], now: kit.clock.now)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.removedPending, ["hydrodrop.duo.\(nudgeID)"])
        XCTAssertTrue(center.pending.isEmpty)
    }

    // MARK: - X14: a pushed one already on screen

    func testANudgeAlreadyDeliveredByPushIsFoundByItsLedgerKey() async {
        let (_, center, notifier) = rig()
        center.delivered = [
            remote(["v": 1, "t": "nudge", "duo": "6d2a0000-0000-4000-8000-000000000001", "seq": NSNumber(value: 419), "id": nudgeID]),
            remote(["v": 1, "t": "goal_met", "duo": "6d2a0000-0000-4000-8000-000000000001", "seq": 420, "day": "2026-09-20"]),
            DuoNotificationRecord(identifier: "hydrodrop.reminder.1", threadIdentifier: "", userInfo: [:]),
        ]
        let found = await notifier.hasDeliveredRemote(forKey: nudgeID)
        XCTAssertTrue(found)
        let goalFound = await notifier.hasDeliveredRemote(forKey: DuoLedger.goalKey(duoID: duoID, day: "2026-09-20"))
        XCTAssertTrue(goalFound)
        let otherDay = await notifier.hasDeliveredRemote(forKey: DuoLedger.goalKey(duoID: duoID, day: "2026-09-21"))
        XCTAssertFalse(otherDay)
        let otherNudge = await notifier.hasDeliveredRemote(forKey: "nudge-8F2A0000-0000-4000-8000-000000000003")
        XCTAssertFalse(otherNudge)
        // Uppercase in the payload is the same duo, and the key is the lowercase one (D25).
        center.delivered = [remote(["v": 1, "t": "goal_met", "duo": "6D2A0000-0000-4000-8000-000000000001", "day": "2026-09-20"])]
        let uppercase = await notifier.hasDeliveredRemote(forKey: "met|6d2a0000-0000-4000-8000-000000000001|2026-09-20")
        XCTAssertTrue(uppercase)
    }

    func testNothingDeliveredIsNothingFound() async {
        let (_, center, notifier) = rig()
        center.delivered = [DuoNotificationRecord(identifier: "hydrodrop.snooze", threadIdentifier: "", userInfo: ["id": nudgeID])]
        let found = await notifier.hasDeliveredRemote(forKey: nudgeID)
        XCTAssertFalse(found, "a notification that is not a Duo payload never matches")
    }

    // MARK: - Removal

    func testClearingADuoRemovesItsThreadOnlyWaitingAndOnScreen() async {
        let (_, center, notifier) = rig()
        let mine = DuoNotifier.threadIdentifier(for: duoID)
        let theirs = DuoNotifier.threadIdentifier(for: otherDuo)
        let iCloudSpelling = "hydrodrop.duo.6D2A0000-0000-4000-8000-000000000001"
        center.pending = [
            DuoNotificationRecord(identifier: "hydrodrop.duo.a", threadIdentifier: mine, userInfo: [:]),
            DuoNotificationRecord(identifier: "hydrodrop.duo.b", threadIdentifier: theirs, userInfo: [:]),
            DuoNotificationRecord(identifier: "hydrodrop.reminder.0", threadIdentifier: "", userInfo: [:]),
        ]
        center.delivered = [
            DuoNotificationRecord(identifier: "remote-1", threadIdentifier: mine, userInfo: [:]),
            DuoNotificationRecord(identifier: "legacy-1", threadIdentifier: iCloudSpelling, userInfo: [:]),
            DuoNotificationRecord(identifier: "remote-2", threadIdentifier: theirs, userInfo: [:]),
        ]
        notifier.removeDelivered(for: duoID)
        await notifier.waitForRemovals()
        XCTAssertEqual(center.pending.map(\.identifier), ["hydrodrop.duo.b", "hydrodrop.reminder.0"])
        XCTAssertEqual(center.delivered.map(\.identifier), ["remote-2"])
    }

    func testDeletingEverythingRemovesEveryDuoNotificationAndNothingElse() async {
        let (_, center, notifier) = rig()
        center.pending = [
            DuoNotificationRecord(identifier: "hydrodrop.duo.x", threadIdentifier: "", userInfo: [:]),
            DuoNotificationRecord(identifier: "hydrodrop.reminder.0", threadIdentifier: "", userInfo: [:]),
            DuoNotificationRecord(identifier: "hydrodrop.snooze", threadIdentifier: "", userInfo: [:]),
            DuoNotificationRecord(identifier: "recap", threadIdentifier: "weekly", userInfo: [:]),
        ]
        center.delivered = [
            DuoNotificationRecord(identifier: "remote-1", threadIdentifier: DuoNotifier.threadIdentifier(for: duoID), userInfo: [:]),
            DuoNotificationRecord(identifier: "remote-2", threadIdentifier: DuoNotifier.threadIdentifier(for: otherDuo), userInfo: [:]),
            DuoNotificationRecord(identifier: "reminder-shown", threadIdentifier: "", userInfo: [:]),
        ]
        notifier.removeAllDelivered()
        await notifier.waitForRemovals()
        XCTAssertEqual(center.pending.map(\.identifier), ["hydrodrop.reminder.0", "hydrodrop.snooze", "recap"])
        XCTAssertEqual(center.delivered.map(\.identifier), ["reminder-shown"])
    }

    /// A removal started before an announcement must not take the announcement too.
    func testAnAnnouncementMadeAfterARemovalStartedSurvivesIt() async {
        let (kit, center, notifier) = rig()
        notifier.removeDelivered(for: duoID)
        _ = await notifier.deliver([nudge()], now: kit.clock.now)
        await notifier.waitForRemovals()
        XCTAssertEqual(center.pending.map(\.identifier), ["hydrodrop.duo.\(nudgeID)"])
    }

    // MARK: - Review findings

    /// What iOS has on screen for a push the server built (its `apnsBody`, run at contract-v1):
    /// the whole body as `userInfo`, the thread its `thread-id`.
    private func serverPush(_ t: String, _ fields: [String: Any], locKey: String) -> DuoNotificationRecord {
        var body: [AnyHashable: Any] = ["aps": ["alert": ["loc-key": locKey], "interruption-level": "active", "sound": "default",
                                                "thread-id": "hydrodrop.duo.6d2a0000-0000-4000-8000-000000000001"],
                                        "duo": "6d2a0000-0000-4000-8000-000000000001", "seq": 7, "t": t, "v": 1]
        for (key, value) in fields { body[key] = value }
        return DuoNotificationRecord(identifier: UUID().uuidString, threadIdentifier: "hydrodrop.duo.6d2a0000-0000-4000-8000-000000000001", userInfo: body)
    }

    /// D75 (review F5): ending a duo on this phone takes its thread off the screen but leaves the
    /// pushed "Your duo has ended", the one notice D36 promises even with Duo's notifications off.
    /// Delete my Duo data still takes everything.
    func testClearingADuosThreadKeepsItsEndedNotice() async {
        let (_, center, notifier) = rig()
        let ended = serverPush("ended", [:], locKey: "duo.ended.partner")
        let pushedNudge = serverPush("nudge", ["id": nudgeID], locKey: "duo.nudge.cheers")
        let pushedGoal = serverPush("goal_met", ["day": "2026-10-08"], locKey: "duo.goal_met.body.both")
        let joined = serverPush("joined", [:], locKey: "duo.joined.body")
        center.delivered = [ended, pushedNudge, pushedGoal, joined]
        center.pending = [DuoNotificationRecord(identifier: "hydrodrop.duo.\(nudgeID)", threadIdentifier: DuoNotifier.threadIdentifier(for: duoID),
                                                userInfo: DuoNotifier.userInfo(for: nudge()))]
        notifier.removeDelivered(for: duoID)
        await notifier.waitForRemovals()
        XCTAssertEqual(center.delivered.map(\.identifier), [ended.identifier], "only the ended notice stays on screen")
        XCTAssertTrue(center.pending.isEmpty, "and nothing held for the duo is left to fire")
        notifier.removeAllDelivered()
        await notifier.waitForRemovals()
        XCTAssertTrue(center.delivered.isEmpty, "Delete my Duo data takes the ended notice too")
    }

    /// Review F4: a wipe that lands while a delivery waits for an earlier removal took the duo and its
    /// partner's name, so the delivery posts nothing.
    func testAWipeWhileADeliveryWaitsForARemovalPostsNothing() async {
        let (kit, center, notifier) = rig()
        kit.store.upsert(DuoFixtures.duo())
        center.holdNextPendingRead = true
        notifier.removeDelivered(for: otherDuo)
        let delivery = Task { await notifier.deliver([nudge()], now: kit.clock.now) }
        for _ in 0..<20 where center.heldRead == nil { await Task.yield() }
        XCTAssertNotNil(center.heldRead, "the removal is halfway")
        kit.store.resetLocalState()
        notifier.removeAllDelivered()
        center.releaseHeldRead()
        let refused = await delivery.value
        await notifier.waitForRemovals()
        XCTAssertEqual(refused, [])
        XCTAssertTrue(center.added.isEmpty, "nothing handed over before the wipe went in after it")
    }

    /// Review F11: turning Duo's notifications off withdraws what is held for the morning and leaves
    /// what is already on screen (the store calls `removeAllPending()` when the toggle goes off).
    func testTurningTheToggleOffWithdrawsWhatIsHeldAndLeavesWhatIsShown() async throws {
        let (kit, center, notifier) = rig(now: ISO8601DateFormatter().date(from: "2026-10-08T23:00:00Z")!)
        kit.dependencies.wakingWindow = { (480, 1320) }
        kit.store.upsert(DuoFixtures.duo())
        _ = await notifier.deliver([nudge()], now: kit.clock.now)
        let held = try XCTUnwrap(center.added.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(held.timeInterval, 9 * 3600, "held to 08:00")
        center.pending.append(DuoNotificationRecord(identifier: "hydrodrop.reminder.0", threadIdentifier: "", userInfo: [:]))
        center.delivered = [serverPush("goal_met", ["day": "2026-10-08"], locKey: "duo.goal_met.body.both")]
        kit.store.notificationsEnabled = false
        await notifier.waitForRemovals()
        XCTAssertEqual(center.pending.map(\.identifier), ["hydrodrop.reminder.0"], "the held nudge is withdrawn, the reminder kept")
        XCTAssertEqual(center.delivered.count, 1, "what is on screen stays")
    }

    /// Review F12: a nudge held so long that it would be shown more than 12 hours after it was sent is
    /// not shown, as the server drops a push it held that long; exactly 12 hours is still shown.
    func testANudgeHeldPastTwelveHoursFromItsSendingIsNotShown() async throws {
        let iso = ISO8601DateFormatter()
        // 22:00 UTC, the window 10:00 to 20:00: the window opens 12 hours later.
        let now = iso.date(from: "2026-10-08T22:00:00Z")!
        let (kit, center, notifier) = rig(now: now)
        kit.dependencies.wakingWindow = { (600, 1200) }
        let onTime = "nudge-8F2A0000-0000-4000-8000-0000000000a1"
        let stale = "nudge-8F2A0000-0000-4000-8000-0000000000a2"
        var duo = DuoFixtures.duo(now: now)
        duo.nudges = [DuoNudge(id: onTime, fromRole: .partner, presetID: "cheers", createdAt: now),
                      DuoNudge(id: stale, fromRole: .partner, presetID: "cheers", createdAt: now.addingTimeInterval(-1))]
        kit.store.upsert(duo)
        let refused = await notifier.deliver([nudge(onTime), nudge(stale)], now: now)
        XCTAssertEqual(refused, [], "too old to show is an answer, not a refusal to try again")
        XCTAssertEqual(center.added.map(\.identifier), ["hydrodrop.duo.\(onTime)"])
        let trigger = try XCTUnwrap(center.added.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 12 * 3600)
        // A goal is not a nudge: it is held however long the night is.
        let goalAnnouncement = goal(day: "2026-10-08")
        _ = await notifier.deliver([goalAnnouncement], now: now)
        XCTAssertEqual(center.added.last?.identifier, "hydrodrop.duo.\(goalAnnouncement.key)")
    }

    /// Review F20: a goal is held however long the night is, here 13 hours (21:00, the window from
    /// 10:00), off the 12-hour boundary the nudge's drop sits on.
    func testAGoalHeldThirteenHoursIsStillPosted() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-08T21:00:00Z")!
        let (kit, center, notifier) = rig(now: now)
        kit.dependencies.wakingWindow = { (600, 1200) }
        let goalAnnouncement = goal(day: "2026-10-08")
        let refused = await notifier.deliver([goalAnnouncement], now: now)
        XCTAssertEqual(refused, [])
        XCTAssertEqual(center.added.map(\.identifier), ["hydrodrop.duo.\(goalAnnouncement.key)"])
        let trigger = try XCTUnwrap(center.added.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 13 * 3600)
    }

    /// Review F17: Duo's toggle turned off while a delivery waits for an earlier removal. The toggle's
    /// withdrawal runs, and the delivery, which read the toggle at its start, used to add the nudge
    /// after it, held to 08:00.
    func testTurningTheToggleOffWhileADeliveryWaitsLeavesNothingHeld() async throws {
        let (kit, center, notifier) = rig(now: ISO8601DateFormatter().date(from: "2026-10-08T23:00:00Z")!)
        kit.dependencies.wakingWindow = { (480, 1320) }
        var duo = DuoFixtures.duo(now: kit.clock.now)
        duo.nudges = [DuoNudge(id: nudgeID, fromRole: .partner, presetID: "cheers", createdAt: kit.clock.now.addingTimeInterval(-600))]
        kit.store.upsert(duo)
        center.holdNextPendingRead = true
        notifier.removeDelivered(for: otherDuo)
        let delivery = Task { await notifier.deliver([nudge()], now: kit.clock.now) }
        for _ in 0..<20 where center.heldRead == nil { await Task.yield() }
        XCTAssertNotNil(center.heldRead, "the earlier removal is halfway")
        kit.store.notificationsEnabled = false
        center.releaseHeldRead()
        let refused = await delivery.value
        await notifier.waitForRemovals()
        XCTAssertEqual(refused, [], "turned off is an answer")
        XCTAssertTrue(center.pending.isEmpty, "nothing is left to come up at 08:00")
        XCTAssertTrue(center.added.isEmpty)
    }

    /// The toggle turned off between two adds: the rest are not added, and the one that went in as it
    /// changed is taken back.
    func testTurningTheToggleOffBetweenAddsStopsTheRest() async throws {
        let (kit, center, notifier) = rig(now: ISO8601DateFormatter().date(from: "2026-10-08T23:00:00Z")!)
        kit.dependencies.wakingWindow = { (480, 1320) }
        kit.store.upsert(DuoFixtures.duo())
        center.onAdd = { _ in kit.store.notificationsEnabled = false }
        let later = goal(day: "2026-10-08")
        _ = await notifier.deliver([nudge(), later], now: kit.clock.now)
        await notifier.waitForRemovals()
        XCTAssertEqual(center.added.map(\.identifier), ["hydrodrop.duo.\(nudgeID)"], "nothing after the change is added")
        XCTAssertTrue(center.pending.isEmpty, "and the one added as it changed is taken back")
    }

    /// Review F22: Clear takes the whole thread off the screen, the pushed "Your duo has ended" too,
    /// while a duo the app ends by itself keeps it (D75, `removeDelivered(for:)`).
    func testClearTakesTheEndedNoticeTooAndAnEndingByTheAppKeepsIt() async {
        let (kit, center, notifier) = rig()
        let ended = serverPush("ended", [:], locKey: "duo.ended.partner")
        let pushedNudge = serverPush("nudge", ["id": nudgeID], locKey: "duo.nudge.cheers")
        let theirs = DuoNotificationRecord(identifier: "remote-other", threadIdentifier: DuoNotifier.threadIdentifier(for: otherDuo), userInfo: [:])
        let iCloudSpelling = DuoNotificationRecord(identifier: "legacy", threadIdentifier: "hydrodrop.duo.6D2A0000-0000-4000-8000-000000000001", userInfo: [:])
        center.delivered = [ended, pushedNudge, theirs, iCloudSpelling]
        notifier.removeDelivered(for: duoID)
        await notifier.waitForRemovals()
        XCTAssertEqual(center.delivered.map(\.identifier), [ended.identifier, theirs.identifier], "the app's own ending keeps the notice")
        center.pending = [DuoNotificationRecord(identifier: "hydrodrop.duo.held", threadIdentifier: DuoNotifier.threadIdentifier(for: duoID), userInfo: [:])]
        kit.store.removeNotifications(for: DuoFixtures.duo())
        await notifier.waitForRemovals()
        XCTAssertEqual(center.delivered.map(\.identifier), [theirs.identifier], "Clear takes the ended notice, and only this duo's thread")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAHoldIsMeasuredFromTheNudgesSendingTime() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        let sent = iso.date(from: "2026-10-08T20:01:00Z")!
        // Shown at once inside the window: never too late here (the sync engine's plan judged its age).
        XCTAssertFalse(DuoNotifier.holdOutlivesTheNudge(sentAt: sent.addingTimeInterval(-11 * 3600), now: iso.date(from: "2026-10-08T12:00:00Z")!,
                                                        window: (600, 1200), calendar: utc))
        // 20:01 with a 10:00 to 20:00 window: shown at 10:00, 13 h 59 min after it was sent.
        XCTAssertTrue(DuoNotifier.holdOutlivesTheNudge(sentAt: sent, now: sent, window: (600, 1200), calendar: utc))
        // Sent at 20:01 but arriving at 23:00 with a window from 10:00: measured from 20:01, 13 h 59 min.
        XCTAssertTrue(DuoNotifier.holdOutlivesTheNudge(sentAt: sent, now: iso.date(from: "2026-10-08T23:00:00Z")!, window: (600, 1320), calendar: utc))
        // The same arrival with a window from 08:00 is 11 h 59 min after the sending: shown.
        XCTAssertFalse(DuoNotifier.holdOutlivesTheNudge(sentAt: sent, now: iso.date(from: "2026-10-08T23:00:00Z")!, window: (480, 1320), calendar: utc))
        // Held to 08:00 from 21:00 the evening before is 11 hours: shown.
        XCTAssertFalse(DuoNotifier.holdOutlivesTheNudge(sentAt: iso.date(from: "2026-10-08T21:00:00Z")!, now: iso.date(from: "2026-10-08T22:30:00Z")!,
                                                        window: (480, 1320), calendar: utc))
    }

    func testTheStoreRemovesThroughTheNotifier() async {
        let (kit, center, notifier) = rig()
        center.delivered = [DuoNotificationRecord(identifier: "remote-1", threadIdentifier: DuoNotifier.threadIdentifier(for: duoID), userInfo: [:])]
        kit.store.removeNotifications(for: DuoFixtures.duo())
        await notifier.waitForRemovals()
        XCTAssertTrue(center.delivered.isEmpty)
    }
}
#endif
