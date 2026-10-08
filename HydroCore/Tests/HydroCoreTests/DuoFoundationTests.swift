import XCTest
@testable import HydroCore

/// The foundation's own tests: the wire contract, the error table, invite codes, time, the
/// mapping from wire to domain, push payloads and rejected days. Each stage adds its own
/// test files beside this one and leaves it alone.
final class DuoFoundationTests: XCTestCase {
    // MARK: - RFC 3339 (KV4)

    func testEveryFormOfTheSameInstantReadsAsTheSameInstant() throws {
        let expected = try XCTUnwrap(DuoWireTime.parse("2026-09-24T18:11:09Z"))
        XCTAssertEqual(DuoWireTime.parse("2026-09-24T18:11:09.123Z")?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970 + 0.123, accuracy: 0.001)
        XCTAssertEqual(DuoWireTime.parse("2026-09-24T18:11:09+00:00"), expected)
        XCTAssertEqual(DuoWireTime.parse("2026-09-25T03:11:09+09:00"), expected)
        XCTAssertEqual(DuoWireTime.parse("2026-09-24T13:11:09-05:00"), expected)
        XCTAssertEqual(DuoWireTime.parse("2026-09-24t18:11:09z"), expected)
    }

    func testTimeIsAlwaysWrittenAsTheContractWritesIt() throws {
        XCTAssertEqual(DuoWireTime.format(try XCTUnwrap(DuoWireTime.parse("2026-09-24T18:11:09.987Z"))), "2026-09-24T18:11:09Z")
        XCTAssertEqual(DuoWireTime.format(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(DuoWireTime.format(Date(timeIntervalSince1970: -1)), "1969-12-31T23:59:59Z")
        XCTAssertEqual(DuoWireTime.format(Date(timeIntervalSince1970: 1_835_481_599)), "2028-02-29T23:59:59Z")
    }

    func testAnythingThatIsNotARealDateTimeIsRefused() {
        for text in ["", "2026-09-24", "2026-09-24T18:11:09", "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z",
                     "2026-09-24T24:00:00Z", "2026-09-24T18:11:09+0900", "2026-09-24T18:11:09.Z", "2026-09-24 18:11:09Z"] {
            XCTAssertNil(DuoWireTime.parse(text), text)
        }
        XCTAssertEqual(DuoWireTime.parse("2026-12-31T23:59:60Z"), DuoWireTime.parse("2026-12-31T23:59:59Z"), "a leap second reads as :59")
    }

    func testTimeRoundTripsAcrossManyInstants() throws {
        var seconds: Int64 = -2_000_000_000
        while seconds < 4_000_000_000 {
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            XCTAssertEqual(DuoWireTime.parse(DuoWireTime.format(date)), date)
            seconds += 7_654_321
        }
    }

    // MARK: - Invite codes and links (KV1)

    func testACodeIsNormalisedTheWayThePersonMeantIt() {
        XCTAssertEqual(DuoInviteCode.normalize("h7k3-9qwx"), "H7K39QWX")
        XCTAssertEqual(DuoInviteCode.normalize("H7K3 9QWX"), "H7K39QWX")
        XCTAssertEqual(DuoInviteCode.normalize("H7KO-9QWX"), "H7K09QWX")
        XCTAssertEqual(DuoInviteCode.normalize("H7KI-9QWL"), "H7K19QW1")
    }

    func testAnythingElseIsNotACode() {
        XCTAssertNil(DuoInviteCode.normalize("H7K3-9QWU"), "U is not in the alphabet")
        XCTAssertNil(DuoInviteCode.normalize("H7K39QW"))
        XCTAssertNil(DuoInviteCode.normalize("H7K39QWXX"))
        XCTAssertNil(DuoInviteCode.normalize("ßßßßßß"), "case folding must never make letters of a code out of other characters")
        XCTAssertNil(DuoInviteCode.normalize("H7K３9QWX"), "a full-width digit is not a digit of a code")
        XCTAssertEqual(DuoInviteCode.display("H7K39QWX"), "H7K3-9QWX")
    }

    func testOnlyTheStrictLinkIsALink() throws {
        let secret = "ABCDEFGHJKMNPQRSTVWXYZ0123"
        func parse(_ text: String) -> DuoParsedInvite? { URL(string: text).flatMap(DuoLink.parse) }
        XCTAssertEqual(parse("https://hydrodrop.us/duo#H7K39QWX"), DuoParsedInvite(code: "H7K39QWX"))
        XCTAssertEqual(parse("https://hydrodrop.us/duo#h7k39qwx.\(secret)"), DuoParsedInvite(code: "H7K39QWX", k: secret))
        XCTAssertNil(parse("http://hydrodrop.us/duo#H7K39QWX.\(secret)"))
        XCTAssertNil(parse("https://hydrodrop.us/duo?c=H7K39QWX"))
        XCTAssertNil(parse("https://hydrodrop.us/tap#H7K39QWX"))
        XCTAssertNil(parse("https://example.com/duo#H7K39QWX"))
        XCTAssertNil(parse("https://hydrodrop.us/duo#H7K39QWX.SHORT"), "a secret of the wrong length makes the whole link invalid")
        XCTAssertNil(parse("https://hydrodrop.us/duo#H7K39QWX.abcdefghjkmnpqrstvwxyz0123"), "the secret is kept verbatim, so lower case is not one")
        XCTAssertEqual(DuoLink.url(code: "H7K39QWX", k: secret)?.absoluteString, "https://hydrodrop.us/duo#H7K39QWX.\(secret)")
        XCTAssertEqual(DuoInviteCode.parse(pasted: " https://hydrodrop.us/duo#H7K39QWX \n"), DuoParsedInvite(code: "H7K39QWX"))
        XCTAssertEqual(DuoInviteCode.parse(pasted: "h7k3 9qwx"), DuoParsedInvite(code: "H7K39QWX"))
    }

    func testALinkSecretIs128BitsOfCrockfordInTwentySixCharacters() {
        let secret = DuoLinkSecret.make(random: SequentialRandom())
        XCTAssertEqual(secret.count, 26)
        XCTAssertTrue(DuoInviteCode.isLinkSecret(secret))
        XCTAssertNotEqual(secret, DuoLinkSecret.make(random: DuoSystemRandom()))
        XCTAssertEqual(DuoLinkSecret.make(random: FixedRandom(byte: 0xFF)), String(repeating: "Z", count: 25) + "W", "the last character holds only three bits")
    }

    // MARK: - The wire, as written

    func testBodiesAreWrittenWithSortedSnakeCaseKeys() throws {
        let body = DuoWirePutStatusesRequest(myToday: "2026-09-24", since: 410,
                                             statuses: [DuoWireStatusIn(day: "2026-09-24", goalMet: false, progressBucket: 50, baseVer: 3)])
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(body), as: UTF8.self),
                       #"{"my_today":"2026-09-24","since":410,"statuses":[{"base_ver":3,"day":"2026-09-24","goal_met":false,"progress_bucket":50}]}"#)
        let nudge = DuoWireSendNudgeRequest(id: "nudge-3B9E1C2A-0000-4000-8000-000000000000", presetId: "waterBreak", senderDay: "2026-09-24")
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(nudge), as: UTF8.self),
                       #"{"id":"nudge-3B9E1C2A-0000-4000-8000-000000000000","preset_id":"waterBreak","sender_day":"2026-09-24"}"#)
    }

    func testANameThatIsRequiredButEmptyIsSentAsNull() throws {
        let create = DuoWireCreateDuoRequest(displayName: nil, skin: "classic", myToday: "2026-09-24", e2eeCapable: true, statuses: [])
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(create), as: UTF8.self),
                       #"{"display_name":null,"e2ee_capable":true,"my_today":"2026-09-24","skin":"classic","statuses":[]}"#)
        let redeem = DuoWireRedeemRequest(code: "H7K39QWX", displayName: "Sam", skin: "forest", myToday: "2026-09-24", e2eeCapable: false, statuses: [], deviceCheckToken: nil)
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(redeem), as: UTF8.self),
                       #"{"code":"H7K39QWX","display_name":"Sam","e2ee_capable":false,"my_today":"2026-09-24","skin":"forest","statuses":[]}"#)
    }

    func testTheTwoRequestsThatHadNoDecoderReadBackWhatTheyWrote() throws {
        func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
            let bytes = try DuoWireCoding.encode(value)
            let back = try DuoWireCoding.decode(T.self, from: bytes)
            // Equatable compares strings by canonical equivalence ("é" typed two ways is equal) and
            // the replay is byte for byte, so the bytes are compared too.
            XCTAssertEqual(try DuoWireCoding.encode(back), bytes, "a rebuilt request encodes to the bytes it was rebuilt from")
            return back
        }
        let status = DuoWireStatusIn(day: "2026-09-24", goalMet: true, progressBucket: 100, baseVer: 3)
        let decomposed = DuoWireCreateDuoRequest(displayName: "Jose\u{0301}", skin: "classic", myToday: "2026-09-24", e2eeCapable: true, statuses: [])
        XCTAssertEqual(try roundTrip(decomposed), decomposed)
        let nameless = DuoWireCreateDuoRequest(displayName: nil, skin: "classic", myToday: "2026-09-24", e2eeCapable: true, statuses: [status])
        XCTAssertEqual(try roundTrip(nameless), nameless, "a null name reads back as no name")
        let named = DuoWireCreateDuoRequest(displayName: "Sam", skin: "forest", myToday: "2026-09-24", e2eeCapable: false, statuses: [])
        XCTAssertEqual(try roundTrip(named), named)
        let redeem = DuoWireRedeemRequest(code: "H7K39QWX", displayName: nil, skin: "forest", myToday: "2026-09-24", e2eeCapable: false,
                                          statuses: [status], deviceCheckToken: "dc")
        XCTAssertEqual(try roundTrip(redeem), redeem)
        let withoutToken = DuoWireRedeemRequest(code: "H7K39QWX", displayName: "Sam", skin: "forest", myToday: "2026-09-24", e2eeCapable: true, statuses: [])
        XCTAssertEqual(try roundTrip(withoutToken), withoutToken, "an absent token stays absent")
    }

    func testPatchMeCanLeaveAFieldAloneClearItOrSetIt() throws {
        func json(_ request: DuoWireUpdateMeRequest) throws -> String { String(decoding: try DuoWireCoding.encode(request), as: UTF8.self) }
        XCTAssertEqual(try json(DuoWireUpdateMeRequest()), "{}")
        XCTAssertEqual(try json(DuoWireUpdateMeRequest(displayName: .null)), #"{"display_name":null}"#)
        XCTAssertEqual(try json(DuoWireUpdateMeRequest(displayName: .value("Sam"), skin: .value("forest"), termsVersion: .value(1))),
                       #"{"display_name":"Sam","skin":"forest","terms_version":1}"#)
    }

    func testPushRegistrationAndDeviceBodies() throws {
        let push = DuoWireRegisterPushRequest(token: "7c3d", apnsEnv: "production", tz: "America/Toronto", wakeStartMin: 480, wakeEndMin: 1320, notificationsEnabled: true)
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(push), as: UTF8.self),
                       #"{"apns_env":"production","notifications_enabled":true,"platform":"apns","token":"7c3d","token_kind":"apns","tz":"America/Toronto","wake_end_min":1320,"wake_start_min":480}"#)
        let off = DuoWireRegisterPushRequest(token: "7c3d", apnsEnv: "sandbox", tz: "Europe/London", wakeStartMin: nil, wakeEndMin: nil, notificationsEnabled: false)
        XCTAssertFalse(String(decoding: try DuoWireCoding.encode(off), as: UTF8.self).contains("wake_"), "the window is never sent with notifications off (D36)")
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(DuoWireCreateDeviceRequest(appVersion: "2.0 (57)", termsVersion: 1)), as: UTF8.self),
                       #"{"app_version":"2.0 (57)","platform":"ios","terms_version":1}"#)
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(DuoWireDeleteMeRequest()), as: UTF8.self), "{}")
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(DuoWireEmptyRequest()), as: UTF8.self), "{}")
        XCTAssertEqual(String(decoding: try DuoWireCoding.encode(DuoWireCreateInviteRequest(purpose: .linkDevice)), as: UTF8.self), #"{"purpose":"link_device"}"#)
    }

    func testTheSameValueIsAlwaysTheSameBytes() throws {
        var rows: [DuoWireStatusIn] = []
        for index in 0..<7 {
            let met = index % 2 == 0
            rows.append(DuoWireStatusIn(day: "2026-09-\(10 + index)", goalMet: met, progressBucket: met ? 100 : 25, baseVer: Int64(index)))
        }
        let request = DuoWirePutStatusesRequest(myToday: "2026-09-24", since: 0, statuses: rows)
        let first = try DuoWireCoding.encode(request)
        for _ in 0..<20 { XCTAssertEqual(try DuoWireCoding.encode(request), first) }
    }

    // MARK: - The wire, as read

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try DuoWireCoding.decode(type, from: Data(json.utf8))
    }

    func testAFullHeaderAndAHeaderOnlyViewAreOneType() throws {
        let full = try decode(DuoWireHeader.self, """
        {"id":"6d2a0000-0000-4000-8000-000000000001","my_role":"partner","state":"active","created_at":"2026-09-20T10:00:00Z",
         "joined_at":"2026-09-20T11:00:00Z","ended_at":null,"ended_by":null,"owner_display_name":"Alex","owner_skin":"classic",
         "partner_display_name":null,"partner_skin":"forest","partner_last_write_day":"2026-09-24","partner_is_demo":false,
         "invite":{"has_open_invite":false,"expires_at":null},"seq":418}
        """)
        XCTAssertTrue(full.isFull)
        XCTAssertEqual(full.myRole, .partner)
        XCTAssertNil(full.partnerDisplayName)
        XCTAssertEqual(full.seq, 418)
        let only = try decode(DuoWireHeader.self, """
        {"id":"6d2a0000-0000-4000-8000-000000000001","my_role":"owner","state":"ended","ended_at":"2026-09-24T10:00:00Z","ended_by":"partner","seq":9}
        """)
        XCTAssertFalse(only.isFull)
        XCTAssertEqual(only.endedBy, .partner)
    }

    func testAnEndedByThisBuildDoesNotKnowIsUnknownNotAFailure() throws {
        let header = try decode(DuoWireHeader.self, """
        {"id":"6d2a0000-0000-4000-8000-000000000001","my_role":"owner","state":"ended","ended_at":"2026-09-24T10:00:00Z","ended_by":"banned_for_good","seq":9}
        """)
        XCTAssertEqual(header.endedBy, .unknown)
        let rejected = try decode(DuoWireRejected.self, #"{"day":"2026-09-24","reason":"a_new_reason"}"#)
        XCTAssertEqual(rejected.reason, .unknown)
    }

    func testAWriteAnswerIsTheFeedPlusTheVerdicts() throws {
        let answer = try decode(DuoWireChangesWithResult.self, """
        {"duo":{"id":"6d2a0000-0000-4000-8000-000000000001","my_role":"owner","state":"active","created_at":"2026-09-20T10:00:00Z","seq":411},
         "full":false,
         "statuses":[{"role":"owner","day":"2026-09-24","goal_met":true,"progress_bucket":100,"updated_at":"2026-09-24T18:11:09Z","ver":4}],
         "nudges":[{"id":"nudge-8F2A0000-0000-4000-8000-000000000002","from_role":"partner","preset_id":"sipWithMe","created_at":"2026-09-24T18:12:00Z"}],
         "handled":[{"kind":"goal_met","day":"2026-09-24"},{"kind":"nudge","id":"nudge-8F2A0000-0000-4000-8000-000000000002"}],
         "cursor":411,"accepted":["2026-09-24"],"unchanged":[],
         "rejected":[{"day":"2026-09-30","reason":"day_out_of_range"},
                     {"day":"2026-09-23","reason":"ver_conflict","current":{"role":"owner","day":"2026-09-23","goal_met":false,"progress_bucket":25,"updated_at":"2026-09-23T10:00:00Z","ver":3}}]}
        """)
        XCTAssertEqual(answer.changes.cursor, 411)
        XCTAssertEqual(answer.changes.statuses.first?.ver, 4)
        XCTAssertEqual(answer.changes.handled.map(\.kind), ["goal_met", "nudge"])
        XCTAssertEqual(answer.accepted, ["2026-09-24"])
        XCTAssertNil(answer.rejected[0].current)
        XCTAssertEqual(answer.rejected[1].current?.ver, 3)
        XCTAssertEqual(answer.rejected[1].reason, .verConflict)
    }

    func testGetMeAndTheOtherAnswers() throws {
        let me = try decode(DuoWireGetMeResponse.self, """
        {"member":{"id":"6d2a0000-0000-4000-8000-000000000003","display_name":null,"skin":null,"support_id":"ABCD1234EFGH","tier":"low","terms_version":1},
         "limits":{"nudges_per_day":1,"max_active_duos":5},
         "devices":[{"id":"6d2a0000-0000-4000-8000-000000000004","platform":"ios","created_at":"2026-09-20T10:00:00Z","this_device":true,"superseded":false}],
         "duos":[],"min_client":{"ios":"2.0","android":"1.1"}}
        """)
        let info = DuoMapping.member(me, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(info.supportIDDisplay, "ABCD-1234-EFGH")
        XCTAssertEqual(info.tier, .low)
        XCTAssertEqual(info.nudgesPerDay, 1)
        XCTAssertEqual(info.devices.first?.thisDevice, true)
        let device = try decode(DuoWireCreateDeviceResponse.self, #"{"member_id":"a","device_id":"b","device_secret":"c","tier":"attested","support_id":"ABCD1234EFGH"}"#)
        XCTAssertEqual(device.deviceSecret, "c")
        let leave = try decode(DuoWireLeaveResponse.self, #"{"state":"ended","ended_by":"owner","ended_at":"2026-09-24T10:00:00Z"}"#)
        XCTAssertEqual(leave.endedBy, .owner)
        let reconnect = try decode(DuoWireReconnectResponse.self, #"{"member_id":"a","support_id":"s","duos":[],"superseded_devices":1}"#)
        XCTAssertEqual(reconnect.supersededDevices, 1)
        let peek = try decode(DuoWirePeekResponse.self, #"{"purpose":"demo","state":"open","expires_at":null,"inviter_display_name":null,"inviter_skin":null}"#)
        XCTAssertEqual(DuoMapping.peek(peek).purpose, .demo)
        let challenge = try decode(DuoWireAttestChallenge.self, #"{"challenge_id":"6d2a0000-0000-4000-8000-000000000005","challenge":"abc","expires_at":"2026-09-24T10:05:00Z"}"#)
        XCTAssertEqual(challenge.challengeId, "6d2a0000-0000-4000-8000-000000000005")
    }

    func testErrorDetailsAreReadLeniently() throws {
        let envelope = try JSONDecoder().decode(DuoWireErrorEnvelope.self, from: Data("""
        {"error":{"code":"duo_limit","message":"m","details":{"active_duos":5,"max":5,"surprise":[1,2],"retryable":"yes"},"retry_after_s":30,"request_id":"9b1c-YYZ"}}
        """.utf8))
        XCTAssertEqual(envelope.error.code, "duo_limit")
        XCTAssertEqual(envelope.error.details?.activeDuos, 5)
        XCTAssertEqual(envelope.error.details?.max, 5)
        XCTAssertNil(envelope.error.details?.retryable, "a value of the wrong type is absent, not a failure")
        XCTAssertEqual(envelope.error.retryAfterS, 30)
        XCTAssertEqual(envelope.error.requestId, "9b1c-YYZ")
        let bare = try JSONDecoder().decode(DuoWireErrorEnvelope.self, from: Data(#"{"error":{"code":"maintenance"}}"#.utf8))
        XCTAssertNil(bare.error.requestId)
    }

    // MARK: - Errors

    func testEveryCodeHasItsOwnCaseAndComesBackOut() {
        XCTAssertEqual(DuoErrorCode.allCases.count, 34)
        for code in DuoErrorCode.allCases {
            let context = DuoErrorContext(httpStatus: 409, requestID: "r")
            let error = DuoTransportError(code: code, context: context)
            XCTAssertEqual(error.code, code)
            XCTAssertEqual(error.context, context)
            XCTAssertEqual(error.requestID, "r")
        }
        XCTAssertNil(DuoTransportError.offline.code)
        XCTAssertEqual(DuoTransportError.unreadable(httpStatus: 502, requestID: "x").requestID, "x")
    }

    func testWhatToDoAboutEachFailure() {
        func verdict(_ code: DuoErrorCode, retryAfter: Int? = nil) -> DuoRetry.Verdict {
            DuoRetry.verdict(for: DuoTransportError(code: code, context: DuoErrorContext(httpStatus: 400, retryAfter: retryAfter)))
        }
        XCTAssertEqual(verdict(.duoUnknown), .ended)
        XCTAssertEqual(verdict(.duoEnded), .ended)
        XCTAssertEqual(verdict(.rateLimited, retryAfter: 120), .retry(after: 120))
        XCTAssertEqual(verdict(.rateLimited, retryAfter: 3), .retry(after: DuoRetry.minimumDelay), "Retry-After is honoured with a floor of 30 s")
        XCTAssertEqual(verdict(.rateLimited), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(verdict(.maintenance), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.offline), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unreadable(httpStatus: 502, requestID: nil)), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unreadable(httpStatus: 200, requestID: nil)), .fail,
                       "a landed request whose answer cannot be read is told, not retried for ever behind the queue")
        XCTAssertEqual(DuoRetry.verdict(for: CancellationError()), .cancelled, "a cancelled task is not a failure and not a retry")
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError(code: .unauthenticated, context: DuoErrorContext(httpStatus: 401))), .reidentify)
        XCTAssertEqual(verdict(.unauthenticated), .fail, "an unauthenticated that did not come from a 401 is not the server forgetting this identity")
        XCTAssertEqual(DuoRetry.verdict(for: DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0))), .fail,
                       "the client's own 'no credential' error discards nothing")
        XCTAssertEqual(verdict(.deviceRevoked), .disconnected)
        XCTAssertEqual(verdict(.upgradeRequired), .upgradeRequired)
        XCTAssertEqual(verdict(.termsRequired), .termsRequired)
        XCTAssertEqual(verdict(.banned), .banned)
        for code in [DuoErrorCode.nudgeLimit, .inviteTaken, .nameRejected, .schema, .partnerAlreadyMet, .conflict] {
            XCTAssertEqual(verdict(code), .fail, "\(code)")
        }
        XCTAssertEqual(DuoRetry.verdict(for: NSError(domain: "x", code: 1)), .fail)
    }

    // One test per row of §4.4's table (the iCloud version's eight `DuoJoinMessageTests` come
    // back as these), and per row of §6.7 and §3.4 the app shows.

    private func text(_ code: DuoErrorCode, _ context: DuoMessageContext = .general, details: DuoWireErrorDetails? = nil, request: String? = nil) -> String {
        DuoUserMessage.text(for: DuoTransportError(code: code, context: DuoErrorContext(httpStatus: 400, requestID: request, details: details)), context: context)
    }

    func testInviteUnknownSaysTheInviteIsNoLongerOpen() {
        XCTAssertEqual(text(.inviteUnknown, .invite), "That invite is no longer open. Ask for a new one.")
    }

    func testInviteTakenSaysSomeoneElseMayHaveJoinedFirst() {
        XCTAssertEqual(text(.inviteTaken, .invite), "This invite is not open to you anymore. Someone else may have joined first. Ask for a new one.")
    }

    func testInviteOwnSaysItIsYourOwnInvite() {
        XCTAssertEqual(text(.inviteOwn, .invite), "That is your own invite. Send it to the person you want to team up with.")
    }

    func testDuoLimitNamesHowManyDuosYouAreIn() {
        XCTAssertEqual(text(.duoLimit, .invite, details: DuoWireErrorDetails(max: 5, activeDuos: 5)), "You are already in 5 duos. Leave one first, then open the invite again.")
        XCTAssertEqual(text(.alreadyInDuo, .invite, details: DuoWireErrorDetails(activeDuos: 2)), "You are already in 2 duos. Leave one first, then open the invite again.")
        XCTAssertEqual(text(.duoLimit, .invite, details: DuoWireErrorDetails(activeDuos: 1)), "You are already in a duo. Leave it first, then open the invite again.")
    }

    func testBlockedNeverSaysWhichSideBlocked() {
        XCTAssertEqual(text(.blocked, .invite), "This person can't be paired with you.")
    }

    func testWrongPurposeSendsYouForADuoInvite() {
        XCTAssertEqual(text(.wrongPurpose, .invite), "That code is for something else. Ask for a duo invite.")
    }

    func testMemberNotFreshSaysToFinishOrLeaveTheDuoStartedHere() {
        XCTAssertEqual(text(.memberNotFresh, .invite), "Finish or leave the duo you started on this phone first.")
    }

    func testAttestationFailingTwiceSaysThePhoneCouldNotBeVerified() {
        XCTAssertEqual(text(.attestRequired, .invite), "HydroDrop could not verify this phone. Try again in a few minutes.")
        XCTAssertEqual(text(.attestInvalid, .invite), "HydroDrop could not verify this phone. Try again in a few minutes.")
    }

    func testRateLimitedSaysToWait() {
        XCTAssertEqual(text(.rateLimited, .invite), "Too many tries. Wait a bit and try again.")
    }

    func testMaintenanceSaysJoiningIsPausedOrTheServiceIsNotAvailable() {
        XCTAssertEqual(text(.maintenance, .invite), "Joining is paused for a few minutes. Try again soon.")
        XCTAssertEqual(text(.maintenance, .general), "HydroDrop's duo service is not available right now. Your duo will catch up when it is.")
        XCTAssertEqual(DuoUserMessage.text(for: DuoTransportError.unreadable(httpStatus: 502, requestID: nil), context: .invite), "Joining is paused for a few minutes. Try again soon.")
    }

    func testOfflineSaysThereIsNoConnection() {
        XCTAssertEqual(DuoUserMessage.text(for: DuoTransportError.offline), "No connection right now. Try again in a bit.")
    }

    func testNameRejectedAsksForADifferentName() {
        XCTAssertEqual(text(.nameRejected), "Please choose a different name.")
    }

    func testUpgradeRequiredSaysToUpdate() {
        XCTAssertEqual(text(.upgradeRequired), "Update HydroDrop to keep using Duo Streaks.")
    }

    func testBannedPointsToSupport() {
        XCTAssertEqual(text(.banned), "Duo Streaks are not available for this device. Contact support@hydrodrop.us.")
    }

    func testNudgeFailuresNameThePartnerAndNoNumber() {
        XCTAssertEqual(text(.nudgeLimit, .nudge(partner: "Sam")), "That is all your nudges for today.")
        XCTAssertEqual(text(.partnerAlreadyMet, .nudge(partner: "Sam")), "Sam already met their goal. Nothing to nudge.")
    }

    func testACodeWithNoApprovedWordingGetsTheGeneralLineWithItsReference() {
        XCTAssertEqual(text(.deviceLimit, .general, request: "9b1c"), "That did not work. Please try again. (ref 9b1c)")
        XCTAssertEqual(text(.schema, .general, request: "9b1c"), "That did not work. Please try again. (ref 9b1c)")
        XCTAssertEqual(text(.idempotencyMismatch), "That did not work. Please try again.")
        XCTAssertEqual(text(.termsRequired), "That did not work. Please try again.")
    }

    // MARK: - Wire to domain

    private let duoID = "6d2a0000-0000-4000-8000-000000000001"

    private func header(state: DuoWireDuoState = .active, owner: String? = "Alex", partner: String? = "Sam", partnerSkin: String? = "forest",
                        endedBy: DuoEndedBy? = nil, full: Bool = true) -> DuoWireHeader {
        DuoWireHeader(id: duoID, myRole: .owner, state: state, createdAt: full ? Date(timeIntervalSince1970: 1_000) : nil,
                      joinedAt: full && state != .pending ? Date(timeIntervalSince1970: 2_000) : nil,
                      endedAt: state == .ended ? Date(timeIntervalSince1970: 3_000) : nil, endedBy: endedBy,
                      ownerDisplayName: full ? owner : nil, ownerSkin: full ? "classic" : nil,
                      partnerDisplayName: full ? partner : nil, partnerSkin: full ? partnerSkin : nil,
                      partnerLastWriteDay: full ? "2026-09-24" : nil, partnerIsDemo: full ? false : nil,
                      invite: full ? DuoWireHeaderInvite(hasOpenInvite: state == .pending, expiresAt: state == .pending ? Date(timeIntervalSince1970: 9_000) : nil) : nil,
                      seq: 5)
    }

    func testANullNameAndAnUnknownSkinDrawAsYourPartnerAndTheClassicDroplet() throws {
        let duo = try XCTUnwrap(DuoMapping.duo(from: header(partner: nil, partnerSkin: "aurora"), previous: nil, now: Date()))
        XCTAssertEqual(duo.partnerDisplayName, "")
        XCTAssertEqual(duo.displayName(of: .partner), "Your partner")
        XCTAssertEqual(DuoMapping.resolvedSkin(duo.partnerSkin, known: ["classic", "forest"]), "classic")
        XCTAssertEqual(DuoMapping.resolvedSkin("forest", known: ["classic", "forest"]), "forest")
        XCTAssertEqual(DuoMapping.resolvedSkin(nil, known: ["classic"]), "classic")
    }

    func testAHeaderBuildsAndUpdatesADuo() throws {
        let created = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: Date()))
        XCTAssertEqual(created.id, UUID(uuidString: duoID))
        XCTAssertEqual(created.wireID, duoID)
        XCTAssertTrue(created.partnerHasJoined)
        XCTAssertEqual(created.partnerLastWriteDay, "2026-09-24")
        XCTAssertNil(DuoMapping.duo(from: DuoWireHeader(id: "nope", myRole: .owner, state: .active, createdAt: nil, joinedAt: nil, endedAt: nil, endedBy: nil,
                                                       ownerDisplayName: nil, ownerSkin: nil, partnerDisplayName: nil, partnerSkin: nil,
                                                       partnerLastWriteDay: nil, partnerIsDemo: nil, invite: nil, seq: 0), previous: nil, now: Date()))
        var pending = created
        pending.partnerHasJoined = false
        let waiting = try XCTUnwrap(DuoMapping.duo(from: header(state: .pending), previous: pending, now: Date()))
        XCTAssertEqual(waiting.openInviteExpiresAt, Date(timeIntervalSince1970: 9_000))
        XCTAssertFalse(waiting.partnerHasJoined)
        let active = try XCTUnwrap(DuoMapping.duo(from: header(state: .active), previous: waiting, now: Date()))
        XCTAssertNil(active.openInviteExpiresAt)
        XCTAssertNil(active.invite)
    }

    func testAnEndedDuoKeepsTheNamesTheSurvivorHad() throws {
        let live = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: Date()))
        let ended = try XCTUnwrap(DuoMapping.duo(from: header(state: .ended, partner: nil, partnerSkin: nil, endedBy: .partner), previous: live, now: Date()))
        XCTAssertEqual(ended.partnerDisplayName, "Sam", "the server masks a departed member's name, and the cache keeps its copy")
        XCTAssertEqual(ended.partnerSkin, "forest")
        XCTAssertEqual(ended.endedBy, .partner)
        XCTAssertEqual(ended.endedAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertTrue(ended.hasEnded)
    }

    func testAHeaderOnlyViewChangesNothingButTheEnd() throws {
        let live = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: Date()))
        let only = try XCTUnwrap(DuoMapping.duo(from: header(state: .ended, endedBy: .owner, full: false), previous: live, now: Date()))
        XCTAssertEqual(only.partnerDisplayName, "Sam")
        XCTAssertEqual(only.ownerSkin, "classic")
        XCTAssertEqual(only.endedBy, .owner)
        XCTAssertTrue(only.partnerHasJoined)
    }

    func testADuoNeverComesBackFromEnded() throws {
        var leaving = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: Date()))
        leaving.endedAt = Date(timeIntervalSince1970: 7_000)
        leaving.endedBy = .owner
        leaving.pendingOp = .leave
        let refreshed = try XCTUnwrap(DuoMapping.duo(from: header(state: .active), previous: leaving, now: Date()))
        XCTAssertTrue(refreshed.hasEnded, "an offline Leave shows the ended card until the server hears")
        XCTAssertEqual(refreshed.pendingOp, .leave)
    }

    func testRowsThisBuildCannotHoldAreDropped() {
        let row = DuoWireStatusRow(role: .owner, day: "2026-09-24", goalMet: true, progressBucket: 100, updatedAt: Date(), ver: 1)
        XCTAssertNotNil(DuoMapping.status(row))
        var badDay = row; badDay.day = "2026-02-30"
        XCTAssertNil(DuoMapping.status(badDay))
        var oldDay = row; oldDay.day = "1999-12-31"
        XCTAssertNil(DuoMapping.status(oldDay))
        var badBucket = row; badBucket.progressBucket = 60
        XCTAssertNil(DuoMapping.status(badBucket))
        XCTAssertNotNil(DuoMapping.nudge(DuoWireNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000002", fromRole: .partner, presetId: "sipWithMe", createdAt: Date())))
        XCTAssertNil(DuoMapping.nudge(DuoWireNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000002\n", fromRole: .partner, presetId: "sipWithMe", createdAt: Date())))
        XCTAssertNil(DuoMapping.nudge(DuoWireNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000002", fromRole: .partner, presetId: String(repeating: "a", count: 41), createdAt: Date())))
    }

    func testANicknameIsWhatThePartnerIsCalled() throws {
        var duo = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: Date()))
        XCTAssertEqual(duo.displayName(of: .partner), "Sam")
        duo.partnerNickname = "Sammy"
        XCTAssertEqual(duo.displayName(of: .partner), "Sammy")
        XCTAssertEqual(duo.displayName(of: .owner), "Alex", "a nickname is for the partner only")
        duo.partnerNickname = ""
        XCTAssertEqual(duo.displayName(of: .partner), "Sam")
    }

    func testTheCacheRoundTripsEveryV2Field() throws {
        let duo = DuoState(
            id: UUID(), myRole: .partner, createdAt: Date(timeIntervalSinceReferenceDate: 100), ownerDisplayName: "Jo", partnerDisplayName: "Sam",
            ownerSkin: "classic", partnerSkin: "forest", statuses: [], partnerHasJoined: true, endedAt: nil, nudges: nil,
            joinedAt: Date(timeIntervalSinceReferenceDate: 200), cursor: 418, vers: ["owner-2026-09-24": 4],
            invite: DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: Date(timeIntervalSinceReferenceDate: 300)),
            openInviteExpiresAt: Date(timeIntervalSinceReferenceDate: 300), endedBy: .inactive, partnerLastWriteDay: "2026-09-24",
            partnerIsDemo: true, partnerNickname: "Sammy", e2eeCapable: true, pendingOp: .block, syncedOnce: true)
        XCTAssertEqual(try JSONDecoder().decode(DuoState.self, from: JSONEncoder().encode(duo)), duo)
        XCTAssertEqual(duo.ver(of: .owner, on: "2026-09-24"), 4)
        XCTAssertEqual(duo.ver(of: .partner, on: "2026-09-24"), 0)
    }

    // MARK: - Pushes (KV13, KV17)

    func testEachKindOfPushIsReadFromItsPayload() throws {
        let duo = "6d2a0000-0000-4000-8000-000000000001"
        let nudge = try XCTUnwrap(DuoPushPayload.parse(data: ["v": "1", "t": "nudge", "duo": duo, "seq": "419", "id": "nudge-8F2A0000-0000-4000-8000-000000000002", "preset": "sipWithMe", "from_name": "Alex"]))
        XCTAssertEqual(nudge.kind, .nudge(id: "nudge-8F2A0000-0000-4000-8000-000000000002", preset: "sipWithMe"))
        XCTAssertEqual(nudge.fromName, "Alex")
        XCTAssertEqual(nudge.seq, 419)
        XCTAssertEqual(nudge.ledgerKeys, ["nudge-8F2A0000-0000-4000-8000-000000000002"])
        let goal = try XCTUnwrap(DuoPushPayload.parse(data: ["t": "goal_met", "duo": duo, "seq": "7", "day": "2026-09-24", "i_have_too": "1"]))
        XCTAssertEqual(goal.kind, .goalMet(day: "2026-09-24", iHaveToo: true))
        XCTAssertEqual(goal.ledgerKeys, ["met|\(duo)|2026-09-24"])
        XCTAssertEqual(DuoPushPayload.parse(data: ["t": "joined", "duo": duo])?.kind, .joined)
        XCTAssertEqual(DuoPushPayload.parse(data: ["t": "ended", "duo": duo, "ended_by": "owner_deleted"])?.kind, .ended(.ownerDeleted))
        XCTAssertEqual(DuoPushPayload.parse(data: ["t": "ended", "duo": duo, "ended_by": "weird"])?.kind, .ended(.unknown))
        XCTAssertEqual(DuoPushPayload.parse(data: ["t": "reconnected", "duo": duo, "who": "superseded"])?.kind, .reconnected(who: "superseded"))
        XCTAssertEqual(DuoPushPayload.parse(data: ["t": "reconnected", "duo": duo])?.kind, .reconnected(who: "unknown"),
                       "the iOS payload has no who in its data: an absent one is not a partner")
        let digest = try XCTUnwrap(DuoPushPayload.parse(data: ["t": "digest", "duo": duo, "kinds": "goal_met,nudge", "days": "2026-09-23,2026-09-24", "nudge_ids": "nudge-8F2A0000-0000-4000-8000-000000000002", "preset": "cheers"]))
        XCTAssertEqual(digest.ledgerKeys.count, 3)
        XCTAssertEqual(DuoPushPayload.parse(data: ["t": "from_the_future", "duo": duo])?.kind, .unknown("from_the_future"))
        XCTAssertNil(DuoPushPayload.parse(data: ["t": "nudge", "duo": "not-a-uuid"]))
        XCTAssertNil(DuoPushPayload.parse(data: ["t": "nudge", "duo": duo, "id": "nudge-nope"]))
        XCTAssertNil(DuoPushPayload.parse(data: ["duo": duo]))
    }

    func testAnApnsPayloadIsReadTheSameWay() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "duo.nudge.sipWithMe"], "thread-id": "hydrodrop.duo.x"],
            "v": 1, "t": "digest", "duo": "6d2a0000-0000-4000-8000-000000000001", "seq": NSNumber(value: 420), "kinds": ["goal_met", "nudge"],
        ]
        let payload = try XCTUnwrap(DuoPushPayload.parse(userInfo: userInfo))
        XCTAssertEqual(payload.seq, 420)
        XCTAssertEqual(payload.kind, .digest(kinds: ["goal_met", "nudge"], days: [], nudgeIDs: [], preset: nil, count: nil))
    }

    func testAPushIsWorthAFetchOnlyWhenItIsAheadOfTheCursor() {
        XCTAssertTrue(DuoPushGate.shouldFetch(cursor: 418, seq: 419))
        XCTAssertFalse(DuoPushGate.shouldFetch(cursor: 418, seq: 418))
        XCTAssertFalse(DuoPushGate.shouldFetch(cursor: 418, seq: 3))
        XCTAssertTrue(DuoPushGate.shouldFetch(cursor: 418, seq: nil))
    }

    // MARK: - Rejected days (KV10)

    private func status(_ day: String, role: DuoRole = .owner, bucket: Int) -> DuoDayStatus {
        DuoDayStatus(role: role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: Date(timeIntervalSince1970: 0))
    }

    func testARefusedDayIsNotSentAgainUntilWhatIsWantedChanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let today = DayKey.key(for: now, calendar: calendar)
        let refusedDay = DayKey.key(for: now.addingTimeInterval(-86_400 * 3), calendar: calendar)
        var rejected = DuoRejectedDays()
        rejected.record(status(refusedDay, bucket: 25))

        func unsent(_ total: Int) -> [DuoDayStatus] {
            DuoOutbox.unsent(role: .owner, totalsByDay: [refusedDay: total], goalML: 2000, known: [], myToday: today, now: now,
                             rejectedDays: rejected, calendar: calendar)
        }
        XCTAssertEqual(unsent(500).filter { $0.day == refusedDay }, [], "500 of 2000 is the 25 the server refused")
        XCTAssertEqual(unsent(1000).filter { $0.day == refusedDay }.map(\.progressBucket), [50], "a change in the wanted status is sent")
        rejected.settle(against: [status(refusedDay, bucket: 50)], myToday: today)
        XCTAssertTrue(rejected.isEmpty, "a change clears the entry")
    }

    func testRefusedDaysOlderThanNineDaysAreForgotten() {
        var rejected = DuoRejectedDays()
        rejected.record(status("2026-09-01", bucket: 25))
        rejected.record(status("2026-09-20", bucket: 25))
        rejected.settle(against: [], myToday: "2026-09-25")
        XCTAssertEqual(Set(rejected.rows.keys), ["2026-09-20"])
    }

    // MARK: - Queued requests and small types

    func testAQueuedLeaveHoldsTheExactBytesToReplay() throws {
        let id = UUID()
        let op = try DuoQueuedOp.leave(duoID: id, key: "k1", now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(op.path, "/duos/\(id.uuidString.lowercased())/leave")
        XCTAssertEqual(op.body, Data("{}".utf8))
        XCTAssertTrue(op.sendsIdempotencyKey)
        XCTAssertEqual(try JSONDecoder().decode(DuoQueuedOp.self, from: JSONEncoder().encode(op)), op)
        XCTAssertFalse(DuoQueuedOp.unregisterPush(key: "k", now: Date()).sendsIdempotencyKey)
        XCTAssertEqual(try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .null), key: "k", now: Date()).body, Data(#"{"display_name":null}"#.utf8))
    }

    func testTheSameRequestReusesItsKeyAndADifferentOneDoesNot() {
        var journal = DuoInflightJournal()
        let random = SequentialRandom()
        let now = Date(timeIntervalSince1970: 1_000)
        let first = journal.key(for: "create", body: Data("a".utf8), now: now, random: random)
        XCTAssertEqual(journal.key(for: "create", body: Data("a".utf8), now: now.addingTimeInterval(60), random: random), first, "a second tap that builds the same bytes replays")
        let changed = journal.key(for: "create", body: Data("b".utf8), now: now.addingTimeInterval(120), random: random)
        XCTAssertNotEqual(changed, first, "different bytes are a different request")
        XCTAssertEqual(journal.entries.count, 1, "one in flight per operation")
        let other = journal.key(for: "redeem:H7K39QWX", body: Data("a".utf8), now: now, random: random)
        XCTAssertNotEqual(other, changed)
        XCTAssertEqual(journal.entries.count, 2)
        journal.clear(operation: "create")
        XCTAssertEqual(journal.entries.count, 1)
        let expired = journal.key(for: "redeem:H7K39QWX", body: Data("a".utf8), now: now.addingTimeInterval(23 * 3600), random: random)
        XCTAssertNotEqual(expired, other, "a record near the server's 24 hours is not replayed")
    }

    func testAPendingInviteExpiresAfterFortyEightHours() {
        let invite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(invite.isExpired(now: Date(timeIntervalSince1970: 48 * 3600 - 1)))
        XCTAssertTrue(invite.isExpired(now: Date(timeIntervalSince1970: 48 * 3600)))
    }

    func testTheAgeGateComparesYearsAndNeverSendsAnything() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2010, now: now, calendar: calendar), .allowed)
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2015, now: now, calendar: calendar), .refused)
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 1800, now: now, calendar: calendar), .unknown)
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2999, now: now, calendar: calendar), .unknown)
    }

    func testAvailabilityGatesWritesAndSpeaksOnlyWhenItMatters() {
        XCTAssertTrue(DuoAvailability.available.allowsWrites)
        XCTAssertTrue(DuoAvailability.maintenance.allowsWrites)
        XCTAssertFalse(DuoAvailability.upgradeRequired.allowsWrites)
        XCTAssertFalse(DuoAvailability.disconnected.allowsWrites)
        XCTAssertNil(DuoAvailability.available.bannerMessage)
        XCTAssertNil(DuoAvailability.unknown.bannerMessage)
        XCTAssertEqual(DuoAvailability.upgradeRequired.bannerMessage, "Update HydroDrop to keep using Duo Streaks.")
    }

    // MARK: - What the card asks

    func testNotThemIsShownToTheInviterForTwentyFourHoursFromTheServersJoinedAt() {
        let joined = Date(timeIntervalSince1970: 1_000_000)
        var duo = DuoState(id: UUID(), myRole: .owner, createdAt: joined, ownerDisplayName: "Jo", partnerDisplayName: "Sam", ownerSkin: "classic",
                           partnerSkin: "forest", statuses: [], partnerHasJoined: true, joinedAt: joined)
        XCTAssertTrue(duo.showsNotThemCard(now: joined.addingTimeInterval(3600)))
        XCTAssertTrue(duo.showsNotThemCard(now: joined.addingTimeInterval(24 * 3600 - 1)))
        XCTAssertFalse(duo.showsNotThemCard(now: joined.addingTimeInterval(24 * 3600)))
        XCTAssertFalse(duo.showsNotThemCard(now: joined.addingTimeInterval(-1)), "a phone whose clock is behind does not show it early")
        duo.myRole = .partner
        XCTAssertFalse(duo.showsNotThemCard(now: joined.addingTimeInterval(3600)), "only the person who sent the invite is asked")
        duo.myRole = .owner
        duo.endedAt = joined.addingTimeInterval(60)
        XCTAssertFalse(duo.showsNotThemCard(now: joined.addingTimeInterval(3600)))
    }

    func testAPartnerIsSilentWhenTheirLastWriteIsOverThreeDaysOld() {
        var duo = DuoState(id: UUID(), myRole: .owner, createdAt: Date(), ownerDisplayName: "Jo", partnerDisplayName: "Sam", ownerSkin: "classic",
                           partnerSkin: "forest", statuses: [], partnerHasJoined: true, partnerLastWriteDay: "2026-09-20")
        XCTAssertEqual(duo.partnerSilentSince(myToday: "2026-09-24"), "2026-09-20")
        XCTAssertTrue(duo.offersReconnect(myToday: "2026-09-24"))
        XCTAssertNil(duo.partnerSilentSince(myToday: "2026-09-23"), "exactly three days is not yet silent")
        XCTAssertNil(duo.partnerSilentSince(myToday: "2026-09-22"))
        duo.partnerIsDemo = true
        XCTAssertNil(duo.partnerSilentSince(myToday: "2026-09-24"), "the App Review sample partner is never silent")
        duo.partnerIsDemo = false
        duo.partnerLastWriteDay = nil
        XCTAssertNil(duo.partnerSilentSince(myToday: "2026-09-24"))
    }

    func testDiagnosticsKeepTheLastFiveErrorsAndNeverAName() {
        var diagnostics = DuoDiagnostics()
        let duo = UUID()
        let now = Date(timeIntervalSince1970: 100)
        for index in 0..<7 {
            diagnostics.record(DuoTransportError.rateLimited(DuoErrorContext(httpStatus: 429, requestID: "r\(index)")), duoID: index == 6 ? duo : nil, now: now)
        }
        XCTAssertEqual(diagnostics.recentErrors.count, 5)
        XCTAssertEqual(diagnostics.recentErrors.first?.requestID, "r6", "newest first")
        XCTAssertEqual(diagnostics.duos[duo.uuidString.lowercased()]?.lastError?.code, "rate_limited")
        diagnostics.record(DuoTransportError.offline, duoID: nil, now: now)
        XCTAssertEqual(diagnostics.recentErrors.first?.code, "offline")
        diagnostics.recordFetch(duoID: duo, seq: 9, cursor: 8, at: now)
        diagnostics.recordWrite(duoID: duo, at: now)
        XCTAssertEqual(diagnostics.duos[duo.uuidString.lowercased()]?.cursor, 8)
        diagnostics.forget(duoID: duo)
        XCTAssertTrue(diagnostics.duos.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(DuoDiagnostics.self, from: JSONEncoder().encode(diagnostics)), diagnostics)
    }

    func testSecretsAreKeptUnderTheNamesThePlanFixes() throws {
        let secrets = DuoSecrets(store: DuoMemorySecretStore())
        XCTAssertNil(secrets.credential())
        let credential = DuoCredential(memberID: "m", deviceID: "d", deviceSecret: "s", secretVersion: 2)
        try secrets.save(credential)
        XCTAssertEqual(secrets.credential(), credential)
        XCTAssertEqual(credential.bearer, "d.s")
        XCTAssertFalse(secrets.hasInstallMarker())
        try secrets.writeInstallMarker(random: SequentialRandom())
        XCTAssertTrue(secrets.hasInstallMarker())
        let duo = UUID()
        try secrets.saveLinkSecret("K", forDuo: duo)
        XCTAssertEqual(secrets.linkSecret(forDuo: duo), "K")
        XCTAssertEqual(DuoSecrets.linkSecretAccount(duoID: duo), "k.\(duo.uuidString.lowercased())")
        try secrets.deleteCredential()
        XCTAssertNil(secrets.credential())
        XCTAssertEqual(DuoClientInfo(marketingVersion: "2.0", build: "57").clientHeader, "ios/2.0 (57)")
        XCTAssertEqual(DuoClientInfo(marketingVersion: "2.0", build: "57").appVersion, "2.0 (57)")
    }

    // MARK: - Review fixes (plan P2, second critique)

    func testNoPromiseAboutTheWhenOfADrinkSurvivesAndEveryClosingLineAgrees() {
        // release/1.8 took "or when" out (2d2b7ef): a day's row records when it last changed and
        // the goal notification follows the drink. The explainer says so itself (its fourth line).
        let closing = "Never what you drank or exactly how much"
        XCTAssertEqual(DuoCopy.explainerLines.count, 6)
        XCTAssertEqual(DuoCopy.explainerLines.last, closing)
        XCTAssertTrue(DuoCopy.screenFooter.hasSuffix(closing + "."))
        let everyPromise = DuoCopy.explainerLines + [DuoCopy.honestyLineStored, DuoCopy.honestyLinePaired, DuoCopy.partnerSeesFooter,
                                                     DuoCopy.inviteSheetWarning, DuoCopy.notificationsFooter, DuoCopy.screenFooter,
                                                     DuoCopy.deleteMessage, DuoCopy.clearMessage]
        for line in everyPromise {
            XCTAssertFalse(line.lowercased().contains("or when"), "a line promises the person's drinks are never timed: \(line)")
            XCTAssertFalse(line.lowercased().contains("how much, or"), line)
        }
    }

    func testAReconnectIsAllowedForADisconnectedPhoneAndWritesStayOff() {
        XCTAssertTrue(DuoAvailability.disconnected.allowsReconnect)
        XCTAssertFalse(DuoAvailability.disconnected.allowsWrites)
        for allowed in [DuoAvailability.unknown, .available, .maintenance] { XCTAssertTrue(allowed.allowsReconnect) }
        for refused in [DuoAvailability.upgradeRequired, .banned, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil))] {
            XCTAssertFalse(refused.allowsReconnect)
        }
    }

    func testARequestWithAFreshTokenEachTimeIsStillTheSameRequestToTheJournal() {
        var journal = DuoInflightJournal()
        let random = SequentialRandom()
        let now = Date(timeIntervalSince1970: 1_000)
        let identity = Data(#"{"code":"H7K39QWX","display_name":null}"#.utf8)
        let first = journal.replayable(for: "redeem:H7K39QWX", identity: identity, body: Data(#"{"code":"H7K39QWX","device_check_token":"AAA"}"#.utf8), now: now, random: random)
        let again = journal.replayable(for: "redeem:H7K39QWX", identity: identity, body: Data(#"{"code":"H7K39QWX","device_check_token":"BBB"}"#.utf8),
                                       now: now.addingTimeInterval(60), random: random)
        XCTAssertEqual(again.key, first.key, "a lost answer is replayed under its key")
        XCTAssertEqual(again.body, first.body, "with the exact bytes of the first attempt, the old token included, never new bytes under an old key")
        let renamed = journal.replayable(for: "redeem:H7K39QWX", identity: Data(#"{"code":"H7K39QWX","display_name":"Sam"}"#.utf8),
                                         body: Data(#"{"code":"H7K39QWX","display_name":"Sam","device_check_token":"CCC"}"#.utf8), now: now.addingTimeInterval(120), random: random)
        XCTAssertNotEqual(renamed.key, first.key, "a different request is a new one")
        XCTAssertEqual(renamed.body, Data(#"{"code":"H7K39QWX","display_name":"Sam","device_check_token":"CCC"}"#.utf8))
        XCTAssertEqual(journal.entries.count, 1)
        let late = journal.replayable(for: "redeem:H7K39QWX", identity: Data(#"{"code":"H7K39QWX","display_name":"Sam"}"#.utf8), body: Data("later".utf8),
                                      now: now.addingTimeInterval(120 + 23 * 3600), random: random)
        XCTAssertNotEqual(late.key, renamed.key, "an entry near the server's 24 hours is not replayed")
        XCTAssertEqual(try JSONDecoder().decode(DuoInflightJournal.self, from: JSONEncoder().encode(journal)), journal)
    }

    func testAReconnectedDuoMustBeReadWholeBeforeAnythingIsWrittenToIt() {
        var duo = DuoState(id: UUID(), myRole: .owner, createdAt: Date(timeIntervalSince1970: 0), ownerDisplayName: "Jo", partnerDisplayName: "Sam",
                           ownerSkin: "classic", partnerSkin: "forest", statuses: [], partnerHasJoined: true, cursor: 40, syncedOnce: true)
        duo.vers = ["owner-2026-09-20": 3]
        let reseated = DuoMapping.reseated(duo)
        XCTAssertFalse(reseated.syncedOnce)
        XCTAssertEqual(reseated.cursor, 0)
        XCTAssertEqual(reseated.vers, duo.vers, "the rows it holds stay until the full read replaces them")
        XCTAssertEqual(reseated.partnerDisplayName, "Sam")
    }

    func testAClearedDuoIsRememberedForAsLongAsTheServerCouldListIt() {
        var cleared = DuoClearedSet()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(cleared.contains(id))
        cleared.mark(id, now: now)
        XCTAssertTrue(cleared.contains(id))
        cleared.prune(now: now.addingTimeInterval(DuoProtocolConstants.endedDuoLifetime - 1))
        XCTAssertTrue(cleared.contains(id))
        let other = UUID()
        cleared.mark(other, now: now.addingTimeInterval(DuoProtocolConstants.endedDuoLifetime + 1))
        XCTAssertFalse(cleared.contains(id), "past 30 days the server no longer lists it, so the note goes")
        XCTAssertTrue(cleared.contains(other))
        XCTAssertEqual(try JSONDecoder().decode(DuoClearedSet.self, from: JSONEncoder().encode(cleared)), cleared)
    }

    func testDiagnosticsKeepTheLastTenRequestIDsAndNothingElseAboutThem() throws {
        var diagnostics = DuoDiagnostics()
        let now = Date(timeIntervalSince1970: 100)
        for index in 0..<12 { diagnostics.recordRequest(status: index == 11 ? 503 : 200, requestID: "ray\(index)", at: now) }
        XCTAssertEqual(diagnostics.recentRequests.count, 10)
        XCTAssertEqual(diagnostics.recentRequests.first, DuoDiagnostics.RequestRecord(status: 503, requestID: "ray11", at: now), "newest first")
        XCTAssertEqual(diagnostics.recentRequests.last?.requestID, "ray2")
        diagnostics.recordRequest(status: 200, requestID: nil, at: now)
        diagnostics.recordRequest(status: 200, requestID: "", at: now)
        diagnostics.recordRequest(status: 200, requestID: "has space", at: now)
        diagnostics.recordRequest(status: 200, requestID: String(repeating: "a", count: 65), at: now)
        XCTAssertEqual(diagnostics.recentRequests.count, 10, "a response with nothing to quote leaves nothing")
        let json = String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self)
        XCTAssertFalse(json.contains("path"), "a record is a status, an id and a time")
        XCTAssertEqual(try JSONDecoder().decode(DuoDiagnostics.self, from: JSONEncoder().encode(diagnostics)), diagnostics)
    }

    func testTheWipeOfTheSecretStoreTakesEveryAccountNotJustTheOnesInTheCache() throws {
        let memory = DuoMemorySecretStore()
        let secrets = DuoSecrets(store: memory)
        try secrets.save(DuoCredential(memberID: "m", deviceID: "d", deviceSecret: "s"))
        try secrets.writeInstallMarker(random: SequentialRandom())
        let orphan = UUID()
        try secrets.saveLinkSecret("K", forDuo: orphan)
        try memory.write(Data("key".utf8), service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: "another-device"), accessibility: .afterFirstUnlockThisDeviceOnly)
        try memory.write(Data("x".utf8), service: "someone.else", account: "item", accessibility: .afterFirstUnlock)
        XCTAssertFalse(secrets.isAgeRefused())
        try secrets.markAgeRefused()
        XCTAssertEqual(memory.accounts(service: DuoSecrets.service).count, 4)
        try secrets.deleteEverything()
        XCTAssertTrue(memory.accounts(service: DuoSecrets.service).isEmpty)
        XCTAssertTrue(secrets.isAgeRefused(), "a refusal is another service: a wipe is not a second try")
        XCTAssertEqual(try memory.read(service: "someone.else", account: "item"), Data("x".utf8), "only Duo's service is wiped")
    }
}

/// Test doubles for the seams, shared by every HydroCore test file.
struct FixedClock: DuoClock {
    var now: Date
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// 0, 1, 2, ... so a test can predict every byte.
final class SequentialRandom: DuoRandom, @unchecked Sendable {
    private var next: UInt8 = 0
    private var nextUUID: UInt8 = 0
    func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in defer { next &+= 1 }; return next }
    }
    func uuid() -> UUID {
        nextUUID &+= 1
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, nextUUID))
    }
}

struct FixedRandom: DuoRandom {
    var byte: UInt8
    func bytes(_ count: Int) -> [UInt8] { Array(repeating: byte, count: count) }
    func uuid() -> UUID { UUID() }
}
