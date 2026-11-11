#if DUO_V2
import XCTest
@testable import HydroDrop

/// These deliberately build the real composition, including its age-gated HTTP wrapper.
/// A preview launch would bypass that composition, so the fixture fails loudly in that host.
@MainActor
final class DuoIntegrationTests: XCTestCase {
    private struct Rig {
        let store: DuoStore
        let session: RecordingSession
        let secrets: DuoMemorySecretStore
        let folder: URL
        let attester: FakeDuoAttester
        let deviceCheck: DuoReviewCountingDeviceCheck
    }

    private func rig(credential: DuoCredential? = nil) throws -> Rig {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-DuoPreview"), "Run composed integration tests without -DuoPreview")
        let suite = "DuoIntegrationTests.\(UUID().uuidString)"
        DuoSuiteJanitor.shared.track(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let secrets = DuoMemorySecretStore()
        if let credential { try DuoSecrets(store: secrets).save(credential) }
        let session = RecordingSession()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DuoIntegration-\(UUID().uuidString)")
        let attester = FakeDuoAttester()
        let deviceCheck = DuoReviewCountingDeviceCheck()
        let store = DuoComposition.makeLiveStore(session: session, secretStore: secrets, cache: DuoCache(defaults: defaults),
                                                 baseURL: URL(string: "https://integration.invalid/v1")!,
                                                 attester: attester, deviceCheck: deviceCheck, identityDirectory: folder, verifiedLegacyEnvironment: .staging)
        XCTAssertNotNil(store.dependencies, "The real services must be installed")
        return Rig(store: store, session: session, secrets: secrets, folder: folder, attester: attester, deviceCheck: deviceCheck)
    }

    func testIdleEntryPointsStaySilentAndAllowedInvitePeekIsAnonymous() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let store = rig.store
        await store.duoScreenOpened()
        await store.refresh()
        await store.flush()
        _ = await store.backgroundRefresh()
        store.activate(logReader: FakeLogReader())
        store.scheduleBackgroundRefresh()
        await store.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 1, kind: .joined))
        XCTAssertTrue(rig.session.requests.isEmpty)
        XCTAssertEqual(rig.attester.attestedNewKeys, 0)
        XCTAssertEqual(rig.deviceCheck.calls, 0)
        XCTAssertTrue(rig.secrets.accounts(service: DuoSecrets.service).isEmpty)

        XCTAssertEqual(store.recordBirthYear(1990, month: 1), .allowed)
        rig.session.respond = { request in
            (Data(#"{"error":{"code":"invite_unknown","message":"Unknown invite","request_id":"0123456789abcdef"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        store.receive(DuoParsedInvite(code: "H7K39QWX"))
        _ = await store.peek(code: "H7K39QWX")
        let request = try XCTUnwrap(rig.session.requests.only)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/invites/peek")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        // The old development build needed a launch override just to meet the server's
        // minimum version. Exercise the real composition without that escape hatch, so
        // a release whose actual bundle version cannot write does not pass this check.
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-DuoClientVersion"))
        let bundledVersion = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let bundledBuild = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertNotEqual(bundledVersion.compare("2.0", options: .numeric), .orderedAscending)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-HD-Client"), "ios/\(bundledVersion) (\(bundledBuild))")
        XCTAssertEqual(rig.attester.attestedNewKeys, 0)
        XCTAssertEqual(rig.deviceCheck.calls, 0)
        XCTAssertFalse(store.hasIdentity)
    }

    func testEveryConsentAttemptAsksForRulesBeforeSending() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let store = rig.store
        XCTAssertEqual(store.recordBirthYear(1990, month: 1), .allowed)
        _ = await store.createDuo(named: "Jo")
        XCTAssertTrue(store.needsTerms)
        store.needsTerms = false
        _ = await store.join(DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date()), named: "Jo")
        XCTAssertTrue(store.needsTerms)
        store.needsTerms = false
        _ = await store.reconnect(code: "H7K39QWX")
        XCTAssertTrue(store.needsTerms)
        XCTAssertTrue(rig.session.requests.isEmpty)
        XCTAssertEqual(rig.attester.attestedNewKeys, 0)
        XCTAssertEqual(rig.deviceCheck.calls, 0)
        XCTAssertFalse(store.hasIdentity)
    }

    func testAnonymousPeek401CannotDiscardARestoredCredential() async throws {
        let credential = DuoFixtures.credential()
        let rig = try rig(credential: credential)
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        XCTAssertEqual(rig.store.recordBirthYear(1990, month: 1), .allowed)
        rig.session.respond = { request in
            (Data(#"{"error":{"code":"unauthenticated","message":"No identity","request_id":"0123456789abcdef"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        _ = await rig.store.peek(code: "H7K39QWX")
        let request = try XCTUnwrap(rig.session.requests.only)
        XCTAssertEqual(request.url?.path, "/v1/invites/peek")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(rig.store.diagnostics.recentErrors.first?.code, "unauthenticated")
        XCTAssertEqual(DuoSecrets(store: rig.secrets).credential(), credential)
        XCTAssertTrue(rig.store.hasIdentity)
    }

    func testRefusalBlocksOrdinaryComposedTrafficButAllowsDeletion() async throws {
        let rig = try rig(credential: DuoFixtures.credential())
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.store.upsert(DuoFixtures.duo())
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        XCTAssertEqual(rig.store.recordBirthYear(year, month: 1), .refused)
        await rig.store.duoScreenOpened()
        await rig.store.refresh()
        _ = await rig.store.backgroundRefresh()
        _ = await rig.store.peek(code: "H7K39QWX")
        XCTAssertTrue(rig.session.requests.isEmpty)
        rig.session.respond = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let deleted = await rig.store.deleteMyData()
        XCTAssertTrue(deleted)
        let request = try XCTUnwrap(rig.session.requests.only)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/me")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(rig.store.duos.isEmpty)
        XCTAssertNil(DuoSecrets(store: rig.secrets).credential())
        XCTAssertEqual(rig.store.ageStatus, .refused)
        XCTAssertTrue(DuoSecrets(store: rig.secrets).isAgeRefused())
    }

    func testLifetimeOnlyEntitlementReceivesTheFiveDuoLimit() {
        let entitlement = PlusEntitlements(productIDs: [StoreManager.PlusProductID.lifetime.rawValue])
        let four = (0..<4).map { _ in DuoFixtures.duo(id: UUID()) }
        XCTAssertTrue(DuoLimit.canAddDuo(existing: four, isSubscribed: entitlement.grantsPlus))
        XCTAssertFalse(DuoLimit.canAddDuo(existing: four + [DuoFixtures.duo()], isSubscribed: entitlement.grantsPlus))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
