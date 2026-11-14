import Foundation

/// What `PUT /devices/me/push` says, and whether it is worth saying now (final design §3.1,
/// §6.2, §9.6, D36). Pure: the app's push service gathers the token, the zone, the waking window
/// and the Duo toggle, asks this what to send, and puts the answer in the op queue.
///
/// The token is compared as a hash (`Snapshot.tokenHash`), never kept as itself: the app records
/// what the server was last known to hold after each 204, and the token is a device identifier
/// the person never chose to keep on disk. HydroCore has no hashing of its own (it imports only
/// Foundation, and the hash has to be the same everywhere it is read), so the app computes the
/// hash and hands it in.
public enum DuoPushUploadPlan {
    /// Why the upload is being looked at. The app has its own `DuoPushUploadReason`, which
    /// HydroCore cannot see, and maps it one to one.
    public enum Trigger: String, CaseIterable, Sendable {
        /// The first time the app became active in this process.
        case launch
        /// iOS handed over a token the server is not known to hold.
        case tokenChanged
        /// The reminders' waking window moved.
        case windowChanged
        /// The Duo notifications toggle was turned on or off.
        case toggleChanged
        /// The phone's time zone or its clock changed.
        case zoneChanged
        /// A background refresh ran.
        case background
        /// A duo was made, joined or reconnected, so there is now a reason to hold a token.
        case duoStarted
    }

    /// What one upload tells the server, with the token as its hash: what the app records after
    /// a 204, and what the next upload is compared with.
    public struct Snapshot: Equatable, Sendable {
        public var tokenHash: String
        public var environment: DuoAPNsEnvironment?
        public var zone: String?
        public var windowStart: Int?
        public var windowEnd: Int?
        public var enabled: Bool

        public init(tokenHash: String, environment: DuoAPNsEnvironment?, zone: String?, windowStart: Int?, windowEnd: Int?, enabled: Bool) {
            self.tokenHash = tokenHash
            self.environment = environment
            self.zone = zone
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.enabled = enabled
        }

        /// What `request` asks the server to hold, for a token whose hash is `tokenHash`.
        public init(_ request: DuoWireRegisterPushRequest, tokenHash: String) {
            self.init(tokenHash: tokenHash, environment: request.apnsEnv.flatMap(DuoAPNsEnvironment.init(rawValue:)), zone: request.tz,
                      windowStart: request.wakeStartMin, windowEnd: request.wakeEndMin, enabled: request.notificationsEnabled)
        }
    }

    /// The last push request still waiting in the op queue. The queue is first in, first out,
    /// so once it has settled the server holds what this one says, whatever came before it.
    public enum Queued: Equatable, Sendable {
        case upload(Snapshot, firstUpload: Bool)
        case removal
    }

    public struct Decision: Equatable, Sendable {
        /// Whether to put a new upload in the queue.
        public var upload: Bool
        /// Whether that upload is the first of this token by this device, which is the one the
        /// API client attests as `push_register` (§6.2, §11.2). The later ones are not.
        public var firstUpload: Bool

        public init(upload: Bool, firstUpload: Bool) {
            self.upload = upload
            self.firstUpload = firstUpload
        }
    }

    /// The token as the wire carries it: the lowercase hex of its bytes.
    public static func tokenHex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// The upload for this phone as it stands. The zone is sent whichever way the Duo toggle is
    /// (D36): with the toggle off the server keeps it, and holds the one notice such a phone still
    /// gets, `ended`, to 08:00 to 22:00 there rather than sending it in the small hours. The window
    /// is sent only with the toggle on, since with it off it would serve only the pushes the person
    /// turned off, and the server would drop it anyway. Its ends are kept to 0 to 1439, which is
    /// all the server accepts: one minute out of range would be a `422 schema` for the whole
    /// upload, and then no push at all.
    public static func desired(tokenHex: String, environment: DuoAPNsEnvironment, zone: String,
                               window: (start: Int, end: Int), notificationsEnabled: Bool) -> DuoWireRegisterPushRequest {
        func minute(_ value: Int) -> Int { min(max(value, 0), DuoQuietHours.minutesPerDay - 1) }
        return DuoWireRegisterPushRequest(token: tokenHex, apnsEnv: environment.rawValue, tz: zone,
                                          wakeStartMin: notificationsEnabled ? minute(window.start) : nil,
                                          wakeEndMin: notificationsEnabled ? minute(window.end) : nil,
                                          notificationsEnabled: notificationsEnabled)
    }

    /// Whether to upload `desired` now, and whether that upload is the token's first.
    ///
    /// - `previous` is what the server was last known to hold: the record of the last upload it
    ///   answered with a 204, nil when there is none or when the token was taken back since.
    /// - `queued` is the last push request still waiting in the op queue, if any. What is
    ///   compared is what the server will hold once that has gone: an upload compared with the
    ///   record alone could be skipped as "unchanged" while an older one, saying something else,
    ///   waited in the queue to overwrite it (a window moved and moved back while offline).
    ///
    /// A launch and a new token always upload: a launch refreshes the row's `updated_at`, which
    /// the server's rule for Apple's `410 Unregistered` reads (§9.6). A window, toggle, zone or new
    /// duo uploads only when something differs from what the server will hold; a background run
    /// only when the zone does (CON R11). Nothing is added when the queue already ends with this
    /// very upload, attested at least as much as this one needs to be.
    ///
    /// The first upload is judged against the record, not against an upload still waiting: that one
    /// may yet be refused, and the next would then go out unattested to a server that has never
    /// seen the token from this device. A removal still waiting is the exception the other way:
    /// once it has gone the server holds no row for the token, so whatever follows it is a first
    /// upload again. It used to be judged against the record alone, which still named the token,
    /// so a duo started while the last one's `DELETE` waited (offline, or held by a `Retry-After`)
    /// had its upload sent unattested right behind the `DELETE`, and in `tier` mode refused.
    public static func decide(previous: Snapshot?, desired: Snapshot, reason: Trigger, queued: Queued? = nil) -> Decision {
        let firstUpload = previous?.tokenHash != desired.tokenHash || queued == .removal
        let willHold: Snapshot?
        switch queued {
        case .upload(let snapshot, let queuedFirst):
            if snapshot == desired, queuedFirst || !firstUpload { return Decision(upload: false, firstUpload: firstUpload) }
            willHold = snapshot
        case .removal:
            willHold = nil
        case nil:
            willHold = previous
        }
        let upload: Bool
        switch reason {
        case .launch, .tokenChanged:
            upload = true
        case .windowChanged, .toggleChanged, .zoneChanged, .duoStarted:
            upload = willHold != desired
        case .background:
            upload = willHold?.zone != desired.zone
        }
        return Decision(upload: upload, firstUpload: firstUpload)
    }
}
