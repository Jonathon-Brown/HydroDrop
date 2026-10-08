import XCTest
@testable import HydroCore

private struct TierHolder: Decodable { var tier: DuoTier }

/// What the independent review of the foundation found in HydroCore, each pinned by a test
/// (contract fidelity; consent, secrets and age). Kept apart from `DuoFoundationTests` so a
/// stage's merge never touches either.
final class DuoFoundationReviewTests: XCTestCase {
    // MARK: - Contract fidelity

    func testAnErrorEnvelopeKeepsItsSnakeCaseKeysThroughItsOwnDecoder() throws {
        let body = Data("""
        {"error":{"code":"pending_exists","message":"m","details":{"duo_id":"6d2a0000-0000-4000-8000-000000000001","active_duos":1,"min_version":"2.0","terms_version":2},"retry_after_s":30,"request_id":"r-1"}}
        """.utf8)
        let envelope = try XCTUnwrap(DuoWireErrorEnvelope.decode(body))
        XCTAssertEqual(envelope.error.code, "pending_exists")
        XCTAssertEqual(envelope.error.details?.duoId, "6d2a0000-0000-4000-8000-000000000001", "a lost create is adopted by this id")
        XCTAssertEqual(envelope.error.details?.activeDuos, 1)
        XCTAssertEqual(envelope.error.details?.minVersion, "2.0")
        XCTAssertEqual(envelope.error.details?.termsVersion, 2)
        XCTAssertEqual(envelope.error.retryAfterS, 30)
        XCTAssertEqual(envelope.error.requestId, "r-1")
        XCTAssertNil(DuoWireErrorEnvelope.decode(Data("<html>Blocked</html>".utf8)), "a WAF page is not an envelope")
    }

    func testPatchMeNeverSendsANullForAFieldTheContractDoesNotAllowToBeNull() throws {
        func json(_ request: DuoWireUpdateMeRequest) throws -> String { String(decoding: try DuoWireCoding.encode(request), as: UTF8.self) }
        XCTAssertEqual(try json(DuoWireUpdateMeRequest(skin: .null, termsVersion: .null)), "{}", "the server refuses either as 400 schema")
        XCTAssertEqual(try json(DuoWireUpdateMeRequest(displayName: .null, skin: .null)), #"{"display_name":null}"#,
                       "display_name is the one nullable field: null clears the name")
        XCTAssertEqual(try json(DuoWireUpdateMeRequest(skin: .value("forest"), termsVersion: .value(1))), #"{"skin":"forest","terms_version":1}"#)
    }

    func testAnUnknownTierReadsAsTheConservativeOneInsteadOfFailingTheWholeAnswer() throws {
        let attested = try JSONDecoder().decode(TierHolder.self, from: Data(#"{"tier":"attested"}"#.utf8))
        let low = try JSONDecoder().decode(TierHolder.self, from: Data(#"{"tier":"low"}"#.utf8))
        let unknown = try JSONDecoder().decode(TierHolder.self, from: Data(#"{"tier":"platinum"}"#.utf8))
        XCTAssertEqual(attested.tier, .attested)
        XCTAssertEqual(low.tier, .low)
        XCTAssertEqual(unknown.tier, .low)
    }

    func testARetryAfterThatIsAbsurdIsNotBelieved() {
        func wait(_ seconds: Int) -> DuoRetry.Verdict {
            DuoRetry.verdict(for: DuoTransportError(code: .maintenance, context: DuoErrorContext(httpStatus: 503, retryAfter: seconds)))
        }
        XCTAssertEqual(wait(Int(Int32.max)), .retry(after: DuoRetry.maximumDelay), "a proxy's 503 cannot park the queue for decades")
        XCTAssertEqual(wait(86_400), .retry(after: 86_400), "the server's own longest wait, a day, is honoured whole")
        XCTAssertEqual(wait(1), .retry(after: DuoRetry.minimumDelay))
    }

    func testAFailedDeleteNeverPromisesThatTheDuoWillCatchUp() {
        let maintenance = DuoTransportError(code: .maintenance, context: DuoErrorContext(httpStatus: 503, requestID: "9b1c2d3e4f5a6b7c-LHR"))
        XCTAssertTrue(DuoUserMessage.text(for: maintenance, context: .general).contains("catch up"), "an ordinary sync can say it")
        for error in [maintenance, DuoTransportError.unreadable(httpStatus: 200, requestID: "9b1c2d3e4f5a6b7c-LHR")] {
            let text = DuoUserMessage.text(for: error, context: .deletion)
            XCTAssertFalse(text.contains("catch up"), "nothing is queued for a delete, so nothing will catch up: \(text)")
            XCTAssertEqual(text, "\(DuoUserMessage.generic) (ref 9b1c2d3e4f5a6b7c-LHR)")
        }
        XCTAssertEqual(DuoUserMessage.text(for: DuoTransportError.offline, context: .deletion), "No connection right now. Try again in a bit.")
    }

    func testTheLedgerForgetsANudgeUnderItsBareId() {
        var ledger = DuoLedger()
        _ = ledger.markSeen("nudge-3B9E1C2A-0000-4000-8000-000000000000")
        _ = ledger.markSeen("nudge-3B9E1C2A-0000-4000-8000-000000000001")
        _ = ledger.markSeen("met|\(UUID().uuidString.lowercased())|2026-10-08")
        ledger.forget(nudgeIDs: ["nudge-3B9E1C2A-0000-4000-8000-000000000000"])
        XCTAssertEqual(ledger.seen.count, 2)
        XCTAssertFalse(ledger.seen.contains("nudge-3B9E1C2A-0000-4000-8000-000000000000"))
        XCTAssertTrue(ledger.seen.contains("nudge-3B9E1C2A-0000-4000-8000-000000000001"), "only the ids named")
    }

    func testAnUnreadableRateLimitIsWaitedOutLikeAnyOther() {
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unreadable(httpStatus: 429, requestID: nil)), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unreadable(httpStatus: 503, requestID: nil)), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unreadable(httpStatus: 404, requestID: nil)), .fail, "other statuses are still not retried")
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unreadable(httpStatus: 204, requestID: nil)), .fail, "an unreadable 2xx is told, never retried")
    }

    // MARK: - Secrets and age

    func testARequestIdOffAFailureIsCheckedLikeOneOffAResponse() {
        var diagnostics = DuoDiagnostics()
        func record(_ id: String?) -> String? {
            diagnostics.record(DuoTransportError(code: .maintenance, context: DuoErrorContext(httpStatus: 503, requestID: id)), duoID: nil, now: Date())
            return diagnostics.recentErrors.first?.requestID
        }
        XCTAssertEqual(record("9b1c-YYZ"), "9b1c-YYZ")
        XCTAssertNil(record("has spaces & <tags>"))
        XCTAssertNil(record(String(repeating: "a", count: DuoDiagnostics.maximumRequestIDLength + 1)))
        XCTAssertNil(record("é-not-ascii"))
        XCTAssertNil(record(nil))
    }

    func testThePendingInvitesSecretIsNeverEncoded() throws {
        let secret = "ABCDEFGHJKMNPQRSTVWXYZ0123"
        let invite = DuoPendingInvite(code: "H7K39QWX", k: secret, receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try JSONEncoder().encode(invite)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ABCDEFGHJK"), "the App Group defaults must never hold k")
        let back = try JSONDecoder().decode(DuoPendingInvite.self, from: data)
        XCTAssertEqual(back.code, "H7K39QWX")
        XCTAssertEqual(back.receivedAt, invite.receivedAt)
        XCTAssertNil(back.k, "a kill before the Join tap leaves a typed-code join, which §4.1 allows")
        XCTAssertEqual(invite.k, secret, "in memory it is still there for the tap")
    }

    func testTheAgeRuleReadsTheYearInTheGregorianCalendarWhateverCalendarIsCurrent() {
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026
        let calendars: [Calendar.Identifier] = [.gregorian, .buddhist, .japanese, .hebrew, .islamicCivil, .persian, .republicOfChina]
        for identifier in calendars {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            XCTAssertEqual(DuoAgeGate.decide(birthYear: 2019, now: now, calendar: calendar), .refused, "a seven-year-old, \(identifier)")
            XCTAssertEqual(DuoAgeGate.decide(birthYear: 2000, now: now, calendar: calendar), .allowed, "an adult, \(identifier)")
            XCTAssertEqual(DuoAgeGate.decide(birthYear: 2999, now: now, calendar: calendar), .unknown, "a year in the future, \(identifier)")
        }
    }

    func testAWrongPhoneClockCannotLockAnAdultOut() {
        let calendar = Calendar(identifier: .gregorian)
        let unsetClock = Date(timeIntervalSince1970: 978_307_200) // 2001-01-01
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 1990, now: unsetClock, calendar: calendar), .allowed,
                       "a refusal is final, so a clock set years back must not make an adult's answer one")
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2019, now: unsetClock, calendar: calendar), .refused, "a child is still refused")
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2026, now: unsetClock, calendar: calendar), .refused, "and so is one born this year")
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2999, now: unsetClock, calendar: calendar), .unknown)
    }

    func testALedgerForgetsEveryKeyOfOneDuoAndOnlyThatDuo() {
        let a = UUID()
        let b = UUID()
        var ledger = DuoLedger()
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: a, day: "2026-10-06"))
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: a, day: "2026-10-07"))
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: b, day: "2026-10-07"))
        ledger.forget(duoID: a)
        XCTAssertEqual(ledger.seen, [DuoLedger.goalKey(duoID: b, day: "2026-10-07")], "Clear takes a duo's ledger keys with it (§12.2)")
    }

    func testTheErrorSheetShowsOnlyAReferenceThatIsSafeToShow() {
        func text(_ id: String?) -> String {
            DuoUserMessage.text(for: DuoTransportError(code: .schema, context: DuoErrorContext(httpStatus: 400, requestID: id)))
        }
        XCTAssertEqual(text("9b1c-YYZ"), "\(DuoUserMessage.generic) (ref 9b1c-YYZ)")
        let hostile = "call 555-0100 or visit https://evil.example/ now <b>" + String(repeating: "x", count: 200)
        XCTAssertEqual(text(hostile), DuoUserMessage.generic, "an id off a body is the server's to write, so it is not printed unfiltered")
        XCTAssertEqual(text(nil), DuoUserMessage.generic)
    }
}
