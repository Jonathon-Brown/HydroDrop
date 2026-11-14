import XCTest
@testable import HydroCore

/// Stage M's privacy review, kept as tests: a store full of hostile content is run through the
/// real export and report code, and every channel a mail leaves by (the composer's plain body,
/// the raw `mailto:` link and the link as a mail app decodes it) is scanned for every marker the
/// review planted. The writers are exercised end to end: what a response's `X-Request-Id`,
/// `CF-Ray` or an error body's `request_id` can put into Diagnostics, and so into the export.
final class DuoSupportPrivacyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_450_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private static let secret43 = "b_moWOq6Ecxy8__wLyHy1H-3k_1cjE4FM3mRJxzq8ks"
    private static let pushToken64 = "6cb4f726197560e73bf2142fc39b70bdad23bb0d45e520876837192525c77935"
    private static let deviceID = "7f3e2a10-aaaa-4bbb-8ccc-0123456789ab"
    private static let memberID = "9c8b7a65-4321-4fed-8cba-fedcba987654"
    private static let duoFull = "6d2a0f3c-1111-4000-8000-000000000001"
    private static let phoneNumber = 4_155_551_234

    /// Every planted marker; one reaching any channel is a leak.
    private static let markers: [(tag: String, value: String)] = [
        ("partner name", "Samantha"), ("partner surname", "Quill"), ("my name", "Jonathon"), ("my surname", "Brownstone"),
        ("nickname", "SammyBear"), ("emoji name", "💧"), ("RTL override", "\u{202E}"), ("long name", String(repeating: "Zq", count: 20)),
        ("email @", "@"), ("email domain", "example.com"), ("email local", "jo.brown"), ("email no-@ form", "jo.brown_example"),
        ("invite code", "H7K39QWX"), ("invite code dashed", "H7K3-9QWX"), ("link secret k", "c2VjcmV0"),
        ("43-char secret", secret43), ("bearer word", "Bearer"), ("DeviceCheck token", "AgAAAP+tDC"),
        ("push token 64hex", pushToken64), ("device id (full)", deviceID), ("member id (full)", memberID),
        ("duo id (full)", duoFull), ("IPv4 dotted", "203.0.113.7"), ("IPv4 embedded", "198.51.100.23"),
        ("IPv4 dashed", "203-0-113-7"), ("IPv4 aws-style", "ip-10-0-0-1"), ("IPv4 hex", "cb007107"),
        ("IPv6 colon", "2001:db8"), ("IPv6 dashed", "2001-db8--1"), ("IPv4-mapped v6", "ffff"),
        ("URL scheme", "https"), ("URL query", "?name"), ("newline-split name", "Sam\nQuill"),
        ("drink amount", "350ml"), ("goal", "goal2500"), ("zone = a name", "Samantha_Quill"),
        ("cyrillic lookalike", "АBCD"), ("fullwidth", "ＡBCD"), ("zero-width", "\u{200B}"),
        ("name-shaped Support ID", "SAMA-NTHA-KERR"), ("cf-ray colo", "-LHR"), ("phone number as a status", String(phoneNumber)),
    ]

    private static let hostileIDs: [String] = [
        "jo.brown@example.com", "Bearer abc.def", "203.0.113.7", "2001:db8::1", "id-198.51.100.23",
        secret43, pushToken64, deviceID, "203-0-113-7", "ip-10-0-0-1", "cb007107", "2001-db8--1",
        "::ffff:203.0.113.9", "https://evil.example.com/?name=Samantha", "Sam\nQuill", "H7K3-9QWX k=c2VjcmV0",
        "jo.brown_example.com", "SammyBear", "\u{202E}8c1f2a3b4c5d6e7f", "АBCD1234", "ＡBCD", "8c1f\u{200B}2a3b",
        "8c1f2a3b4c5d6e7f-LHR", "goal2500-350ml", String(repeating: "Zq", count: 300), "AgAAAP+tDC==", "H7K39QWX",
    ]

    /// The review's hostile diagnostics for some of the hostile ids, with one change: the
    /// counters (seq, the queue, the window's minutes) hold ordinary numbers, since a counter
    /// prints as the number it is (`testCountersPrintAsTheNumbersTheyAre`). Every status is the
    /// phone number. At most five ids at a time, so each one is inside both caps (five errors,
    /// ten requests) and really reaches the filter: the review's probe put 27 in one store, and
    /// the caps kept 17 of them from ever being looked at.
    private func hostileDiagnostics(_ ids: ArraySlice<String>) -> DuoDiagnostics {
        var errors: [DuoDiagnostics.ErrorRecord] = []
        var requests: [DuoDiagnostics.RequestRecord] = []
        for (index, id) in ids.enumerated() {
            let code = ["rate_limited", "Samantha Quill", "H7K39QWX"][index % 3]
            errors.append(.init(code: code, http: Self.phoneNumber, requestID: id, at: ago(Double(index))))
            requests.append(.init(status: Self.phoneNumber, requestID: id, at: ago(Double(index))))
        }
        return DuoDiagnostics(
            recentErrors: errors, recentRequests: requests,
            duos: [Self.duoFull: .init(seq: 4, cursor: 3, lastFetchAt: ago(1), lastWriteAt: ago(2),
                                       lastError: .init(code: "Quill", http: Self.phoneNumber, requestID: "sam@example.com", at: ago(6))),
                   "Samantha Quill": .init(seq: 9, cursor: 9, lastError: .init(code: "x", http: 1, requestID: "SammyBear", at: ago(1))),
                   Self.deviceID: .init(seq: 1, cursor: 1)],
            lastUploadedZone: "Samantha_Quill", lastUploadedWindowStart: 480, lastUploadedWindowEnd: 1320,
            lastUploadedEnabled: true, lastUploadAt: now)
    }

    /// `Diagnostics.summary` as the app writes it (the bundle's and UIDevice's values; the model
    /// is the generic "iPhone", never the name the person gave the phone).
    private static let header = "---\nApp version: 1.8.1 (34)\niOS version: 26.5\nDevice: iPhone"

    private struct Channels {
        var plain: String
        var raw: String
        var decoded: String
    }

    private func channels(subject: String, body: String) throws -> Channels {
        let url = try XCTUnwrap(DuoReportMail.mailtoURL(recipient: DuoReportMail.recipient, subject: subject, body: body))
        let prefix = "mailto:" + DuoReportMail.recipient
        XCTAssertTrue(url.absoluteString.hasPrefix(prefix + "?subject="))
        let raw = String(url.absoluteString.dropFirst(prefix.count))
        return Channels(plain: subject + "\n" + body, raw: raw, decoded: raw.removingPercentEncoding ?? "<undecodable>")
    }

    private func leaks(_ channels: Channels) -> [String] {
        Self.markers.compactMap { marker in
            var hits: [String] = []
            if channels.plain.localizedCaseInsensitiveContains(marker.value) { hits.append("composer") }
            if channels.raw.contains(marker.value) { hits.append("mailto") }
            if channels.decoded.localizedCaseInsensitiveContains(marker.value) { hits.append("decoded") }
            return hits.isEmpty ? nil : "\(marker.tag) [\(hits.joined(separator: ","))]"
        }
    }

    // MARK: - The export

    func testAHostileStoreLeavesNoMarkerInAnyChannelOfTheExport() throws {
        let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Samantha Quill", myName: "Jonathon Brownstone"))
        var printedTheRealID = false
        for start in stride(from: 0, to: Self.hostileIDs.count, by: 5) {
            let ids = Self.hostileIDs[start..<min(start + 5, Self.hostileIDs.count)]
            let report = DuoDiagnosticsExport.report(supportID: "SAMANTHAKERR", tier: .attested, appVersion: "2.0 (57) Jonathon",
                                                     systemVersion: "26.5\u{202E}jo.brown@example.com", availability: restore,
                                                     queuedOps: 3, diagnostics: hostileDiagnostics(ids), duos: [UUID(uuidString: Self.duoFull)!])
            XCTAssertEqual(report.errors.count, ids.count, "every id of this batch reaches the filter")
            XCTAssertEqual(report.requests.count, ids.count)
            let body = Self.header + "\n\n" + DuoDiagnosticsExport.text(report, now: now, alreadySaid: Self.header.components(separatedBy: "\n"))
            let found = leaks(try channels(subject: DuoDiagnosticsExport.Label.mailSubject, body: body))
            XCTAssertEqual(found, [], "\(found)\n\(body)")
            let odd = body.unicodeScalars.filter { !($0.isASCII && ($0.value >= 0x20 || $0 == "\n")) }
            XCTAssertEqual(Set(odd.map(\.value)), [0x2014], "the only character outside printable ASCII is the dash")
            if body.contains("8c1f2a3b4c5d6e7f ") { printedTheRealID = true }
        }
        XCTAssertTrue(printedTheRealID, "the one id of the Worker's shape is still printed, as its 16 hex characters")
    }

    func testAHostileDefaultsBlobLeavesNothing() throws {
        let json = """
        {"recentErrors":[{"code":"Samantha","http":null,"requestID":"jo.brown@example.com","at":0},
                         {"code":"rate_limited","http":4155551234,"requestID":"\(Self.secret43)","at":1}],
         "recentRequests":[{"status":200,"requestID":"Sam\\u202eQuill","at":0},{"status":200,"requestID":"\(Self.deviceID)","at":1}],
         "duos":{"\(Self.duoFull)":{"seq":1,"cursor":1,"lastError":{"code":"other","requestID":"203.0.113.7","at":2}}},
         "lastUploadedZone":"Samantha Quill","lastUploadedEnabled":true,"lastUploadAt":3}
        """
        let diagnostics = try JSONDecoder().decode(DuoDiagnostics.self, from: Data(json.utf8))
        let text = DuoDiagnosticsExport.text(supportID: "jo.brown@example.com", tier: .low, appVersion: "1.8.1 (34)", systemVersion: "26.5",
                                             availability: .available, queuedOps: 0, diagnostics: diagnostics,
                                             duos: [UUID(uuidString: Self.duoFull)!], now: now)
        let found = leaks(try channels(subject: DuoDiagnosticsExport.Label.mailSubject, body: text))
        XCTAssertEqual(found, [], "\(found)\n\(text)")
    }

    /// What whatever answers the request (the Worker, the edge, a proxy the phone trusts) can put
    /// in `X-Request-Id`, `CF-Ray` or an error body's `request_id`, through the real classifier and
    /// recorders, and into the export. Only the Worker's shape gets through, as 16 hex characters.
    func testWhatAResponseCanPlantEndToEnd() throws {
        let planted = [Self.secret43, Self.pushToken64, Self.deviceID, "203-0-113-7", "2001-db8--1", "ip-10-0-0-1",
                       "SammyBear", "jo.brown_example.com", "8C1F2A3B4C5D6E7F-lhr", "203.0.113.7", "2001:db8::1",
                       "Bearer abc", "x" + String(repeating: "a", count: 64), "Samantha.Quill", "Jonathon"]
        for value in planted {
            for (xRequestID, cfRay) in [(value, nil), (nil, value)] as [(String?, String?)] {
                var diagnostics = DuoDiagnostics()
                diagnostics.recordRequest(status: 200, requestID: DuoErrorClassifier.headerRequestID(xRequestID: xRequestID, cfRay: cfRay), at: now)
                let body = try JSONSerialization.data(withJSONObject: ["error": ["code": "rate_limited", "message": "m", "request_id": value]])
                diagnostics.record(DuoErrorClassifier.classify(status: 429, contentType: "application/json", retryAfter: nil,
                                                               requestID: "bad id!", body: body), duoID: nil, now: now)
                let text = DuoDiagnosticsExport.text(supportID: nil, tier: nil, appVersion: "1.8.1 (34)", systemVersion: "26.5",
                                                     availability: .available, queuedOps: 0, diagnostics: diagnostics, duos: [], now: now)
                XCTAssertFalse(text.localizedCaseInsensitiveContains(value), "\(value) planted in \(xRequestID == nil ? "CF-Ray" : "X-Request-Id") printed")
            }
        }
        var diagnostics = DuoDiagnostics()
        diagnostics.recordRequest(status: 200, requestID: DuoErrorClassifier.headerRequestID(xRequestID: nil, cfRay: "8c1f2a3b4c5d6e7f-LHR"), at: now)
        let text = DuoDiagnosticsExport.text(supportID: nil, tier: nil, appVersion: "1.8.1 (34)", systemVersion: "26.5",
                                             availability: .available, queuedOps: 0, diagnostics: diagnostics, duos: [], now: now)
        XCTAssertTrue(text.contains("200 8c1f2a3b4c5d6e7f 2026-10-08"), "a real ray id is printed without its data-centre code")
        XCTAssertFalse(text.contains("-LHR"))
    }

    /// A counter prints as the number it is, whatever that is: the one thing in the export a
    /// hostile defaults blob can still choose freely. Pinned so a change is made on purpose.
    func testCountersPrintAsTheNumbersTheyAre() {
        let diagnostics = DuoDiagnostics(duos: [Self.duoFull: .init(seq: Int64(Self.phoneNumber), cursor: 3)],
                                         lastUploadedWindowStart: Self.phoneNumber, lastUploadedWindowEnd: 1320)
        let lines = DuoDiagnosticsExport.text(supportID: nil, tier: nil, appVersion: "1.8.1 (34)", systemVersion: "26.5", availability: .available,
                                              queuedOps: Self.phoneNumber, diagnostics: diagnostics,
                                              duos: [UUID(uuidString: Self.duoFull)!], now: now).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Seq: 4155551234"))
        XCTAssertTrue(lines.contains("Queued requests: 4155551234"))
        XCTAssertTrue(lines.contains("Window: 4155551234-22:00"))
    }

    // MARK: - The report mail

    func testTheReportMailLeavesNoMarkerInAnyChannel() throws {
        for reason in DuoReportMail.Reason.allCases {
            for supportID in ["jo.brown@example.com", "\u{202E}BCD1234EFGH", "АBCD1234EFGH", nil] as [String?] {
                let mail = DuoReportMail.make(reason: reason, duoID: UUID(uuidString: Self.duoFull)!, supportID: supportID)
                let found = leaks(try channels(subject: mail.subject, body: mail.body)).filter { !$0.hasPrefix("duo id (full)") }
                XCTAssertEqual(found, [], "\(found)")
                XCTAssertEqual(mail.body.components(separatedBy: "\n").count, 3)
            }
            // The one thing the review could not exclude (L4, accepted): a Support ID is twelve
            // Crockford characters, and some names are too. Only `GET /me` writes it.
            let named = DuoReportMail.make(reason: reason, duoID: UUID(uuidString: Self.duoFull)!, supportID: "SAMANTHAKERR")
            XCTAssertTrue(named.body.hasSuffix("Support ID: SAMA-NTHA-KERR"))
        }
    }

    // MARK: - The mailto: channel

    /// The largest export this build can make, as a `mailto:` link: RFC 6068 line breaks, no raw
    /// `+` (a zone such as `Etc/GMT+5`), and a round trip to the same text.
    func testTheLargestExportRoundTripsThroughAMailtoLink() throws {
        var diagnostics = DuoDiagnostics()
        for index in 0..<5 {
            diagnostics.recentErrors.append(.init(code: "idempotency_mismatch", http: 422, requestID: "8c1f2a3b4c5d6e7f-LHR", at: ago(Double(index))))
        }
        for index in 0..<10 { diagnostics.recentRequests.append(.init(status: 200, requestID: "8c1f2a3b4c5d6e7f-LHR", at: ago(Double(index)))) }
        var duos: [UUID] = []
        for index in 0..<5 {
            let id = UUID()
            duos.append(id)
            diagnostics.duos[id.uuidString.lowercased()] = .init(seq: Int64.max, cursor: Int64.max, lastFetchAt: now, lastWriteAt: now,
                                                                 lastError: .init(code: "conflict", http: 409, requestID: nil, at: ago(Double(index))))
        }
        diagnostics.recordPushUpload(zone: "Etc/GMT+5", windowStart: 0, windowEnd: 1439, enabled: true, at: now)
        let body = Self.header + "\n\n" + DuoDiagnosticsExport.text(supportID: "ABCD1234EFGH", tier: .attested, appVersion: "12.34.56 (123456)",
                                                                    systemVersion: "26.5.1", availability: .available, queuedOps: 999,
                                                                    diagnostics: diagnostics, duos: duos, now: now)
        XCTAssertTrue(body.contains("Time zone: Etc/GMT+5"))
        let url = try XCTUnwrap(DuoReportMail.mailtoURL(recipient: DuoReportMail.recipient, subject: DuoDiagnosticsExport.Label.mailSubject, body: body))
        let link = url.absoluteString
        XCTAssertFalse(link.contains("+") || link.contains(" ") || link.contains("\n") || link.contains("\r"))
        XCTAssertTrue(link.contains("%2B"))
        let back = URLComponents(string: link)?.percentEncodedQueryItems?.first { $0.name == "body" }?.value?.removingPercentEncoding
        XCTAssertEqual(back, body.replacingOccurrences(of: "\n", with: "\r\n"))
    }
}
