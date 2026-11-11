#if DUO_V2
import XCTest
@testable import HydroDrop

@MainActor final class DuoLegacyStagingProvenanceTests: XCTestCase {
    private let staging = URL(string: "https://api-staging.hydrodrop.us/v1")!
    private var approval: [String] { ["HydroDrop", DuoLegacyStagingProvenance.approvalArgument, DuoLegacyStagingProvenance.approvalReceipt] }
    private func member(_ credential: DuoCredential) -> DuoMemberInfo {
        DuoMemberInfo(memberID: credential.memberID, displayName: nil, skin: nil,
                      supportID: DuoLegacyStagingProvenance.approvedSupportID, tier: .low, termsVersion: 1,
                      nudgesPerDay: 1, maxActiveDuos: 1,
                      devices: [DuoDeviceInfo(id: credential.deviceID, platform: "ios", createdAt: .distantPast, thisDevice: true, superseded: false)],
                      minClientIOS: "2.0", updatedAt: .distantPast)
    }
    private func evaluate(_ credential: DuoCredential = DuoFixtures.credential(), base: URL? = nil,
                          arguments: [String]? = nil, bundle: String? = "com.jonathonbrown.HydroDrop",
                          cached: DuoMemberInfo? = nil) -> DuoRecoveryEnvironment? {
        DuoLegacyStagingProvenance.approvedEnvironment(baseURL: base ?? staging, arguments: arguments ?? approval,
            bundleIdentifier: bundle, cachedMember: cached ?? member(credential), credential: credential)
    }
    func testExactExplicitReceiptAndBoundCachedIdentityAreRequired() {
        #if DEBUG
        XCTAssertEqual(evaluate(), .staging)
        #else
        XCTAssertNil(evaluate())
        #endif
        XCTAssertNil(evaluate(arguments: []))
        XCTAssertNil(evaluate(arguments: [DuoLegacyStagingProvenance.approvalArgument]))
        XCTAssertNil(evaluate(arguments: [DuoLegacyStagingProvenance.approvalArgument, "other-receipt"]))
        XCTAssertNil(evaluate(arguments: approval + approval))
        XCTAssertNil(evaluate(bundle: "com.example.Other"))
    }
    func testHostSelectionAloneNeverApprovesAndNoncanonicalOriginsAreRejected() {
        for value in ["https://api.hydrodrop.us/v1", "https://test.invalid/v1", "http://api-staging.hydrodrop.us/v1",
                      "https://api-staging.hydrodrop.us:443/v1", "https://api-staging.hydrodrop.us/v1?x=1",
                      "https://api-staging.hydrodrop.us/v1#x", "https://user@api-staging.hydrodrop.us/v1",
                      "https://api-staging.hydrodrop.us/v1/"] {
            XCTAssertNil(evaluate(base: URL(string: value)!))
        }
        XCTAssertNil(evaluate(base: staging, arguments: ["HydroDrop", "-DuoClientVersion", "2.0"]))
    }
    func testCachedMemberSupportIDAndThisDeviceMustAllMatch() {
        let credential = DuoFixtures.credential()
        var cached = member(credential); cached.supportID = "000000000000"
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.memberID = UUID().uuidString.lowercased()
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.devices = []
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.devices[0].id = UUID().uuidString.lowercased()
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.devices[0].superseded = true
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.devices[0].thisDevice = false
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.devices[0].platform = "android"
        XCTAssertNil(evaluate(cached: cached))
        cached = member(credential); cached.devices.append(cached.devices[0])
        XCTAssertNil(evaluate(cached: cached))
        XCTAssertNil(DuoLegacyStagingProvenance.approvedEnvironment(baseURL: staging, arguments: approval,
            bundleIdentifier: "com.jonathonbrown.HydroDrop", cachedMember: nil, credential: credential))
    }
    func testInvalidLegacyCredentialDoesNotGainProvenance() {
        var credential = DuoFixtures.credential(); credential.deviceSecret = "invalid"
        XCTAssertNil(evaluate(credential))
        credential = DuoFixtures.credential(); credential.secretVersion = 0
        XCTAssertNil(evaluate(credential))
    }
    func testApprovedSameInstallMigratesLocallyWithoutOrdinaryNetwork() async throws {
        #if !DEBUG
        throw XCTSkip("The staging approval mechanism is absent in Release")
        #else
        let kit = DuoTestKit(); let credential = DuoFixtures.credential()
        kit.dependencies.cache.recordConfirmedAgeStatus(.allowed); kit.dependencies.cache.acceptedTermsVersion = 1
        try kit.dependencies.secrets.save(credential); try kit.dependencies.secrets.writeInstallMarker(random: kit.random)
        kit.dependencies.cache.saveMember(member(credential))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("D65-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("settled".utf8).write(to: folder.appendingPathComponent("duo.settled"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let sut = DuoRecoveryIdentity(dependencies: kit.dependencies, environment: .staging, directory: folder) { legacy in
            self.evaluate(legacy, cached: kit.dependencies.cache.loadMember())
        }
        kit.dependencies.identity = sut
        let launch = await sut.prepare()
        XCTAssertEqual(launch, .ready)
        XCTAssertEqual(try sut.journal.read()?.phase, .activeLegacy)
        XCTAssertEqual(sut.credential, credential)
        XCTAssertEqual(try sut.journal.readMirror()?.environment, .staging)
        XCTAssertFalse(try XCTUnwrap(try sut.journal.read()).restoreRotationRequired)
        XCTAssertFalse(try XCTUnwrap(try sut.journal.read()).restoreConfirmationRequired)
        XCTAssertNil(try kit.secretStore.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount))
        XCTAssertTrue(kit.transport.calls.isEmpty)
        #endif
    }
    func testUnapprovedMappingKeepsLegacyRecordUntouchedAndSendsNothing() async throws {
        let kit = DuoTestKit(); let credential = DuoFixtures.credential()
        kit.dependencies.cache.recordConfirmedAgeStatus(.allowed); kit.dependencies.cache.acceptedTermsVersion = 1
        try kit.dependencies.secrets.save(credential)
        let before = try kit.secretStore.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount)
        let sut = DuoRecoveryIdentity(dependencies: kit.dependencies, environment: .staging) { legacy in
            self.evaluate(legacy, arguments: [])
        }
        kit.dependencies.identity = sut
        let launch = await sut.prepare()
        XCTAssertEqual(launch, .unavailable)
        XCTAssertNil(try sut.journal.read())
        XCTAssertEqual(try kit.secretStore.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount), before)
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }
}
#endif
