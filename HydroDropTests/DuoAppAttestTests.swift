#if DUO_V2
import DeviceCheck
import XCTest
@testable import HydroDrop

/// Stands in for the Secure Enclave. Its bytes are chosen so that standard base64 would carry
/// `+`, `/` and `=` padding, which an unpadded base64url token must not.
fileprivate final class BFakeAppAttestService: DCAppAttestServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var supported = true
    private var keys = 0
    private var attestedCalls: [(keyID: String, hash: Data)] = []
    private var assertedCalls: [(keyID: String, hash: Data)] = []
    var attestError: Error?
    var assertError: Error?
    let attestation = Data([0xFB, 0xFF])
    let assertion = Data([0xFB, 0xEF, 0xBF, 0xFF])

    var isSupported: Bool {
        get { lock.lock(); defer { lock.unlock() }; return supported }
        set { lock.lock(); supported = newValue; lock.unlock() }
    }
    var generated: Int { lock.lock(); defer { lock.unlock() }; return keys }
    var attested: [(keyID: String, hash: Data)] { lock.lock(); defer { lock.unlock() }; return attestedCalls }
    var asserted: [(keyID: String, hash: Data)] { lock.lock(); defer { lock.unlock() }; return assertedCalls }

    func generateKey() async throws -> String {
        lock.withLock {
            keys += 1
            return "key-\(keys)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { attestedCalls.append((keyID, clientDataHash)) }
        if let attestError { throw attestError }
        return attestation
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { assertedCalls.append((keyID, clientDataHash)) }
        if let assertError { throw assertError }
        return assertion
    }
}

/// Counts every token it is asked for, so a test can say none was.
fileprivate final class BFakeDevice: DCDeviceProviding, @unchecked Sendable {
    let isSupported: Bool
    let data: Data?
    private let lock = NSLock()
    private var asked = 0

    init(isSupported: Bool = true, data: Data? = Data([0xFB, 0xFF])) {
        self.isSupported = isSupported
        self.data = data
    }

    var tokensAsked: Int { lock.lock(); defer { lock.unlock() }; return asked }

    func generateToken() async throws -> Data {
        lock.withLock { asked += 1 }
        guard let data else { throw DCError(.serverUnavailable) }
        return data
    }
}

/// Records the accessibility each item was written with.
fileprivate final class BAccessibilityStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    private let lock = NSLock()
    private var kept: [String: DuoSecretAccessibility] = [:]
    var accessibility: [String: DuoSecretAccessibility] { lock.lock(); defer { lock.unlock() }; return kept }

    func read(service: String, account: String) throws -> Data? { try memory.read(service: service, account: account) }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        lock.lock(); kept[account] = accessibility; lock.unlock()
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}

final class DuoAppAttestTests: XCTestCase {
    private let deviceID = "6d2a0000-0000-4000-8000-0000000000bb"
    private let bind = Data(repeating: 0xAB, count: 32)
    private let base64URLAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private func make(_ service: BFakeAppAttestService = BFakeAppAttestService(),
                      store: DuoSecretStore = DuoMemorySecretStore()) -> (DuoAppAttest, BFakeAppAttestService, DuoSecrets) {
        let secrets = DuoSecrets(store: store)
        return (DuoAppAttest(secrets: secrets, service: service), service, secrets)
    }

    private func keyID(_ secrets: DuoSecrets, account: String) -> String? {
        ((try? secrets.store.read(service: DuoSecrets.service, account: account)) ?? nil).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - App Attest

    func testNothingRunsUntilTheAPIClientAsks() {
        let store = DuoMemorySecretStore()
        let (attest, service, _) = make(store: store)
        XCTAssertTrue(attest.isSupported)
        XCTAssertFalse(attest.hasKey(forDevice: deviceID))
        XCTAssertEqual(service.generated, 0, "no key is made at init, and reading isSupported makes none (§3.1)")
        XCTAssertTrue(store.accounts(service: DuoSecrets.service).isEmpty)
    }

    func testAttestingANewKeyLeavesItPendingAndReturnsUnpaddedBase64URL() async throws {
        let store = BAccessibilityStore()
        let (attest, service, secrets) = make(store: store)

        let token = try await attest.attestNewKey(clientDataHash: bind)

        XCTAssertEqual(token.kind, .attestation)
        XCTAssertEqual(token.keyID, "key-1")
        XCTAssertEqual(token.token, "-_8", "standard base64 would be +/8=: X-HD-Attest carries base64url without padding")
        XCTAssertEqual(service.attested.map(\.keyID), ["key-1"])
        XCTAssertEqual(service.attested.first?.hash, bind, "attested over the bind as given")
        XCTAssertEqual(keyID(secrets, account: DuoSecrets.pendingAttestKeyAccount), "key-1", "pending until the server accepts it")
        XCTAssertEqual(store.accessibility[DuoSecrets.pendingAttestKeyAccount], .afterFirstUnlockThisDeviceOnly,
                       "a key id is useless on another phone")
        XCTAssertFalse(attest.hasKey(forDevice: deviceID))
    }

    func testAdoptingMovesThePendingKeyToTheDevice() async throws {
        let store = BAccessibilityStore()
        let (attest, _, secrets) = make(store: store)
        let token = try await attest.attestNewKey(clientDataHash: bind)

        attest.adoptPendingKey(token.keyID, forDevice: deviceID)

        XCTAssertTrue(attest.hasKey(forDevice: deviceID))
        XCTAssertEqual(keyID(secrets, account: DuoSecrets.attestKeyAccount(deviceID: deviceID)), "key-1")
        XCTAssertNil(keyID(secrets, account: DuoSecrets.pendingAttestKeyAccount))
        XCTAssertEqual(store.accessibility[DuoSecrets.attestKeyAccount(deviceID: deviceID)], .afterFirstUnlockThisDeviceOnly)
    }

    func testOnlyThePendingKeyIsAdopted() async throws {
        let (attest, _, secrets) = make()
        _ = try await attest.attestNewKey(clientDataHash: bind)
        let retry = try await attest.attestNewKey(clientDataHash: bind) // a retry re-keyed

        attest.adoptPendingKey("key-1", forDevice: deviceID)

        XCTAssertFalse(attest.hasKey(forDevice: deviceID), "an older key than the pending one is not adopted")
        XCTAssertEqual(keyID(secrets, account: DuoSecrets.pendingAttestKeyAccount), retry.keyID)
        attest.adoptPendingKey(retry.keyID, forDevice: deviceID)
        XCTAssertEqual(keyID(secrets, account: DuoSecrets.attestKeyAccount(deviceID: deviceID)), "key-2")
    }

    func testAnAssertionUsesTheStoredKeyAndNeverAttestsItAgain() async throws {
        let (attest, service, _) = make()
        let first = try await attest.attestNewKey(clientDataHash: bind)
        attest.adoptPendingKey(first.keyID, forDevice: deviceID)
        let other = Data(repeating: 0xCD, count: 32)

        let token = try await attest.assert(clientDataHash: other, deviceID: deviceID)

        XCTAssertEqual(token.kind, .assertion)
        XCTAssertEqual(token.keyID, "key-1")
        XCTAssertEqual(token.token, "---__w", "standard base64 would be +++//w==: base64url without padding")
        XCTAssertTrue(token.token.unicodeScalars.allSatisfy { base64URLAlphabet.contains($0) })
        XCTAssertEqual(service.asserted.map(\.keyID), ["key-1"])
        XCTAssertEqual(service.asserted.first?.hash, other)
        XCTAssertEqual(service.attested.count, 1, "a key is attested once only")
        XCTAssertEqual(service.generated, 1)
    }

    func testAnAssertionWithNoStoredKeyThrowsNoKey() async {
        let (attest, service, _) = make()
        do {
            _ = try await attest.assert(clientDataHash: bind, deviceID: deviceID)
            XCTFail("there is no key to assert with")
        } catch {
            XCTAssertEqual(error as? DuoAttestationError, .noKey)
        }
        XCTAssertTrue(service.asserted.isEmpty)
        XCTAssertEqual(service.generated, 0, "and asserting never makes one")
    }

    func testAKeyTheSystemLostIsForgottenSoTheNextAttemptBringsANewOne() async throws {
        let (attest, service, _) = make()
        let first = try await attest.attestNewKey(clientDataHash: bind)
        attest.adoptPendingKey(first.keyID, forDevice: deviceID)
        service.assertError = DCError(.invalidKey)

        do {
            _ = try await attest.assert(clientDataHash: bind, deviceID: deviceID)
            XCTFail("the key is gone")
        } catch {
            XCTAssertEqual(error as? DuoAttestationError, .invalidKey)
        }
        XCTAssertFalse(attest.hasKey(forDevice: deviceID), "a reinstall leaves the Keychain item and loses the key")

        service.assertError = DCError(.serverUnavailable)
        let second = try await attest.attestNewKey(clientDataHash: bind)
        attest.adoptPendingKey(second.keyID, forDevice: deviceID)
        do {
            _ = try await attest.assert(clientDataHash: bind, deviceID: deviceID)
            XCTFail("Apple's service was unavailable")
        } catch {
            XCTAssertNotEqual(error as? DuoAttestationError, .invalidKey)
        }
        XCTAssertTrue(attest.hasKey(forDevice: deviceID), "any other failure keeps the key")
    }

    func testAFailedAttestationLeavesNothingPending() async {
        let (attest, service, secrets) = make()
        service.attestError = DCError(.serverUnavailable)
        do {
            _ = try await attest.attestNewKey(clientDataHash: bind)
            XCTFail("the attestation failed")
        } catch {}
        XCTAssertNil(keyID(secrets, account: DuoSecrets.pendingAttestKeyAccount))
    }

    func testForgettingTakesTheDevicesKeyAndThePendingOne() async throws {
        let (attest, _, secrets) = make()
        let first = try await attest.attestNewKey(clientDataHash: bind)
        attest.adoptPendingKey(first.keyID, forDevice: deviceID)
        _ = try await attest.attestNewKey(clientDataHash: bind)

        attest.forgetKeys(forDevice: deviceID)

        XCTAssertFalse(attest.hasKey(forDevice: deviceID))
        XCTAssertNil(keyID(secrets, account: DuoSecrets.pendingAttestKeyAccount))
    }

    func testAnUnsupportedPhoneAttestsNothing() async {
        let service = BFakeAppAttestService()
        service.isSupported = false
        let (attest, _, secrets) = make(service)
        XCTAssertFalse(attest.isSupported, "mirrors the service: the request then goes without a header, at the low tier")
        do {
            _ = try await attest.attestNewKey(clientDataHash: bind)
            XCTFail("unsupported")
        } catch {
            XCTAssertEqual(error as? DuoAttestationError, .unsupported)
        }
        do {
            _ = try await attest.assert(clientDataHash: bind, deviceID: deviceID)
            XCTFail("unsupported")
        } catch {
            XCTAssertEqual(error as? DuoAttestationError, .unsupported)
        }
        XCTAssertEqual(service.generated, 0)
        XCTAssertNil(keyID(secrets, account: DuoSecrets.pendingAttestKeyAccount))
    }

    func testBase64URLIsUnpaddedForEveryLength() {
        XCTAssertEqual(DuoAppAttest.base64URL(Data()), "")
        XCTAssertEqual(DuoAppAttest.base64URL(Data([0xFF])), "_w")
        XCTAssertEqual(DuoAppAttest.base64URL(Data([0xFB, 0xFF])), "-_8")
        XCTAssertEqual(DuoAppAttest.base64URL(Data([0xFB, 0xFF, 0xBF])), "-_-_")
    }

    // MARK: - DeviceCheck

    func testADeviceCheckTokenIsStandardBase64WithItsPadding() async throws {
        let check = DuoDeviceCheck(device: BFakeDevice())
        XCTAssertTrue(check.isSupported)
        let issued = await check.token()
        let token = try XCTUnwrap(issued)
        XCTAssertEqual(token, "+/8=", "the contract's pattern is standard base64, not base64url")
        XCTAssertNotNil(token.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression))
    }

    /// M3h: building the wrapper and reading `isSupported` asks Apple for nothing; only `token()` does.
    func testDeviceCheckAsksForNoTokenUntilOneIsWanted() async {
        let device = BFakeDevice()
        let check = DuoDeviceCheck(device: device)
        XCTAssertTrue(check.isSupported)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(device.tokensAsked, 0, "nothing is generated before the joining or exit service asks (§3.1)")
        _ = await check.token()
        XCTAssertEqual(device.tokensAsked, 1, "one token per request, fresh each time")
        _ = await check.token()
        XCTAssertEqual(device.tokensAsked, 2)

        let unsupported = BFakeDevice(isSupported: false)
        _ = await DuoDeviceCheck(device: unsupported).token()
        XCTAssertEqual(unsupported.tokensAsked, 0, "an unsupported phone is never asked")
    }

    func testNoDeviceCheckTokenWhereItIsUnsupportedFailsOrIsEmpty() async {
        let unsupported = DuoDeviceCheck(device: BFakeDevice(isSupported: false))
        XCTAssertFalse(unsupported.isSupported)
        let none = await unsupported.token()
        XCTAssertNil(none)
        let failing = await DuoDeviceCheck(device: BFakeDevice(data: nil)).token()
        XCTAssertNil(failing, "the request then goes without one")
        let empty = await DuoDeviceCheck(device: BFakeDevice(data: Data())).token()
        XCTAssertNil(empty, "an empty token would not match the contract's pattern")
    }

    // MARK: - The system services

    #if targetEnvironment(simulator)
    /// The simulator can do neither, which is why everything above uses fakes: a real key and a
    /// real token come only from a real iPhone.
    func testTheSimulatorCanNeitherAttestNorCheck() async {
        let attest = DuoAppAttest(secrets: DuoSecrets(store: DuoMemorySecretStore()))
        XCTAssertFalse(attest.isSupported)
        do {
            _ = try await attest.attestNewKey(clientDataHash: bind)
            XCTFail("the simulator cannot attest")
        } catch {
            XCTAssertEqual(error as? DuoAttestationError, .unsupported)
        }
        let check = DuoDeviceCheck()
        XCTAssertFalse(check.isSupported)
        let token = await check.token()
        XCTAssertNil(token)
    }
    #endif
}
#endif
