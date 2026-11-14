import XCTest
@testable import HydroCore

/// The push upload's rules (final design §3.1, §6.2, §9.6, D36): what is sent, and when.
final class DuoPushUploadPlanTests: XCTestCase {
    private typealias Plan = DuoPushUploadPlan

    private func request(token: String = "7c3d", environment: DuoAPNsEnvironment = .production, zone: String = "America/Toronto",
                         window: (Int, Int) = (480, 1320), enabled: Bool = true) -> DuoWireRegisterPushRequest {
        Plan.desired(tokenHex: token, environment: environment, zone: zone, window: (window.0, window.1), notificationsEnabled: enabled)
    }

    private func snapshot(hash: String = "hash-a", environment: DuoAPNsEnvironment = .production, zone: String = "America/Toronto",
                          window: (Int, Int) = (480, 1320), enabled: Bool = true) -> Plan.Snapshot {
        Plan.Snapshot(request(environment: environment, zone: zone, window: window, enabled: enabled), tokenHash: hash)
    }

    // MARK: - What is sent

    func testTheTokenIsSentAsTheLowercaseHexOfItsBytes() {
        XCTAssertEqual(Plan.tokenHex(Data([0x7C, 0x3D, 0x00, 0xFF, 0x0A])), "7c3d00ff0a")
        XCTAssertEqual(Plan.tokenHex(Data()), "")
    }

    func testWithTheToggleOnTheZoneAndTheWindowAreSent() throws {
        let sent = request(token: "7c3d", environment: .sandbox, zone: "Europe/London", window: (420, 1380), enabled: true)
        XCTAssertEqual(sent.platform, "apns")
        XCTAssertEqual(sent.tokenKind, "apns")
        XCTAssertEqual(sent.token, "7c3d")
        XCTAssertEqual(sent.apnsEnv, "sandbox")
        XCTAssertEqual(sent.tz, "Europe/London")
        XCTAssertEqual(sent.wakeStartMin, 420)
        XCTAssertEqual(sent.wakeEndMin, 1380)
        XCTAssertTrue(sent.notificationsEnabled)
        // The wire form: every key the contract names, snake_case, and nothing else.
        let json = try XCTUnwrap(String(data: DuoWireCoding.encode(sent), encoding: .utf8))
        XCTAssertEqual(json, #"{"apns_env":"sandbox","notifications_enabled":true,"platform":"apns","token":"7c3d","token_kind":"apns","tz":"Europe/London","wake_end_min":1380,"wake_start_min":420}"#)
    }

    /// D36: with the toggle off the zone still goes, so the one notice the server still sends,
    /// `ended`, is held to 08:00 to 22:00 there; the window never does.
    func testWithTheToggleOffTheZoneIsStillSentAndTheWindowIsNot() throws {
        let sent = request(zone: "Asia/Tokyo", window: (480, 1320), enabled: false)
        XCTAssertEqual(sent.tz, "Asia/Tokyo")
        XCTAssertNil(sent.wakeStartMin)
        XCTAssertNil(sent.wakeEndMin)
        XCTAssertFalse(sent.notificationsEnabled)
        let json = try XCTUnwrap(String(data: DuoWireCoding.encode(sent), encoding: .utf8))
        XCTAssertFalse(json.contains("wake_"), "no minutes in the body with the toggle off: \(json)")
        XCTAssertTrue(json.contains(#""tz":"Asia/Tokyo""#))
    }

    /// The server answers a minute outside 0 to 1439 with `422 schema`, which would lose the whole
    /// upload, so the ends are kept inside it.
    func testTheWindowsEndsAreKeptToMinutesTheServerAccepts() {
        let sent = request(window: (-5, 1440), enabled: true)
        XCTAssertEqual(sent.wakeStartMin, 0)
        XCTAssertEqual(sent.wakeEndMin, 1439)
        let wrapped = request(window: (1320, 360), enabled: true)
        XCTAssertEqual(wrapped.wakeStartMin, 1320, "a window past midnight is sent as it is")
        XCTAssertEqual(wrapped.wakeEndMin, 360)
    }

    func testASnapshotSaysWhatTheRequestSaid() {
        let shot = Plan.Snapshot(request(environment: .sandbox, zone: "UTC", window: (60, 120), enabled: true), tokenHash: "h")
        XCTAssertEqual(shot, Plan.Snapshot(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: 60, windowEnd: 120, enabled: true))
        let off = Plan.Snapshot(request(enabled: false), tokenHash: "h")
        XCTAssertNil(off.windowStart)
        XCTAssertNil(off.windowEnd)
        XCTAssertFalse(off.enabled)
    }

    // MARK: - When it is sent

    func testALaunchAndANewTokenAlwaysUpload() {
        let same = snapshot()
        for reason in [Plan.Trigger.launch, .tokenChanged] {
            XCTAssertEqual(Plan.decide(previous: same, desired: same, reason: reason), Plan.Decision(upload: true, firstUpload: false), "\(reason)")
        }
    }

    func testAWindowToggleZoneOrNewDuoUploadsOnlyWhenSomethingDiffers() {
        let held = snapshot()
        let changes: [(String, Plan.Snapshot)] = [
            ("window start", snapshot(window: (420, 1320))),
            ("window end", snapshot(window: (480, 1260))),
            ("toggle", snapshot(enabled: false)),
            ("zone", snapshot(zone: "Europe/Paris")),
            ("environment", snapshot(environment: .sandbox)),
            ("token", snapshot(hash: "hash-b")),
        ]
        for reason in [Plan.Trigger.windowChanged, .toggleChanged, .zoneChanged, .duoStarted] {
            XCTAssertFalse(Plan.decide(previous: held, desired: held, reason: reason).upload, "\(reason) with nothing changed")
            for (what, changed) in changes {
                XCTAssertTrue(Plan.decide(previous: held, desired: changed, reason: reason).upload, "\(reason) with the \(what) changed")
            }
            XCTAssertTrue(Plan.decide(previous: nil, desired: held, reason: reason).upload, "\(reason) with nothing on the server")
        }
    }

    /// CON R11: a background run re-uploads only when the zone moved.
    func testABackgroundRunUploadsOnlyWhenTheZoneDiffers() {
        let held = snapshot()
        XCTAssertFalse(Plan.decide(previous: held, desired: held, reason: .background).upload)
        XCTAssertFalse(Plan.decide(previous: held, desired: snapshot(window: (420, 1320)), reason: .background).upload,
                       "a window change is the window trigger's, not a background run's")
        XCTAssertFalse(Plan.decide(previous: held, desired: snapshot(enabled: false), reason: .background).upload)
        XCTAssertTrue(Plan.decide(previous: held, desired: snapshot(zone: "Asia/Kolkata"), reason: .background).upload)
        XCTAssertTrue(Plan.decide(previous: nil, desired: held, reason: .background).upload, "nothing on the server is no zone there")
    }

    func testOnlyAnUploadOfATokenTheServerHasNotTakenFromThisDeviceIsTheFirst() {
        let held = snapshot(hash: "hash-a")
        XCTAssertTrue(Plan.decide(previous: nil, desired: held, reason: .launch).firstUpload)
        XCTAssertTrue(Plan.decide(previous: held, desired: snapshot(hash: "hash-b"), reason: .tokenChanged).firstUpload)
        XCTAssertFalse(Plan.decide(previous: held, desired: snapshot(hash: "hash-a", zone: "UTC"), reason: .zoneChanged).firstUpload)
        XCTAssertFalse(Plan.decide(previous: held, desired: snapshot(hash: "hash-a", environment: .sandbox), reason: .launch).firstUpload,
                       "an environment change alone is a change, not a new token")
    }

    // MARK: - With something waiting in the queue

    func testAnUploadAlreadyWaitingIsNotQueuedASecondTime() {
        let held = snapshot()
        let desired = snapshot(window: (420, 1320))
        for reason in Plan.Trigger.allCases {
            XCTAssertFalse(Plan.decide(previous: held, desired: desired, reason: reason, queued: .upload(desired, firstUpload: false)).upload,
                           "\(reason): the queue already ends with this very upload")
        }
    }

    /// A waiting upload that was not attested does not stand in for one that must be.
    func testAWaitingUploadThatIsNotAttestedDoesNotStandInForAFirstOne() {
        let desired = snapshot(hash: "hash-new")
        let decision = Plan.decide(previous: snapshot(hash: "hash-old"), desired: desired, reason: .tokenChanged,
                                   queued: .upload(desired, firstUpload: false))
        XCTAssertEqual(decision, Plan.Decision(upload: true, firstUpload: true))
        XCTAssertFalse(Plan.decide(previous: snapshot(hash: "hash-old"), desired: desired, reason: .tokenChanged,
                                   queued: .upload(desired, firstUpload: true)).upload)
    }

    /// A window moved while offline and moved back: the server will hold what the queue says, not
    /// what it last answered, so the move back is sent.
    func testWhatIsComparedIsWhatTheServerWillHoldOnceTheQueueHasGone() {
        let held = snapshot()
        let moved = snapshot(window: (540, 1320))
        XCTAssertTrue(Plan.decide(previous: held, desired: held, reason: .windowChanged, queued: .upload(moved, firstUpload: false)).upload)
        XCTAssertFalse(Plan.decide(previous: held, desired: moved, reason: .windowChanged, queued: .upload(moved, firstUpload: false)).upload)
        // A removal still waiting means the server will hold nothing.
        XCTAssertTrue(Plan.decide(previous: held, desired: held, reason: .duoStarted, queued: .removal).upload)
        XCTAssertTrue(Plan.decide(previous: held, desired: held, reason: .background, queued: .removal).upload)
    }

    /// A removal still waiting means the server will hold no row for the token once it has gone, so
    /// an upload queued behind it is the first again, whatever the record says (review F8).
    func testAnUploadQueuedBehindAWaitingRemovalIsAFirstUpload() {
        let held = snapshot()
        XCTAssertEqual(Plan.decide(previous: held, desired: held, reason: .duoStarted, queued: .removal),
                       Plan.Decision(upload: true, firstUpload: true))
        for reason in Plan.Trigger.allCases {
            let decision = Plan.decide(previous: held, desired: held, reason: reason, queued: .removal)
            XCTAssertTrue(decision.upload, "\(reason): the server will hold nothing, so there is something to send")
            XCTAssertTrue(decision.firstUpload, "\(reason): sent after the DELETE, unattested it would be refused")
        }
    }

    /// Every combination of a small domain against the rules written out a second time, apart from
    /// the code (the review's table, 5,376 rows): previous record, desired upload, what waits in the
    /// queue, and every trigger.
    func testEveryCombinationAgreesWithTheRulesWrittenOutAgain() {
        func shot(_ hash: String = "h1", env: DuoAPNsEnvironment = .production, zone: String = "Europe/London",
                  window: (Int, Int) = (480, 1320), enabled: Bool = true) -> Plan.Snapshot {
            Plan.Snapshot(tokenHash: hash, environment: env, zone: zone, windowStart: enabled ? window.0 : nil,
                          windowEnd: enabled ? window.1 : nil, enabled: enabled)
        }
        let variants: [(String, Plan.Snapshot)] = [
            ("base", shot()), ("zone", shot(zone: "Asia/Tokyo")), ("window", shot(window: (420, 1320))),
            ("off", shot(enabled: false)), ("env", shot(env: .sandbox)), ("token", shot("h2")), ("blank", shot("")),
        ]
        let previous: [(String, Plan.Snapshot?)] = [("nil", nil)] + variants.map { ($0.0, Optional($0.1)) }
        var queued: [(String, Plan.Queued?)] = [("none", nil), ("removal", .removal)]
        for (name, snapshot) in variants {
            queued.append(("upload(\(name), first)", .upload(snapshot, firstUpload: true)))
            queued.append(("upload(\(name), re)", .upload(snapshot, firstUpload: false)))
        }
        var rows = 0
        var wrong: [String] = []
        for (previousName, before) in previous {
            for (desiredName, desired) in variants where !desired.tokenHash.isEmpty {
                for (queuedName, waiting) in queued {
                    for reason in Plan.Trigger.allCases {
                        rows += 1
                        let first = before?.tokenHash != desired.tokenHash || waiting == .removal
                        var willHold = before
                        var alreadyWaiting = false
                        switch waiting {
                        case .upload(let snapshot, let waitingFirst):
                            willHold = snapshot
                            alreadyWaiting = snapshot == desired && (waitingFirst || !first)
                        case .removal:
                            willHold = nil
                        case nil:
                            break
                        }
                        var upload: Bool
                        switch reason {
                        case .launch, .tokenChanged: upload = true
                        case .windowChanged, .toggleChanged, .zoneChanged, .duoStarted: upload = willHold != desired
                        case .background: upload = willHold?.zone != desired.zone
                        }
                        if alreadyWaiting { upload = false }
                        let got = Plan.decide(previous: before, desired: desired, reason: reason, queued: waiting)
                        if got != Plan.Decision(upload: upload, firstUpload: first) {
                            wrong.append("previous \(previousName), desired \(desiredName), queued \(queuedName), \(reason): \(got)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows, 5_376)
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) rows disagree, first: \(wrong.prefix(3))")
    }

    func testTheFirstUploadIsJudgedAgainstWhatTheServerAnsweredNotWhatIsWaiting() {
        let desired = snapshot(hash: "hash-new", zone: "UTC")
        let waiting = snapshot(hash: "hash-new")
        let decision = Plan.decide(previous: nil, desired: desired, reason: .zoneChanged, queued: .upload(waiting, firstUpload: true))
        XCTAssertEqual(decision, Plan.Decision(upload: true, firstUpload: true),
                       "the waiting upload may yet be refused, and this one must then be attested itself")
    }
}
