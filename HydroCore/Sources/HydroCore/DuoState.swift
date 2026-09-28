import Foundation

// A duo is one shared streak with one other person. Everything in this file is a value
// type with no CloudKit in it, so the app, the tests and later a widget can all read a
// duo without being able to reach the network.

/// Which side of a duo someone is on. The owner is whoever sent the invite, and the
/// duo's records live in a zone in their iCloud. It carries no rank: both sides see and
/// do exactly the same things.
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

/// How records and zones are named.
///
/// A day's status is named after whose it is and which day, so writing it twice is
/// writing the same record twice: an upsert, never a duplicate, however many times a
/// retry or a second device repeats it.
enum DuoRecordName {
    static let zonePrefix = "Duo-"
    /// The one `Duo` record in each zone.
    static let duo = "duo"

    static func zoneName(for id: UUID) -> String { zonePrefix + id.uuidString }

    /// The duo a zone belongs to, or nil for any zone that is not a duo's. Every write
    /// and every delete goes through this first, which is what keeps this layer out of
    /// the zone SwiftData mirrors into.
    static func duoID(fromZoneName zoneName: String) -> UUID? {
        guard zoneName.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(zoneName.dropFirst(zonePrefix.count)))
    }

    static func dayStatus(role: DuoRole, day: String) -> String { "\(role.rawValue)-\(day)" }

    /// Reads a status record's name back. Nil for anything else in the zone, including
    /// record types a newer version of the app may add later.
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

    /// A first name as it is stored: trimmed, one line, and short enough for the card.
    static func cleanedName(_ raw: String) -> String {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(maximumNameLength))
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

    /// Whether `text` is a real day, written the way `DayKey` writes one. Calendars are
    /// forgiving about a thirteenth month, so the day is written back out and compared.
    static func isDayKey(_ text: String) -> Bool {
        guard text.count == 10, let date = DayKey.date(from: text, calendar: arithmetic) else { return false }
        return DayKey.key(for: date, calendar: arithmetic) == text
    }

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

        let met = Dictionary(grouping: statuses.filter(\.goalMet), by: \.day)
            .mapValues { Set($0.map(\.role)) }
        guard let earliest = statuses.map(\.day).min() else { return 0 }
        let newest = max(myToday, statuses.map(\.day).max() ?? myToday)

        var streak = 0
        var cursor: String? = newest
        while let day = cursor, day >= earliest {
            let metBy = met[day] ?? []
            if metBy.count == DuoRole.allCases.count {
                streak += 1
            } else {
                let waitingOn = DuoRole.allCases.filter { !metBy.contains($0) }
                let allCouldStill = waitingOn.allSatisfy {
                    isStillOpen(day, for: $0, statuses: statuses, myRole: myRole, myToday: myToday, now: now)
                }
                if !allCouldStill { break }
            }
            cursor = DayKey.previousDayKey(before: day, calendar: arithmetic)
        }
        return streak
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

    /// Drops what can no longer matter: everything before the most recent day that
    /// ended the streak for good, once that day is too old to be corrected. Keeps the
    /// cache the size of the streak rather than the size of the friendship.
    static func pruned(_ statuses: [DuoDayStatus], myToday: String, now: Date) -> [DuoDayStatus] {
        guard let today = DayKey.date(from: myToday, calendar: arithmetic),
              let cutoffDate = arithmetic.date(byAdding: .day, value: -(correctionWindowDays + 2), to: today),
              let earliest = statuses.map(\.day).min() else { return statuses }
        let cutoff = DayKey.key(for: cutoffDate, calendar: arithmetic)
        let met = Dictionary(grouping: statuses.filter(\.goalMet), by: \.day)
            .mapValues { Set($0.map(\.role)) }

        var cursor: String? = cutoff
        while let day = cursor, day >= earliest {
            if (met[day] ?? []).count < DuoRole.allCases.count, isOverEverywhere(day, now: now) {
                return statuses.filter { $0.day >= day }
            }
            cursor = DayKey.previousDayKey(before: day, calendar: arithmetic)
        }
        return statuses
    }
}

/// What this device should write, worked out by comparing the log with what iCloud is
/// already known to hold.
///
/// There is no queue of writes to lose. Whatever could not be sent, because the phone
/// was offline or the app was closed, is simply still different the next time this
/// runs, and is sent then.
enum DuoOutbox {
    /// - Parameters:
    ///   - totalsByDay: hydrating mL per day from the log, as `StreakCalculator` groups it.
    ///   - known: what the duo's zone is known to hold.
    static func unsent(
        role: DuoRole,
        totalsByDay: [String: Int],
        goalML: Int,
        known: [DuoDayStatus],
        myToday: String,
        now: Date,
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
                return existing.saysTheSame(as: wanted) ? nil : wanted
            }
            // Today is always written, even empty: it tells a partner that yesterday is
            // over for me. An empty day in the past says nothing a missing record does not.
            return (day == myToday || wanted.progressBucket > 0) ? wanted : nil
        }
    }
}

/// Spaces writes out. However fast drinks are logged, iCloud hears about it at most
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

/// Owner-side rule for who stays in a share: the first person to accept, and nobody
/// else. A duo is two people.
enum DuoParticipants {
    struct Participant: Equatable {
        var id: String
        var isOwner: Bool
        var hasAccepted: Bool
    }

    /// Who should be removed from the share. Nobody, until someone has accepted; then
    /// everyone who is neither the owner nor that first partner, invited or not.
    static func toRemove(from participants: [Participant], keeping partnerID: String?) -> [String] {
        let others = participants.filter { !$0.isOwner }
        guard let kept = partnerID ?? others.first(where: \.hasAccepted)?.id else { return [] }
        return others.filter { $0.id != kept }.map(\.id)
    }
}

/// The duo state, kept in the App Group so that a widget can draw a duo without the
/// app running. Holds exactly what the zone holds and nothing more personal than that.
enum DuoCache {
    /// The duo widget's kind, here because both the app, which reloads it, and the
    /// widget extension, which declares it, have to agree on the spelling.
    static let widgetKind = "DuoWidget"

    private static let statesKey = "duo.states.v1"
    private static let nameKey = "duo.myDisplayName"

    /// The App Group if this build has one, this process's own defaults if not, so a
    /// build signed without the group still has a working Duo screen.
    static var defaults: UserDefaults { AppGroup.defaults ?? .standard }

    static func load(from defaults: UserDefaults = DuoCache.defaults) -> [DuoState] {
        guard let data = defaults.data(forKey: statesKey) else { return [] }
        do {
            return try JSONDecoder().decode([DuoState].self, from: data)
        } catch {
            Diagnostics.log("could not read the duo cache: \(error)")
            return []
        }
    }

    static func save(_ states: [DuoState], to defaults: UserDefaults = DuoCache.defaults) {
        do {
            defaults.set(try JSONEncoder().encode(states), forKey: statesKey)
        } catch {
            Diagnostics.log("could not write the duo cache: \(error)")
        }
    }

    /// The first name last typed in, so a second duo does not ask for it again.
    static func myDisplayName(in defaults: UserDefaults = DuoCache.defaults) -> String {
        defaults.string(forKey: nameKey) ?? ""
    }

    static func setMyDisplayName(_ name: String, in defaults: UserDefaults = DuoCache.defaults) {
        defaults.set(name, forKey: nameKey)
    }
}
