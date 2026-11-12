import XCTest
@testable import HydroCore

// Stage H's pure model of the Duo screen: which rows each state draws, the words each dialog
// says, the free limit, names inside sentences, and that nothing that ends, deletes or sends is
// reachable from a tap without its confirmation, nor from a confirmation whose row has gone.

private let hNow = Date(timeIntervalSince1970: 1_790_000_000)
private let hToday = DayKey.key(for: hNow)
private let fsi = "\u{2068}"
private let pdi = "\u{2069}"
private func iso(_ name: String) -> String { fsi + name + pdi }

private func hDuo(_ id: Int = 1, role: DuoRole = .owner, partner: String = "Sam", joined: Bool = true, ended: Bool = false,
                  endedBy: DuoEndedBy? = nil, endedDaysAgo: Double = 0.04, pendingOp: DuoPendingOp? = nil, nickname: String? = nil,
                  demo: Bool = false, joinedHoursAgo: Double = 96, partnerLastWriteDay: String? = nil, nudges: [DuoNudge]? = nil) -> DuoState {
    let uuid = UUID(uuidString: String(format: "6d2a0000-0000-4000-8000-%012d", id))!
    let owner = role == .owner ? "Jo" : partner
    let other = role == .owner ? partner : "Jo"
    return DuoState(id: uuid, myRole: role, createdAt: hNow.addingTimeInterval(-86_400 * 60), ownerDisplayName: owner,
                    partnerDisplayName: other, ownerSkin: "classic", partnerSkin: "forest", statuses: [], partnerHasJoined: joined,
                    endedAt: ended ? hNow.addingTimeInterval(-endedDaysAgo * 86_400) : nil, nudges: nudges,
                    joinedAt: joined ? hNow.addingTimeInterval(-joinedHoursAgo * 3600) : nil,
                    endedBy: ended ? (endedBy ?? .partner) : nil, partnerLastWriteDay: partnerLastWriteDay ?? (joined ? hToday : nil),
                    partnerIsDemo: demo, partnerNickname: nickname, pendingOp: pendingOp, syncedOnce: true)
}

private func hContext(_ duos: [DuoState], _ availability: DuoAvailability = .available, nudgesPerDay: Int = 3,
                      identity: Bool = true, throwaway: Bool = false, subscribed: Bool = false,
                      blocksSent: Set<UUID> = []) -> DuoScreenModel.Context {
    DuoScreenModel.Context(duos: duos, availability: availability, nudgesPerDay: nudgesPerDay, hasIdentity: identity,
                           credentialIsAThrowaway: throwaway, isSubscribed: subscribed, blocksSent: blocksSent,
                           now: hNow, myToday: hToday)
}

private func hRows(_ duo: DuoState, _ verdict: DuoNudgeRules.Verdict = .allowed(remaining: 3),
                   in context: DuoScreenModel.Context) -> DuoScreenModel.DuoRows {
    DuoScreenModel.rows(for: duo, verdict: verdict, in: context)
}

private let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))

final class DuoScreenModelTests: XCTestCase {
    // MARK: - States to rows

    /// Finding 1: with the age gate closed (a refusal, the recheck, an unreadable answer) nothing
    /// that sends is offered, and a stale tap or a dialog left open does nothing. Clear, Report and
    /// Delete stay: they send nothing to the partner, and Delete goes through the gate's exemption.
    func testAClosedAgeGateOffersNoNudgeInviteLeaveOrBlock() {
        let live = hDuo(1)
        let pending = hDuo(2, joined: false)
        let ended = hDuo(3, ended: true)
        var context = hContext([live, pending, ended])
        context.sharingPaused = true
        let rows = hRows(live, in: context)
        XCTAssertNil(rows.nudge)
        XCTAssertNil(rows.lastNudge)
        XCTAssertFalse(rows.showsLeave)
        XCTAssertNil(rows.block)
        XCTAssertTrue(rows.showsReport)
        XCTAssertFalse(hRows(pending, in: context).showsInvite)
        XCTAssertNil(hRows(ended, in: context).block)
        XCTAssertTrue(hRows(ended, in: context).showsClear)
        XCTAssertTrue(DuoScreenModel.showsDelete(in: context))
        XCTAssertEqual(DuoScreenModel.tap(.leave, on: live, verdict: .allowed(remaining: 3), in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.block, on: live, verdict: .allowed(remaining: 3), in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.nudge, on: live, verdict: .allowed(remaining: 3), in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.confirm(.block(live.id), in: context), .nothing, "a dialog opened before the refusal does nothing")
        XCTAssertEqual(DuoScreenModel.confirm(.sendNudge(.waterBreak, live.id), verdict: .allowed(remaining: 3), in: context), .nothing)
    }

    func testALiveJoinedDuoOffersNudgeNicknameLeaveBlockAndReportAndNothingElse() {
        let duo = hDuo()
        let rows = hRows(duo, .allowed(remaining: 2), in: hContext([duo]))
        XCTAssertEqual(rows.nudge, .send(remaining: 2, enabled: true))
        XCTAssertEqual(DuoScreenModel.nudgesLeft(2), "2 left today")
        XCTAssertEqual(rows.nickname, .init(placeholder: "Sam", current: ""))
        XCTAssertTrue(rows.showsLeave)
        XCTAssertEqual(rows.block, "Block \(iso("Sam"))")
        XCTAssertTrue(rows.showsReport)
        XCTAssertFalse(rows.showsClear, "a live duo is never cleared")
        XCTAssertFalse(rows.showsInvite)
        XCTAssertFalse(rows.showsStartFresh)
    }

    func testAPendingDuoOffersTheInviteAndLeaveButNoBlockReportNicknameOrNudge() {
        let duo = hDuo(partner: "", joined: false)
        let rows = hRows(duo, .nobodyToNudge, in: hContext([duo]))
        XCTAssertTrue(rows.showsInvite)
        XCTAssertEqual(DuoScreenModel.sendInviteAgain, "Send the invite again")
        XCTAssertTrue(rows.showsLeave)
        XCTAssertNil(rows.block, "nobody has joined: there is nobody to block")
        XCTAssertFalse(rows.showsReport)
        XCTAssertNil(rows.nickname)
        XCTAssertNil(rows.nudge)
        XCTAssertNil(rows.lastNudge)
    }

    func testAnEndedDuoOffersClearAndBlockButNoLeaveNudgeOrInvite() {
        let duo = hDuo(partner: "Alex", ended: true)
        let rows = hRows(duo, .nobodyToNudge, in: hContext([duo]))
        XCTAssertTrue(rows.showsClear)
        XCTAssertEqual(rows.block, "Block \(iso("Alex"))", "a block works on an ended card within its 30 days (§11.8)")
        XCTAssertFalse(rows.showsLeave)
        XCTAssertNil(rows.nudge)
        XCTAssertTrue(rows.showsReport)
        XCTAssertEqual(rows.nickname?.placeholder, "Alex")
        // P07: an ended duo nobody ever joined has no invite to send again.
        let endedUnjoined = hDuo(2, partner: "", joined: false, ended: true, endedBy: .inactive)
        XCTAssertFalse(hRows(endedUnjoined, .nobodyToNudge, in: hContext([endedUnjoined])).showsInvite)
        XCTAssertEqual(DuoScreenModel.tap(.invite, on: endedUnjoined, in: hContext([endedUnjoined])), .nothing)
    }

    func testTheLastNudgeIsShownOnlyOnALiveJoinedDuo() {
        let nudge = DuoNudge(id: "nudge-A", fromRole: .partner, presetID: DuoNudgePreset.sipWithMe.rawValue, createdAt: hNow.addingTimeInterval(-600))
        let live = hDuo(1, nudges: [nudge])
        XCTAssertEqual(hRows(live, in: hContext([live])).lastNudge?.line, "\(iso("Sam")): Sip with me?")
        // P73: an ended duo keeps no "last nudge" line.
        let ended = hDuo(2, ended: true, nudges: [nudge])
        XCTAssertNil(hRows(ended, .nobodyToNudge, in: hContext([ended])).lastNudge)
    }

    func testTheNudgeLimitLineSaysThreeOnlyWhenTheLimitIsThree() {
        let duo = hDuo()
        XCTAssertEqual(hRows(duo, .limitReached, in: hContext([duo], nudgesPerDay: 3)).nudge, .allSent("That is all three nudges for today."))
        XCTAssertEqual(hRows(duo, .limitReached, in: hContext([duo], nudgesPerDay: 1)).nudge, .allSent("That is all your nudges for today."))
        XCTAssertEqual(hRows(duo, .limitReached, in: hContext([duo], nudgesPerDay: 2)).nudge, .allSent("That is all your nudges for today."))
    }

    func testAPartnerWhoMetTheirGoalIsNamedAsShownAndANobodyVerdictDrawsNoRow() {
        let duo = hDuo(nickname: "Bestie")
        XCTAssertEqual(hRows(duo, .partnerAlreadyMet, in: hContext([duo])).nudge,
                       .partnerMet("\(iso("Bestie")) already met their goal. Nothing to nudge."))
        XCTAssertNil(hRows(duo, .nobodyToNudge, in: hContext([duo])).nudge)
        let unnamed = hDuo(2, partner: "")
        XCTAssertEqual(hRows(unnamed, .partnerAlreadyMet, in: hContext([unnamed])).nudge,
                       .partnerMet("Your partner already met their goal. Nothing to nudge."), "the fallback starts the sentence")
    }

    func testSendingIsDrawnButOffWhileTheAppMayNotWrite() {
        let duo = hDuo()
        for availability in [DuoAvailability.upgradeRequired, .disconnected, restore] {
            XCTAssertEqual(hRows(duo, .allowed(remaining: 3), in: hContext([duo], availability)).nudge, .send(remaining: 3, enabled: false),
                           "\(availability)")
        }
        XCTAssertEqual(hRows(duo, .allowed(remaining: 3), in: hContext([duo], .maintenance)).nudge, .send(remaining: 3, enabled: true),
                       "maintenance still lets the engine queue and retry")
    }

    func testTheLastNudgeShownIsThePartnersLatestAndNeverMyOwn() {
        let older = DuoNudge(id: "nudge-A", fromRole: .partner, presetID: DuoNudgePreset.waterBreak.rawValue, createdAt: hNow.addingTimeInterval(-7200))
        let newer = DuoNudge(id: "nudge-B", fromRole: .partner, presetID: DuoNudgePreset.sipWithMe.rawValue, createdAt: hNow.addingTimeInterval(-600))
        let mine = DuoNudge(id: "nudge-C", fromRole: .owner, presetID: DuoNudgePreset.cheers.rawValue, createdAt: hNow.addingTimeInterval(-60))
        let duo = hDuo(nudges: [older, mine, newer])
        XCTAssertEqual(hRows(duo, in: hContext([duo])).lastNudge, .init(line: "\(iso("Sam")): Sip with me?", at: newer.createdAt))
        XCTAssertNil(hRows(hDuo(nudges: [mine]), in: hContext([hDuo(nudges: [mine])])).lastNudge)
        let unknown = hDuo(nudges: [DuoNudge(id: "nudge-D", fromRole: .partner, presetID: "fromTheFuture", createdAt: hNow)])
        XCTAssertEqual(hRows(unknown, in: hContext([unknown])).lastNudge?.line, "\(iso("Sam")): Time for some water?")
    }

    func testThePartnerRoleSeesTheOwnersNameEverywhere() {
        let duo = hDuo(role: .partner, partner: "Riley")
        let rows = hRows(duo, .partnerAlreadyMet, in: hContext([duo]))
        XCTAssertEqual(rows.nickname?.placeholder, "Riley")
        XCTAssertEqual(rows.block, "Block \(iso("Riley"))")
        XCTAssertEqual(rows.nudge, .partnerMet("\(iso("Riley")) already met their goal. Nothing to nudge."))
    }

    func testNoNicknameRowWithoutANameFromTheServerAndTheCurrentNicknameIsShown() {
        let unnamed = hDuo(partner: "")
        let rows = hRows(unnamed, in: hContext([unnamed]))
        XCTAssertNil(rows.nickname, "the field's placeholder is the server's name")
        XCTAssertEqual(rows.block, "Block your partner", "the fallback is lowercase inside a phrase")
        let named = hDuo(nickname: "Bestie")
        XCTAssertEqual(hRows(named, in: hContext([named])).nickname, .init(placeholder: "Sam", current: "Bestie"))
    }

    // MARK: - Block (D87)

    func testBlockIsHiddenWhileABlockIsQueuedAndOnceOneWasProvenDone() {
        let queued = hDuo(ended: true, endedBy: .owner, pendingOp: .block)
        XCTAssertNil(hRows(queued, in: hContext([queued])).block)
        let went = hDuo(ended: true, endedBy: .owner)
        XCTAssertNil(hRows(went, in: hContext([went], blocksSent: [went.id])).block)
        XCTAssertEqual(hRows(went, in: hContext([went])).block, "Block \(iso("Sam"))", "without the record nothing says a block went")
        let stillLive = hDuo()
        XCTAssertEqual(hRows(stillLive, in: hContext([stillLive], blocksSent: [stillLive.id])).block, "Block \(iso("Sam"))",
                       "a block that never ended the duo did not go")
        let leaving = hDuo(ended: true, endedBy: .owner, pendingOp: .leave)
        XCTAssertEqual(hRows(leaving, in: hContext([leaving])).block, "Block \(iso("Sam"))", "a queued leave can still be made a block")
    }

    func testBlockIsHiddenOnAnEndedCardTheServerHasForgotten() {
        let recent = hDuo(1, ended: true, endedDaysAgo: 29.9)
        XCTAssertEqual(hRows(recent, in: hContext([recent])).block, "Block \(iso("Sam"))")
        let purged = hDuo(2, ended: true, endedDaysAgo: 30)
        XCTAssertNil(hRows(purged, in: hContext([purged])).block, "30 days after the end the server answers duo_unknown")
        XCTAssertEqual(DuoScreenModel.tap(.block, on: purged, in: hContext([purged])), .nothing)
        XCTAssertTrue(hRows(purged, in: hContext([purged])).showsClear)
    }

    func testBlockIsNotOfferedWhenThePartnerNoLongerExists() {
        let ownerSees = hDuo(1, role: .owner, ended: true, endedBy: .partnerDeleted)
        XCTAssertNil(hRows(ownerSees, in: hContext([ownerSees])).block)
        let partnerSees = hDuo(2, role: .partner, ended: true, endedBy: .ownerDeleted)
        XCTAssertNil(hRows(partnerSees, in: hContext([partnerSees])).block)
        let sample = hDuo(3, ended: true, endedBy: .demoExpired, demo: true)
        XCTAssertNil(hRows(sample, in: hContext([sample])).block, "the App Review sample partner")
        XCTAssertEqual(DuoScreenModel.tap(.block, on: ownerSees, in: hContext([ownerSees])), .nothing)
        for (role, endedBy) in [(DuoRole.owner, DuoEndedBy.owner), (.owner, .partner), (.owner, .inactive), (.owner, .unknown),
                                (.owner, .ownerDeleted), (.partner, .partnerDeleted), (.partner, .partner)] {
            let duo = hDuo(4, role: role, ended: true, endedBy: endedBy)
            XCTAssertEqual(hRows(duo, in: hContext([duo])).block, "Block \(iso("Sam"))", "\(role) \(endedBy)")
            XCTAssertTrue(hRows(duo, in: hContext([duo])).showsClear)
        }
    }

    // MARK: - Exits only where they can be sent (D87)

    func testLeaveAndBlockAreHiddenWithoutACredentialOrWithTheThrowawayAndForABannedMember() {
        let live = hDuo(1)
        let ended = hDuo(2, partner: "Alex", ended: true)
        for context in [hContext([live, ended], identity: false), hContext([live, ended], throwaway: true), hContext([live, ended], .banned)] {
            XCTAssertFalse(hRows(live, in: context).showsLeave)
            XCTAssertNil(hRows(live, in: context).block)
            XCTAssertNil(hRows(ended, in: context).block)
            XCTAssertTrue(hRows(ended, in: context).showsClear, "Clear is local and always offered")
            XCTAssertEqual(DuoScreenModel.tap(.leave, on: live, in: context), .nothing)
            XCTAssertEqual(DuoScreenModel.tap(.block, on: ended, in: context), .nothing)
        }
    }

    func testLeaveAndBlockStayInEveryOtherState() {
        let duo = hDuo()
        for availability in [DuoAvailability.unknown, .available, .maintenance, .upgradeRequired, .disconnected, restore] {
            let rows = hRows(duo, in: hContext([duo], availability))
            XCTAssertTrue(rows.showsLeave, "\(availability)")
            XCTAssertEqual(rows.block, "Block \(iso("Sam"))", "\(availability)")
        }
    }

    func testABannedMemberKeepsClearReportAndDeleteButNotTheInvite() {
        let pending = hDuo(1, partner: "", joined: false)
        let ended = hDuo(2, partner: "Alex", ended: true)
        let context = hContext([pending, ended], .banned)
        XCTAssertFalse(hRows(pending, .nobodyToNudge, in: context).showsInvite, "the ban voids the codes")
        XCTAssertEqual(DuoScreenModel.tap(.invite, on: pending, in: context), .nothing)
        XCTAssertTrue(hRows(ended, in: context).showsClear)
        XCTAssertTrue(hRows(ended, in: context).showsReport)
        XCTAssertTrue(DuoScreenModel.showsDelete(in: context), "D33: a banned member keeps DELETE /me")
        XCTAssertEqual(DuoScreenModel.tap(.delete, on: nil, in: context),
                       .confirm(DuoScreenModel.deleteConfirmation(credentialIsAThrowaway: false)))
        XCTAssertEqual(DuoScreenModel.addRow(in: context), .hidden)
    }

    func testDeleteIsHiddenDuringTheRestoreQuestionAndDiagnosticsFollowsTheCredential() {
        XCTAssertFalse(DuoScreenModel.showsDelete(in: hContext([], restore)))
        XCTAssertEqual(DuoScreenModel.tap(.delete, on: nil, in: hContext([], restore)), .nothing)
        XCTAssertTrue(DuoScreenModel.showsDiagnostics(in: hContext([], restore)))
        XCTAssertTrue(DuoScreenModel.showsDelete(in: hContext([], .disconnected)), "a superseded phone keeps DELETE /me")
        XCTAssertFalse(DuoScreenModel.showsDelete(in: hContext([hDuo()], identity: false)))
        XCTAssertFalse(DuoScreenModel.showsDiagnostics(in: hContext([hDuo()], identity: false)))
    }

    func testTheToggleFollowsALiveDuoWhateverTheCredential() {
        let live = hDuo(1)
        let ended = hDuo(2, ended: true)
        let pending = hDuo(3, partner: "", joined: false)
        XCTAssertTrue(DuoScreenModel.showsNotificationsToggle(in: hContext([live, ended])))
        XCTAssertTrue(DuoScreenModel.showsNotificationsToggle(in: hContext([pending])), "an invite nobody joined is live")
        XCTAssertTrue(DuoScreenModel.showsNotificationsToggle(in: hContext([live], identity: false)))
        XCTAssertFalse(DuoScreenModel.showsNotificationsToggle(in: hContext([ended])))
        XCTAssertFalse(DuoScreenModel.showsNotificationsToggle(in: hContext([])))
    }

    // MARK: - The free limit and the add rows

    func testTheAddRowFollowsTheLimitAndHidesWhenTheAppMayNotWrite() {
        let live = hDuo(1)
        let ended = hDuo(2, ended: true)
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext([])), .start)
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext([live])), .locked, "a free person with one live duo")
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext([ended])), .start, "an ended duo takes no place")
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext([live], subscribed: true)), .start)
        let five = (1...5).map { hDuo($0) }
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext(five, subscribed: true)), .full)
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext(Array(five.prefix(4)) + [hDuo(9, ended: true)], subscribed: true)), .start)
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext(five, subscribed: false)), .locked)
        XCTAssertEqual(DuoScreenModel.atTheLimit, "You are in 5 duos, which is as many as there can be.")
        XCTAssertEqual(DuoScreenModel.addRow(in: hContext([], .maintenance)), .start)
        XCTAssertTrue(DuoScreenModel.showsHaveCode(in: hContext([live])), "a typed code is offered at the limit too")
        for availability in [DuoAvailability.upgradeRequired, .disconnected, .banned, restore] {
            XCTAssertEqual(DuoScreenModel.addRow(in: hContext([], availability)), .hidden, "\(availability)")
            XCTAssertFalse(DuoScreenModel.showsHaveCode(in: hContext([], availability)), "\(availability)")
        }
    }

    // MARK: - Dialogs

    func testTheLeaveDialogIsTheApprovedTextWithTheGenericAlsoEndsSentence() {
        let sam = hDuo(1)
        let dialog = DuoScreenModel.leaveConfirmation(for: sam)
        XCTAssertEqual(dialog.title, "Leave this duo?")
        XCTAssertEqual(dialog.confirmLabel, "Leave duo")
        XCTAssertEqual(dialog.message, DuoCopy.leaveMessage(partner: iso("Sam"), alsoEndsAnotherDuo: false)
                       + "\n\nIf you share another duo with them, it ends too.")
        XCTAssertFalse(dialog.message.contains("Your other duo"), "no name-matched guess (D87)")
        XCTAssertTrue(dialog.presets.isEmpty)
        let unnamed = DuoScreenModel.leaveConfirmation(for: hDuo(2, partner: ""))
        XCTAssertTrue(unnamed.message.contains(". Your partner will see that it ended."), "the fallback starts its sentence")
        let pending = hDuo(3, partner: "", joined: false)
        XCTAssertEqual(DuoScreenModel.leaveConfirmation(for: pending).message, "This cancels the invite. Nobody is told.")
    }

    func testTheBlockDialogFollowsTheCardAndTheNickname() {
        let live = hDuo(1)
        let liveDialog = DuoScreenModel.blockConfirmation(for: live)
        XCTAssertEqual(liveDialog.title, "Block \(iso("Sam"))?")
        XCTAssertEqual(liveDialog.confirmLabel, "Block")
        XCTAssertEqual(liveDialog.message, DuoCopy.blockMessage(partner: iso("Sam"), onEndedCard: false, sharesAnotherDuo: false))
        XCTAssertTrue(liveDialog.presets.isEmpty)
        let ended = hDuo(2, ended: true)
        XCTAssertEqual(DuoScreenModel.blockConfirmation(for: ended).message,
                       DuoCopy.blockMessage(partner: iso("Sam"), onEndedCard: true, sharesAnotherDuo: true))
        XCTAssertTrue(DuoScreenModel.blockConfirmation(for: ended).message.hasPrefix("This ends any other duo you share with \(iso("Sam")). "))
        // P55: the title and the words use the nickname.
        let nicknamed = DuoScreenModel.blockConfirmation(for: hDuo(3, nickname: "Bestie"))
        XCTAssertEqual(nicknamed.title, "Block \(iso("Bestie"))?")
        XCTAssertTrue(nicknamed.message.contains("your duo with \(iso("Bestie")),"))
        // The fallback: lowercase inside a sentence, capitalised where one starts.
        let unnamed = DuoScreenModel.blockConfirmation(for: hDuo(4, partner: ""))
        XCTAssertEqual(unnamed.title, "Block your partner?")
        XCTAssertTrue(unnamed.message.hasPrefix("This ends your duo with your partner, and any other you share."))
        XCTAssertTrue(unnamed.message.hasSuffix("Your partner will see that the duo ended, not that you blocked them."))
    }

    func testTheClearDeleteAndStartFreshDialogs() {
        let ended = hDuo(ended: true)
        let clear = DuoScreenModel.clearConfirmation(for: ended)
        XCTAssertEqual(clear.title, "Clear this duo?")
        XCTAssertEqual(clear.message, "It is already over. This only takes it off your screen.")
        XCTAssertEqual(clear.confirmLabel, "Clear")
        let delete = DuoScreenModel.deleteConfirmation(credentialIsAThrowaway: false)
        XCTAssertEqual(delete.title, "Delete my Duo data")
        XCTAssertEqual(delete.message, DuoCopy.deleteMessage)
        XCTAssertEqual(delete.confirmLabel, "Delete my Duo data")
        XCTAssertEqual(delete.action(), .deleteMyData(throwaway: false))
        let throwaway = DuoScreenModel.deleteConfirmation(credentialIsAThrowaway: true)
        XCTAssertEqual(throwaway.title, "Delete my Duo data from this phone")
        XCTAssertEqual(throwaway.message, "This deletes the Duo data on this phone. It cannot be undone.")
        XCTAssertEqual(throwaway.action(), .deleteMyData(throwaway: true), "the action carries the wording it was shown with")
        XCTAssertEqual(DuoScreenModel.tap(.delete, on: nil, in: hContext([], throwaway: true)), .confirm(throwaway))
        let fresh = DuoScreenModel.startFreshConfirmation(for: ended)
        XCTAssertEqual(fresh.title, "Start fresh?")
        XCTAssertEqual(fresh.message, "This removes the ended duo cards and anything waiting to be sent from this phone.")
        XCTAssertEqual(fresh.confirmLabel, "Start fresh")
        XCTAssertEqual(fresh.action(), .startFresh)
        for dialog in [clear, delete, throwaway, fresh] { XCTAssertTrue(dialog.presets.isEmpty) }
    }

    func testTheNudgeDialogOffersEveryPresetAndPromisesNoNotification() {
        let duo = hDuo(nickname: "Bestie")
        let dialog = DuoScreenModel.nudgeConfirmation(for: duo)
        XCTAssertEqual(dialog.title, "Send a nudge")
        XCTAssertEqual(dialog.message, "Your partner will see it.")
        XCTAssertNil(dialog.confirmLabel)
        XCTAssertEqual(dialog.presets, DuoNudgePreset.allCases)
        XCTAssertNil(dialog.action(), "a nudge needs a chosen line")
        XCTAssertEqual(dialog.action(preset: .cheers), .sendNudge(.cheers, duo.id))
    }

    // MARK: - Names inside sentences (H13)

    func testNamesAreIsolatedSoARightToLeftNameCannotReorderTheSentence() {
        for name in ["سارة", "\u{202E}maS", "**Sam**", "%@", "[x](https://e.com)", String(repeating: "W", count: 24)] {
            let duo = hDuo(partner: name)
            XCTAssertEqual(hRows(duo, in: hContext([duo])).block, "Block \(fsi)\(name)\(pdi)", name)
            XCTAssertEqual(DuoScreenModel.blockConfirmation(for: duo).title, "Block \(fsi)\(name)\(pdi)?", name)
            let message = DuoScreenModel.leaveConfirmation(for: duo).message
            XCTAssertTrue(message.contains(". \(fsi)\(name)\(pdi) will see that it ended."), name)
            XCTAssertFalse(message.contains(" " + name + " "), "never a bare name: \(name)")
        }
        // Every isolate opened is closed, so nothing after a name inherits its direction.
        let arabic = DuoScreenModel.blockConfirmation(for: hDuo(partner: "سارة")).message
        XCTAssertEqual(arabic.filter { $0 == "\u{2068}" }.count, arabic.filter { $0 == "\u{2069}" }.count)
        XCTAssertGreaterThan(arabic.filter { $0 == "\u{2068}" }.count, 1)
    }

    // MARK: - Taps: nothing that ends, deletes or sends without its dialog

    func testEveryRowThatEndsDeletesOrSendsAsksFirst() {
        let live = hDuo(1)
        let ended = hDuo(2, partner: "Alex", ended: true)
        let stuck = hDuo(3, ended: true, endedBy: .owner, pendingOp: .leave)
        let context = hContext([live, ended])
        func kind(_ result: DuoScreenModel.TapResult) -> DuoScreenModel.Confirmation.Kind? {
            if case .confirm(let confirmation) = result { return confirmation.kind }
            return nil
        }
        XCTAssertEqual(kind(DuoScreenModel.tap(.nudge, on: live, verdict: .allowed(remaining: 1), in: context)), .nudge)
        XCTAssertEqual(kind(DuoScreenModel.tap(.leave, on: live, in: context)), .leave)
        XCTAssertEqual(kind(DuoScreenModel.tap(.block, on: live, in: context)), .block)
        XCTAssertEqual(kind(DuoScreenModel.tap(.block, on: ended, in: context)), .block)
        XCTAssertEqual(kind(DuoScreenModel.tap(.clear, on: ended, in: context)), .clear)
        XCTAssertEqual(kind(DuoScreenModel.tap(.delete, on: nil, in: context)), .delete)
        XCTAssertEqual(kind(DuoScreenModel.tap(.startFresh, on: stuck, in: hContext([stuck], identity: false))), .startFresh)
        XCTAssertEqual(DuoScreenModel.leaveConfirmation(for: live).action(), .leave(live.id))
        XCTAssertEqual(DuoScreenModel.blockConfirmation(for: ended).action(), .block(ended.id))
        XCTAssertEqual(DuoScreenModel.clearConfirmation(for: ended).action(), .clear(ended.id))
    }

    func testATapOnARowThatIsNotOfferedDoesNothing() {
        let live = hDuo(1)
        let ended = hDuo(2, ended: true)
        let pending = hDuo(3, partner: "", joined: false)
        let context = hContext([live, ended, pending])
        XCTAssertEqual(DuoScreenModel.tap(.leave, on: ended, in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.clear, on: live, in: context), .nothing, "a live duo is never cleared")
        XCTAssertEqual(DuoScreenModel.tap(.block, on: pending, in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.nudge, on: live, verdict: .limitReached, in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.nudge, on: live, in: context), .nothing, "no verdict, no nudge")
        XCTAssertEqual(DuoScreenModel.tap(.nudge, on: live, verdict: .allowed(remaining: 2), in: hContext([live], .upgradeRequired)), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.leave, on: live, in: hContext([live], .banned)), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.leave, on: hDuo(7), in: context), .nothing, "a duo that is gone")
        XCTAssertEqual(DuoScreenModel.tap(.delete, on: nil, in: hContext([live], identity: false)), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.startFresh, on: live, in: context), .nothing)
        // P69: the invite row is gated like every other.
        XCTAssertEqual(DuoScreenModel.tap(.invite, on: live, in: context), .nothing, "a joined duo has no invite")
        let endedSince = hDuo(1, ended: true)
        XCTAssertEqual(DuoScreenModel.tap(.leave, on: live, in: hContext([endedSince])), .nothing, "judged as the duo is now")
    }

    func testTheSheetRowsPresentTheirSheets() {
        let pending = hDuo(1, partner: "", joined: false)
        let live = hDuo(2)
        XCTAssertEqual(DuoScreenModel.tap(.invite, on: pending, in: hContext([pending], subscribed: true)), .present(.invite(pending.id)))
        XCTAssertEqual(DuoScreenModel.tap(.report, on: live, in: hContext([live])), .present(.report(live.id)))
        XCTAssertEqual(DuoScreenModel.tap(.report, on: pending, in: hContext([pending])), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.start, on: nil, in: hContext([])), .present(.setup))
        XCTAssertEqual(DuoScreenModel.tap(.start, on: nil, in: hContext([live])), .nothing, "at the free limit")
        XCTAssertEqual(DuoScreenModel.tap(.locked, on: nil, in: hContext([live])), .present(.paywall))
        XCTAssertEqual(DuoScreenModel.tap(.locked, on: nil, in: hContext([live], subscribed: true)), .nothing)
        XCTAssertEqual(DuoScreenModel.tap(.haveCode, on: nil, in: hContext([live])), .present(.codeEntry))
        XCTAssertEqual(DuoScreenModel.tap(.haveCode, on: nil, in: hContext([live], .disconnected)), .nothing)
    }

    // MARK: - The confirm button, judged again (H4)

    func testAConfirmationIsJudgedAgainWhenItsButtonIsPressed() {
        let live = hDuo(1)
        let ended = hDuo(2, ended: true)
        let context = hContext([live, ended])
        XCTAssertEqual(DuoScreenModel.confirm(.leave(live.id), in: context), .perform(.leave(live.id)))
        XCTAssertEqual(DuoScreenModel.confirm(.block(ended.id), in: context), .perform(.block(ended.id)))
        XCTAssertEqual(DuoScreenModel.confirm(.clear(ended.id), in: context), .perform(.clear(ended.id)))
        XCTAssertEqual(DuoScreenModel.confirm(.sendNudge(.cheers, live.id), verdict: .allowed(remaining: 1), in: context),
                       .perform(.sendNudge(.cheers, live.id)))
        XCTAssertEqual(DuoScreenModel.confirm(.leave(live.id), in: hContext([hDuo(1, ended: true)])), .nothing, "ended meanwhile")
        XCTAssertEqual(DuoScreenModel.confirm(.leave(live.id), in: hContext([live], identity: false)), .nothing, "the credential went")
        XCTAssertEqual(DuoScreenModel.confirm(.clear(ended.id), in: hContext([live])), .nothing, "cleared meanwhile")
        XCTAssertEqual(DuoScreenModel.confirm(.sendNudge(.cheers, live.id), verdict: .limitReached, in: context), .nothing)
        XCTAssertEqual(DuoScreenModel.confirm(.startFresh, in: context), .nothing)
    }

    func testADeleteWhoseWordingNoLongerHoldsAsksAgain() {
        XCTAssertEqual(DuoScreenModel.confirm(.deleteMyData(throwaway: false), in: hContext([])), .perform(.deleteMyData(throwaway: false)))
        XCTAssertEqual(DuoScreenModel.confirm(.deleteMyData(throwaway: true), in: hContext([], throwaway: true)), .perform(.deleteMyData(throwaway: true)))
        XCTAssertEqual(DuoScreenModel.confirm(.deleteMyData(throwaway: true), in: hContext([])),
                       .confirm(DuoScreenModel.deleteConfirmation(credentialIsAThrowaway: false)), "the marker went: the full wording")
        XCTAssertEqual(DuoScreenModel.confirm(.deleteMyData(throwaway: false), in: hContext([], throwaway: true)),
                       .confirm(DuoScreenModel.deleteConfirmation(credentialIsAThrowaway: true)))
        XCTAssertEqual(DuoScreenModel.confirm(.deleteMyData(throwaway: false), in: hContext([], restore)), .nothing)
        XCTAssertEqual(DuoScreenModel.confirm(.deleteMyData(throwaway: false), in: hContext([], identity: false)), .nothing)
    }

    // MARK: - Start fresh for a card nothing can leave

    func testStartFreshIsOfferedOnlyForAQueuedExitWithNoCredentialAndNoLiveDuo() {
        let stuck = hDuo(1, ended: true, endedBy: .owner, pendingOp: .leave)
        XCTAssertTrue(hRows(stuck, in: hContext([stuck], identity: false)).showsStartFresh)
        XCTAssertEqual(DuoScreenModel.tap(.startFresh, on: stuck, in: hContext([stuck], identity: false)),
                       .confirm(DuoScreenModel.startFreshConfirmation(for: stuck)))
        XCTAssertEqual(DuoScreenModel.confirm(.startFresh, in: hContext([stuck], identity: false)), .perform(.startFresh))
        let blocked = hDuo(1, ended: true, endedBy: .owner, pendingOp: .block)
        XCTAssertTrue(hRows(blocked, in: hContext([blocked], identity: false)).showsStartFresh)
        XCTAssertFalse(hRows(stuck, in: hContext([stuck], identity: true)).showsStartFresh, "a credential can still send it")
        XCTAssertFalse(hRows(stuck, in: hContext([stuck, hDuo(2)], identity: false)).showsStartFresh, "a live duo would be lost too")
        let plainEnded = hDuo(1, ended: true)
        XCTAssertFalse(hRows(plainEnded, in: hContext([plainEnded], identity: false)).showsStartFresh, "Clear is enough")
    }

    // MARK: - The small things

    func testTheFooterListsWhatTheExplainerListsAndNeverPromisesMore() {
        XCTAssertTrue(DuoScreenModel.footer.hasPrefix("One streak, two people."))
        XCTAssertTrue(DuoScreenModel.footer.contains("when your phone last updated each day"))
        XCTAssertTrue(DuoScreenModel.footer.hasSuffix("Never what you drank or exactly how much."))
        XCTAssertFalse(DuoScreenModel.footer.contains("or when"))
        XCTAssertTrue(DuoCopy.explainerLines.contains("When your phone last updated each day"))
    }

    func testTheRequestIDLineIsDrawnOnlyForAUsableID() {
        XCTAssertEqual(DuoScreenModel.requestIDLine("0123456789abcdef"), "(ref 0123456789abcdef)")
        XCTAssertNil(DuoScreenModel.requestIDLine(nil))
        XCTAssertNil(DuoScreenModel.requestIDLine(""))
        XCTAssertNil(DuoScreenModel.requestIDLine("ref with spaces"))
        XCTAssertNil(DuoScreenModel.requestIDLine(String(repeating: "a", count: 500)))
    }

    func testTheCodeEntrySheetClosesSettingsOnlyForAnInviteItPublished() {
        let old = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: hNow.addingTimeInterval(-3600))
        let new = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: hNow)
        XCTAssertFalse(DuoScreenModel.closesSettingsAfterEntry(pendingInvite: nil), "a cancelled sheet leaves Settings open")
        XCTAssertTrue(DuoScreenModel.closesSettingsAfterEntry(pendingInvite: new), "a typed or scanned code")
        XCTAssertFalse(DuoScreenModel.closesSettingsAfterEntry(pendingInvite: old, before: old), "an older invite is not this sheet's")
        XCTAssertTrue(DuoScreenModel.closesSettingsAfterEntry(pendingInvite: new, before: old), "the same code typed again")
        XCTAssertFalse(DuoScreenModel.closesSettingsAfterEntry(pendingInvite: nil, before: old))
    }

    func testTheSetupSheetHandsItsDuoToTheInviteSheetOnlyAfterItHasGone() {
        var handoff = DuoScreenModel.SetupHandoff()
        XCTAssertNil(handoff.setupDidDismiss(), "a cancelled setup brings up nothing")
        let id = UUID()
        handoff.created(id)
        XCTAssertEqual(handoff.created, id)
        XCTAssertEqual(handoff.setupDidDismiss(), id)
        XCTAssertNil(handoff.setupDidDismiss(), "once")
    }

    func testTheSettingsRowValueIsInWords() {
        XCTAssertEqual(DuoScreenModel.settingsRowValue(liveDuos: 0), "Off")
        XCTAssertEqual(DuoScreenModel.settingsRowValue(liveDuos: 1), "1 duo")
        XCTAssertEqual(DuoScreenModel.settingsRowValue(liveDuos: 2), "2 duos")
        XCTAssertEqual(DuoScreenModel.settingsRowValue(liveDuos: 5), "5 duos")
    }

    func testTheRulesLinkGoesToTheTermsPage() {
        XCTAssertEqual(DuoScreenModel.rulesURL.absoluteString, "https://hydrodrop.us/terms.html")
        XCTAssertEqual(DuoScreenModel.rulesLink, "Duo Streaks rules")
    }
}
