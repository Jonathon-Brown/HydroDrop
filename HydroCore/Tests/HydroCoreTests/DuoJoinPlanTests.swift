import XCTest
@testable import HydroCore

/// The join sheet's plan for every answer a peek can give, the words it draws, and the root's rules
/// for when it may come up, when the notice alert may, and how a tapped Duo notification reaches the
/// Duo screen (stage K).
final class DuoJoinPlanTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_790_172_800)
    private let fsi = "\u{2068}"
    private let pdi = "\u{2069}"

    private func peek(_ purpose: DuoPeek.Purpose, name: String? = "Alex", skin: String? = "forest", target: String? = nil,
                      expires: Date? = Date(timeIntervalSince1970: 1_790_172_800)) -> DuoPeek {
        DuoPeek(purpose: purpose, inviterName: name, inviterSkin: skin, targetName: target, expiresAt: expires)
    }

    // MARK: - The plan per purpose

    func testAnInviteIsTheFormWithTheInviterAsTheServerSentThem() {
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.invite)),
                       .invite(inviterName: "Alex", inviterSkin: "forest", expiresAt: expiry, isSample: false))
    }

    func testADemoCodeIsTheFormMarkedAsTheSamplePartner() {
        // As built (Stage 18), peek answers a demo code with no name, no droplet and no expiry.
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.demo, name: nil, skin: nil, expires: nil)),
                       .invite(inviterName: nil, inviterSkin: nil, expiresAt: nil, isSample: true))
        // Only the purpose decides the sample flag: an ordinary invite with no name is not a sample.
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.invite, name: nil, skin: nil, expires: nil)),
                       .invite(inviterName: nil, inviterSkin: nil, expiresAt: nil, isSample: false))
    }

    func testAReconnectCodeIsTheReconnectSheetForItsTarget() {
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.reconnect, name: "Alex", target: "Sam")), .reconnect(targetName: "Sam"))
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.reconnect, target: nil)), .reconnect(targetName: nil))
    }

    func testALinkDeviceOrUnknownCodeIsUnsupported() {
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.linkDevice)), .unsupported)
        XCTAssertEqual(DuoJoinPlan.make(peek: peek(.unknown)), .unsupported)
    }

    func testEveryPurposeHasAPlan() {
        // A purpose added to `DuoPeek.Purpose` must be placed here deliberately.
        let all: [DuoPeek.Purpose] = [.invite, .reconnect, .linkDevice, .demo, .unknown]
        let plans = all.map { DuoJoinPlan.make(peek: peek($0)) }
        XCTAssertEqual(plans.filter { if case .invite = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(plans.filter { if case .reconnect = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(plans.filter { $0 == .unsupported }.count, 2)
    }

    // MARK: - Names untouched, but isolated

    func testNamesPassThroughExactlyAsTheServerSentThem() {
        let hostile = [
            "**Alex**", "[Sam](https://evil.example)", "%@ %d", "Zoë", "  padded  ", "a\u{202E}evil", "Ålex\u{200D}",
            "<script>alert(1)</script>", "ALEX", "alex", String(repeating: "x", count: 60), "",
        ]
        for name in hostile {
            XCTAssertEqual(DuoJoinPlan.make(peek: peek(.invite, name: name, skin: name)),
                           .invite(inviterName: name, inviterSkin: name, expiresAt: expiry, isSample: false), name)
            XCTAssertEqual(DuoJoinPlan.make(peek: peek(.reconnect, target: name)), .reconnect(targetName: name), name)
            if !name.isEmpty {
                // The banner holds the name byte for byte between the two isolates: not trimmed,
                // re-cased or cut.
                XCTAssertEqual(DuoJoinPlan.banner(inviterName: name), "\(fsi)\(name)\(pdi) invited you to keep a streak together.", name)
            }
        }
    }

    func testARightToLeftNameCannotReorderTheSentence() {
        let name = "مريم عبد الرحمن"
        let banner = DuoJoinPlan.banner(inviterName: name)
        XCTAssertEqual(banner, DuoCopy.inviteBanner(inviter: "\u{2068}\(name)\u{2069}"))
        XCTAssertTrue(banner.hasPrefix("\u{2068}"))
        XCTAssertTrue(banner.hasSuffix("\u{2069} invited you to keep a streak together."))
        XCTAssertEqual(DuoJoinPlan.isolated("x"), "\u{2068}x\u{2069}")
    }

    func testTheBannerIsTheApprovedSentenceAndYourPartnerWhenThereIsNoName() {
        XCTAssertEqual(DuoJoinPlan.banner(inviterName: "Alex"), DuoCopy.inviteBanner(inviter: "\(fsi)Alex\(pdi)"))
        XCTAssertEqual(DuoJoinPlan.banner(inviterName: nil), "Your partner invited you to keep a streak together.")
        XCTAssertEqual(DuoJoinPlan.banner(inviterName: ""), "Your partner invited you to keep a streak together.")
        // A name of spaces is the server's to clean, not this sheet's: it is drawn as sent.
        XCTAssertEqual(DuoJoinPlan.banner(inviterName: " "), "\(fsi) \(pdi) invited you to keep a streak together.")
    }

    func testTheWordsAreTheApprovedOnesOrTheListedPlaceholders() {
        // D82: the approved fallback, where "Someone" was not.
        XCTAssertEqual(DuoJoinPlan.unnamedInviter, "Your partner")
        // Stage G's placeholder for the restore card, awaiting approval with it.
        XCTAssertEqual(DuoJoinPlan.unnamedSelf, "you")
        // New copy awaiting approval.
        XCTAssertEqual(DuoJoinPlan.unsupportedLine, "This code can't be used in this version of HydroDrop.")
        XCTAssertEqual(DuoJoinPlan.tryAgain, "Try again")
    }

    // MARK: - The restore question

    func testTheRestoreQuestionIsTheApprovedSentenceWithIsolatedNames() {
        XCTAssertEqual(DuoJoinPlan.restoreQuestion(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")),
                       DuoCopy.restorePrompt(partner: "\(fsi)Sam\(pdi)", name: "\(fsi)Jo\(pdi)"))
        XCTAssertEqual(DuoJoinPlan.restoreQuestion(DuoRestorePrompt(partnerName: nil, myName: nil)),
                       "This phone was connected to a duo with Your partner. Continue as you?")
        XCTAssertEqual(DuoJoinPlan.restoreQuestion(DuoRestorePrompt(partnerName: "", myName: "")),
                       "This phone was connected to a duo with Your partner. Continue as you?")
    }

    func testTheRestorePromptIsReadOnlyFromTheRestoreQuestion() {
        let prompt = DuoRestorePrompt(partnerName: "Sam", myName: "Jo")
        XCTAssertEqual(DuoJoinPlan.restorePrompt(in: .needsRestoreChoice(prompt)), prompt)
        for availability in [DuoAvailability.unknown, .available, .maintenance, .upgradeRequired, .disconnected, .banned] {
            XCTAssertNil(DuoJoinPlan.restorePrompt(in: availability), "\(availability)")
        }
    }

    // MARK: - A peek with no answer

    func testAFailureSaysWhatTheServiceWroteFirst() {
        let expired = "That invite is no longer open. Ask for a new one."
        XCTAssertEqual(DuoJoinPlan.failureText(sheetError: expired, availability: .available), expired)
        // Even on a phone whose banner has something to say: the service's words are about this code.
        XCTAssertEqual(DuoJoinPlan.failureText(sheetError: expired, availability: .maintenance), expired)
    }

    func testAFailureTheServiceDidNotSayShowsTheBanner() {
        // The service returns nothing and says nothing for a disconnected phone (amendments, H row).
        XCTAssertEqual(DuoJoinPlan.failureText(sheetError: nil, availability: .disconnected), "This phone was disconnected from the duo")
        XCTAssertEqual(DuoJoinPlan.failureText(sheetError: "", availability: .banned),
                       "Duo Streaks are not available for this device. Contact support@hydrodrop.us.")
        XCTAssertEqual(DuoJoinPlan.failureText(sheetError: nil, availability: .upgradeRequired), "Update HydroDrop to keep using Duo Streaks.")
    }

    func testAFailureDuringTheRestoreQuestionAsksIt() {
        let prompt = DuoRestorePrompt(partnerName: "Sam", myName: "Jo")
        XCTAssertEqual(DuoJoinPlan.failureText(sheetError: nil, availability: .needsRestoreChoice(prompt)), DuoJoinPlan.restoreQuestion(prompt))
        XCTAssertNotEqual(DuoJoinPlan.failureText(sheetError: nil, availability: .needsRestoreChoice(prompt)), DuoUserMessage.generic)
    }

    func testAFailureWithNothingToSayIsNeverBlank() {
        for availability in [DuoAvailability.unknown, .available] {
            XCTAssertEqual(DuoJoinPlan.failureText(sheetError: nil, availability: availability), DuoUserMessage.generic)
        }
    }

    func testOnlyAFailureThatMayPassOffersTryAgain() {
        let context = DuoErrorContext(httpStatus: 0, requestID: "0123456789abcdef")
        let passing: [Error] = [DuoTransportError.offline, DuoTransportError.rateLimited(context), DuoTransportError.maintenance(context),
                                DuoTransportError.attestInvalid(context), DuoTransportError.unreadable(httpStatus: 503, requestID: nil)]
        for error in passing {
            let text = DuoUserMessage.text(for: error, context: .invite)
            XCTAssertTrue(DuoJoinPlan.failureMayPass(text), text)
        }
        XCTAssertTrue(DuoJoinPlan.failureMayPass(DuoUserMessage.generic))
        XCTAssertTrue(DuoJoinPlan.failureMayPass("\(DuoUserMessage.generic) (ref 0123456789abcdef)"))
        let settled: [Error] = [DuoTransportError.inviteUnknown(context), DuoTransportError.inviteTaken(context), DuoTransportError.inviteOwn(context),
                                DuoTransportError.blocked(context), DuoTransportError.wrongPurpose(context), DuoTransportError.memberNotFresh(context),
                                DuoTransportError.upgradeRequired(context), DuoTransportError.banned(context), DuoTransportError.deviceRevoked(context)]
        for error in settled {
            let text = DuoUserMessage.text(for: error, context: .invite)
            XCTAssertFalse(DuoJoinPlan.failureMayPass(text), text)
        }
        XCTAssertFalse(DuoJoinPlan.failureMayPass(DuoJoinPlan.restoreQuestion(DuoRestorePrompt(partnerName: nil, myName: nil))))
        XCTAssertFalse(DuoJoinPlan.failureMayPass("This phone was disconnected from the duo"))
    }

    func testOnlyADisconnectedPhoneIsOfferedTheReconnectSheetFromAFailure() {
        let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil))
        XCTAssertTrue(DuoJoinPlan.offersReconnect(availability: .disconnected))
        for availability in [DuoAvailability.unknown, .available, .maintenance, .upgradeRequired, .banned, restore] {
            XCTAssertFalse(DuoJoinPlan.offersReconnect(availability: availability), "\(availability)")
        }
    }

    // MARK: - The form

    func testThePeekWaitsForTheBirthYearScreen() {
        XCTAssertTrue(DuoJoinPlan.mayPeek(ageStatus: .allowed))
        XCTAssertFalse(DuoJoinPlan.mayPeek(ageStatus: .unknown))
        XCTAssertFalse(DuoJoinPlan.mayPeek(ageStatus: .refused))
    }

    func testJoinIsOfferedOnlyWhileWritesAreAllowedAndNothingIsUnderWay() {
        let prompt = DuoRestorePrompt(partnerName: "Sam", myName: nil)
        let restore = DuoAvailability.needsRestoreChoice(prompt)
        for availability in [DuoAvailability.unknown, .available, .maintenance] {
            XCTAssertTrue(DuoJoinPlan.joinIsEnabled(isWorking: false, availability: availability), "\(availability)")
            XCTAssertFalse(DuoJoinPlan.joinIsEnabled(isWorking: true, availability: availability), "\(availability)")
            XCTAssertNil(DuoJoinPlan.joinBlockedLine(availability: availability))
        }
        for availability in [DuoAvailability.upgradeRequired, .disconnected, .banned, restore] {
            XCTAssertFalse(DuoJoinPlan.joinIsEnabled(isWorking: false, availability: availability), "\(availability)")
            XCTAssertNotNil(DuoJoinPlan.joinBlockedLine(availability: availability), "\(availability)")
        }
        XCTAssertEqual(DuoJoinPlan.joinBlockedLine(availability: .disconnected), "This phone was disconnected from the duo")
        XCTAssertEqual(DuoJoinPlan.joinBlockedLine(availability: .upgradeRequired), DuoAvailability.upgradeRequired.bannerMessage)
        // The restore question has no banner of its own: the question is the line.
        XCTAssertEqual(DuoJoinPlan.joinBlockedLine(availability: restore), DuoJoinPlan.restoreQuestion(prompt))
    }

    func testTheNameFieldStopsAtTheLongestNameThatCanBeSent() {
        XCTAssertEqual(DuoState.maximumNameLength, 24)
        XCTAssertEqual(DuoJoinPlan.cappedName("Ana"), "Ana")
        XCTAssertEqual(DuoJoinPlan.cappedName(String(repeating: "a", count: 24)), String(repeating: "a", count: 24))
        XCTAssertEqual(DuoJoinPlan.cappedName(String(repeating: "a", count: 25)), String(repeating: "a", count: 24))
        // Counted in what a person sees as characters, so a flag or an accented letter is one.
        let flags = String(repeating: "🇳🇴", count: 30)
        XCTAssertEqual(DuoJoinPlan.cappedName(flags), String(repeating: "🇳🇴", count: 24))
        // Nothing else is changed: spaces and case stay as typed (the service cleans at the tap).
        XCTAssertEqual(DuoJoinPlan.cappedName("  aNA "), "  aNA ")
    }

    func testTheNameFieldStartsFromTheTypedNameElseTheServersName() {
        XCTAssertEqual(DuoJoinPlan.prefilledName(typed: "Ana", serverName: "Server"), "Ana")
        // After a reinstall and Continue the typed name is gone; the server's keeps the field from
        // sending none and clearing the name for every partner.
        XCTAssertEqual(DuoJoinPlan.prefilledName(typed: "", serverName: "Server"), "Server")
        XCTAssertEqual(DuoJoinPlan.prefilledName(typed: "", serverName: nil), "")
        XCTAssertEqual(DuoJoinPlan.prefilledName(typed: "", serverName: String(repeating: "s", count: 30)), String(repeating: "s", count: 24))
    }

    // MARK: - The hold

    func testShouldHoldTruthTable() {
        for onboarding in [false, true] {
            for settings in [false, true] {
                for entry in [false, true] {
                    let held = DuoJoinPlan.shouldHold(onboardingDone: onboarding, settingsIsOnScreen: settings, entrySheetIsOnScreen: entry)
                    XCTAssertEqual(held, !onboarding || settings || entry, "onboarding \(onboarding), settings \(settings), entry \(entry)")
                }
            }
        }
    }

    func testTheEntrySheetHoldsTheInviteExactlyAsSettingsDoes() {
        for onboarding in [false, true] {
            XCTAssertEqual(DuoJoinPlan.shouldHold(onboardingDone: onboarding, settingsIsOnScreen: true, entrySheetIsOnScreen: false),
                           DuoJoinPlan.shouldHold(onboardingDone: onboarding, settingsIsOnScreen: false, entrySheetIsOnScreen: true))
        }
        XCTAssertTrue(DuoJoinPlan.shouldHold(onboardingDone: true, settingsIsOnScreen: false, entrySheetIsOnScreen: true))
        XCTAssertFalse(DuoJoinPlan.shouldHold(onboardingDone: true, settingsIsOnScreen: false, entrySheetIsOnScreen: false))
    }

    /// One moment of the root: whether the intro is done, Settings and the code-entry sheet are on
    /// screen, the recap is up and the notice alert is up or leaving.
    private struct Moment {
        var onboarding = true
        var settings = false
        var entry = false
        var recap = false
        var notice = false
    }

    private let invite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date(timeIntervalSince1970: 1_790_000_000))

    private func shown(_ moment: Moment, pending: DuoPendingInvite?, refusedLink: DuoPendingInvite? = nil, onScreen: DuoPendingInvite? = nil,
                       refused: Bool = false) -> DuoPendingInvite? {
        DuoJoinPlan.invite(toShow: pending, refusedLink: refusedLink, onScreen: onScreen, ageRefused: refused, onboardingDone: moment.onboarding,
                           settingsIsOnScreen: moment.settings, entrySheetIsOnScreen: moment.entry, anotherSheetIsOnScreen: moment.recap,
                           noticeIsUp: moment.notice)
    }

    /// Walks the moments an invite lives through and says at which one the join sheet comes up.
    private func firstShown(_ moments: [Moment], refused: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Int? {
        let shownAt = moments.indices.filter {
            shown(moments[$0], pending: refused ? nil : invite, refusedLink: refused ? invite : nil, refused: refused) != nil
        }
        guard let first = shownAt.first else { return nil }
        // Once everything has left it stays shown: no later moment of the walk holds it again.
        XCTAssertEqual(shownAt, Array(first..<moments.count), file: file, line: line)
        return first
    }

    func testACodeTypedInsideSettingsComesUpOnceEntryAndSettingsHaveBothLeft() {
        // Settings is up and the entry sheet over it; the code is stored as the entry sheet closes;
        // the Duo screen closes Settings from the entry sheet's onDismiss; Settings slides away.
        let moments = [
            Moment(settings: true, entry: true),
            Moment(settings: true, entry: false),
            Moment(settings: false, entry: false),
        ]
        XCTAssertEqual(firstShown(moments), 2)
    }

    func testACodeScannedOverTodayComesUpOnceTheEntrySheetHasLeft() {
        let moments = [Moment(entry: true), Moment(entry: false)]
        XCTAssertEqual(firstShown(moments), 1)
    }

    func testALinkTappedWithSettingsOpenComesUpOnceSettingsHasLeft() {
        // `takeDuoLink` lowers `showingSettings`; `settingsIsOnScreen` stays true until onDismiss.
        let moments = [Moment(settings: true), Moment(settings: true), Moment(settings: false)]
        XCTAssertEqual(firstShown(moments), 2)
    }

    func testALinkThatOpenedTheAppComesUpOnlyAfterTheIntro() {
        let moments = [Moment(onboarding: false), Moment(onboarding: true)]
        XCTAssertEqual(firstShown(moments), 1)
    }

    func testAnInviteWaitsOutTheWeeklyRecap() {
        let moments = [Moment(recap: true), Moment(recap: false)]
        XCTAssertEqual(firstShown(moments), 1)
    }

    func testAnInviteWaitsOutTheNoticeAlertUntilItHasLeft() {
        let moments = [Moment(notice: true), Moment(notice: true), Moment(notice: false)]
        XCTAssertEqual(firstShown(moments), 2)
    }

    func testNoInviteNoSheet() {
        XCTAssertNil(shown(Moment(), pending: nil))
    }

    func testASheetThatIsUpStaysUpForItsOwnInvite() {
        // Nothing can hold a sheet that is already up: taking it down is what drops the invite.
        let busy = Moment(onboarding: false, settings: true, entry: true, recap: true, notice: true)
        XCTAssertEqual(shown(busy, pending: invite, onScreen: invite), invite)
        // The same code opened again (a newer `receivedAt`) is still the sheet's own.
        let again = DuoPendingInvite(code: invite.code, k: "ABCDEFGHJKMNPQRSTVWXYZ0123", receivedAt: invite.receivedAt.addingTimeInterval(60))
        XCTAssertEqual(shown(busy, pending: again, onScreen: invite), again)
    }

    func testAJoinThatClearedTheInviteTakesTheSheetDown() {
        XCTAssertNil(shown(Moment(), pending: nil, onScreen: invite))
    }

    func testARefusalOnTheSheetsOwnAgeScreenKeepsItUpUntilClosed() {
        // The refusal drops the pending invite; the sheet stays so the refusal is read.
        XCTAssertEqual(shown(Moment(), pending: nil, onScreen: invite, refused: true), invite)
        // Closing it clears `onScreen` and the refused link, and nothing comes back.
        XCTAssertNil(shown(Moment(), pending: nil, onScreen: nil, refused: true))
        // A pending invite is never shown to a refused person (and `receive` keeps none).
        XCTAssertNil(shown(Moment(), pending: invite, onScreen: nil, refused: true))
    }

    func testARefusedPersonsLinkShowsTheRefusalAfterTheSameHolds() {
        XCTAssertEqual(shown(Moment(), pending: nil, refusedLink: invite, refused: true), invite)
        let moments = [Moment(settings: true), Moment(settings: false, notice: true), Moment(notice: false)]
        XCTAssertEqual(firstShown(moments, refused: true), 2)
        // The refused link means nothing to someone who is not refused.
        XCTAssertNil(shown(Moment(), pending: nil, refusedLink: invite, refused: false))
    }

    // MARK: - The root's presentations

    private func sheets(onboarding: Bool = true, settingsRequested: Bool = false, settingsOnScreen: Bool = false, recapRequested: Bool = false,
                        recapOnScreen: Bool = false, join: Bool = false, entry: Bool = false, notice: Bool = false) -> DuoJoinPlan.RootSheets {
        DuoJoinPlan.RootSheets(onboardingDone: onboarding, settingsRequested: settingsRequested, settingsIsOnScreen: settingsOnScreen,
                               recapRequested: recapRequested, recapIsOnScreen: recapOnScreen, joinSheetIsUp: join, entrySheetIsOnScreen: entry,
                               noticeIsUp: notice)
    }

    func testNothingInTheWayOpensSettings() {
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets()), .openSettings)
    }

    func testSettingsAlreadyUpOrComingUpTakesOnlyTheFlag() {
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(settingsRequested: true, settingsOnScreen: true)), .settingsIsUp)
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(settingsRequested: true, settingsOnScreen: false)), .settingsIsUp)
    }

    func testSettingsOnItsWayOutIsWaitedOut() {
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(settingsRequested: false, settingsOnScreen: true)), .waitForSheet)
    }

    func testTheRecapIsClosedAloneThenWaitedOutThenSettingsOpens() {
        // Up: close it (and only it).
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(recapRequested: true, recapOnScreen: true)), .closeRecap)
        // Lowered and still sliding away: never open Settings in the same turn.
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(recapRequested: false, recapOnScreen: true)), .waitForSheet)
        // Its onDismiss has run.
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets()), .openSettings)
        // Asked for but held behind Settings leaving: lowered, then Settings is waited out.
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(settingsOnScreen: true, recapRequested: true)), .closeRecap)
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(settingsOnScreen: true)), .waitForSheet)
    }

    func testTheJoinSheetTheEntrySheetAndTheNoticeAreWaitedOutNotClosed() {
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(join: true)), .waitForSheet)
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(entry: true)), .waitForSheet)
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(notice: true)), .waitForSheet)
    }

    func testTheIntroIsWaitedOutFirst() {
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(onboarding: false)), .waitForIntro)
        XCTAssertEqual(DuoJoinPlan.duoScreenStep(sheets(onboarding: false, settingsRequested: true, recapRequested: true, join: true)), .waitForIntro)
    }

    private func everyCombination(_ check: (DuoJoinPlan.RootSheets, Int) -> Void) {
        for bits in 0..<(1 << 8) {
            check(sheets(onboarding: bits & 1 != 0, settingsRequested: bits & 2 != 0, settingsOnScreen: bits & 4 != 0,
                         recapRequested: bits & 8 != 0, recapOnScreen: bits & 16 != 0, join: bits & 32 != 0, entry: bits & 64 != 0,
                         notice: bits & 128 != 0), bits)
        }
    }

    private func nothingElse(_ s: DuoJoinPlan.RootSheets) -> Bool {
        !s.settingsRequested && !s.settingsIsOnScreen && !s.recapRequested && !s.recapIsOnScreen && !s.joinSheetIsUp
            && !s.entrySheetIsOnScreen && !s.noticeIsUp
    }

    func testEverySheetCombinationEndsInOneSingleMove() {
        // Settings is opened only when nothing at all is asked for, up or leaving, the notice alert
        // included, and the recap is closed only when it was asked for and Settings was not.
        everyCombination { s, bits in
            let step = DuoJoinPlan.duoScreenStep(s)
            if step == .openSettings { XCTAssertTrue(s.onboardingDone && nothingElse(s), "\(bits)") }
            if step == .closeRecap { XCTAssertTrue(s.recapRequested && !s.settingsRequested, "\(bits)") }
        }
    }

    func testTheNoticeAlertComesUpOnlyWithNothingElseAskedForUpOrLeaving() {
        everyCombination { s, bits in
            XCTAssertEqual(DuoJoinPlan.noticeMayShow(hasNotice: true, s), s.onboardingDone && nothingElse(s), "\(bits)")
            XCTAssertFalse(DuoJoinPlan.noticeMayShow(hasNotice: false, s), "\(bits)")
        }
        // The two the review's wedge came from, each on its own.
        XCTAssertFalse(DuoJoinPlan.noticeMayShow(hasNotice: true, sheets(settingsRequested: true)))
        XCTAssertFalse(DuoJoinPlan.noticeMayShow(hasNotice: true, sheets(recapRequested: true)))
        XCTAssertFalse(DuoJoinPlan.noticeMayShow(hasNotice: true, sheets(join: true)))
        XCTAssertTrue(DuoJoinPlan.noticeMayShow(hasNotice: true, sheets()))
    }

    func testTheRecapWaitsForTheJoinSheetAndTheNotice() {
        XCTAssertTrue(DuoJoinPlan.recapMayShow(joinSheetIsUp: false, noticeIsUp: false))
        XCTAssertFalse(DuoJoinPlan.recapMayShow(joinSheetIsUp: true, noticeIsUp: false))
        XCTAssertFalse(DuoJoinPlan.recapMayShow(joinSheetIsUp: false, noticeIsUp: true))
        XCTAssertFalse(DuoJoinPlan.recapMayShow(joinSheetIsUp: true, noticeIsUp: true))
    }

    func testAWaitingTapGoesStale() {
        let asked = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(DuoJoinPlan.duoScreenRouteIsStale(askedAt: asked, now: asked))
        XCTAssertFalse(DuoJoinPlan.duoScreenRouteIsStale(askedAt: asked, now: asked.addingTimeInterval(DuoJoinPlan.duoScreenRouteLifetime)))
        XCTAssertTrue(DuoJoinPlan.duoScreenRouteIsStale(askedAt: asked, now: asked.addingTimeInterval(DuoJoinPlan.duoScreenRouteLifetime + 1)))
        XCTAssertTrue(DuoJoinPlan.duoScreenRouteIsStale(askedAt: asked, now: asked.addingTimeInterval(-60)), "a clock that went back")
        XCTAssertTrue(DuoJoinPlan.duoScreenRouteIsStale(askedAt: nil, now: asked))
        XCTAssertEqual(DuoJoinPlan.duoScreenRouteLifetime, 600)
    }
}
