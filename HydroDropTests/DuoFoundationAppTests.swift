#if DUO_V2
import XCTest
@testable import HydroDrop

/// The foundation's app-side tests: the cache, the store as a host, and the forwarding. Each
/// stage adds test files of its own beside this one and leaves it alone.
@MainActor
final class DuoFoundationAppTests: XCTestCase {
    private func makeCache() -> DuoCache {
        let suite = "DuoFoundationAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DuoCache(defaults: defaults)
    }

    // MARK: - The cache (the four storage tests that came back with it)

    func testTheCacheSurvivesARoundTrip() {
        let cache = makeCache()
        XCTAssertTrue(cache.loadDuos().isEmpty)
        var saved = DuoFixtures.duo()
        saved.statuses = [DuoFixtures.status(.owner, "2026-09-20", bucket: 100)]
        saved.vers = ["owner-2026-09-20": 3]
        cache.saveDuos([saved])
        XCTAssertEqual(cache.loadDuos(), [saved])
    }

    func testAnUnreadableCacheIsAnEmptyOneNotACrash() {
        let cache = makeCache()
        cache.defaults.set(Data("not json".utf8), forKey: DuoCache.statesKey)
        XCTAssertTrue(cache.loadDuos().isEmpty)
        cache.defaults.set(Data("not json".utf8), forKey: DuoCache.opsKey)
        XCTAssertTrue(cache.loadOps().isEmpty)
    }

    func testTheInflightJournalSurvivesALaunchAndIsWipedWithTheRest() {
        let cache = makeCache()
        var journal = cache.loadInflight()
        let key = journal.key(for: "create", body: Data("{}".utf8), now: Date(), random: TestRandom())
        cache.saveInflight(journal)
        var again = cache.loadInflight()
        XCTAssertEqual(again.key(for: "create", body: Data("{}".utf8), now: Date(), random: TestRandom()), key)
        cache.clearEverything()
        XCTAssertTrue(cache.loadInflight().entries.isEmpty)
    }

    func testTheLedgerSurvivesBeingSaved() {
        let cache = makeCache()
        var ledger = cache.loadLedger()
        XCTAssertTrue(ledger.markSeen("met|6d2a|2026-09-24"))
        cache.saveLedger(ledger)
        XCTAssertFalse(cache.loadLedger().seen.isEmpty)
        var again = cache.loadLedger()
        XCTAssertFalse(again.markSeen("met|6d2a|2026-09-24"))
    }

    func testNotificationsAreOnUntilTurnedOff() {
        let cache = makeCache()
        XCTAssertTrue(cache.notificationsEnabled)
        cache.notificationsEnabled = false
        XCTAssertFalse(cache.notificationsEnabled)
        cache.notificationsEnabled = true
        XCTAssertTrue(cache.notificationsEnabled)
    }

    func testEveryKeyIsNewAndNoneIsOneTheLegacyCleanupDeletes() {
        let legacy: Set<String> = ["duo.states.v1", "duo.myDisplayName", "duo.ledger.v1", "duo.notificationsOff", "duoInviteMoment.dismissed"]
        let all = [DuoCache.statesKey, DuoCache.ledgerKey, DuoCache.myDisplayNameKey, DuoCache.opsKey, DuoCache.pendingInviteKey,
                   DuoCache.rejectedDaysKey, DuoCache.diagnosticsKey, DuoCache.notificationsOffKey, DuoCache.inviteMomentDismissedKey,
                   DuoCache.memberKey, DuoCache.ageStatusKey, DuoCache.termsAcceptedKey, DuoCache.pushUploadKey, DuoCache.seenDevicesKey,
                   DuoCache.goalRaiseNoticeKey, DuoCache.inflightKey, DuoCache.clearedKey]
        XCTAssertTrue(legacy.isDisjoint(with: all))
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(DuoCache.statesKey, "duo.states.v2")
        XCTAssertEqual(DuoCache.ledgerKey, "duo.ledger.v2")
        XCTAssertEqual(DuoCache.myDisplayNameKey, "duo.myDisplayName.v2")
        XCTAssertEqual(DuoCache.opsKey, "duo.ops.v1")
        XCTAssertEqual(DuoCache.pendingInviteKey, "duo.pendingInvite")
    }

    func testWipingKeepsTheAgeAnswerAndTheSwitches() {
        let cache = makeCache()
        cache.saveDuos([DuoFixtures.duo()])
        cache.myDisplayName = "Jo"
        cache.saveOps([try! DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "k", now: Date())])
        cache.ageStatus = .allowed
        cache.notificationsEnabled = false
        cache.clearEverything()
        XCTAssertTrue(cache.loadDuos().isEmpty)
        XCTAssertEqual(cache.myDisplayName, "")
        XCTAssertTrue(cache.loadOps().isEmpty)
        XCTAssertEqual(cache.ageStatus, .allowed)
        XCTAssertFalse(cache.notificationsEnabled)
    }

    // MARK: - The store as a host

    func testAChangeToADuoIsSavedAndTheWidgetIsTold() {
        let cache = makeCache()
        var reloads = 0
        let store = DuoStore(cache: cache, usesServer: true, reloadWidget: { reloads += 1 })
        store.upsert(DuoFixtures.duo())
        XCTAssertEqual(reloads, 1)
        store.update(DuoFixtures.duoID) { $0.cursor = 9 }
        XCTAssertEqual(store.duos.first?.cursor, 9)
        XCTAssertEqual(DuoStore(cache: cache, reloadWidget: {}).duos.first?.cursor, 9, "a second store reads what the first saved")
        store.update(DuoFixtures.duoID) { $0.cursor = 9 }
        XCTAssertEqual(reloads, 2, "a change that changed nothing is not a save")
        store.update(UUID()) { $0.cursor = 1 }
        XCTAssertEqual(reloads, 2)
        store.remove(DuoFixtures.duoID)
        XCTAssertTrue(store.duos.isEmpty)
        XCTAssertTrue(cache.loadDuos().isEmpty)
    }

    func testUpsertReplacesInPlaceAndAppendsTheRest() {
        let store = DuoStore(cache: makeCache(), reloadWidget: {})
        let other = UUID()
        store.upsert(DuoFixtures.duo())
        store.upsert(DuoFixtures.duo(id: other, partner: "Alex"))
        var changed = DuoFixtures.duo()
        changed.cursor = 4
        store.upsert(changed)
        XCTAssertEqual(store.duos.map(\.id), [DuoFixtures.duoID, other])
        XCTAssertEqual(store.duos[0].cursor, 4)
    }

    func testThePendingInviteIsKeptAcrossALaunchAndDroppedWhenItExpires() {
        let cache = makeCache()
        let store = DuoStore(cache: cache, reloadWidget: {})
        store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date())
        XCTAssertEqual(DuoStore(cache: cache, reloadWidget: {}).pendingInvite?.code, "H7K39QWX")
        store.pendingInvite = nil
        XCTAssertNil(DuoStore(cache: cache, reloadWidget: {}).pendingInvite)
        cache.savePendingInvite(DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date().addingTimeInterval(-49 * 3600)))
        XCTAssertNil(DuoStore(cache: cache, reloadWidget: {}).pendingInvite, "a code received 49 hours ago is gone")
    }

    // MARK: - Review fixes (plan P2, second critique)

    func testWhatTheServerSaidAboutThisMemberSurvivesALaunch() {
        let cache = makeCache()
        let store = DuoStore(cache: cache, reloadWidget: {})
        XCTAssertEqual(store.nudgesPerDay, 3)
        let info = DuoMemberInfo(memberID: "m", displayName: "Jo", skin: "forest", supportID: "ABCD1234EFGH", tier: .low, termsVersion: 1,
                                 nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        store.memberInfo = info
        let relaunched = DuoStore(cache: cache, reloadWidget: {})
        XCTAssertEqual(relaunched.memberInfo, info, "the Support ID and the tier are known before the next GET /me")
        XCTAssertEqual(relaunched.nudgesPerDay, 1, "a low-tier member's limit is not three until the server says so again")
        XCTAssertEqual(relaunched.memberInfo?.supportIDDisplay, "ABCD-1234-EFGH")
        store.memberInfo = nil
        XCTAssertNil(DuoStore(cache: cache, reloadWidget: {}).memberInfo)
        store.memberInfo = info
        cache.clearEverything()
        XCTAssertNil(DuoStore(cache: cache, reloadWidget: {}).memberInfo, "a wipe takes it too")
    }

    func testAClearedDuoIsRememberedAndAWipeForgetsIt() {
        let cache = makeCache()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(cache.isCleared(DuoFixtures.duoID, now: now))
        cache.markCleared(DuoFixtures.duoID, now: now)
        XCTAssertTrue(cache.isCleared(DuoFixtures.duoID, now: now.addingTimeInterval(86_400)))
        XCTAssertFalse(cache.isCleared(UUID(), now: now))
        XCTAssertFalse(cache.isCleared(DuoFixtures.duoID, now: now.addingTimeInterval(DuoProtocolConstants.endedDuoLifetime + 1)),
                       "the server no longer lists it by then")
        cache.clearEverything()
        XCTAssertFalse(cache.isCleared(DuoFixtures.duoID, now: now))
    }

    func testARefusalSurvivesDeletingTheAppAndStartingFresh() throws {
        let secretStore = DuoMemorySecretStore()
        let first = DuoTestKit(secretStore: secretStore)
        XCTAssertEqual(first.store.recordBirthYear(2020, now: first.clock.now), .refused)
        XCTAssertTrue(first.dependencies.secrets.isAgeRefused())
        XCTAssertEqual(secretStore.accounts(service: DuoSecrets.ageService), [DuoSecrets.ageRefusedAccount], "only the fact is kept, as one byte")
        // The app is deleted and installed again: new defaults, same Keychain.
        let reinstalled = DuoTestKit(secretStore: secretStore)
        XCTAssertEqual(reinstalled.store.ageStatus, .refused, "the defaults went with the app, the Keychain did not")
        XCTAssertEqual(reinstalled.store.recordBirthYear(1990, now: reinstalled.clock.now), .refused, "no second try")
        // Delete my Duo data and Start fresh wipe Duo's own service and leave the refusal.
        try reinstalled.dependencies.secrets.deleteEverything()
        reinstalled.dependencies.cache.clearEverything()
        XCTAssertTrue(reinstalled.dependencies.secrets.isAgeRefused())
        XCTAssertEqual(DuoTestKit(secretStore: secretStore).store.ageStatus, .refused)
        // An adult answer is not remembered in the Keychain at all.
        let adult = DuoTestKit()
        XCTAssertEqual(adult.store.recordBirthYear(1990, now: adult.clock.now), .allowed)
        XCTAssertFalse(adult.dependencies.secrets.isAgeRefused())
        XCTAssertTrue(adult.secretStore.accounts(service: DuoSecrets.ageService).isEmpty)
    }

    func testTheIdentityRowsAreDrawnInThePreviewForAPhoneWithDuosAndNotForOneWithout() {
        XCTAssertTrue(DuoStore.makePreview(scenario: "sample").hasIdentity, "Diagnostics and Delete my Duo data must be reachable to look at")
        XCTAssertTrue(DuoStore.makePreview(scenario: "disconnected").hasIdentity)
        XCTAssertTrue(DuoStore.makePreview(scenario: "banned").hasIdentity)
        XCTAssertFalse(DuoStore.makePreview(scenario: "empty").hasIdentity)
        XCTAssertFalse(DuoStore.makePreview(scenario: "restore").hasIdentity)
        let kit = DuoTestKit()
        XCTAssertFalse(kit.store.hasIdentity)
        kit.identity.credential = DuoFixtures.credential()
        XCTAssertTrue(kit.store.hasIdentity, "a real store answers from the credential, whatever the duos")
    }

    #if DEBUG
    func testADebugBuildMayClaimAnotherVersionForTheStagingLoopAndNothingElse() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.8.1", "CFBundleVersion": "34"]
        XCTAssertEqual(DuoConfig.client(info: info, arguments: []).clientHeader, "ios/1.8.1 (34)")
        XCTAssertEqual(DuoConfig.client(info: info, arguments: ["-DuoClientVersion", "2.0"]).clientHeader, "ios/2.0 (34)",
                       "staging's MIN_CLIENT_IOS is 2.0, so the first write of the loop would be a 426 without it")
        XCTAssertEqual(DuoConfig.client(info: info, arguments: ["-DuoClientVersion", "2.0.1"]).appVersion, "2.0.1 (34)")
        for bad in ["", "2", "2.", "v2.0", "2.0 (57)", "2.0.0.1", "-UITestSkipOnboarding"] {
            XCTAssertEqual(DuoConfig.client(info: info, arguments: ["-DuoClientVersion", bad]).marketingVersion, "1.8.1", bad)
        }
        XCTAssertEqual(DuoConfig.client(info: info, arguments: ["-DuoClientVersion"]).marketingVersion, "1.8.1", "no value after the flag")
        XCTAssertEqual(DuoConfig.client(info: nil, arguments: []).clientHeader, "ios/0.0 (0)")
    }
    #endif

    func testACloudflarePageThatCarriesOnlyARayStillLeavesSomethingToQuote() async throws {
        let recording = RecordingSession()
        let seen = SeenResponses()
        let observed = DuoObservedSession(base: recording) { status, id in seen.add(status, id) }
        let url = URL(string: "https://api-staging.hydrodrop.us/v1/me")!
        var headers: [String: String] = ["CF-Ray": "8f1a2b3c4d5e6f70-AMS"]
        recording.respond = { _ in (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers)!) }
        let request = URLRequest(url: url)
        _ = try await observed.data(for: request)
        headers["X-Request-Id"] = "9b1c2d3e4f5a6b7c-LHR"
        _ = try await observed.data(for: request)
        headers["X-Request-Id"] = "has spaces & <tags>"
        _ = try await observed.data(for: request)
        XCTAssertEqual(seen.all, ["403:8f1a2b3c4d5e6f70-AMS", "403:9b1c2d3e4f5a6b7c-LHR", "403:8f1a2b3c4d5e6f70-AMS"],
                       "the server's own id wins when both are there, and an unusable one gives way to the ray")
    }

    func testEveryResponseLeavesItsRequestIDAndAFailedOneLeavesNothing() async throws {
        let recording = RecordingSession()
        let seen = SeenResponses()
        let observed = DuoObservedSession(base: recording) { status, id in seen.add(status, id) }
        let url = URL(string: "https://api-staging.hydrodrop.us/v1/me")!
        recording.respond = { request in
            let ok = request.httpMethod == "GET"
            let headers = ok ? ["X-Request-Id": "9b1c2d3e4f5a6b7c-LHR"] : [:]
            return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: ok ? 200 : 503, httpVersion: nil, headerFields: headers)!)
        }
        var get = URLRequest(url: url); get.httpMethod = "GET"
        var post = URLRequest(url: url); post.httpMethod = "POST"
        let (data, response) = try await observed.data(for: get)
        XCTAssertEqual(data, Data("{}".utf8), "the response is passed through untouched")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        _ = try await observed.data(for: post)
        XCTAssertEqual(seen.all, ["200:9b1c2d3e4f5a6b7c-LHR", "503:nil"])
        recording.respond = nil
        do { _ = try await observed.data(for: get); XCTFail("a lost connection is still an error") } catch {}
        XCTAssertEqual(seen.all.count, 2, "no response, nothing to note")
        var diagnostics = DuoDiagnostics()
        diagnostics.recordRequest(status: 200, requestID: "9b1c2d3e4f5a6b7c-LHR", at: Date())
        diagnostics.recordRequest(status: 503, requestID: nil, at: Date())
        XCTAssertEqual(diagnostics.recentRequests.count, 1)
        let kit = DuoTestKit()
        XCTAssertNil(kit.store.lastRequestID)
        kit.store.diagnostics = diagnostics
        XCTAssertEqual(kit.store.lastRequestID, "9b1c2d3e4f5a6b7c-LHR")
        XCTAssertEqual(DuoStore(cache: DuoCache(defaults: kit.defaults), reloadWidget: {}).lastRequestID, "9b1c2d3e4f5a6b7c-LHR", "kept across a launch")
    }

    // MARK: - Derived state

    func testMyOwnSideIsDrawnFromTheLogNotFromWhatWasSent() {
        let kit = DuoTestKit()
        let today = kit.clock.today
        kit.store.upsert(DuoFixtures.duo())
        kit.store.latest = DuoLogSummary(totalsByDay: [today: 1000], goalML: 2000, earliestEntryDay: nil)
        let duo = kit.store.duos[0]
        let mine = kit.store.status(of: .owner, in: duo, now: kit.clock.now)
        XCTAssertEqual(mine?.progressBucket, 50)
    }

    func testTheNudgeLimitComesFromTheServersAnswerForThisMember() {
        let kit = DuoTestKit()
        let duo = DuoFixtures.duo(now: kit.clock.now)
        kit.store.upsert(duo)
        XCTAssertEqual(kit.store.nudgesPerDay, 3)
        var info = DuoMemberInfo(memberID: "m", displayName: nil, skin: nil, supportID: "ABCD1234EFGH", tier: .low, termsVersion: 1,
                                 nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: kit.clock.now)
        kit.store.memberInfo = info
        XCTAssertEqual(kit.store.nudgeVerdict(for: duo, now: kit.clock.now), .allowed(remaining: 1))
        info.nudgesPerDay = 3
        kit.store.memberInfo = info
        XCTAssertEqual(kit.store.nudgeVerdict(for: duo, now: kit.clock.now), .allowed(remaining: 3))
    }

    func testTheShareLinkCarriesTheSecretFromTheKeychain() throws {
        let kit = DuoTestKit()
        var duo = DuoFixtures.duo(joined: false)
        duo.invite = DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: kit.clock.now.addingTimeInterval(3600))
        kit.store.upsert(duo)
        XCTAssertEqual(kit.store.shareURL(for: duo)?.absoluteString, "https://hydrodrop.us/duo#H7K39QWX")
        let secret = DuoLinkSecret.make(random: kit.random)
        try kit.dependencies.secrets.saveLinkSecret(secret, forDuo: duo.id)
        XCTAssertEqual(kit.store.shareURL(for: duo)?.absoluteString, "https://hydrodrop.us/duo#H7K39QWX.\(secret)")
    }

    func testTheLogSummaryKeepsTheLastWeekAndTheOldestDay() {
        let kit = DuoTestKit()
        let now = kit.clock.now
        let old = now.addingTimeInterval(-86_400 * 40)
        let recent = now.addingTimeInterval(-3600)
        kit.store.logChanged(entries: [WaterEntry(amountML: 300, timestamp: old), WaterEntry(amountML: 500, timestamp: recent)], goalML: 2000, now: now)
        let summary = kit.store.latest
        XCTAssertEqual(summary?.totalsByDay[DayKey.key(for: recent)], 500)
        XCTAssertNil(summary?.totalsByDay[DayKey.key(for: old)], "only the last nine days are kept")
        XCTAssertEqual(summary?.earliestEntryDay, DayKey.key(for: old))
        XCTAssertEqual(kit.sync.summaries.count, 1)
    }

    func testANicknameIsCleanedAndKeptOnThisPhone() {
        let kit = DuoTestKit()
        kit.store.upsert(DuoFixtures.duo())
        kit.store.setNickname("  Sammy \n", for: DuoFixtures.duoID)
        XCTAssertEqual(kit.store.duos[0].partnerNickname, "Sammy")
        XCTAssertEqual(kit.store.duos[0].displayName(of: .partner), "Sammy")
        kit.store.setNickname("   ", for: DuoFixtures.duoID)
        XCTAssertNil(kit.store.duos[0].partnerNickname)
    }

    func testTheBirthYearScreenKeepsOnlyTheAnswerAndARefusalIsFinal() {
        let kit = DuoTestKit()
        let now = kit.clock.now
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        XCTAssertEqual(kit.store.recordBirthYear(1800, now: now), .unknown)
        XCTAssertEqual(kit.store.recordBirthYear(2020, now: now), .refused)
        XCTAssertEqual(kit.store.recordBirthYear(1990, now: now), .refused, "no second try")
        XCTAssertEqual(DuoStore(cache: DuoCache(defaults: kit.defaults), reloadWidget: {}).ageStatus, .refused)
    }

    // MARK: - Forwarding

    func testOnlyTheDuoScreenOpeningAsksTheIdentityWithoutADuo() async {
        let kit = DuoTestKit()
        await kit.store.refresh()
        XCTAssertEqual(kit.identity.prepared, 0, "a refresh alone never asks the identity: it cannot tell a foreground from the screen")
        await kit.store.duoScreenOpened()
        XCTAssertEqual(kit.identity.prepared, 1, "the Duo screen opening is the one time an unsettled phone is asked about")
        XCTAssertEqual(kit.sync.calls, ["refresh", "refresh"], "and it then reads like any refresh")
    }

    func testTheStoreAsksItsServicesAndDoesNothingItself() async {
        let kit = DuoTestKit()
        let duo = DuoFixtures.duo()
        await kit.store.refresh()
        _ = await kit.store.backgroundRefresh()
        await kit.store.sendNudge(.cheers, in: duo)
        _ = await kit.store.createDuo(named: "Jo")
        await kit.store.leave(duo)
        await kit.store.block(duo)
        kit.store.clear(duo)
        _ = await kit.store.deleteMyData()
        kit.store.startFresh()
        kit.store.scheduleBackgroundRefresh()
        kit.store.pushTokenArrived(Data([1]), environment: .sandbox)
        XCTAssertEqual(kit.sync.calls, ["refresh", "backgroundRefresh", "sendNudge:cheers"])
        XCTAssertEqual(kit.joining.calls, ["createDuo:Jo:classic"], "the skin is the active one")
        XCTAssertEqual(kit.exiting.calls, ["leave", "block", "clear", "deleteMyData", "startFresh"])
        XCTAssertEqual(kit.background.scheduled, 1)
        XCTAssertEqual(kit.push.tokens, [Data([1])])
    }

    func testTheNotificationsToggleChangesWhatIsUploadedNotTheToken() {
        let kit = DuoTestKit()
        kit.store.notificationsEnabled = false
        XCTAssertEqual(kit.push.reasons, [.toggleChanged])
        XCTAssertFalse(DuoCache(defaults: kit.defaults).notificationsEnabled)
        kit.store.notificationsEnabled = false
        XCTAssertEqual(kit.push.reasons, [.toggleChanged], "no change, no upload")
    }

    func testTheLimitOnDuosFollowsTheSubscription() {
        let kit = DuoTestKit()
        kit.store.upsert(DuoFixtures.duo())
        XCTAssertFalse(kit.store.canAddDuo(isSubscribed: false))
        XCTAssertTrue(kit.store.canAddDuo(isSubscribed: true))
        kit.store.upsert(DuoFixtures.duo(id: UUID(), ended: true))
        XCTAssertEqual(kit.store.activeDuos.count, 1, "an ended duo takes no place")
    }
}

/// What an observer was told, collected from a `@Sendable` closure.
final class SeenResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ status: Int, _ id: String?) { lock.lock(); seen.append("\(status):\(id ?? "nil")"); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

@MainActor
final class DuoCompositionTests: XCTestCase {
    func testTheWholeWiringBuildsAndOpeningTheScreenSendsNothing() async {
        let session = RecordingSession()
        let suite = "DuoCompositionTests.\(UUID().uuidString)"
        let cache = DuoCache(defaults: UserDefaults(suiteName: suite)!)
        let store = DuoComposition.makeLiveStore(session: session, secretStore: DuoMemorySecretStore(), cache: cache)
        let dependencies = try! XCTUnwrap(store.dependencies)
        XCTAssertNotNil(dependencies.identity)
        XCTAssertNotNil(dependencies.sync)
        XCTAssertNotNil(dependencies.joining)
        XCTAssertNotNil(dependencies.exiting)
        XCTAssertNotNil(dependencies.ops)
        XCTAssertNotNil(dependencies.push)
        XCTAssertNotNil(dependencies.announcer)
        XCTAssertNotNil(dependencies.background)
        XCTAssertFalse(store.hasIdentity)
        await store.refresh()
        _ = await store.backgroundRefresh()
        XCTAssertTrue(session.requests.isEmpty, "no request leaves the phone before a Create, Join or Reconnect tap (final design §3.1)")
    }
}

@MainActor
final class DuoServiceSupportTests: XCTestCase {
    private func failure(_ code: DuoErrorCode, status: Int = 400, retryAfter: Int? = nil) -> DuoTransportError {
        DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "r1", retryAfter: retryAfter))
    }

    func testAFailureIsRecordedAndActedOn() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.upgradeRequired)), .upgradeRequired)
        XCTAssertEqual(kit.store.availability, .upgradeRequired)
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.deviceRevoked)), .disconnected)
        XCTAssertEqual(kit.store.availability, .disconnected)
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.banned)), .banned)
        XCTAssertEqual(kit.store.availability, .banned)
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.termsRequired)), .termsRequired)
        XCTAssertTrue(kit.store.needsTerms)
        XCTAssertEqual(kit.store.diagnostics.recentErrors.first?.code, "terms_required")
        XCTAssertEqual(kit.store.diagnostics.recentErrors.first?.requestID, "r1")
    }

    func testAnUnknownIdentityIsForgottenAndAServicePauseIsNoted() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.unauthenticated, status: 401)), .reidentify)
        XCTAssertEqual(kit.identity.discardCount, 1)
        XCTAssertNil(kit.identity.credential)
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.maintenance)), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(kit.store.availability, .maintenance)
        kit.dependencies.noteSuccess()
        XCTAssertEqual(kit.store.availability, .available)
        kit.store.availability = .upgradeRequired
        kit.dependencies.noteSuccess()
        XCTAssertEqual(kit.store.availability, .upgradeRequired, "a read that worked does not lift an upgrade requirement")
    }

    func testAnIdentityTheServerForgotFinishesADeleteTheAnswerOfWhichWasLost() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.unauthenticated, status: 401)), .reidentify)
        XCTAssertFalse(kit.exiting.calls.contains("startFresh"), "an identity that was never asked to be deleted is only forgotten")
        kit.dependencies.cache.deleteRequestedAt = kit.clock.now
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.unauthenticated, status: 401)), .reidentify)
        XCTAssertEqual(kit.exiting.calls.filter { $0 == "startFresh" }.count, 1,
                       "the person asked for everything to go and the identity being gone is the answer: finish the wipe")
    }

    func testAThrowawayCredentialBehindCachedDuosStillReadsAsDisconnectedAfterARelaunch() throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let throwaway = try XCTUnwrap(kit.identity.credential).deviceID
        kit.dependencies.cache.saveDuos([DuoFixtures.duo()])

        func relaunch() -> DuoStore {
            let store = DuoStore(cache: DuoCache(defaults: kit.defaults), reloadWidget: {})
            store.install(kit.dependencies)
            return store
        }
        XCTAssertEqual(relaunch().availability, .unknown, "no marker, nothing to say")
        kit.dependencies.cache.throwawayDeviceID = throwaway
        XCTAssertEqual(relaunch().availability, .disconnected, "the stored credential is the throwaway and live duos belong to someone else")
        kit.dependencies.cache.saveDuos([DuoFixtures.duo(ended: true)])
        XCTAssertEqual(relaunch().availability, .unknown, "no live duo, nothing to be disconnected from")
        kit.dependencies.cache.saveDuos([DuoFixtures.duo()])
        kit.dependencies.cache.throwawayDeviceID = "some-other-device"
        XCTAssertEqual(relaunch().availability, .unknown, "the credential is not the throwaway")
        XCTAssertNil(kit.dependencies.cache.throwawayDeviceID, "a marker for a credential that is gone is dropped")
    }

    func testTheDeleteRequestedMarkerIsADateAndNothingElse() {
        let defaults = UserDefaults(suiteName: "DuoDeleteMarker.\(UUID().uuidString)")!
        let cache = DuoCache(defaults: defaults)
        XCTAssertNil(cache.deleteRequestedAt)
        let moment = Date(timeIntervalSince1970: 1_790_000_000)
        cache.deleteRequestedAt = moment
        XCTAssertEqual(cache.deleteRequestedAt, moment)
        XCTAssertTrue(DuoCache.wipedKeys.contains(DuoCache.deleteRequestedKey), "a wipe removes it")
        XCTAssertFalse(DuoCache.keptKeys.contains(DuoCache.deleteRequestedKey))
        cache.clearEverything()
        XCTAssertNil(cache.deleteRequestedAt)
        cache.deleteRequestedAt = moment
        cache.deleteRequestedAt = nil
        XCTAssertNil(cache.deleteRequestedAt)
    }

    func testAnIdentityTheServerForgotTakesTheLiveDuosAndEverythingMadeWithItDown() throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let live = DuoFixtures.duo()
        let ended = DuoFixtures.duo(id: UUID(), ended: true)
        kit.store.upsert(live)
        kit.store.upsert(ended)
        try kit.dependencies.secrets.saveLinkSecret("K", forDuo: live.id)
        try kit.dependencies.secrets.saveLinkSecret("K2", forDuo: ended.id)
        kit.ops.enqueue(try DuoQueuedOp.leave(duoID: live.id, key: "k", now: kit.clock.now))
        var journal = DuoInflightJournal()
        _ = journal.key(for: "createDuo", body: Data("{}".utf8), now: kit.clock.now, random: kit.random)
        kit.dependencies.cache.saveInflight(journal)
        kit.dependencies.cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: nil,
                                                                 windowEnd: nil, enabled: true, uploadedAt: kit.clock.now))
        XCTAssertEqual(kit.dependencies.noteFailure(failure(.unauthenticated, status: 401), duoID: live.id), .reidentify)
        XCTAssertNil(kit.identity.credential)
        let after = try XCTUnwrap(kit.store.duo(live.id))
        XCTAssertTrue(after.hasEnded)
        XCTAssertEqual(after.endedBy, .unknown, "no alert and no claim about who ended it, as for duo_unknown")
        XCTAssertNil(after.invite)
        XCTAssertEqual(kit.store.duo(ended.id)?.endedBy, .partner, "an ended duo keeps what it said")
        XCTAssertNil(kit.dependencies.secrets.linkSecret(forDuo: live.id))
        XCTAssertNil(kit.dependencies.secrets.linkSecret(forDuo: ended.id))
        XCTAssertEqual(kit.ops.discards, 1)
        XCTAssertTrue(kit.ops.pending.isEmpty)
        XCTAssertTrue(kit.dependencies.cache.loadInflight().entries.isEmpty)
        XCTAssertNil(kit.dependencies.cache.loadPushUpload())
        XCTAssertEqual(kit.push.clearedLast, 0, "the token row belonged to the device the server forgot: nothing to unregister")
        XCTAssertTrue(kit.store.canAddDuo(isSubscribed: false), "an ended duo takes no place, so the person can start again")
    }

    func testAnUnauthenticatedThatNeverReachedTheServerForgetsNothing() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let local = DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0))
        XCTAssertEqual(kit.dependencies.noteFailure(local), .fail)
        XCTAssertEqual(kit.identity.discardCount, 0, "the client's own 'no credential' error is not the server forgetting this identity")
        XCTAssertNotNil(kit.identity.credential)
    }

    func testACancelledTaskLeavesNoTraceAndChangesNothing() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.availability = .available
        XCTAssertEqual(kit.dependencies.noteFailure(CancellationError()), .cancelled)
        XCTAssertTrue(kit.store.diagnostics.recentErrors.isEmpty, "a cancelled refresh is not a failure to report")
        XCTAssertEqual(kit.store.availability, .available)
        XCTAssertEqual(kit.identity.discardCount, 0)
    }

    func testNoConnectionIsNotAnAvailabilityProblem() {
        let kit = DuoTestKit()
        kit.store.availability = .available
        XCTAssertEqual(kit.dependencies.noteFailure(DuoTransportError.offline), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(kit.store.availability, .available)
    }

    func testTheFirstRowsAreTheOutboxAtBaseVersionZero() {
        let kit = DuoTestKit()
        let today = kit.clock.today
        kit.store.latest = DuoLogSummary(totalsByDay: [today: 1500], goalML: 2000, earliestEntryDay: "2026-01-01")
        let rows = kit.dependencies.firstRows(role: .owner, now: kit.clock.now)
        XCTAssertEqual(rows.first, DuoWireStatusIn(day: today, goalMet: false, progressBucket: 75, baseVer: 0))
        XCTAssertTrue(rows.allSatisfy { $0.baseVer == 0 })
        XCTAssertLessThanOrEqual(rows.count, 7)
        XCTAssertEqual(kit.dependencies.cleanedNameOrNil("  Jo \n"), "Jo")
        XCTAssertNil(kit.dependencies.cleanedNameOrNil("  \u{200B} "))
        XCTAssertNil(kit.dependencies.cleanedNameOrNil(nil))
    }

    func testTheNoticeCardsDrawOnlyWhenThereIsSomethingToSay() {
        let store = DuoStore.makePreview(duos: [])
        store.availability = .available
        XCTAssertFalse(store.hasNoticeCards)
        store.availability = .unknown
        XCTAssertFalse(store.hasNoticeCards)
        for availability in [DuoAvailability.maintenance, .upgradeRequired, .disconnected, .banned,
                             .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))] {
            store.availability = availability
            XCTAssertTrue(store.hasNoticeCards, "\(availability)")
        }
        store.availability = .available
        store.newDeviceNotice = true
        XCTAssertTrue(store.hasNoticeCards)
    }

    func testEveryPreviewScenarioBuildsAndSaysWhatItIsFor() {
        for name in DuoStore.previewScenarioNames {
            let store = DuoStore.makePreview(scenario: name)
            XCTAssertFalse(store.usesServer, name)
            switch name {
            case "empty", "restore": XCTAssertTrue(store.duos.isEmpty, name)
            case "endedall": XCTAssertEqual(store.duos.filter(\.hasEnded).count, 7, name)
            case "full": XCTAssertEqual(store.activeDuos.count, DuoLimit.plusDuoCount, name)
            case "waiting": XCTAssertTrue(store.duos.first?.isPending == true, name)
            case "justjoined": XCTAssertTrue(store.duos.first?.showsNotThemCard(now: Date()) == true, name)
            case "silent": XCTAssertTrue(store.duos.first?.offersReconnect(myToday: DayKey.key(for: Date())) == true, name)
            case "demo": XCTAssertTrue(store.duos.first?.partnerIsDemo == true, name)
            case "streak100":
                let duo = store.duos[0]
                XCTAssertTrue(store.reachedRetentionEdge(of: duo), name)
            default: XCTAssertFalse(store.duos.isEmpty, name)
            }
        }
        XCTAssertTrue(DuoStore.makePreview(scenario: "restore").hasNoticeCards)
        XCTAssertTrue(DuoStore.makePreview(scenario: "maintenance").hasNoticeCards)
        XCTAssertFalse(DuoStore.makePreview(scenario: "sample").hasNoticeCards)
        XCTAssertEqual(DuoStore.makePreview(scenario: "nonsense").duos.count, DuoStore.makePreview().duos.count)
    }
}

// MARK: - Redirects

/// Counts the requests a stubbed network was asked for, whichever thread it was asked on.
final class RedirectLog: @unchecked Sendable {
    static let shared = RedirectLog()
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    func reset() { lock.lock(); urls = []; lock.unlock() }
    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return urls.compactMap(\.host) }
}

/// Answers `api.example.test` with a 302 to another host, carrying the bearer along the way a
/// followed redirect would, and anything else with a 200.
final class RedirectingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        RedirectLog.shared.record(url)
        if url.host == "api.example.test" {
            let target = URL(string: "https://elsewhere.example.test/collect")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target)
            next.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // When the session's delegate declines, nothing else delivers the 302, so the stub
            // hands it over itself, as a real server's answer would arrive. When the session
            // follows, it stops this load at once and asks the other host, and delivering the 302
            // as well would make a followed redirect look like a refused one: so only after a
            // moment, and only if this load was not stopped.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.wasStopped else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("followed".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private let stoppedLock = NSLock()
    private var stopped = false
    private var wasStopped: Bool { stoppedLock.lock(); defer { stoppedLock.unlock() }; return stopped }

    override func stopLoading() {
        stoppedLock.lock(); stopped = true; stoppedLock.unlock()
    }
}

final class DuoRedirectTests: XCTestCase {
    func testARedirectIsAnAnswerNotAnErrandAndTheBearerNeverLeavesForAnotherHost() async throws {
        RedirectLog.shared.reset()
        let http = URLSessionHTTP(session: URLSessionHTTP.makeDefaultSession(protocolClasses: [RedirectingURLProtocol.self]))
        var request = URLRequest(url: URL(string: "https://api.example.test/v1/me")!)
        request.setValue("Bearer not-a-real-secret", forHTTPHeaderField: "Authorization")
        let (_, response) = try await http.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302, "the 302 itself comes back, for the client to read as not the contract's")
        XCTAssertEqual(RedirectLog.shared.hosts, ["api.example.test"], "the Location was never asked for, so the Authorization header never went there")
    }

    func testTheSessionTheAppUsesCarriesTheRefuser() {
        XCTAssertTrue(URLSessionHTTP.makeDefaultSession().delegate is DuoRedirectRefuser)
    }

    func testTheRefuserAnswersNoToAnyRedirect() throws {
        let session = URLSessionHTTP.makeDefaultSession()
        let url = URL(string: "https://api.example.test/v1/me")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": "https://elsewhere.example.test/"])!
        let answered = expectation(description: "the delegate answered")
        var followed: URLRequest?? = .some(URLRequest(url: url))
        DuoRedirectRefuser().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { request in
            followed = .some(request)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        XCTAssertNil(try XCTUnwrap(followed), "nil tells the session to hand back the 3xx and send nothing again")
    }
}
#endif
