import Foundation

/// What Settings > Duo Streaks > Diagnostics shows, kept in the cache so it survives a launch
/// (final design §10.8): the last five transport errors, and per duo the cursor, the last
/// fetch and the last write and the last error. It holds ids and times and error codes, and
/// never a name, a drink or a token.
public struct DuoDiagnostics: Codable, Equatable, Sendable {
    public struct ErrorRecord: Codable, Equatable, Sendable {
        /// The contract's code, or `offline` / `unreadable`.
        public var code: String
        public var http: Int?
        public var requestID: String?
        public var at: Date

        public init(code: String, http: Int?, requestID: String?, at: Date) {
            self.code = code
            self.http = http
            self.requestID = requestID
            self.at = at
        }
    }

    /// One response the app got from the service, success or failure: what Diagnostics lists so
    /// a person (or support) can quote a request id. Only the HTTP status, the id and the time:
    /// never a path, a body or a duo id, so a record says nothing about who or what was asked.
    public struct RequestRecord: Codable, Equatable, Sendable {
        public var status: Int
        public var requestID: String
        public var at: Date

        public init(status: Int, requestID: String, at: Date) {
            self.status = status
            self.requestID = requestID
            self.at = at
        }
    }

    public struct PerDuo: Codable, Equatable, Sendable {
        public var seq: Int64
        public var cursor: Int64
        public var lastFetchAt: Date?
        public var lastWriteAt: Date?
        public var lastError: ErrorRecord?

        public init(seq: Int64 = 0, cursor: Int64 = 0, lastFetchAt: Date? = nil, lastWriteAt: Date? = nil, lastError: ErrorRecord? = nil) {
            self.seq = seq
            self.cursor = cursor
            self.lastFetchAt = lastFetchAt
            self.lastWriteAt = lastWriteAt
            self.lastError = lastError
        }
    }

    public static let keepErrors = 5
    public static let keepRequests = 10
    /// The longest request id kept. The server's is a Cloudflare ray id (about 20 characters);
    /// anything longer or with other characters in it is not one and is not kept.
    public static let maximumRequestIDLength = 64

    /// Newest first.
    public var recentErrors: [ErrorRecord]
    /// The last `keepRequests` responses of any kind, newest first, so a clean run still has
    /// request ids to quote (the errors above are the only ones that carry one otherwise).
    public var recentRequests: [RequestRecord]
    /// Keyed by the duo's lowercase id.
    public var duos: [String: PerDuo]
    public var lastUploadedZone: String?
    public var lastUploadedWindowStart: Int?
    public var lastUploadedWindowEnd: Int?
    public var lastUploadedEnabled: Bool?
    public var lastUploadAt: Date?

    public init(recentErrors: [ErrorRecord] = [], recentRequests: [RequestRecord] = [], duos: [String: PerDuo] = [:],
                lastUploadedZone: String? = nil, lastUploadedWindowStart: Int? = nil, lastUploadedWindowEnd: Int? = nil,
                lastUploadedEnabled: Bool? = nil, lastUploadAt: Date? = nil) {
        self.recentErrors = recentErrors
        self.recentRequests = recentRequests
        self.duos = duos
        self.lastUploadedZone = lastUploadedZone
        self.lastUploadedWindowStart = lastUploadedWindowStart
        self.lastUploadedWindowEnd = lastUploadedWindowEnd
        self.lastUploadedEnabled = lastUploadedEnabled
        self.lastUploadAt = lastUploadAt
    }

    /// Notes a failed request, against a duo when it was about one.
    public mutating func record(_ error: Error, duoID: UUID?, now: Date) {
        let record: ErrorRecord
        if let error = error as? DuoTransportError {
            record = ErrorRecord(code: error.code?.rawValue ?? (error == .offline ? "offline" : "unreadable"),
                                 http: error.httpStatus, requestID: Self.usableRequestID(error.requestID), at: now)
        } else {
            record = ErrorRecord(code: "other", http: nil, requestID: nil, at: now)
        }
        recentErrors.insert(record, at: 0)
        if recentErrors.count > Self.keepErrors { recentErrors.removeLast(recentErrors.count - Self.keepErrors) }
        if let duoID {
            let key = duoID.uuidString.lowercased()
            var entry = duos[key] ?? PerDuo()
            entry.lastError = record
            duos[key] = entry
        }
    }

    /// Notes a response: its status and `X-Request-Id`. A response with no usable id (a WAF page,
    /// an id with odd characters or an absurd length) leaves nothing, since there is nothing to quote.
    public mutating func recordRequest(status: Int, requestID: String?, at: Date) {
        guard let requestID = Self.usableRequestID(requestID) else { return }
        recentRequests.insert(RequestRecord(status: status, requestID: requestID, at: at), at: 0)
        if recentRequests.count > Self.keepRequests { recentRequests.removeLast(recentRequests.count - Self.keepRequests) }
    }

    /// The id if it is something safe to keep and to print (ASCII letters, digits and `-_.`, of
    /// a sane length), else nil. Both ways in, a response and a failure, go through this: an id
    /// taken off a failure's body used to be stored unchecked, and a body is the server's (or
    /// whatever sits in front of it) to write.
    static func usableRequestID(_ requestID: String?) -> String? {
        guard let requestID, !requestID.isEmpty, requestID.count <= maximumRequestIDLength,
              requestID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return nil }
        return requestID
    }

    public mutating func recordFetch(duoID: UUID, seq: Int64, cursor: Int64, at: Date) {
        let key = duoID.uuidString.lowercased()
        var entry = duos[key] ?? PerDuo()
        entry.seq = seq
        entry.cursor = cursor
        entry.lastFetchAt = at
        duos[key] = entry
    }

    public mutating func recordWrite(duoID: UUID, at: Date) {
        let key = duoID.uuidString.lowercased()
        var entry = duos[key] ?? PerDuo()
        entry.lastWriteAt = at
        duos[key] = entry
    }

    public mutating func recordPushUpload(zone: String?, windowStart: Int?, windowEnd: Int?, enabled: Bool, at: Date) {
        lastUploadedZone = zone
        lastUploadedWindowStart = windowStart
        lastUploadedWindowEnd = windowEnd
        lastUploadedEnabled = enabled
        lastUploadAt = at
    }

    public mutating func forget(duoID: UUID) {
        duos[duoID.uuidString.lowercased()] = nil
    }
}

/// The things Duo keeps as plain numbers and names, so no stage spells one differently.
public enum DuoProtocolConstants {
    /// `TERMS_VERSION` today (§11.8). The terms the person accepted ride in `POST /devices`
    /// and `PATCH /me` as `terms_version`.
    public static let termsVersion = 1
    /// An invite code lasts 48 hours (§4.1), and so does a received one on this phone.
    public static let inviteLifetime: TimeInterval = 48 * 60 * 60
    /// "Not them? Leave & block" is shown for 24 hours from the server's `joined_at` (§11.8).
    public static let notThemWindow: TimeInterval = 24 * 60 * 60
    /// The card offers "Reconnect <name>'s new phone" when the partner's last write is older
    /// than today minus this many days (§3.5).
    public static let reconnectSilentDays = 3
    /// `GET /me` is asked for at most this often during a session (§3.4: only if a duo is
    /// cached or the Duo screen opens).
    public static let meRefreshInterval: TimeInterval = 60 * 60
    /// The most devices one member may link (D49).
    public static let maxLinkedDevices = 5
    /// A duo ended this long ago is gone from the server (§12.1).
    public static let endedDuoLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// A nudge that could not be sent is retried after each of these, then at the next foreground (§6.6).
    public static let nudgeRetryDelays: [TimeInterval] = [30, 60, 120]
}
