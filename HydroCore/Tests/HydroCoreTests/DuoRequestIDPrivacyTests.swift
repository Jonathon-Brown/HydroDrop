import XCTest
@testable import HydroCore

final class DuoRequestIDPrivacyTests: XCTestCase {
    func testOnlyWorkerIDsAreKeptAndLocationSuffixIsRemoved() throws {
        let now = Date(timeIntervalSince1970: 100)
        let valid = "0123456789abcdef"
        for raw in [valid, valid + "-LHR"] {
            var diagnostics = DuoDiagnostics()
            diagnostics.recordRequest(status: 200, requestID: raw, at: now)
            diagnostics.record(DuoTransportError.schema(.init(httpStatus: 400, requestID: raw)), duoID: nil, now: now)
            XCTAssertEqual(diagnostics.recentRequests.first?.requestID, valid)
            XCTAssertEqual(diagnostics.recentErrors.first?.requestID, valid)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self).contains("LHR"))
        }
    }

    func testNamesTokensAddressesAndMalformedIDsAreNotStoredOrShown() {
        for raw in ["Samantha", "203.0.113.7", String(repeating: "a", count: 43),
                    "0123456789ABCDEF", "0123456789abcdef-lhr", "0123456789abcdef-LHR\n",
                    "0123456789abcde", "0123456789abcdef0", "0123456789abcdef-AB1"] {
            var diagnostics = DuoDiagnostics()
            let error = DuoTransportError.schema(DuoErrorContext(httpStatus: 400, requestID: raw))
            diagnostics.recordRequest(status: 200, requestID: raw, at: Date())
            diagnostics.record(error, duoID: nil, now: Date())
            XCTAssertTrue(diagnostics.recentRequests.isEmpty, raw)
            XCTAssertNil(diagnostics.recentErrors.first?.requestID, raw)
            XCTAssertEqual(DuoUserMessage.text(for: error, context: .general), "That did not work. Please try again.", raw)
        }
    }
}
