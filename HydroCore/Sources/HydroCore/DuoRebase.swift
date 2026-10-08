import Foundation

/// What this phone learns from the per-row verdicts of a status write (final design §6.5,
/// §10.2, §10.3, §10.5; vectors KV11, X6 and X7 from the client's side).
///
/// A write's answer is two things in one body: the change feed after the write, which carries
/// every accepted row back with the server's `ver` and `updated_at` and goes through
/// `DuoFeedReducer` like any other feed, and the verdict on each row sent. This is the second
/// half, applied to the duo as the first half left it, so a conflict's `current` (the stored
/// row as the answering batch left it) has the last word.
///
/// - `accepted`: nothing to do. The feed brought the row and its `ver`; `known` advances only
///   from rows the server stamped (§10.1), never from what this phone sent.
/// - `unchanged`: the server already holds the same `goal_met` and `progress_bucket`, so `known`
///   takes the sent row and the diff stops offering it. The stored `ver` is not told and is
///   left as it was: a later change re-bases off the conflict it gets, if the `ver` was stale.
/// - `ver_conflict` with `current`: `current` goes into `known` and its `ver` into `vers`, so the
///   re-diff sends against the server's row. Without `current` the server holds no row for the
///   day, which is `ver` 0, so the day leaves both `known` and `vers`: kept, the stale `ver` was
///   sent on every flush and refused every time, and §10.2 forbids stopping that by poisoning
///   the day. Either way `needsRetry` says one more write in the same slot may now go through.
/// - `downgrade_refused`: `current` is adopted the same way, and the row that was sent is handed
///   back in `heldRows` and never poisoned, since a refusal of a downgrade is the server
///   protecting a partner's streak from a phone whose log may be incomplete (§10.5). The caller
///   holds it back for a while, in memory: it is not sent again in this slot, nor on every flush
///   after, which used to be one refused request for every foreground for 48 hours.
/// - `day_out_of_range`, `day_after_today` and `status_inconsistent`: the row that was sent is
///   recorded in `DuoRejectedDays`, so the outbox skips it until what is wanted for that day
///   changes (§10.2, KV10).
/// - A reason this build has never heard of is a newer server's, and may mean anything: the sent
///   row goes into `heldRows` too, held in memory rather than poisoned on disk, so a reason that
///   turns out to pass is not remembered for nine days.
public enum DuoRebase {
    public struct Outcome: Equatable, Sendable {
        public var statuses: [DuoDayStatus]
        public var vers: [String: Int64]
        public var rejectedDays: DuoRejectedDays
        /// A `ver_conflict` was re-based: the caller may write once more in the same slot, if the
        /// re-diff still holds anything (a replay whose `current` is what is wanted holds nothing,
        /// X7, so no third request is made).
        public var needsRetry: Bool
        /// The sent rows the server refused as a downgrade or for a reason this build does not
        /// know: for the caller to hold back, not to poison (`DuoSyncPlan.write(holding:)`).
        public var heldRows: [DuoDayStatus]

        public init(statuses: [DuoDayStatus], vers: [String: Int64], rejectedDays: DuoRejectedDays, needsRetry: Bool, heldRows: [DuoDayStatus]) {
            self.statuses = statuses
            self.vers = vers
            self.rejectedDays = rejectedDays
            self.needsRetry = needsRetry
            self.heldRows = heldRows
        }
    }

    /// - Parameters:
    ///   - sent: the rows the request carried, as `DuoDayStatus` in this phone's role.
    ///   - accepted, unchanged, rejected: the answer's verdicts.
    ///   - role: this phone's role in the duo. A verdict's `current` in any other role is not
    ///     this phone's row and is ignored: a phone only ever writes its own side.
    ///   - statuses, vers: what this phone knows, after the answer's feed was applied.
    public static func apply(sent: [DuoDayStatus], accepted: [String], unchanged: [String], rejected: [DuoWireRejected],
                             role: DuoRole, statuses: [DuoDayStatus], vers: [String: Int64],
                             rejectedDays: DuoRejectedDays) -> Outcome {
        var known = statuses
        var vers = vers
        var refused = rejectedDays
        var needsRetry = false
        var hold: [DuoDayStatus] = []
        let sentByDay = Dictionary(sent.filter { $0.role == role }.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })

        for day in unchanged {
            guard let row = sentByDay[day] else { continue }
            if let index = known.firstIndex(where: { $0.role == role && $0.day == day }) {
                // The time stays the one the server last stamped this day with: the sent row's is
                // this phone's clock, which is not the server's (§8.2, vector X8).
                known[index].goalMet = row.goalMet
                known[index].progressBucket = row.progressBucket
            } else {
                known.append(row)
            }
        }

        for refusal in rejected {
            switch refusal.reason {
            case .verConflict:
                if let current = refusal.current {
                    // A `current` this build cannot hold (not a real day, a bucket that is not a
                    // quarter) says nothing it can act on; the day is left as it was.
                    guard current.role == role, let row = DuoMapping.status(current) else { continue }
                    upsert(row, into: &known)
                    vers[row.recordName] = current.ver
                } else {
                    known.removeAll { $0.role == role && $0.day == refusal.day }
                    vers[DuoRecordName.dayStatus(role: role, day: refusal.day)] = nil
                }
                needsRetry = true
            case .downgradeRefused:
                if let row = sentByDay[refusal.day] { hold.append(row) }
                guard let current = refusal.current, current.role == role, let row = DuoMapping.status(current) else { continue }
                upsert(row, into: &known)
                vers[row.recordName] = current.ver
            case .dayOutOfRange, .dayAfterToday, .statusInconsistent:
                if let row = sentByDay[refusal.day] { refused.record(row) }
            case .unknown:
                if let row = sentByDay[refusal.day] { hold.append(row) }
            }
        }
        return Outcome(statuses: known, vers: vers, rejectedDays: refused, needsRetry: needsRetry, heldRows: hold)
    }

    /// The same, applied to a duo and the answer that came back for it.
    public static func apply(_ answer: DuoWireChangesWithResult, sent: [DuoDayStatus], to duo: DuoState,
                             rejectedDays: DuoRejectedDays) -> (duo: DuoState, outcome: Outcome) {
        let outcome = apply(sent: sent, accepted: answer.accepted, unchanged: answer.unchanged, rejected: answer.rejected,
                            role: duo.myRole, statuses: duo.statuses, vers: duo.vers, rejectedDays: rejectedDays)
        var rebased = duo
        rebased.statuses = outcome.statuses
        rebased.vers = outcome.vers
        return (rebased, outcome)
    }

    private static func upsert(_ row: DuoDayStatus, into known: inout [DuoDayStatus]) {
        if let index = known.firstIndex(where: { $0.role == row.role && $0.day == row.day }) {
            known[index] = row
        } else {
            known.append(row)
        }
    }
}
