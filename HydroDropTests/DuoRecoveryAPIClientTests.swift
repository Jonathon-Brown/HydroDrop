#if DUO_V2
import CryptoKit
import XCTest
@testable import HydroDrop

/// These tests go through the app's HTTP adapter. In particular, a synthetic response must
/// not reach the journal as an authoritative refusal merely because its status is 401.
final class DuoRecoveryAPIClientTests: XCTestCase {
    private let device = "11111111-1111-4111-8111-111111111111"
    private let member = "22222222-2222-4222-8222-222222222222"
    private var credential: DuoRecoveryCredential { .init(deviceID: device, deviceSecret: String(repeating: "A", count: 43)) }
    private var state: Data {
        Data("{\"contract_version\":\"1.1\",\"device_id\":\"\(device)\",\"member_id\":\"\(member)\",\"secret_version\":1,\"credential_protocol\":\"1.1\",\"device_tier\":\"low\",\"support_id\":\"ABCDEFGHJKMN\"}".utf8)
    }
    private func make(_ session: RecoveryHTTPSession, attester: RecoveryHTTPAttester = .init(), base: String = "https://api-staging.hydrodrop.us/v1") -> DuoAPIClient {
        DuoAPIClient(baseURL: URL(string: base)!, client: .init(marketingVersion: "2.0", build: "57"),
                     credentials: RecoveryNoOrdinaryCredential(), attester: attester, session: session)
    }
    private func error(_ code: String) -> Data {
        Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"Refused\",\"request_id\":\"abcdef0123456789\"}}".utf8)
    }
    private func expectUnavailable(_ body: Data, status: Int = 401, headers: [String: String] = ["Content-Type": "application/json"], url: URL? = nil) async {
        let session = RecoveryHTTPSession([.init(status, body, headers: headers, url: url)])
        do { _ = try await make(session).credentialState(as: credential); XCTFail("Accepted invalid response") }
        catch let error as DuoRecoveryError { if case .unavailable = error {} else { XCTFail("Unexpected classification: \(error)") } }
        catch { XCTFail("Wrong error type: \(error)") }
        XCTAssertEqual(session.requests.count, 1)
    }

    func testPrepareIsAnonymousAndUsesVersionedRoute() async throws {
        let body = Data("{\"contract_version\":\"1.1\",\"device_id\":\"\(device)\",\"expires_at\":\"2026-11-05T04:00:00.000Z\"}".utf8)
        let session = RecoveryHTTPSession([.init(201, body)])
        _ = try await make(session).prepareDeviceIssuance(.init(appVersion: "2.0", termsVersion: 1, deviceSecret: credential.deviceSecret))
        let request = try XCTUnwrap(session.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api-staging.hydrodrop.us/v1.1/device-issuances")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-HD-Attest"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["platform", "app_version", "terms_version", "device_secret"])
        XCTAssertEqual(object["device_secret"] as? String, credential.deviceSecret)
    }

    func testStateUsesCapturedCredentialWithoutOrdinaryIdentity() async throws {
        let session = RecoveryHTTPSession([.init(200, state)])
        let result = try await make(session).credentialState(as: credential)
        XCTAssertEqual(result.deviceID, device)
        let request = try XCTUnwrap(session.requests.first)
        XCTAssertEqual(request.url?.path, "/v1.1/devices/me/credential-state")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(device).\(credential.deviceSecret)")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(session.requests.count, 1)
    }

    func testGenuineCredentialRejectionStaysInRecoveryDomain() async throws {
        let session = RecoveryHTTPSession([.init(401, error("credential_rejected"))])
        do { _ = try await make(session).credentialState(as: credential); XCTFail() }
        catch let error as DuoRecoveryError { XCTAssertEqual(error.code, .credentialRejected) }
        XCTAssertEqual(session.requests.count, 1)
    }

    func testMalformedAndProxyErrorsCannotRejectCredential() async {
        await expectUnavailable(Data("<html>Denied</html>".utf8), headers: ["Content-Type": "text/html"])
        await expectUnavailable(error("unauthenticated"))
        await expectUnavailable(error("credential_rejected"), status: 403)
        let duplicate = String(decoding: error("credential_rejected"), as: UTF8.self).replacingOccurrences(of: "\"code\":", with: "\"code\":\"maintenance\",\"code\":")
        await expectUnavailable(Data(duplicate.utf8))
        await expectUnavailable(error("credential_rejected"), url: URL(string: "https://portal.example/v1.1/devices/me/credential-state"))
        await expectUnavailable(error("credential_rejected"), url: URL(string: "https://api-staging.hydrodrop.us/v1.1/devices/me/credential-state?redirected=1"))
    }

    func testSuccessStillRequiresExactStatusAndSameDevice() async {
        await expectUnavailable(state, status: 201)
        await expectUnavailable(Data(String(decoding: state, as: UTF8.self).replacingOccurrences(of: device, with: "33333333-3333-4333-8333-333333333333").utf8), status: 200)
        await expectUnavailable(state, status: 200, headers: ["Content-Type": "text/html"])
    }

    func testCapabilityFailureNeverFallsBackToV1Mint() async throws {
        let session = RecoveryHTTPSession([.init(404, Data("not found".utf8))])
        do { _ = try await make(session).recoveryCapabilities(); XCTFail() } catch {}
        XCTAssertEqual(session.requests.map { $0.url?.path }, ["/v1.1/capabilities"])
    }

    func testBadOriginConfigurationDoesNotSendAnyRequest() async {
        for base in ["http://api-staging.hydrodrop.us/v1", "https://api-staging.hydrodrop.us/v1?x=y", "https://secret@api-staging.hydrodrop.us/v1", "https://api-staging.hydrodrop.us/other"] {
            let session = RecoveryHTTPSession([])
            do { _ = try await make(session, base: base).credentialState(as: credential); XCTFail() } catch {}
            XCTAssertTrue(session.requests.isEmpty)
        }
    }

    func testLostCommitIsNotBlindlyRetried() async throws {
        let session = RecoveryHTTPSession([])
        do { _ = try await make(session).commitDevice(.init(deviceID: device), as: credential); XCTFail() }
        catch let error as DuoRecoveryError { if case .offline = error {} else { XCTFail() } }
        XCTAssertEqual(session.requests.map { $0.url?.path }, ["/v1.1/devices"])
    }

    func testCommitAttestationBindsReservedDeviceAndAdoptsOnlyNewCommit() async throws {
        for status in [201, 200] {
            let attester = RecoveryHTTPAttester(supported: true)
            let session = RecoveryHTTPSession([.init(status, state)])
            _ = try await make(session, attester: attester).commitDevice(.init(deviceID: device), as: credential)
            XCTAssertEqual(session.requests.map { $0.url?.path }, ["/v1/attest/challenge", "/v1.1/devices"])
            let body = try XCTUnwrap(session.requests.last?.httpBody)
            var bind = Data("\(RecoveryHTTPSession.challengeID)\ndevice_create_v11\n\(device)\n".utf8)
            bind.append(contentsOf: SHA256.hash(data: body))
            XCTAssertEqual(attester.hashes, [Data(SHA256.hash(data: bind))])
            XCTAssertEqual(attester.adopted, status == 201 ? [device] : [])
            XCTAssertEqual(session.requests.last?.value(forHTTPHeaderField: "X-HD-Attest"), "v1.ios.\(RecoveryHTTPSession.challengeID).YXR0ZXN0")
        }
    }

    func testCancelUsesExactReservedIDAndEmptyObject() async throws {
        let session = RecoveryHTTPSession([.init(200, Data("{\"contract_version\":\"1.1\",\"device_id\":\"\(device)\",\"outcome\":\"cancelled\"}".utf8))])
        _ = try await make(session).cancelDeviceIssuance(deviceID: device, as: credential)
        XCTAssertEqual(session.requests.first?.url?.path, "/v1.1/device-issuances/\(device)/cancel")
        XCTAssertEqual(session.requests.first?.httpBody, Data("{}".utf8))
    }

    func testAttestationRetryBudgetIncludesInitialHeaderlessAttempt() async throws {
        for supported in [false, true] {
            let session = RecoveryHTTPSession(Array(repeating: .init(403, error("attest_required")), count: 4))
            do { _ = try await make(session, attester: .init(supported: supported)).commitDevice(.init(deviceID: device), as: credential); XCTFail() }
            catch let error as DuoRecoveryError { XCTAssertEqual(error.code, .attestRequired) }
            let commits = session.requests.filter { $0.url?.path == "/v1.1/devices" }
            XCTAssertEqual(commits.count, supported ? 3 : 1)
            XCTAssertEqual(commits.filter { $0.value(forHTTPHeaderField: "X-HD-Attest") == nil }.count, 1)
            XCTAssertEqual(Set(commits.compactMap(\.httpBody)).count, 1)
        }
    }

    func testCleanupDeleteRetainsV1RouteButUsesCapturedCredential() async throws {
        let session = RecoveryHTTPSession([.init(204, Data())])
        let key = DuoIdempotencyKey("44444444-4444-4444-8444-444444444444")
        try await make(session).deleteMe(as: credential, .init(), key: key)
        XCTAssertEqual(session.requests.first?.url?.path, "/v1/me")
        XCTAssertEqual(session.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"), key.value)
        XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(device).\(credential.deviceSecret)")
    }

    func testCleanupDeleteClassifiesOnlyGenuineV1AuthRefusals() async throws {
        for code in ["unauthenticated", "device_revoked"] {
            let session = RecoveryHTTPSession([.init(401, error(code))])
            do { try await make(session).deleteMe(as: credential, .init(), key: .init("44444444-4444-4444-8444-444444444444")); XCTFail() }
            catch let error as DuoRecoveryError { XCTAssertEqual(error.code, .credentialRejected) }
        }
    }
}

private struct RecoveryNoOrdinaryCredential: DuoCredentialProviding {
    var credential: DuoCredential? { XCTFail("Recovery read ordinary identity"); return nil }
}

private final class RecoveryHTTPSession: DuoHTTPSession, @unchecked Sendable {
    static let challengeID = "55555555-5555-4555-8555-555555555555"
    struct Reply {
        let status: Int; let body: Data; let headers: [String: String]; let url: URL?
        init(_ status: Int, _ body: Data, headers: [String: String] = ["Content-Type": "application/json"], url: URL? = nil) {
            self.status = status; self.body = body; self.headers = headers; self.url = url
        }
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: Reply = try lock.withLock {
            recorded.append(request)
            if request.url?.path == "/v1/attest/challenge" {
                return .init(201, Data("{\"challenge_id\":\"\(Self.challengeID)\",\"challenge\":\"q83vEjRWeJBzh-nHvNkFFSIsr3Kdo6pZuL1lDGmzRpI\",\"expires_at\":\"2026-11-05T04:00:00Z\"}".utf8))
            }
            guard !replies.isEmpty else { throw URLError(.networkConnectionLost) }
            return replies.removeFirst()
        }
        return (reply.body, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }
}

private final class RecoveryHTTPAttester: DuoAttesting, @unchecked Sendable {
    let isSupported: Bool
    private let lock = NSLock()
    private var recorded: [Data] = []
    private var accepted: [String] = []
    init(supported: Bool = false) { isSupported = supported }
    var hashes: [Data] { lock.withLock { recorded } }
    var adopted: [String] { lock.withLock { accepted } }
    func hasKey(forDevice deviceID: String) -> Bool { false }
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        lock.withLock { recorded.append(clientDataHash) }
        return .init(token: "YXR0ZXN0", keyID: "pending", kind: .attestation)
    }
    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken { XCTFail("Pending issuance used assertion"); return .init(token: "", keyID: "", kind: .assertion) }
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) { lock.withLock { accepted.append(deviceID) } }
    func forgetKeys(forDevice deviceID: String) {}
}
#endif
