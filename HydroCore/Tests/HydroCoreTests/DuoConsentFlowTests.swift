import XCTest
@testable import HydroCore

/// The consent flow's rules (plan P2 stage I): which screen a consent sheet is on, the year the
/// birth-year field accepts and the confirmation it asks for, the name the field keeps and the
/// request sends, what the form says, and what is said before the consent tap.
final class DuoConsentFlowTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func calendar(_ identifier: Calendar.Identifier = .gregorian, secondsFromGMT: Int = 0) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        return calendar
    }

    private var mid2027: Date { date("2027-06-15T12:00:00Z") }

    // MARK: - The steps

    func testEveryAgeAndTermsPairHasItsStep() {
        let current = DuoProtocolConstants.termsVersion
        let expected: [(DuoAgeStatus, Int, DuoConsentFlow.Step)] = [
            (.unknown, 0, .askAge), (.unknown, current, .askAge), (.unknown, current + 1, .askAge),
            (.refused, 0, .refused), (.refused, current, .refused), (.refused, current + 1, .refused),
            (.allowed, 0, .terms), (.allowed, current, .form), (.allowed, current + 1, .form),
        ]
        for (age, terms, step) in expected {
            XCTAssertEqual(DuoConsentFlow.step(ageStatus: age, acceptedTermsVersion: terms), step, "\(age), terms \(terms)")
        }
        XCTAssertEqual(current, 1, "the table above was written for terms version 1; a new version needs its own rows")
    }

    func testARefusalWinsOverEverythingAndIsNeverTheForm() {
        for terms in [-1, 0, 1, 2, 99] {
            XCTAssertEqual(DuoConsentFlow.step(ageStatus: .refused, acceptedTermsVersion: terms), .refused)
        }
    }

    func testTheFormIsReachedOnlyBySomeoneOldEnoughWhoAcceptedTheCurrentRules() {
        let all: [DuoAgeStatus] = [.unknown, .allowed, .refused]
        for age in all {
            for terms in -1...3 {
                let isForm = DuoConsentFlow.step(ageStatus: age, acceptedTermsVersion: terms) == .form
                XCTAssertEqual(isForm, age == .allowed && terms >= DuoProtocolConstants.termsVersion, "\(age), terms \(terms)")
            }
        }
    }

    func testTheAgeScreenComesBeforeTheRules() {
        // An age not known yet is asked first even after the rules were accepted (a phone whose
        // defaults kept the terms answer but lost the age one), so no one reads past the age screen.
        XCTAssertEqual(DuoConsentFlow.step(ageStatus: .unknown, acceptedTermsVersion: 1), .askAge)
        XCTAssertEqual(DuoConsentFlow.step(ageStatus: .allowed, acceptedTermsVersion: 0), .terms)
    }

    // MARK: - The typed year

    func testATypedYearIsExactlyFourDigitsThatMakeAPlausibleYear() {
        let now = mid2027
        let phone = calendar()
        XCTAssertEqual(DuoConsentFlow.typedYear("1990", now: now, calendar: phone), 1990)
        XCTAssertEqual(DuoConsentFlow.typedYear("2027", now: now, calendar: phone), 2027, "this year is an answer")
        XCTAssertEqual(DuoConsentFlow.typedYear("1927", now: now, calendar: phone), 1927, "and so is a hundred years back")
        let refused = ["", "1", "19", "199", "19900", "abcd", "19a0", "199O", "    ", " 199", "199 ", "1990\n", "-199", "+199", "1e03",
                       "19.9", "1,99", "¹⁹⁹⁰", "1\u{0301}99", "1926", "1899", "0000", "2028", "9999", "01990", "001990"]
        for text in refused {
            XCTAssertNil(DuoConsentFlow.typedYear(text, now: now, calendar: phone), text.debugDescription)
        }
    }

    func testDigitsFromAnyKeyboardAreReadAsTheYearTheyWrite() {
        XCTAssertEqual(DuoConsentFlow.typedYear("١٩٩٠", now: mid2027, calendar: calendar()), 1990, "Arabic-Indic digits")
        XCTAssertEqual(DuoConsentFlow.typedYear("۱۹۹۰", now: mid2027, calendar: calendar()), 1990, "Persian digits")
        XCTAssertEqual(DuoConsentFlow.typedYear("１９９０", now: mid2027, calendar: calendar()), 1990, "full-width digits")
        XCTAssertEqual(DuoConsentFlow.typedYear("१९९०", now: mid2027, calendar: calendar()), 1990, "Devanagari digits")
    }

    func testTheYearIsJudgedInGregorianYearsWhateverCalendarThePhoneUses() {
        for identifier: Calendar.Identifier in [.buddhist, .japanese, .islamicUmmAlQura, .hebrew, .persian] {
            let phone = calendar(identifier)
            XCTAssertEqual(DuoConsentFlow.typedYear("2027", now: mid2027, calendar: phone), 2027, "\(identifier)")
            XCTAssertEqual(DuoConsentFlow.currentYear(now: mid2027, calendar: phone), 2027, "\(identifier)")
        }
        XCTAssertNil(DuoConsentFlow.typedYear("2570", now: mid2027, calendar: calendar(.buddhist)), "a Buddhist-era year is not a Gregorian one")
    }

    func testThisYearTurnsOverAtThePhonesNewYear() {
        let now = date("2027-12-31T23:30:00Z")
        XCTAssertNil(DuoConsentFlow.typedYear("2028", now: now, calendar: calendar(secondsFromGMT: 0)))
        XCTAssertEqual(DuoConsentFlow.typedYear("2028", now: now, calendar: calendar(secondsFromGMT: 2 * 3600)), 2028,
                       "the time zone is the phone's, as DuoAgeGate.decide reads it")
    }

    func testAPhoneClockSetInThePastStillAcceptsEveryYearTheRuleCountsFrom() {
        let unset = date("2001-01-01T00:00:00Z")
        XCTAssertEqual(DuoConsentFlow.currentYear(now: unset, calendar: calendar()), DuoAgeGate.earliestPlausibleYear)
        XCTAssertEqual(DuoConsentFlow.typedYear(String(DuoAgeGate.earliestPlausibleYear), now: unset, calendar: calendar()),
                       DuoAgeGate.earliestPlausibleYear)
        XCTAssertEqual(DuoConsentFlow.typedYear("2010", now: unset, calendar: calendar()), 2010)
        XCTAssertEqual(DuoConsentFlow.plausibleBirthYears(now: unset, calendar: calendar()).count, DuoConsentFlow.plausibleAgeSpan + 1)
    }

    /// The field and the rule must agree: a year the field accepts is always an answer, never the
    /// "unreadable" that would make the screen ask again, and the line between the two answers falls
    /// where the rule puts it, whatever the phone's calendar or clock.
    func testEveryYearTheFieldAcceptsIsAnAnswerTheRuleCanGive() {
        let nows = [date("2026-03-01T00:00:00Z"), date("2027-12-31T23:30:00Z"), date("2001-01-01T00:00:00Z"), date("2040-07-04T09:00:00Z")]
        for now in nows {
            for phone in [calendar(), calendar(.buddhist, secondsFromGMT: 2 * 3600), calendar(.japanese, secondsFromGMT: -10 * 3600)] {
                let thisYear = DuoConsentFlow.currentYear(now: now, calendar: phone)
                for year in 1800...2100 {
                    let accepted = DuoConsentFlow.typedYear(String(year), now: now, calendar: phone)
                    XCTAssertEqual(accepted != nil, (thisYear - DuoConsentFlow.plausibleAgeSpan...thisYear).contains(year), "\(year) at \(now)")
                    guard accepted != nil else { continue }
                    let answer = DuoAgeGate.decide(birthYear: year, now: now, calendar: phone)
                    XCTAssertEqual(answer, thisYear - year >= DuoAgeGate.minimumAge ? .allowed : .refused, "\(year) at \(now)")
                }
            }
        }
    }

    func testTheYearFieldKeepsTheWholeInput() {
        XCTAssertEqual(DuoConsentFlow.limitedYearInput("19901"), "19901")
        XCTAssertEqual(DuoConsentFlow.limitedYearInput("199"), "199")
        XCTAssertEqual(DuoConsentFlow.limitedYearInput(" 1990"), " 1990", "pasted space stays, and keeps Continue off")
        XCTAssertNil(DuoConsentFlow.typedYear(DuoConsentFlow.limitedYearInput(" 1990"), now: mid2027, calendar: calendar()))
        XCTAssertEqual(DuoConsentFlow.limitedYearInput("ab12"), "ab12")
    }

    func testMalformedPastesCannotBecomeAnAnswer() {
        for text in ["2019 ", "2019\n", "20199", "1990x", "２０１９ ", "2019\u{200B}"] {
            var entry = DuoConsentFlow.AgeEntry()
            entry.type(text)
            XCTAssertEqual(entry.typed, text)
            XCTAssertFalse(entry.canContinue(now: mid2027, calendar: calendar()))
            XCTAssertFalse(entry.continueFromField(now: mid2027, calendar: calendar()))
            XCTAssertNil(entry.takeConfirmedYear())
        }
    }

    func testAnEditInvalidatesTheYearAwaitingConfirmation() {
        var entry = DuoConsentFlow.AgeEntry()
        entry.type("2019")
        XCTAssertTrue(entry.continueFromField(now: mid2027, calendar: calendar()))
        entry.type("1990")
        XCTAssertNil(entry.takeConfirmedYear(), "an old confirmation must not record the old year")
        XCTAssertTrue(entry.continueFromField(now: mid2027, calendar: calendar()))
        XCTAssertEqual(entry.takeConfirmedYear(), 1990)
    }

    // MARK: - The confirmation

    func testAYearIsHandedOverOnlyAfterItsConfirmation() {
        var entry = DuoConsentFlow.AgeEntry()
        let now = mid2027
        let phone = calendar()
        XCTAssertFalse(entry.canContinue(now: now, calendar: phone), "an empty field cannot continue")
        XCTAssertNil(entry.takeConfirmedYear(), "nothing to record before an answer")
        entry.type("1990")
        XCTAssertTrue(entry.canContinue(now: now, calendar: phone))
        XCTAssertNil(entry.takeConfirmedYear(), "a typed year is not an answer until it is confirmed")
        XCTAssertEqual(entry.typed, "1990", "and asking for it did not clear the field")
        XCTAssertTrue(entry.continueFromField(now: now, calendar: phone))
        XCTAssertEqual(entry.pendingYear, 1990, "Continue asks 'Born in 1990?'")
        XCTAssertFalse(entry.canContinue(now: now, calendar: phone), "the field's Continue is gone while the question is up")
        XCTAssertEqual(entry.takeConfirmedYear(), 1990)
        XCTAssertNil(entry.takeConfirmedYear(), "once")
        XCTAssertEqual(entry, DuoConsentFlow.AgeEntry(), "and the year is not kept a moment longer")
    }

    func testChangeGoesBackToTheFieldWithWhatWasTyped() {
        var entry = DuoConsentFlow.AgeEntry()
        entry.type("2015")
        XCTAssertTrue(entry.continueFromField(now: mid2027, calendar: calendar()))
        entry.change()
        XCTAssertNil(entry.pendingYear)
        XCTAssertEqual(entry.typed, "2015")
        XCTAssertNil(entry.takeConfirmedYear(), "Change records nothing")
        entry.type("1985")
        XCTAssertTrue(entry.continueFromField(now: mid2027, calendar: calendar()))
        XCTAssertEqual(entry.takeConfirmedYear(), 1985)
    }

    func testEveryAnswerIsConfirmedTheSameWayWhateverTheYear() {
        // A child's year and an adult's are asked about in the same words: the confirmation says
        // nothing about which one passes.
        for year in [2020, 2014, 2013, 1990, 1927] {
            var entry = DuoConsentFlow.AgeEntry()
            entry.type(String(year))
            XCTAssertTrue(entry.continueFromField(now: mid2027, calendar: calendar()), "\(year)")
            XCTAssertEqual(DuoConsentFlow.NewCopy.bornIn(year), "Born in \(year)?")
        }
        var invalid = DuoConsentFlow.AgeEntry()
        invalid.type("19x0")
        XCTAssertFalse(invalid.continueFromField(now: mid2027, calendar: calendar()))
        XCTAssertNil(invalid.pendingYear)
        XCTAssertEqual(DuoConsentFlow.NewCopy.bornIn(1990), "Born in 1990?", "no thousands separator")
    }

    // MARK: - The name

    func testTheNameIsTrimmedExactlyAsTheRequestCleansIt() {
        let samples = ["  Jo  ", "Mary\u{00A0}\u{00A0}Ann", "Sam\n", "\u{200B}Alex", "", "   ", String(repeating: "a", count: 30),
                       "e\u{0301}lise", "ශ්\u{200D}රී"]
        for raw in samples {
            XCTAssertEqual(DuoConsentFlow.trimmedName(raw), DuoState.cleanedName(raw), raw.debugDescription)
        }
        XCTAssertEqual(DuoConsentFlow.trimmedName("  Jo  "), "Jo")
    }

    func testAnEmptyNameIsSentAsNoName() {
        XCTAssertNil(DuoConsentFlow.nameForRequest(""))
        XCTAssertNil(DuoConsentFlow.nameForRequest("   \n "))
        XCTAssertNil(DuoConsentFlow.nameForRequest("\u{200B}"), "an invisible name is no name")
        XCTAssertEqual(DuoConsentFlow.nameForRequest("  Jo "), "Jo")
    }

    func testTheFieldCleansBeforeItCutsSoWhatItShowsIsWhatIsSent() {
        // Review 3 L5: the cut used to count raw characters.
        let pasted = String(repeating: " ", count: 12) + "Christopher Alexander Montgomery"
        XCTAssertEqual(DuoConsentFlow.nameForRequest(DuoConsentFlow.limitedInput(pasted)), "Christopher Alexander Mo")
        XCTAssertEqual(DuoConsentFlow.nameForRequest(DuoConsentFlow.limitedInput(String(repeating: "\u{200B}", count: 30) + "Jo")), "Jo")
        let samples = [pasted, "\u{202E}evil", "Jo\u{202E}nas\u{202C}", String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 30),
                       String(repeating: "\u{1F1EC}\u{1F1E7}", count: 25), "Jo\tAnn", String(repeating: "e\u{0301}", count: 30), "Mary\nAnn",
                       "  Mary   Ann  ", String(repeating: "b", count: 40), "\u{0007}Jo", "\u{E000}Jo"]
        for raw in samples {
            let kept = DuoConsentFlow.limitedInput(raw)
            XCTAssertLessThanOrEqual(kept.count, DuoState.maximumNameLength, raw.debugDescription)
            XCTAssertEqual(DuoState.cleanedName(kept), DuoState.cleanedName(raw), raw.debugDescription)
        }
    }

    func testTypingStillWorksOneCharacterAtATime() {
        XCTAssertEqual(DuoConsentFlow.limitedInput("Mary "), "Mary ", "a space at the end survives typing, or 'Mary Ann' could never be typed")
        XCTAssertEqual(DuoConsentFlow.limitedInput("Mary  "), "Mary ", "but only one")
        XCTAssertEqual(DuoConsentFlow.limitedInput(" "), "", "a name does not start with a space")
        XCTAssertEqual(DuoConsentFlow.limitedInput("ශ්\u{200D}"), "ශ්\u{200D}", "a joiner waits for the letter after it")
        XCTAssertEqual(DuoConsentFlow.limitedInput("Jo\tAnn"), "Jo Ann")
        let accented = String(repeating: "e\u{0301}", count: DuoState.maximumNameLength)
        XCTAssertEqual(DuoConsentFlow.limitedInput(accented + "x"), accented, "characters as a person sees them, not code points")
        XCTAssertEqual(DuoConsentFlow.limitedInput(String(repeating: "c", count: DuoState.maximumNameLength)).count, DuoState.maximumNameLength)
    }

    // MARK: - The button and what the form says

    func testTheConsentButtonWorksOnlyWhenAllowedAndIdle() {
        XCTAssertTrue(DuoConsentFlow.canConfirm(allowed: true, isWorking: false))
        XCTAssertFalse(DuoConsentFlow.canConfirm(allowed: true, isWorking: true))
        XCTAssertFalse(DuoConsentFlow.canConfirm(allowed: false, isWorking: false))
        XCTAssertFalse(DuoConsentFlow.canConfirm(allowed: false, isWorking: true))
    }

    func testADisabledButtonIsExplainedWithTheDuoScreensOwnBanner() {
        XCTAssertNil(DuoConsentFlow.writesBlockedMessage(.unknown))
        XCTAssertNil(DuoConsentFlow.writesBlockedMessage(.available))
        XCTAssertNil(DuoConsentFlow.writesBlockedMessage(.maintenance), "Create still works during maintenance")
        XCTAssertNil(DuoConsentFlow.writesBlockedMessage(.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))))
        for blocked: DuoAvailability in [.upgradeRequired, .disconnected, .banned] {
            XCTAssertFalse(blocked.allowsWrites)
            XCTAssertEqual(DuoConsentFlow.writesBlockedMessage(blocked), blocked.bannerMessage)
            XCTAssertNotNil(DuoConsentFlow.writesBlockedMessage(blocked), "\(blocked)")
        }
    }

    func testTheFormSaysOneThingAndNeverTheSameSentenceTwice() {
        let generic = "That did not work. Please try again."
        XCTAssertNil(DuoConsentFlow.formNotice(sheetError: nil, availability: .available))
        XCTAssertEqual(DuoConsentFlow.formNotice(sheetError: generic, availability: .available), .error(generic))
        XCTAssertEqual(DuoConsentFlow.formNotice(sheetError: generic, availability: .maintenance), .error(generic))
        for blocked: DuoAvailability in [.upgradeRequired, .disconnected, .banned] {
            let banner = blocked.bannerMessage ?? ""
            XCTAssertEqual(DuoConsentFlow.formNotice(sheetError: generic, availability: blocked), .unavailable(banner),
                           "no 'Please try again.' beside a button that cannot be tapped")
            XCTAssertEqual(DuoConsentFlow.formNotice(sheetError: banner, availability: blocked), .unavailable(banner), "said once")
            XCTAssertEqual(DuoConsentFlow.formNotice(sheetError: nil, availability: blocked), .unavailable(banner))
        }
    }

    // MARK: - The rules shown again

    func testTheRulesAreShownAgainOnlyOverALiveFormAndOnlyByTheTopmostOne() {
        for step in DuoConsentFlow.Step.allCases {
            for needsTerms in [false, true] {
                for live in [false, true] {
                    for topmost in [false, true] {
                        let shown = DuoConsentFlow.presentsTermsAgain(step: step, needsTerms: needsTerms, formIsLive: live, isTopmostForm: topmost)
                        XCTAssertEqual(shown, step == .form && needsTerms && live && topmost, "\(step) \(needsTerms) \(live) \(topmost)")
                    }
                }
            }
        }
    }

    // MARK: - What is said

    func testTheExplainerSaysEveryApprovedLineInOrderEachWithItsOwnSymbol() {
        for context: DuoConsentFlow.ExplainerContext in [.setup, .join, .reconnect] {
            let items = DuoConsentFlow.explainerShared(context)
            let lines = items.compactMap { item -> String? in if case .shared(let line, _) = item { return line }; return nil }
            let approved = lines.filter { DuoCopy.explainerLines.contains($0) }
            XCTAssertEqual(approved, DuoCopy.explainerLines, "\(context): every approved line, in order, word for word")
            let symbols = items.compactMap { item -> String? in if case .shared(_, let symbol) = item { return symbol }; return nil }
            XCTAssertEqual(Set(symbols).count, symbols.count, "\(context): a symbol of its own for every line")
            XCTAssertFalse(symbols.contains("checkmark"), "\(context): no tick beside a negative line")
        }
        let setup = DuoConsentFlow.explainerShared(.setup)
        XCTAssertEqual(setup.last, .shared("Never what you drank or exactly how much", symbol: "lock.fill"))
        XCTAssertEqual(setup[3], .shared("When your phone last updated each day", symbol: "clock"))
        XCTAssertEqual(setup[4], .shared("Your last week, from the moment you tap Create", symbol: "calendar"))
        XCTAssertEqual(DuoConsentFlow.explainerShared(.join)[4], .shared("Your last week, from the moment you tap Join", symbol: "calendar"))
        XCTAssertEqual(DuoConsentFlow.explainerShared(.reconnect).count, DuoCopy.explainerLines.count, "a reconnect sends no week")
        XCTAssertEqual(DuoConsentFlow.explainerHeading, "What your partner sees", "the iCloud version's heading, unchanged")
    }

    func testTheExplainerSaysTheHonestyLinesThenTheProcessorsAndTheRulesLink() {
        XCTAssertEqual(DuoConsentFlow.explainerNotes, [
            .note(DuoCopy.honestyLineStored),
            .note(DuoCopy.honestyLinePaired),
            .note(DuoConsentFlow.NewCopy.processors),
            .rulesLink(text: "Duo Streaks rules", url: DuoConsentFlow.termsURL),
        ])
        XCTAssertEqual(DuoConsentFlow.termsURL.absoluteString, "https://hydrodrop.us/terms.html")
        let processors = DuoConsentFlow.explainerNotes.firstIndex(of: .note(DuoConsentFlow.NewCopy.processors))
        XCTAssertEqual(processors.map { $0 + 1 }, DuoConsentFlow.explainerNotes.firstIndex { if case .rulesLink = $0 { return true }; return false },
                       "the rules link follows the processors directly")
    }

    private func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    }

    func testTheRulesKeepTheApprovedSentenceAndPromiseNothingTheServiceCannotDo() {
        let rules = DuoConsentFlow.termsRules
        XCTAssertEqual(rules.last, "If you break these rules, we may remove your name from Duo Streaks or bar you from using it.",
                       "TM1, approved 2026-10-02, word for word")
        XCTAssertTrue(rules.contains("We aim to act on every report within 24 hours."), "D85, decision d (2026-11-12)")
        XCTAssertFalse(rules.joined(separator: " ").contains("We act on reports"), "never the absolute promise")
        let all = rules.joined(separator: " ")
        XCTAssertTrue(all.contains("support@hydrodrop.us"))
        XCTAssertTrue(all.contains("under 13"))
        for rule in rules {
            let said = words(rule)
            // D55: no admin action ends a duo. TM2 waits for D54: no phone is flagged or barred yet.
            XCTAssertTrue(said.isDisjoint(with: ["end", "ends", "ended", "ending", "phone", "phones", "iphone", "device", "devices", "flag", "flagged", "apple"]),
                          rule)
        }
    }

    func testTheAgeScreenSaysNothingAboutWhichAnswerOpensTheFeature() {
        let lines = [DuoConsentFlow.NewCopy.ageTitle, DuoConsentFlow.NewCopy.ageQuestion, DuoConsentFlow.NewCopy.yearPlaceholder,
                     DuoConsentFlow.NewCopy.change, DuoConsentFlow.NewCopy.ageRefusal, DuoConsentFlow.NewCopy.bornIn(1990).replacingOccurrences(of: "1990", with: "")]
        for line in lines {
            XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits), "no age or year in the words: \(line)")
            XCTAssertTrue(words(line).isDisjoint(with: ["age", "old", "older", "young", "younger", "adult", "adults", "child", "children", "kid", "kids",
                                                        "teen", "teens", "parent", "parents", "minimum", "enough", "under", "over", "check", "allowed", "eligible"]),
                          line)
        }
    }

    /// Every placeholder this stage shows, word for word, so a change is a decision someone made
    /// (and the list Jonathon approves from) rather than a drift nobody noticed.
    func testEveryNewStringIsTheOneSubmittedForApproval() {
        typealias C = DuoConsentFlow.NewCopy
        XCTAssertEqual(C.ageTitle, "Before you start")
        XCTAssertEqual(C.ageQuestion, "What year were you born?")
        XCTAssertEqual(C.yearPlaceholder, "Year")
        XCTAssertEqual(C.bornIn(2001), "Born in 2001?")
        XCTAssertEqual(C.change, "Change")
        XCTAssertEqual(C.ageRefusal, "Duo Streaks is not available on this iPhone.")
        XCTAssertEqual(C.processors, "Our service runs on Cloudflare. Apple delivers notifications, vouches that this is a real copy of HydroDrop, and keeps a note for us, tied to this iPhone, that it has used Duo Streaks, which stays even if the iPhone is erased.")
        XCTAssertEqual(C.lastWeek(.setup), "Your last week, from the moment you tap Create")
        XCTAssertEqual(C.lastWeek(.join), "Your last week, from the moment you tap Join")
        XCTAssertNil(C.lastWeek(.reconnect))
        XCTAssertEqual(C.rulesTitle, "Duo Streaks rules")
        XCTAssertEqual(C.fullRulesLink, "Read the full rules")
        XCTAssertEqual(C.noOffensiveNames, "No offensive names and no harassment. We do not tolerate either.")
        XCTAssertEqual(C.notUnder13, "Duo Streaks is not for anyone under 13.")
        XCTAssertEqual(C.howToReport, "Report a problem from the Duo Streaks screen, or email support@hydrodrop.us.")
        XCTAssertEqual(C.reportsActedOn, "We aim to act on every report within 24 hours.")
        XCTAssertEqual(C.acceptanceLine, "By tapping Accept you agree to the Duo Streaks rules.")
        XCTAssertEqual(C.accept, "Accept")
        XCTAssertEqual(C.inProgress, "In progress")
        XCTAssertEqual(DuoConsentFlow.termsRules, [C.noOffensiveNames, C.notUnder13, C.howToReport, C.reportsActedOn, DuoConsentFlow.ruleBreakingLine])
    }
}
