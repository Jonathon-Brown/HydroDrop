import XCTest
@testable import HydroCore

// Stage L: how a typed, pasted or scanned code is read, what the two hand-entry sheets say
// about the phone, when a Reconnect tap may send, and the camera's states (final design §3.4,
// §3.5, §4.1). The code-entry and reconnect sheets draw these answers and decide nothing of
// their own.

final class DuoCodeEntryModelTests: XCTestCase {
    private let secret = "ABCDEFGHJKMNPQRSTVWXYZ0123"

    private func code(_ text: String) -> DuoParsedInvite? {
        if case .invite(let invite) = DuoCodeEntryModel.submit(text) { return invite }
        return nil
    }

    // MARK: - Typed and pasted

    func testEveryTypedShapeOfAGoodCodeReadsAsTheCanonicalCode() {
        let shapes = [
            "H7K39QWX", "h7k39qwx", "h7k3-9qwx", "H7K3-9QWX", "H7K3 9QWX", "h7k3 9qwx", "H7-K3 9Q-WX",
            "  h7k3-9qwx  ", "\th7k3-9qwx\n", "H7k3-9QwX",
        ]
        for shape in shapes {
            XCTAssertEqual(code(shape), DuoParsedInvite(code: "H7K39QWX"), "\(shape.debugDescription)")
        }
    }

    func testTheLookalikeLettersReadAsDigits() {
        XCTAssertEqual(code("H7KO-9QWX")?.code, "H7K09QWX", "O is 0")
        XCTAssertEqual(code("h7ko-9qwx")?.code, "H7K09QWX", "o is 0")
        XCTAssertEqual(code("H7KI-9QWL")?.code, "H7K19QW1", "I and L are 1")
        XCTAssertEqual(code("h7ki-9qwl")?.code, "H7K19QW1", "i and l are 1")
        XCTAssertEqual(code("OIL0-OIL0")?.code, "01100110")
    }

    func testAPastedLinkGivesItsCodeAndKeepsItsSecretExactly() {
        XCTAssertEqual(code("https://hydrodrop.us/duo#H7K39QWX"), DuoParsedInvite(code: "H7K39QWX", k: nil))
        XCTAssertEqual(code("https://hydrodrop.us/duo#H7K39QWX.\(secret)"), DuoParsedInvite(code: "H7K39QWX", k: secret))
        XCTAssertEqual(code("https://hydrodrop.us/duo#h7k39qwx.\(secret)"), DuoParsedInvite(code: "H7K39QWX", k: secret),
                       "the code is normalised, the secret kept as it came")
        XCTAssertEqual(code("  https://hydrodrop.us/duo#H7K39QWX.\(secret)\n"), DuoParsedInvite(code: "H7K39QWX", k: secret),
                       "a paste with a line break around it")
        XCTAssertEqual(code("HTTPS://HYDRODROP.US/duo#H7K39QWX"), DuoParsedInvite(code: "H7K39QWX"), "scheme and host in any case")
    }

    func testALinkAnywhereButHydroDropDuoIsNotACode() {
        let refused = [
            "https://example.com/duo#H7K39QWX",
            "https://hydrodrop.us.example.com/duo#H7K39QWX",
            "https://hydrodrop.us/tap#H7K39QWX",
            "https://hydrodrop.us/DUO#H7K39QWX",
            "http://hydrodrop.us/duo#H7K39QWX",
            "https://hydrodrop.us/duo?c=H7K39QWX",
            "https://hydrodrop.us/duo?c=1#H7K39QWX",
            "https://hydrodrop.us/duo",
            "https://hydrodrop.us/duo#",
            "https://hydrodrop.us/duo#H7K39QWX.SHORT",
            "https://hydrodrop.us/duo#H7K39QWX.\(secret.lowercased())",
            "https://hydrodrop.us/duo#H7K39QWX.\(secret)Z",
            "hydrodrop.us/duo#H7K39QWX",
            "hydrodrop://duo#H7K39QWX",
        ]
        for text in refused {
            XCTAssertEqual(DuoCodeEntryModel.submit(text), .notACode, text)
        }
        // D82 requires the exact raw path; a trailing slash is a different link.
        XCTAssertEqual(DuoCodeEntryModel.submit("https://hydrodrop.us/duo/#H7K39QWX"), .notACode)
    }

    func testWrongLengthsEmptyAndOtherCharactersAreNotACode() {
        let refused = [
            "", " ", "   \n", "H7K39QW", "H7K3-9QW", "H7K39QWXY", "H7K3-9QWX-Y", "H7K39QWU", "H7K3_9QWX", "H7K3.9QWX",
            "\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}", "H7K3-9QW\u{1F4A7}",
            "H7K\u{FF13}9QWX", String(repeating: "\u{DF}", count: 8), "H7K3\n9QWX", "H7K3\u{00A0}9QWX",
        ]
        for text in refused {
            XCTAssertEqual(DuoCodeEntryModel.submit(text), .notACode, text.debugDescription)
        }
    }

    // MARK: - Scanned

    func testOnlyAScannedHydroDropLinkIsRead() {
        XCTAssertEqual(DuoCodeEntryModel.scan("https://hydrodrop.us/duo#H7K39QWX.\(secret)"), DuoParsedInvite(code: "H7K39QWX", k: secret))
        XCTAssertEqual(DuoCodeEntryModel.scan("https://hydrodrop.us/duo#H7K39QWX"), DuoParsedInvite(code: "H7K39QWX"))
        XCTAssertEqual(DuoCodeEntryModel.scan("https://hydrodrop.us/duo#h7k39qwx\r\n"), DuoParsedInvite(code: "H7K39QWX"), "a QR's trailing line break")
        XCTAssertEqual(DuoCodeEntryModel.scan("HTTPS://HYDRODROP.US/duo#H7K39QWX"), DuoParsedInvite(code: "H7K39QWX"))
    }

    /// D88: a bare code is typed or pasted, never scanned. A QR code whose text happens to be eight
    /// characters of the alphabet once became a code, was kept as the pending invite and was peeked
    /// at the server.
    func testABareCodeOrAWordOnAQRCodeIsNotTaken() {
        for payload in ["H7K3-9QWX", "H7K39QWX", "h7k3 9qwx\r\n", "H7KO-9QWL", "PASSWORD", "WELCOME1", "SHIPMENT", "12345678",
                        "A B C D E F G H", "password"] {
            XCTAssertNil(DuoCodeEntryModel.scan(payload), payload.debugDescription)
        }
        // The same text typed is still a code: the person typed what they meant to.
        XCTAssertEqual(code("PASSWORD")?.code, "PASSW0RD")
        XCTAssertEqual(code("H7K3-9QWX")?.code, "H7K39QWX")
    }

    func testAQRCodeOfAnythingElseIsIgnored() {
        let ignored = [
            "https://example.com/menu", "https://example.com/duo#H7K39QWX", "https://hydrodrop.us/tap#ABC123",
            "https://hydrodrop.us/duo?c=H7K39QWX", "http://hydrodrop.us/duo#H7K39QWX", "Hello, world", "WIFI:S:Home;T:WPA;P:pass;;",
            "mailto:support@hydrodrop.us", "tel:+15555550100", "", "H7K39QW", "H7K39QWXY",
            "\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}\u{1F4A7}", "BEGIN:VCARD\nFN:Sam\nEND:VCARD",
            String(repeating: "A", count: 4_000),
        ]
        for payload in ignored {
            XCTAssertNil(DuoCodeEntryModel.scan(payload), payload.prefix(40).debugDescription)
        }
    }

    /// A link reads the same pasted or scanned, so a person who pastes the link they were sent and
    /// one who scans its QR code are told the same thing; a bare code is read only when typed.
    func testALinkReadsTheSameTypedPastedOrScanned() {
        let links = [
            "https://hydrodrop.us/duo#H7K39QWX", "https://hydrodrop.us/duo#H7K39QWX.\(secret)", "https://hydrodrop.us/duo#h7k3-9qwx",
            "https://example.com/duo#H7K39QWX", "https://hydrodrop.us/duo?c=H7K39QWX", "https://hydrodrop.us/duo#H7K39QW",
        ]
        for link in links {
            XCTAssertEqual(code(link), DuoCodeEntryModel.scan(link), link)
        }
        for bare in ["h7k3-9qwx", "H7K3 9QWX", "H7KO-9QWL"] {
            XCTAssertNotNil(code(bare), bare)
            XCTAssertNil(DuoCodeEntryModel.scan(bare), bare)
        }
        for nothing in ["H7K39QW", "H7K39QWXY", "", "\u{1F4A7}", "Hello"] {
            XCTAssertNil(code(nothing), nothing)
            XCTAssertNil(DuoCodeEntryModel.scan(nothing), nothing)
        }
    }

    /// KV1, the shared vectors' invite-code cases: what they state for `parse(pasted:)` is what
    /// Continue and the scanner answer, so this stage cannot drift from the server and Android.
    func testContinueAndTheScannerAgreeWithEveryKV1Case() throws {
        let cases = Vectors.foundationCases().filter { $0.id.hasPrefix("KV1.") }
        XCTAssertGreaterThanOrEqual(cases.count, 16)
        for vector in cases {
            guard case .object(let input) = vector.input, case .string(let text)? = input["text"] else {
                return XCTFail("\(vector.id) has no text")
            }
            let spec = try XCTUnwrap(vector.spec, vector.id)
            func render(_ parsed: DuoParsedInvite?) -> String {
                guard let parsed else { return JSON.null.rendered }
                return JSON.object(["code": .string(parsed.code), "k": parsed.k.map { JSON.string($0) } ?? .null]).rendered
            }
            XCTAssertEqual(render(code(text)), spec.rendered, "Continue: \(vector.id)")
            // The scanner takes the links of KV1 exactly as it states them, and no bare code.
            let isLink = text.lowercased().hasPrefix("https://")
            XCTAssertEqual(render(DuoCodeEntryModel.scan(text)), isLink ? spec.rendered : JSON.null.rendered, "scan: \(vector.id)")
        }
    }

    // MARK: - Reconnect's code

    func testAReconnectCodeMayBeSentOnlyWhenItNormalises() {
        for good in ["H7K39QWX", "h7k3-9qwx", "h7k3 9qwx", "  H7K3-9QWX ", "h7ko-9qwl", "H7K3-9QWX\n", "\tH7K3-9QWX", "\nh7k3 9qwx \r\n"] {
            XCTAssertTrue(DuoCodeEntryModel.canReconnect(code: good), good.debugDescription)
        }
        for bad in ["", "H7K39QW", "H7K39QWXY", "H7K39QWU", "https://hydrodrop.us/duo#H7K39QWX", "\u{1F4A7}", "H7K3\n9QWX", " \n "] {
            XCTAssertFalse(DuoCodeEntryModel.canReconnect(code: bad), bad.debugDescription)
        }
    }

    /// Continue and Reconnect trim the same way: a code that one sheet takes, the other takes too.
    func testBothFieldsTrimTheSameWay() {
        for text in ["H7K3-9QWX\n", "\tH7K3-9QWX", " h7k3 9qwx \r\n", "H7K3\n9QWX", "H7K39QW\n"] {
            XCTAssertEqual(DuoCodeEntryModel.canReconnect(code: text), code(text) != nil, text.debugDescription)
        }
        XCTAssertEqual(DuoCodeEntryModel.trimmed(" \t h7k3 9qwx \r\n"), "h7k3 9qwx")
    }

    func testBlankIsEmptyOrOnlySpaceAndLineBreaks() {
        XCTAssertTrue(DuoCodeEntryModel.isBlank(""))
        XCTAssertTrue(DuoCodeEntryModel.isBlank("  \n\t"))
        XCTAssertFalse(DuoCodeEntryModel.isBlank("x"))
        XCTAssertFalse(DuoCodeEntryModel.isBlank(" -"))
    }

    // MARK: - What the sheets say about the phone

    private let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
    private var every: [DuoAvailability] { [.unknown, .available, .maintenance, .upgradeRequired, .disconnected, .banned, restore] }

    func testTheCodeEntrySheetSaysWhyWhenWritesAreOff() {
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: .unknown), .none)
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: .available), .none)
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: .maintenance), .none, "a join can still be tried; its sheet says the service is away")
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: .upgradeRequired), .line("Update HydroDrop to keep using Duo Streaks."))
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: .disconnected), .line("This phone was disconnected from the duo"))
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: .banned),
                       .line("Duo Streaks are not available for this device. Contact support@hydrodrop.us."))
        XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: restore), .restoreQuestion)
    }

    func testTheReconnectSheetSaysWhyWhenAReconnectIsRuledOut() {
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: .unknown), .none)
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: .available), .none)
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: .maintenance), .none)
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: .disconnected), .none, "the phone this sheet is for")
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: .upgradeRequired), .line("Update HydroDrop to keep using Duo Streaks."))
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: .banned),
                       .line("Duo Streaks are not available for this device. Contact support@hydrodrop.us."))
        XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: restore), .restoreQuestion)
    }

    /// A notice is said exactly when the sheet's own action is off, so a disabled button always
    /// comes with its reason and a working one never carries a stale line.
    func testANoticeIsSaidExactlyWhenTheSheetsActionIsOff() {
        for availability in every {
            XCTAssertEqual(DuoCodeEntryModel.entryNotice(for: availability) != .none, !availability.allowsWrites, "\(availability)")
            XCTAssertEqual(DuoCodeEntryModel.reconnectNotice(for: availability) != .none, !availability.allowsReconnect, "\(availability)")
        }
    }

    // MARK: - The code-entry sheet's Continue

    func testACodeIsTakenOnlyWhileWritesAreOnAndTheyWereNotRefused() {
        for availability in every {
            for age in [DuoAgeStatus.unknown, .allowed, .refused] {
                let expected = age != .refused && availability.allowsWrites
                XCTAssertEqual(DuoCodeEntryModel.mayTakeACode(ageStatus: age, availability: availability), expected, "\(age) \(availability)")
                XCTAssertEqual(DuoCodeEntryModel.canContinue(text: "h7k3-9qwx", ageStatus: age, availability: availability), expected)
                let action = DuoCodeEntryModel.entryAction(text: "h7k3-9qwx", ageStatus: age, availability: availability)
                XCTAssertEqual(action, expected ? .receive(DuoParsedInvite(code: "H7K39QWX")) : .nothing, "\(age) \(availability)")
            }
        }
    }

    func testContinueReceivesAGoodCodeSaysNotACodeForABadOneAndNothingForAnEmptyField() {
        let ok: (String) -> DuoCodeEntryModel.EntryAction = {
            DuoCodeEntryModel.entryAction(text: $0, ageStatus: .unknown, availability: .available)
        }
        XCTAssertEqual(ok("h7k3-9qwx"), .receive(DuoParsedInvite(code: "H7K39QWX")),
                       "an unknown age still stores the code: the join sheet's gate asks the birth year before anything is sent")
        XCTAssertEqual(ok("https://hydrodrop.us/duo#H7K39QWX.\(secret)"), .receive(DuoParsedInvite(code: "H7K39QWX", k: secret)))
        XCTAssertEqual(ok("H7K39QW"), .notACode)
        XCTAssertEqual(ok("https://example.com/duo#H7K39QWX"), .notACode)
        XCTAssertEqual(ok(""), .nothing)
        XCTAssertEqual(ok("  \n"), .nothing)
        XCTAssertFalse(DuoCodeEntryModel.canContinue(text: "", ageStatus: .allowed, availability: .available))
        XCTAssertFalse(DuoCodeEntryModel.canContinue(text: " ", ageStatus: .allowed, availability: .available))
        XCTAssertTrue(DuoCodeEntryModel.canContinue(text: "x", ageStatus: .allowed, availability: .available),
                      "a bad code is not blocked by the button: Continue says why")
    }

    // MARK: - The reconnect sheet's button

    func testReconnectSendsTheCodeAsTypedOnlyOnceTheAgeIsAllowed() {
        XCTAssertEqual(DuoCodeEntryModel.reconnectRequest(code: "h7k3 9qwx", ageStatus: .allowed, availability: .available, isWorking: false),
                       "h7k3 9qwx", "as typed: the service normalises it")
        XCTAssertEqual(DuoCodeEntryModel.reconnectRequest(code: " h7k3 9qwx\r\n", ageStatus: .allowed, availability: .available, isWorking: false),
                       "h7k3 9qwx", "without the line break a paste brought, which the service would refuse")
        XCTAssertNil(DuoCodeEntryModel.reconnectRequest(code: "h7k3 9qwx", ageStatus: .allowed, availability: .available, isWorking: false,
                                                        hasLanded: true), "a reconnect that landed is not sent again")
        XCTAssertNil(DuoCodeEntryModel.reconnectRequest(code: "h7k3 9qwx", ageStatus: .unknown, availability: .available, isWorking: false),
                     "the birth-year screen comes first")
        XCTAssertNil(DuoCodeEntryModel.reconnectRequest(code: "h7k3 9qwx", ageStatus: .refused, availability: .available, isWorking: false))
    }

    func testReconnectIsAllowedForAvailableAndDisconnectedAndRuledOutForTheRest() {
        let expected: [(DuoAvailability, Bool)] = [
            (.unknown, true), (.available, true), (.maintenance, true), (.disconnected, true),
            (.upgradeRequired, false), (.banned, false), (restore, false),
        ]
        for (availability, sends) in expected {
            let request = DuoCodeEntryModel.reconnectRequest(code: "H7K39QWX", ageStatus: .allowed, availability: availability, isWorking: false)
            XCTAssertEqual(request != nil, sends, "\(availability)")
        }
    }

    func testReconnectSendsNothingWhileWorkingOrForSomethingThatIsNotACode() {
        XCTAssertNil(DuoCodeEntryModel.reconnectRequest(code: "H7K39QWX", ageStatus: .allowed, availability: .available, isWorking: true))
        for bad in ["", "H7K39QW", "H7K39QWU", "https://hydrodrop.us/duo#H7K39QWX"] {
            XCTAssertNil(DuoCodeEntryModel.reconnectRequest(code: bad, ageStatus: .allowed, availability: .disconnected, isWorking: false), bad)
        }
    }

    // MARK: - The camera

    func testEveryCameraStatusMapsToItsState() {
        XCTAssertEqual(DuoCameraAccess.from(rawStatus: 0, hasCamera: true), .ask, "not determined")
        XCTAssertEqual(DuoCameraAccess.from(rawStatus: 1, hasCamera: true), .restricted, "restricted")
        XCTAssertEqual(DuoCameraAccess.from(rawStatus: 2, hasCamera: true), .denied, "denied")
        XCTAssertEqual(DuoCameraAccess.from(rawStatus: 3, hasCamera: true), .allowed, "authorized")
        for unknown in [-1, 4, 5, 99, Int.max, Int.min] {
            XCTAssertEqual(DuoCameraAccess.from(rawStatus: unknown, hasCamera: true), .denied, "a status this build cannot read is no yes: \(unknown)")
        }
    }

    func testWithoutACameraNothingIsOfferedWhateverTheStatus() {
        for raw in [-1, 0, 1, 2, 3, 4] {
            XCTAssertEqual(DuoCameraAccess.from(rawStatus: raw, hasCamera: false), .unavailable, "\(raw)")
        }
    }

    func testTheAnswerToTheOneRequest() {
        XCTAssertEqual(DuoCameraAccess.afterRequest(granted: true), .allowed)
        XCTAssertEqual(DuoCameraAccess.afterRequest(granted: false), .denied)
    }

    /// A restricted camera has its own line and no Settings button; a denied one is told where to
    /// turn it on; the rest say nothing.
    func testEachCameraStateLeavesItsOwnLine() {
        XCTAssertEqual(DuoCameraAccess.denied.line, .off)
        XCTAssertEqual(DuoCameraAccess.restricted.line, .restricted)
        XCTAssertEqual(DuoCameraAccess.ask.line, .none)
        XCTAssertEqual(DuoCameraAccess.allowed.line, .none)
        XCTAssertEqual(DuoCameraAccess.unavailable.line, .none)
    }

    // MARK: - What the code-entry sheet draws

    private func entry(_ text: String = "", age: DuoAgeStatus = .allowed, in availability: DuoAvailability = .available,
                       camera: Bool = true, scanner: Bool = false, asking: Bool = false,
                       line: DuoCodeEntryModel.CameraLine = .none, notACode: Bool = false) -> DuoCodeEntryModel.EntryLayout {
        DuoCodeEntryModel.entryLayout(text: text, ageStatus: age, availability: availability, hasCamera: camera, wantsScanner: scanner,
                                      isAskingForTheCamera: asking, cameraLine: line, showsNotACode: notACode)
    }

    func testTheFormForATypingPerson() {
        let empty = entry()
        XCTAssertFalse(empty.showsRefusal)
        XCTAssertFalse(empty.showsScanner)
        XCTAssertEqual(empty.notice, .none)
        XCTAssertTrue(empty.fieldIsEnabled)
        XCTAssertFalse(empty.continueIsEnabled, "nothing typed")
        XCTAssertTrue(entry("h").continueIsEnabled)
        XCTAssertTrue(empty.showsScanButton)
        XCTAssertTrue(empty.scanButtonIsEnabled)
        XCTAssertEqual(empty.cancel, .closeSheet)
        XCTAssertFalse(entry(camera: false).showsScanButton, "no camera, no Scan")
        XCTAssertFalse(entry(asking: true).scanButtonIsEnabled, "the question is up")
        XCTAssertTrue(entry(notACode: true).showsNotACode)
    }

    func testARefusedPersonIsShownTheRefusalAndNothingElse() {
        let refused = entry("H7K39QWX", age: .refused, scanner: true, line: .off, notACode: true)
        XCTAssertTrue(refused.showsRefusal)
        XCTAssertFalse(refused.showsScanner)
        XCTAssertFalse(refused.showsScanButton)
        XCTAssertFalse(refused.fieldIsEnabled)
        XCTAssertFalse(refused.continueIsEnabled)
        XCTAssertFalse(refused.showsNotACode)
        XCTAssertEqual(refused.cameraLine, .none)
        XCTAssertFalse(refused.showsOpenSettings)
        XCTAssertFalse(entry(age: .unknown).showsRefusal, "an unknown age types a code; the join sheet asks it")
    }

    func testWhileScanningCancelPutsTheCameraAwayAndTheFormIsHidden() {
        let scanning = entry(scanner: true, notACode: true)
        XCTAssertTrue(scanning.showsScanner)
        XCTAssertEqual(scanning.cancel, .backToTyping)
        XCTAssertFalse(scanning.showsScanButton)
        XCTAssertFalse(scanning.showsNotACode)
        XCTAssertFalse(entry(camera: false, scanner: true).showsScanner, "no camera, no scanner")
    }

    func testAPhoneThatMayNotJoinGetsTheFormAndItsReasonEvenMidScan() {
        for availability in [DuoAvailability.disconnected, restore, .upgradeRequired, .banned] {
            let layout = entry("H7K39QWX", in: availability, scanner: true, line: .off)
            XCTAssertFalse(layout.showsScanner, "\(availability)")
            XCTAssertEqual(layout.cancel, .closeSheet, "\(availability)")
            XCTAssertNotEqual(layout.notice, .none, "\(availability)")
            XCTAssertFalse(layout.fieldIsEnabled, "\(availability)")
            XCTAssertFalse(layout.continueIsEnabled, "\(availability)")
            XCTAssertFalse(layout.showsScanButton, "\(availability)")
            XCTAssertEqual(layout.cameraLine, .none, "\(availability)")
        }
        XCTAssertEqual(entry(in: .disconnected).notice, .line("This phone was disconnected from the duo"))
    }

    func testTheCameraLineAndOpenSettings() {
        XCTAssertEqual(entry(line: .off).cameraLine, .off)
        XCTAssertTrue(entry(line: .off).showsOpenSettings)
        XCTAssertEqual(entry(line: .restricted).cameraLine, .restricted)
        XCTAssertFalse(entry(line: .restricted).showsOpenSettings, "Settings cannot lift a restriction")
        XCTAssertEqual(entry(line: .unavailableNow).cameraLine, .unavailableNow)
        XCTAssertFalse(entry(line: .unavailableNow).showsOpenSettings)
        XCTAssertFalse(entry(line: .none).showsOpenSettings)
    }

    /// Every combination, held to the rules that tie the controls together.
    func testEveryEntryLayoutKeepsItsRules() {
        let lines: [DuoCodeEntryModel.CameraLine] = [.none, .off, .restricted, .unavailableNow]
        for availability in every {
            for age in [DuoAgeStatus.unknown, .allowed, .refused] {
                for text in ["", " ", "nope", "H7K39QWX"] {
                    for camera in [false, true] {
                        for scanner in [false, true] {
                            for asking in [false, true] {
                                for line in lines {
                                    for notACode in [false, true] {
                                        let l = entry(text, age: age, in: availability, camera: camera, scanner: scanner, asking: asking,
                                                      line: line, notACode: notACode)
                                        let may = age != .refused && availability.allowsWrites
                                        let why = "\(availability) \(age) \(text.debugDescription) \(camera) \(scanner) \(asking) \(line) \(notACode)"
                                        XCTAssertEqual(l.showsRefusal, age == .refused, why)
                                        XCTAssertEqual(l.fieldIsEnabled, may, why)
                                        XCTAssertEqual(l.continueIsEnabled, may && !DuoCodeEntryModel.isBlank(text), why)
                                        XCTAssertEqual(l.showsScanner, may && camera && scanner, why)
                                        XCTAssertEqual(l.cancel == .backToTyping, l.showsScanner, why)
                                        XCTAssertEqual(l.showsScanButton, may && camera && !l.showsScanner, why)
                                        XCTAssertEqual(l.scanButtonIsEnabled, l.showsScanButton && !asking, why)
                                        XCTAssertEqual(l.cameraLine, l.showsScanButton ? line : .none, why)
                                        XCTAssertEqual(l.showsOpenSettings, l.cameraLine == .off, why)
                                        XCTAssertEqual(l.showsNotACode, notACode && !l.showsRefusal && !l.showsScanner, why)
                                        XCTAssertEqual(l.notice, age == .refused ? .none : DuoCodeEntryModel.entryNotice(for: availability), why)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - What the reconnect sheet draws

    private func reconnect(_ code: String = "H7K39QWX", prefilled: Bool = false, age: DuoAgeStatus = .allowed,
                           in availability: DuoAvailability = .available, working: Bool = false, landed: Bool = false,
                           error: String? = nil) -> DuoCodeEntryModel.ReconnectLayout {
        DuoCodeEntryModel.reconnectLayout(code: code, isPrefilled: prefilled, ageStatus: age, availability: availability,
                                          isWorking: working, hasLanded: landed, sheetError: error)
    }

    func testTheReconnectSheetsControls() {
        XCTAssertTrue(reconnect().buttonIsEnabled)
        XCTAssertTrue(reconnect().fieldIsEditable)
        XCTAssertTrue(reconnect().mayBeSwipedAway)
        XCTAssertFalse(reconnect().showsProgress)
        XCTAssertFalse(reconnect(prefilled: true).fieldIsEditable, "a code that came with the sheet is only confirmed")
        XCTAssertTrue(reconnect(prefilled: true).buttonIsEnabled)
        let working = reconnect(working: true)
        XCTAssertFalse(working.buttonIsEnabled)
        XCTAssertFalse(working.fieldIsEditable)
        XCTAssertTrue(working.showsProgress)
        XCTAssertFalse(working.mayBeSwipedAway, "an answer must not arrive for a sheet nobody sees")
        XCTAssertFalse(reconnect(landed: true).buttonIsEnabled, "landed: no second reconnect")
        XCTAssertFalse(reconnect("H7K39QW").buttonIsEnabled)
        XCTAssertFalse(reconnect(age: .unknown).buttonIsEnabled)
        XCTAssertEqual(reconnect(error: "Finish or leave the duo you started on this phone first.").error,
                       "Finish or leave the duo you started on this phone first.", "the service's words, as they are")
        XCTAssertNil(reconnect().error)
    }

    func testTheReconnectSheetNeverSaysThePhoneWasDisconnected() {
        XCTAssertEqual(reconnect(in: .disconnected).notice, .none)
        XCTAssertTrue(reconnect(in: .disconnected).buttonIsEnabled)
        XCTAssertEqual(reconnect(in: .upgradeRequired).notice, .line("Update HydroDrop to keep using Duo Streaks."))
        XCTAssertFalse(reconnect(in: .upgradeRequired).buttonIsEnabled)
        XCTAssertEqual(reconnect(in: restore).notice, .restoreQuestion)
        for availability in every {
            XCTAssertNotEqual(reconnect(in: availability).notice, .line("This phone was disconnected from the duo"), "\(availability)")
            XCTAssertEqual(reconnect(in: availability).notice, DuoCodeEntryModel.reconnectNotice(for: availability))
        }
    }
}
