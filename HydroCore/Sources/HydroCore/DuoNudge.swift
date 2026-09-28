import Foundation

// Nudges: one tap sends a partner one of a handful of ready-made lines. Everything here
// is a value type with no CloudKit and no notifications in it, so the rules about who
// may send what, what gets announced and when can all be tested without either.

/// The lines a nudge can say. There is no free text anywhere in a duo: a nudge carries
/// the name of one of these and nothing else, and the words are looked up on the
/// receiving phone. Nothing a person typed ever reaches another person.
enum DuoNudgePreset: String, CaseIterable, Identifiable, Codable {
    case waterBreak
    case sipWithMe
    case dropletMissesYou
    case soClose
    case cheers
    case keepTheFlame
    case halfwayCheck
    case youHaveGotThis

    var id: String { rawValue }

    var text: String {
        switch self {
        case .waterBreak: return "Water break?"
        case .sipWithMe: return "Sip with me?"
        case .dropletMissesYou: return "Your droplet misses you."
        case .soClose: return "You are so close. One more glass?"
        case .cheers: return "Cheers! I just had a glass."
        case .keepTheFlame: return "Let's keep our flame going."
        case .halfwayCheck: return "Halfway through the day. How is the water going?"
        case .youHaveGotThis: return "You have got this."
        }
    }

    /// What is shown for a preset this version has never heard of, which is what a
    /// partner on a newer version may one day send.
    static let fallbackText = "Time for some water?"

    static func text(forID id: String) -> String {
        DuoNudgePreset(rawValue: id)?.text ?? fallbackText
    }
}

/// One nudge, as it sits in the duo's zone.
struct DuoNudge: Codable, Equatable, Identifiable {
    static let recordPrefix = "nudge-"

    /// The record's name, `nudge-<uuid>`.
    var id: String
    var fromRole: DuoRole
    var presetID: String
    var createdAt: Date

    static func make(from role: DuoRole, preset: DuoNudgePreset, now: Date) -> DuoNudge {
        DuoNudge(id: recordPrefix + UUID().uuidString, fromRole: role, presetID: preset.rawValue, createdAt: now)
    }

    static func isNudgeRecordName(_ name: String) -> Bool {
        name.hasPrefix(recordPrefix) && UUID(uuidString: String(name.dropFirst(recordPrefix.count))) != nil
    }
}

/// Who may send a nudge, and when.
enum DuoNudgeRules {
    /// Nudges one person can send one duo in one of their own days.
    static let dailyLimit = 3
    /// A nudge older than this is history. It is kept off the screen, never announced,
    /// and cleared out of the zone by whoever sent it.
    static let lifetime: TimeInterval = 2 * 24 * 60 * 60
    /// A nudge that turns up later than this is too late to be worth a notification.
    static let announceWithin: TimeInterval = 12 * 60 * 60

    enum Verdict: Equatable {
        case allowed(remaining: Int)
        /// All of today's have been sent.
        case limitReached
        /// The partner has already met their goal. There is nothing to nudge them about.
        case partnerAlreadyMet
        /// Nobody has joined yet, or the duo is over.
        case nobodyToNudge
    }

    static func sentToday(by role: DuoRole, nudges: [DuoNudge], now: Date, calendar: Calendar = .current) -> Int {
        nudges.filter { $0.fromRole == role && calendar.isDate($0.createdAt, inSameDayAs: now) }.count
    }

    static func verdict(
        for duo: DuoState,
        partnerStatus: DuoDayStatus?,
        now: Date,
        calendar: Calendar = .current
    ) -> Verdict {
        guard !duo.hasEnded, !duo.isPending else { return .nobodyToNudge }
        if partnerStatus?.goalMet == true { return .partnerAlreadyMet }
        let sent = sentToday(by: duo.myRole, nudges: duo.allNudges, now: now, calendar: calendar)
        return sent >= dailyLimit ? .limitReached : .allowed(remaining: dailyLimit - sent)
    }

    /// My own nudges that have outlived their use, to be deleted from the zone the next
    /// time I send one. Only ever my own: a partner's records are theirs to tidy.
    static func expired(sentBy role: DuoRole, nudges: [DuoNudge], now: Date) -> [DuoNudge] {
        nudges.filter { $0.fromRole == role && now.timeIntervalSince($0.createdAt) > lifetime }
    }

    /// What is worth keeping in the cache.
    static func current(_ nudges: [DuoNudge], now: Date) -> [DuoNudge] {
        nudges.filter { now.timeIntervalSince($0.createdAt) <= lifetime }
    }
}

/// What has already been announced, so nothing is ever announced twice, whether the
/// news arrives by push, by background refresh, by opening the app, or by all three.
struct DuoLedger: Equatable {
    static let capacity = 200

    private(set) var seen: [String]

    init(seen: [String] = []) {
        self.seen = seen
    }

    func hasSeen(_ key: String) -> Bool { seen.contains(key) }

    /// Records `key`. True the first time, false every time after.
    mutating func markSeen(_ key: String) -> Bool {
        guard !seen.contains(key) else { return false }
        seen.append(key)
        if seen.count > Self.capacity { seen.removeFirst(seen.count - Self.capacity) }
        return true
    }

    /// Takes a key back out: it was planned but never actually shown.
    mutating func forget(_ key: String) {
        seen.removeAll { $0 == key }
    }

    static func goalKey(duoID: UUID, day: String) -> String { "met|\(duoID.uuidString)|\(day)" }
}

/// Something to tell the user about a duo.
struct DuoAnnouncement: Equatable {
    enum Kind: Equatable {
        case nudge(presetID: String)
        /// The partner met their goal. `iHaveToo` picks the wording.
        case partnerMetGoal(iHaveToo: Bool)
    }

    /// The ledger key, which is also what the notification is named after.
    var key: String
    var duoID: UUID
    var partnerName: String
    var kind: Kind

    var title: String {
        switch kind {
        case .nudge: return "\(partnerName) nudged you"
        case .partnerMetGoal: return "\(partnerName) hit their goal"
        }
    }

    var body: String {
        switch kind {
        case .nudge(let presetID): return DuoNudgePreset.text(forID: presetID)
        case .partnerMetGoal(let iHaveToo):
            return iHaveToo ? "You both made it today." : "Your turn. Keep the flame going."
        }
    }

    /// Only a nudge carries the reminder's buttons, so a glass can be logged from it.
    var isActionable: Bool {
        if case .nudge = kind { return true }
        return false
    }
}

/// Works out what a fetch is worth telling the user about.
enum DuoAnnouncements {
    /// - Parameters:
    ///   - before: the duo as it was cached before the fetch.
    ///   - after: the same duo with the fetch applied.
    ///   - isFirstRead: true when the whole zone was read rather than what changed.
    ///     A first read is catching up, not news, so a goal found already met is not
    ///     announced as though it had just happened.
    static func plan(
        before: DuoState,
        after: DuoState,
        isFirstRead: Bool,
        ledger: inout DuoLedger,
        myToday: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [DuoAnnouncement] {
        guard !after.hasEnded else { return [] }
        let partner = after.myRole.other
        let name = after.displayName(of: partner)
        var result: [DuoAnnouncement] = []

        // Nudges from the other side, newest last, and never more in a day than one
        // person is allowed to send, whatever the other phone claims to have sent.
        let known = Set(before.allNudges.map(\.id))
        var announcedToday = after.allNudges.filter {
            $0.fromRole == partner && known.contains($0.id) && calendar.isDate($0.createdAt, inSameDayAs: now)
        }.count
        let arrivals = after.allNudges
            .filter { $0.fromRole == partner && !known.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        for nudge in arrivals {
            // Marked as seen whether or not it is announced, so a nudge that was too
            // old or one too many does not come back to be judged again.
            guard ledger.markSeen(nudge.id) else { continue }
            let age = now.timeIntervalSince(nudge.createdAt)
            guard age >= -300, age <= DuoNudgeRules.announceWithin else { continue }
            guard announcedToday < DuoNudgeRules.dailyLimit else { continue }
            announcedToday += 1
            result.append(DuoAnnouncement(key: nudge.id, duoID: after.id, partnerName: name, kind: .nudge(presetID: nudge.presetID)))
        }

        // The moment the partner's day turns to "goal met".
        if !isFirstRead,
           let theirs = DuoStreak.currentStatus(of: partner, statuses: after.statuses, myRole: after.myRole, myToday: myToday, now: now),
           theirs.goalMet,
           before.status(of: partner, on: theirs.day)?.goalMet != true {
            let key = DuoLedger.goalKey(duoID: after.id, day: theirs.day)
            if ledger.markSeen(key) {
                let mine = after.status(of: after.myRole, on: myToday)?.goalMet == true
                result.append(DuoAnnouncement(key: key, duoID: after.id, partnerName: name, kind: .partnerMetGoal(iHaveToo: mine)))
            }
        }
        return result
    }
}

/// When a duo notification may be shown: only inside the waking window, which is the
/// same window reminders keep to. Anything that arrives outside it is held until the
/// window next opens, so a partner in another time zone can never wake anyone up.
enum DuoQuietHours {
    static let minutesPerDay = 24 * 60

    static func isAwake(_ date: Date, startMinutes: Int, endMinutes: Int, calendar: Calendar = .current) -> Bool {
        // No window at all is the "paused" state for reminders. For a duo it is read as
        // no restriction: there is no opening time to hold anything until.
        guard startMinutes != endMinutes else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if endMinutes > startMinutes { return minute >= startMinutes && minute < endMinutes }
        // A window that wraps past midnight, as a night shift's does.
        return minute >= startMinutes || minute < endMinutes
    }

    /// When to show something that arrived at `date`: nil for now, or the next time the
    /// window opens.
    static func holdUntil(_ date: Date, startMinutes: Int, endMinutes: Int, calendar: Calendar = .current) -> Date? {
        guard !isAwake(date, startMinutes: startMinutes, endMinutes: endMinutes, calendar: calendar) else { return nil }
        let start = min(max(startMinutes, 0), minutesPerDay - 1)
        let startOfDay = calendar.startOfDay(for: date)
        let today = calendar.date(byAdding: .minute, value: start, to: startOfDay) ?? date
        if today > date { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86_400)
        return calendar.date(byAdding: .minute, value: start, to: tomorrow) ?? tomorrow
    }
}

/// The one-time suggestion, after a few days of a solo streak, to keep one with
/// someone else. Shown once, dismissible, and never again after that.
enum DuoInviteMoment {
    static let streakNeeded = 3

    static func shouldShow(soloStreak: Int, hasAnyDuo: Bool, wasDismissed: Bool) -> Bool {
        !wasDismissed && !hasAnyDuo && soloStreak >= streakNeeded
    }
}

extension DuoCache {
    private static let ledgerKey = "duo.ledger.v1"
    private static let notificationsOffKey = "duo.notificationsOff"

    static func loadLedger(from defaults: UserDefaults = DuoCache.defaults) -> DuoLedger {
        DuoLedger(seen: defaults.stringArray(forKey: ledgerKey) ?? [])
    }

    static func save(_ ledger: DuoLedger, to defaults: UserDefaults = DuoCache.defaults) {
        defaults.set(ledger.seen, forKey: ledgerKey)
    }

    /// Stored as "off" so that the default, with nothing stored, is on.
    static func notificationsEnabled(in defaults: UserDefaults = DuoCache.defaults) -> Bool {
        !defaults.bool(forKey: notificationsOffKey)
    }

    static func setNotificationsEnabled(_ enabled: Bool, in defaults: UserDefaults = DuoCache.defaults) {
        defaults.set(!enabled, forKey: notificationsOffKey)
    }
}
