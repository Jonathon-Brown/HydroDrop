import XCTest
@testable import HydroCore

/// Stage J's pure part: the countdown on a code and which state each code sheet is in.
final class DuoInviteCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let hour: TimeInterval = 3600

    private func hours(_ interval: TimeInterval) -> Int {
        DuoInviteCountdown.hoursLeft(expiresAt: now.addingTimeInterval(interval), now: now)
    }

    // MARK: - Hours left

    func testHoursAreRoundedUp() {
        XCTAssertEqual(hours(47 * hour + 59 * 60), 48, "47 h 59 min left says 48")
        XCTAssertEqual(hours(48 * hour), 48)
        XCTAssertEqual(hours(47 * hour), 47, "a whole number of hours is not rounded further")
        XCTAssertEqual(hours(hour + 1), 2)
        XCTAssertEqual(hours(hour), 1)
        XCTAssertEqual(hours(60), 1, "a minute left says 1, not 0")
        XCTAssertEqual(hours(0.001), 1, "anything left at all is at least an hour")
        XCTAssertEqual(hours(23.5 * hour), 24)
    }

    func testZeroAtAndAfterExpiry() {
        XCTAssertEqual(hours(0), 0, "at the very moment it expires")
        XCTAssertEqual(hours(-0.001), 0)
        XCTAssertEqual(hours(-1), 0)
        XCTAssertEqual(hours(-5 * hour), 0)
        XCTAssertEqual(hours(-1_000 * 24 * hour), 0, "never below zero")
    }

    func testNeverMoreThanACodeLastsAndNeverACrash() {
        XCTAssertEqual(DuoInviteCountdown.longestHours, 48)
        XCTAssertEqual(hours(48 * hour + 1), 48, "a phone clock behind the server's must not promise more than 48 h")
        XCTAssertEqual(hours(60 * hour), 48)
        XCTAssertEqual(DuoInviteCountdown.hoursLeft(expiresAt: .distantFuture, now: now), 48)
        XCTAssertEqual(DuoInviteCountdown.hoursLeft(expiresAt: Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude), now: now), 48)
        XCTAssertEqual(DuoInviteCountdown.hoursLeft(expiresAt: Date(timeIntervalSinceReferenceDate: .infinity), now: now), 48)
        XCTAssertEqual(DuoInviteCountdown.hoursLeft(expiresAt: Date(timeIntervalSinceReferenceDate: .nan), now: now), 0, "an unreadable date reads as expired")
        XCTAssertEqual(DuoInviteCountdown.hoursLeft(expiresAt: .distantPast, now: now), 0)
    }

    func testOpenAgreesWithTheInviteAndWithTheHoursLeft() {
        let offsets: [TimeInterval] = [-48 * hour, -hour, -1, -0.001, 0, 0.001, 1, 59, 60, hour, 47 * hour + 3599, 48 * hour, 49 * hour]
        for offset in offsets {
            let expiresAt = now.addingTimeInterval(offset)
            let invite = DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: expiresAt)
            let open = DuoInviteCountdown.isOpen(expiresAt: expiresAt, now: now)
            XCTAssertEqual(open, invite.isOpen(now: now), "offset \(offset)")
            XCTAssertEqual(open, DuoInviteCountdown.hoursLeft(expiresAt: expiresAt, now: now) > 0,
                           "an open code never says 0 h and a closed one never says more (offset \(offset))")
        }
        XCTAssertFalse(DuoInviteCountdown.isOpen(expiresAt: now, now: now), "a code is closed at its expiry, as DuoInvite says")
    }

    func testTheLineIsTheApprovedOne() {
        XCTAssertEqual(DuoInviteCountdown.label(expiresAt: now.addingTimeInterval(48 * hour), now: now), "expires in 48 h")
        XCTAssertEqual(DuoInviteCountdown.label(expiresAt: now.addingTimeInterval(90 * 60), now: now), DuoCopy.expiresIn(hours: 2))
    }

    // MARK: - The invite sheet

    private func duo(role: DuoRole = .owner, joined: Bool = false, ended: Bool = false, invite: DuoInvite? = nil,
                     serverExpiry: Date? = nil) -> DuoState {
        DuoState(id: UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!, myRole: role, createdAt: now.addingTimeInterval(-hour),
                 ownerDisplayName: "Jo", partnerDisplayName: joined ? "Sam" : "", ownerSkin: "classic", partnerSkin: "",
                 statuses: [], partnerHasJoined: joined, endedAt: ended ? now : nil, invite: invite,
                 openInviteExpiresAt: serverExpiry, endedBy: ended ? .owner : nil)
    }

    private func invite(expiringIn interval: TimeInterval) -> DuoInvite {
        DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: now.addingTimeInterval(interval))
    }

    func testAnOpenCodeIsShownWithItsOwnExpiry() {
        let open = invite(expiringIn: 40 * hour)
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: open.expiresAt), now: now), .code(open))
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open), now: now), .code(open), "no word from the server yet")
    }

    /// One open invite per person (§7.2): a server expiry more than a minute later than this phone's
    /// code is a newer code, which voided this one (D79). Within the minute it is the same code.
    func testALaterServerExpiryMeansThisPhonesCodeWasVoided() {
        let open = invite(expiringIn: 10 * hour)
        XCTAssertEqual(DuoInviteCountdown.sameCodeTolerance, 60)
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: now.addingTimeInterval(47 * hour)), now: now),
                       .noOpenCode, "a newer code exists, so the one on this phone is dead")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: open.expiresAt.addingTimeInterval(60.001)), now: now),
                       .noOpenCode, "just over the minute")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: open.expiresAt.addingTimeInterval(60)), now: now),
                       .code(open), "exactly the minute is still the same code, and its own expiry stands")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: open.expiresAt.addingTimeInterval(0.5)), now: now),
                       .code(open), "a rounding difference")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: Date(timeIntervalSinceReferenceDate: .nan)), now: now),
                       .code(open), "an unreadable server date changes nothing")
    }

    func testTheServersEarlierExpiryWins() {
        let open = invite(expiringIn: 40 * hour)
        var earlier = open
        earlier.expiresAt = now.addingTimeInterval(10 * hour)
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: earlier.expiresAt), now: now), .code(earlier))
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: open, serverExpiry: now.addingTimeInterval(-1)), now: now), .noOpenCode,
                       "the server says the open invite has expired")
    }

    func testNoUsableCodeOffersANewOne() {
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: nil), now: now), .noOpenCode, "never had one")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: invite(expiringIn: 0)), now: now), .noOpenCode, "expired this second")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: invite(expiringIn: -hour)), now: now), .noOpenCode)
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(invite: nil, serverExpiry: now.addingTimeInterval(30 * hour)), now: now), .noOpenCode,
                       "a reinstalled owner: the server still has an open invite, and this phone has no code to show for it")
    }

    func testTheSheetClosesOnceTheDuoIsNoLongerWaiting() {
        let open = invite(expiringIn: 40 * hour)
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: nil, now: now), .closed, "gone (a wipe)")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(joined: true, invite: open), now: now), .closed, "the partner joined")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(ended: true, invite: open), now: now), .closed, "it ended")
        XCTAssertEqual(DuoInviteCountdown.inviteSheet(for: duo(role: .partner, invite: open), now: now), .closed, "not mine to invite to")
        XCTAssertTrue(DuoInviteCountdown.inviteSheetCloses(for: nil))
        XCTAssertTrue(DuoInviteCountdown.inviteSheetCloses(for: duo(joined: true)))
        XCTAssertTrue(DuoInviteCountdown.inviteSheetCloses(for: duo(ended: true)))
        XCTAssertFalse(DuoInviteCountdown.inviteSheetCloses(for: duo(invite: nil)), "a waiting duo with no code stays, to offer a new one")
        XCTAssertFalse(DuoInviteCountdown.inviteSheetCloses(for: duo(invite: invite(expiringIn: -hour))))
    }

    func testAFailedNewCodeSaysWhatTheStoreSaidOrTheGeneralLineButNeverNothing() {
        XCTAssertNil(DuoInviteCountdown.inviteSheetError(sheetError: nil, availability: .available, tapCameBackEmpty: false), "nothing tapped, nothing said")
        XCTAssertEqual(DuoInviteCountdown.inviteSheetError(sheetError: "Too many tries. Wait a bit and try again.", availability: .available, tapCameBackEmpty: true),
                       "Too many tries. Wait a bit and try again.")
        XCTAssertEqual(DuoInviteCountdown.inviteSheetError(sheetError: "Too many tries. Wait a bit and try again.", availability: .available, tapCameBackEmpty: false),
                       "Too many tries. Wait a bit and try again.", "the store's line shows whoever asked")
        XCTAssertEqual(DuoInviteCountdown.inviteSheetError(sheetError: nil, availability: .available, tapCameBackEmpty: true), DuoUserMessage.generic,
                       "a tap the service refused without a word")
        XCTAssertEqual(DuoInviteCountdown.inviteSheetError(sheetError: "", availability: .maintenance, tapCameBackEmpty: true), DuoUserMessage.generic)
        XCTAssertNil(DuoInviteCountdown.inviteSheetError(sheetError: nil, availability: .disconnected, tapCameBackEmpty: true),
                     "writes are off: the banner line says why, and the general line would only repeat it worse")
    }

    // MARK: - Redrawing

    func testTheSheetsRedrawEveryMinuteAndAtTheMomentTheCodeExpires() {
        let start = now
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start, start: start, expiresAt: nil), start.addingTimeInterval(60))
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start.addingTimeInterval(59.9), start: start, expiresAt: nil), start.addingTimeInterval(60))
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start.addingTimeInterval(60), start: start, expiresAt: nil), start.addingTimeInterval(120),
                       "always strictly after the date asked about")
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start, start: start, expiresAt: start.addingTimeInterval(1.5)), start.addingTimeInterval(1.5),
                       "a code that runs out before the next minute leaves the screen when it does")
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start.addingTimeInterval(1.5), start: start, expiresAt: start.addingTimeInterval(1.5)),
                       start.addingTimeInterval(60), "and once past it the minutes go on")
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start, start: start, expiresAt: start.addingTimeInterval(3 * hour)), start.addingTimeInterval(60),
                       "a later expiry waits its turn")
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start, start: start, expiresAt: start.addingTimeInterval(-5)), start.addingTimeInterval(60),
                       "an expiry already past adds nothing")
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start, start: start, expiresAt: Date(timeIntervalSinceReferenceDate: .nan)), start.addingTimeInterval(60))
        XCTAssertEqual(DuoInviteCountdown.nextRedraw(after: start.addingTimeInterval(-10), start: start, expiresAt: nil), start)
    }

    func testACopiedCodeLeavesThePasteboardWithTheCodeOrSoonerForAReconnectCode() {
        XCTAssertEqual(DuoInviteCountdown.invitePasteboardLifetime, 48 * hour)
        XCTAssertEqual(DuoInviteCountdown.reconnectPasteboardLifetime, 10 * 60, "D79: a takeover code stays ten minutes at most")
        let soon = now.addingTimeInterval(5 * 60)
        XCTAssertEqual(DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: soon, now: now, longest: 10 * 60), soon, "the code goes first")
        XCTAssertEqual(DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: now.addingTimeInterval(40 * hour), now: now, longest: 10 * 60),
                       now.addingTimeInterval(10 * 60), "the ten minutes go first")
        XCTAssertEqual(DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: now.addingTimeInterval(40 * hour), now: now, longest: 48 * hour),
                       now.addingTimeInterval(40 * hour))
        XCTAssertEqual(DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: .distantFuture, now: now, longest: 48 * hour), now.addingTimeInterval(48 * hour),
                       "an absurd expiry never keeps a code there for good")
        XCTAssertEqual(DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: Date(timeIntervalSinceReferenceDate: .nan), now: now, longest: 10 * 60),
                       now.addingTimeInterval(10 * 60))
        XCTAssertEqual(DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: now.addingTimeInterval(-1), now: now, longest: 10 * 60), now.addingTimeInterval(-1),
                       "an expired code leaves at once")
    }

    // MARK: - The reconnect code sheet

    func testAHeldReconnectCodeIsShownAgainOnlyWhileNothingWasWipedTheCodeIsOpenAndTheDuoLive() {
        let live = duo(joined: true)
        let code = invite(expiringIn: 48 * hour)
        XCTAssertTrue(DuoInviteCountdown.heldReconnectCodeHolds(code, heldAtWipeEpoch: 2, wipeEpoch: 2, duo: live, now: now))
        XCTAssertFalse(DuoInviteCountdown.heldReconnectCodeHolds(code, heldAtWipeEpoch: 2, wipeEpoch: 3, duo: live, now: now), "a wipe since")
        XCTAssertFalse(DuoInviteCountdown.heldReconnectCodeHolds(invite(expiringIn: 0), heldAtWipeEpoch: 2, wipeEpoch: 2, duo: live, now: now), "expired")
        XCTAssertFalse(DuoInviteCountdown.heldReconnectCodeHolds(code, heldAtWipeEpoch: 2, wipeEpoch: 2, duo: duo(joined: true, ended: true), now: now), "ended")
        XCTAssertFalse(DuoInviteCountdown.heldReconnectCodeHolds(code, heldAtWipeEpoch: 2, wipeEpoch: 2, duo: nil, now: now), "gone")
    }

    private func reconnect(_ duo: DuoState?, _ answer: DuoInviteCountdown.ReconnectAnswer, error: String? = nil,
                           availability: DuoAvailability = .available) -> DuoInviteCountdown.ReconnectSheet {
        DuoInviteCountdown.reconnectSheet(for: duo, answer: answer, sheetError: error, availability: availability, now: now)
    }

    func testTheReconnectSheetWaitsThenShowsItsCode() {
        let live = duo(joined: true)
        let code = invite(expiringIn: 48 * hour)
        XCTAssertEqual(reconnect(live, .notYet), .waiting)
        XCTAssertEqual(reconnect(live, .code(code)), .code(code))
        XCTAssertEqual(reconnect(live, .code(invite(expiringIn: 0))), .noOpenCode, "expired while the sheet stayed open")
        XCTAssertEqual(reconnect(live, .code(invite(expiringIn: -hour))), .noOpenCode)
    }

    func testAReconnectFailureSaysWhatTheStoreSaidOrWhyWritesAreOffOrTheGeneralLine() {
        let live = duo(joined: true)
        XCTAssertEqual(reconnect(live, .noCode, error: "No connection right now. Try again in a bit."),
                       .failed("No connection right now. Try again in a bit."))
        XCTAssertEqual(reconnect(live, .noCode, error: "No connection right now. Try again in a bit.", availability: .disconnected),
                       .failed("No connection right now. Try again in a bit."), "what the service said comes first")
        XCTAssertEqual(reconnect(live, .noCode, availability: .disconnected), .failed("This phone was disconnected from the duo"))
        XCTAssertEqual(reconnect(live, .noCode, availability: .upgradeRequired), .failed("Update HydroDrop to keep using Duo Streaks."))
        XCTAssertEqual(reconnect(live, .noCode), .failed(DuoUserMessage.generic), "refused before anything was sent, with nothing said")
        XCTAssertEqual(reconnect(live, .noCode, error: ""), .failed(DuoUserMessage.generic), "never an empty line")
        XCTAssertEqual(reconnect(live, .noCode, availability: .maintenance), .failed(DuoUserMessage.generic),
                       "maintenance allows writes, so it is not why nothing came back")
        XCTAssertEqual(reconnect(live, .noCode, availability: .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil))),
                       .failed(DuoUserMessage.generic), "the restore question has no banner of its own")
    }

    func testTheReconnectSheetClosesWhenTheDuoEndsOrGoes() {
        let code = invite(expiringIn: 48 * hour)
        for answer: DuoInviteCountdown.ReconnectAnswer in [.notYet, .code(code), .noCode] {
            XCTAssertEqual(reconnect(nil, answer), .closed)
            XCTAssertEqual(reconnect(duo(joined: true, ended: true), answer, error: "x"), .closed)
        }
        XCTAssertTrue(DuoInviteCountdown.reconnectSheetCloses(for: nil))
        XCTAssertTrue(DuoInviteCountdown.reconnectSheetCloses(for: duo(joined: true, ended: true)))
        XCTAssertFalse(DuoInviteCountdown.reconnectSheetCloses(for: duo(joined: true)))
    }
}
