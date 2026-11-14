import Foundation

/// Applies a change feed to a duo (final design §6.4's apply order, §10.3). The one place a
/// feed becomes `DuoState`: a fetch uses it, so does the answer to a status write (which is
/// the feed after the write) and the answer to a redeem (the whole duo as this person now
/// sees it), so a row means the same however it arrived.
public enum DuoFeedReducer {
    public struct Result: Equatable, Sendable {
        public var duo: DuoState
        /// True when the feed held every retained row. A first read is catching up, not
        /// news, so `DuoAnnouncements.plan` is told not to announce a goal found already met.
        public var isFirstRead: Bool
        /// The ledger keys of the pushes this device was already sent (`handled`), to be
        /// marked seen before `plan` runs so none is announced a second time (§6.4, §9.5).
        public var handledKeys: [String]
    }

    /// Nil only if the header's id is not a UUID.
    ///
    /// In this order: the header; on a full feed, forget every row and nudge held; upsert the
    /// feed's rows (a row this build cannot hold is dropped, and a day sent twice takes the
    /// last), keeping each row's `ver`; merge its nudges and keep the last two days of them;
    /// prune to the retained window and drop the `ver` of any day no longer held; and move the
    /// cursor on, never back (`max(cursor, response.cursor)`, CON R8). A header-only feed (a
    /// caller who left, was blocked or is superseded) has no rows, and changes only the header.
    public static func apply(_ changes: DuoWireChanges, to previous: DuoState?, myToday: String, now: Date) -> Result? {
        guard var duo = DuoMapping.duo(from: changes.duo, previous: previous, now: now) else { return nil }
        if changes.full {
            duo.statuses = []
            duo.vers = [:]
            duo.nudges = []
        }
        for row in changes.statuses {
            guard let status = DuoMapping.status(row) else { continue }
            duo.upsert(status)
            duo.vers[status.recordName] = row.ver
        }

        var nudges = duo.allNudges
        for wire in changes.nudges {
            guard let nudge = DuoMapping.nudge(wire) else { continue }
            if let index = nudges.firstIndex(where: { $0.id == nudge.id }) { nudges[index] = nudge } else { nudges.append(nudge) }
        }
        duo.nudges = DuoNudgeRules.current(nudges, now: now)

        duo.statuses = DuoStreak.pruned(duo.statuses, myToday: myToday, now: now)
        let held = Set(duo.statuses.map(\.recordName))
        duo.vers = duo.vers.filter { held.contains($0.key) }

        duo.cursor = max(duo.cursor, changes.cursor)
        if changes.duo.isFull { duo.syncedOnce = true }

        let handled = changes.handled.compactMap { entry -> String? in
            switch entry.kind {
            case "goal_met":
                guard let day = entry.day, DuoStreak.isDayKey(day) else { return nil }
                return DuoLedger.goalKey(duoID: duo.id, day: day)
            case "nudge":
                guard let id = entry.id, DuoNudge.isNudgeRecordName(id) else { return nil }
                return id
            default:
                return nil
            }
        }
        return Result(duo: duo, isFirstRead: changes.full, handledKeys: handled)
    }
}
