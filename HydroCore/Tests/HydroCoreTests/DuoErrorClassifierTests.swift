import XCTest
@testable import HydroCore

/// `DuoErrorClassifier`, row by row: final design §6.0's last bullet, §6.7's table, D63 and the
/// KV15 cases. The statuses each code may come with are contract-v1's own (`x-error-codes` on
/// every operation's responses, read off `openapi.json` at the tag), so a code that moved to
/// another status in a later contract would show here as a row to revisit.
final class DuoErrorClassifierTests: XCTestCase {
    private static let contractStatuses: [DuoErrorCode: [Int]] = [
        .schema: [400, 422], .idempotencyMismatch: [422], .unauthenticated: [401], .deviceRevoked: [401], .banned: [403],
        .blocked: [403], .notPartner: [403], .attestRequired: [403], .attestInvalid: [403], .duoUnknown: [404],
        .inviteUnknown: [404], .inviteTaken: [409], .inviteOwn: [409], .wrongPurpose: [409], .alreadyInDuo: [409],
        .duoLimit: [409], .deviceLimit: [409], .pendingExists: [409], .memberNotFresh: [409], .targetActive: [409],
        .duoEnded: [409], .duoPending: [409], .partnerAlreadyMet: [409], .conflict: [409], .payloadTooLarge: [413],
        .nameRejected: [422], .presetUnknown: [422], .dayOutOfRange: [422], .senderDayOutOfRange: [422],
        .upgradeRequired: [426], .termsRequired: [428], .nudgeLimit: [429], .rateLimited: [429], .maintenance: [503],
    ]

    private let html = "text/html; charset=UTF-8"
    private let waf = Data("<!DOCTYPE html><html><body>Sorry, you have been blocked</body></html>".utf8)

    private func envelope(_ code: String, details: String? = nil, retryAfterS: String? = nil, requestID: String? = "body-id") -> Data {
        var fields = [#""code":"\#(code)""#, #""message":"for logs""#]
        if let details { fields.append(#""details":\#(details)"#) }
        if let retryAfterS { fields.append(#""retry_after_s":\#(retryAfterS)"#) }
        if let requestID { fields.append(#""request_id":"\#(requestID)""#) }
        return Data(#"{"error":{\#(fields.joined(separator: ","))}}"#.utf8)
    }

    private func classify(_ status: Int, _ contentType: String?, retryAfter: String? = nil, requestID: String? = nil,
                          _ body: Data) -> DuoTransportError {
        DuoErrorClassifier.classify(status: status, contentType: contentType, retryAfter: retryAfter, requestID: requestID, body: body)
    }

    /// The same, as the server sends it: `application/json`.
    private func classify(_ status: Int, retryAfter: String? = nil, requestID: String? = nil, _ body: Data) -> DuoTransportError {
        classify(status, "application/json", retryAfter: retryAfter, requestID: requestID, body)
    }

    // MARK: - The server's envelope

    func testEveryKnownCodeInEachOfItsStatusesMapsToItsOwnCaseWithItsContext() {
        XCTAssertEqual(Set(Self.contractStatuses.keys), Set(DuoErrorCode.allCases), "every code of the contract has its statuses here")
        for code in DuoErrorCode.allCases {
            for status in Self.contractStatuses[code] ?? [] {
                let error = classify(status, retryAfter: "45", requestID: "hdr-1", envelope(code.rawValue, details: #"{"max":5}"#))
                XCTAssertEqual(error, DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "hdr-1",
                                                                                              retryAfter: 45, details: DuoWireErrorDetails(max: 5))),
                               "\(code.rawValue) at \(status)")
                XCTAssertEqual(error.code, code)
            }
        }
    }

    func testTheContextKeepsEveryDetailTheBodyCarries() {
        let error = classify(409, envelope("pending_exists", details: #"{"duo_id":"6d2a0000-0000-4000-8000-000000000001","active_duos":1,"max":5}"#))
        XCTAssertEqual(error.context?.details?.duoId, "6d2a0000-0000-4000-8000-000000000001", "a lost create is adopted by this id")
        XCTAssertEqual(error.context?.details?.activeDuos, 1)
        XCTAssertEqual(error.context?.details?.max, 5)
        XCTAssertEqual(error.requestID, "body-id")
        let terms = classify(428, envelope("terms_required", details: #"{"terms_version":2}"#))
        XCTAssertEqual(terms.context?.details?.termsVersion, 2)
        let upgrade = classify(426, envelope("upgrade_required", details: #"{"min_version":"2.0"}"#))
        XCTAssertEqual(upgrade.context?.details?.minVersion, "2.0")
        let attest = classify(403, envelope("attest_required", details: #"{"retryable":true}"#))
        XCTAssertEqual(attest.context?.details?.retryable, true)
    }

    func testTheRetryAfterHeaderBeatsTheBodysRetryAfterS() {
        XCTAssertEqual(classify(429, retryAfter: "120", envelope("rate_limited", retryAfterS: "90")).context?.retryAfter, 120)
        XCTAssertEqual(classify(429, envelope("rate_limited", retryAfterS: "90")).context?.retryAfter, 90, "the body when there is no header")
        XCTAssertEqual(classify(429, retryAfter: "soon", envelope("nudge_limit", retryAfterS: "90")).context?.retryAfter, 90,
                       "a header that is not whole seconds is ignored, and the body's number used")
        XCTAssertNil(classify(429, envelope("rate_limited")).context?.retryAfter, "neither: nothing, and the verdict's own fallback applies")
    }

    func testTheRequestIDHeaderBeatsTheBodysAndAnUnusableOneFallsBackToIt() {
        XCTAssertEqual(classify(409, requestID: "9b1c2d3e4f5a6b7c-LHR", envelope("conflict", requestID: "body-id")).requestID, "9b1c2d3e4f5a6b7c-LHR")
        XCTAssertEqual(classify(409, envelope("conflict", requestID: "body-id")).requestID, "body-id")
        XCTAssertEqual(classify(409, requestID: "has spaces <and> tags", envelope("conflict", requestID: "body-id")).requestID, "body-id",
                       "a header that could not be printed safely does not hide the body's id")
        XCTAssertEqual(classify(409, requestID: "", envelope("conflict", requestID: "body-id")).requestID, "body-id")
        XCTAssertNil(classify(409, envelope("conflict", requestID: String(repeating: "a", count: DuoDiagnostics.maximumRequestIDLength + 1))).requestID,
                     "an absurd id is kept nowhere")
        XCTAssertNil(classify(409, envelope("conflict", requestID: nil)).requestID)
        XCTAssertEqual(classify(403, html, requestID: "9b1c-LHR", waf).requestID, "9b1c-LHR", "a WAF page keeps the header's id")
        XCTAssertEqual(classify(404, html, requestID: "9b1c-LHR", waf), .unreadable(httpStatus: 404, requestID: "9b1c-LHR"))
    }

    func testJunkAndNegativeRetryAfterValuesAreIgnored() {
        for junk in ["-5", "+30", "1.5", "30s", "Wed, 21 Oct 2026 07:28:00 GMT", "", " ", "0x1E", "３０", "99999999999999999999999",
                     String(DuoErrorClassifier.maximumRetryAfter + 1)] {
            XCTAssertNil(classify(503, html, retryAfter: junk, waf).context?.retryAfter, "header \(junk.debugDescription)")
            XCTAssertEqual(classify(429, html, retryAfter: junk, waf).context?.retryAfter, 60, "a WAF 429's fallback, header \(junk.debugDescription)")
        }
        XCTAssertNil(classify(429, envelope("rate_limited", retryAfterS: "-5")).context?.retryAfter, "a negative retry_after_s")
        XCTAssertNil(classify(429, envelope("rate_limited", retryAfterS: #""30""#)).context?.retryAfter, "a retry_after_s that is a string")
        XCTAssertEqual(classify(429, envelope("rate_limited", retryAfterS: "-5")).code, .rateLimited, "and the error itself still classifies")
        XCTAssertEqual(classify(503, html, retryAfter: " 30 ", waf).context?.retryAfter, 30, "spaces around the number are not junk")
        XCTAssertEqual(classify(503, html, retryAfter: "0", waf).context?.retryAfter, 0, "zero is a delay the contract allows")
        XCTAssertEqual(classify(503, html, retryAfter: "007", waf).context?.retryAfter, 7)
        XCTAssertEqual(classify(503, html, retryAfter: String(DuoErrorClassifier.maximumRetryAfter), waf).context?.retryAfter,
                       DuoErrorClassifier.maximumRetryAfter)
    }

    func testAnUnknownJSONCodeIsUnreadableOrMaintenanceByItsStatus() {
        XCTAssertEqual(classify(409, requestID: "r-1", envelope("duo_frozen")), .unreadable(httpStatus: 409, requestID: "r-1"))
        XCTAssertEqual(classify(502, retryAfter: "10", requestID: "r-1", envelope("duo_frozen")),
                       .maintenance(DuoErrorContext(httpStatus: 502, requestID: "r-1", retryAfter: 10)))
        XCTAssertEqual(classify(401, requestID: "r-1", envelope("token_expired")), .unreadable(httpStatus: 401, requestID: "r-1"),
                       "a 401 with a code this build does not know forgets nothing")
        XCTAssertEqual(DuoRetry.verdict(for: classify(401, envelope("token_expired"))), .fail)
        XCTAssertEqual(classify(429, envelope("slow_down")), .rateLimited(DuoErrorContext(httpStatus: 429, requestID: "body-id", retryAfter: 60)),
                       "a 429 is a rate limit whatever its code: a newer server's is waited out, a minute when it says nothing")
        XCTAssertEqual(classify(429, retryAfter: "15", envelope("slow_down", retryAfterS: "20")).context?.retryAfter, 15)
        XCTAssertEqual(classify(429, envelope("slow_down", retryAfterS: "20")).context?.retryAfter, 20)
        XCTAssertEqual(DuoRetry.verdict(for: classify(429, envelope("slow_down"))), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(classify(413, envelope("too_big")), .unreadable(httpStatus: 413, requestID: "body-id"),
                       "outside 429 and 5xx an unknown code is still unreadable")
        XCTAssertEqual(classify(500, envelope("UNAUTHENTICATED")).code, .maintenance, "codes are matched exactly, never re-cased")
    }

    func testTheFiveCodesThatChangeStandingAreBelievedOnlyAtTheirOwnStatus() {
        // Each at its own status: believed.
        XCTAssertEqual(classify(401, envelope("unauthenticated")).code, .unauthenticated)
        XCTAssertEqual(classify(401, envelope("device_revoked")).code, .deviceRevoked)
        XCTAssertEqual(classify(403, envelope("banned")).code, .banned)
        XCTAssertEqual(classify(404, envelope("duo_unknown")).code, .duoUnknown)
        XCTAssertEqual(classify(409, envelope("duo_ended")).code, .duoEnded)
        // Anywhere else: the status alone decides, keeping the envelope's id and delay.
        let rows: [(String, Int, DuoTransportError)] = [
            ("unauthenticated", 403, .maintenance(DuoErrorContext(httpStatus: 403, requestID: "body-id", retryAfter: 30))),
            ("unauthenticated", 400, .unreadable(httpStatus: 400, requestID: "body-id")),
            ("unauthenticated", 500, .maintenance(DuoErrorContext(httpStatus: 500, requestID: "body-id", retryAfter: 30))),
            ("device_revoked", 503, .maintenance(DuoErrorContext(httpStatus: 503, requestID: "body-id", retryAfter: 30))),
            ("device_revoked", 409, .unreadable(httpStatus: 409, requestID: "body-id")),
            ("banned", 500, .maintenance(DuoErrorContext(httpStatus: 500, requestID: "body-id", retryAfter: 30))),
            ("banned", 401, .maintenance(DuoErrorContext(httpStatus: 401, requestID: "body-id", retryAfter: 30))),
            ("banned", 429, .rateLimited(DuoErrorContext(httpStatus: 429, requestID: "body-id", retryAfter: 30))),
            ("duo_unknown", 409, .unreadable(httpStatus: 409, requestID: "body-id")),
            ("duo_unknown", 410, .unreadable(httpStatus: 410, requestID: "body-id")),
            ("duo_ended", 404, .unreadable(httpStatus: 404, requestID: "body-id")),
            ("duo_ended", 502, .maintenance(DuoErrorContext(httpStatus: 502, requestID: "body-id", retryAfter: 30))),
        ]
        for (code, status, expected) in rows {
            let error = classify(status, envelope(code, retryAfterS: "30"))
            XCTAssertEqual(error, expected, "\(code) at \(status)")
            XCTAssertFalse([DuoRetry.Verdict.reidentify, .disconnected, .banned, .ended].contains(DuoRetry.verdict(for: error)),
                           "\(code) at \(status) must not change who this phone is or end a duo")
        }
        // Every other code is taken at its word wherever it comes.
        XCTAssertEqual(classify(400, envelope("pending_exists")).code, .pendingExists)
        XCTAssertEqual(classify(409, envelope("blocked")).code, .blocked)
        XCTAssertEqual(classify(500, envelope("upgrade_required")).code, .upgradeRequired)
        for code in DuoErrorCode.allCases {
            let standing: Set<DuoErrorCode> = [.unauthenticated, .deviceRevoked, .banned, .duoUnknown, .duoEnded]
            XCTAssertEqual(DuoErrorClassifier.isBelieved(code, at: 418), !standing.contains(code), code.rawValue)
        }
    }

    func testTheHeadersRequestIDIsXRequestIdElseCFRay() {
        XCTAssertEqual(DuoErrorClassifier.headerRequestID(xRequestID: "9b1c2d3e4f5a6b7c-LHR", cfRay: "aaaa-YYZ"), "9b1c2d3e4f5a6b7c-LHR")
        XCTAssertEqual(DuoErrorClassifier.headerRequestID(xRequestID: nil, cfRay: "8a0b1c2d3e4f5a6b-YYZ"), "8a0b1c2d3e4f5a6b-YYZ")
        XCTAssertEqual(DuoErrorClassifier.headerRequestID(xRequestID: "bad id <x>", cfRay: "8a0b1c2d3e4f5a6b-YYZ"), "8a0b1c2d3e4f5a6b-YYZ",
                       "an unusable X-Request-Id does not hide a usable CF-Ray")
        XCTAssertNil(DuoErrorClassifier.headerRequestID(xRequestID: nil, cfRay: "has spaces"))
        XCTAssertNil(DuoErrorClassifier.headerRequestID(xRequestID: nil, cfRay: nil))
        let fromRay = DuoErrorClassifier.headerRequestID(xRequestID: nil, cfRay: "8a0b1c2d3e4f5a6b-YYZ")
        XCTAssertEqual(classify(403, html, requestID: fromRay, waf).requestID, "8a0b1c2d3e4f5a6b-YYZ", "a WAF page's CF-Ray is quoted")
        XCTAssertEqual(classify(409, requestID: fromRay, envelope("conflict", requestID: "body-id")).requestID, "8a0b1c2d3e4f5a6b-YYZ",
                       "the headers' id still comes before the body's")
    }

    func testAWrongTypedDetailsValueStillClassifies() {
        let error = classify(409, envelope("duo_limit", details: #"{"active_duos":"three","max":5,"duo_id":7}"#))
        XCTAssertEqual(error.code, .duoLimit)
        XCTAssertNil(error.context?.details?.activeDuos)
        XCTAssertEqual(error.context?.details?.max, 5)
        XCTAssertNil(error.context?.details?.duoId)
        let notAnObject = classify(409, envelope("duo_limit", details: #"[1,2]"#))
        XCTAssertEqual(notAnObject.code, .duoLimit, "details that are not an object are dropped, never the error")
        XCTAssertNil(notAnObject.context?.details)
    }

    // MARK: - Anything else, by status alone

    func testAPageThatIsNotTheEnvelopeIsClassifiedByItsStatusAlone() {
        XCTAssertEqual(classify(401, html, requestID: "r", waf), .maintenance(DuoErrorContext(httpStatus: 401, requestID: "r")),
                       "D63: a bare 401 is a captive portal or a proxy, not a gone identity")
        XCTAssertEqual(classify(403, html, waf), .maintenance(DuoErrorContext(httpStatus: 403)), "a WAF page is never banned")
        XCTAssertEqual(classify(503, html, retryAfter: "120", waf), .maintenance(DuoErrorContext(httpStatus: 503, retryAfter: 120)))
        XCTAssertEqual(classify(413, html, waf), .schema(DuoErrorContext(httpStatus: 413)))
        XCTAssertEqual(classify(429, html, retryAfter: "30", waf), .rateLimited(DuoErrorContext(httpStatus: 429, retryAfter: 30)))
        XCTAssertEqual(classify(429, html, waf), .rateLimited(DuoErrorContext(httpStatus: 429, retryAfter: 60)))
        for status in [500, 502, 504, 520, 522, 599] {
            XCTAssertEqual(classify(status, html, waf), .maintenance(DuoErrorContext(httpStatus: status)), "\(status)")
        }
        for status in [300, 304, 400, 404, 405, 409, 410, 422, 426, 428, 451, 600] {
            XCTAssertEqual(classify(status, html, waf), .unreadable(httpStatus: status, requestID: nil), "\(status)")
        }
    }

    func testD63AJSONBodyThatIsNotTheEnvelopeIsNotTheServerEither() {
        let gateway = Data(#"{"message":"Unauthorized"}"#.utf8)
        XCTAssertEqual(classify(401, gateway), .maintenance(DuoErrorContext(httpStatus: 401)), "JSON without error.code is someone else's")
        XCTAssertEqual(classify(401, Data()), .maintenance(DuoErrorContext(httpStatus: 401)), "an empty 401")
        XCTAssertEqual(classify(401, nil, Data()), .maintenance(DuoErrorContext(httpStatus: 401)), "no Content-Type at all")
        XCTAssertEqual(classify(401, nil, envelope("unauthenticated")), .maintenance(DuoErrorContext(httpStatus: 401)),
                       "the server's own envelope with no Content-Type is not the server: the identity is not forgotten for it")
        XCTAssertEqual(classify(403, nil, envelope("banned")).code, .maintenance, "nor is anyone barred for it")
        XCTAssertEqual(classify(401, Data(#"{"error":{"message":"no code"}}"#.utf8)), .maintenance(DuoErrorContext(httpStatus: 401)))
        XCTAssertEqual(classify(401, Data(#"{"error":"unauthenticated"}"#.utf8)), .maintenance(DuoErrorContext(httpStatus: 401)))
        XCTAssertEqual(classify(401, html, envelope("unauthenticated")), .maintenance(DuoErrorContext(httpStatus: 401)),
                       "the envelope's words under an HTML Content-Type are not the server's")
        XCTAssertEqual(DuoRetry.verdict(for: classify(401, html, waf)), .retry(after: DuoRetry.fallbackDelay), "and so nothing is forgotten")
        // The server's own 401s still mean what §3.4 says.
        XCTAssertEqual(classify(401, envelope("unauthenticated")).code, .unauthenticated)
        XCTAssertEqual(DuoRetry.verdict(for: classify(401, envelope("unauthenticated"))), .reidentify)
        XCTAssertEqual(classify(401, envelope("device_revoked")).code, .deviceRevoked)
        XCTAssertEqual(DuoRetry.verdict(for: classify(401, envelope("device_revoked"))), .disconnected)
    }

    func testBannedAndBlockedAreReadOnlyFromAJSONCode() {
        XCTAssertEqual(classify(403, envelope("banned")).code, .banned)
        XCTAssertEqual(classify(403, envelope("blocked")).code, .blocked)
        for body in [waf, Data("banned".utf8), Data("blocked".utf8), Data()] {
            for contentType in [html, "text/plain", nil] {
                let error = classify(403, contentType, body)
                XCTAssertEqual(error.code, .maintenance, "\(contentType ?? "none"): \(String(decoding: body, as: UTF8.self))")
                XCTAssertNotEqual(DuoRetry.verdict(for: error), .banned)
            }
        }
    }

    func testTheJSONContentTypeIsReadAsAMediaType() {
        for contentType in ["application/json", "application/json; charset=utf-8", "Application/JSON", " application/json ;charset=UTF-8"] {
            XCTAssertEqual(classify(403, contentType, envelope("banned")).code, .banned, contentType)
        }
        for contentType in ["text/json", "application/jsonp", "application/problem+json", "text/html", "application/json-seq", ""] {
            XCTAssertEqual(classify(403, contentType, envelope("banned")).code, .maintenance, contentType)
        }
    }

    // MARK: - KV15

    func testTheFourKV15CasesOfTheDesign() {
        let banned = classify(403, envelope("banned"))
        XCTAssertEqual(banned.code, .banned)
        XCTAssertEqual(DuoRetry.verdict(for: banned), .banned)
        XCTAssertEqual(DuoUserMessage.text(for: banned), "Duo Streaks are not available for this device. Contact support@hydrodrop.us.",
                       "the banned copy")

        let forbidden = classify(403, html, waf)
        XCTAssertEqual(forbidden, .maintenance(DuoErrorContext(httpStatus: 403)))
        XCTAssertEqual(DuoRetry.verdict(for: forbidden), .retry(after: DuoRetry.fallbackDelay))

        let limited = classify(429, html, retryAfter: "30", waf)
        XCTAssertEqual(limited, .rateLimited(DuoErrorContext(httpStatus: 429, retryAfter: 30)))
        XCTAssertEqual(DuoRetry.verdict(for: limited), .retry(after: 30))

        let unknown = classify(404, envelope("duo_unknown"))
        XCTAssertEqual(unknown.code, .duoUnknown)
        XCTAssertEqual(DuoRetry.verdict(for: unknown), .ended, "on a cached duo: mark it ended locally, no alert")
    }

    func testTheKV15VectorsAgreeWithTheirStatedAnswers() {
        let cases = Vectors.apiCases()
        XCTAssertEqual(Set(cases.map(\.id)), ["KV15.jsonBanned", "KV15.htmlForbidden", "KV15.html429", "KV15.html429NoRetryAfter",
                                              "KV15.jsonDuoUnknown", "KV15.html401", "KV15.json401", "KV15.html413", "KV15.html502",
                                              "KV15.jsonUnknownCode409", "KV15.jsonUnknownCode429", "KV15.jsonRateLimited",
                                              "KV15.jsonBannedAt500", "KV15.jsonUnauthenticatedAt403", "KV15.jsonDeviceRevokedAt503",
                                              "KV15.jsonDuoUnknownAt409", "KV15.jsonDuoEndedAt404"])
        for vector in cases {
            XCTAssertEqual(vector.fn, "DuoErrorClassifier.classify")
            XCTAssertEqual(vector.expect.rendered, vector.spec?.rendered, vector.id)
        }
        let html401 = cases.first { $0.id == "KV15.html401" }
        XCTAssertEqual(html401?.expect.rendered, #"{"code":"maintenance","retryAfter":null,"verdict":"retry:60"}"#, "D63's own vector")
    }
}
