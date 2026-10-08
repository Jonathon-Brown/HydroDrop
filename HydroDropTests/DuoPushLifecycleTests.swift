#if DUO_V2
import BackgroundTasks
import XCTest
@testable import HydroDrop

// The stage F review's findings on the push service's and the background refresh's lifecycle, each
// pinned by a port of the reviewers' probe (lens folders review-f/lens-{lifecycle,permissions,
// notifications}). Kept apart from DuoPushServiceTests so the findings read as one list.

// MARK: - Test doubles of this file's own

/// An identity whose launch answer the test sets, and which notes when it is asked.
private final class LIdentity: DuoIdentityProviding, @unchecked Sendable {
    var credential: DuoCredential?
    var installDay = "2026-09-01"
    var launch: DuoIdentityLaunch = .ready
    var log: ((String) -> Void)?
    private(set) var prepares = 0
    init(credential: DuoCredential?) { self.credential = credential }
    func store(_ credential: DuoCredential) throws { self.credential = credential }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { credential = nil }
    /// Runs off the main actor, as the protocol allows, so what it touches it touches on the main
    /// actor, where the tests read it: counting and logging from here raced the main actor's own
    /// writes to the same log and crashed about one run in six (review F16, under TSan).
    func prepare() async -> DuoIdentityLaunch {
        await MainActor.run {
            prepares += 1
            log?("prepare")
            return credential == nil ? .none : launch
        }
    }
    func continueAsRestored() async {}
}

/// The op queue as stage E's brief has it, cut down to the two push kinds: in order, through the
/// transport, a failure through `noteFailure`; done on a 2xx, kept on `offline`, dropped on anything
/// else; and the push service told of each push op it settles.
@MainActor
private final class LQueue: DuoOpQueueing {
    private let dependencies: DuoDependencies
    private(set) var pending: [DuoQueuedOp] = []
    init(dependencies: DuoDependencies) { self.dependencies = dependencies }
    func enqueue(_ op: DuoQueuedOp) { pending.append(op) }
    func startMonitoring() {}
    func discardAll() { pending = [] }
    func drain() async {
        guard await dependencies.identity.prepare() == .ready else { return }
        while let op = pending.first {
            do {
                switch op.kind {
                case .registerPush:
                    let request = try DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: op.body)
                    try await dependencies.transport.registerPush(request, firstUpload: op.attestsFirstUpload)
                case .unregisterPush:
                    try await dependencies.transport.unregisterPush()
                default:
                    break
                }
                pending.removeFirst()
                dependencies.push?.opFinished(op, succeeded: true)
            } catch DuoTransportError.offline {
                return
            } catch {
                dependencies.noteFailure(error)
                pending.removeFirst()
                dependencies.push?.opFinished(op, succeeded: false)
            }
        }
    }
}

/// A sync whose background refresh waits in a task of its own, as stage C's does, so a cancellation
/// of the handler never reaches it; the test lets it finish.
@MainActor
private final class LSlowSync: DuoSyncing {
    let gate = DuoFirstOf()
    private(set) var started = false
    private(set) var finished = false
    func activate(logReader: DuoLogReading) {}
    func logChanged(_ summary: DuoLogSummary) {}
    func refresh() async {}
    func flush() async {}
    func backgroundRefresh() async -> Bool {
        started = true
        let gate = gate
        await Task { await gate.wait() }.value
        finished = true
        return false
    }
    func pushArrived(_ payload: DuoPushPayload) async {}
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async {}
}

/// A real push service and background service over a `DuoTestKit`, with the system's part recorded.
@MainActor
private final class LRig {
    let kit: DuoTestKit
    let identity: LIdentity
    let center = NotificationCenter()
    var zone = "America/Toronto"
    var window = (start: 480, end: 1320)
    var permissionUndetermined = true
    private(set) var events: [String] = []
    private(set) var submits: [BGAppRefreshTaskRequest] = []
    private(set) var cancels = 0
    private(set) var service: DuoPushService!
    private(set) var background: DuoBackground!

    static let token = Data((1...32).map { UInt8($0) })

    init(credential: DuoCredential? = DuoFixtures.credential(), duos: [DuoState] = [DuoFixtures.duo()], executingQueue: Bool = false) {
        kit = DuoTestKit()
        identity = LIdentity(credential: credential)
        kit.dependencies.identity = identity
        for duo in duos { kit.store.upsert(duo) }
        identity.log = { [unowned self] in events.append($0) }
        kit.dependencies.wakingWindow = { [unowned self] in window }
        let system = DuoPushSystem(
            registerForRemoteNotifications: { [unowned self] in events.append("register") },
            permissionUndetermined: { [unowned self] in permissionUndetermined },
            requestNotificationPermission: { [unowned self] in events.append("prompt") },
            zoneIdentifier: { [unowned self] in zone },
            notificationCenter: center
        )
        service = DuoPushService(dependencies: kit.dependencies, system: system)
        kit.dependencies.push = service
        background = DuoBackground(dependencies: kit.dependencies, system: DuoBackgroundSystem(
            submit: { [unowned self] in submits.append($0) }, cancel: { [unowned self] _ in cancels += 1 }, notificationCenter: center))
        kit.dependencies.background = background
        if executingQueue { kit.dependencies.ops = LQueue(dependencies: kit.dependencies) }
    }

    var ops: DuoOpQueueing { kit.dependencies.ops! }
    var queued: [DuoQueuedOp] { ops.pending }
    var prompts: Int { events.filter { $0 == "prompt" }.count }
    var registrations: Int { events.filter { $0 == "register" }.count }
    var record: DuoPushUploadState? { kit.dependencies.cache.loadPushUpload() }
    var puts: [Bool] { kit.transport.calls.compactMap { if case .registerPush(_, let first) = $0 { return first }; return nil } }
    var deletes: Int { kit.transport.calls.filter { $0 == .unregisterPush }.count }

    func settle() async {
        for _ in 0..<3 {
            for _ in 0..<20 { await Task.yield() }
            await service.waitUntilSettled()
        }
    }

    func post(_ name: Notification.Name) async {
        center.post(name: name, object: nil)
        await settle()
    }

    func tokenArrives() async {
        service.tokenArrived(Self.token, environment: .sandbox)
        await settle()
    }

    func seedRecord() {
        kit.dependencies.cache.savePushUpload(DuoPushUploadState(
            tokenHash: DuoPushService.tokenHash(DuoPushUploadPlan.tokenHex(Self.token), deviceID: DuoFixtures.credential().deviceID),
            environment: .sandbox, zone: zone, windowStart: 480, windowEnd: 1320, enabled: true, uploadedAt: kit.clock.now))
    }

    func endEveryDuo() {
        for duo in kit.store.duos where !duo.hasEnded { kit.store.update(duo.id) { $0.endedAt = kit.clock.now; $0.endedBy = .partner } }
    }
}

// MARK: - The findings

@MainActor
final class DuoPushLifecycleTests: XCTestCase {

    // MARK: F1: the background handler returns at the expiry

    /// iOS cancels the task when the run's time is up. The sync engine's requests run in tasks of
    /// their own that the cancellation never reaches, so the handler returns at the cancellation,
    /// re-armed, and leaves the work to run (probe testExpiryWithStageCsEngineDoesNotStopTheRequests:
    /// cancelled at 0.31 s, the handler returned 2.74 s later).
    func testAnExpiredRunReturnsAtTheCancellationAndIsReArmed() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.upsert(DuoFixtures.duo())
        let sync = LSlowSync()
        kit.dependencies.sync = sync
        let run = Task { @MainActor in await DuoBackground.handleAppRefresh(store: kit.store) }
        for _ in 0..<50 where !sync.started { await Task.yield() }
        XCTAssertTrue(sync.started)
        // The work would end 1.5 s from now, long after the expiry.
        let release = Task { try? await Task.sleep(nanoseconds: 1_500_000_000); sync.gate.open() }
        let cancelledAt = Date()
        run.cancel()
        await run.value
        let took = Date().timeIntervalSince(cancelledAt)
        XCTAssertLessThan(took, 0.5, "returned \(took) s after the expiry, while the work was still out")
        XCTAssertFalse(sync.finished, "the work is left to run")
        XCTAssertEqual(kit.background.scheduled, 1, "re-armed at the expiry")
        await release.value
        for _ in 0..<20 where !sync.finished { await Task.yield() }
        XCTAssertTrue(sync.finished)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(kit.push.reasons.isEmpty, "a run that did not finish in time starts no zone check")
    }

    func testARunThatFinishesInTimeWaitsForTheWorkAndAsksForTheZoneCheck() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.upsert(DuoFixtures.duo())
        let sync = LSlowSync()
        kit.dependencies.sync = sync
        let run = Task { @MainActor in await DuoBackground.handleAppRefresh(store: kit.store) }
        for _ in 0..<50 where !sync.started { await Task.yield() }
        XCTAssertEqual(kit.background.scheduled, 0, "still working")
        sync.gate.open()
        await run.value
        XCTAssertTrue(sync.finished)
        XCTAssertEqual(kit.push.reasons, [.background])
        XCTAssertEqual(kit.background.scheduled, 1)
    }

    func testTheGateResumesItsWaiterOnceWhicheverSideOpensIt() async {
        let gate = DuoFirstOf()
        gate.open()
        gate.open()
        await gate.wait()
        await gate.wait()
        let other = DuoFirstOf()
        let waiter = Task { await other.wait() }
        for _ in 0..<10 { await Task.yield() }
        other.open()
        other.open()
        await waiter.value
    }

    // MARK: F3: a defaults write on another thread does not wait for the main thread

    /// Observed with `queue: .main`, every `UserDefaults.didChangeNotification`, posted on the thread
    /// that wrote, made that thread wait for the main thread (probe LPDefaultsCoupling: held 1.5 s).
    func testABackgroundDefaultsWriteDoesNotWaitForTheMainThread() {
        let rig = LRig(credential: nil, duos: [])
        let done = expectation(description: "posted")
        let held = LockedSeconds()
        let center = rig.center
        DispatchQueue.global().async {
            let start = Date()
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            held.value = Date().timeIntervalSince(start)
            done.fulfill()
        }
        // The main thread busy for a second.
        Thread.sleep(forTimeInterval: 1.0)
        wait(for: [done], timeout: 5)
        XCTAssertLessThan(held.value, 0.3, "the post waited \(held.value) s for the main thread")
    }

    // MARK: F6: nothing is sent for a phone the server has shut out

    /// Probe testADisconnectedPhoneSendsAPutWithItsRevokedBearerAtEveryTrigger: after the first
    /// `401 device_revoked` every trigger sent the same PUT with the same revoked bearer.
    func testADisconnectedPhoneSendsNoMoreUploadsAfterTheFirstRefusal() async {
        let rig = LRig(executingQueue: true)
        rig.kit.transport.onRegisterPush = { _, _ in throw DuoTransportError.deviceRevoked(DuoErrorContext(httpStatus: 401)) }
        await rig.tokenArrives()
        XCTAssertEqual(rig.kit.store.availability, .disconnected)
        await rig.post(UIApplication.didBecomeActiveNotification)
        rig.zone = "Europe/London"
        await rig.post(.NSSystemTimeZoneDidChange)
        rig.kit.store.notificationsEnabled = false
        await rig.settle()
        rig.window = (420, 1260)
        await rig.post(UserDefaults.didChangeNotification)
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        XCTAssertEqual(rig.puts.count, 1, "one PUT, the one that was refused")
        XCTAssertEqual(rig.prompts, 0)
    }

    func testNothingIsAskedOrQueuedForADisconnectedBannedOrOutOfDatePhone() async {
        for availability: DuoAvailability in [.disconnected, .banned, .upgradeRequired] {
            let rig = LRig()
            rig.kit.store.availability = availability
            await rig.tokenArrives()
            await rig.post(UIApplication.didBecomeActiveNotification)
            rig.service.reevaluate(.duoStarted)
            await rig.settle()
            XCTAssertEqual(rig.identity.prepares, 0, "\(availability)")
            XCTAssertEqual(rig.registrations, 0, "\(availability)")
            XCTAssertEqual(rig.prompts, 0, "\(availability)")
            XCTAssertTrue(rig.queued.isEmpty, "\(availability)")
            // And the token is not taken back either: the DELETE would be refused the same way.
            let ended = LRig(duos: [DuoFixtures.duo(ended: true)])
            ended.seedRecord()
            ended.kit.store.availability = availability
            ended.service.noLiveDuoRemains()
            await ended.post(UIApplication.didBecomeActiveNotification)
            XCTAssertTrue(ended.queued.isEmpty, "\(availability)")
        }
    }

    /// Probe testAnEndedOnlyPhoneWhoseDeleteIsRefusedSendsItAgainAtEveryTrigger: a refused DELETE
    /// left the record, so every trigger sent it again. A refusal that leaves the phone's standing
    /// alone (`422 schema`) shows the record going is what stops it.
    func testARefusedRemovalForgetsTheRecordAndIsNotSentAgain() async {
        let rig = LRig(duos: [DuoFixtures.duo(ended: true)], executingQueue: true)
        rig.seedRecord()
        rig.kit.transport.onUnregisterPush = { throw DuoTransportError.schema(DuoErrorContext(httpStatus: 422)) }
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.deletes, 1)
        XCTAssertNil(rig.record, "refused for good: nothing more this phone can do about the row")
        rig.zone = "Europe/London"
        await rig.post(.NSSystemTimeZoneDidChange)
        rig.kit.store.notificationsEnabled = false
        await rig.settle()
        rig.service.noLiveDuoRemains()
        await rig.settle()
        XCTAssertEqual(rig.deletes, 1)
    }

    // MARK: F7 and F13: when permission is asked

    /// Probe testTurningDuosToggleOnLaterNeverAsksForPermission: someone whose toggle was off when
    /// their duo started was never asked.
    func testTurningDuosToggleOnAsksForPermissionIfIOSNeverHas() async {
        let rig = LRig()
        rig.kit.store.notificationsEnabled = false
        await rig.settle()
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        XCTAssertEqual(rig.prompts, 0, "not with the toggle off")
        rig.kit.store.notificationsEnabled = true
        await rig.settle()
        XCTAssertEqual(rig.prompts, 1)
        rig.kit.store.notificationsEnabled = false
        await rig.settle()
        XCTAssertEqual(rig.prompts, 1, "turning it off asks nothing")
    }

    func testPermissionIsNotAskedWhenIOSHasAlreadyAsked() async {
        let rig = LRig()
        rig.permissionUndetermined = false
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        rig.kit.store.notificationsEnabled = false
        rig.kit.store.notificationsEnabled = true
        await rig.settle()
        XCTAssertEqual(rig.prompts, 0)
    }

    /// Review F13: the prompt comes only once `prepare()` has said `.ready`, never during a restore
    /// question or with the launch answer unknown.
    func testPermissionIsAskedOnlyAfterTheLaunchAnswerIsReady() async {
        for launch: DuoIdentityLaunch in [.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")), .unavailable, .disconnected, .none] {
            let rig = LRig()
            rig.identity.launch = launch
            rig.service.reevaluate(.duoStarted)
            await rig.settle()
            XCTAssertEqual(rig.prompts, 0, "\(launch)")
        }
        let rig = LRig()
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        let prepared = rig.events.firstIndex(of: "prepare")
        let prompted = rig.events.firstIndex(of: "prompt")
        XCTAssertNotNil(prompted)
        XCTAssertLessThan(prepared ?? .max, prompted ?? .min, "asked after the answer, not before: \(rig.events)")
    }

    /// Review F20: the wish to ask belongs to the moment it was made. An evaluation that could not
    /// ask (the launch answer not ready) does not leave it for a later zone change or launch.
    func testAWishToAskDoesNotOutliveTheEvaluationThatCouldNotAsk() async {
        let rig = LRig()
        rig.identity.launch = .unavailable
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        XCTAssertEqual(rig.prompts, 0)
        rig.identity.launch = .ready
        rig.zone = "Europe/London"
        await rig.post(.NSSystemTimeZoneDidChange)
        await rig.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(rig.prompts, 0, "a zone change or a launch never prompts")
    }

    /// A launch waiting beside `.duoStarted` would swallow it as a reason; the prompt is kept apart.
    func testADuoStartedBesideALaunchStillAsks() async {
        let rig = LRig()
        rig.service.reevaluate(.launch)
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        XCTAssertEqual(rig.prompts, 1)
    }

    // MARK: F8: an upload behind a waiting removal is attested

    /// Probe testAnUploadQueuedBehindAWaitingRemovalGoesOutUnattested: the DELETE removes the row,
    /// and the server refuses an unattested PUT of a token it does not hold (403 attest_required).
    func testAnUploadQueuedBehindAWaitingRemovalGoesOutAttested() async {
        let rig = LRig(duos: [DuoFixtures.duo(ended: true)], executingQueue: true)
        rig.seedRecord()
        rig.kit.transport.onUnregisterPush = { throw DuoTransportError.offline }
        await rig.tokenArrives()
        rig.service.noLiveDuoRemains()
        await rig.settle()
        XCTAssertEqual(rig.queued.map(\.kind), [.unregisterPush], "the removal waits, offline")
        var serverHasRow = true
        rig.kit.transport.onUnregisterPush = { serverHasRow = false }
        rig.kit.transport.onRegisterPush = { _, first in
            if !first && !serverHasRow { throw DuoTransportError.attestRequired(DuoErrorContext(httpStatus: 403)) }
            serverHasRow = true
        }
        rig.kit.store.upsert(DuoFixtures.duo(id: UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!))
        rig.service.reevaluate(.duoStarted)
        await rig.settle()
        await rig.ops.drain()
        XCTAssertEqual(rig.puts, [true], "behind its own DELETE, the upload is the token's first")
        XCTAssertTrue(serverHasRow)
        XCTAssertNotNil(rig.record)
    }

    // MARK: F9: the background request

    /// Probes testABackgroundRefreshIsScheduledForACachedLiveDuoWithNoCredential and
    /// testARequestSubmittedWhileLiveIsLeftPendingAfterTheLastDuoEnds.
    func testTheRequestNeedsACredentialAndIsTakenBackWhenNoLiveDuoRemains() async {
        let noCredential = LRig(credential: nil)
        noCredential.kit.store.scheduleBackgroundRefresh()
        await DuoBackground.handleAppRefresh(store: noCredential.kit.store)
        XCTAssertTrue(noCredential.submits.isEmpty)
        XCTAssertTrue(noCredential.kit.transport.calls.isEmpty)

        let rig = LRig()
        rig.kit.store.scheduleBackgroundRefresh()
        XCTAssertEqual(rig.submits.count, 1)
        XCTAssertEqual(rig.cancels, 0)
        rig.endEveryDuo()
        rig.kit.store.scheduleBackgroundRefresh()
        XCTAssertEqual(rig.submits.count, 1)
        XCTAssertEqual(rig.cancels, 1, "the request submitted while the duo was live is taken back")
        rig.kit.store.upsert(DuoFixtures.duo(id: UUID(uuidString: "6d2a0000-0000-4000-8000-000000000003")!))
        rig.kit.store.scheduleBackgroundRefresh()
        rig.kit.store.resetLocalState()
        rig.kit.store.scheduleBackgroundRefresh()
        XCTAssertEqual(rig.cancels, 2, "and after a wipe")
    }

    /// Review F21: a phone the server has shut out is not woken again; the pending request is taken
    /// back, and nothing is submitted.
    func testAShutOutPhoneIsNotWokenAgain() async {
        for availability: DuoAvailability in [.disconnected, .banned, .upgradeRequired] {
            let rig = LRig()
            rig.kit.store.availability = availability
            rig.kit.store.scheduleBackgroundRefresh()
            await rig.post(.NSSystemTimeZoneDidChange)
            await DuoBackground.handleAppRefresh(store: rig.kit.store)
            XCTAssertTrue(rig.submits.isEmpty, "\(availability)")
            XCTAssertEqual(rig.cancels, 3, "\(availability): taken back each time")
        }
        let maintenance = LRig()
        maintenance.kit.store.availability = .maintenance
        maintenance.kit.store.scheduleBackgroundRefresh()
        XCTAssertEqual(maintenance.submits.count, 1, "a paused service is not a refusal: it is tried again later")
    }

    /// A run iOS cancelled before it began starts no work, even once tasks have run.
    func testARunCancelledBeforeItBeganStartsNoWorkLater() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.upsert(DuoFixtures.duo())
        let run = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await DuoBackground.handleAppRefresh(store: kit.store)
        }
        await run.value
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(kit.sync.calls.isEmpty)
        XCTAssertTrue(kit.push.reasons.isEmpty)
        XCTAssertEqual(kit.background.scheduled, 1)
    }

    func testAClockSetByHandAsksAgain() async {
        let rig = LRig()
        await rig.post(.NSSystemClockDidChange)
        XCTAssertEqual(rig.submits.count, 1)
    }

    // MARK: F14: a dropped store's services touch nothing

    /// Probe testCrashADroppedComposedStoreStillHearsTheSystemClock: the services keep each other
    /// alive through `DuoDependencies`, and their observers read `dependencies.host`, which is
    /// unowned, after the store had gone. The process ended; now nothing is read.
    func testADroppedStoresServicesHearTheSystemAndTouchNothing() async {
        let center = NotificationCenter()
        weak var dropped: DuoStore?
        var submits = 0
        do {
            let store = DuoStore(cache: DuoCache(defaults: UserDefaults(suiteName: "DuoPushLifecycleTests.\(UUID().uuidString)")!),
                                 usesServer: true, reloadWidget: {})
            let dependencies = DuoDependencies(host: store, cache: store.cache, secrets: DuoSecrets(store: DuoMemorySecretStore()),
                                               client: DuoClientInfo(marketingVersion: "2.0", build: "1"),
                                               attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
            dependencies.identity = FakeDuoIdentity(credential: DuoFixtures.credential())
            dependencies.ops = FakeOpQueue()
            dependencies.push = DuoPushService(dependencies: dependencies, system: DuoPushSystem(
                registerForRemoteNotifications: {}, permissionUndetermined: { true }, requestNotificationPermission: {},
                zoneIdentifier: { "UTC" }, notificationCenter: center))
            dependencies.background = DuoBackground(dependencies: dependencies, system: DuoBackgroundSystem(
                submit: { _ in submits += 1 }, cancel: { _ in }, notificationCenter: center))
            store.install(dependencies)
            store.upsert(DuoFixtures.duo())
            dropped = store
        }
        XCTAssertNil(dropped, "the store went")
        for name in [UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
                     UIApplication.didBecomeActiveNotification, UserDefaults.didChangeNotification] {
            center.post(name: name, object: nil)
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(submits, 0)
    }

    /// Probe testCrashAnUnawaitedBackgroundEvaluationOutlivesItsStore: the zone check a run starts
    /// is not awaited, and it ran after the test had dropped its store.
    func testAZoneCheckThatOutlivesItsStoreTouchesNothing() async {
        do {
            let rig = LRig()
            await rig.tokenArrives()
            rig.service.reevaluate(.background)
        }
        for _ in 0..<100 { await Task.yield() }
    }

    // MARK: The consent table (the permissions review's 13 states by 13 entry points, cut down)

    /// For every state that has not given consent, or that may not be asked, no entry point prompts,
    /// asks iOS for a token, queues an upload or a removal, or submits a background request.
    func testNoEntryPointActsWithoutConsentOrWhenItMayNotAsk() async {
        enum State: CaseIterable { case noCredentialNoDuo, noCredentialLiveDuo, credentialNoDuo, restoreQuestion, disconnectedLaunch, revoked }
        enum Entry: CaseIterable { case launch, token, zone, clock, window, toggleOff, toggleOn, duoStarted, background, sceneBackground, noLiveDuo }
        var acted: [String] = []
        for state in State.allCases {
            for entry in Entry.allCases {
                let rig: LRig
                switch state {
                case .noCredentialNoDuo: rig = LRig(credential: nil, duos: [])
                case .noCredentialLiveDuo: rig = LRig(credential: nil)
                case .credentialNoDuo: rig = LRig(duos: [])
                case .restoreQuestion:
                    rig = LRig()
                    rig.identity.launch = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
                case .disconnectedLaunch:
                    rig = LRig()
                    rig.identity.launch = .disconnected
                case .revoked:
                    rig = LRig()
                    rig.kit.store.availability = .disconnected
                }
                switch entry {
                case .launch: await rig.post(UIApplication.didBecomeActiveNotification)
                case .token: await rig.tokenArrives()
                case .zone: rig.zone = "Europe/London"; await rig.post(.NSSystemTimeZoneDidChange)
                case .clock: await rig.post(UIApplication.significantTimeChangeNotification)
                case .window:
                    await rig.post(UserDefaults.didChangeNotification)
                    rig.window = (420, 1260)
                    await rig.post(UserDefaults.didChangeNotification)
                case .toggleOff: rig.kit.store.notificationsEnabled = false; await rig.settle()
                case .toggleOn:
                    rig.kit.store.notificationsEnabled = false
                    rig.kit.store.notificationsEnabled = true
                    await rig.settle()
                case .duoStarted: rig.service.reevaluate(.duoStarted); await rig.settle()
                case .background: await DuoBackground.handleAppRefresh(store: rig.kit.store); await rig.settle()
                case .sceneBackground: rig.kit.store.scheduleBackgroundRefresh(); await rig.settle()
                case .noLiveDuo: rig.service.noLiveDuoRemains(); await rig.settle()
                }
                // A shut-out phone is not woken either (review F21).
                let backgroundAllowed = state == .restoreQuestion || state == .disconnectedLaunch
                if rig.prompts > 0 || rig.registrations > 0 || !rig.queued.isEmpty || (!backgroundAllowed && !rig.submits.isEmpty) {
                    acted.append("\(state) / \(entry): prompts \(rig.prompts), registrations \(rig.registrations), queued \(rig.queued.map(\.kind)), submits \(rig.submits.count)")
                }
                if state == .noCredentialNoDuo || state == .noCredentialLiveDuo || state == .credentialNoDuo {
                    XCTAssertEqual(rig.identity.prepares, 0, "\(state) / \(entry): prepare() with nothing to ask it for")
                }
            }
        }
        XCTAssertTrue(acted.isEmpty, acted.joined(separator: "\n"))
    }
}

/// A number written on one thread and read on another.
private final class LockedSeconds: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = .infinity
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return seconds }
        set { lock.lock(); seconds = newValue; lock.unlock() }
    }
}
#endif
