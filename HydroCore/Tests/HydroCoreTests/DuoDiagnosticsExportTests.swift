import XCTest
@testable import HydroCore

/// Stage M: what the Diagnostics screen shows and Export diagnostics mails (final design §10.8).
/// It leaves the phone by email, so the tests hold it to ids, numbers, error codes and UTC
/// dates, and feed it every personal thing a field could be made to hold.
final class DuoDiagnosticsExportTests: XCTestCase {
    /// 2026-09-21T14:13:20Z.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let duoA = UUID(uuidString: "6D2A0F3C-1111-4000-8000-000000000001")!
    private let duoB = UUID(uuidString: "0B1C2D3E-2222-4000-8000-000000000002")!

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    /// A request id of the Worker's own shape, 16 lowercase hex characters.
    private func hex(_ value: Int) -> String { String(format: "%016x", value) }

    private func text(supportID: String? = "ABCD1234EFGH", tier: DuoTier? = .attested, appVersion: String = "2.0 (57)",
                      systemVersion: String = "26.5", availability: DuoAvailability = .available, queuedOps: Int = 0,
                      diagnostics: DuoDiagnostics = DuoDiagnostics(), duos: [UUID] = []) -> String {
        DuoDiagnosticsExport.text(supportID: supportID, tier: tier, appVersion: appVersion, systemVersion: systemVersion,
                                  availability: availability, queuedOps: queuedOps, diagnostics: diagnostics, duos: duos, now: now)
    }

    private func report(diagnostics: DuoDiagnostics, duos: [UUID] = []) -> DuoDiagnosticsExport.Report {
        DuoDiagnosticsExport.report(supportID: nil, tier: nil, appVersion: "2.0 (57)", systemVersion: "26.5",
                                    availability: .available, queuedOps: 0, diagnostics: diagnostics, duos: duos)
    }

    // MARK: - The content

    func testTheExportSaysEveryFactOnePerLineWithTimesInUTC() {
        var diagnostics = DuoDiagnostics()
        diagnostics.recordPushUpload(zone: "Europe/London", windowStart: 480, windowEnd: 1320, enabled: true, at: minutesAgo(60))
        diagnostics.recordFetch(duoID: duoA, seq: 12, cursor: 11, at: minutesAgo(1))
        diagnostics.recordWrite(duoID: duoA, at: minutesAgo(2))
        diagnostics.record(DuoTransportError.inviteUnknown(DuoErrorContext(httpStatus: 404, requestID: "8c1f2a3b4c5d6e7f-LHR")),
                           duoID: duoA, now: minutesAgo(120))
        diagnostics.recordRequest(status: 200, requestID: "0123456789abcdef", at: minutesAgo(1))

        XCTAssertEqual(text(queuedOps: 2, diagnostics: diagnostics, duos: [duoA, duoB]), """
        Duo Streaks
        Exported: 2026-09-21T14:13:20Z
        Support ID: ABCD-1234-EFGH
        Tier: attested
        App version: 2.0 (57)
        iOS version: 26.5
        Availability: available
        Queued requests: 2

        Notifications
        Enabled: on
        Time zone: Europe/London
        Window: 08:00-22:00
        Last upload: 2026-09-21T13:13:20Z

        Duo 6d2a0f3c
        Seq: 12
        Cursor: 11
        Last fetch: 2026-09-21T14:12:20Z
        Last write: 2026-09-21T14:11:20Z
        Last error: invite_unknown 404 8c1f2a3b4c5d6e7f 2026-09-21T12:13:20Z

        Duo 0b1c2d3e
        Seq: —
        Cursor: —
        Last fetch: —
        Last write: —
        Last error: —

        Recent errors
        invite_unknown 404 8c1f2a3b4c5d6e7f 2026-09-21T12:13:20Z

        Recent requests
        200 0123456789abcdef 2026-09-21T14:12:20Z
        """)
    }

    func testAPhoneThatKnowsNothingYetReadsAsDashes() {
        XCTAssertEqual(text(supportID: nil, tier: nil, availability: .unknown), """
        Duo Streaks
        Exported: 2026-09-21T14:13:20Z
        Support ID: —
        Tier: —
        App version: 2.0 (57)
        iOS version: 26.5
        Availability: unknown
        Queued requests: 0

        Notifications
        Enabled: —
        Time zone: —
        Window: —
        Last upload: —

        Recent errors
        —

        Recent requests
        —
        """, "no duo means no duo section; no errors or requests means a dash, not an empty heading")
        let off = DuoDiagnostics(lastUploadedZone: "Asia/Tokyo", lastUploadedEnabled: false, lastUploadAt: now)
        let lines = text(diagnostics: off).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Enabled: off"))
        XCTAssertTrue(lines.contains("Window: —"), "the window is sent only with notifications on")
        XCTAssertTrue(lines.contains("Time zone: Asia/Tokyo"))
    }

    func testTheScreenAndTheExportCarryTheSameFacts() {
        var diagnostics = DuoDiagnostics()
        diagnostics.recordPushUpload(zone: "America/New_York", windowStart: 420, windowEnd: 1380, enabled: true, at: minutesAgo(9))
        diagnostics.recordFetch(duoID: duoB, seq: 4, cursor: 4, at: minutesAgo(3))
        for minute in 1...3 {
            diagnostics.record(DuoTransportError.conflict(DuoErrorContext(httpStatus: 409, requestID: "abcdef012345678\(minute)")),
                               duoID: duoB, now: minutesAgo(Double(minute)))
            diagnostics.recordRequest(status: 409, requestID: "abcdef012345678\(minute)", at: minutesAgo(Double(minute)))
        }
        let report = DuoDiagnosticsExport.report(supportID: "ABCD-1234-EFGH", tier: .low, appVersion: "2.0 (57)", systemVersion: "26.5",
                                                 availability: .maintenance, queuedOps: 1, diagnostics: diagnostics, duos: [duoA, duoB])
        let lines = DuoDiagnosticsExport.text(report, now: now).components(separatedBy: "\n")
        for field in report.summary + report.notifications + report.duos.flatMap(\.fields) {
            XCTAssertTrue(lines.contains("\(field.label): \(field.value)"), "\(field.label) is on the screen but not in the export")
        }
        XCTAssertEqual(report.duos.map(\.title), ["Duo 6d2a0f3c", "Duo 0b1c2d3e"], "one section per duo, in the store's order")
        for line in report.errors.map(\.text) + report.requests.map(\.text) { XCTAssertTrue(lines.contains(line)) }
        XCTAssertEqual(report.errors.count, 3)
        XCTAssertEqual(report.requests.count, 3)
        XCTAssertEqual(report.supportID, "ABCD-1234-EFGH")
    }

    // MARK: - Nothing personal

    /// The richest input there can be: names, invite codes, a DeviceCheck token, a bearer, an
    /// email address, IP addresses and a URL, in every field whose type is a string. None of it
    /// may come out, because none of it is an id, an error code or a date. (Counters print as
    /// numbers whatever they hold; `DuoSupportPrivacyTests` pins that.)
    func testNoStringFieldCanCarryANameACodeAKeyOrAnAddressIntoTheExport() {
        let partner = "Samantha Quill", me = "Jonathon Brownstone"
        let diagnostics = DuoDiagnostics(
            recentErrors: [
                .init(code: "H7K39QWX", http: 404, requestID: "jo.brown@example.com", at: minutesAgo(1)),
                .init(code: "samantha", http: nil, requestID: "Bearer abc.def", at: minutesAgo(2)),
                .init(code: "invite_unknown", http: 404, requestID: "203.0.113.7", at: minutesAgo(3)),
                .init(code: "rate_limited", http: 429, requestID: "2001:db8::1", at: minutesAgo(4)),
                .init(code: me, http: 500, requestID: "id-198.51.100.23", at: minutesAgo(5)),
            ],
            recentRequests: [
                .init(status: 200, requestID: "RGV2aWNlQ2hlY2s=", at: minutesAgo(1)),
                .init(status: 200, requestID: "https://evil.example.com/?name=Samantha", at: minutesAgo(2)),
                .init(status: 401, requestID: "H7K3-9QWX k=c2VjcmV0", at: minutesAgo(3)),
                .init(status: 200, requestID: "8c1f2a3b4c5d6e7f-LHR", at: minutesAgo(4)),
            ],
            duos: [duoA.uuidString.lowercased(): .init(seq: 3, cursor: 3, lastError: .init(code: "Quill", http: 500, requestID: "sam@example.com", at: minutesAgo(6)))],
            lastUploadedZone: partner, lastUploadedWindowStart: 480, lastUploadedWindowEnd: 1320, lastUploadedEnabled: true, lastUploadAt: now)
        let output = text(supportID: partner, tier: .low, appVersion: "2.0 (57) \(me)", systemVersion: "jo.brown@example.com",
                          availability: .needsRestoreChoice(DuoRestorePrompt(partnerName: partner, myName: me)),
                          queuedOps: 1, diagnostics: diagnostics, duos: [duoA])

        let forbidden = ["Samantha", "Quill", "Jonathon", "Brownstone", "H7K39QWX", "H7K3-9QWX", "c2VjcmV0", "@", "example.com",
                         "RGV2aWNlQ2hlY2s", "Bearer", "203.0.113.7", "198.51.100.23", "2001:db8", "https", "?name", "-LHR"]
        for word in forbidden {
            XCTAssertFalse(output.localizedCaseInsensitiveContains(word), "\(word) reached the export:\n\(output)")
        }
        XCTAssertFalse(output.contains(duoA.uuidString.lowercased()), "only the first eight characters of a duo id are shown")
        XCTAssertFalse(output.contains(duoA.uuidString))
        // The parts that are what they claim to be still come out.
        XCTAssertTrue(output.contains("Availability: restore question"))
        XCTAssertTrue(output.contains("Duo 6d2a0f3c"))
        XCTAssertTrue(output.contains("200 8c1f2a3b4c5d6e7f 2026-09-21T14:09:20Z"), "a ray id comes out as its 16 hex characters")
        XCTAssertTrue(output.contains("rate_limited 429 —"), "a code this build writes stays, with its unusable id dropped")
        XCTAssertTrue(output.contains("Support ID: —"))
        XCTAssertTrue(output.contains("Time zone: —"))
    }

    func testEveryAvailabilityIsOneFixedWord() {
        let cases: [(DuoAvailability, String)] = [
            (.unknown, "unknown"), (.available, "available"), (.maintenance, "maintenance"), (.upgradeRequired, "update required"),
            (.disconnected, "disconnected"), (.banned, "banned"),
            (.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")), "restore question"),
        ]
        for (availability, word) in cases {
            XCTAssertEqual(DuoDiagnosticsExport.word(for: availability), word)
            XCTAssertTrue(text(availability: availability).components(separatedBy: "\n").contains("Availability: \(word)"))
        }
    }

    func testOnlyACodeThisBuildWritesIsPrinted() {
        var diagnostics = DuoDiagnostics()
        diagnostics.record(DuoTransportError.offline, duoID: nil, now: minutesAgo(1))
        diagnostics.record(DuoTransportError.unreadable(httpStatus: 502, requestID: nil), duoID: nil, now: minutesAgo(2))
        diagnostics.record(CancellationError(), duoID: nil, now: minutesAgo(3))
        diagnostics.recentErrors.append(.init(code: "brand_new_code", http: 400, requestID: nil, at: minutesAgo(4)))
        XCTAssertEqual(report(diagnostics: diagnostics).errors.map(\.code), ["offline", "unreadable", "other", "—"])
        // An unreadable answer keeps its own status (`DuoTransportError.httpStatus`); offline and
        // a non-transport error have none.
        XCTAssertEqual(report(diagnostics: diagnostics).errors.map(\.http), ["—", "502", "—", "400"])
        for code in DuoErrorCode.allCases {
            let record = DuoDiagnostics(recentErrors: [.init(code: code.rawValue, http: 400, requestID: nil, at: now)])
            XCTAssertEqual(report(diagnostics: record).errors.first?.code, code.rawValue)
        }
    }

    // MARK: - At most five errors and ten requests, newest first

    func testAtMostFiveErrorsAndTenRequestsNewestFirst() {
        // Written out of order and over the limits, as a cache this build did not write could hold them.
        let errorAges: [Double] = [9, 3, 7, 1, 8, 2, 6, 4, 5]
        let requestAges: [Double] = [12, 3, 14, 1, 9, 6, 11, 2, 13, 4, 8, 10, 7, 5]
        let diagnostics = DuoDiagnostics(
            recentErrors: errorAges.map { .init(code: "conflict", http: 409, requestID: hex(0xe00 + Int($0)), at: minutesAgo($0)) },
            recentRequests: requestAges.map { .init(status: 200, requestID: hex(0xf00 + Int($0)), at: minutesAgo($0)) })
        let made = report(diagnostics: diagnostics)
        XCTAssertEqual(made.errors.map(\.requestID), (1...5).map { hex(0xe00 + $0) })
        XCTAssertEqual(made.requests.map(\.requestID), (1...10).map { hex(0xf00 + $0) })

        let lines = DuoDiagnosticsExport.text(made, now: now).components(separatedBy: "\n")
        let errorsAt = lines.firstIndex(of: "Recent errors")!, requestsAt = lines.firstIndex(of: "Recent requests")!
        XCTAssertEqual(Array(lines[(errorsAt + 1)..<(requestsAt - 1)]), made.errors.map(\.text))
        XCTAssertEqual(Array(lines[(requestsAt + 1)...]), made.requests.map(\.text))
        XCTAssertEqual(lines[requestsAt + 1], "200 0000000000000f01 \(DuoDiagnosticsExport.time(minutesAgo(1)))", "one `status id time` line each")
    }

    func testTheRecordersListsComeOutNewestFirstAndRecordsAtOneTimeKeepTheirOrder() {
        var diagnostics = DuoDiagnostics()
        for minute in stride(from: 12.0, through: 1, by: -1) {
            diagnostics.record(DuoTransportError.maintenance(DuoErrorContext(httpStatus: 503, requestID: hex(Int(minute)))), duoID: nil, now: minutesAgo(minute))
            diagnostics.recordRequest(status: 503, requestID: hex(Int(minute)), at: minutesAgo(minute))
        }
        XCTAssertEqual(report(diagnostics: diagnostics).errors.map(\.requestID), (1...5).map(hex))
        XCTAssertEqual(report(diagnostics: diagnostics).requests.map(\.requestID), (1...10).map(hex))

        let same = DuoDiagnostics(recentRequests: [.init(status: 200, requestID: hex(0xb), at: now), .init(status: 200, requestID: hex(0xa), at: now)])
        XCTAssertEqual(report(diagnostics: same).requests.map(\.requestID), [hex(0xb), hex(0xa)], "a tie keeps the order it was written in")
    }

    // MARK: - Dates, ids and the window

    func testTimesAreISO8601InUTCWhateverThePhonesZone() {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Pacific/Chatham")!
        defer { NSTimeZone.default = saved }
        XCTAssertEqual(DuoDiagnosticsExport.time(now), "2026-09-21T14:13:20Z")
        XCTAssertEqual(DuoDiagnosticsExport.time(nil), "—")
        let diagnostics = DuoDiagnostics(recentRequests: [.init(status: 204, requestID: "0123456789abcdef", at: now)])
        XCTAssertTrue(text(diagnostics: diagnostics).contains("204 0123456789abcdef 2026-09-21T14:13:20Z"))
        XCTAssertTrue(text().contains("Exported: 2026-09-21T14:13:20Z"))
    }

    func testADuoIsNamedByTheFirstEightCharactersOfItsLowercaseID() {
        XCTAssertEqual(DuoDiagnosticsExport.shortID(duoA), "6d2a0f3c")
        let output = text(duos: [duoA])
        XCTAssertTrue(output.contains("Duo 6d2a0f3c\n"))
        XCTAssertFalse(output.contains("6d2a0f3c-"), "nothing past the first eight characters")
        XCTAssertFalse(output.contains("6D2A0F3C"))
    }

    func testTheSupportIDIsShownOnlyWhenItIsOne() {
        XCTAssertEqual(DuoDiagnosticsExport.displaySupportID("ABCD1234EFGH"), "ABCD-1234-EFGH")
        XCTAssertEqual(DuoDiagnosticsExport.displaySupportID("ABCD-1234-EFGH"), "ABCD-1234-EFGH")
        XCTAssertEqual(DuoDiagnosticsExport.displaySupportID("0123456789VZ"), "0123-4567-89VZ")
        for notOne in [nil, "", "abcd1234efgh", "ABCD1234EFG", "ABCD1234EFGHJ", "ABCDI234EFGH", "ABCDL234EFGH", "ABCDO234EFGH",
                       "ABCDU234EFGH", "ABC-D1234EFGH", "ABCD-1234EFGH", "ABCD_1234_EFGH", "Samantha Q", "ABCD 1234 EFGH"] {
            XCTAssertNil(DuoDiagnosticsExport.displaySupportID(notOne), "\(notOne ?? "nil") is not a Support ID")
        }
    }

    func testTheWindowIsHoursAndMinutesAndAnythingOddIsShownAsANumber() {
        func window(_ start: Int?, _ end: Int?) -> String {
            let diagnostics = DuoDiagnostics(lastUploadedWindowStart: start, lastUploadedWindowEnd: end)
            return report(diagnostics: diagnostics).notifications.first { $0.label == "Window" }!.value
        }
        XCTAssertEqual(window(0, 1439), "00:00-23:59")
        XCTAssertEqual(window(450, 1305), "07:30-21:45")
        XCTAssertEqual(window(nil, nil), "—")
        XCTAssertEqual(window(480, nil), "—")
        XCTAssertEqual(window(1440, -5), "1440--5")
    }

    func testAVersionOrAZoneThatIsNotOneReadsAsADash() {
        let made = DuoDiagnosticsExport.report(supportID: nil, tier: nil, appVersion: "2.0 (57) beta", systemVersion: "",
                                               availability: .available, queuedOps: 0,
                                               diagnostics: DuoDiagnostics(lastUploadedZone: "Not/AZone"), duos: [])
        XCTAssertEqual(made.summary.first { $0.label == "App version" }?.value, "—")
        XCTAssertEqual(made.summary.first { $0.label == "iOS version" }?.value, "—")
        XCTAssertEqual(made.notifications.first { $0.label == "Time zone" }?.value, "—")
        let fine = DuoDiagnosticsExport.report(supportID: nil, tier: .attested, appVersion: "1.8.1 (34)", systemVersion: "26.0.1",
                                               availability: .available, queuedOps: 0,
                                               diagnostics: DuoDiagnostics(lastUploadedZone: "America/Argentina/Buenos_Aires"), duos: [])
        XCTAssertEqual(fine.summary.map(\.value), ["—", "attested", "1.8.1 (34)", "26.0.1", "available", "0"])
        XCTAssertEqual(fine.notifications.first { $0.label == "Time zone" }?.value, "America/Argentina/Buenos_Aires")
    }

    // MARK: - Decision D76 and the stage review's fixes

    /// D76: a request id prints only in the one shape the Worker writes, `cf-ray` style, and then
    /// only its 16 hex characters (the data-centre code names a city). The privacy review planted
    /// each of these through the shared filter, which let them all print.
    func testARequestIDPrintsOnlyInTheWorkersShapeAndOnlyItsSixteenHexCharacters() {
        func printed(_ id: String) -> String {
            report(diagnostics: DuoDiagnostics(recentRequests: [.init(status: 200, requestID: id, at: now)])).requests[0].requestID
        }
        XCTAssertEqual(printed("8c1f2a3b4c5d6e7f"), "8c1f2a3b4c5d6e7f")
        XCTAssertEqual(printed("8c1f2a3b4c5d6e7f-LHR"), "8c1f2a3b4c5d6e7f", "the data-centre code is not printed")
        XCTAssertEqual(printed("0123456789abcdef-MAN"), "0123456789abcdef")
        let refused = [
            "b_moWOq6Ecxy8__wLyHy1H-3k_1cjE4FM3mRJxzq8ks",                      // a 43-character secret
            "6cb4f726197560e73bf2142fc39b70bdad23bb0d45e520876837192525c77935", // a 64-hex push token
            "7f3e2a10-aaaa-4bbb-8ccc-0123456789ab",                             // a UUID (a device id)
            "203-0-113-7", "ip-10-0-0-1", "2001-db8--1", "203.0.113.7", "fe80--1",  // addresses
            "SammyBear", "jo.brown_example.com", "SamanthaQuill", "Bearer.abc",     // names, mail
            "8C1F2A3B4C5D6E7F-lhr", "8C1F2A3B4C5D6E7F", "8c1f2a3b4c5d6e7f-lhr",    // the wrong case
            "8c1f2a3b4c5d6e7", "8c1f2a3b4c5d6e7f0", "8c1f2a3b4c5d6e7f-LHRX", "8c1f2a3b4c5d6e7f-LH",
            "8c1f2a3b4c5d6e7f\n", " 8c1f2a3b4c5d6e7f", "8c1f\u{200B}2a3b4c5d6e7f", "\u{202E}8c1f2a3b4c5d6e7f",
            "", String(repeating: "a", count: 64),
        ]
        for id in refused { XCTAssertEqual(printed(id), "—", "\(id.debugDescription) printed") }
        let error = DuoDiagnostics(recentErrors: [.init(code: "conflict", http: 409, requestID: "7f3e2a10-aaaa-4bbb-8ccc-0123456789ab", at: now)],
                                   duos: [duoA.uuidString.lowercased(): .init(lastError: .init(code: "conflict", http: 409, requestID: "8c1f2a3b4c5d6e7f-LHR", at: now))])
        let made = report(diagnostics: error, duos: [duoA])
        XCTAssertEqual(made.errors[0].requestID, "—", "an error's id goes through the same rule")
        XCTAssertEqual(made.duos[0].fields.last?.value, "conflict 409 8c1f2a3b4c5d6e7f 2026-09-21T14:13:20Z", "and a duo's last error's")
    }

    /// D76: an HTTP status outside 100 to 599 is not one, on an error or a response, on the screen
    /// and in the export.
    func testAStatusOutside100To599ReadsAsADash() {
        for (status, shown) in [(4_155_551_234, "—"), (0, "—"), (-1, "—"), (99, "—"), (600, "—"), (100, "100"), (599, "599"), (404, "404")] {
            let diagnostics = DuoDiagnostics(recentErrors: [.init(code: "conflict", http: status, requestID: nil, at: now)],
                                             recentRequests: [.init(status: status, requestID: hex(1), at: now)])
            let made = report(diagnostics: diagnostics)
            XCTAssertEqual(made.errors[0].http, shown, "error status \(status)")
            XCTAssertEqual(made.requests[0].status, shown, "response status \(status)")
            let lines = DuoDiagnosticsExport.text(made, now: now).components(separatedBy: "\n")
            XCTAssertTrue(lines.contains("conflict \(shown) — 2026-09-21T14:13:20Z"), "\(status) in the export's error line")
            XCTAssertTrue(lines.contains("\(shown) \(hex(1)) 2026-09-21T14:13:20Z"), "\(status) in the export's request line")
        }
    }

    /// The foundation now keeps an unreadable answer's own status, and the export prints it with
    /// the request id in the Worker's shape (the copy review's probe).
    func testAnUnreadableAnswerKeepsItsStatusInTheExport() {
        var diagnostics = DuoDiagnostics()
        diagnostics.record(DuoTransportError.unreadable(httpStatus: 502, requestID: "8c1f2a3b4c5d6e7f-LHR"), duoID: duoA, now: now)
        diagnostics.record(DuoTransportError.unreadable(httpStatus: 200, requestID: nil), duoID: nil, now: minutesAgo(1))
        let lines = text(diagnostics: diagnostics, duos: [duoA]).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("unreadable 502 8c1f2a3b4c5d6e7f 2026-09-21T14:13:20Z"))
        XCTAssertTrue(lines.contains("Last error: unreadable 502 8c1f2a3b4c5d6e7f 2026-09-21T14:13:20Z"))
        XCTAssertTrue(lines.contains("unreadable 200 — 2026-09-21T14:12:20Z"), "a 2xx that did not decode says so")
    }

    /// D76: while the restore question is up the identity may be the previous owner's, so neither
    /// the screen nor the export shows a Support ID (and the screen offers no Copy).
    func testTheSupportIDIsADashWhileTheRestoreQuestionIsUp() {
        let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        XCTAssertNil(DuoDiagnosticsExport.shownSupportID("ABCD1234EFGH", availability: restore))
        for other in [DuoAvailability.unknown, .available, .maintenance, .upgradeRequired, .disconnected, .banned] {
            XCTAssertEqual(DuoDiagnosticsExport.shownSupportID("ABCD1234EFGH", availability: other), "ABCD-1234-EFGH")
            XCTAssertNil(DuoDiagnosticsExport.shownSupportID("Samantha Q", availability: other))
        }
        let made = DuoDiagnosticsExport.report(supportID: "ABCD1234EFGH", tier: .attested, appVersion: "2.0 (57)", systemVersion: "26.5",
                                               availability: restore, queuedOps: 0, diagnostics: DuoDiagnostics(), duos: [])
        XCTAssertNil(made.supportID, "no Copy")
        XCTAssertEqual(made.summary[0].value, "—")
        XCTAssertTrue(text(availability: restore).components(separatedBy: "\n").contains("Support ID: —"))
        XCTAssertFalse(text(availability: restore).contains("ABCD"))
        XCTAssertTrue(text(availability: .available).components(separatedBy: "\n").contains("Support ID: ABCD-1234-EFGH"))
    }

    func testTheTierIsAWord() {
        XCTAssertEqual(DuoDiagnosticsExport.word(for: DuoTier.attested), "attested")
        XCTAssertEqual(DuoDiagnosticsExport.word(for: DuoTier.low), "low")
        XCTAssertTrue(text(tier: .low).components(separatedBy: "\n").contains("Tier: low"))
    }

    /// The bug-report header above the export already says "App version" and "iOS version"; the
    /// Duo facts repeat them only when they differ (a Debug `-DuoClientVersion`), and the screen
    /// always shows them.
    func testTheExportSaysTheVersionsOnceUnlessTheyDifferFromTheHeader() {
        let made = DuoDiagnosticsExport.report(supportID: nil, tier: nil, appVersion: "2.0 (57)", systemVersion: "26.5",
                                               availability: .available, queuedOps: 0, diagnostics: DuoDiagnostics(), duos: [])
        let header = ["---", "App version: 2.0 (57)", "iOS version: 26.5", "Device: iPhone"]
        let same = DuoDiagnosticsExport.text(made, now: now, alreadySaid: header).components(separatedBy: "\n")
        XCTAssertFalse(same.contains("App version: 2.0 (57)"))
        XCTAssertFalse(same.contains("iOS version: 26.5"))
        XCTAssertTrue(same.contains("Availability: available"), "only the two repeated lines go")
        let other = DuoDiagnosticsExport.text(made, now: now, alreadySaid: ["App version: 1.8.1 (34)", "iOS version: 26.5"]).components(separatedBy: "\n")
        XCTAssertTrue(other.contains("App version: 2.0 (57)"), "a version the Duo server is told that the header does not say stays")
        XCTAssertFalse(other.contains("iOS version: 26.5"))
        let noHeader = DuoDiagnosticsExport.text(made, now: now).components(separatedBy: "\n")
        XCTAssertTrue(noHeader.contains("App version: 2.0 (57)") && noHeader.contains("iOS version: 26.5"))
        XCTAssertEqual(made.summary.map(\.label), ["Support ID", "Tier", "App version", "iOS version", "Availability", "Queued requests"],
                       "the screen keeps both")
        let sneaky = DuoDiagnosticsExport.text(made, now: now, alreadySaid: ["Availability: available"]).components(separatedBy: "\n")
        XCTAssertTrue(sneaky.contains("Availability: available"), "no other line is ever dropped")
    }

    func testTheExportMailsSubjectIsTheBugReportsWithTheScreensName() {
        XCTAssertEqual(DuoDiagnosticsExport.Label.mailSubject, "HydroDrop bug report: Diagnostics")
        XCTAssertEqual(DuoDiagnosticsExport.Label.title, "Duo Streaks")
    }
}
