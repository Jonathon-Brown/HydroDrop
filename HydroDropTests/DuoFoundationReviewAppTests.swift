#if DUO_V2
import XCTest
@testable import HydroDrop

/// Counts DeviceCheck tokens asked for, so a test of the composed app can show none was before a tap.
final class DuoReviewCountingDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isSupported: Bool { true }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func bump() { lock.lock(); count += 1; lock.unlock() }
    func token() async -> String? { bump(); return "RGV2aWNlQ2hlY2s=" }
}

/// A secret store that holds nothing and records every write under every service, so a test can
/// say "no Keychain item was written, whatever it was called". Counting the accounts under the
/// two services Duo knows would miss a write under a third.
final class DuoReviewSpySecretStore: DuoSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var removed: [String] = []
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return written }
    /// Every delete, one by one or a whole service, so a launch that clears an item it should not
    /// touch is as visible as one that writes.
    var deletes: [String] { lock.lock(); defer { lock.unlock() }; return removed }
    private func record(_ item: String) { lock.lock(); written.append(item); lock.unlock() }
    private func recordDelete(_ item: String) { lock.lock(); removed.append(item); lock.unlock() }
    func read(service: String, account: String) throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws { record("\(service)/\(account)") }
    func delete(service: String, account: String) throws { recordDelete("\(service)/\(account)") }
    func deleteAll(service: String) throws { recordDelete("\(service)/*") }
}

/// What the independent review of the foundation found in the app target (consent, secrets and
/// age; flag-off and wipe), each pinned by a test. Kept apart from `DuoFoundationAppTests` so a
/// stage's merge never touches either.
@MainActor
final class DuoFoundationReviewAppTests: XCTestCase {
    private func memberInfo() -> DuoMemberInfo {
        DuoMemberInfo(memberID: "m", displayName: "Jo", skin: "forest", supportID: "ABCD1234EFGH", tier: .low, termsVersion: 1,
                      nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "DuoFoundationReviewAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Every key Duo keeps in the defaults is named `duo...` (or `duoInviteMoment...`).
    private func duoKeys(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("duo") })
    }

    /// Writes something under every key `DuoCache` knows, the ones a wipe keeps included.
    private func seedEveryKey(_ kit: DuoTestKit) async throws {
        let store = kit.store
        let cache = kit.dependencies.cache
        let duoID = DuoFixtures.duoID
        store.myDisplayName = "Jo"
        _ = await store.acceptTerms()
        store.diagnostics.recordRequest(status: 200, requestID: "old-request", at: kit.clock.now)
        store.memberInfo = memberInfo()
        store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: kit.clock.now)
        store.upsert(DuoFixtures.duo())
        var ledger = DuoLedger()
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: duoID, day: "2026-10-06"))
        cache.saveLedger(ledger)
        cache.saveOps([try DuoQueuedOp.leave(duoID: duoID, key: "k", now: kit.clock.now)])
        cache.saveRejectedDays([duoID.uuidString.lowercased(): DuoRejectedDays(rows: ["2026-10-06": DuoFixtures.status(.owner, "2026-10-06", bucket: 100)])])
        cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: nil, windowEnd: nil,
                                                enabled: true, uploadedAt: kit.clock.now))
        cache.saveSeenDeviceIDs(["old-device"])
        var journal = DuoInflightJournal()
        _ = journal.key(for: "POST /duos", body: Data("{}".utf8), now: kit.clock.now, random: kit.random)
        cache.saveInflight(journal)
        cache.markCleared(UUID(), now: kit.clock.now)
        cache.deleteRequestedAt = kit.clock.now
        cache.throwawayDeviceID = "throwaway-device"
        // The four a wipe keeps.
        store.notificationsEnabled = false
        cache.inviteMomentDismissed = true
        cache.goalRaiseNoticeShown = true
        XCTAssertEqual(store.recordBirthYear(1990, now: kit.clock.now), .allowed)
    }

    // MARK: - The wipe

    func testAWipeLeavesNothingButWhatItKeepsInMemoryOrOnDisk() async throws {
        let kit = DuoTestKit()
        let store = kit.store
        try await seedEveryKey(kit)
        XCTAssertTrue(Set(DuoCache.allKeys).isSubset(of: duoKeys(kit.defaults)),
                      "the seed must write every key DuoCache has, or a new key could be forgotten by the wipe unseen")
        store.needsTerms = true
        store.newDeviceNotice = true
        let before = store.wipeEpoch

        store.resetLocalState()

        XCTAssertEqual(store.myDisplayName, "", "the setup sheet must not pre-fill a name the person just deleted")
        XCTAssertEqual(store.acceptedTermsVersion, 0, "or skip the terms step")
        XCTAssertTrue(store.duos.isEmpty)
        XCTAssertNil(store.memberInfo)
        XCTAssertNil(store.pendingInvite)
        XCTAssertTrue(store.diagnostics.recentRequests.isEmpty)
        XCTAssertFalse(store.needsTerms)
        XCTAssertFalse(store.newDeviceNotice)
        XCTAssertEqual(store.ageStatus, .allowed, "the age answer says nothing about an identity and stays")
        XCTAssertEqual(store.wipeEpoch, before + 1, "a request that was out when the wipe ran can tell, and drops its answer")
        XCTAssertEqual(duoKeys(kit.defaults), Set(DuoCache.keptKeys),
                       "on disk, exactly the keys a wipe keeps are left: the oracle is the on-disk set, not wipedKeys itself")

        // A change made afterwards must not bring the old values back from memory.
        store.diagnostics.recordRequest(status: 200, requestID: "new-request", at: kit.clock.now)
        XCTAssertEqual(DuoCache(defaults: kit.defaults).loadDiagnostics().recentRequests.map(\.requestID), ["new-request"])
        let relaunched = DuoStore(cache: DuoCache(defaults: kit.defaults), reloadWidget: {})
        XCTAssertEqual(relaunched.myDisplayName, "")
        XCTAssertEqual(relaunched.acceptedTermsVersion, 0)
        XCTAssertTrue(relaunched.duos.isEmpty)
    }

    func testAWipeTakesWhatTheScreenSaidAboutTheIdentityThatIsGone() {
        let kit = DuoTestKit()
        let store = kit.store
        store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        store.notice = "Sam already met their goal. Nothing to nudge."
        store.sheetError = "That did not work."
        store.isWorking = true
        XCTAssertTrue(store.hasNoticeCards)

        store.resetLocalState()

        XCTAssertEqual(store.availability, .unknown, "\"Not me, start fresh\" must not keep asking \"Continue as Jo?\"")
        XCTAssertNil(store.notice)
        XCTAssertNil(store.sheetError)
        XCTAssertFalse(store.isWorking)
        XCTAssertFalse(store.hasNoticeCards)

        for gone in [DuoAvailability.disconnected, .banned] {
            store.availability = gone
            store.resetLocalState()
            XCTAssertEqual(store.availability, .unknown, "\(gone) describes the identity, which no longer exists")
            XCTAssertTrue(store.availability.allowsWrites, "so Create and Join work again")
        }
        for stays in [DuoAvailability.maintenance, .upgradeRequired] {
            store.availability = stays
            store.resetLocalState()
            XCTAssertEqual(store.availability, stays, "\(stays) describes the server or the build, which a wipe changes nothing about")
        }
    }

    func testAnEmptyNameLeavesNoKeyBehind() {
        let kit = DuoTestKit()
        kit.store.myDisplayName = "Jo"
        XCTAssertEqual(kit.defaults.string(forKey: DuoCache.myDisplayNameKey), "Jo")
        kit.store.myDisplayName = ""
        XCTAssertNil(kit.defaults.object(forKey: DuoCache.myDisplayNameKey))
    }

    func testAClearTakesTheDuosRejectedDaysAndLedgerKeysToo() {
        let kit = DuoTestKit()
        let cache = kit.dependencies.cache
        let other = UUID()
        kit.store.upsert(DuoFixtures.duo())
        kit.store.upsert(DuoFixtures.duo(id: other, partner: "Alex"))
        var ledger = DuoLedger()
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: DuoFixtures.duoID, day: "2026-10-06"))
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: other, day: "2026-10-06"))
        cache.saveLedger(ledger)
        let row = DuoFixtures.status(.owner, "2026-10-06", bucket: 100)
        cache.saveRejectedDays([DuoFixtures.duoID.uuidString.lowercased(): DuoRejectedDays(rows: ["2026-10-06": row]),
                                other.uuidString.lowercased(): DuoRejectedDays(rows: ["2026-10-06": row])])

        kit.store.remove(DuoFixtures.duoID)

        XCTAssertEqual(cache.loadLedger().seen, [DuoLedger.goalKey(duoID: other, day: "2026-10-06")], "§12.2: Clear takes the duo's ledger keys")
        XCTAssertEqual(Set(cache.loadRejectedDays().keys), [other.uuidString.lowercased()], "and its rejected days, which hold a progress bucket")
    }

    // MARK: - An identity the server forgot

    func testAnIdentityTheServerForgotAlsoTakesTheMemberRecordTheSeenDevicesAndTheAttestationKey() {
        let credential = DuoFixtures.credential()
        let kit = DuoTestKit(credential: credential)
        kit.attester.keys = [credential.deviceID]
        kit.store.memberInfo = memberInfo()
        kit.dependencies.cache.saveSeenDeviceIDs(["old-device"])
        kit.store.newDeviceNotice = true
        let unauthenticated = DuoTransportError(code: .unauthenticated, context: DuoErrorContext(httpStatus: 401, requestID: "r"))

        XCTAssertEqual(kit.dependencies.noteFailure(unauthenticated), .reidentify)

        XCTAssertNil(kit.store.memberInfo)
        XCTAssertNil(kit.dependencies.cache.loadMember(), "the Support ID and name of someone the server no longer knows")
        XCTAssertNil(kit.dependencies.cache.loadSeenDeviceIDs(), "or the next new device would look like an added one (D45)")
        XCTAssertFalse(kit.store.newDeviceNotice)
        XCTAssertFalse(kit.attester.hasKey(forDevice: credential.deviceID), "the key was made for a device id that no longer exists")
    }

    func testATermsVersionNewerThanThisBuildMeansUpdateNotTheTermsSheet() {
        let kit = DuoTestKit()
        func termsRequired(_ version: Int?) -> DuoTransportError {
            DuoTransportError(code: .termsRequired, context: DuoErrorContext(httpStatus: 428, requestID: "r",
                                                                              details: version.map { DuoWireErrorDetails(termsVersion: $0) }))
        }
        XCTAssertEqual(kit.dependencies.noteFailure(termsRequired(DuoProtocolConstants.termsVersion + 1)), .termsRequired)
        XCTAssertEqual(kit.store.availability, .upgradeRequired, "Accept would record the built-in version and be refused again, for ever")
        XCTAssertFalse(kit.store.needsTerms)
        kit.store.availability = .available
        XCTAssertEqual(kit.dependencies.noteFailure(termsRequired(DuoProtocolConstants.termsVersion)), .termsRequired)
        XCTAssertTrue(kit.store.needsTerms)
        kit.store.needsTerms = false
        _ = kit.dependencies.noteFailure(termsRequired(nil))
        XCTAssertTrue(kit.store.needsTerms, "a body with no version is the ordinary case")
    }

    // MARK: - Age

    func testARefusalIsReadFreshFromWhereItIsKeptNotTrustedFromMemory() throws {
        let fromDefaults = DuoTestKit()
        fromDefaults.dependencies.cache.ageStatus = .refused
        XCTAssertEqual(fromDefaults.store.ageStatus, .unknown, "memory has not heard")
        XCTAssertEqual(fromDefaults.store.recordBirthYear(1990, now: fromDefaults.clock.now), .refused)
        XCTAssertEqual(fromDefaults.store.ageStatus, .refused)

        let fromKeychain = DuoTestKit()
        try fromKeychain.dependencies.secrets.markAgeRefused()
        XCTAssertEqual(fromKeychain.store.recordBirthYear(1990, now: fromKeychain.clock.now), .refused,
                       "a process that could not read either at launch must not let an adult year overwrite the refusal")
        XCTAssertEqual(DuoCache(defaults: fromKeychain.defaults).ageStatus, .refused)
    }

    func testARefusalFoundInOnePlaceIsWrittenToTheOthers() async {
        let kit = DuoTestKit()
        kit.dependencies.cache.ageStatus = .refused
        XCTAssertFalse(kit.dependencies.secrets.isAgeRefused(), "the first Keychain write had failed, say")
        _ = await kit.store.peek(code: "H7K39QWX")
        XCTAssertTrue(kit.dependencies.secrets.isAgeRefused(), "deleting and reinstalling must not undo a refusal the defaults held")
        XCTAssertEqual(kit.store.ageStatus, .refused)
    }

    func testAWrongPhoneClockCannotLockAnAdultOutForGood() {
        let kit = DuoTestKit()
        let unsetClock = Date(timeIntervalSince1970: 978_307_200) // 2001-01-01
        XCTAssertEqual(kit.store.recordBirthYear(1990, now: unsetClock), .allowed)
        XCTAssertFalse(kit.dependencies.secrets.isAgeRefused(), "no refusal was written, so a fixed clock is enough")
        XCTAssertEqual(kit.store.recordBirthYear(1990, now: kit.clock.now), .allowed)
    }

    func testAPersonWhoWasRefusedReachesNothingAndKeepsNothing() async {
        let refused = DuoTestKit()
        refused.store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: refused.clock.now)
        XCTAssertEqual(refused.store.recordBirthYear(2020, now: refused.clock.now), .refused)
        XCTAssertNil(refused.store.pendingInvite, "nothing is kept for someone who was refused")
        XCTAssertNil(refused.dependencies.cache.loadPendingInvite())

        let peeked = await refused.store.peek(code: "H7K39QWX")
        XCTAssertNil(peeked)
        refused.store.receive(DuoParsedInvite(code: "H7K39QWX"))
        let created = await refused.store.createDuo(named: "Jo")
        let joined = await refused.store.join(DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: refused.clock.now), named: "Jo")
        let reconnected = await refused.store.reconnect(code: "H7K39QWX")
        let accepted = await refused.store.acceptTerms()
        XCTAssertNil(created)
        XCTAssertNil(joined)
        XCTAssertFalse(reconnected)
        XCTAssertFalse(accepted)
        XCTAssertEqual(refused.store.acceptedTermsVersion, 0)
        XCTAssertTrue(refused.joining.calls.isEmpty, "nothing is sent for them")

        let adult = DuoTestKit()
        XCTAssertEqual(adult.store.recordBirthYear(1990, now: adult.clock.now), .allowed)
        _ = await adult.store.peek(code: "H7K39QWX")
        adult.store.receive(DuoParsedInvite(code: "H7K39QWX"))
        XCTAssertEqual(adult.joining.calls, ["peek:H7K39QWX", "receive:H7K39QWX"])
    }

    // MARK: - What stays on the phone

    func testAnExpiredPendingInviteIsRemovedFromDiskNotJustSkipped() {
        let defaults = makeDefaults()
        let cache = DuoCache(defaults: defaults)
        cache.savePendingInvite(DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date().addingTimeInterval(-49 * 3600)))
        XCTAssertNil(DuoStore(cache: cache, reloadWidget: {}).pendingInvite)
        XCTAssertNil(cache.loadPendingInvite(), "§4.1: dropped after 48 hours, from disk too")
        XCTAssertNil(defaults.object(forKey: DuoCache.pendingInviteKey))
    }

    func testAnInflightRecordPastItsLifetimeIsDroppedAtLaunchFromDisk() {
        let defaults = makeDefaults()
        let cache = DuoCache(defaults: defaults)
        var journal = DuoInflightJournal()
        _ = journal.key(for: "POST /invites/redeem", body: Data(#"{"device_check_token":"abc","code":"H7K39QWX"}"#.utf8),
                        now: Date().addingTimeInterval(-30 * 86_400), random: TestRandom())
        cache.saveInflight(journal)
        XCTAssertNotNil(defaults.data(forKey: DuoCache.inflightKey))
        _ = DuoStore(cache: cache, reloadWidget: {})
        XCTAssertNil(defaults.object(forKey: DuoCache.inflightKey), "a typed code and a DeviceCheck token must not sit there for 30 days")
    }

    func testAPendingInvitesSecretNeverReachesTheDefaults() {
        let kit = DuoTestKit()
        kit.store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: "ABCDEFGHJKMNPQRSTVWXYZ0123", receivedAt: kit.clock.now)
        XCTAssertEqual(kit.store.pendingInvite?.k, "ABCDEFGHJKMNPQRSTVWXYZ0123", "kept in memory for the Join tap")
        let stored = kit.defaults.data(forKey: DuoCache.pendingInviteKey)
        XCTAssertNotNil(stored)
        XCTAssertFalse(String(decoding: stored ?? Data(), as: UTF8.self).contains("ABCDEFGHJK"))
        XCTAssertNil(DuoStore(cache: DuoCache(defaults: kit.defaults), reloadWidget: {}).pendingInvite?.k)
    }

    // MARK: - Before a tap

    /// Meant to fail the day a service attests, asks DeviceCheck, writes the Keychain or sends
    /// before a Create, Join or Reconnect tap. It once could not: with every service a stub it
    /// asserted at once, before any fire-and-forget task ran, and called only six entry points.
    /// Mutants of the stubs showed seven of nine slipping through, so it now starts from the
    /// state a refresh must not send from (a cached live duo, an invite waiting, a queued
    /// request, an in-flight record and a push record, with no credential), calls every entry
    /// point the store has, lets tasks run, and watches a Keychain that records any write.
    func testNothingIsAttestedCheckedOrKeptInTheKeychainBeforeATap() async throws {
        let session = RecordingSession()
        let secretStore = DuoReviewSpySecretStore()
        let attester = FakeDuoAttester()
        let deviceCheck = DuoReviewCountingDeviceCheck()
        let cache = DuoCache(defaults: makeDefaults())
        let now = Date()
        cache.saveDuos([DuoFixtures.duo(now: now)])
        cache.savePendingInvite(DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: now))
        cache.saveOps([try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "k", now: now)])
        var journal = DuoInflightJournal()
        _ = journal.key(for: "POST /duos", body: Data("{}".utf8), now: now, random: TestRandom())
        cache.saveInflight(journal)
        cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: nil, windowEnd: nil,
                                                enabled: true, uploadedAt: now))
        let identityFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DuoBeforeATap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: identityFolder) }
        let store = DuoComposition.makeLiveStore(session: session, secretStore: secretStore, cache: cache,
                                                 attester: attester, deviceCheck: deviceCheck, identityDirectory: identityFolder)

        store.activate(logReader: FakeLogReader())
        store.logChanged(entries: [], goalML: 2000)
        await store.refresh()
        await store.flush()
        _ = await store.backgroundRefresh()
        store.scheduleBackgroundRefresh()
        store.notificationsEnabled = false
        store.notificationsEnabled = true
        store.pushTokenArrived(Data([1, 2, 3]), environment: .sandbox)
        await store.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 5, kind: .unknown("x")))
        await store.changeMyName("Jo")
        _ = await store.acceptTerms()
        // Whatever a service started without awaiting gets to run before anything is asserted.
        for _ in 0..<200 { await Task.yield() }

        XCTAssertTrue(session.requests.isEmpty, "no request before a Create, Join or Reconnect tap (§3.1)")
        XCTAssertEqual(attester.attestedNewKeys, 0, "App Attest talks to Apple outside the HTTP session")
        XCTAssertTrue(attester.assertions.isEmpty)
        XCTAssertEqual(deviceCheck.calls, 0)
        XCTAssertTrue(secretStore.writes.isEmpty, "no Keychain item is written before a tap, under any service name: \(secretStore.writes)")
        XCTAssertTrue(secretStore.deletes.isEmpty, "no Keychain item is deleted before a tap either: \(secretStore.deletes)")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: identityFolder.path)) ?? []
        XCTAssertTrue(left.isEmpty, "the identity keeps no duo.install or duo.settled file before a tap: \(left)")
    }
}
#endif
