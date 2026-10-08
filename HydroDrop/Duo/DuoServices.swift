#if DUO_V2
import Foundation

// The seams between Duo's parts (plan P2, "Foundation"). `DuoStore` owns what the screen
// draws and nothing else; everything it does it asks of a service, and every service is a
// class of its own in its own file, written against these protocols and nothing else. A
// service is built with a `DuoDependencies` and reads what it needs from it at the time it
// needs it, never at init: the dependencies are filled in one at a time by `DuoComposition`,
// and a service built early must still find the ones built after it.

/// What a service may do to the state the screen is drawn from. `DuoStore` is the one
/// implementation; a test writes a fake. Every change to a duo goes through `update` or
/// `upsert` so it is saved and the widget is told.
@MainActor
protocol DuoHost: AnyObject {
    var duos: [DuoState] { get }
    func duo(_ id: UUID) -> DuoState?
    /// Changes one duo and saves the cache. Does nothing if the duo is gone or the change
    /// changed nothing.
    func update(_ id: UUID, _ change: (inout DuoState) -> Void)
    /// Adds a duo, or replaces the one with the same id in place.
    func upsert(_ duo: DuoState)
    func remove(_ id: UUID)
    func replaceAll(with duos: [DuoState])

    var availability: DuoAvailability { get set }
    /// Something worth telling the person once, in an alert on the Duo screen or the root.
    var notice: String? { get set }
    /// The same, for the setup and join sheets, which say it in place: an alert raised from
    /// underneath a sheet is never seen.
    var sheetError: String? { get set }
    /// Starting, joining, leaving or deleting is under way.
    var isWorking: Bool { get set }
    /// The last week of the log, as of the last time it changed.
    var latest: DuoLogSummary? { get set }
    /// What `GET /me` last said, and the Support ID and limits drawn from it.
    var memberInfo: DuoMemberInfo? { get set }
    /// An invite that has been received and is waiting for a name and a yes.
    var pendingInvite: DuoPendingInvite? { get set }
    var diagnostics: DuoDiagnostics { get set }
    /// True after `GET /me` showed a device this phone had not been told about (D45).
    var newDeviceNotice: Bool { get set }
    /// True after the server answered `428 terms_required`: the sheet that is open shows the
    /// terms, and on "accept" sends again.
    var needsTerms: Bool { get set }
    /// What this person typed as their own name, so the next sheet starts from it. A service
    /// that learns the name (a join, a rename) writes it here, never to the cache directly.
    var myDisplayName: String { get set }

    /// Forgets everything this phone kept about the person's Duo identity, in memory and in
    /// the cache together. The exit service calls this and nothing finer: a wipe that cleared
    /// only the cache left the typed name, the accepted terms and the diagnostics alive in the
    /// store until the next launch (the setup sheet pre-filled a name the person had just
    /// deleted, and the terms step was skipped), and the next change to any of them wrote the
    /// old value back to disk.
    func resetLocalState()

    /// Counts how many times `resetLocalState()` has run. A service reads it before it sends a
    /// request and compares it after the answer: if it moved, a wipe happened while the request
    /// was out, and the answer is dropped, never written back. A late answer would otherwise
    /// resurrect a duo (and a partner's name) the person had just deleted.
    var wipeEpoch: Int { get }
}

/// Reads the water log, which lives in SwiftData in the app. The only thing in Duo that
/// does, so the rest is testable without it.
@MainActor
protocol DuoLogReading: AnyObject {
    func read(now: Date) -> DuoLogSummary
}

/// Publishing and fetching: the shared streak's read and write path (final design §10).
@MainActor
protocol DuoSyncing: AnyObject {
    /// Given the log reader at launch, so a refresh with nobody looking, after a background
    /// task or a notification, can still read the log.
    func activate(logReader: DuoLogReading)
    /// Told whenever the log or the goal changes. Arranges for whatever the server has not
    /// heard to be sent, at most once every thirty seconds.
    func logChanged(_ summary: DuoLogSummary)
    /// Reads what changed in every live duo and, then, sends anything of mine the server
    /// is missing. Runs on foreground, on the Duo screen appearing, on a tapped notification
    /// and on pull to refresh.
    func refresh() async
    /// Sends every duo whatever it is missing, now if the coalescer allows and otherwise
    /// when it does.
    func flush() async
    /// A refresh with nobody looking: reads the log, publishes, then fetches. True if anything
    /// changed, so the system can be told.
    func backgroundRefresh() async -> Bool
    /// A remote notification arrived: fetch if it is ahead of the cursor (vector KV17).
    func pushArrived(_ payload: DuoPushPayload) async
    /// Sends one of the ready-made lines, if today's rules still allow one.
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async
}

/// Starting, joining, reconnecting and linking: every flow that makes or changes who this
/// phone is in a duo. Each one of these sends the first request of a consent the person has
/// just given by tapping a button (§3.1).
@MainActor
protocol DuoJoining: AnyObject {
    /// `POST /duos`. The caller has shown the explainer and the person tapped "Create and
    /// invite". Returns the new duo, with its invite, or nil with `sheetError` set.
    func createDuo(named: String?, skin: String) async -> DuoState?
    /// `POST /invites/peek`: with this phone's bearer if it has an identity, else anonymously.
    func peek(code: String) async -> DuoPeek?
    /// A code arrived by link, QR or typing: kept (and published as `pendingInvite`) before
    /// anything else, so a kill during onboarding loses nothing.
    func receive(_ invite: DuoParsedInvite, now: Date)
    func discardPendingInvite()
    /// `POST /invites/redeem`.
    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState?
    /// "Make a new code": a fresh invite for a pending duo.
    func newInvite(for duo: DuoState) async -> DuoInvite?
    /// A reconnect code for the other member's new phone, when they have been silent (§3.5).
    func createReconnectCode(for duo: DuoState) async -> DuoInvite?
    /// A code to link a second device of this member (v1 has the endpoint, the UI is phase 4).
    func createLinkCode() async -> DuoInvite?
    /// `POST /invites/reconnect`: this phone takes over the identity the code is for.
    func reconnect(code: String) async -> Bool
    /// `PATCH /me` for the name or the skin, through the op queue so an offline change lands later.
    func changeMyName(_ name: String?) async
    /// `PATCH /me {terms_version}` after a `428 terms_required`, then the caller sends again.
    func acceptTerms() async -> Bool
}

/// Leaving, blocking, clearing and deleting: every way out.
@MainActor
protocol DuoExiting: AnyObject {
    /// Leave = block with the soft bit. Queued, so an offline Leave shows the ended card at once.
    func leave(_ duo: DuoState) async
    /// Block: ends the duo and sets the hard bit (D34).
    func block(_ duo: DuoState) async
    /// Takes an ended duo off the screen (§12.2): local only.
    func clear(_ duo: DuoState)
    /// `DELETE /me`, then everything local. True if it went through.
    func deleteMyData() async -> Bool
    /// "Not me, start fresh" and "Start fresh" after a disconnect: discards the credential
    /// and this phone's Duo state without a server call.
    func startFresh()
}

/// The queue of requests that must reach the server even if the app is closed first (§10.1).
@MainActor
protocol DuoOpQueueing: AnyObject {
    var pending: [DuoQueuedOp] { get }
    func enqueue(_ op: DuoQueuedOp)
    /// Sends what is queued, in order, stopping at the first one that must wait.
    func drain() async
    /// Starts watching the network, so the queue drains when a connection comes back.
    func startMonitoring()
    /// Forgets every queued request, in memory and on disk: the identity they were made with is
    /// gone, so a replay could only answer 401 (a 401 `unauthenticated`, "Start fresh", Delete
    /// my Duo data).
    func discardAll()
}

enum DuoPushUploadReason: Equatable {
    case launch
    case tokenChanged
    case windowChanged
    case toggleChanged
    case zoneChanged
    case background
    /// A duo was made, joined or reconnected: there is now a reason to hold a token.
    case duoStarted
}

/// The push token: uploaded only while a live duo exists, with the zone whichever way the
/// Duo toggle is and the window whenever it is on (§3.1, §6.2, D36).
@MainActor
protocol DuoPushRegistering: AnyObject {
    func tokenArrived(_ token: Data, environment: DuoAPNsEnvironment)
    func reevaluate(_ reason: DuoPushUploadReason)
    /// No live duo remains (the last one ended, was left, cleared or deleted): the token is
    /// forgotten, by a queued `DELETE /devices/me/push` (§3.1).
    func noLiveDuoRemains()
    /// The op queue finished with a `registerPush` or `unregisterPush` it was given: sent (true)
    /// or dropped for good (false). The service records what the server now holds only on
    /// success, so a dropped upload is tried again at the next trigger.
    func opFinished(_ op: DuoQueuedOp, succeeded: Bool)
}

/// Turning announcements into notifications on this phone, and looking after the ones the
/// server's pushes already put there.
@MainActor
protocol DuoAnnouncing: AnyObject {
    /// Returns the keys of anything iOS refused to take, so the caller can forget they were
    /// ever announced and try again. Turned off is not refused: that is an answer.
    func deliver(_ announcements: [DuoAnnouncement], now: Date) async -> [String]
    /// Whether a remote notification for the event with this ledger key is already delivered
    /// on this phone, so the local one is not a second copy (§9.5, vector X14).
    func hasDeliveredRemote(forKey key: String) async -> Bool
    /// Removes every pending and delivered notification on this duo's thread.
    func removeDelivered(for duoID: UUID)
    /// Removes every Duo notification there is (Delete my Duo data).
    func removeAllDelivered()
}

@MainActor
protocol DuoBackgrounding: AnyObject {
    /// Asks iOS for the next background refresh: sooner of the regular one and the one just
    /// after local midnight (§10.6). A no-op without a live duo.
    func scheduleRefresh()
}

/// The credential and the install: what makes this phone a member (final design §3).
protocol DuoIdentityProviding: DuoCredentialProviding, AnyObject {
    /// The local date of the first run, kept in a file excluded from backup (§3.2). Today
    /// for a phone that has no file yet.
    var installDay: String { get }
    /// Saves a credential just minted or recovered, and writes the install marker.
    func store(_ credential: DuoCredential) throws
    /// A rotate gave a new secret.
    func replaceSecret(_ secret: String, version: Int) throws
    /// Forgets the credential (401 `unauthenticated`, "Start fresh", after `DELETE /me`).
    func discard()
    /// The launch sequence of §3.4, once per launch, before any other Duo request:
    /// nothing without a credential; nothing more with a credential and its marker; and with
    /// a credential and no marker (a reinstall, a restore, a Quick Start) a rotate, a marker,
    /// and a `GET /me`. Idempotent: later calls in the same launch answer the first one's result.
    func prepare() async -> DuoIdentityLaunch
    /// The two buttons of "This phone was connected to a duo with <partner>. Continue as
    /// <name>?": Continue seeds the cache from `GET /me`; "Not me" is `DuoExiting.startFresh`.
    func continueAsRestored() async
}

enum DuoIdentityLaunch: Equatable {
    /// No credential: nothing is sent until a Create, Join or Reconnect tap.
    case none
    case ready
    /// A credential was found without its marker and `GET /me` lists duos the cache lacks.
    case needsRestoreChoice(DuoRestorePrompt)
    /// The credential is known but another phone took the identity over.
    case disconnected
    /// Could not tell now (offline, maintenance): try again at the next refresh.
    case unavailable
}

/// The one place a request leaves the app by: `URLSession` in the app, a recording stub in a
/// test. The API client takes one, and `DuoComposition.makeLiveStore` can be handed one, so
/// a test of the whole wiring can count every request the app makes.
protocol DuoHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Answers every redirect with "no". The contract has no redirects, so one is never the server
/// being helpful: it is a captive portal or a misconfigured proxy. A followed 307 or 308 sends the
/// whole request again to the new host, body included (a name, an invite code, the DeviceCheck
/// token), with `Idempotency-Key` and `X-HD-Attest` on it, and a followed 302 still carries the
/// headers. Current macOS drops `Authorization` on a redirect, but that is not documented for
/// iOS 17, so the bearer is not left to the platform either. Refused, the 3xx comes back as the
/// response and the client reads it as an answer that is not the contract's.
final class DuoRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// `URLSession` as a `DuoHTTPSession`, set up the way Duo wants it: no cookies, no cache (the
/// server answers `Cache-Control: no-store`), no waiting for connectivity (an offline request
/// fails at once and the op queue or the next refresh tries again), and no redirects.
struct URLSessionHTTP: DuoHTTPSession {
    let session: URLSession

    init(session: URLSession = URLSessionHTTP.makeDefaultSession()) {
        self.session = session
    }

    /// `protocolClasses` is for a test that needs to answer in place of the network (a 302, say)
    /// through a real session, so the delegate and the configuration are the ones the app uses.
    static func makeDefaultSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        // The session keeps its delegate for as long as it lives, which is as long as the app.
        return URLSession(configuration: configuration, delegate: DuoRedirectRefuser(), delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Wraps another session so that every response, a success as much as a failure, leaves its
/// `X-Request-Id` in Diagnostics. The transport returns typed values and carries no side
/// channel, and a clean run would otherwise leave nothing to quote: only failures carry an id
/// (`DuoDiagnostics.recordRequest` keeps the status, the id and the time, never a path or a
/// body). It changes nothing about the request or the response.
struct DuoObservedSession: DuoHTTPSession {
    let base: DuoHTTPSession
    let observe: @Sendable (_ status: Int, _ requestID: String?) -> Void

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await base.data(for: request)
        if let http = response as? HTTPURLResponse {
            // Cloudflare's own block and error pages carry `CF-Ray` and no `X-Request-Id`, and the
            // server's request id is the same ray, so the one stands in for the other: a refused
            // request then still leaves something to quote.
            observe(http.statusCode, http.value(forHTTPHeaderField: "X-Request-Id") ?? http.value(forHTTPHeaderField: "CF-Ray"))
        }
        return (data, response)
    }
}

/// Everything a service may need, filled in by `DuoComposition` in dependency order. A
/// service reads these when it uses them, so one built before another still finds it.
@MainActor
final class DuoDependencies {
    unowned let host: DuoHost
    let cache: DuoCache
    let secrets: DuoSecrets
    let clock: DuoClock
    let random: DuoRandom
    let client: DuoClientInfo

    /// Whether HydroDrop+ is active (`StoreManager.shared.isSubscribed`): how many duos may be started.
    var isSubscribed: @MainActor () -> Bool = { false }
    /// The mascot skin to send with a name (`AppSettings.shared.activeMascotSkin.rawValue`).
    var activeSkin: @MainActor () -> String = { "classic" }
    /// The reminder window in minutes after midnight (`AppSettings.quietStartMinutes` and
    /// `quietEndMinutes`), the waking window nudges are held to (§9.4).
    var wakingWindow: @MainActor () -> (start: Int, end: Int) = { (480, 1320) }
    /// The mascot skins this build can draw, for `DuoMapping.resolvedSkin`.
    var knownSkins: Set<String> = ["classic"]
    /// How a service waits (a retry's delay, the owed write's thirty seconds). A test replaces
    /// it with one that records the delay and returns at once, so no test ever sleeps.
    var sleep: @MainActor (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    var transport: DuoTransport = DuoUnwiredTransport()
    /// Built after the dependencies (it reads them), so it is filled in by `DuoComposition`.
    var identity: DuoIdentityProviding!
    var attester: DuoAttesting
    var deviceCheck: DuoDeviceCheckProviding

    var sync: DuoSyncing?
    var joining: DuoJoining?
    var exiting: DuoExiting?
    var ops: DuoOpQueueing?
    var push: DuoPushRegistering?
    var announcer: DuoAnnouncing?
    var background: DuoBackgrounding?

    init(host: DuoHost, cache: DuoCache, secrets: DuoSecrets, clock: DuoClock = DuoSystemClock(), random: DuoRandom = DuoSystemRandom(),
         client: DuoClientInfo, attester: DuoAttesting, deviceCheck: DuoDeviceCheckProviding) {
        self.host = host
        self.cache = cache
        self.secrets = secrets
        self.clock = clock
        self.random = random
        self.client = client
        self.attester = attester
        self.deviceCheck = deviceCheck
    }
}

/// What a service gets until `DuoComposition` has built the real transport: every call is
/// "not available", which the callers already handle.
struct DuoUnwiredTransport: DuoTransport {
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { throw DuoTransportError.offline }
    func attestChallenge() async throws -> DuoWireAttestChallenge { throw DuoTransportError.offline }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { throw DuoTransportError.offline }
    func me() async throws -> DuoWireGetMeResponse { throw DuoTransportError.offline }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { throw DuoTransportError.offline }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { throw DuoTransportError.offline }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { throw DuoTransportError.offline }
    func unregisterPush() async throws { throw DuoTransportError.offline }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { throw DuoTransportError.offline }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { throw DuoTransportError.offline }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { throw DuoTransportError.offline }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { throw DuoTransportError.offline }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { throw DuoTransportError.offline }
    func fetchDuo(id: String) async throws -> DuoWireHeader { throw DuoTransportError.offline }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { throw DuoTransportError.offline }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { throw DuoTransportError.offline }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { throw DuoTransportError.offline }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { throw DuoTransportError.offline }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { throw DuoTransportError.offline }
}
#endif
