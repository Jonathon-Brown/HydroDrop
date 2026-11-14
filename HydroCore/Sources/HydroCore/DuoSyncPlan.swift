import Foundation

/// The two pure steps of a shared streak's sync (final design §6.4, §6.5, §9.5, §10.1 to §10.5):
/// what a change feed does to a duo and what it is worth telling the person, and what this phone
/// owes the server for a duo. The app's sync engine sequences the requests around them; the
/// decisions are here, so the Android app can be held to the same vectors (KV11, KV12, X14).
public enum DuoSyncPlan {
    // MARK: - A feed

    /// The one step every change feed goes through, a fetch's and a write's answer alike (a
    /// write's answer is the feed after the write).
    ///
    /// In this order: the feed is applied (`DuoFeedReducer.apply`); the pushes the server says
    /// this device was already sent (`handled`) are marked seen in the ledger before anything is
    /// planned, so a nudge or a goal the server already pushed is not announced a second time
    /// (§6.4, §9.5, vector KV12); then `DuoAnnouncements.plan` runs, with a first read (a full
    /// feed, or a duo this phone has not read since a reinstall, reconnect or link) treated as
    /// catching up rather than news; and last, an announcement for an event whose remote
    /// notification is already on this phone (`deliveredRemoteKeys`) is dropped. It stays marked
    /// seen, so it is never offered again: the push said it (§9.5, vector X14).
    ///
    /// Nil when the feed cannot be applied: its header is not a duo id, or it is the header of a
    /// different duo from `before`. The reducer keeps `before`'s id whatever the header says, so a
    /// feed for another duo would otherwise be written into this one.
    ///
    /// Two of the reducer's inputs are adjusted for a phone whose clock is wrong or a server that
    /// was restored:
    /// - It prunes as of `pruneDay(...)`, never later than two days past the newest row held. A
    ///   clock set twelve days ahead used to prune the whole cache (every held day was then over
    ///   everywhere and before the break rule's cutoff), and a delta feed never brings pruned rows
    ///   back, so the shared streak read 0 on this phone after the clock was put right.
    /// - Given the `since` the request was sent with, a full answer to a `since` ahead of the
    ///   server's own cursor (the server's database was restored to an earlier point, §6.4) moves
    ///   the cursor back to the server's (D72). Kept ahead, it made every row written after the
    ///   restore until the server's seq passed it invisible to the push gate and the delta feed.
    ///   Whether such an answer may be applied at all is `answerFits`'s to say.
    public static func process(changes: DuoWireChanges, before: DuoState?, ledger: DuoLedger, deliveredRemoteKeys: Set<String>,
                               myToday: String, now: Date, calendar: Calendar, since: Int64? = nil)
        -> (duo: DuoState, announcements: [DuoAnnouncement], ledger: DuoLedger, isFirstRead: Bool)? {
        if let before, UUID(uuidString: changes.duo.id) != before.id { return nil }
        let held = (before?.statuses ?? []) + changes.statuses.compactMap(DuoMapping.status)
        guard var result = DuoFeedReducer.apply(changes, to: before, myToday: pruneDay(myToday: myToday, held: held), now: now) else { return nil }
        if let since, isRestoredServerAnswer(changes, since: since) { result.duo.cursor = changes.cursor }
        var ledger = ledger
        for key in result.handledKeys { _ = ledger.markSeen(key) }
        let isFirstRead = result.isFirstRead || !(before?.syncedOnce ?? false)
        // A duo this phone never held is compared against nothing: every nudge in the feed is an
        // arrival (announced only if it is under 12 hours old), and goals are not news.
        let baseline = before ?? {
            var nothing = result.duo
            nothing.statuses = []
            nothing.nudges = []
            return nothing
        }()
        let planned = DuoAnnouncements.plan(before: baseline, after: result.duo, isFirstRead: isFirstRead, ledger: &ledger,
                                            myToday: myToday, now: now, calendar: calendar)
        let announcements = planned.filter { !deliveredRemoteKeys.contains($0.key) }
        return (result.duo, announcements, ledger, isFirstRead)
    }

    /// The day the reducer prunes as of: `myToday`, or two days past the newest row held when
    /// that is earlier. Nobody is more than two days ahead of anybody else (`DuoStreak.plausible`),
    /// so a `myToday` further ahead than that is this phone's clock, not the duo's calendar.
    public static func pruneDay(myToday: String, held: [DuoDayStatus]) -> String {
        guard let newest = held.map(\.day).filter(DuoStreak.isDayKey).max(),
              let next = DayKey.nextDayKey(after: newest, calendar: utc),
              let limit = DayKey.nextDayKey(after: next, calendar: utc) else { return myToday }
        return min(myToday, limit)
    }

    /// A full answer to a `since` ahead of the cursor the server answered with: the server's
    /// database is behind what this phone has read (§6.4, D72).
    public static func isRestoredServerAnswer(_ changes: DuoWireChanges, since: Int64) -> Bool {
        changes.full && since > changes.cursor
    }

    /// Whether an answer to a request sent with `since` may still be applied to the duo as it is
    /// now. Two answers for one duo can cross (a fetch and a write's answer, say), and each was
    /// computed from the server as it stood when it was asked.
    ///
    /// - Not when the duo was reseated meanwhile (a reconnect or a restore made it unread, cursor
    ///   0): an answer to an older `since` would mark it read without the rows before that
    ///   `since`, and the next write could lower a day another device moved on (§10.3, KV11).
    /// - Not when it is older than an answer already applied (its cursor is behind the duo's):
    ///   its rows would replace newer ones, and the cursor, which never moves back (CON R8),
    ///   would never offer the newer ones again.
    /// - The exception is the answer of a restored server (`isRestoredServerAnswer`), which is the
    ///   whole truth however old its cursor looks, but only while the duo's cursor is still the
    ///   `since` it answers (D72). Once another answer has moved the cursor, a second full answer
    ///   to that same stale `since` is just behind, and taking it would put older rows back.
    /// A header-only answer carries the `since` it was asked with as its cursor, so it fits for
    /// as long as nothing newer has been applied.
    public static func answerFits(_ changes: DuoWireChanges, since: Int64, before: DuoState) -> Bool {
        guard since <= (before.syncedOnce ? before.cursor : 0) else { return false }
        if changes.cursor < before.cursor {
            return isRestoredServerAnswer(changes, since: since) && before.syncedOnce && before.cursor == since
        }
        return true
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    // MARK: - A write

    /// How long a new install only ever raises a row (D71, mirroring the server's own 48-hour
    /// downgrade backstop for a new device).
    public static let youngInstallWindow: TimeInterval = 48 * 60 * 60

    /// A status write this phone owes a duo: the request and the rows it carries, in this phone's
    /// role, for the verdicts to be judged against.
    public struct Write: Equatable, Sendable {
        public var request: DuoWirePutStatusesRequest
        public var rows: [DuoDayStatus]

        public init(request: DuoWirePutStatusesRequest, rows: [DuoDayStatus]) {
            self.request = request
            self.rows = rows
        }
    }

    /// What the log wants each of the last seven days to say, today first: the days
    /// `DuoOutbox.unsent` looks at, worked out the same way.
    public static func wanted(role: DuoRole, summary: DuoLogSummary, myToday: String, now: Date, calendar: Calendar) -> [DuoDayStatus] {
        guard let today = DayKey.date(from: myToday, calendar: calendar) else { return [] }
        return (0..<DuoStreak.correctionWindowDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let day = DayKey.key(for: date, calendar: calendar)
            return DuoProgress.status(role: role, day: day, totalML: summary.totalsByDay[day] ?? 0, goalML: summary.goalML, now: now)
        }
    }

    /// The write a duo is owed now, if any, and its refused days settled against what the log
    /// wants now (a day whose wanted status changed is no longer refused; one older than nine
    /// days is forgotten). Return the settled days to the cache whether or not there is a write.
    ///
    /// Nothing is owed:
    /// - to a duo that has ended, or has a leave or block waiting to be sent;
    /// - to a duo this phone has not read since a reinstall, a reconnect or a link
    ///   (`syncedOnce` false): it must complete one read before its first write (§3.4 step 4,
    ///   §10.3, vector KV11), or it could lower a day another device of this member moved on;
    /// - from a log with no goal (0 or less): that is a log that has not been read, not a person
    ///   who drank nothing, and judged against it every day of the week would be sent as missed;
    /// - for a row in `holding` while it is still what is wanted: a row the server refused in a way
    ///   that is not this phone's to fix (a downgrade it protects, a reason this build does not
    ///   know), which the caller holds back for a while (`DuoRebase.Outcome.heldRows`);
    /// - a lower row than the one the server holds, while this install is younger than
    ///   `youngInstallWindow` (D71). After a reinstall the iCloud mirror can bring the log back a
    ///   piece at a time, so a week that says 0 may only be a week not imported yet, and the
    ///   server's own 48-hour backstop does not see a same-device reinstall (a rotate keeps the
    ///   device's `created_at`). `coverageStart` alone did not cover it: the first old drink to
    ///   come back moved coverage to before the week.
    ///
    /// Each row carries `base_ver`, the `ver` last seen for that day or 0 (§10.3), and the four
    /// fields the contract takes and nothing else: no role (the server's to assign), no time
    /// (the server stamps it), never a row of the partner's (§6.5, §8.1).
    public static func write(for duo: DuoState, summary: DuoLogSummary?, coverageStart: String, rejectedDays: DuoRejectedDays,
                             holding: [DuoDayStatus] = [], installAge: TimeInterval = .infinity, myToday: String, now: Date,
                             calendar: Calendar) -> (write: Write?, rejectedDays: DuoRejectedDays) {
        guard !duo.hasEnded, duo.pendingOp == nil, duo.syncedOnce, let summary, summary.goalML > 0,
              DuoStreak.isDayKey(myToday) else { return (nil, rejectedDays) }
        var settled = rejectedDays
        settled.settle(against: wanted(role: duo.myRole, summary: summary, myToday: myToday, now: now, calendar: calendar), myToday: myToday)
        let rows = DuoOutbox.unsent(role: duo.myRole, totalsByDay: summary.totalsByDay, goalML: summary.goalML, known: duo.statuses,
                                    myToday: myToday, now: now, coverageStart: coverageStart, rejectedDays: settled, calendar: calendar)
            .filter { wanted in
                guard wanted.role == duo.myRole, !holding.contains(where: { $0.saysTheSame(as: wanted) }) else { return false }
                guard installAge < youngInstallWindow, let known = duo.status(of: duo.myRole, on: wanted.day) else { return true }
                return wanted.progressBucket >= known.progressBucket
            }
        guard !rows.isEmpty else { return (nil, settled) }
        let statuses = rows.map {
            DuoWireStatusIn(day: $0.day, goalMet: $0.goalMet, progressBucket: $0.progressBucket, baseVer: duo.ver(of: duo.myRole, on: $0.day))
        }
        return (Write(request: DuoWirePutStatusesRequest(myToday: myToday, since: duo.cursor, statuses: statuses), rows: rows), settled)
    }
}
