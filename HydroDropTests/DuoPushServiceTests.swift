#if DUO_V2
import BackgroundTasks
import XCTest
@testable import HydroDrop

// MARK: - Test doubles of this file's own

/// An identity that counts `prepare()` and can run something in the middle of it, so a test can
/// show the push service asks it only when it may, and drops what a wipe overtook.
private final class FIdentity: DuoIdentityProviding, @unchecked Sendable {
    var credential: DuoCredential?
    var installDay = "2026-09-01"
    var launch: DuoIdentityLaunch = .ready
    var duringPrepare: (@MainActor () -> Void)?
    private(set) var prepares = 0

    func store(_ credential: DuoCredential) throws { self.credential = credential }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { credential = nil }
    /// Runs off the main actor, so the count, the hook and the answer are all read on it, where the
    /// tests write them (review F16).
    func prepare() async -> DuoIdentityLaunch {
        await MainActor.run {
            prepares += 1
            duringPrepare?()
            return launch
        }
    }
    func continueAsRestored() async {}
}

/// A real `DuoPushService` over a `DuoTestKit`, with the system's part recorded.
@MainActor
private final class FPushRig {
    let kit: DuoTestKit
    let identity = FIdentity()
    let center = NotificationCenter()
    var zone = "America/Toronto"
    /// What iOS says when asked whether it has ever asked about notifications.
    var permissionUndetermined = true
    private(set) var registrations = 0
    private(set) var permissionRequests = 0
    private(set) var service: DuoPushService!

    static let token = Data((1...32).map { UInt8($0) })
    static var tokenHex: String { DuoPushUploadPlan.tokenHex(token) }

    init(credential: DuoCredential? = DuoFixtures.credential(), duos: [DuoState] = [DuoFixtures.duo()]) {
        kit = DuoTestKit()
        identity.credential = credential
        kit.dependencies.identity = identity
        for duo in duos { kit.store.upsert(duo) }
        let system = DuoPushSystem(
            registerForRemoteNotifications: { [unowned self] in registrations += 1 },
            permissionUndetermined: { [unowned self] in permissionUndetermined },
            requestNotificationPermission: { [unowned self] in permissionRequests += 1 },
            zoneIdentifier: { [unowned self] in zone },
            notificationCenter: center
        )
        service = DuoPushService(dependencies: kit.dependencies, system: system)
        kit.dependencies.push = service
    }

    var ops: FakeOpQueue { kit.ops }
    var uploads: [DuoQueuedOp] { kit.ops.pending.filter { $0.kind == .registerPush } }
    var removals: [DuoQueuedOp] { kit.ops.pending.filter { $0.kind == .unregisterPush } }
    var record: DuoPushUploadState? { kit.dependencies.cache.loadPushUpload() }

    func settle() async {
        for _ in 0..<2 {
            for _ in 0..<10 { await Task.yield() }
            await service.waitUntilSettled()
        }
    }

    func post(_ name: Notification.Name) async {
        center.post(name: name, object: nil)
        await settle()
    }

    func reevaluate(_ reason: DuoPushUploadReason) async {
        service.reevaluate(reason)
        await settle()
    }

    func tokenArrives(_ token: Data = FPushRig.token, environment: DuoAPNsEnvironment = .sandbox) async {
        service.tokenArrived(token, environment: environment)
        await settle()
    }

    /// The queue sent everything it held and the server answered each the same way.
    func queueAnswers(succeeded: Bool) {
        for op in kit.ops.pending { service.opFinished(op, succeeded: succeeded) }
        kit.ops.discardAll()
    }

    /// A launch with the token on hand, its upload answered: what the server holds is recorded.
    func primed() async -> FPushRig {
        await tokenArrives()
        queueAnswers(succeeded: true)
        return self
    }

    func endEveryDuo() {
        for duo in kit.store.duos { kit.store.update(duo.id) { $0.endedAt = kit.clock.now; $0.endedBy = .partner } }
    }

    static func request(_ op: DuoQueuedOp) -> DuoWireRegisterPushRequest {
        try! DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: op.body)
    }

    static func body(_ op: DuoQueuedOp) -> String { String(decoding: op.body, as: UTF8.self) }
}

// MARK: - The upload

/// The push upload (final design §3.1, §6.2, §9.6, D36): the consent rule, the triggers, the D36
/// zone rule, the first upload's attestation, the queue's answers and the token taken back once.
@MainActor
final class DuoPushServiceTests: XCTestCase {

    // MARK: Consent

    func testALaunchWithNoDuoAndNoCredentialDoesNothing() async {
        let rig = FPushRig(credential: nil, duos: [])
        await rig.post(UIApplication.didBecomeActiveNotification)
        await rig.tokenArrives()
        await rig.reevaluate(.zoneChanged)
        await rig.post(UserDefaults.didChangeNotification)
        XCTAssertEqual(rig.registrations, 0, "no token is asked of iOS")
        XCTAssertEqual(rig.permissionRequests, 0)
        XCTAssertEqual(rig.identity.prepares, 0, "prepare() is never asked with no duo cached")
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertEqual(rig.ops.drains, 0)
        XCTAssertTrue(rig.kit.transport.calls.isEmpty)
    }

    /// A cached live duo is not consent on its own: without a credential (no tap yet, or an identity
    /// the server forgot) nothing is asked, uploaded or removed.
    func testWithoutACredentialALiveDuoChangesNothing() async {
        let rig = FPushRig(credential: nil)
        rig.kit.dependencies.cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: nil,
                                                                     windowEnd: nil, enabled: true, uploadedAt: rig.kit.clock.now))
        await rig.post(UIApplication.didBecomeActiveNotification)
        await rig.tokenArrives()
        await rig.reevaluate(.duoStarted)
        rig.endEveryDuo()
        rig.service.noLiveDuoRemains()
        await rig.settle()
        XCTAssertEqual(rig.registrations, 0)
        XCTAssertEqual(rig.permissionRequests, 0)
        XCTAssertEqual(rig.identity.prepares, 0)
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertNotNil(rig.record, "nothing is changed either")
    }

    func testNothingIsUploadedUntilTheLaunchAnswerIsReady() async {
        let answers: [DuoIdentityLaunch] = [.none, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")), .disconnected, .unavailable]
        for answer in answers {
            let rig = FPushRig()
            rig.identity.launch = answer
            await rig.post(UIApplication.didBecomeActiveNotification)
            await rig.tokenArrives()
            await rig.reevaluate(.duoStarted)
            XCTAssertGreaterThan(rig.identity.prepares, 0, "\(answer)")
            XCTAssertEqual(rig.registrations, 0, "\(answer): not even a token is asked for")
            XCTAssertTrue(rig.ops.pending.isEmpty, "\(answer): nothing is queued while the identity is not ready")
        }
    }

    // MARK: The launch and the token

    func testALiveDuoAsksIOSForATokenAndUploadsItWhenItArrives() async throws {
        let rig = FPushRig()
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.registrations, 1, "a live duo with no token in hand asks iOS for one")
        XCTAssertTrue(rig.ops.pending.isEmpty, "and waits for it")
        await rig.tokenArrives(environment: .sandbox)
        let op = try XCTUnwrap(rig.uploads.first)
        XCTAssertEqual(rig.uploads.count, 1)
        XCTAssertTrue(op.attestsFirstUpload, "the first upload of a token by this device is attested")
        XCTAssertEqual(op.method, "PUT")
        XCTAssertEqual(op.path, "/devices/me/push")
        let request = FPushRig.request(op)
        XCTAssertEqual(request.token, FPushRig.tokenHex)
        XCTAssertEqual(request.apnsEnv, "sandbox")
        XCTAssertEqual(request.tz, "America/Toronto")
        XCTAssertEqual(request.wakeStartMin, 480)
        XCTAssertEqual(request.wakeEndMin, 1320)
        XCTAssertTrue(request.notificationsEnabled)
        XCTAssertGreaterThanOrEqual(rig.ops.drains, 1, "queued, then the queue is drained")
        XCTAssertEqual(rig.permissionRequests, 0, "a launch never asks for permission")
    }

    func testTheTokenAlreadyInHandIsUploadedAtLaunch() async {
        let rig = FPushRig()
        rig.service.tokenArrived(FPushRig.token, environment: .production)
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.registrations, 0)
        XCTAssertEqual(rig.uploads.count, 1, "the token's arrival and the launch are one upload, not two")
        XCTAssertEqual(rig.uploads.first.map(FPushRig.request)?.apnsEnv, "production")
    }

    func testOnlyTheFirstTimeTheAppBecomesActiveIsTheLaunch() async {
        let rig = await FPushRig().primed()
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.uploads.count, 1, "a launch re-uploads, to refresh the row's updated_at (§9.6)")
        XCTAssertFalse(rig.uploads[0].attestsFirstUpload, "a re-upload is not attested")
        rig.queueAnswers(succeeded: true)
        await rig.post(UIApplication.didBecomeActiveNotification)
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertTrue(rig.ops.pending.isEmpty, "coming back to the foreground is not a launch")
    }

    func testASecondEvaluationWithNothingChangedQueuesNothing() async {
        let rig = await FPushRig().primed()
        for reason: DuoPushUploadReason in [.windowChanged, .toggleChanged, .zoneChanged, .duoStarted, .background] {
            await rig.reevaluate(reason)
            XCTAssertTrue(rig.ops.pending.isEmpty, "\(reason) with nothing changed")
        }
    }

    /// CloudKit's mirror asks for the token at every launch, so the same token arrives again and
    /// again; only a new one is a change.
    func testTheSameTokenArrivingAgainIsNotAChange() async throws {
        let rig = await FPushRig().primed()
        await rig.tokenArrives()
        XCTAssertTrue(rig.ops.pending.isEmpty)
        await rig.tokenArrives(Data(repeating: 0x5A, count: 32))
        let op = try XCTUnwrap(rig.uploads.first)
        XCTAssertTrue(op.attestsFirstUpload, "a new token is a first upload")
        XCTAssertEqual(FPushRig.request(op).token, String(repeating: "5a", count: 32))
    }

    func testAnUploadStillWaitingIsNotQueuedASecondTime() async {
        let rig = FPushRig()
        await rig.tokenArrives()
        rig.service.reevaluate(.launch)
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        XCTAssertEqual(rig.uploads.count, 1)
    }

    // MARK: Triggers

    func testAZoneChangeUploadsTheNewZone() async throws {
        let rig = await FPushRig().primed()
        await rig.post(UIApplication.significantTimeChangeNotification)
        XCTAssertTrue(rig.ops.pending.isEmpty, "a clock change that moved no zone is no change")
        rig.zone = "Europe/Paris"
        await rig.post(.NSSystemTimeZoneDidChange)
        let op = try XCTUnwrap(rig.uploads.first)
        XCTAssertEqual(rig.uploads.count, 1)
        XCTAssertEqual(FPushRig.request(op).tz, "Europe/Paris")
        XCTAssertFalse(op.attestsFirstUpload)
    }

    func testABackgroundRunUploadsOnlyAMovedZone() async {
        let rig = await FPushRig().primed()
        rig.kit.dependencies.wakingWindow = { (420, 1320) }
        await rig.reevaluate(.background)
        XCTAssertTrue(rig.ops.pending.isEmpty, "a background run looks at the zone alone")
        rig.zone = "Asia/Tokyo"
        await rig.reevaluate(.background)
        XCTAssertEqual(rig.uploads.map { FPushRig.request($0).tz }, ["Asia/Tokyo"])
    }

    /// The window lives in the defaults: a burst of writes is looked at once, and only a window that
    /// moved is uploaded.
    func testAWindowThatMovedIsUploadedOnceAndAWriteThatLeftItAloneIsNot() async throws {
        let rig = await FPushRig().primed()
        await rig.post(UserDefaults.didChangeNotification)
        XCTAssertTrue(rig.ops.pending.isEmpty, "a write that changed something else")
        rig.kit.dependencies.wakingWindow = { (420, 1260) }
        for _ in 0..<5 { rig.center.post(name: UserDefaults.didChangeNotification, object: nil) }
        await rig.settle()
        let op = try XCTUnwrap(rig.uploads.first)
        XCTAssertEqual(rig.uploads.count, 1, "one upload for the burst")
        XCTAssertEqual(FPushRig.request(op).wakeStartMin, 420)
        XCTAssertEqual(FPushRig.request(op).wakeEndMin, 1260)
        await rig.post(UserDefaults.didChangeNotification)
        XCTAssertEqual(rig.uploads.count, 1)
    }

    /// The op queue writes its own defaults whenever something is queued. If every write were taken
    /// for a window change, an upload the server kept refusing would queue itself again for ever.
    func testARefusedUploadDoesNotQueueItselfAgainOnEveryDefaultsWrite() async {
        let rig = FPushRig()
        await rig.tokenArrives()
        rig.queueAnswers(succeeded: false)
        for _ in 0..<3 { await rig.post(UserDefaults.didChangeNotification) }
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    /// D36: with the toggle off the zone is still sent and the window never is.
    func testTurningTheToggleOffKeepsTheZoneAndDropsTheWindow() async throws {
        let rig = await FPushRig().primed()
        rig.kit.store.notificationsEnabled = false
        await rig.settle()
        let op = try XCTUnwrap(rig.uploads.first)
        let request = FPushRig.request(op)
        XCTAssertFalse(request.notificationsEnabled)
        XCTAssertEqual(request.tz, "America/Toronto")
        XCTAssertNil(request.wakeStartMin)
        XCTAssertNil(request.wakeEndMin)
        XCTAssertFalse(FPushRig.body(op).contains("wake_"), "no minutes on the wire: \(FPushRig.body(op))")
        XCTAssertFalse(op.attestsFirstUpload)
        rig.queueAnswers(succeeded: true)
        rig.kit.dependencies.wakingWindow = { (300, 1200) }
        await rig.reevaluate(.windowChanged)
        XCTAssertTrue(rig.ops.pending.isEmpty, "with the toggle off the window is not the server's, so moving it changes nothing")
        rig.kit.store.notificationsEnabled = true
        await rig.settle()
        let back = try XCTUnwrap(rig.uploads.first.map(FPushRig.request))
        XCTAssertEqual(back.wakeStartMin, 300)
        XCTAssertEqual(back.wakeEndMin, 1200)
        XCTAssertTrue(back.notificationsEnabled)
    }

    // MARK: The queue's answers

    func testASentUploadRecordsAHashOfTheTokenAndNeverTheToken() async throws {
        let rig = FPushRig()
        await rig.tokenArrives()
        rig.queueAnswers(succeeded: true)
        let record = try XCTUnwrap(rig.record)
        let deviceID = DuoFixtures.credential().deviceID
        XCTAssertEqual(record.tokenHash, DuoPushService.tokenHash(FPushRig.tokenHex, deviceID: deviceID))
        XCTAssertEqual(record.tokenHash.count, 64)
        XCTAssertEqual(record.environment, .sandbox)
        XCTAssertEqual(record.zone, "America/Toronto")
        XCTAssertEqual(record.windowStart, 480)
        XCTAssertEqual(record.windowEnd, 1320)
        XCTAssertTrue(record.enabled)
        XCTAssertEqual(rig.kit.store.diagnostics.lastUploadedZone, "America/Toronto")
        XCTAssertEqual(rig.kit.store.diagnostics.lastUploadedWindowStart, 480)
        XCTAssertEqual(rig.kit.store.diagnostics.lastUploadAt, rig.kit.clock.now)
        // Nowhere in the defaults, in hex or as the raw bytes.
        for (key, value) in rig.kit.defaults.dictionaryRepresentation() {
            let text: String
            if let data = value as? Data { text = String(decoding: data, as: UTF8.self) } else { text = "\(value)" }
            XCTAssertFalse(text.contains(FPushRig.tokenHex), "\(key) holds the token")
            if let data = value as? Data { XCTAssertNil(data.range(of: FPushRig.token), "\(key) holds the token's bytes") }
        }
    }

    func testAHashIsAboutOneTokenOnOneDevice() {
        let a = DuoPushService.tokenHash("abcd", deviceID: "device-a")
        XCTAssertEqual(a, DuoPushService.tokenHash("abcd", deviceID: "device-a"))
        XCTAssertNotEqual(a, DuoPushService.tokenHash("abcd", deviceID: "device-b"))
        XCTAssertNotEqual(a, DuoPushService.tokenHash("abce", deviceID: "device-a"))
        XCTAssertFalse(a.contains("abcd"))
    }

    func testADroppedUploadRecordsNothingSoTheNextTriggerTriesAgain() async throws {
        let rig = FPushRig()
        await rig.tokenArrives()
        rig.queueAnswers(succeeded: false)
        XCTAssertNil(rig.record)
        await rig.reevaluate(.windowChanged)
        let retry = try XCTUnwrap(rig.uploads.first)
        XCTAssertTrue(retry.attestsFirstUpload, "the server never took it, so it is still the first")
    }

    /// A re-upload the server refused (an unattested one, to a server that lost the token's row) is
    /// tried next time as a first upload, attested, while the record still says a token may be held.
    func testARefusedReUploadIsAttestedNextTimeAndTheTokenCanStillBeTakenBack() async throws {
        let rig = await FPushRig().primed()
        await rig.reevaluate(.launch)
        XCTAssertEqual(rig.uploads.map(\.attestsFirstUpload), [false])
        rig.queueAnswers(succeeded: false)
        await rig.reevaluate(.launch)
        XCTAssertEqual(rig.uploads.map(\.attestsFirstUpload), [true])
        rig.kit.ops.discardAll()
        rig.endEveryDuo()
        rig.service.noLiveDuoRemains()
        XCTAssertEqual(rig.removals.count, 1, "the record still says the server may hold a token")
    }

    func testARefusedFirstUploadLeavesAnEarlierTokensRecordAlone() async throws {
        let rig = await FPushRig().primed()
        let before = try XCTUnwrap(rig.record)
        await rig.tokenArrives(Data(repeating: 0x77, count: 32))
        XCTAssertEqual(rig.uploads.map(\.attestsFirstUpload), [true])
        rig.queueAnswers(succeeded: false)
        XCTAssertEqual(rig.record, before)
    }

    /// A wipe while an upload was out: its answer is about data the person deleted, and the record it
    /// would write is one the wipe removed (written back, the next identity's first upload would look
    /// like a re-upload).
    func testAnAnswerThatArrivesAfterAWipeIsNotWrittenBack() async throws {
        let rig = FPushRig()
        await rig.tokenArrives()
        let op = try XCTUnwrap(rig.uploads.first)
        rig.kit.store.resetLocalState()
        rig.service.opFinished(op, succeeded: true)
        XCTAssertNil(rig.record)
    }

    func testAnAnswerForAnotherDeviceIsNotRecorded() async throws {
        let rig = FPushRig()
        await rig.tokenArrives()
        let op = try XCTUnwrap(rig.uploads.first)
        rig.identity.credential = DuoCredential(memberID: "m2", deviceID: "6d2a0000-0000-4000-8000-0000000000cc", deviceSecret: "x")
        rig.service.opFinished(op, succeeded: true)
        XCTAssertNil(rig.record)
    }

    /// An op queued in an earlier launch survived it: its answer is believed as long as nothing has
    /// been wiped in this one.
    func testAnAnswerToAnUploadQueuedInAnEarlierLaunchIsRecorded() throws {
        let rig = FPushRig()
        let request = DuoPushUploadPlan.desired(tokenHex: FPushRig.tokenHex, environment: .production, zone: "UTC", window: (480, 1320),
                                                notificationsEnabled: true)
        let op = try DuoQueuedOp.registerPush(request, firstUpload: true, key: "earlier", now: rig.kit.clock.now)
        rig.service.opFinished(op, succeeded: true)
        XCTAssertEqual(rig.record?.tokenHash, DuoPushService.tokenHash(FPushRig.tokenHex, deviceID: DuoFixtures.credential().deviceID))
        rig.kit.store.resetLocalState()
        rig.service.opFinished(op, succeeded: true)
        XCTAssertNil(rig.record, "but not once a wipe has happened in this launch")
    }

    /// A wipe while the launch answer was being worked out: whatever was going to be uploaded is not.
    func testAWipeWhileTheLaunchAnswerWasWorkedOutUploadsNothing() async {
        let rig = FPushRig()
        rig.service.tokenArrived(FPushRig.token, environment: .sandbox)
        rig.kit.ops.discardAll()
        let kit = rig.kit
        rig.identity.duringPrepare = {
            // The wipe, then a duo back on the screen, so only the wipe count can tell.
            kit.store.resetLocalState()
            kit.store.upsert(DuoFixtures.duo())
        }
        await rig.reevaluate(.launch)
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testAReconnectAsAnotherDeviceUploadsTheSameTokenAsAFirstUpload() async throws {
        let rig = await FPushRig().primed()
        // A disconnected phone mints a new device and reconnects as it (§3.4); the token is the same.
        rig.identity.credential = DuoCredential(memberID: "m", deviceID: "6d2a0000-0000-4000-8000-0000000000dd", deviceSecret: "y")
        await rig.reevaluate(.duoStarted)
        let op = try XCTUnwrap(rig.uploads.first)
        XCTAssertTrue(op.attestsFirstUpload, "the server has never had this token from this device")
    }

    // MARK: No live duo left

    func testTheLastDuoEndingQueuesOneRemoval() async throws {
        let rig = await FPushRig().primed()
        rig.endEveryDuo()
        rig.service.noLiveDuoRemains()
        rig.service.noLiveDuoRemains()
        await rig.reevaluate(.launch)
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.removals.count, 1, "once, however many ask")
        XCTAssertTrue(rig.uploads.isEmpty, "and nothing is uploaded with no live duo")
        let op = try XCTUnwrap(rig.removals.first)
        XCTAssertEqual(op.method, "DELETE")
        XCTAssertEqual(op.path, "/devices/me/push")
        XCTAssertEqual(rig.identity.prepares, 1, "only the launch before the end asked for the identity")
        rig.queueAnswers(succeeded: true)
        XCTAssertNil(rig.record, "a removal the server took forgets the record")
    }

    /// A removal refused for good forgets the record, so it is not sent again at every trigger; the
    /// server's sweep is the backstop for a row it still holds (review F6; it used to be retried).
    func testADroppedRemovalForgetsTheRecordAndIsNotQueuedAgain() async {
        let rig = await FPushRig().primed()
        rig.endEveryDuo()
        rig.service.noLiveDuoRemains()
        rig.queueAnswers(succeeded: false)
        XCTAssertNil(rig.record)
        await rig.reevaluate(.zoneChanged)
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertTrue(rig.removals.isEmpty)
    }

    func testNoRemovalWhileADuoIsStillLive() async {
        let rig = await FPushRig().primed()
        rig.service.noLiveDuoRemains()
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testNoRemovalWhenTheServerHoldsNothing() async {
        let rig = FPushRig()
        rig.endEveryDuo()
        rig.service.noLiveDuoRemains()
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    /// An upload still waiting when the last duo ends would, once sent, leave a token on the server
    /// that nothing here would take back.
    func testAnUploadStillWaitingWhenTheLastDuoEndsIsTakenBack() async {
        let rig = FPushRig()
        await rig.tokenArrives()
        XCTAssertNil(rig.record)
        rig.endEveryDuo()
        rig.service.noLiveDuoRemains()
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.registerPush, .unregisterPush])
    }

    /// With no duo cached at all there is nothing to be told about, and asking `prepare()` would be
    /// asking it with no duo cached: the record goes locally and nothing is sent.
    func testWithNoDuoCachedTheRecordIsForgottenHereAndNothingIsSent() async {
        let rig = FPushRig(duos: [])
        rig.kit.dependencies.cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: 480,
                                                                     windowEnd: 1320, enabled: true, uploadedAt: rig.kit.clock.now))
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertNil(rig.record)
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertEqual(rig.identity.prepares, 0)
        XCTAssertEqual(rig.registrations, 0)
    }

    // MARK: Permission

    /// Asked when a duo has started and when Duo's toggle is turned on (`DuoPushLifecycleTests` has
    /// the second), never at a launch, a token, a zone, a window or a background run.
    func testPermissionIsAskedOnlyWhenADuoHasStarted() async {
        let rig = FPushRig()
        for reason: DuoPushUploadReason in [.launch, .tokenChanged, .windowChanged, .zoneChanged, .background] {
            await rig.reevaluate(reason)
        }
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.permissionRequests, 0)
        await rig.reevaluate(.duoStarted)
        XCTAssertEqual(rig.permissionRequests, 1)
    }

    func testPermissionIsNotAskedWithoutALiveDuoOrWithDuosNotificationsOff() async {
        let ended = FPushRig()
        ended.endEveryDuo()
        await ended.reevaluate(.duoStarted)
        XCTAssertEqual(ended.permissionRequests, 0)
        let off = FPushRig()
        off.kit.store.notificationsEnabled = false
        await off.reevaluate(.duoStarted)
        XCTAssertEqual(off.permissionRequests, 0)
    }
}

// MARK: - The background refresh

@MainActor
private final class FBackgroundRig {
    let kit: DuoTestKit
    let center = NotificationCenter()
    var fails = false
    private(set) var submitted: [BGAppRefreshTaskRequest] = []
    private(set) var cancelled: [String] = []
    private(set) var background: DuoBackground!

    init(duos: [DuoState] = [DuoFixtures.duo()], credential: DuoCredential? = DuoFixtures.credential(),
         now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        kit = DuoTestKit(now: now, credential: credential)
        for duo in duos { kit.store.upsert(duo) }
        let system = DuoBackgroundSystem(submit: { [unowned self] request in
            if fails { throw NSError(domain: BGTaskScheduler.errorDomain, code: BGTaskScheduler.Error.unavailable.rawValue) }
            submitted.append(request)
        }, cancel: { [unowned self] identifier in cancelled.append(identifier) }, notificationCenter: center)
        background = DuoBackground(dependencies: kit.dependencies, system: system)
    }
}

/// The background refresh (final design §10.6, §9.7): asked for only with a live duo, at the
/// midnight one-shot or the regular net, under the one identifier the project declares.
@MainActor
final class DuoBackgroundTests: XCTestCase {
    func testTheIdentifierIsTheOneTheProjectDeclaresAndTheModesStay() throws {
        XCTAssertEqual(DuoBackground.refreshIdentifier, "com.jonathonbrown.HydroDrop.duo.refresh")
        XCTAssertEqual(DuoBackground.refreshIdentifier, LegacyDuoCleanup.refreshIdentifier)
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let permitted = try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        XCTAssertEqual(permitted, [DuoBackground.refreshIdentifier])
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("fetch"), "Duo's background refresh rides on it")
        XCTAssertTrue(modes.contains("remote-notification"), "SwiftData's CloudKit mirror needs it")
    }

    func testARefreshIsAskedForWithALiveDuo() throws {
        let rig = FBackgroundRig()
        rig.background.scheduleRefresh()
        let request = try XCTUnwrap(rig.submitted.first)
        XCTAssertEqual(rig.submitted.count, 1)
        XCTAssertEqual(request.identifier, DuoBackground.refreshIdentifier)
        // The kit's clock is 14:13:20 UTC, ten hours from midnight: the regular net.
        let expected = DuoBackgroundSchedule.nextEarliestBegin(now: rig.kit.clock.now, calendar: rig.kit.clock.calendar,
                                                               jitterSeconds: DuoBackgroundSchedule.jitterSeconds(random: TestRandom()))
        XCTAssertEqual(request.earliestBeginDate, expected)
        XCTAssertEqual(request.earliestBeginDate, rig.kit.clock.now.addingTimeInterval(30 * 60))
    }

    func testInTheEveningItIsTheOneShotJustAfterMidnight() throws {
        // A clock that reads 21:00 UTC.
        let rig = FBackgroundRig(now: Date(timeIntervalSince1970: 1_790_024_400))
        rig.background.scheduleRefresh()
        let begin = try XCTUnwrap(rig.submitted.first?.earliestBeginDate)
        let midnight = Date(timeIntervalSince1970: 1_790_035_200)
        XCTAssertGreaterThanOrEqual(begin.timeIntervalSince(midnight), 300)
        XCTAssertLessThanOrEqual(begin.timeIntervalSince(midnight), 2100)
    }

    /// No live duo, or no credential: nothing is asked for, and a request already pending is taken
    /// back (review F9).
    func testNothingIsAskedForWithoutALiveDuoOrACredential() {
        let none = FBackgroundRig(duos: [])
        none.background.scheduleRefresh()
        XCTAssertTrue(none.submitted.isEmpty)
        XCTAssertEqual(none.cancelled, [DuoBackground.refreshIdentifier])
        let ended = FBackgroundRig(duos: [DuoFixtures.duo(ended: true)])
        ended.background.scheduleRefresh()
        XCTAssertTrue(ended.submitted.isEmpty)
        XCTAssertEqual(ended.cancelled, [DuoBackground.refreshIdentifier])
        let noCredential = FBackgroundRig(credential: nil)
        noCredential.background.scheduleRefresh()
        XCTAssertTrue(noCredential.submitted.isEmpty, "a cached live duo is not enough without a credential")
        XCTAssertEqual(noCredential.cancelled, [DuoBackground.refreshIdentifier])
        let pending = FBackgroundRig(duos: [DuoFixtures.duo(joined: false)])
        pending.background.scheduleRefresh()
        XCTAssertEqual(pending.submitted.count, 1, "a duo waiting for its partner is live")
        XCTAssertTrue(pending.cancelled.isEmpty)
    }

    func testAZoneOrClockChangeAsksAgain() async {
        let rig = FBackgroundRig()
        rig.center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        rig.center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        rig.center.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(rig.submitted.count, 3, "a zone change, midnight, and a clock set by hand")
    }

    func testASchedulerThatRefusesIsSurvived() {
        let rig = FBackgroundRig()
        rig.fails = true
        rig.background.scheduleRefresh()
        XCTAssertTrue(rig.submitted.isEmpty)
    }

    func testTheHandlerRefreshesLooksAtTheZoneAndAsksForTheNextRun() async {
        let kit = DuoTestKit()
        await DuoBackground.handleAppRefresh(store: kit.store)
        XCTAssertEqual(kit.sync.calls, ["backgroundRefresh"])
        XCTAssertEqual(kit.push.reasons, [.background])
        XCTAssertEqual(kit.background.scheduled, 1)
    }

    /// iOS cancels the task when its time is up: nothing more is started, and the next run is still
    /// asked for, or the background path would stop after one expiry.
    func testACancelledRunStartsNothingMoreAndStillAsksForTheNextOne() async {
        let kit = DuoTestKit()
        let run = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await DuoBackground.handleAppRefresh(store: kit.store)
        }
        await run.value
        XCTAssertTrue(kit.sync.calls.isEmpty)
        XCTAssertTrue(kit.push.reasons.isEmpty)
        XCTAssertEqual(kit.background.scheduled, 1)
    }
}
#endif
