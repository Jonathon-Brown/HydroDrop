import Foundation

/// What the three consent sheets (start a duo, join one, reconnect) show before the first request
/// this phone ever makes, decided here so `swift test` can hold it and the views only draw the
/// answer (plan P2 stage I; final design §3.1, §11.8, §12.6, §12.7).
///
/// The order is the rule. The birth-year screen comes first, so someone under the minimum age
/// never reads past it; then the Duo Streaks rules, accepted on a screen of their own before the
/// form that holds the name field (section-compliance §2.5 and §3.4: "accepted before a name can
/// be entered"); and only then the form whose button is the consent (§3.1). A refusal wins over
/// everything and is final. The contract's `terms_version` on `POST /devices` means the version
/// the person accepted, which a tap on Create alone never showed them, so acceptance is a real
/// step rather than something read into the tap (foundation note 11; D80 keeps the separate Accept).
public enum DuoConsentFlow {
    /// Which screen a consent sheet is on.
    public enum Step: String, Equatable, Sendable, CaseIterable {
        /// The age is not known yet: the neutral birth-year screen.
        case askAge
        /// The birth-year screen refused the person. Final: only a way out is offered.
        case refused
        /// Old enough, but the current rules have not been accepted on this phone.
        case terms
        /// The consent form itself, the only place a Create, Join or Reconnect button exists.
        case form
    }

    /// The step for what this phone holds. `acceptedTermsVersion` is `DuoStore.acceptedTermsVersion`,
    /// the version the person accepted here (0 for none), which the mint sends as `terms_version`.
    ///
    /// A `428 terms_required` met on the form is not a step: it is a sheet over the form
    /// (`presentsTermsAgain`), so a name the person has typed survives it.
    public static func step(ageStatus: DuoAgeStatus, acceptedTermsVersion: Int) -> Step {
        switch ageStatus {
        case .refused: return .refused
        case .unknown: return .askAge
        case .allowed: return acceptedTermsVersion >= DuoProtocolConstants.termsVersion ? .form : .terms
        }
    }

    // MARK: - The birth-year screen

    /// The year is typed, four digits, into an empty field (D80). It used to be a wheel whose
    /// blank first row sat directly above the thirteen refusing years, so a flick still slowing
    /// when Continue was tapped, or VoiceOver's one row per swipe, recorded a year the person never
    /// chose, and a refusal is final for everyone who uses that iPhone.
    public static let yearDigits = 4

    /// How far back from this year a typed year is believed. Nobody living was born earlier, and
    /// `DuoAgeGate.decide` reads anything before 1900 as unreadable anyway.
    public static let plausibleAgeSpan = 100

    /// This year as the age rule reads it: Gregorian whatever calendar the phone uses (keeping only
    /// its time zone), and never earlier than `DuoAgeGate.earliestPlausibleYear`, so a clock set to
    /// 2001 neither refuses an adult nor rejects the years since. A typed year is judged against
    /// the same year the rule will use, so a year the field accepts is always an answer the rule
    /// can give, never the "unreadable" that would make the screen ask again.
    public static func currentYear(now: Date, calendar: Calendar) -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return max(gregorian.component(.year, from: now), DuoAgeGate.earliestPlausibleYear)
    }

    /// The years a typed answer may be: this year and the hundred before it, never before 1900.
    public static func plausibleBirthYears(now: Date, calendar: Calendar) -> ClosedRange<Int> {
        let thisYear = currentYear(now: now, calendar: calendar)
        return max(thisYear - plausibleAgeSpan, 1900)...thisYear
    }

    /// Keep the whole input visible. Cutting a paste to four characters used to turn malformed
    /// text such as "2019 " into a valid answer with a permanent consequence.
    public static func limitedYearInput(_ raw: String) -> String {
        raw
    }

    /// The year in the field, or nil while Continue must stay off: exactly four decimal digits (in
    /// any script the keyboard types, Arabic-Indic and full-width included, never letters, spaces,
    /// signs or superscripts) that make a plausible year. Nothing says why a year is not accepted:
    /// a message would hint at what the screen is looking for.
    public static func typedYear(_ text: String, now: Date, calendar: Calendar) -> Int? {
        guard text.count == yearDigits else { return nil }
        var year = 0
        for character in text {
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
                  scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue else { return nil }
            year = year * 10 + Int(value)
        }
        return plausibleBirthYears(now: now, calendar: calendar).contains(year) ? year : nil
    }

    /// The birth-year screen's two phases: the field, and after Continue the confirmation
    /// "Born in <year>?" with Continue and Change, shown after every answer whatever the year so
    /// that it says nothing about which years pass (D80). Only the confirmation's Continue hands a
    /// year over to be recorded; the year itself lives here, in memory, while the screen is up.
    // Legacy year-only helper retained for historical pure conformance tests; app entry uses BirthEntry.
    public struct AgeEntry: Equatable, Sendable {
        /// What is in the field.
        public private(set) var typed = ""
        /// The year waiting for the person to confirm it, or nil while the field is showing.
        public private(set) var pendingYear: Int?

        public init() {}

        /// The field changed.
        public mutating func type(_ raw: String) {
            let next = limitedYearInput(raw)
            if next != typed { pendingYear = nil }
            typed = next
        }

        public func canContinue(now: Date, calendar: Calendar) -> Bool {
            pendingYear == nil && typedYear(typed, now: now, calendar: calendar) != nil
        }

        /// Continue under the field: asks "Born in <year>?" and records nothing.
        @discardableResult
        public mutating func continueFromField(now: Date, calendar: Calendar) -> Bool {
            guard canContinue(now: now, calendar: calendar), let year = typedYear(typed, now: now, calendar: calendar) else { return false }
            pendingYear = year
            return true
        }

        /// Change: back to the field, with what was typed still in it.
        public mutating func change() {
            pendingYear = nil
        }

        /// Continue on the confirmation: the year to record, once. The field and the year are
        /// forgotten here, whatever the answer turns out to be.
        public mutating func takeConfirmedYear() -> Int? {
            guard let year = pendingYear else { return nil }
            pendingYear = nil
            typed = ""
            return year
        }
    }

    /// Month and year remain transient. Every edit invalidates confirmation, and its answer
    /// can be consumed only once. Invalid pasted text is never shortened into a valid answer.
    public struct BirthEntry: Equatable, Sendable {
        public private(set) var monthText = ""
        public private(set) var yearText = ""
        public private(set) var pending: BirthAnswer?
        public init() {}
        public mutating func typeMonth(_ text: String) { monthText = text; pending = nil }
        public mutating func typeYear(_ text: String) { yearText = text; pending = nil }
        public func answer(now: Date, calendar: Calendar) -> BirthAnswer? {
            guard (1...2).contains(monthText.count),
                  let month = decimal(monthText), (1...12).contains(month),
                  let year = typedYear(yearText, now: now, calendar: calendar),
                  DuoAgeGate.decide(birthYear: year, birthMonth: month, now: now, calendar: calendar) != .unknown
            else { return nil }
            return BirthAnswer(year: year, month: month)
        }
        public func canContinue(now: Date, calendar: Calendar) -> Bool { pending == nil && answer(now: now, calendar: calendar) != nil }
        @discardableResult public mutating func confirm(now: Date, calendar: Calendar) -> Bool {
            guard canContinue(now: now, calendar: calendar) else { return false }
            pending = answer(now: now, calendar: calendar)
            return true
        }
        public mutating func change() { pending = nil }
        public mutating func take() -> BirthAnswer? {
            guard let answer = pending else { return nil }
            pending = nil; monthText = ""; yearText = ""
            return answer
        }
        private func decimal(_ text: String) -> Int? {
            var result = 0
            for c in text {
                guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first,
                      s.properties.numericType == .decimal, let value = s.properties.numericValue else { return nil }
                result = result * 10 + Int(value)
            }
            return result
        }
    }
    public struct BirthAnswer: Equatable, Sendable {
        public let year: Int
        public let month: Int
        fileprivate init(year: Int, month: Int) { self.year = year; self.month = month }
        public var confirmation: String {
            let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            return "Born in \(names[month - 1]) \(year)?"
        }
    }

    // MARK: - The name field

    /// The name as the request will carry it: `DuoState.cleanedName`, so what the field shows
    /// once tidied and what the server is sent are the same text.
    public static func trimmedName(_ raw: String) -> String {
        DuoState.cleanedName(raw)
    }

    /// What a Create or Join tap sends as the name: the trimmed name, or nil when nothing is left
    /// (the name is optional, §4.3).
    public static func nameForRequest(_ raw: String) -> String? {
        let trimmed = trimmedName(raw)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the name field keeps of what was typed or pasted. It is cleaned the way the request is
    /// before it is cut to `DuoState.maximumNameLength` characters as a person sees them: spaces at
    /// the start go, a run of spaces, tabs or line breaks becomes one space, and characters that
    /// draw nothing (zero-width spaces, direction marks, controls) go. The cut used to count the
    /// raw text, so twelve pasted spaces and a long name sent "Christopher", and thirty zero-width
    /// spaces before "Jo" sent no name at all. One space at the end is kept, or "Mary Ann" could
    /// not be typed; the two joiners are kept too, as cleaning keeps them between letters, since
    /// the letter after one may not have been typed yet.
    public static func limitedInput(_ raw: String) -> String {
        let lineBreaksAndTabs: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        let joiners: Set<UInt32> = [0x200C, 0x200D]
        var kept = String.UnicodeScalarView()
        var afterSpace = true
        for scalar in raw.unicodeScalars {
            if lineBreaksAndTabs.contains(scalar.value) || scalar.value == 0x20 || scalar.properties.generalCategory == .spaceSeparator {
                if !afterSpace { kept.append(" ") }
                afterSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .unassigned:
                continue
            case .format where !joiners.contains(scalar.value):
                continue
            default:
                kept.append(scalar)
                afterSpace = false
            }
        }
        let text = String(kept)
        return text.count > DuoState.maximumNameLength ? String(text.prefix(DuoState.maximumNameLength)) : text
    }

    // MARK: - The form's button and what it says

    /// Whether the consent button may be tapped: writes are allowed (for a reconnect,
    /// `DuoAvailability.allowsReconnect`) and nothing is already under way.
    public static func canConfirm(allowed: Bool, isWorking: Bool) -> Bool {
        allowed && !isWorking
    }

    /// The line a consent form shows when writes are off, so a disabled button is never left
    /// without a word: the Duo screen's own banner for that state. Nil while writes are allowed
    /// (a maintenance banner is the Duo screen's, and Create still works then), and nil during the
    /// restore question, which has no banner and is asked on the Duo screen.
    public static func writesBlockedMessage(_ availability: DuoAvailability) -> String? {
        availability.allowsWrites ? nil : availability.bannerMessage
    }

    /// The one thing a consent form says above its button.
    public enum FormNotice: Equatable, Sendable {
        /// The last request's failure, in `DuoUserMessage`'s words.
        case error(String)
        /// Why the button is off: the Duo screen's own banner.
        case unavailable(String)
    }

    /// What the form says: only the banner while writes are off, since a failure's words beside a
    /// button that cannot be tapped ask for a retry that cannot happen, and after a 426, a ban or a
    /// disconnection the failure's words are the banner's own, which said the same sentence twice;
    /// otherwise the last failure, if any.
    public static func formNotice(sheetError: String?, availability: DuoAvailability) -> FormNotice? {
        if let blocked = writesBlockedMessage(availability) { return .unavailable(blocked) }
        return sheetError.map { .error($0) }
    }

    // MARK: - The rules shown again

    /// Whether a gate presents the rules as a sheet over its form. Only for a `428 terms_required`
    /// (`DuoStore.needsTerms`) that this form's own request met, so not before the form has
    /// appeared (`formIsLive`: a flag left up by a request from a sheet that has since gone would
    /// otherwise bring the rules up over a form nobody has tapped, and Accept would send its
    /// request), and only by the consent form on top (`isTopmostForm`): when one consent sheet is
    /// drawn inside another, the one the person tapped is the one on top, two sheets asked for at
    /// once drop one, and the other gate's Accept would send the other sheet's request.
    public static func presentsTermsAgain(step: Step, needsTerms: Bool, formIsLive: Bool, isTopmostForm: Bool) -> Bool {
        step == .form && needsTerms && formIsLive && isTopmostForm
    }

    // MARK: - What is said before the consent tap

    /// The page the rules link opens (final design §11.8: `docs/terms.html`, "Duo Streaks rules").
    public static let termsURL = URL(string: "https://hydrodrop.us/terms.html")!

    /// The heading above the explainer's first section: the iCloud version's section header,
    /// unchanged (§12.7 changes the lines under it, not the heading). The same for every sheet.
    public static let explainerHeading = "What your partner sees"

    /// Which consent sheet the explainer is on: it changes only the line about the week that goes
    /// up at the tap, which names that sheet's button.
    public enum ExplainerContext: Equatable, Sendable {
        case setup
        case join
        case reconnect
    }

    /// One thing the explainer says.
    public enum ExplainerItem: Equatable, Sendable {
        /// A line of what is shared, with the SF Symbol drawn beside it.
        case shared(String, symbol: String)
        /// A plain line: the two honesty lines and the processors.
        case note(String)
        /// The link to the rules, in a row of its own.
        case rulesLink(text: String, url: URL)
    }

    /// The symbols beside `DuoCopy.explainerLines`, in order. The iCloud version gave each line its
    /// own; six checkmarks put a tick beside "Never what you drank or exactly how much".
    public static let explainerSymbols = ["drop.fill", "checkmark.circle.fill", "chart.bar.fill", "clock", "square.and.pencil", "lock.fill"]
    public static let lastWeekSymbol = "calendar"

    /// The explainer's first section, under "What your partner sees": every approved line, word for
    /// word and in order, with its own symbol, and on the setup and join sheets the line saying
    /// that the last week goes up at the tap (the create and the redeem both carry it; a reconnect
    /// carries no rows) after the line about when the phone last updated.
    public static func explainerShared(_ context: ExplainerContext) -> [ExplainerItem] {
        var items = zip(DuoCopy.explainerLines, explainerSymbols).map { ExplainerItem.shared($0, symbol: $1) }
        if let lastWeek = NewCopy.lastWeek(context) {
            items.insert(.shared(lastWeek, symbol: lastWeekSymbol), at: 4)
        }
        return items
    }

    /// The explainer's second section, with no header: the two honesty lines, the processors and
    /// the rules link, which follows the processors directly so neither is ever shown without the
    /// other (§3.1: "a sheet that shows the explainer, the two honesty lines and the processor
    /// names"). The view adds the privacy policy's link after the rules link.
    public static let explainerNotes: [ExplainerItem] = [
        .note(DuoCopy.honestyLineStored), .note(DuoCopy.honestyLinePaired), .note(NewCopy.processors),
        .rulesLink(text: NewCopy.rulesTitle, url: termsURL),
    ]

    /// section-compliance TM1, approved by Jonathon on 2026-10-02 and kept word for word. It
    /// releases with the admin Worker (Stage 17), which is what can remove a name or bar someone.
    public static let ruleBreakingLine = "If you break these rules, we may remove your name from Duo Streaks or bar you from using it."

    /// The Duo Streaks rules, as the rules sheet lists them: a short version of `docs/terms.html`
    /// (section-compliance §1.8), linked in full below the list. No offensive names or harassment
    /// (Apple's guideline 1.2 asks for no tolerance of either), who it is not for, how to report and
    /// how fast reports are acted on, then TM1. Never that we may end a duo (D55: no admin action
    /// ends one) and never that a phone may be flagged or barred (TM2 waits for the D54 change).
    public static let termsRules = [
        NewCopy.noOffensiveNames,
        NewCopy.notUnder13,
        NewCopy.howToReport,
        NewCopy.reportsActedOn,
        ruleBreakingLine,
    ]

    /// Wording no one has approved yet: the plain placeholders for stage I, each waiting for
    /// Jonathon's approval before it ships (listed in the stage's report). Everything else these
    /// screens say comes from `DuoCopy`, `DuoUserMessage`, `DuoAvailability`, the iCloud version's
    /// views or the app's existing chrome, word for word.
    public enum NewCopy {
        // NEW COPY: the birth-year screen. Neutral on purpose: nothing here says what age is
        // asked for or what answer opens the feature (§12.6).
        public static let ageTitle = "Before you start"
        // NEW COPY: the question, and the field's VoiceOver label (the visible line is not read too).
        public static let ageQuestion = "What year were you born?"
        // NEW COPY: the empty field's placeholder.
        public static let yearPlaceholder = "Year"
        public static let monthPlaceholder = "Month"
        public static let monthLabel = "Birth month"
        public static let monthYearQuestion = "What month and year were you born?"
        // NEW COPY (D80): the confirmation shown after every answer, whatever the year.
        public static func bornIn(_ year: Int) -> String { "Born in \(year)?" }
        // NEW COPY (D80): the confirmation's way back to the field.
        public static let change = "Change"
        // NEW COPY: shown in place of the question after a refusal, which is final and kept per
        // iPhone (the defaults and a ThisDeviceOnly Keychain item), so it says so.
        public static let ageRefusal = "Duo Streaks is not available on this iPhone."

        // NEW COPY: the processors line on the consent sheets (§3.1), naming DeviceCheck's part:
        // the server sets bit0 on every mint and Apple keeps it with the iPhone.
        public static let processors = "Our service runs on Cloudflare. Apple delivers notifications, checks that this is a real copy of HydroDrop, and keeps a note on this iPhone that it has used Duo Streaks."

        // NEW COPY: the explainer's line about the week sent at the tap, naming the sheet's button
        // ("Create" for the setup sheet; "Join" for the join sheet is this placeholder's extension).
        public static func lastWeek(_ context: ExplainerContext) -> String? {
            switch context {
            case .setup: return "Your last week, from the moment you tap Create"
            case .join: return "Your last week, from the moment you tap Join"
            case .reconnect: return nil
            }
        }

        // NEW COPY: the rules sheet's title and the explainer's link to the rules page.
        public static let rulesTitle = "Duo Streaks rules"
        // NEW COPY: the rules sheet's link to the full page (it used to repeat the title).
        public static let fullRulesLink = "Read the full rules"

        // NEW COPY: the rules, the plain version of section-compliance §1.8's outline.
        public static let noOffensiveNames = "No offensive names and no harassment. We do not tolerate either."
        // NEW COPY
        public static let notUnder13 = "Duo Streaks is not for anyone under 13."
        // NEW COPY
        public static let howToReport = "Report a problem from the Duo Streaks screen, or email support@hydrodrop.us."
        // NEW COPY: waits for the admin Worker (Stage 17), like TM1. Kept exactly as it is until
        // Jonathon decides between it and "We aim to act on every report within 24 hours."
        public static let reportsActedOn = "We act on reports within 24 hours."

        // NEW COPY: the line above Accept saying what the tap is (section-compliance §2.5, P7a:
        // the service records that the person accepted the rules, which version and when).
        public static let acceptanceLine = "By tapping Accept you agree to the Duo Streaks rules."
        // NEW COPY: the rules sheet's button.
        public static let accept = "Accept"

        // NEW COPY: what VoiceOver says of Accept and Create while their request is out.
        public static let inProgress = "In progress"
    }
}
