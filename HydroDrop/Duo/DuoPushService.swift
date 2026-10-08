#if DUO_V2
import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// What the push service asks of the system, one closure each, so a test can stand in for every
/// part and count what was asked.
struct DuoPushSystem {
    /// Asks iOS for this install's APNs token, which arrives in `DuoAppDelegate`. It needs no
    /// permission and shows nothing: SwiftData's CloudKit mirror already asks at every launch.
    var registerForRemoteNotifications: @MainActor () -> Void
    /// Whether iOS has never asked this person about notifications, so asking now shows a prompt.
    var permissionUndetermined: @MainActor () async -> Bool
    /// Shows iOS's notification permission prompt.
    var requestNotificationPermission: @MainActor () -> Void
    /// The phone's IANA zone, read each time it is needed, never kept.
    var zoneIdentifier: @MainActor () -> String
    /// Where the triggers are posted: becoming active, a zone or clock change, a defaults write.
    var notificationCenter: NotificationCenter

    @MainActor static var live: DuoPushSystem {
        DuoPushSystem(
            registerForRemoteNotifications: { UIApplication.shared.registerForRemoteNotifications() },
            permissionUndetermined: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined },
            // The reminders use the same permission, and the iCloud Duo asked at this same moment,
            // when the first duo existed.
            requestNotificationPermission: { ReminderManager.shared.requestAuthorizationIfNeeded() },
            zoneIdentifier: { TimeZone.current.identifier },
            notificationCenter: .default
        )
    }
}

/// Notification observers that are removed when the object holding them goes.
///
/// That is not the same as "a service that is dropped stops listening": a service and the
/// `DuoDependencies` it was built with hold each other (`dependencies.push`, the service's
/// `dependencies`), so a store a test builds and drops leaves its services alive and listening,
/// with `dependencies.host` (unowned) naming a store that is gone. So each service holds the host
/// weakly as well and stops when it has gone; a zone change posted after a dropped composed store
/// used to end the test process ("unowned reference already destroyed").
final class DuoSystemObservers {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    /// Runs `action` on the main actor for every `name` posted, after the post has returned. The
    /// block runs on the posting thread and only schedules the work: with `queue: .main` every
    /// `UserDefaults.didChangeNotification`, which is posted on whatever thread wrote, made that
    /// thread wait for the main thread, so a background defaults write anywhere in the process was
    /// held for as long as the main thread was busy.
    func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
            Task { @MainActor in action() }
        })
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}

/// The push token's upload (final design §3.1, §6.2, §9.6, D36): `PUT /devices/me/push` while a
/// live duo exists, through the op queue so a change made offline lands later, and
/// `DELETE /devices/me/push` when none is left.
///
/// What is sent, and when, is `DuoPushUploadPlan`'s; this decides when to ask it. The consent rule
/// (§3.1) comes first everywhere: with no credential, nothing is uploaded, nothing is removed, no
/// token is asked of iOS and no permission is asked of the person, so a launch with no duo and no
/// identity does none of it. A token the phone holds before then stays in memory and nowhere else.
///
/// Every upload waits for `identity.prepare()` and goes on only at `.ready`, after the restore
/// question has been answered (D64): a phone restored onto another phone must not register a token
/// under an identity it has not yet said is its own. `prepare()` is only asked with a live duo
/// cached, the one moment a request is allowed to make it: an unsettled phone's first `prepare()`
/// sends `GET /me` under the previous owner's bearer, which moves their `last_seen_at` (a
/// reconnect is then refused for 72 hours), so it is never asked for a phone with nothing to say.
/// Nothing is asked either of a phone the server has shut out (disconnected, banned, or an app
/// too old to write): each upload would be refused again, with the same revoked bearer, at every
/// trigger.
///
/// The token is never written down. What the server was told is recorded after its 204, with the
/// token as a hash (`tokenHash(_:deviceID:)`), and the request itself sits in the op queue only
/// until it is sent, as every queued request does (§10.1). Nothing here logs anything.
@MainActor
final class DuoPushService: DuoPushRegistering {
    private let dependencies: DuoDependencies
    private let system: DuoPushSystem
    private var observers: DuoSystemObservers?
    /// `dependencies.host`, held weakly: see `DuoSystemObservers`. Everything here reads the host
    /// through this and stops when it is gone.
    private weak var host: DuoHost?

    /// The token iOS last handed over, as the lowercase hex the wire carries, and its APNs
    /// environment. In memory only.
    private var tokenHex: String?
    private var tokenEnvironment: DuoAPNsEnvironment?
    /// What an evaluation that found no token was for, kept until iOS hands one over.
    private var awaitingToken: DuoPushUploadReason?
    /// Evaluations run one at a time, and whatever is asked meanwhile waits as one more.
    private var nextReason: DuoPushUploadReason?
    private var evaluation: Task<Void, Never>?
    /// A duo started, or Duo's toggle was turned on: the next evaluation asks for permission if
    /// iOS never has. Kept apart from the reason, since a launch waiting beside it would swallow
    /// it, and taken by the evaluation that runs next whatever it finds.
    private var permissionWanted = false
    /// Whether this process has become active yet: its first time is the launch's upload.
    private var hasBecomeActive = false
    /// The waking window as last seen, so a defaults write that left it alone is not a change.
    private var observedWindow: [Int]?
    private var windowCheck: Task<Void, Never>?
    private var permissionCheck: Task<Void, Never>?
    /// The wipe count and the device each push request was queued under, by its key, so the queue's
    /// answer to one is believed only while both still hold.
    private var origins: [String: (epoch: Int, deviceID: String)] = [:]

    convenience init(dependencies: DuoDependencies) {
        self.init(dependencies: dependencies, system: .live)
    }

    init(dependencies: DuoDependencies, system: DuoPushSystem) {
        self.dependencies = dependencies
        self.system = system
        host = dependencies.host
        let observers = DuoSystemObservers(center: system.notificationCenter)
        observers.observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.becameActive() }
        observers.observe(.NSSystemTimeZoneDidChange) { [weak self] in self?.clockOrZoneChanged() }
        observers.observe(UIApplication.significantTimeChangeNotification) { [weak self] in self?.clockOrZoneChanged() }
        observers.observe(UserDefaults.didChangeNotification) { [weak self] in self?.defaultsChanged() }
        self.observers = observers
    }

    // MARK: - DuoPushRegistering

    func tokenArrived(_ token: Data, environment: DuoAPNsEnvironment) {
        let hex = DuoPushUploadPlan.tokenHex(token)
        guard !hex.isEmpty else { return }
        tokenHex = hex
        tokenEnvironment = environment
        let waiting = awaitingToken
        awaitingToken = nil
        guard let credential = dependencies.identity?.credential else { return }
        // SwiftData's CloudKit mirror asks iOS for the token at every launch, background launches
        // included, so the same token arrives again and again. Only one the server is not known to
        // hold is a change; the same one is news only to an evaluation that was waiting for it.
        let recorded = dependencies.cache.loadPushUpload()
        if recorded?.tokenHash != Self.tokenHash(hex, deviceID: credential.deviceID) || recorded?.environment != environment {
            reevaluate(.tokenChanged)
        } else if let waiting {
            reevaluate(waiting)
        }
    }

    func reevaluate(_ reason: DuoPushUploadReason) {
        // The prompt belongs to the moment a duo exists (a Create, Join or Reconnect tap that
        // worked, a Continue on the restore question) and to the moment the person turns Duo's
        // notifications on; someone whose toggle was off when their duo started would otherwise
        // never be asked. The evaluation decides whether it is really asked.
        if reason == .duoStarted || (reason == .toggleChanged && dependencies.cache.notificationsEnabled) { permissionWanted = true }
        nextReason = Self.stronger(nextReason, reason)
        guard evaluation == nil else { return }
        evaluation = Task { [weak self] in
            while let self, let reason = self.nextReason {
                self.nextReason = nil
                await self.evaluate(reason)
            }
            self?.evaluation = nil
        }
    }

    func noLiveDuoRemains() {
        guard let host, !Self.isShutOut(host.availability), !Self.hasLiveDuo(host),
              let credential = dependencies.identity?.credential, let ops = dependencies.ops else { return }
        let last = Self.lastPushOp(in: ops.pending)
        // Already on its way: once is enough, whoever asks again.
        guard last?.kind != .unregisterPush else { return }
        // Something the server holds, or will once the queue reaches it. An upload still waiting
        // counts: sent after the last duo ended, it would leave a token on the server that nothing
        // here would ever take back.
        guard dependencies.cache.loadPushUpload() != nil || last?.kind == .registerPush else { return }
        let op = DuoQueuedOp.unregisterPush(key: DuoIdempotencyKey.make(random: dependencies.random).value, now: dependencies.clock.now)
        origins[op.key] = (host.wipeEpoch, credential.deviceID)
        ops.enqueue(op)
        Task { await ops.drain() }
    }

    func opFinished(_ op: DuoQueuedOp, succeeded: Bool) {
        guard op.kind == .registerPush || op.kind == .unregisterPush, let host else { return }
        // A request queued in an earlier launch survived it, so it belongs to this launch's first
        // epoch. A wipe since it was queued (or since launch) means its answer is about data the
        // person has deleted, and the record it would write is one the wipe just removed: written
        // back, it would make the next identity's first upload look like a re-upload, which the
        // server refuses unattested.
        let origin = origins.removeValue(forKey: op.key)
        guard (origin?.epoch ?? 0) == host.wipeEpoch, let credential = dependencies.identity?.credential,
              origin == nil || origin?.deviceID == credential.deviceID else { return }
        let cache = dependencies.cache
        switch op.kind {
        case .registerPush:
            guard let request = try? DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: op.body) else { return }
            let hash = Self.tokenHash(request.token, deviceID: credential.deviceID)
            if succeeded {
                let now = dependencies.clock.now
                cache.savePushUpload(DuoPushUploadState(
                    tokenHash: hash, environment: request.apnsEnv.flatMap(DuoAPNsEnvironment.init(rawValue:)) ?? DuoConfig.apnsEnvironment,
                    zone: request.tz, windowStart: request.wakeStartMin, windowEnd: request.wakeEndMin,
                    enabled: request.notificationsEnabled, uploadedAt: now))
                host.diagnostics.recordPushUpload(zone: request.tz, windowStart: request.wakeStartMin, windowEnd: request.wakeEndMin,
                                                  enabled: request.notificationsEnabled, at: now)
            } else if !op.attestsFirstUpload, var recorded = cache.loadPushUpload(), recorded.tokenHash == hash {
                // A re-upload the server refused. Nothing else is decided here, and the next
                // trigger tries again, but no longer as a re-upload: the server answers an
                // unattested one `403 attest_required` once it has lost the token's row (a phone
                // unseen for 90 days, a token Apple refused at both hosts), and since every
                // re-upload of a token it has lost is refused the same way, the phone would never
                // be told anything again. The record stays, so the last duo's end still takes the
                // token back; it just no longer vouches for this token.
                recorded.tokenHash = ""
                cache.savePushUpload(recorded)
            }
        case .unregisterPush:
            // Taken back, or refused for good (a banned member, a revoked device): either way there
            // is nothing more this phone can do about the row. Kept after a refusal, the record
            // sent the same refused `DELETE` again at every trigger; the server's daily sweep of a
            // member with no live duo is the backstop for a row it still holds (§3.1, S13).
            cache.savePushUpload(nil)
        default:
            break
        }
    }

    // MARK: - Triggers

    private func becameActive() {
        guard !hasBecomeActive else { return }
        hasBecomeActive = true
        reevaluate(.launch)
    }

    private func clockOrZoneChanged() {
        // Foundation keeps the system zone it first read, so it is read again before it is sent.
        NSTimeZone.resetSystemTimeZone()
        reevaluate(.zoneChanged)
    }

    /// The reminders' waking window lives in the defaults, so every write anywhere in the app is
    /// looked at, once per burst, and only a window that moved since an upload last looked at it
    /// is a change. That matters: the op queue writes its own defaults whenever an upload is
    /// queued, and if every write were taken for a window change, an upload the server kept
    /// refusing would queue itself again for ever. Before any upload has looked, there is nothing
    /// to compare with, and the next one reads the window as it is then.
    private func defaultsChanged() {
        guard windowCheck == nil, host != nil else { return }
        windowCheck = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.windowCheck = nil
            guard self.host != nil else { return }
            let window = self.dependencies.wakingWindow()
            let seen = [window.start, window.end]
            guard let observed = self.observedWindow else {
                self.observedWindow = seen
                return
            }
            guard seen != observed else { return }
            self.observedWindow = seen
            self.reevaluate(.windowChanged)
        }
    }

    // MARK: - Evaluating

    private func evaluate(_ reason: DuoPushUploadReason) async {
        let askForPermission = permissionWanted
        permissionWanted = false
        guard let host, !Self.isShutOut(host.availability), let identity = dependencies.identity, identity.credential != nil else { return }
        guard Self.hasLiveDuo(host) else {
            forgetTheTokenWithNoLiveDuo(host)
            return
        }
        let epoch = host.wipeEpoch
        guard await identity.prepare() == .ready else { return }
        // A wipe, a forgotten identity, the last duo ending or the server shutting this phone out
        // while the launch answer was being worked out: whatever this was going to do is no longer
        // wanted. The host is read again, since the store may be gone by now (a test's).
        guard let host = self.host, host.wipeEpoch == epoch, !Self.isShutOut(host.availability), Self.hasLiveDuo(host),
              let credential = identity.credential else { return }
        // Its own task: asking iOS whether it has asked is an `await`, and nothing may wait between
        // the checks above and the upload below. It checks again after that `await`.
        if askForPermission { permissionCheck = Task { [weak self] in await self?.askForPermissionIfNeverAsked() } }
        guard let token = tokenHex, let environment = tokenEnvironment else {
            awaitingToken = Self.stronger(awaitingToken, reason)
            system.registerForRemoteNotifications()
            return
        }
        await upload(reason, token: token, environment: environment, as: credential)
    }

    /// Asked only after `prepare()` said `.ready` with a live duo, and not at all for someone who has
    /// turned Duo's notifications off or whom iOS has already asked (an answer is final there, and
    /// the reminders' own request would reschedule them for nothing).
    private func askForPermissionIfNeverAsked() async {
        guard dependencies.cache.notificationsEnabled, await system.permissionUndetermined() else { return }
        guard let host, Self.hasLiveDuo(host), dependencies.identity?.credential != nil, dependencies.cache.notificationsEnabled else { return }
        system.requestNotificationPermission()
    }

    private func upload(_ reason: DuoPushUploadReason, token: String, environment: DuoAPNsEnvironment, as credential: DuoCredential) async {
        guard let ops = dependencies.ops, let host else { return }
        let window = dependencies.wakingWindow()
        observedWindow = [window.start, window.end]
        let request = DuoPushUploadPlan.desired(tokenHex: token, environment: environment, zone: system.zoneIdentifier(),
                                               window: window, notificationsEnabled: dependencies.cache.notificationsEnabled)
        let desired = DuoPushUploadPlan.Snapshot(request, tokenHash: Self.tokenHash(token, deviceID: credential.deviceID))
        let decision = DuoPushUploadPlan.decide(previous: dependencies.cache.loadPushUpload().map(Self.snapshot), desired: desired,
                                                reason: Self.trigger(reason), queued: Self.queuedPush(in: ops.pending, deviceID: credential.deviceID))
        guard decision.upload else { return }
        let key = DuoIdempotencyKey.make(random: dependencies.random).value
        guard let op = try? DuoQueuedOp.registerPush(request, firstUpload: decision.firstUpload, key: key, now: dependencies.clock.now) else { return }
        origins[op.key] = (host.wipeEpoch, credential.deviceID)
        ops.enqueue(op)
        await ops.drain()
    }

    /// No live duo is left on this phone. With ended ones still cached, the token is taken back
    /// (§3.1). With none cached at all there is nothing it could be told about, and the request
    /// would have to ask `prepare()` with no duo cached, which is never done at launch, on
    /// foreground or in the background (see the type's comment); the record goes on this phone
    /// alone, and the server's daily sweep takes the token row of a member with no live duo (§3.1,
    /// S13). Left behind, the record would make the next duo's upload look like one the server
    /// already had.
    private func forgetTheTokenWithNoLiveDuo(_ host: DuoHost) {
        if host.duos.isEmpty {
            if dependencies.cache.loadPushUpload() != nil { dependencies.cache.savePushUpload(nil) }
        } else {
            noLiveDuoRemains()
        }
    }

    /// For a test: returns once every evaluation, window check and permission check started so far
    /// has finished.
    func waitUntilSettled() async {
        while windowCheck != nil || evaluation != nil || permissionCheck != nil {
            await windowCheck?.value
            await evaluation?.value
            if let check = permissionCheck {
                await check.value
                if permissionCheck == check { permissionCheck = nil }
            }
        }
    }

    // MARK: - Plumbing

    /// SHA-256 of the device id and the token together, hex. The token is never kept, and a
    /// record is about one token on one device: the server attests the first upload of a token by
    /// a device (§6.2, §11.2), so a phone that reconnects as another device id after a disconnect
    /// (§3.4) must upload it again, attested, even though the token itself did not change.
    static func tokenHash(_ tokenHex: String, deviceID: String) -> String {
        SHA256.hash(data: Data("\(deviceID)|\(tokenHex)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasLiveDuo(_ host: DuoHost) -> Bool { host.duos.contains { !$0.hasEnded } }

    /// The server will refuse this phone whatever it sends: another phone took the identity over
    /// (`device_revoked`), the member is banned, or the app is too old to write (426).
    private static func isShutOut(_ availability: DuoAvailability) -> Bool {
        switch availability {
        case .disconnected, .banned, .upgradeRequired: return true
        case .unknown, .available, .maintenance, .needsRestoreChoice: return false
        }
    }

    private static func snapshot(_ state: DuoPushUploadState) -> DuoPushUploadPlan.Snapshot {
        DuoPushUploadPlan.Snapshot(tokenHash: state.tokenHash, environment: state.environment, zone: state.zone,
                                   windowStart: state.windowStart, windowEnd: state.windowEnd, enabled: state.enabled)
    }

    private static func lastPushOp(in pending: [DuoQueuedOp]) -> DuoQueuedOp? {
        pending.last { $0.kind == .registerPush || $0.kind == .unregisterPush }
    }

    /// The last push request still in the queue, which is what the server will hold once it has
    /// gone. One the app cannot read back is left out, and the record decides.
    private static func queuedPush(in pending: [DuoQueuedOp], deviceID: String) -> DuoPushUploadPlan.Queued? {
        guard let last = lastPushOp(in: pending) else { return nil }
        if last.kind == .unregisterPush { return .removal }
        guard let request = try? DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: last.body) else { return nil }
        return .upload(DuoPushUploadPlan.Snapshot(request, tokenHash: tokenHash(request.token, deviceID: deviceID)),
                       firstUpload: last.attestsFirstUpload)
    }

    private static func trigger(_ reason: DuoPushUploadReason) -> DuoPushUploadPlan.Trigger {
        switch reason {
        case .launch: return .launch
        case .tokenChanged: return .tokenChanged
        case .windowChanged: return .windowChanged
        case .toggleChanged: return .toggleChanged
        case .zoneChanged: return .zoneChanged
        case .background: return .background
        case .duoStarted: return .duoStarted
        }
    }

    /// Two reasons waiting become the one that uploads in more cases: a launch or a new token
    /// always uploads, a background run only for a new zone, and the rest for any change.
    private static func stronger(_ waiting: DuoPushUploadReason?, _ reason: DuoPushUploadReason) -> DuoPushUploadReason {
        func rank(_ reason: DuoPushUploadReason) -> Int {
            switch reason {
            case .launch, .tokenChanged: return 2
            case .windowChanged, .toggleChanged, .zoneChanged, .duoStarted: return 1
            case .background: return 0
            }
        }
        guard let waiting else { return reason }
        return rank(reason) > rank(waiting) ? reason : waiting
    }
}
#endif
