import Foundation
import XCTest
@testable import HydroCore

/// Independent approved-contract inputs exercise the real decoder and error classifier.
/// Raw JSON cases stay raw: parsing them into a dictionary first would erase duplicates.
final class DuoRecoveryConformanceTests: XCTestCase {
    private let device = "11111111-1111-4111-8111-111111111111"
    private let secret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    private func bundled(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
        return try Data(contentsOf: url)
    }

    private func fixtures() throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bundled("d65-wire-fixtures")) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    func testApprovedResponseAndErrorFixturesThroughActualWireCodec() throws {
        var exercised = 0
        for fixture in try fixtures() {
            let schema = try XCTUnwrap(fixture["schema"] as? String)
            let name = try XCTUnwrap(fixture["id"] as? String)
            let expected = try XCTUnwrap(fixture["valid"] as? Bool)
            let payload = try XCTUnwrap(fixture["payload"] as? [String: Any])
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var accepted: Bool
            switch schema {
            case "Capabilities": accepted = (try? DuoRecoveryWire.decode(DuoRecoveryCapabilities.self, from: bytes)) != nil
            case "PrepareResponse": accepted = (try? DuoRecoveryWire.decode(DuoRecoveryIssuance.self, from: bytes)) != nil
            case "CredentialState": accepted = (try? DuoRecoveryWire.decode(DuoRecoveryCredentialState.self, from: bytes)) != nil
            case "CancelResponse": accepted = (try? DuoRecoveryWire.decode(DuoRecoveryCancelResponse.self, from: bytes)) != nil
            default:
                guard schema.hasPrefix("Error"), let status = Int(schema.dropFirst(5)) else { continue }
                let inner = payload["error"] as? [String: Any]
                let delay = (inner?["retry_after_s"] as? Int).map(String.init)
                let error = DuoRecoveryWire.classify(status: status, contentType: "application/json", retryAfter: delay,
                                                     requestID: "0123456789abcdef", body: bytes)
                accepted = error.code != nil
            }
            exercised += 1
            XCTAssertEqual(accepted, expected, name)
        }
        // Outbound request fixtures are checked below; the client never decodes requests.
        XCTAssertEqual(exercised, 72)
    }

    func testApprovedValidRequestsEncodeToThePinnedWireObjects() throws {
        for fixture in try fixtures() where fixture["valid"] as? Bool == true {
            let schema = try XCTUnwrap(fixture["schema"] as? String)
            let payload = try XCTUnwrap(fixture["payload"] as? [String: Any])
            let original = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let encoded: Data
            switch schema {
            case "PrepareRequest":
                let value = try JSONDecoder().decode(DuoRecoveryPrepareRequest.self, from: original)
                try value.validate(); encoded = try DuoRecoveryWire.encode(value)
            case "CommitRequest":
                let value = try JSONDecoder().decode(DuoRecoveryCommitRequest.self, from: original)
                try value.validate(); encoded = try DuoRecoveryWire.encode(value)
            case "RotateRequest":
                let value = try JSONDecoder().decode(DuoRecoveryRotateRequest.self, from: original)
                try value.validate(); encoded = try DuoRecoveryWire.encode(value)
            default: continue
            }
            let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            XCTAssertEqual(roundTrip, payload as NSDictionary, schema)
        }
    }

    func testRawDuplicateKeysIncludingEscapedAliasesNeverBecomeARefusal() {
        let attacks = [
            #"{"error":{"code":"credential_rejected","code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"}}"#,
            #"{"error":{"code":"credential_rejected","\u0063ode":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"}}"#,
            #"{"error":{"code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef","request\u005fid":"0123456789abcdef"}}"#,
            #"{"error":{"code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"},"error":{"code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"}}"#,
            #"{"error":{"code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"}} {}"#,
            #"{"error":{"code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"},}"#
        ]
        for text in attacks {
            let bytes = Data(text.utf8)
            XCTAssertThrowsError(try DuoRecoveryWire.validateJSON(bytes))
            XCTAssertNil(DuoRecoveryWire.classify(status: 401, contentType: "application/json", retryAfter: nil,
                                                 requestID: nil, body: bytes).code)
        }
    }

    func testScannerRejectsInvalidUTF8DepthAndBodyOverflow() throws {
        let bad = [Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d]),
                   Data((String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)).utf8),
                   Data(("{\"x\":\"" + String(repeating: "a", count: 16_384) + "\"}").utf8)]
        for data in bad { XCTAssertThrowsError(try DuoRecoveryWire.validateJSON(data)) }
        // Strings containing punctuation and escapes must not confuse structural scanning.
        try DuoRecoveryWire.validateJSON(Data(#"{"x":"{\"x\": [1,2]}","nested":{"x":true}}"#.utf8))
    }

    func testOnlyExactErrorStatusMediaAndRetryAfterAuthorizeClassification() throws {
        let refusal = Data(#"{"error":{"code":"credential_rejected","message":"Refused","request_id":"0123456789abcdef"}}"#.utf8)
        XCTAssertEqual(DuoRecoveryWire.classify(status: 401, contentType: "application/json; charset=utf-8", retryAfter: nil,
                                                requestID: nil, body: refusal).code, .credentialRejected)
        for status in [200, 400, 403, 404, 409, 500] {
            XCTAssertNil(DuoRecoveryWire.classify(status: status, contentType: "application/json", retryAfter: nil,
                                                 requestID: nil, body: refusal).code)
        }
        for media: String? in [nil, "text/html", "application/problem+json", "text/plain"] {
            XCTAssertNil(DuoRecoveryWire.classify(status: 401, contentType: media, retryAfter: nil,
                                                 requestID: nil, body: refusal).code)
        }
        let rate = Data(#"{"error":{"code":"rate_limited","message":"Later","request_id":"0123456789abcdef","retry_after_s":60}}"#.utf8)
        XCTAssertEqual(DuoRecoveryWire.classify(status: 429, contentType: "application/json", retryAfter: "60", requestID: nil, body: rate).code, .rateLimited)
        for header: String? in [nil, "61", "060", "-1", "Mon, 03 Nov 2026 00:00:00 GMT"] {
            XCTAssertNil(DuoRecoveryWire.classify(status: 429, contentType: "application/json", retryAfter: header, requestID: nil, body: rate).code)
        }
    }

    func testCanonicalSecretUUIDAndTimestampBounds() throws {
        XCTAssertTrue(DuoRecoveryWire.isSecret(secret))
        for value in [secret + "\n", secret + "=", String(secret.dropLast()) + "B", String(repeating: "A", count: 42)] {
            XCTAssertFalse(DuoRecoveryWire.isSecret(value))
        }
        XCTAssertTrue(DuoRecoveryWire.isUUID(device))
        for value in [device + "\n", device.replacingOccurrences(of: "-4111-", with: "-1111-"), device.replacingOccurrences(of: "-8111-", with: "-7111-")] {
            XCTAssertFalse(DuoRecoveryWire.isUUID(value))
        }
        for value in ["2026-02-29T00:00:00.000Z", "2026-02-30T00:00:00.000Z", "2026-11-03T24:00:00.000Z", "2026-11-03T23:59:60.000Z", "2026-11-03T00:00:00.000Z\n"] {
            XCTAssertNil(DuoRecoveryWire.timestamp(value), value)
        }
        XCTAssertNotNil(DuoRecoveryWire.timestamp("2028-02-29T00:00:00.000Z"))
    }

    func testCombiningCharactersDoNotBypassSchemaStringLength() throws {
        // JSON Schema maxLength counts Unicode scalar values, not rendered graphemes.
        let tooLongMessage = "e" + String(repeating: "\u{301}", count: 256)
        let payload: [String: Any] = ["error": ["code": "credential_rejected", "message": tooLongMessage, "request_id": "0123456789abcdef"]]
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(DuoRecoveryWire.classify(status: 401, contentType: "application/json", retryAfter: nil, requestID: nil, body: bytes).code)
        let badVersion = "e" + String(repeating: "\u{301}", count: 64)
        XCTAssertThrowsError(try DuoRecoveryPrepareRequest(appVersion: badVersion, termsVersion: 1, deviceSecret: secret).validate())
    }

    func testCredentialAndProofDescriptionsAreRedacted() {
        let credential = DuoRecoveryCredential(deviceID: device, deviceSecret: secret)
        let prepare = DuoRecoveryPrepareRequest(appVersion: "2.0", termsVersion: 1, deviceSecret: secret)
        let rotate = DuoRecoveryRotateRequest(expectedSecretVersion: 1, nextDeviceSecret: secret)
        for text in [String(describing: credential), String(reflecting: credential), String(describing: prepare), String(reflecting: prepare), String(describing: rotate), String(reflecting: rotate)] {
            XCTAssertFalse(text.contains(secret))
        }
        let proof = "PUBLIC-DUMMY-DEVICECHECK-PROOF"
        let commit = DuoRecoveryCommitRequest(deviceID: device, deviceCheckToken: proof)
        XCTAssertFalse(String(describing: commit).contains(proof))
        XCTAssertFalse(String(reflecting: commit).contains(proof))
    }
}
