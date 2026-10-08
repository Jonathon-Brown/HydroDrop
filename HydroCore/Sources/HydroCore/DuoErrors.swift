import Foundation

// Every way a Duo request can fail, as one Swift error, and what to do about each (final
// design §4.4, §6.7). The API client turns a response into one of these; nothing above it
// ever looks at a status code or a body.

/// The contract's error codes (`openapi.json`, `Error.code`), all 34.
public enum DuoErrorCode: String, CaseIterable, Sendable {
    case schema
    case idempotencyMismatch = "idempotency_mismatch"
    case unauthenticated
    case deviceRevoked = "device_revoked"
    case banned
    case blocked
    case notPartner = "not_partner"
    case attestRequired = "attest_required"
    case attestInvalid = "attest_invalid"
    case duoUnknown = "duo_unknown"
    case inviteUnknown = "invite_unknown"
    case inviteTaken = "invite_taken"
    case inviteOwn = "invite_own"
    case wrongPurpose = "wrong_purpose"
    case alreadyInDuo = "already_in_duo"
    case duoLimit = "duo_limit"
    case deviceLimit = "device_limit"
    case pendingExists = "pending_exists"
    case memberNotFresh = "member_not_fresh"
    case targetActive = "target_active"
    case duoEnded = "duo_ended"
    case duoPending = "duo_pending"
    case partnerAlreadyMet = "partner_already_met"
    case conflict
    case payloadTooLarge = "payload_too_large"
    case nameRejected = "name_rejected"
    case presetUnknown = "preset_unknown"
    case dayOutOfRange = "day_out_of_range"
    case senderDayOutOfRange = "sender_day_out_of_range"
    case upgradeRequired = "upgrade_required"
    case termsRequired = "terms_required"
    case nudgeLimit = "nudge_limit"
    case rateLimited = "rate_limited"
    case maintenance
}

/// What came with an error: enough to explain it, show a reference and honour `Retry-After`.
public struct DuoErrorContext: Equatable, Sendable {
    public var httpStatus: Int
    /// `X-Request-Id`, which the error sheet shows in small print as `(ref <id>)`.
    public var requestID: String?
    /// Whole seconds, from `Retry-After` or the body's `retry_after_s`.
    public var retryAfter: Int?
    public var details: DuoWireErrorDetails?

    public init(httpStatus: Int, requestID: String? = nil, retryAfter: Int? = nil, details: DuoWireErrorDetails? = nil) {
        self.httpStatus = httpStatus
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.details = details
    }
}

/// One case per error code, each with its context (§6.7: "`DuoTransportError` maps 1:1"), and
/// two of the client's own: no connection, and an answer that could not be read.
public enum DuoTransportError: Error, Equatable, Sendable {
    case schema(DuoErrorContext)
    case idempotencyMismatch(DuoErrorContext)
    case unauthenticated(DuoErrorContext)
    case deviceRevoked(DuoErrorContext)
    case banned(DuoErrorContext)
    case blocked(DuoErrorContext)
    case notPartner(DuoErrorContext)
    case attestRequired(DuoErrorContext)
    case attestInvalid(DuoErrorContext)
    case duoUnknown(DuoErrorContext)
    case inviteUnknown(DuoErrorContext)
    case inviteTaken(DuoErrorContext)
    case inviteOwn(DuoErrorContext)
    case wrongPurpose(DuoErrorContext)
    case alreadyInDuo(DuoErrorContext)
    case duoLimit(DuoErrorContext)
    case deviceLimit(DuoErrorContext)
    case pendingExists(DuoErrorContext)
    case memberNotFresh(DuoErrorContext)
    case targetActive(DuoErrorContext)
    case duoEnded(DuoErrorContext)
    case duoPending(DuoErrorContext)
    case partnerAlreadyMet(DuoErrorContext)
    case conflict(DuoErrorContext)
    case payloadTooLarge(DuoErrorContext)
    case nameRejected(DuoErrorContext)
    case presetUnknown(DuoErrorContext)
    case dayOutOfRange(DuoErrorContext)
    case senderDayOutOfRange(DuoErrorContext)
    case upgradeRequired(DuoErrorContext)
    case termsRequired(DuoErrorContext)
    case nudgeLimit(DuoErrorContext)
    case rateLimited(DuoErrorContext)
    case maintenance(DuoErrorContext)
    /// No connection, a timeout or a dropped one: the request may or may not have arrived.
    case offline
    /// An answer that is not the contract's, with the status it came with: a 2xx whose body
    /// does not decode, or an error body whose code this build does not know.
    case unreadable(httpStatus: Int, requestID: String?)

    public init(code: DuoErrorCode, context: DuoErrorContext) {
        switch code {
        case .schema: self = .schema(context)
        case .idempotencyMismatch: self = .idempotencyMismatch(context)
        case .unauthenticated: self = .unauthenticated(context)
        case .deviceRevoked: self = .deviceRevoked(context)
        case .banned: self = .banned(context)
        case .blocked: self = .blocked(context)
        case .notPartner: self = .notPartner(context)
        case .attestRequired: self = .attestRequired(context)
        case .attestInvalid: self = .attestInvalid(context)
        case .duoUnknown: self = .duoUnknown(context)
        case .inviteUnknown: self = .inviteUnknown(context)
        case .inviteTaken: self = .inviteTaken(context)
        case .inviteOwn: self = .inviteOwn(context)
        case .wrongPurpose: self = .wrongPurpose(context)
        case .alreadyInDuo: self = .alreadyInDuo(context)
        case .duoLimit: self = .duoLimit(context)
        case .deviceLimit: self = .deviceLimit(context)
        case .pendingExists: self = .pendingExists(context)
        case .memberNotFresh: self = .memberNotFresh(context)
        case .targetActive: self = .targetActive(context)
        case .duoEnded: self = .duoEnded(context)
        case .duoPending: self = .duoPending(context)
        case .partnerAlreadyMet: self = .partnerAlreadyMet(context)
        case .conflict: self = .conflict(context)
        case .payloadTooLarge: self = .payloadTooLarge(context)
        case .nameRejected: self = .nameRejected(context)
        case .presetUnknown: self = .presetUnknown(context)
        case .dayOutOfRange: self = .dayOutOfRange(context)
        case .senderDayOutOfRange: self = .senderDayOutOfRange(context)
        case .upgradeRequired: self = .upgradeRequired(context)
        case .termsRequired: self = .termsRequired(context)
        case .nudgeLimit: self = .nudgeLimit(context)
        case .rateLimited: self = .rateLimited(context)
        case .maintenance: self = .maintenance(context)
        }
    }

    /// The code, or nil for `offline` and `unreadable`.
    public var code: DuoErrorCode? {
        switch self {
        case .schema: return .schema
        case .idempotencyMismatch: return .idempotencyMismatch
        case .unauthenticated: return .unauthenticated
        case .deviceRevoked: return .deviceRevoked
        case .banned: return .banned
        case .blocked: return .blocked
        case .notPartner: return .notPartner
        case .attestRequired: return .attestRequired
        case .attestInvalid: return .attestInvalid
        case .duoUnknown: return .duoUnknown
        case .inviteUnknown: return .inviteUnknown
        case .inviteTaken: return .inviteTaken
        case .inviteOwn: return .inviteOwn
        case .wrongPurpose: return .wrongPurpose
        case .alreadyInDuo: return .alreadyInDuo
        case .duoLimit: return .duoLimit
        case .deviceLimit: return .deviceLimit
        case .pendingExists: return .pendingExists
        case .memberNotFresh: return .memberNotFresh
        case .targetActive: return .targetActive
        case .duoEnded: return .duoEnded
        case .duoPending: return .duoPending
        case .partnerAlreadyMet: return .partnerAlreadyMet
        case .conflict: return .conflict
        case .payloadTooLarge: return .payloadTooLarge
        case .nameRejected: return .nameRejected
        case .presetUnknown: return .presetUnknown
        case .dayOutOfRange: return .dayOutOfRange
        case .senderDayOutOfRange: return .senderDayOutOfRange
        case .upgradeRequired: return .upgradeRequired
        case .termsRequired: return .termsRequired
        case .nudgeLimit: return .nudgeLimit
        case .rateLimited: return .rateLimited
        case .maintenance: return .maintenance
        case .offline, .unreadable: return nil
        }
    }

    public var context: DuoErrorContext? {
        switch self {
        case .schema(let c), .idempotencyMismatch(let c), .unauthenticated(let c), .deviceRevoked(let c), .banned(let c),
             .blocked(let c), .notPartner(let c), .attestRequired(let c), .attestInvalid(let c), .duoUnknown(let c),
             .inviteUnknown(let c), .inviteTaken(let c), .inviteOwn(let c), .wrongPurpose(let c), .alreadyInDuo(let c),
             .duoLimit(let c), .deviceLimit(let c), .pendingExists(let c), .memberNotFresh(let c), .targetActive(let c),
             .duoEnded(let c), .duoPending(let c), .partnerAlreadyMet(let c), .conflict(let c), .payloadTooLarge(let c),
             .nameRejected(let c), .presetUnknown(let c), .dayOutOfRange(let c), .senderDayOutOfRange(let c),
             .upgradeRequired(let c), .termsRequired(let c), .nudgeLimit(let c), .rateLimited(let c), .maintenance(let c):
            return c
        case .offline, .unreadable:
            return nil
        }
    }

    /// `X-Request-Id`, for the `(ref ...)` line under an error.
    public var requestID: String? {
        switch self {
        case .unreadable(_, let id): return id
        default: return context?.requestID
        }
    }

    /// The HTTP status of the answer, or nil for `offline`. `context` is nil for an unreadable answer,
    /// so reading the status through it used to drop exactly the answers Diagnostics exists to explain
    /// (a 2xx that does not decode, a WAF's 5xx), and they all read alike in the export.
    public var httpStatus: Int? {
        switch self {
        case .unreadable(let status, _): return status
        default: return context?.httpStatus
        }
    }
}

/// What to do after a failed request. The sync engine, the op queue and the membership
/// flows all switch over this rather than over the error (§6.7's "Client behaviour" column).
public enum DuoRetry {
    /// `Retry-After` is honoured with this as its floor (§6.7: min 30 s).
    public static let minimumDelay: TimeInterval = 30
    /// When a failure says nothing about when to try again (a WAF page's 429 reads as 60 s, §6.0).
    public static let fallbackDelay: TimeInterval = 60
    /// The longest a `Retry-After` is believed. The server's own longest wait is a day (the daily
    /// windows, the redeem lock, `nudge_limit`), but a proxy's 503 can carry any number, and one
    /// that said 2147483647 would park the queue for sixty-eight years.
    public static let maximumDelay: TimeInterval = 2 * 86_400
    /// Retries in a row before waiting for the next foreground (§6.7: max 3).
    public static let maximumAttempts = 3

    public enum Verdict: Equatable, Sendable {
        /// `duo_unknown` or `duo_ended`: the duo is over. Mark it ended here, say nothing.
        case ended
        /// Try again after this long: rate limits, maintenance, 5xx and no connection. The
        /// retry of an idempotent (I) request replays its `Idempotency-Key` and its bytes;
        /// `createDevice` and `rotate` have no key, so a flow that re-sends either on this
        /// verdict has to know what it is doing (a second `createDevice` makes a second member).
        case retry(after: TimeInterval)
        /// The task was cancelled (the person left the screen, a newer refresh took over). Nothing
        /// is known about the request or the server: change nothing, tell no one, keep any
        /// in-flight record, and do not schedule a re-send. The next refresh or tap tries again.
        case cancelled
        /// 401 `unauthenticated`: this identity is gone. Discard it; a new one is made on the
        /// next Create or Join tap, never silently (§3.4).
        case reidentify
        /// 401 `device_revoked`: another phone took this identity over (§3.4, §3.5).
        case disconnected
        /// 426: writes are off; the card stays (§6.7).
        case upgradeRequired
        /// 428: show the terms sheet, then send again.
        case termsRequired
        /// 403 `banned`.
        case banned
        /// Anything else: log it, tell the person in words, do not retry.
        case fail
    }

    public static func verdict(for error: Error) -> Verdict {
        // A cancelled task says nothing about the request or the server. As `.fail` it would be
        // written to Diagnostics and told to the person in words, for something that did not go
        // wrong; as `.retry` it would invite a re-send a minute after the person left the screen.
        // It is its own verdict, and `noteFailure` does not log it.
        if error is CancellationError { return .cancelled }
        guard let error = error as? DuoTransportError else { return .fail }
        switch error {
        case .duoUnknown, .duoEnded:
            return .ended
        case .rateLimited(let context), .maintenance(let context):
            return .retry(after: delay(for: context))
        case .offline:
            return .retry(after: fallbackDelay)
        case .unreadable(let status, _) where status >= 500 || status == 429:
            // 429 as well as 5xx: the contract says to dispatch on the HTTP status first, and a
            // rate limit whose body this build cannot read (a code a newer server added) is
            // still a rate limit, to be waited out rather than failed (§6.7). An unreadable 2xx
            // is not here on purpose: the request landed and its answer cannot be read, and a
            // replay is answered from the server's record with the same bytes, so retrying it
            // would repeat for ever at every foreground and hold up every request queued behind
            // it. It is a failure the person is told about; a flow that started an (I) request
            // keeps its in-flight record (the client's header comment says which outcomes keep
            // it), so the next tap replays the same key instead of starting a second join.
            return .retry(after: fallbackDelay)
        case .unauthenticated(let context) where context.httpStatus == 401:
            // Only a real 401 from the server means this identity is gone. The client's own
            // "no credential" error carries status 0, and discarding on that would forget an
            // identity that was never sent, so it falls through to `.fail`.
            return .reidentify
        case .deviceRevoked:
            return .disconnected
        case .upgradeRequired:
            return .upgradeRequired
        case .termsRequired:
            return .termsRequired
        case .banned:
            return .banned
        default:
            return .fail
        }
    }

    private static func delay(for context: DuoErrorContext) -> TimeInterval {
        guard let seconds = context.retryAfter else { return fallbackDelay }
        return min(maximumDelay, max(minimumDelay, TimeInterval(seconds)))
    }
}

/// Where an error is being shown, which decides some of its words.
public enum DuoMessageContext: Equatable, Sendable {
    /// Creating, peeking or joining: the join sheet's wording.
    case invite
    /// Anything else on the Duo screen.
    case general
    /// A nudge, with the partner's name for "<Partner> already met their goal".
    case nudge(partner: String)
    /// Delete my Duo data. It is online only and nothing is queued, so a line that says the duo
    /// "will catch up" would promise something that will not happen.
    case deletion
}

/// The words for an error, from the final design's approved table (§4.4, §6.7, §3.4). Codes
/// with no approved wording fall back to the general line with the request reference, and
/// are listed as copy awaiting approval in the plan: `device_limit`, `terms_required`.
public enum DuoUserMessage {
    public static let generic = "That did not work. Please try again."

    public static func text(for error: Error, context: DuoMessageContext = .general) -> String {
        guard let error = error as? DuoTransportError else { return generic }
        switch error {
        case .offline:
            return "No connection right now. Try again in a bit."
        case .inviteUnknown:
            return "That invite is no longer open. Ask for a new one."
        case .inviteTaken:
            return "This invite is not open to you anymore. Someone else may have joined first. Ask for a new one."
        case .inviteOwn:
            return "That is your own invite. Send it to the person you want to team up with."
        case .duoLimit(let failure), .alreadyInDuo(let failure):
            return limitMessage(active: failure.details?.activeDuos ?? failure.details?.max)
        case .blocked:
            return "This person can't be paired with you."
        case .wrongPurpose:
            return "That code is for something else. Ask for a duo invite."
        case .memberNotFresh:
            return "Finish or leave the duo you started on this phone first."
        case .attestRequired, .attestInvalid:
            return "HydroDrop could not verify this phone. Try again in a few minutes."
        case .rateLimited:
            return "Too many tries. Wait a bit and try again."
        case .maintenance, .unreadable:
            if case .invite = context { return "Joining is paused for a few minutes. Try again soon." }
            if case .deletion = context { return withReference(generic, error) }
            return "HydroDrop's duo service is not available right now. Your duo will catch up when it is."
        case .nameRejected:
            return "Please choose a different name."
        case .upgradeRequired:
            return "Update HydroDrop to keep using Duo Streaks."
        case .banned:
            return "Duo Streaks are not available for this device. Contact support@hydrodrop.us."
        case .deviceRevoked:
            return "This phone was disconnected from the duo"
        case .partnerAlreadyMet:
            if case .nudge(let partner) = context { return "\(partner) already met their goal. Nothing to nudge." }
            return withReference(generic, error)
        case .nudgeLimit:
            return "That is all your nudges for today."
        default:
            return withReference(generic, error)
        }
    }

    /// `You are already in N duos.` The final design's sentence has an N in it; a free
    /// person's limit is one, where "1 duos" would read wrong, so one reads "a duo". That
    /// singular is the old TestFlight wording and awaits Jonathon's approval (plan P2).
    private static func limitMessage(active: Int?) -> String {
        if active == 1 { return "You are already in a duo. Leave it first, then open the invite again." }
        let count = active.map(String.init) ?? "5"
        return "You are already in \(count) duos. Leave one first, then open the invite again."
    }

    private static func withReference(_ text: String, _ error: DuoTransportError) -> String {
        // The id is the server's (or whatever sits in front of it) to write, so it is shown only
        // if it passes the filter Diagnostics keeps ids under: an id of 200 odd characters came
        // out as a 295-character line on the error sheet, carrying whatever it was made to say.
        guard let id = DuoDiagnostics.usableRequestID(error.requestID) else { return text }
        return "\(text) (ref \(id))"
    }
}
