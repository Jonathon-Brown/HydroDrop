#if DUO_V2
import Foundation

/// Every way out of Duo (final design §7.5, §7.6, §10.1, §12.2, §12.3, §3.4): leave, block,
/// clear, delete my Duo data, and start fresh. The confirmations and their approved words are the
/// Duo screen's (stage H); this service says only what went wrong, in `DuoUserMessage`'s words.
///
/// Leave and block go through the op queue, so an offline one shows the ended card at once and is
/// sent when it can be, the same request with the same key however many times that takes. A leave
/// or a block ends every live duo of the pair on the server (§7.5), so once one lands the queue asks
/// the sync engine to read the duos again, and a sibling duo with the same partner ends here as the
/// server reports it. Clear is local. Delete my Duo
/// data is the one exit that needs the server to answer before anything here changes, because it
/// tells the person their data is gone from the service, which only a `204` (or the `401` a replay
/// meets) can say. Start fresh changes only this phone; the seat on the server ends by its own
/// 30-day rule.
@MainActor
final class DuoExitService: DuoExiting {
    private let dependencies: DuoDependencies
    /// A delete under way. A second tap while one is out would send a second `DELETE /me`, which a
    /// replay answers `401` and so counts as done, and both would then wipe; the first is enough.
    private var deleting = false

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    // MARK: - Leave and block

    /// Leave ends a duo that is still on (§12.2). A duo already over has nothing to leave; Clear
    /// takes it off the screen.
    func leave(_ duo: DuoState) async {
        await end(duo, as: .leave)
    }

    /// Block works on a live duo and on one already over (the ended card's Block row, §11.8): on
    /// an ended one it sets the pair's hard bit and ends any other live duo of the pair (§7.6).
    func block(_ duo: DuoState) async {
        await end(duo, as: .block)
    }

    private func end(_ duo: DuoState, as kind: DuoPendingOp) async {
        let host = dependencies.host
        // A banned member keeps `DELETE /me` and nothing else (D33: the contract's `banned_allowed`
        // is true for it alone), so a leave or block would be refused `403 banned` and dropped,
        // while the card here claimed the duo had ended and the partner's stayed live. Nothing is
        // queued and nothing changes on the card; the banned line says where to turn instead.
        guard host.availability != .banned else {
            host.notice = DuoAvailability.banned.bannerMessage
            return
        }
        // No credential (a backup that brought the duos and not the Keychain), or only the
        // throwaway a Reconnect minted and has not finished with (the cached duos are another
        // member's, so the server would answer 404 and the exit would count as done): nothing could
        // send it for this duo. Ending the card anyway hid a duo that is live on the server, and
        // with no live duo left the next launch stopped offering "I had a duo", the one way back to
        // it. Nothing changes, and the person is told it did not work; the disconnected card says
        // what to do.
        guard dependencies.identity?.credential != nil, !dependencies.credentialIsAThrowaway else {
            host.notice = DuoUserMessage.generic
            return
        }
        // What the store holds now, not the copy a view was drawn from, which may be stale.
        guard let current = host.duo(duo.id), let ops = dependencies.ops else { return }
        if kind == .leave, current.hasEnded { return }
        // Already queued (a second tap, or a block tapped again before the first was sent): one is
        // enough, and the queue is asked to try it now.
        if current.pendingOp == kind {
            await ops.drain()
            return
        }
        let now = dependencies.clock.now
        let key = DuoIdempotencyKey.make(random: dependencies.random).value
        let op: DuoQueuedOp
        do {
            op = kind == .leave ? try DuoQueuedOp.leave(duoID: duo.id, key: key, now: now)
                                : try DuoQueuedOp.block(duoID: duo.id, key: key, now: now)
        } catch {
            host.notice = DuoUserMessage.text(for: error)
            return
        }
        // Queued before the card changes: a kill between the two then leaves a request that ends
        // the duo when it is sent, never an ended card with nothing queued to end it.
        ops.enqueue(op)
        let endsALiveDuo = !current.hasEnded
        host.update(duo.id) { state in
            // An offline Leave shows the ended card at once (§10.1); a block of a duo already over
            // keeps the end it had.
            if state.endedAt == nil {
                state.endedAt = now
                state.endedBy = state.myRole == .owner ? .owner : .partner
            }
            state.pendingOp = kind
            // The server voids the duo's open codes with the end (§7.5); the code is not shown again.
            // Its link secret stays until Clear, which takes the duo's last trace off the phone.
            state.invite = nil
            state.openInviteExpiresAt = nil
        }
        // Not the pushed "ended" notice: only Clear takes that one (D75).
        dependencies.announcer?.removeDelivered(for: duo.id)
        // The last live duo gone: there is no reason left to hold a push token (§3.1), and the push
        // service queues its removal behind this request.
        if endsALiveDuo, !host.duos.contains(where: { !$0.hasEnded }) {
            dependencies.push?.noLiveDuoRemains()
        }
        await ops.drain()
    }

    // MARK: - Clear

    /// Takes an ended duo off this phone (§12.2: "It is already over. This only takes it off your
    /// screen."). Nothing is sent about the duo.
    ///
    /// The duo is remembered as cleared first: the server lists an ended duo for 30 days, and the
    /// next `GET /me`, a restore or a reconnect would otherwise bring the card straight back.
    /// `host.remove` then takes the duo with its rows and vers, its refused days, its ledger keys
    /// and its Diagnostics.
    ///
    /// A leave or block still waiting in the queue is kept and still sent, where §12.2 says Clear
    /// drops the duo's queued entries. The only entries a duo can have are its leave and its block,
    /// and an offline Leave shows the ended card, Clear row and all, before it is sent: dropping it
    /// would undo a block the person asked for, or a leave whose dialog told them their days and
    /// name are removed, while the server kept the duo live and the partner was told nothing for up
    /// to 30 days. Kept, it ends the duo when it goes, and its answer finds no card and changes
    /// nothing here. (A choice for Jonathon to overrule, made in stage E.)
    func clear(_ duo: DuoState) {
        let host = dependencies.host
        // A live duo is never cleared: hidden here and remembered as cleared, it would stay live on
        // the server, with the partner's nudges still arriving, and could never be shown again.
        guard let current = host.duo(duo.id), current.hasEnded else { return }
        dependencies.cache.markCleared(duo.id, now: dependencies.clock.now)
        host.remove(duo.id)
        try? dependencies.secrets.deleteLinkSecret(forDuo: duo.id)
        // The pushed "ended" notice goes too. Leave, block and the app's own ending keep it, so the
        // person is told the duo is over (D75); a Clear is the person taking the duo off the screen
        // on purpose, and §12.2 takes its notifications with it.
        dependencies.announcer?.removeDeliveredIncludingEnded(for: duo.id)
        // The push service forgets a token only if the server holds one, so asking whenever no live
        // duo is left covers the last duo, and an end the push service was not told of, alike.
        if !host.duos.contains(where: { !$0.hasEnded }) {
            dependencies.push?.noLiveDuoRemains()
        }
    }

    // MARK: - Delete my Duo data

    /// `DELETE /me`, then everything on this phone (§12.3). Online only, with the spinner, and not
    /// queued: the person is told their data is gone, which must be true when they read it.
    ///
    /// A `204` is success, and so is `401 unauthenticated`: the identity is already gone from the
    /// server, which is what a replay of a delete that did land meets (§6.0: `DELETE /me` keeps no
    /// idempotency record). Nothing else is. `401 device_revoked` above all is not: a superseded
    /// phone inside its 30 days and a banned member are both let through to `DELETE /me` and get
    /// their `204`, so `device_revoked` means another holder rotated this phone's secret away and
    /// nothing was deleted. Wiping then, and letting the person read that their data is gone from
    /// the service, would be false while the member still exists on the other phone; it is a
    /// failure, the disconnected card appears, and Start fresh is the honest way out.
    ///
    /// Not kept in the in-flight journal (D62): once it succeeds the member is gone and a replay can
    /// only answer `401`, so each tap sends its own key. What is kept is the bare fact that it was
    /// asked for (`DuoCache.deleteRequestedAt`, a date and nothing else), written before the request
    /// leaves: if the server deleted the member and the answer was lost (a dropped connection, the app
    /// closed with the spinner up), the next request meets `401 unauthenticated`, and `noteFailure`
    /// then finishes this wipe instead of forgetting only part of the phone, the ended cards with
    /// the partner's name, the typed name and the ledger staying with nothing on screen able to take
    /// them. The mark goes only when the server's answer proves nothing was deleted, and with the
    /// wipe.
    ///
    /// A launch that says `.disconnected` still sends it: a superseded phone keeps `DELETE /me` for
    /// its 30 days (D33, §3.5) though its `GET /me` answers `device_revoked`, and a phone whose secret
    /// was rotated away is answered `device_revoked` and told so. The restore question sends nothing:
    /// the credential may be someone else's.
    func deleteMyData() async -> Bool {
        let host = dependencies.host
        guard !deleting else { return false }
        deleting = true
        let epoch = host.wipeEpoch
        host.isWorking = true
        defer {
            deleting = false
            // A wipe has already put the spinner away, and anything that started after it is not
            // this delete's to stop.
            if host.wipeEpoch == epoch { host.isWorking = false }
        }
        let launch = await dependencies.identity.prepare()
        guard host.wipeEpoch == epoch else { return false }
        switch launch {
        case .ready, .disconnected:
            break
        case .none:
            // No credential. If a delete was asked for on this install and its answer never seen,
            // the identity being gone is that answer (the server forgot it, and with it the member):
            // the wipe the person asked for is finished. A mark older than this install proves
            // nothing: the install day lives in a file no backup carries, so a mark dated before it
            // came with a backup restored without the Keychain, and the request it stood for may
            // never have landed. It goes, and the ordinary answer follows.
            if let asked = dependencies.cache.deleteRequestedAt {
                if DayKey.key(for: asked, calendar: dependencies.clock.calendar) >= dependencies.identity.installDay {
                    wipeEverything()
                    return true
                }
                dependencies.cache.deleteRequestedAt = nil
            }
            host.notice = DuoUserMessage.generic
            return false
        case .unavailable:
            // The launch could not tell yet (no connection, the service paused): nothing is sent.
            host.notice = DuoUserMessage.generic
            return false
        case .needsRestoreChoice:
            // The question is on the Duo screen and says what to do; nothing is sent while it is up.
            return false
        }
        // Asked only now, when the request will go: a token is for one request (D62).
        let token = await dependencies.deviceCheck.token()
        guard host.wipeEpoch == epoch else { return false }

        dependencies.cache.deleteRequestedAt = dependencies.clock.now
        var failure: Error?
        do {
            try await dependencies.transport.deleteMe(DuoWireDeleteMeRequest(deviceCheckToken: token),
                                                      key: DuoIdempotencyKey.make(random: dependencies.random))
        } catch {
            failure = error
        }
        let deleted = failure.map(Self.meansTheIdentityIsGone) ?? true
        // A Start fresh while the request was out has already wiped this phone, and any identity
        // made since is not the one this answer is about: nothing is wiped or noted for it again.
        guard host.wipeEpoch == epoch else { return deleted }
        if deleted {
            wipeEverything()
            return true
        }
        guard let failure else { return false }
        if Self.provesNothingWasDeleted(failure) { dependencies.cache.deleteRequestedAt = nil }
        let verdict = dependencies.noteFailure(failure)
        // A cancelled task is not a failure to tell anyone about. The words are a delete's: nothing
        // is queued, so the maintenance line's "your duo will catch up" would not be true.
        if verdict != .cancelled { host.notice = DuoUserMessage.text(for: failure, context: .deletion) }
        return false
    }

    /// The server's own `401 unauthenticated`. The client's `unauthenticated` at status 0 means
    /// nothing was sent (no credential, or one it would not send), so nothing was deleted.
    private static func meansTheIdentityIsGone(_ error: Error) -> Bool {
        guard case .unauthenticated(let context) = error as? DuoTransportError else { return false }
        return context.httpStatus == 401
    }

    /// A refusal the server judged: the member is still there, so no attempt, this one or one whose
    /// answer was lost before it, deleted anything (a deleted member is answered `401
    /// unauthenticated`). That is `device_revoked`, `banned`, 426, 428 and any other 4xx with the
    /// server's envelope but 429. No connection, a cancelled task, maintenance, a rate limit, an
    /// answer that cannot be read, and the client's own refusals at status 0 say nothing about an
    /// earlier attempt, so they keep the mark.
    private static func provesNothingWasDeleted(_ error: Error) -> Bool {
        guard let failure = error as? DuoTransportError else { return false }
        switch failure {
        case .offline, .rateLimited, .maintenance, .unauthenticated:
            return false
        case .deviceRevoked:
            return true
        case .unreadable(let status, _):
            return (400...499).contains(status) && status != 429 && status != 401
        default:
            guard let status = failure.context?.httpStatus else { return false }
            return (400...499).contains(status) && status != 429
        }
    }

    // MARK: - Start fresh

    /// How long Start fresh waits for a leave or block still queued before it wipes anyway.
    static let startFreshBound: TimeInterval = 5
    /// A Start fresh waiting for its last drain, so a second tap does not start another.
    private(set) var pendingStartFresh: Task<Void, Never>?

    /// "Not me, start fresh" on the restore question and "Start fresh" after a disconnect (§3.4):
    /// the same wipe as a delete, without a word to the server about the identity.
    ///
    /// A leave or a block still queued is what the person already asked for, and the wipe would
    /// throw it away (a superseded phone's block waiting on a 503, say, which its server still
    /// accepts for 30 days). So when one is queued and the identity is this phone's own (not the
    /// restore question's, whose credential may be someone else's, and not a Reconnect's
    /// throwaway, which no exit can be sent with), the queue gets one last drain of its leaves and
    /// blocks first, for at most `startFreshBound` seconds, with the spinner up; then the wipe runs
    /// whatever came of it. Otherwise the wipe is at once.
    func startFresh() {
        guard pendingStartFresh == nil else { return }
        let host = dependencies.host
        let exitsQueued = dependencies.ops?.pending.contains { $0.kind == .leave || $0.kind == .block } ?? false
        let restoring: Bool
        if case .needsRestoreChoice = host.availability { restoring = true } else { restoring = false }
        guard exitsQueued, !restoring, dependencies.identity?.credential != nil, !dependencies.credentialIsAThrowaway,
              let ops = dependencies.ops else {
            wipeEverything()
            // Only the restore question's "Not me, start fresh" takes an allowed age answer back: the
            // defaults travel with a backup, so the phone may hold ANOTHER person's answer. A Start fresh
            // from the same person (or a 401 finishing their delete, which comes through here too) keeps it.
            if restoring { host.forgetAnAllowedAge() }
            return
        }
        // What was queued for the identity being given up (a rename, a push upload) goes now: a
        // refresh in the window (a foreground, or one an exit's landing asks for) would otherwise
        // send it before the wipe.
        ops.discardIdentityBound()
        host.isWorking = true
        let epoch = host.wipeEpoch
        pendingStartFresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let launch = await self.dependencies.identity.prepare()
            if host.wipeEpoch == epoch, launch == .ready || launch == .disconnected {
                await self.drainExits(ops, within: Self.startFreshBound)
            }
            self.pendingStartFresh = nil
            // Something else has wiped meanwhile (a 401 finishing a delete): nothing is left to do.
            guard host.wipeEpoch == epoch else { return }
            self.wipeEverything()
        }
    }

    /// The queue's leaves and blocks, or the bound, whichever ends first. A drain still out when the
    /// bound ends is left to finish on its own: the wipe that follows discards the queue and moves
    /// the wipe epoch, so its answer writes nothing.
    private func drainExits(_ ops: DuoOpQueueing, within seconds: TimeInterval) async {
        let first = DuoExitFirstOfTwo()
        let drain = Task { @MainActor in
            if let queue = ops as? DuoOpQueueService { await queue.drainExitsBeforeAWipe() } else { await ops.drain() }
            first.fire()
        }
        let sleep = dependencies.sleep
        let bound = Task { @MainActor in
            try? await sleep(seconds)
            first.fire()
        }
        await first.wait()
        bound.cancel()
        _ = drain
    }

    /// Everything this phone kept about the person's Duo identity, in an order that never leaves a
    /// way back to it: the identity first (the credential, the install marker, the settled file and
    /// this device's attestation key; without it the cached credential stays and the launch answer
    /// stays `.ready`), then every item of Duo's Keychain service, so a link secret for a duo that
    /// left the cache some other way, or an attestation key under another device's id, cannot
    /// outlive it (the age refusal is a service of its own and stays, D60), then the queue, the
    /// notifications, and last the store and the cache together (`resetLocalState`, which also
    /// empties the in-flight journal and the delete mark and moves `wipeEpoch`, so a request still
    /// out drops its answer). What stays is what `DuoCache.keptKeys` names: the age answer, the
    /// notifications switch and the two one-time notes. After it nothing is sent until a Create, Join
    /// or Reconnect tap.
    ///
    /// The Keychain's deletes are read back. One it refused (`try?` would swallow it) used to leave
    /// a screen that looked clean over a credential the next launch read back, which then asked
    /// "Continue as <name>?" about the identity the person had just said was not theirs. So a
    /// credential or marker still there is deleted once more, and if it stays the person is told
    /// it did not work.
    private func wipeEverything() {
        let secrets = dependencies.secrets
        let deviceID = dependencies.identity?.credential?.deviceID
        dependencies.identity?.discard()
        if let deviceID { dependencies.attester.forgetKeys(forDevice: deviceID) }
        try? secrets.deleteEverything()
        var keptByTheKeychain = Self.stillHoldsTheIdentity(secrets)
        if keptByTheKeychain {
            try? secrets.deleteEverything()
            keptByTheKeychain = Self.stillHoldsTheIdentity(secrets)
        }
        dependencies.ops?.discardAll()
        dependencies.announcer?.removeAllDelivered()
        dependencies.host.resetLocalState()
        if keptByTheKeychain { dependencies.host.notice = DuoUserMessage.generic }
    }

    private static func stillHoldsTheIdentity(_ secrets: DuoSecrets) -> Bool {
        secrets.credential() != nil || secrets.hasInstallMarker()
    }
}

/// Which of two tasks ends first, on the main actor.
@MainActor
private final class DuoExitFirstOfTwo {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if fired { continuation.resume() } else { self.continuation = continuation }
        }
    }
}
#endif
