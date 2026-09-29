import Foundation

// A duo is one shared streak with one other person. Everything in this file is a value
// type with no CloudKit in it, so the app, the tests and later a widget can all read a
// duo without being able to reach the network.

/// Which side of a duo someone is on. The owner is whoever sent the invite. It carries no
/// rank: both sides see and do exactly the same things.
enum DuoRole: String, Codable, CaseIterable {
    case owner
    case partner

    var other: DuoRole { self == .owner ? .partner : .owner }
}

/// Everything one person shares about one day, and the whole of it.
///
/// No amounts, no drinks, no times of day, nothing from Night Out, caffeine or Health.
/// Progress is rounded down to a quarter on purpose: enough to draw a face with, not
/// enough to work out what anyone drank.
struct DuoDayStatus: Codable, Equatable {
    var role: DuoRole
    /// `yyyy-MM-dd` in the calendar of whoever wrote it. See `DayKey`.
    var day: String
    var goalMet: Bool
    /// 0, 25, 50, 75 or 100.
    var progressBucket: Int
    var updatedAt: Date

    var recordName: String { DuoRecordName.dayStatus(role: role, day: day) }

    /// Whether `other` says the same thing about the same day. When it was written is
    /// not part of what it says.
    func saysTheSame(as other: DuoDayStatus) -> Bool {
        role == other.role && day == other.day && goalMet == other.goalMet && progressBucket == other.progressBucket
    }
}

/// How a day's status is named.
///
/// A day's status is named after whose it is and which day, so writing it twice is
/// writing the same record twice: an upsert, never a duplicate, however many times a
/// retry or a second device repeats it. The names outlived the iCloud records they were
/// made for: Duo v2 keeps them as the keys of the per-day version map that decides whose
/// write is newer (final design §14).
///
/// This used to name each duo's CloudKit zone too (`Duo-<uuid>`) and the one `Duo`
/// record in it, and turned a zone name back into a duo. Duo v2 has no zones, so those
/// are gone.
enum DuoRecordName {
    static func dayStatus(role: DuoRole, day: String) -> String { "\(role.rawValue)-\(day)" }

    /// Reads a status's name back. Nil for any other key, including ones a newer version
    /// of the app may add later.
    static func parseDayStatus(_ recordName: String) -> (role: DuoRole, day: String)? {
        guard let dash = recordName.firstIndex(of: "-"),
              let role = DuoRole(rawValue: String(recordName[..<dash])) else { return nil }
        let day = String(recordName[recordName.index(after: dash)...])
        guard DuoStreak.isDayKey(day) else { return nil }
        return (role, day)
    }
}

/// Turns a day's total into the two things that are shared about it.
enum DuoProgress {
    static let buckets = [0, 25, 50, 75, 100]

    /// Progress towards the goal, rounded down to a quarter.
    ///
    /// Measured against the saved goal, as the solo streak is, not against a target
    /// raised for a hot day. That keeps "goal met" and a full bucket the same moment,
    /// and means saying yes to extra water can never cost a partner the shared streak.
    static func bucket(totalML: Int, goalML: Int) -> Int {
        guard goalML > 0, totalML > 0 else { return 0 }
        let quarters = min(4, (totalML * 4) / goalML)
        return quarters * 25
    }

    static func goalMet(totalML: Int, goalML: Int) -> Bool {
        goalML > 0 && totalML >= goalML
    }

    /// What a mascot should be drawn at for a bucket.
    static func fraction(forBucket bucket: Int) -> Double {
        Double(min(max(bucket, 0), 100)) / 100
    }

    static func status(role: DuoRole, day: String, totalML: Int, goalML: Int, now: Date) -> DuoDayStatus {
        DuoDayStatus(
            role: role,
            day: day,
            goalMet: goalMet(totalML: totalML, goalML: goalML),
            progressBucket: bucket(totalML: totalML, goalML: goalML),
            updatedAt: now
        )
    }

    /// One short line for a day's status. Nil reads as a day nobody has heard about yet.
    static func line(for status: DuoDayStatus?) -> String {
        guard let status else { return "Nothing yet today" }
        if status.goalMet { return "Goal met" }
        switch status.progressBucket {
        case ..<25: return "Just getting started"
        case ..<50: return "A quarter of the way"
        case ..<75: return "Halfway there"
        default: return "Almost there"
        }
    }
}

/// One duo, as this device last saw it.
struct DuoState: Codable, Equatable, Identifiable {
    var id: UUID
    var zoneName: String
    /// Who the zone belongs to, as CloudKit names them. Needed to find the zone again
    /// from the partner's side, where it lives in someone else's iCloud.
    var zoneOwnerName: String
    var myRole: DuoRole
    var createdAt: Date
    /// First names, typed in by each person during setup. Never read from iCloud.
    var ownerDisplayName: String
    var partnerDisplayName: String
    var ownerSkin: String
    var partnerSkin: String
    var statuses: [DuoDayStatus]
    /// The invite link, once there is one. Only the owner has it.
    var shareURL: URL?
    var partnerHasJoined: Bool
    /// Set when the other side left or the duo was deleted. The duo stays on screen,
    /// saying so, until it is cleared by hand.
    var endedAt: Date?
    /// Where the last read of the zone left off, as iCloud handed it over. Kept beside
    /// what that read brought back, so the two can never be saved apart.
    var changeToken: Data?
    /// The last couple of days of nudges, from both sides. Optional so that a cache
    /// written before nudges existed still reads.
    var nudges: [DuoNudge]?

    var allNudges: [DuoNudge] { nudges ?? [] }

    var hasEnded: Bool { endedAt != nil }
    /// Waiting for the invite to be accepted.
    var isPending: Bool { myRole == .owner && !partnerHasJoined && !hasEnded }

    func displayName(of role: DuoRole) -> String {
        let name = role == .owner ? ownerDisplayName : partnerDisplayName
        return name.isEmpty ? "Your partner" : name
    }

    func skinRawValue(of role: DuoRole) -> String {
        role == .owner ? ownerSkin : partnerSkin
    }

    func status(of role: DuoRole, on day: String) -> DuoDayStatus? {
        statuses.first { $0.role == role && $0.day == day }
    }

    /// Puts `status` in place of whatever was known about that person's day.
    mutating func upsert(_ status: DuoDayStatus) {
        if let index = statuses.firstIndex(where: { $0.role == status.role && $0.day == status.day }) {
            statuses[index] = status
        } else {
            statuses.append(status)
        }
    }

    /// A first name as it is stored: one line, no invisible characters, and short enough
    /// for the card. Empty means no name, which is shown as "Your partner".
    ///
    /// The server, the Android app and this one all clean a name the same way, step for
    /// step, and the server's result is the one everybody displays. The steps, in order:
    /// compose to NFC; turn tabs and line breaks into spaces; drop control, format,
    /// private-use and unassigned characters, except a joiner between two letters or
    /// marks; turn every run of spaces into one; trim; compose again; keep the first 24
    /// characters as a person sees them (grapheme clusters, so an emoji or an accented
    /// letter is one); trim once more, and drop a joiner the cut left at the end. Cleaning
    /// a cleaned name changes nothing (final design §8.8).
    ///
    /// It used to split on newlines and join with a space, which turned a pasted
    /// "a\r\nb" into "a  b" with two spaces, and it left zero-width and right-to-left
    /// override characters in. Those let a name look like someone else's or run
    /// backwards across the card.
    ///
    /// Invisible characters are dropped before spaces are collapsed and trimmed, not
    /// after. The other way round, a zero-width space next to a real one survived as a
    /// stray space: "\u{200B} Sam" came out as " Sam". Composing again at the end rejoins
    /// a letter and its accent that had something invisible between them.
    ///
    /// The two joiners, U+200C and U+200D, are format characters but are kept between two
    /// letters or marks, because there they are part of how a name is spelled: U+200C in
    /// Persian, U+200D in Sinhala (as in ශ්‍රී) and other Indic scripts. Dropping them there
    /// silently respells the name. Anywhere else, at an edge, next to a space or on their
    /// own, they spell nothing and would leave an invisible name, so they go. The server's
    /// name check allows them in the same places (§11.5, as Phase 1 erratum 2 amended it),
    /// and it rejects emoji whatever cleaning keeps.
    static func cleanedName(_ raw: String) -> String {
        let lineBreaksAndTabs: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        let joiners: Set<UInt32> = [0x200C, 0x200D]

        var visible: [Unicode.Scalar] = []
        for scalar in composed(raw).unicodeScalars {
            if lineBreaksAndTabs.contains(scalar.value) {
                visible.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .unassigned:
                continue
            case .format where !joiners.contains(scalar.value):
                continue
            default:
                visible.append(scalar)
            }
        }

        var spelled = String.UnicodeScalarView()
        for (index, scalar) in visible.enumerated() {
            if joiners.contains(scalar.value) {
                let next = index + 1 < visible.count ? visible[index + 1] : nil
                guard isLetterOrMark(spelled.last), isLetterOrMark(next) else { continue }
            }
            spelled.append(scalar)
        }

        var spaced = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in spelled {
            if scalar.value == 0x20 || scalar.properties.generalCategory == .spaceSeparator {
                if !lastWasSpace { spaced.append(" ") }
                lastWasSpace = true
            } else {
                spaced.append(scalar)
                lastWasSpace = false
            }
        }
        let trimmed = String(spaced).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        // Cutting at 24 can end on the space before a word that didn't fit, so what is
        // left is trimmed once more.
        //
        // It can also end on a joiner. A joiner belongs to the character before it as a
        // person sees it, so when the letter after it falls past the cut, the joiner is
        // kept and ends the name. The cut used to stop there, which meant 23 × "a" +
        // "b\u{200D}c" came out as 23 × "a" + "b\u{200D}", a name the server's check
        // refuses and that cleaning a second time turns into 23 × "a" + "b". So a final
        // joiner goes too. A joiner is only ever kept between two letters or marks, so
        // there is no space before it for the trim to have missed.
        let cut = String(composed(trimmed).prefix(maximumNameLength))
        var ending = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ")).unicodeScalars
        if let last = ending.last, joiners.contains(last.value) { ending.removeLast() }
        return String(ending)
    }

    private static func isLetterOrMark(_ scalar: Unicode.Scalar?) -> Bool {
        switch scalar?.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// `text` in NFC, the composed form every side compares names in.
    ///
    /// Foundation's own NFC gets a few inputs wrong: it leaves 가 followed by a trailing
    /// ㄱ (U+AC00 U+11A8) apart instead of making 각 (U+AC01), misses a Kannada
    /// composition, and turns an Old Hangul pair into a different syllable. Decomposing
    /// first fixes the first two. For the third, each character, as a person sees it, is
    /// composed on its own and the result kept only if it decomposes back to exactly what
    /// the original does; otherwise that one character is kept as written, which is what
    /// ICU (the server and Android) does with it. Checking character by character keeps
    /// one odd character from leaving the rest of the name uncomposed, and comparing
    /// decompositions avoids Swift's `==`, which gets some Tibetan vowel signs wrong.
    ///
    /// Three Tibetan vowel signs, U+0F73, U+0F75 and U+0F81, are split into their two
    /// parts by hand first. NFC never contains them. Foundation does split them, but after
    /// a combining mark of a higher class, Tibetan marks included, it leaves the two halves
    /// where the sign was instead of moving them in front of that mark as NFC's ordering
    /// requires: U+0F40 U+0301 U+0F73 comes out as U+0F40 U+0301 U+0F71 U+0F72, where NFC
    /// (and ICU) give U+0F40 U+0F71 U+0F72 U+0301, and U+0F40 U+0F80 U+0F73 as U+0F40
    /// U+0F80 U+0F71 U+0F72, where NFC gives U+0F40 U+0F71 U+0F80 U+0F72. Split beforehand,
    /// the halves are ordinary marks and are put in order. This comment used to say
    /// Foundation left the signs whole after marks of another script, which was not what
    /// happens.
    static func composed(_ text: String) -> String {
        let alwaysSplit: [UInt32: [UInt32]] = [0x0F73: [0x0F71, 0x0F72], 0x0F75: [0x0F71, 0x0F74], 0x0F81: [0x0F71, 0x0F80]]
        var split = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let parts = alwaysSplit[scalar.value] {
                split.append(contentsOf: parts.compactMap(Unicode.Scalar.init))
            } else {
                split.append(scalar)
            }
        }

        var result = String.UnicodeScalarView()
        for character in String(split) {
            let piece = String(character)
            let candidate = piece.decomposedStringWithCanonicalMapping.precomposedStringWithCanonicalMapping
            let keepsMeaning = Array(candidate.decomposedStringWithCanonicalMapping.unicodeScalars)
                == Array(piece.decomposedStringWithCanonicalMapping.unicodeScalars)
            result.append(contentsOf: (keepsMeaning ? candidate : piece).unicodeScalars)
        }
        return String(result)
    }

    static let maximumNameLength = 24
}

/// The shared streak: consecutive days on which both people met their own goal.
///
/// Days are compared as the strings each person wrote, never as instants. Someone in
/// Tokyo and someone in Los Angeles both have a "2026-09-21", they live through it at
/// different times, and it is the same day of the streak for both of them.
enum DuoStreak {
    /// Day-key arithmetic happens in a fixed calendar, so no daylight saving change
    /// anywhere can make a day go missing or arrive twice.
    private static let arithmetic: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// The last place on Earth a day ends: twelve hours behind UTC.
    private static let lastPlace: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -12 * 3600) ?? .gmt
        return calendar
    }()

    /// Whether `text` is a real day, written the way `DayKey` writes one, in the year 2000
    /// or later. Calendars are forgiving about a thirteenth month, so the day is written
    /// back out and compared.
    ///
    /// The year is the wire's rule (final design §6.0 and §8.4): the server stores no
    /// earlier day, so a phone that kept one would be counting a day nobody else has. This
    /// used to accept any year the calendar could write, which meant 1999-12-31 and even
    /// 0001-01-01 were read as days.
    static func isDayKey(_ text: String) -> Bool {
        guard text.count == 10, let date = DayKey.date(from: text, calendar: arithmetic),
              DayKey.key(for: date, calendar: arithmetic) == text else { return false }
        // Written back out the same, so the calendar's year is the one in the text.
        return arithmetic.component(.year, from: date) >= earliestYear
    }

    /// The first year a day key can be in.
    static let earliestYear = 2000

    /// Whether `day` is over everywhere, so nobody can still be living through it.
    static func isOverEverywhere(_ day: String, now: Date) -> Bool {
        guard let next = DayKey.nextDayKey(after: day, calendar: arithmetic),
              let end = DayKey.date(from: next, calendar: lastPlace) else { return false }
        return now >= end
    }

    /// Whether `role` could still meet their goal on `day`.
    ///
    /// My own day is over when my calendar says so. My partner's time zone is not
    /// shared, so their day counts as over once they have written a later one, or once
    /// it is over everywhere, whichever comes first.
    static func isStillOpen(
        _ day: String,
        for role: DuoRole,
        statuses: [DuoDayStatus],
        myRole: DuoRole,
        myToday: String,
        now: Date
    ) -> Bool {
        if role == myRole { return day >= myToday }
        if statuses.contains(where: { $0.role == role && $0.day > day }) { return false }
        return !isOverEverywhere(day, now: now)
    }

    /// Nobody on Earth is more than two calendar days ahead of anybody else, so a day
    /// further off than that is a mistake or a fib. It is not counted, not walked back
    /// from, not shown, and not taken as a sign that anyone has moved on from today.
    static func plausible(_ statuses: [DuoDayStatus], myToday: String) -> [DuoDayStatus] {
        let furthest = DayKey.date(from: myToday, calendar: arithmetic)
            .flatMap { arithmetic.date(byAdding: .day, value: 2, to: $0) }
            .map { DayKey.key(for: $0, calendar: arithmetic) } ?? myToday
        return statuses.filter { $0.day <= furthest }
    }

    /// The current shared streak.
    ///
    /// Walks back from the newest day anyone has. A day both people met counts. A day
    /// someone has not met but still could is stepped over, so a day in progress for
    /// either person never breaks the streak. Anything else ends it. Streak freezes
    /// play no part here.
    static func current(statuses all: [DuoDayStatus], myRole: DuoRole, myToday: String, now: Date) -> Int {
        let statuses = plausible(all, myToday: myToday)
        guard let earliest = statuses.map(\.day).min() else { return 0 }
        return walk(statuses, down: earliest, myRole: myRole, myToday: myToday, now: now).streak
    }

    /// Whether the streak reaches back to the start of the kept window, which is when a
    /// card or widget shows "100+ days" rather than a number.
    ///
    /// Every phone keeps the same 100-day window (see `pruned`), and the server a day or
    /// two more, so a streak longer than that can't be counted by anyone, and "100+" is
    /// what they all agree on.
    ///
    /// This is true when the walk back from today reaches the window's first day without
    /// the streak breaking, that day itself judged, and something is known about that day
    /// or before it; a break before that day doesn't matter (final design §8.5). On
    /// statuses pruned at the same `myToday`, that is the same as the walk reaching the
    /// earliest status unbroken with the earliest status on the window's first day. But a
    /// cache last pruned the day before can start a day earlier than the window, and there
    /// the two differ. This comment used to say they were the same on any pruned statuses,
    /// which they aren't: 130 both-met days pruned on 2026-09-24, then both met on 09-25
    /// and read on 09-25, start on 06-17; without the partner's 06-17 the streak still
    /// reaches the window's first day, 06-18, unbroken, so this is true, while "the
    /// earliest status, unbroken" would say false (vector HC.edge.staleCache).
    static func reachedRetentionEdge(statuses all: [DuoDayStatus], myRole: DuoRole, myToday: String, now: Date) -> Bool {
        let statuses = plausible(all, myToday: myToday)
        guard let edge = retentionStart(myToday: myToday),
              let earliest = statuses.map(\.day).min(), earliest <= edge else { return false }
        return !walk(statuses, down: edge, myRole: myRole, myToday: myToday, now: now).broke
    }

    /// The walk both of the above share: back from the newest day anyone has, one day at
    /// a time, down to and including `floor`, stopping at the first day that ends the
    /// streak.
    private static func walk(
        _ statuses: [DuoDayStatus],
        down floor: String,
        myRole: DuoRole,
        myToday: String,
        now: Date
    ) -> (streak: Int, broke: Bool) {
        let met = Dictionary(grouping: statuses.filter(\.goalMet), by: \.day)
            .mapValues { Set($0.map(\.role)) }
        let newest = max(myToday, statuses.map(\.day).max() ?? myToday)

        var streak = 0
        var cursor: String? = newest
        while let day = cursor, day >= floor {
            let metBy = met[day] ?? []
            if metBy.count == DuoRole.allCases.count {
                streak += 1
            } else {
                let waitingOn = DuoRole.allCases.filter { !metBy.contains($0) }
                let allCouldStill = waitingOn.allSatisfy {
                    isStillOpen(day, for: $0, statuses: statuses, myRole: myRole, myToday: myToday, now: now)
                }
                if !allCouldStill { return (streak, true) }
            }
            cursor = DayKey.previousDayKey(before: day, calendar: arithmetic)
        }
        return (streak, false)
    }

    /// How recently a partner's status for my yesterday must have been written to be
    /// shown as their today. See `currentStatus`.
    static let freshness: TimeInterval = 6 * 60 * 60

    /// The status to show for someone right now.
    ///
    /// Mine is today's. My partner may be on a different day from me, so theirs is the
    /// newest they have written if it is for my today or later, or for my yesterday and
    /// written in the last few hours, which is what a partner a few time zones behind
    /// looks like. Anything older is yesterday's news and is not shown as today's.
    static func currentStatus(
        of role: DuoRole,
        statuses: [DuoDayStatus],
        myRole: DuoRole,
        myToday: String,
        now: Date
    ) -> DuoDayStatus? {
        let theirs = plausible(statuses, myToday: myToday).filter { $0.role == role }
        if role == myRole { return theirs.first { $0.day == myToday } }
        guard let newest = theirs.max(by: { $0.day < $1.day }) else { return nil }
        if newest.day >= myToday { return newest }
        let yesterday = DayKey.previousDayKey(before: myToday, calendar: arithmetic)
        if newest.day == yesterday,
           !isOverEverywhere(newest.day, now: now),
           now.timeIntervalSince(newest.updatedAt) < freshness {
            return newest
        }
        return nil
    }

    /// How far back a day can still be corrected. Editing a drink can move it to another
    /// day, so the last week is republished when it changes. Nothing older ever is.
    static let correctionWindowDays = 7

    /// How many days of statuses anyone keeps: both phones and the server, the same
    /// number, so that they all show the same streak. The privacy page states it, and
    /// the server reads it from `RETENTION_DAYS` (decision D9).
    static let retentionDays = 100

    /// The first day of the kept window: `myToday` and the 99 days before it.
    static func retentionStart(myToday: String) -> String? {
        guard let today = DayKey.date(from: myToday, calendar: arithmetic),
              let start = arithmetic.date(byAdding: .day, value: -(retentionDays - 1), to: today) else { return nil }
        return DayKey.key(for: start, calendar: arithmetic)
    }

    /// Drops what can no longer matter: everything before the most recent day that
    /// ended the streak for good, once that day is too old to be corrected, and
    /// everything older than the kept window of `retentionDays`. Keeps the cache the
    /// size of the streak rather than the size of the friendship, and nothing older than
    /// 100 days of anybody's goals.
    ///
    /// The server runs the same rule each day with the date in the last time zone on
    /// Earth as `myToday`. That date is never later than any phone's, so the server never
    /// drops a day a phone still counts; it holds the same window or a day or two more.
    static func pruned(_ statuses: [DuoDayStatus], myToday: String, now: Date) -> [DuoDayStatus] {
        guard let today = DayKey.date(from: myToday, calendar: arithmetic),
              let cutoffDate = arithmetic.date(byAdding: .day, value: -(correctionWindowDays + 2), to: today),
              let windowStart = retentionStart(myToday: myToday),
              let earliest = statuses.map(\.day).min() else { return statuses }
        let cutoff = DayKey.key(for: cutoffDate, calendar: arithmetic)
        let met = Dictionary(grouping: statuses.filter(\.goalMet), by: \.day)
            .mapValues { Set($0.map(\.role)) }

        var kept = statuses
        var cursor: String? = cutoff
        while let day = cursor, day >= earliest {
            if (met[day] ?? []).count < DuoRole.allCases.count, isOverEverywhere(day, now: now) {
                kept = statuses.filter { $0.day >= day }
                break
            }
            cursor = DayKey.previousDayKey(before: day, calendar: arithmetic)
        }
        return kept.filter { $0.day >= windowStart }
    }
}

/// What this device should write, worked out by comparing the log with what the server
/// is already known to hold.
///
/// There is no queue of writes to lose. Whatever could not be sent, because the phone
/// was offline or the app was closed, is simply still different the next time this
/// runs, and is sent then.
enum DuoOutbox {
    /// A `coverageStart` earlier than any real day, for callers that know the log goes
    /// back as far as it needs to.
    static let coveredForever = "0000-01-01"

    /// - Parameters:
    ///   - totalsByDay: hydrating mL per day from the log, as `StreakCalculator` groups it.
    ///   - known: what the server is known to hold for this duo.
    ///   - coverageStart: the first day this phone's log can speak for: the earlier of
    ///     the day this install first ran and the day of the oldest drink in the log.
    ///     Before it, a day can only be raised, never lowered, because an empty day
    ///     there means this phone wasn't keeping a log yet, not that nobody drank.
    ///     Without it, reinstalling the app and opening the duo before the log came back
    ///     from iCloud would publish a week of empty days over a partner's shared streak.
    static func unsent(
        role: DuoRole,
        totalsByDay: [String: Int],
        goalML: Int,
        known: [DuoDayStatus],
        myToday: String,
        now: Date,
        coverageStart: String = coveredForever,
        calendar: Calendar = .current
    ) -> [DuoDayStatus] {
        guard let today = DayKey.date(from: myToday, calendar: calendar) else { return [] }
        var days: [String] = []
        for offset in 0..<DuoStreak.correctionWindowDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            days.append(DayKey.key(for: date, calendar: calendar))
        }

        return days.compactMap { day in
            let wanted = DuoProgress.status(role: role, day: day, totalML: totalsByDay[day] ?? 0, goalML: goalML, now: now)
            if let existing = known.first(where: { $0.role == role && $0.day == day }) {
                if existing.saysTheSame(as: wanted) { return nil }
                let isDowngrade = wanted.progressBucket <= existing.progressBucket
                if day != myToday, day < coverageStart, isDowngrade { return nil }
                return wanted
            }
            // Today is always written, even empty: it tells a partner that yesterday is
            // over for me. An empty day in the past says nothing a missing record does not.
            return (day == myToday || wanted.progressBucket > 0) ? wanted : nil
        }
    }
}

/// Spaces writes out. However fast drinks are logged, the server hears about it at most
/// once every thirty seconds, and it hears the latest state, not every step on the way.
struct DuoWriteCoalescer {
    static let minimumInterval: TimeInterval = 30

    enum Decision: Equatable {
        case writeNow
        /// Too soon after the last write. One write is now owed at this time.
        case wait(until: Date)
        /// Too soon, and a write is already owed. Nothing more to arrange.
        case alreadyWaiting
    }

    private(set) var lastWriteAt: Date?
    private(set) var isWaiting = false

    mutating func request(now: Date) -> Decision {
        guard let lastWriteAt else {
            self.lastWriteAt = now
            return .writeNow
        }
        let due = lastWriteAt.addingTimeInterval(Self.minimumInterval)
        if now >= due {
            self.lastWriteAt = now
            isWaiting = false
            return .writeNow
        }
        if isWaiting { return .alreadyWaiting }
        isWaiting = true
        return .wait(until: due)
    }

    /// The owed write's time has come.
    mutating func waitEnded(now: Date) {
        isWaiting = false
        lastWriteAt = now
    }
}

enum DuoLimit {
    /// One duo is free. More is part of HydroDrop+.
    static let freeDuoCount = 1
    static let plusDuoCount = 5

    static func maximum(isSubscribed: Bool) -> Int {
        isSubscribed ? plusDuoCount : freeDuoCount
    }

    /// Duos that have ended do not take up a place: they are only a notice waiting to
    /// be cleared.
    static func canAddDuo(existing: [DuoState], isSubscribed: Bool) -> Bool {
        existing.filter { !$0.hasEnded }.count < maximum(isSubscribed: isSubscribed)
    }
}

// `DuoParticipants`, which trimmed an iCloud share down to the owner and the first
// person to accept it, used to sit here. A duo is still exactly two people and the first
// to join still wins, but in Duo v2 the server enforces that when an invite is redeemed,
// in one conditional write, so no phone has to tidy up after the fact.

// The App Group cache that used to end this file, `DuoCache`, stays out of HydroCore on
// purpose. It reads the app's App Group and logs through the app's `Diagnostics`, and
// HydroCore imports nothing but Foundation so that the same rules can be ported to Android
// and the server and checked against one set of vectors. It was removed with the iCloud
// Duo and comes back in Phase 2 of Duo v2 as app-side storage, under new key names:
// `duo.states.v2` because the v2 state has new fields, and `duo.ledger.v2` and
// `duo.myDisplayName.v2` because `LegacyDuoCleanup` deletes the old names (decision D15).
// The cleanup also deletes `duo.notificationsOff` and `duoInviteMoment.dismissed`, so those
// need new names too.
