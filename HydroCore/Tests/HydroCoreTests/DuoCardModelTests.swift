import XCTest
@testable import HydroCore

/// What a card, the buttons under it and the notice cards say, for every phase, every end,
/// a silent, a sample and a hostile partner, and the edge of the kept window (stage G).
final class DuoCardModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13 UTC, the day `today` names
    private let today = "2026-09-21"
    private let english = Locale(identifier: "en_US")

    /// A name as a sentence holds it: wrapped in a first-strong isolate (D83).
    private func iso(_ name: String) -> String { "\u{2068}\(name)\u{2069}" }

    private func duo(role: DuoRole = .owner, joined: Bool = true, owner: String = "Jo", partner: String = "Sam",
                     endedBy: DuoEndedBy? = nil, ended: Bool = false, pendingOp: DuoPendingOp? = nil,
                     lastWrite: String? = nil, demo: Bool = false, nickname: String? = nil,
                     joinedAt: Date? = nil) -> DuoState {
        DuoState(id: UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!, myRole: role, createdAt: now.addingTimeInterval(-86_400 * 5),
                 ownerDisplayName: owner, partnerDisplayName: partner, ownerSkin: "classic", partnerSkin: "forest",
                 statuses: [], partnerHasJoined: joined, endedAt: ended ? now : nil,
                 joinedAt: joined ? (joinedAt ?? now.addingTimeInterval(-86_400 * 4)) : nil, endedBy: endedBy,
                 partnerLastWriteDay: lastWrite, partnerIsDemo: demo, partnerNickname: nickname, pendingOp: pendingOp, syncedOnce: true)
    }

    private func status(_ role: DuoRole, bucket: Int) -> DuoDayStatus {
        DuoDayStatus(role: role, day: today, goalMet: bucket == 100, progressBucket: bucket, updatedAt: now)
    }

    private func model(_ duo: DuoState, mine: DuoDayStatus? = nil, theirs: DuoDayStatus? = nil, streak: Int = 3,
                       edge: Bool = false, locale: Locale? = nil) -> DuoCardModel {
        DuoCardModel.make(duo: duo, myStatus: mine, partnerStatus: theirs, streak: streak, reachedEdge: edge,
                          myToday: today, locale: locale ?? english)
    }

    // MARK: - Phases

    func testAWaitingDuoSaysSoAndFadesTheEmptySide() {
        let card = model(duo(joined: false, partner: ""), mine: status(.owner, bucket: 50),
                         theirs: status(.partner, bucket: 100), streak: 0)
        XCTAssertEqual(card.phase, .waiting)
        XCTAssertEqual(card.waitingLine, "Waiting for your partner to accept the invite.")
        XCTAssertEqual(card.mine.name, "You")
        XCTAssertEqual(card.mine.line, "Halfway there")
        XCTAssertFalse(card.mine.isDimmed)
        XCTAssertEqual(card.partner.name, "Your partner", "an empty name reads as the approved fallback")
        XCTAssertEqual(card.partner.line, "Not here yet")
        XCTAssertTrue(card.partner.isDimmed)
        XCTAssertEqual(card.partner.progressBucket, 0, "nobody is there to have made progress")
        XCTAssertFalse(card.partner.goalMet, "a stray status cannot paint the empty side green")
        XCTAssertNil(card.endedTitle)
        XCTAssertNil(card.endedLine)
        XCTAssertNil(card.notSeenLine)
        XCTAssertEqual(card.streakText, "0")
    }

    func testAWaitingDuoHasNoSharedStreakWhateverItsStatusesSay() {
        let card = model(duo(joined: false), streak: 4, edge: true)
        XCTAssertEqual(card.phase, .waiting)
        XCTAssertEqual(card.streakDays, 0, "nobody has joined to share one")
        XCTAssertEqual(card.streakText, "0")
        XCTAssertEqual(card.streakCaption, "days together")
        XCTAssertFalse(card.streakIsLit)
        XCTAssertEqual(card.spokenSummary, "Duo streak. Waiting for your partner to accept the invite.")
    }

    func testARunningDuoDrawsBothSidesAndTheStreak() {
        let card = model(duo(), mine: status(.owner, bucket: 100), theirs: status(.partner, bucket: 25), streak: 3)
        XCTAssertEqual(card.phase, .running)
        XCTAssertEqual(card.mine.name, "You")
        XCTAssertEqual(card.mine.role, .owner)
        XCTAssertEqual(card.mine.skin, "classic")
        XCTAssertEqual(card.mine.line, "Goal met")
        XCTAssertTrue(card.mine.goalMet)
        XCTAssertEqual(card.mine.progressBucket, 100)
        XCTAssertEqual(card.partner.name, "Sam")
        XCTAssertEqual(card.partner.role, .partner)
        XCTAssertEqual(card.partner.skin, "forest")
        XCTAssertEqual(card.partner.line, "A quarter of the way")
        XCTAssertEqual(card.partner.progressBucket, 25)
        XCTAssertFalse(card.partner.isDimmed)
        XCTAssertEqual(card.streakText, "3")
        XCTAssertEqual(card.streakCaption, "days together")
        XCTAssertTrue(card.streakIsLit)
        XCTAssertNil(card.waitingLine)
        XCTAssertNil(card.endedTitle)
    }

    func testAPartnerSideReadsFromThePartnersRoleWhenIAmThePartner() {
        let card = model(duo(role: .partner), mine: status(.partner, bucket: 75), theirs: status(.owner, bucket: 0))
        XCTAssertEqual(card.mine.role, .partner)
        XCTAssertEqual(card.mine.skin, "forest")
        XCTAssertEqual(card.mine.line, "Almost there")
        XCTAssertEqual(card.partner.name, "Jo", "my partner is the owner")
        XCTAssertEqual(card.partner.skin, "classic")
        XCTAssertEqual(card.partner.line, "Just getting started")
    }

    func testNothingKnownAboutTodayReadsAsNothingYet() {
        let card = model(duo(), mine: nil, theirs: nil)
        XCTAssertEqual(card.mine.line, "Nothing yet today")
        XCTAssertEqual(card.partner.line, "Nothing yet today")
        XCTAssertEqual(card.mine.progressBucket, 0)
    }

    func testTheCaptionIsSingularForOneDayAndPluralOtherwise() {
        XCTAssertEqual(model(duo(), streak: 1).streakCaption, "day together")
        XCTAssertEqual(model(duo(), streak: 1).streakText, "1")
        XCTAssertEqual(model(duo(), streak: 2).streakCaption, "days together")
        let none = model(duo(), streak: 0)
        XCTAssertEqual(none.streakText, "0")
        XCTAssertEqual(none.streakCaption, "days together")
        XCTAssertFalse(none.streakIsLit, "no streak, no lit flame")
        XCTAssertEqual(model(duo(), streak: -4).streakText, "0", "a negative count is never drawn")
    }

    func testAStreakAtTheEdgeOfTheKeptWindowReads100PlusDays() {
        let card = model(duo(), mine: status(.owner, bucket: 100), theirs: status(.partner, bucket: 100), streak: 100, edge: true)
        XCTAssertEqual(card.streakText, "100+ days")
        XCTAssertNil(card.streakCaption, "\"100+ days days together\" would say days twice")
        XCTAssertTrue(card.streakIsLit)
        XCTAssertEqual(card.spokenSummary, "Duo streak with Sam. 100+ days together. You: Goal met. Sam: Goal met.")
        let below = model(duo(), streak: 100, edge: false)
        XCTAssertEqual(below.streakText, "100", "only the edge reads as 100+")
        XCTAssertEqual(below.streakCaption, "days together")
    }

    // MARK: - Ended

    func testWhenThePartnerEndedItTheOwnerReadsThatTheyLeft() {
        let card = model(duo(role: .owner, endedBy: .partner, ended: true))
        XCTAssertEqual(card.phase, .ended)
        XCTAssertEqual(card.endedTitle, "Your duo ended")
        XCTAssertEqual(card.endedLine, "\(iso("Sam")) left this duo.")
        XCTAssertNil(card.waitingLine)
        XCTAssertEqual(card.spokenSummary, "Your duo with Sam ended.")
    }

    func testWhenTheOwnerEndedItThePartnerReadsThatTheyEndedIt() {
        let card = model(duo(role: .partner, endedBy: .owner, ended: true))
        XCTAssertEqual(card.endedTitle, "Your duo ended")
        XCTAssertEqual(card.endedLine, "\(iso("Jo")) ended this duo.")
        XCTAssertEqual(card.spokenSummary, "Your duo with Jo ended.")
    }

    func testEveryOtherEndShowsTheTitleAloneBecauseNoWordingIsApprovedForIt() {
        let ends: [DuoEndedBy?] = [nil, .owner, .partner, .ownerDeleted, .partnerDeleted, .inactive, .demoExpired, .unknown]
        var checked = 0
        for role in DuoRole.allCases {
            for end in ends {
                if role == .owner, end == .partner { continue }
                if role == .partner, end == .owner { continue }
                let card = model(duo(role: role, endedBy: end, ended: true))
                XCTAssertEqual(card.phase, .ended, "\(role) \(String(describing: end))")
                XCTAssertEqual(card.endedTitle, "Your duo ended", "\(role) \(String(describing: end))")
                XCTAssertNil(card.endedLine, "no approved second line for \(role) \(String(describing: end))")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 14, "my own end, both deletes, inactive, demo_expired, unknown and none, on each side")
    }

    func testAQueuedLeaveOrBlockDrawsExactlyAsAnEndedDuo() {
        for op in [DuoPendingOp.leave, .block] {
            let queued = model(duo(pendingOp: op, lastWrite: "2026-09-01"), mine: status(.owner, bucket: 50), streak: 4)
            var ended = duo(endedBy: nil, ended: true, lastWrite: "2026-09-01")
            ended.pendingOp = nil
            let over = model(ended, mine: status(.owner, bucket: 50), streak: 4)
            XCTAssertEqual(queued.pendingLine, "Waiting for a connection to finish this.", "\(op): it has not reached the server yet")
            XCTAssertNil(over.pendingLine, "an end the server made says nothing of the kind")
            XCTAssertEqual(queued.spokenSummary, over.spokenSummary + " Waiting for a connection to finish this.")
            var drawnAlike = queued
            drawnAlike.pendingLine = nil
            drawnAlike.spokenSummary = over.spokenSummary
            XCTAssertEqual(drawnAlike, over, "\(op): otherwise drawn exactly as ended")
            XCTAssertEqual(queued.phase, .ended)
            XCTAssertEqual(queued.endedTitle, "Your duo ended")
            XCTAssertNil(queued.notSeenLine, "a duo on its way out says nothing about the partner")
        }
        let unjoined = model(duo(joined: false, pendingOp: .leave))
        XCTAssertEqual(unjoined.phase, .ended, "a waiting duo being left is ended, not waiting")
        XCTAssertNil(unjoined.waitingLine)
        // The exit service stamps my own role when it queues a leave: still the title alone.
        let mine = model(duo(role: .partner, endedBy: .partner, ended: true, pendingOp: .leave))
        XCTAssertNil(mine.endedLine)
        // A block queued on a duo the partner had already left keeps the end it had.
        let blockAfterLeave = model(duo(endedBy: .partner, ended: true, pendingOp: .block))
        XCTAssertEqual(blockAfterLeave.endedLine, "\(iso("Sam")) left this duo.")
        XCTAssertEqual(blockAfterLeave.pendingLine, "Waiting for a connection to finish this.", "and says the block has not gone yet")
    }

    // MARK: - Not seen since

    func testASilentPartnerIsNotSeenSinceTheirLastDay() {
        let card = model(duo(lastWrite: "2026-09-16"), mine: nil, theirs: nil, streak: 0)
        XCTAssertEqual(card.notSeenLine, "Not seen since Sep 16")
        XCTAssertEqual(card.spokenSummary,
                       "Duo streak with Sam. 0 days together. You: Nothing yet today. Sam: Nothing yet today. Not seen since Sep 16.")
    }

    func testTheNotSeenLineStartsAfterMoreThanThreeQuietDays() {
        XCTAssertNil(model(duo(lastWrite: "2026-09-21")).notSeenLine)
        XCTAssertNil(model(duo(lastWrite: "2026-09-18")).notSeenLine, "three days is not yet silent")
        XCTAssertEqual(model(duo(lastWrite: "2026-09-17")).notSeenLine, "Not seen since Sep 17")
        XCTAssertNil(model(duo(lastWrite: nil)).notSeenLine, "nothing known is not silence")
    }

    func testNoNotSeenLineForAnUnjoinedASampleOrAnEndedDuo() {
        XCTAssertNil(model(duo(joined: false, lastWrite: "2026-09-01")).notSeenLine)
        XCTAssertNil(model(duo(lastWrite: "2026-09-01", demo: true)).notSeenLine)
        XCTAssertNil(model(duo(endedBy: .partner, ended: true, lastWrite: "2026-09-01")).notSeenLine)
    }

    func testTheNotSeenDayIsWrittenForTheLocaleAndNeverAsTheKey() {
        for identifier in ["en_GB", "de_DE", "fr_FR", "ja_JP", "ar_EG", "he_IL", "th_TH"] {
            let line = model(duo(lastWrite: "2026-09-16"), locale: Locale(identifier: identifier)).notSeenLine
            let text = try? XCTUnwrap(line, identifier)
            XCTAssertTrue(text?.hasPrefix("Not seen since ") == true, identifier)
            XCTAssertFalse(text?.contains("2026-09-16") ?? true, "\(identifier): \(text ?? "")")
            XCTAssertFalse(text?.contains("2026") ?? true, "a short date, without the year: \(identifier)")
            XCTAssertGreaterThan(text?.count ?? 0, "Not seen since ".count, identifier)
        }
    }

    func testTheNotSeenDayDoesNotMoveWithThePhonesTimeZone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for offset in [-11, -5, 0, 9, 14] {
            NSTimeZone.default = TimeZone(secondsFromGMT: offset * 3600)!
            XCTAssertEqual(DuoCardModel.shortDay("2026-09-16", locale: english), "Sep 16", "UTC\(offset)")
            XCTAssertEqual(DuoCardModel.shortDay("2026-12-31", locale: english), "Dec 31", "UTC\(offset)")
        }
    }

    func testShortDayRefusesWhatIsNotADayKey() {
        for bad in ["", "garbage", "2026-13-01", "2026-02-30", "1999-12-31", "2026-9-22"] {
            XCTAssertNil(DuoCardModel.shortDay(bad, locale: english), bad)
        }
    }

    // MARK: - Sample

    func testTheSamplePartnerIsBadgedAndSaidToBeASample() {
        let sample = model(duo(demo: true), mine: status(.owner, bucket: 100), theirs: status(.partner, bucket: 50), streak: 2)
        XCTAssertTrue(sample.showsSampleBadge)
        XCTAssertEqual(sample.spokenSummary, "Duo streak with Sam. 2 days together. You: Goal met. Sam: Halfway there. Sample.")
        XCTAssertTrue(model(duo(endedBy: .unknown, ended: true, demo: true)).showsSampleBadge, "an expired sample duo is still the sample")
        let real = model(duo())
        XCTAssertFalse(real.showsSampleBadge)
        XCTAssertFalse(real.spokenSummary.contains("Sample"))
    }

    // MARK: - Spoken

    func testTheSpokenSummaryForEachPhase() {
        XCTAssertEqual(model(duo(joined: false, partner: "")).spokenSummary, "Duo streak. Waiting for your partner to accept the invite.")
        XCTAssertEqual(model(duo(), mine: status(.owner, bucket: 100), theirs: status(.partner, bucket: 75), streak: 1).spokenSummary,
                       "Duo streak with Sam. 1 day together. You: Goal met. Sam: Almost there.")
        XCTAssertEqual(model(duo(), mine: status(.owner, bucket: 25), theirs: nil, streak: 12).spokenSummary,
                       "Duo streak with Sam. 12 days together. You: A quarter of the way. Sam: Nothing yet today.")
        XCTAssertEqual(model(duo(endedBy: .inactive, ended: true)).spokenSummary, "Your duo with Sam ended.")
        XCTAssertEqual(model(duo(partner: "", endedBy: .partnerDeleted, ended: true)).spokenSummary, "Your duo with your partner ended.", "inside a sentence the fallback is lowercase")
    }

    // MARK: - Names

    func testAHostileNameArrivesUnchanged() {
        let names = [
            "\u{202E}kcabrevO",                           // right-to-left override
            String(repeating: "Bartholomew", count: 30), // far past the card's width
            "💧🔥👩🏽‍🚀",                                   // emoji, one with a joiner
            "**Sam** _it_ [link](https://x.example) `x`", // markdown
            "%@ %d %n %s {0} \\(x)",                      // format specifiers
            "A\u{200B}B\u{FEFF}",                         // invisible characters
        ]
        for name in names {
            let running = model(duo(partner: name), mine: status(.owner, bucket: 0), theirs: status(.partner, bucket: 0))
            XCTAssertEqual(running.partner.name, name)
            XCTAssertTrue(running.spokenSummary.contains("Duo streak with \(name). "), name)
            XCTAssertTrue(running.spokenSummary.contains(" \(name): Just getting started."), name)
            XCTAssertEqual(model(duo(partner: name, endedBy: .partner, ended: true)).endedLine, "\(iso(name)) left this duo.")
            XCTAssertEqual(model(duo(role: .partner, owner: name, endedBy: .owner, ended: true)).endedLine, "\(iso(name)) ended this duo.")
            XCTAssertEqual(model(duo(partner: name, endedBy: .partner, ended: true)).spokenSummary, "Your duo with \(name) ended.")
            XCTAssertEqual(model(duo(nickname: name)).partner.name, name, "a nickname too")
            XCTAssertEqual(DuoNoticeModel.restoreText(DuoRestorePrompt(partnerName: name, myName: name)),
                           "This phone was connected to a duo with \(iso(name)). Continue as \(iso(name))?")
        }
    }

    func testANicknameIsWhatTheCardCallsThePartnerEverywhere() {
        let card = model(duo(endedBy: .partner, ended: true, nickname: "Bestie"))
        XCTAssertEqual(card.partner.name, "Bestie")
        XCTAssertEqual(card.endedLine, "\(iso("Bestie")) left this duo.")
        XCTAssertEqual(card.spokenSummary, "Your duo with Bestie ended.")
        XCTAssertEqual(model(duo(nickname: "Bestie")).mine.name, "You", "my own side is always You")
    }

    // MARK: - The buttons under a card

    private func actions(_ duo: DuoState, _ availability: DuoAvailability = .available, at time: Date? = nil) -> DuoCardActionsModel {
        DuoCardActionsModel.make(duo: duo, availability: availability, now: time ?? now, myToday: today)
    }

    func testNotThemIsOfferedToTheOwnerForTheFirst24HoursFromJoinedAt() {
        let joined = now.addingTimeInterval(-2 * 3600)
        XCTAssertTrue(actions(duo(joinedAt: joined)).offersNotThem)
        XCTAssertFalse(actions(duo(joinedAt: joined)).isEmpty)
        XCTAssertTrue(actions(duo(joinedAt: now.addingTimeInterval(-86_399))).offersNotThem)
        XCTAssertFalse(actions(duo(joinedAt: now.addingTimeInterval(-86_400))).offersNotThem, "24 hours on, it is gone")
        XCTAssertFalse(actions(duo(role: .partner, joinedAt: joined)).offersNotThem, "only the person who sent the invite")
        XCTAssertFalse(actions(duo(joined: false)).offersNotThem, "nobody has joined")
        XCTAssertFalse(actions(duo(joinedAt: joined), .banned).offersNotThem, "a banned member's block is refused 403")
        for availability: DuoAvailability in [.unknown, .maintenance, .disconnected, .upgradeRequired] {
            XCTAssertTrue(actions(duo(joinedAt: joined), availability).offersNotThem, "\(availability)")
        }
    }

    func testReconnectIsOfferedForASilentPartnerOnlyWhenThePhoneMayWrite() {
        let silent = duo(lastWrite: "2026-09-14")
        XCTAssertTrue(actions(silent).offersReconnect)
        XCTAssertFalse(actions(silent).offersNotThem, "joined four days ago")
        XCTAssertTrue(actions(silent, .maintenance).offersReconnect)
        XCTAssertTrue(actions(silent, .unknown).offersReconnect)
        for availability: DuoAvailability in [.disconnected, .banned, .upgradeRequired,
                                              .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))] {
            XCTAssertFalse(actions(silent, availability).offersReconnect, "making the code is a write: \(availability)")
        }
        XCTAssertFalse(actions(duo(lastWrite: "2026-09-19")).offersReconnect, "two days is not silence")
        XCTAssertFalse(actions(duo(lastWrite: "2026-09-01", demo: true)).offersReconnect, "the sample partner has no phone")
        XCTAssertTrue(actions(duo(lastWrite: "2026-09-19")).isEmpty)
    }

    func testNothingIsOfferedForADuoThatIsOverOrOnItsWayOut() {
        let joined = now.addingTimeInterval(-3600)
        for state in [duo(endedBy: .partner, ended: true, lastWrite: "2026-09-01", joinedAt: joined),
                      duo(pendingOp: .leave, lastWrite: "2026-09-01", joinedAt: joined),
                      duo(pendingOp: .block, lastWrite: "2026-09-01", joinedAt: joined)] {
            let offered = actions(state)
            XCTAssertFalse(offered.offersNotThem)
            XCTAssertFalse(offered.offersReconnect)
            XCTAssertTrue(offered.isEmpty)
        }
        let both = actions(duo(lastWrite: "2026-09-01", joinedAt: joined))
        XCTAssertTrue(both.offersNotThem && both.offersReconnect, "both apply at once on a live duo")
    }

    // MARK: - The notice cards

    func testEachAvailabilityHasTheCardItShouldAndNoOther() {
        let restore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let expected: [(DuoAvailability, [DuoNoticeCard.Kind], String?)] = [
            (.unknown, [], nil),
            (.available, [], nil),
            (.maintenance, [.service], "HydroDrop's duo service is not available right now. Your duo will catch up when it is."),
            (.upgradeRequired, [.service], "Update HydroDrop to keep using Duo Streaks."),
            (.banned, [.service], "Duo Streaks are not available for this device. Contact support@hydrodrop.us."),
            (.disconnected, [.disconnected], "This phone was disconnected from the duo"),
            (restore, [.restore], "This phone was connected to a duo with \(iso("Sam")). Continue as \(iso("Jo"))?"),
        ]
        for (availability, kinds, text) in expected {
            let cards = DuoNoticeModel.cards(availability: availability, newDeviceNotice: false)
            XCTAssertEqual(cards.map(\.kind), kinds, "\(availability)")
            XCTAssertEqual(cards.first?.text, text, "\(availability)")
            if kinds == [.service] { XCTAssertEqual(cards.first?.text, availability.bannerMessage) }
            if kinds == [.service] { XCTAssertTrue(cards.first?.buttons.isEmpty == true, "a plain row") }
            let withDevice = DuoNoticeModel.cards(availability: availability, newDeviceNotice: true)
            XCTAssertEqual(withDevice.map(\.kind), kinds + [.newDevice], "the device notice comes last: \(availability)")
        }
    }

    func testTheRestoreQuestionOffersContinueAndStartFreshInThatOrder() {
        let cards = DuoNoticeModel.cards(availability: .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")),
                                         newDeviceNotice: false)
        XCTAssertEqual(cards.first?.buttons, [
            DuoNoticeButton(action: .continueAsRestored, title: "Continue", isPrimary: true),
            DuoNoticeButton(action: .startFresh, title: "Not me, start fresh", isPrimary: false),
        ])
    }

    func testTheDisconnectedQuestionOffersIHadADuoAndStartFresh() {
        let cards = DuoNoticeModel.cards(availability: .disconnected, newDeviceNotice: false)
        XCTAssertEqual(cards.count, 1, "its banner line is not drawn a second time")
        XCTAssertEqual(cards.first?.buttons, [
            DuoNoticeButton(action: .reconnect, title: "I had a duo", isPrimary: true),
            DuoNoticeButton(action: .startFresh, title: "Start fresh", isPrimary: false),
        ])
    }

    func testTheNewDeviceNoticeHasItsPlaceholderAndADismiss() {
        let cards = DuoNoticeModel.cards(availability: .available, newDeviceNotice: true)
        XCTAssertEqual(cards, [DuoNoticeCard(kind: .newDevice, text: "A device was added to your Duo Streaks.",
                                             buttons: [DuoNoticeButton(action: .dismissNewDevice, title: "Dismiss", isPrimary: false)])])
    }

    func testTheRestoreQuestionsFallbacks() {
        func text(_ partner: String?, _ me: String?) -> String {
            DuoNoticeModel.restoreText(DuoRestorePrompt(partnerName: partner, myName: me))
        }
        XCTAssertEqual(text("Sam", "Jo"), "This phone was connected to a duo with \(iso("Sam")). Continue as \(iso("Jo"))?")
        XCTAssertEqual(text(nil, "Jo"), "This phone was connected to a duo with your partner. Continue as \(iso("Jo"))?",
                       "inside the sentence the fallback is lowercase")
        XCTAssertEqual(text("", "Jo"), "This phone was connected to a duo with your partner. Continue as \(iso("Jo"))?")
        XCTAssertEqual(text("Sam", nil), "This phone was connected to a duo with \(iso("Sam")). Continue as you?",
                       "never the name this phone kept, which may be the person now holding it")
        XCTAssertEqual(text("Sam", ""), "This phone was connected to a duo with \(iso("Sam")). Continue as you?")
        XCTAssertEqual(text("  ", " \n"), "This phone was connected to a duo with your partner. Continue as you?",
                       "only spaces is no name")
        XCTAssertEqual(text(" Sam ", nil), "This phone was connected to a duo with \(iso(" Sam ")). Continue as you?",
                       "a name with spaces round it is used as it came")
    }

    // MARK: - The fix round (D83)

    func testAQueuedLeaveOrBlockSaysItHasNotGoneYet() {
        XCTAssertEqual(model(duo(role: .owner, endedBy: .owner, ended: true, pendingOp: .leave)).pendingLine,
                       "Waiting for a connection to finish this.")
        XCTAssertEqual(model(duo(role: .partner, endedBy: .partner, ended: true, pendingOp: .block)).pendingLine,
                       "Waiting for a connection to finish this.")
        XCTAssertEqual(model(duo(pendingOp: .leave)).spokenSummary, "Your duo with Sam ended. Waiting for a connection to finish this.")
        for end in [DuoEndedBy.owner, .partner, .inactive, .unknown] {
            XCTAssertNil(model(duo(endedBy: end, ended: true)).pendingLine, "an end the server made: \(end)")
        }
        XCTAssertNil(model(duo()).pendingLine)
    }

    func testTheFlameIsLitAtTheEdgeWhateverTheCount() {
        XCTAssertTrue(model(duo(), streak: 0, edge: true).streakIsLit, "the edge is a long streak, not none")
        XCTAssertTrue(model(duo(), streak: 1).streakIsLit)
        XCTAssertFalse(model(duo(), streak: 0).streakIsLit)
    }

    func testACardThatHasNotEndedHasNoEndedLinesWhateverItsHeaderSays() {
        let live = model(duo(endedBy: .partner, ended: false))
        XCTAssertEqual(live.phase, .running)
        XCTAssertNil(live.endedLine, "a stray ended_by on a live duo is not an end")
        XCTAssertNil(live.endedTitle)
        XCTAssertNil(live.pendingLine)
    }

    func testANameInsideASentenceIsIsolatedSoItCannotReorderTheWordsAroundIt() {
        let arabic = "\u{0633}\u{0627}\u{0631}\u{0629}"
        let override = "\u{202E}kcabrevO"
        for name in [arabic, override, "Sam"] {
            let ended = model(duo(partner: name, endedBy: .partner, ended: true))
            XCTAssertEqual(ended.endedLine, "\u{2068}\(name)\u{2069} left this duo.")
            XCTAssertEqual(ended.partner.name, name, "a name standing alone is drawn as it is")
            let live = duo(partner: name, lastWrite: "2026-09-01")
            XCTAssertEqual(DuoCardActionsModel.blockTitle(for: live), "Block \u{2068}\(name)\u{2069}?")
            XCTAssertEqual(DuoCardActionsModel.reconnectOffer(for: live), "Reconnect \u{2068}\(name)\u{2069}'s new phone")
            let message = DuoCardActionsModel.blockMessage(for: live)
            XCTAssertEqual(message, DuoCopy.blockMessage(partner: "\u{2068}\(name)\u{2069}", onEndedCard: false, sharesAnotherDuo: false))
            XCTAssertEqual(message.components(separatedBy: "\u{2068}\(name)\u{2069}").count, 3, "both places the name stands")
        }
        XCTAssertEqual(DuoCardModel.isolated("Sam").unicodeScalars.first, "\u{2068}")
        XCTAssertEqual(DuoCardModel.isolated("Sam").unicodeScalars.last, "\u{2069}")
    }

    func testAMissingNameIsCapitalOnlyWhereItStartsASentence() {
        let nameless = duo(partner: "", endedBy: .partner, ended: true)
        XCTAssertEqual(model(nameless).endedLine, "Your partner left this duo.")
        XCTAssertEqual(model(duo(role: .partner, owner: "", endedBy: .owner, ended: true)).endedLine, "Your partner ended this duo.")
        let live = duo(partner: "")
        XCTAssertEqual(DuoCardActionsModel.blockTitle(for: live), "Block your partner?")
        XCTAssertEqual(DuoCardActionsModel.reconnectOffer(for: live), "Reconnect your partner's new phone")
        let message = DuoCardActionsModel.blockMessage(for: live)
        XCTAssertTrue(message.hasPrefix("This ends your duo with your partner, and any other you share."), message)
        XCTAssertTrue(message.hasSuffix("we can't tell it's them. Your partner will see that the duo ended, not that you blocked them."), message)
        XCTAssertFalse(message.contains("\u{E000}"), "no marker is left behind")
        XCTAssertEqual(model(duo(partner: ""), mine: nil, theirs: nil, streak: 2).spokenSummary,
                       "Duo streak with your partner. 2 days together. You: Nothing yet today. Your partner: Nothing yet today.")
    }

    func testThePartnersNameIsTheNicknameThenTheServersThenNone() {
        XCTAssertEqual(DuoCardModel.partnerName(of: duo(partner: "Sam")), "Sam")
        XCTAssertEqual(DuoCardModel.partnerName(of: duo(partner: "Sam", nickname: "Bestie")), "Bestie")
        XCTAssertEqual(DuoCardModel.partnerName(of: duo(partner: "Sam", nickname: "")), "Sam")
        XCTAssertNil(DuoCardModel.partnerName(of: duo(partner: "")))
        XCTAssertEqual(DuoCardModel.partnerName(of: duo(role: .partner, owner: "Jo")), "Jo")
        for state in [duo(partner: "Sam"), duo(partner: "Sam", nickname: "Bestie"), duo(role: .partner, owner: "Jo")] {
            XCTAssertEqual(DuoCardModel.partnerName(of: state), state.displayName(of: state.myRole.other), "the same rule as displayName")
        }
    }

    func testNotThemIsOfferedOnlyWhenThePhoneCanSendTheBlock() {
        let joined = duo(lastWrite: "2026-09-01", joinedAt: now.addingTimeInterval(-3600))
        for availability: DuoAvailability in [.unknown, .available, .maintenance, .upgradeRequired, .disconnected] {
            XCTAssertTrue(DuoCardActionsModel.make(duo: joined, availability: availability, now: now, myToday: today, canSendExits: true).offersNotThem,
                          "\(availability)")
            let without = DuoCardActionsModel.make(duo: joined, availability: availability, now: now, myToday: today, canSendExits: false)
            XCTAssertFalse(without.offersNotThem, "no credential, or only a Reconnect's throwaway: the block could not be queued (\(availability))")
            XCTAssertEqual(without.offersReconnect, availability.allowsWrites, "the reconnect offer does not depend on it")
        }
    }

    func testTodaysRule() {
        func rule(hasDuos: Bool = false, hasIdentity: Bool = false, notices: Bool = false, wants: Bool = true, refused: Bool = false,
                  availability: DuoAvailability = .available, screenshots: Bool = false) -> DuoTodayRule {
            DuoTodayRule.make(hasDuos: hasDuos, hasIdentity: hasIdentity, hasNoticeCards: notices, wantsSuggestion: wants,
                              ageRefused: refused, availability: availability, screenshotMode: screenshots)
        }
        XCTAssertEqual(rule(), DuoTodayRule(showsNotices: false, showsCards: true, showsSuggestion: true, talksToTheServer: true, refreshable: false))
        XCTAssertFalse(rule(wants: false).showsSuggestion)
        XCTAssertFalse(rule(refused: true).showsSuggestion, "not for someone the birth-year screen refused")
        XCTAssertFalse(rule(hasDuos: true, hasIdentity: true, refused: true).showsCards,
                       "nor any duo card: a refusal whose delete failed would show the partner's name and day")
        XCTAssertFalse(rule(notices: true).showsSuggestion, "not while a notice asks something first")
        XCTAssertTrue(rule(notices: true).showsNotices)
        for availability: DuoAvailability in [.disconnected, .banned, .upgradeRequired, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil))] {
            XCTAssertFalse(rule(availability: availability).showsSuggestion, "not on a phone that may not write: \(availability)")
        }
        XCTAssertTrue(rule(availability: .maintenance).showsSuggestion)
        XCTAssertTrue(rule(availability: .unknown).showsSuggestion)
        XCTAssertTrue(rule(hasDuos: true).refreshable)
        XCTAssertTrue(rule(hasIdentity: true).refreshable)
        XCTAssertFalse(rule().refreshable, "nothing to fetch for someone with neither")
        XCTAssertEqual(rule(hasDuos: true, hasIdentity: true, notices: true, screenshots: true),
                       DuoTodayRule(showsNotices: false, showsCards: false, showsSuggestion: false, talksToTheServer: false, refreshable: false),
                       "nothing of Duo shows or is sent during an App Store capture")
    }

    func testThePagerPutsLiveDuosFirstThenTheWaitingOneThenTheEndedOnes() {
        func named(_ name: String, joined: Bool = true, ended: Bool = false, pendingOp: DuoPendingOp? = nil) -> DuoState {
            var state = duo(joined: joined, partner: name, endedBy: ended ? .partner : nil, ended: ended, pendingOp: pendingOp)
            state.id = UUID()
            return state
        }
        let input = [named("Ended", ended: true), named("Waiting", joined: false), named("Live1"), named("Leaving", pendingOp: .leave),
                     named("Live2")]
        XCTAssertEqual(DuoCardModel.pagerOrder(input).map(\.partnerDisplayName), ["Live1", "Live2", "Waiting", "Ended", "Leaving"])
        XCTAssertEqual(DuoCardModel.pagerOrder([]).count, 0)
    }

    func testThePageValue() {
        XCTAssertEqual(DuoCardModel.pageValue(index: 1, count: 3), "Page 2 of 3")
        XCTAssertEqual(DuoCardModel.pageValue(index: 0, count: 1), "Page 1 of 1")
    }

    /// Finding 6 and decision f: Start fresh asks first on both cards, restore and disconnected;
    /// no other notice button does.
    func testStartFreshAsksFirstOnBothCardsAndNothingElseDoes() {
        for availability in [DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")), .disconnected] {
            let buttons = DuoNoticeModel.cards(availability: availability, newDeviceNotice: true).flatMap(\.buttons)
            XCTAssertTrue(buttons.contains { $0.action == .startFresh })
            for button in buttons { XCTAssertEqual(button.action.asksFirst, button.action == .startFresh, button.title) }
        }
    }
}
