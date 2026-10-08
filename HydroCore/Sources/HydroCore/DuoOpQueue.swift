import Foundation

/// The op queue of final design §10.1 as a value: the requests that must reach the server even
/// if the app is closed first (`POST /duos/{id}/leave`, `POST /duos/{id}/block`, `PATCH /me`,
/// `PUT /devices/me/push` and `DELETE /devices/me/push`), oldest first, and the rule for what one
/// answer does to the entry that was sent. The app's `DuoOpQueueService` keeps it in `duo.ops.v1`
/// and sends it; Android keeps the same queue in Room and is held to the same table by the KV20
/// vectors, so the rule lives here, apart from any network.
///
/// First in, first out within a group of kinds, and no coalescing (D74, 2026-10-08). The groups
/// are the exits (leave and block), the profile (`PATCH /me`) and the push token (its upload and
/// its removal): within a group the order is strict, because only the person's last word may win
/// and only the order says which that was (two renames, an upload and then a removal). Across
/// groups nothing depends on order, and a strict order across them let a rate-limited rename,
/// whose `Retry-After` can run to the next UTC midnight, hold a Block back for up to a day. So an
/// entry that has to wait stops its own group only.
public struct DuoOpQueue: Equatable, Sendable {
    /// The groups whose entries keep their order among themselves and nobody else's (D74).
    public enum Group: String, CaseIterable, Sendable {
        /// Leave and block: what ends a duo or bars a person, the requests a person most needs to land.
        case exits
        /// `PATCH /me`: the name, the skin, the terms version.
        case profile
        /// `PUT` and `DELETE /devices/me/push`.
        case push
    }

    public static func group(of kind: DuoOpKind) -> Group {
        switch kind {
        case .leave, .block: return .exits
        case .updateMe: return .profile
        case .registerPush, .unregisterPush: return .push
        }
    }

    /// What `enqueue` did with an entry.
    public enum EnqueueResult: Equatable, Sendable {
        case added
        /// The very same entry was already queued: one request is one entry.
        case alreadyQueued
        /// Another entry is queued under the same key with other contents. The first is kept: its
        /// bytes may already have reached the server under that key, and a replay with other bytes
        /// would be refused `422 idempotency_mismatch`. No caller should ever do this (every key is
        /// a fresh UUID), so the app treats it as a programming error in Debug.
        case conflicting
    }

    public private(set) var ops: [DuoQueuedOp]

    public init(_ ops: [DuoQueuedOp] = []) {
        self.ops = ops
    }

    public var isEmpty: Bool { ops.isEmpty }

    /// The oldest entry of all.
    public var next: DuoQueuedOp? { ops.first }

    /// The entry to send next: the oldest one that is at the head of its own group, of a group not
    /// in `blocked`, and, when `keys` is given, one of those keys (the entries a drain found when it
    /// began, so entries queued while it runs wait for the next drain instead of keeping this one
    /// going for as long as they keep coming).
    public func next(skipping blocked: Set<Group>, among keys: Set<String>? = nil) -> DuoQueuedOp? {
        var seen = Set<Group>()
        for op in ops {
            let group = Self.group(of: op.kind)
            guard seen.insert(group).inserted else { continue }
            guard !blocked.contains(group) else { continue }
            if let keys, !keys.contains(op.key) { continue }
            return op
        }
        return nil
    }

    /// Appends an entry, unless one with its key is already queued (see `EnqueueResult`). An entry
    /// is its key (`DuoQueuedOp.id`), so the same entry handed over twice is kept once: two copies
    /// would be sent twice, and the first answer's removal by key would take both. Two different
    /// requests always have two keys, so this is not coalescing.
    @discardableResult
    public mutating func enqueue(_ op: DuoQueuedOp) -> EnqueueResult {
        if let queued = ops.first(where: { $0.key == op.key }) {
            return queued == op ? .alreadyQueued : .conflicting
        }
        ops.append(op)
        return .added
    }

    /// Removes the entry with this key, wherever it is. Removal is by key, never "the first",
    /// because the entry a request was sent for may have moved or gone while the request was out
    /// (a Clear, a discard), and taking the first would then take a request that was never sent.
    public mutating func remove(key: String) {
        ops.removeAll { $0.key == key }
    }

    /// Removes every leave and block for one duo. The duo id is compared in lowercase, the spelling
    /// every entry is made with (`DuoQueuedOp.leave`, `.block`), so an id read back in another case
    /// still matches.
    public mutating func removeAll(forDuo duoID: UUID) {
        let id = duoID.uuidString.lowercased()
        ops.removeAll { $0.duoID?.lowercased() == id }
    }

    /// Removes the entries that only mean something for the identity they were made with: a
    /// rename and a push-token upload or removal. A leave or a block stays: under another member it
    /// answers 404 and is done, and under the member a Reconnect brought back it is exactly right.
    public mutating func removeIdentityBound() {
        ops.removeAll { Self.group(of: $0.kind) != .exits }
    }

    public mutating func removeAll() {
        ops = []
    }
}

// The queue is written to the defaults as the bare array of entries (`DuoCache.saveOps`), so its
// own encoding is that array too: a queue saved either way reads back either way.
extension DuoOpQueue: Codable {
    public init(from decoder: Decoder) throws {
        ops = try decoder.singleValueContainer().decode([DuoQueuedOp].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ops)
    }
}

// MARK: - What one answer does to the entry

extension DuoOpQueue {
    /// What happens to an entry after one attempt to send it.
    public enum Disposition: Equatable, Sendable {
        /// It went through, or the server says there is nothing left to do (a leave or block of a
        /// duo it no longer has): remove it, and apply what the answer says.
        case done
        /// A refusal the server judged and would repeat: remove it for good. A drop is final; the
        /// local state it changed (an ended card) stays as it is, unless the refusal says the
        /// person is barred (see `DuoOpQueueService`).
        case drop
        /// "Not now": keep it, and try it again after this long (a rate limit, maintenance, a 5xx,
        /// no connection). Nothing behind it in its group is sent first.
        case wait(after: TimeInterval)
        /// Keep it, send nothing more now, and schedule nothing: the next trigger (a foreground, a
        /// connection coming back, the background path) tries again. Only for an outcome that says
        /// nothing at all about the request: the task was cancelled, or nothing left the phone or
        /// came back (status 0: the client had no credential to send with, or no HTTP response
        /// arrived). The request may have landed in the second case, so it is kept and replayed
        /// with the same bytes and the same key, which the server answers from its record (§6.0).
        case hold
        /// The server no longer knows this identity (401 `unauthenticated`): every queued request
        /// was made with it, so every one of them is useless. Empty the queue.
        case discardAll
    }

    /// The rule of §10.1, "an entry is removed on 2xx or any 4xx other than 401/429; `duo_unknown`
    /// and `duo_ended` on a leave count as done; `device_revoked` keeps the local ended state and
    /// drops the op", read the way the contract asks a client to read any answer: by the HTTP status
    /// first, then by the code where the status alone does not decide.
    ///
    /// - No error: done.
    /// - `CancellationError`: hold. Nothing is known about the request.
    /// - Any error that is not a `DuoTransportError` (an entry whose saved body no longer decodes, a
    ///   request that cannot be encoded): drop. It could never be sent, and kept it would hold up
    ///   every entry behind it for ever.
    /// - An answer that cannot be read: by its status. The endpoint's own success status
    ///   (`successStatus(of:)`) is done: the request landed, and nothing of its body is applied (an
    ///   entry that was kept instead was sent again at every trigger, for ever, and held every
    ///   entry behind it, though the server had already done what it asked). Any other 2xx is not
    ///   the server's answer (the client reads one only when it is not the endpoint's status, as a
    ///   school's filter answering a block's URL with a 200 page) and waits like maintenance. Status
    ///   0 (no HTTP response at all) holds. A 429 or a 5xx waits, any other 4xx but a 401 drops, and
    ///   anything else waits.
    /// - `unauthenticated`: discard all at a real 401; hold at status 0, which is the client's own
    ///   "no credential right now", not the server's word (an identity the server forgot comes back
    ///   as a 401, and discarding on the client's own refusal would throw away requests that were
    ///   never sent, for a credential that may be there at the next trigger).
    /// - `device_revoked`: drop. The ended card stays ended. The rest of the queue is still sent:
    ///   a superseded phone keeps leave and block for its 30 days (§3.5, D33) while its `PATCH /me`
    ///   and push calls answer `device_revoked`, so one revoked answer says nothing about the next.
    /// - `duo_unknown` or `duo_ended` on a leave or a block: done. Elsewhere they are judged by status.
    /// - `rate_limited`, `maintenance` (whatever the status: the classifier makes a WAF 403, a bare
    ///   401 and any 5xx `maintenance`, none of them the server's refusal) and `offline`: wait, for
    ///   `DuoRetry`'s delay (`Retry-After` with its 30-second floor and two-day ceiling, else 60 s).
    /// - Anything else, by status: a 429 or a 5xx waits like maintenance; a 4xx other than 401 and
    ///   429 drops (403 `banned` on a leave or block, 422 `name_rejected`, 426); a coded error at
    ///   status 0 drops (the client refused to build the request, a duo id that is not one, say, and
    ///   it never will); anything else (a 401 with a code that is neither identity code) waits.
    public static func disposition(for op: DuoQueuedOp, error: Error?) -> Disposition {
        guard let error else { return .done }
        if error is CancellationError { return .hold }
        guard let failure = error as? DuoTransportError else { return .drop }
        switch failure {
        case .offline:
            return wait(failure)
        case .unreadable(let status, _):
            switch status {
            case 0: return .hold
            case 200...299:
                // Only the endpoint's own success status says the request landed. Any other 2xx
                // (a filtering proxy's 200 page where the server answers 204) never reached it.
                return status == successStatus(of: op.kind) ? .done : wait(.maintenance(DuoErrorContext(httpStatus: status)))
            case 429, 500...599: return wait(failure)
            case 400...499 where status != 401: return .drop
            default: return wait(.maintenance(DuoErrorContext(httpStatus: status)))
            }
        case .unauthenticated(let context):
            return context.httpStatus == 401 ? .discardAll : .hold
        case .deviceRevoked:
            return .drop
        case .duoUnknown(let context), .duoEnded(let context):
            if op.kind == .leave || op.kind == .block { return .done }
            return byStatus(context)
        case .rateLimited, .maintenance:
            return wait(failure)
        default:
            return failure.context.map(byStatus) ?? .hold
        }
    }

    /// The status contract-v1 answers each kind's success with: 200 with a body for a leave and a
    /// `PATCH /me`, 204 with none for a block and both push calls.
    public static func successStatus(of kind: DuoOpKind) -> Int {
        switch kind {
        case .leave, .updateMe: return 200
        case .block, .registerPush, .unregisterPush: return 204
        }
    }

    /// Whether a wait is the server's own "not before" (a rate limit, maintenance, a 5xx), which a
    /// trigger inside it must respect, rather than no connection, which a trigger (a connection
    /// coming back, above all) should try again at once.
    public static func isServerWait(_ error: Error?) -> Bool {
        guard let failure = error as? DuoTransportError else { return false }
        if case .offline = failure { return false }
        return true
    }

    /// A coded answer that the code alone does not settle.
    private static func byStatus(_ context: DuoErrorContext) -> Disposition {
        switch context.httpStatus {
        case 0: return .drop
        case 429, 500...599: return wait(.maintenance(context))
        case 400...499 where context.httpStatus != 401: return .drop
        default: return wait(.maintenance(context))
        }
    }

    /// The delay `DuoRetry` gives the error, so the queue and every other caller wait alike. Every
    /// error this is called with is one the verdict answers with a retry.
    private static func wait(_ error: DuoTransportError) -> Disposition {
        if case .retry(let after) = DuoRetry.verdict(for: error) { return .wait(after: after) }
        return .wait(after: DuoRetry.fallbackDelay)
    }
}
