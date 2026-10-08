#if DUO_V2
import Foundation
import Network

/// The requests that must reach the server even if the app is closed first (final design §10.1):
/// a leave, a block, a `PATCH /me` and the push token's upload and removal. Each is written to
/// `duo.ops.v1` before anything is sent, with the exact bytes and the `Idempotency-Key` it goes
/// out with, and leaves it only once an answer settles it (`DuoOpQueue.disposition`), so a request
/// that was out when the app was killed is sent again at the next chance as the very same request.
///
/// The queue on disk is the only copy. Every read goes to the defaults, so whatever else changes
/// them (a wipe's `clearEverything`, a `DuoCache` built over the same defaults by another service)
/// is what the next read sees; a copy held in memory here would write a wiped queue straight back
/// at the next save. An empty queue leaves no key behind, so a wipe leaves the defaults as the
/// cache's `keptKeys` say, whatever order its steps ran in.
///
/// Draining, first in, first out within each group of kinds (D74: the exits, the profile, the push
/// token), so an entry that has to wait holds back only the entries of its own group. A drain sends
/// the entries it found when it began and no others, so one whose answers keep queueing new
/// entries (a push service that re-queues a dropped upload) cannot keep it going for ever; a caller
/// that waited for a drain already under way then gets a drain of its own, so what it queued goes
/// with its own call. It is started by the sync engine's refresh (on foreground, on the Duo screen,
/// after a notification), by the background path, by whoever enqueues, and by a network path that
/// becomes satisfied; only one runs at a time.
///
/// A drain never waits out a delay itself: a "not now" ends that group's part of it, and a retry of
/// its own waits the delay and drains again, at most three tries of one entry in a row (§6.7).
/// Sleeping inside the drain would hold every caller behind it, and the sync engine's refresh awaits
/// the drain, so one `Retry-After` (believed for up to two days) would stop every refresh and every
/// Leave tap for as long. The server's own "not before" (a rate limit, maintenance, a 5xx) is
/// remembered for as long as the app runs: a trigger inside it sends nothing for that group and only
/// makes sure a retry is waiting for its end, where it used to send the same request again at every
/// foreground. No connection has no such window, so a trigger (a connection coming back, above all)
/// tries at once.
///
/// Every drain asks `identity.prepare()` before anything is sent: a drain the network monitor
/// starts can come before the first refresh, and on a restored phone (a credential and no install
/// marker) the first request has to be the rotate that locks out the copy on the other phone, never
/// a queued request under the secret both phones still hold. With nothing queued no drain asks it
/// either, because `prepare()` itself sends a `GET /me` on an unsettled phone, which moves a
/// previous owner's `last_seen_at`. A launch that answers `.disconnected` still sends leaves and
/// blocks (a superseded phone keeps them for 30 days, and a phone whose secret was rotated away is
/// answered `device_revoked`, which drops them), and nothing else.
///
/// What it never does: send `DELETE /me`, a create, a redeem or a reconnect (those need the person
/// there, §10.1), wait for the sync engine's refresh inside a drain (the refresh drains, so that
/// would wait for itself), or keep anything about an answer after a wipe (`host.wipeEpoch` moved)
/// or a discard.
@MainActor
final class DuoOpQueueService: DuoOpQueueing {
    /// Watches the network path. The app's is `NWPathMonitor`; a test hands in its own and says
    /// when the path changes. It reports every reading (true when the path is satisfied); deciding
    /// which readings are a connection coming back is the service's, so a test can hold it to it.
    @MainActor
    protocol PathMonitoring: AnyObject {
        func start(_ onPathChange: @escaping @MainActor (_ satisfied: Bool) -> Void)
    }

    /// A group waiting out a delay: until when, and whether the server said so.
    private struct Pause {
        var due: Date
        /// A rate limit, maintenance or a 5xx: a trigger before `due` sends nothing for the group.
        /// No connection is not one: a trigger tries again at once.
        var isServerWindow: Bool
    }

    private let dependencies: DuoDependencies
    private let makeMonitor: @MainActor () -> PathMonitoring
    private var monitor: PathMonitoring?
    /// The last reading of the path, nil before the first. The first reading, which the monitor
    /// gives as soon as it starts, is not a change: a phone that starts online has nothing to catch
    /// up on that the launch's own refresh does not already drain.
    private var lastPathSatisfied: Bool?
    /// The drain under way, which any other call waits for instead of starting a second.
    private var running: Task<Void, Never>?
    /// The retry waiting out a delay, which nobody waits for.
    private var scheduledRetry: Task<Void, Never>?
    /// The newest retry made, whether or not it was let go since: the next one waits for it to end.
    private var lastRetry: Task<Void, Never>?
    /// How many times in a row each group's head has had to wait (§6.7: three tries, then the next
    /// foreground or connection).
    private var waitsInARow: [DuoOpQueue.Group: Int] = [:]
    /// The groups waiting out a delay, in memory only: a relaunch starts with none, and its first
    /// drain is a try like any trigger's.
    private var paused: [DuoOpQueue.Group: Pause] = [:]
    /// A leave or a block went through in the drain under way: once it is over, the sync engine is
    /// asked to read the duos again, since the server ends every live duo of the pair (§7.5) and a
    /// sibling here would otherwise show live until the next foreground.
    private var refreshAfterDrain = false
    /// Moves on every discard, so a drain whose request was out when the queue was emptied (a 401
    /// met by another service, a wipe, a new identity) acts on nothing it brought back.
    private var generation = 0

    init(dependencies: DuoDependencies) {
        self.dependencies = dependencies
        makeMonitor = { DuoSystemPathMonitor() }
    }

    /// For a test: the monitor `startMonitoring()` starts.
    init(dependencies: DuoDependencies, makeMonitor: @escaping @MainActor () -> PathMonitoring) {
        self.dependencies = dependencies
        self.makeMonitor = makeMonitor
    }

    // MARK: - The queue

    var pending: [DuoQueuedOp] { Self.load(dependencies.cache).ops }

    /// Written to disk at once, before anything is sent: the caller shows the result of the
    /// request straight away (an ended card), and a kill a moment later must not lose it.
    func enqueue(_ op: DuoQueuedOp) {
        var queue = Self.load(dependencies.cache)
        if queue.enqueue(op) == .conflicting {
            // Every key is a fresh UUID, so another entry under a queued key is a bug in the caller.
            // The first is kept (its bytes may already be on the server under that key).
            assertionFailure("Duo: a queued request's key was used again for another request")
        }
        Self.save(queue, to: dependencies.cache)
    }

    /// Everything queued goes, from disk and from whatever drain is under way. A card still marked
    /// as waiting for its leave or block is told nothing is waiting any more: left as it was, it
    /// would claim a request is queued that never will be sent (after a 401, or a wipe).
    func discardAll() {
        generation += 1
        cancelScheduledRetry()
        waitsInARow = [:]
        paused = [:]
        Self.save(DuoOpQueue(), to: dependencies.cache)
        let host = dependencies.host
        for duo in host.duos where duo.pendingOp != nil {
            host.update(duo.id) { $0.pendingOp = nil }
        }
    }

    /// The entries that mean something only for the identity they were made with go: a rename and
    /// a push-token upload or removal, which would otherwise go out under the next member. A leave
    /// and a block stay: under another member they answer 404 and are done, and under the member a
    /// Reconnect brings back they are exactly what the person asked for. Stage D calls this when it
    /// mints a new identity; a drain whose launch finds no credential does the same.
    func discardIdentityBound() {
        generation += 1
        var queue = Self.load(dependencies.cache)
        queue.removeIdentityBound()
        Self.save(queue, to: dependencies.cache)
        for group in [DuoOpQueue.Group.profile, .push] {
            waitsInARow[group] = nil
            paused[group] = nil
        }
    }

    static func load(_ cache: DuoCache) -> DuoOpQueue {
        DuoOpQueue(cache.loadOps())
    }

    static func save(_ queue: DuoOpQueue, to cache: DuoCache) {
        if queue.isEmpty {
            cache.defaults.removeObject(forKey: DuoCache.opsKey)
        } else {
            cache.saveOps(queue.ops)
        }
    }

    // MARK: - Draining

    /// A trigger from outside: it tries now, but for a group inside a window the server set, and
    /// the count of waits in a row starts again, so each trigger gets its three tries (and a group
    /// inside its window gets a retry at the window's end). A retry still waiting is let go; the
    /// drain leaves the one it needs.
    func drain() async {
        cancelScheduledRetry()
        if running == nil { waitsInARow = [:] }
        await drainNow(asOf: nil, exitsOnly: false, ignoringWindows: false)
    }

    /// Start fresh's last chance for what the person already asked for (stage E, E18): one drain of
    /// the leaves and blocks, inside a server window too, before the wipe throws them away.
    func drainExitsBeforeAWipe() async {
        cancelScheduledRetry()
        await drainNow(asOf: nil, exitsOnly: true, ignoringWindows: true)
    }

    /// Nothing under way and nothing waiting to retry. For a test, which has to know when the
    /// retries a drain left behind are over.
    var isIdle: Bool { running == nil && scheduledRetry == nil }

    /// `asOf` is the moment a retry waited for: the drain it starts treats the delay as over even
    /// on a clock that has not moved as far (a test's), and measures the next delay from there.
    private func drainNow(asOf: Date?, exitsOnly: Bool, ignoringWindows: Bool) async {
        if let underWay = running {
            // The drain under way sends only what it found when it began, and may have stopped on an
            // answer from before a discard: what this caller queued goes in a drain of its own.
            await underWay.value
            // Unless another caller has already started that one, which includes it.
            if let followUp = running {
                await followUp.value
                return
            }
        }
        let now = max(dependencies.clock.now, asOf ?? .distantPast)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendQueued(now: now, exitsOnly: exitsOnly, ignoringWindows: ignoringWindows)
            self.running = nil
            self.rearm(from: now)
            if self.refreshAfterDrain {
                self.refreshAfterDrain = false
                // Not awaited: the refresh drains the queue, which would then wait for this drain.
                let sync = self.dependencies.sync
                Task { @MainActor in await sync?.refresh() }
            }
        }
        running = task
        await task.value
    }

    /// Schedules the retry the paused groups need: the soonest end of a pause whose group still
    /// has tries left in a row. A group that used its three waits only for the next trigger.
    private func rearm(from now: Date) {
        let queued = Set(Self.load(dependencies.cache).ops.map { DuoOpQueue.group(of: $0.kind) })
        let due = paused.filter { queued.contains($0.key) && waitsInARow[$0.key, default: 0] < DuoRetry.maximumAttempts }
            .map(\.value.due).min()
        guard let due, scheduledRetry == nil else { return }
        scheduleRetry(due: due, from: now)
    }

    /// Waits until `due` through `dependencies.sleep`, then drains again, unless a trigger or a
    /// discard let it go first. Its own task, so whoever started the drain is not held for the delay.
    private func scheduleRetry(due: Date, from now: Date) {
        cancelScheduledRetry()
        let generation = self.generation
        let sleep = dependencies.sleep
        let delay = max(0, due.timeIntervalSince(now))
        let previous = lastRetry
        let retry = Task { @MainActor [weak self] in
            // The retry this one replaces was let go a moment ago, and its wait ends as soon as it
            // sees that; this one starts its own only after, so no more than one is ever under way
            // (a let-go wait could otherwise still be ending while this one began).
            await previous?.value
            var slept = true
            do {
                try await sleep(delay)
            } catch {
                slept = false
            }
            // Let go by a trigger or a discard, which has already cleared it (and may have put a
            // newer retry in its place). Otherwise this is the retry on file, and it is over now.
            guard let self, !Task.isCancelled else { return }
            self.scheduledRetry = nil
            guard slept, self.generation == generation else { return }
            await self.drainNow(asOf: due, exitsOnly: false, ignoringWindows: false)
        }
        scheduledRetry = retry
        lastRetry = retry
    }

    private func cancelScheduledRetry() {
        scheduledRetry?.cancel()
        scheduledRetry = nil
    }

    private func sendQueued(now: Date, exitsOnly: Bool, ignoringWindows: Bool) async {
        let found = Set(Self.load(dependencies.cache).ops.map(\.key))
        guard !found.isEmpty else { return }
        var blocked: Set<DuoOpQueue.Group> = exitsOnly ? [.profile, .push] : []
        if !ignoringWindows {
            for (group, pause) in paused where pause.isServerWindow && pause.due > now { blocked.insert(group) }
        }
        while true {
            let generation = self.generation
            let epoch = dependencies.host.wipeEpoch
            guard Self.load(dependencies.cache).next(skipping: blocked, among: found) != nil else { return }
            // Every bearer request is preceded by the identity's launch answer (§3.4), which is
            // kept for the launch, so asking again before each entry costs nothing once known.
            let launch = await dependencies.identity.prepare()
            guard isCurrent(generation, epoch) else { return }
            switch launch {
            case .ready:
                break
            case .disconnected:
                // The server decides about a leave or a block (allowed to a superseded phone for its
                // 30 days, `device_revoked` to one whose secret was rotated away); everything else
                // is refused to a superseded phone, so it is not sent.
                blocked.formUnion([.profile, .push])
            case .none:
                // The Keychain was read and holds no credential. A rename or a push entry was made for
                // an identity this phone no longer has and goes; a leave or a block waits, for the
                // Reconnect ("I had a duo") that would bring that member back.
                discardIdentityBound()
                return
            case .needsRestoreChoice, .unavailable:
                // The person has a question to answer first, or the launch could not tell yet: send
                // nothing and keep everything for the next trigger.
                return
            }
            if dependencies.credentialIsAThrowaway {
                // The credential is the throwaway a Reconnect minted and has not finished with: it is
                // nobody with a duo, and the cached duos are another member's, so a leave or a block
                // would be answered 404 and counted as done while the duo stayed live and a Block was
                // never applied. They wait, with nothing scheduled: the Reconnect that finishes the
                // throwaway clears the mark and drains, and they go then, under the member it brings
                // back.
                blocked.insert(.exits)
            }
            guard let op = Self.load(dependencies.cache).next(skipping: blocked, among: found) else { return }
            let group = DuoOpQueue.group(of: op.kind)

            let sent = await send(op)
            // A wipe or a discard while the request was out: its answer belongs to an identity or a
            // queue that is gone, and acting on it (a member record, a push record, a 401's discard)
            // would write something back onto a phone that has just forgotten it.
            guard isCurrent(generation, epoch) else { return }

            let disposition = DuoOpQueue.disposition(for: op, error: sent.error)
            if let error = sent.error {
                // Against the duo only while the phone still holds it: a Clear took its Diagnostics,
                // and a queued leave that fails afterwards must not write the cleared duo back.
                let duoID = op.duoID.flatMap(UUID.init(uuidString:)).flatMap { dependencies.host.duo($0) == nil ? nil : $0 }
                dependencies.noteFailure(error, duoID: duoID)
            } else {
                dependencies.noteSuccess()
            }
            switch disposition {
            case .done:
                waitsInARow[group] = nil
                paused[group] = nil
                settle(op, succeeded: true, sent, asksForARefresh: !exitsOnly)
            case .drop:
                waitsInARow[group] = nil
                paused[group] = nil
                settle(op, succeeded: false, sent, asksForARefresh: !exitsOnly)
            case .hold:
                // Kept as it is, and nothing is scheduled: a cancelled task, or nothing left the
                // phone or came back. That says something about this phone, not one group, so the
                // whole drain stops; the next trigger replays it.
                return
            case .discardAll:
                // `noteFailure` has already discarded the identity, and with it this queue; this is
                // the same rule said where the queue is.
                discardAll()
                return
            case .wait(let delay):
                // §6.7: honour the delay, at most three tries of one entry in a row, then wait for
                // the next foreground or connection. Only this group stops: the others go on.
                waitsInARow[group, default: 0] += 1
                paused[group] = Pause(due: now.addingTimeInterval(delay), isServerWindow: DuoOpQueue.isServerWait(sent.error))
                blocked.insert(group)
            }
        }
    }

    private func isCurrent(_ generation: Int, _ epoch: Int) -> Bool {
        generation == self.generation && epoch == dependencies.host.wipeEpoch
    }

    /// What one attempt brought back.
    private struct Sent {
        var error: Error?
        var left: DuoWireLeaveResponse?
        var member: DuoWireMember?
    }

    /// An entry that cannot be sent as it was saved (a leave or block with no duo id). It drops,
    /// since it never will be.
    private struct UnsendableEntry: Error {}

    /// One attempt, through the typed transport. The typed request is read back from the bytes the
    /// entry was saved with, and `DuoWireCoding` writes the same value as the same bytes, so the
    /// request that goes out is the one that was recorded (vector KV20): a replay under the same
    /// key is the same request, and a `PATCH /me` sent twice says the same thing twice.
    private func send(_ op: DuoQueuedOp) async -> Sent {
        let transport = dependencies.transport
        do {
            switch op.kind {
            case .leave:
                guard let duoID = op.duoID else { throw UnsendableEntry() }
                return Sent(left: try await transport.leave(duoID: duoID, key: DuoIdempotencyKey(op.key)))
            case .block:
                guard let duoID = op.duoID else { throw UnsendableEntry() }
                try await transport.block(duoID: duoID, key: DuoIdempotencyKey(op.key))
                return Sent()
            case .updateMe:
                let request = try DuoWireCoding.decode(DuoWireUpdateMeRequest.self, from: op.body)
                return Sent(member: try await transport.updateMe(request))
            case .registerPush:
                let request = try DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: op.body)
                try await transport.registerPush(request, firstUpload: op.attestsFirstUpload)
                return Sent()
            case .unregisterPush:
                try await transport.unregisterPush()
                return Sent()
            }
        } catch {
            return Sent(error: error)
        }
    }

    /// An entry is done with, sent or dropped for good: it leaves the queue, then what its answer
    /// says is applied. A 2xx whose body could not be read is a success with nothing to apply.
    /// Start fresh's last drain asks for no refresh: the refresh would run before its wipe and send
    /// what was queued for the identity being given up.
    private func settle(_ op: DuoQueuedOp, succeeded: Bool, _ sent: Sent, asksForARefresh: Bool) {
        var queue = Self.load(dependencies.cache)
        queue.remove(key: op.key)
        Self.save(queue, to: dependencies.cache)
        let host = dependencies.host
        switch op.kind {
        case .leave, .block:
            guard let id = op.duoID.flatMap(UUID.init(uuidString:)) else { return }
            // A block queued behind this leave still waits, and the card says so; otherwise nothing
            // is waiting for this duo any more.
            let stillWaiting = queue.ops.last { $0.duoID?.lowercased() == op.duoID?.lowercased() && ($0.kind == .leave || $0.kind == .block) }
            let barred: Bool
            if case .banned = sent.error as? DuoTransportError { barred = true } else { barred = false }
            host.update(id) { duo in
                let mine: DuoEndedBy = duo.myRole == .owner ? .owner : .partner
                if succeeded, let left = sent.left {
                    duo.endedAt = left.endedAt
                    duo.endedBy = left.endedBy
                } else if succeeded, duo.endedAt == nil {
                    // A block's 204 has no body. It ends the duo on the server, so a card still shown
                    // live (a kill between the queue and the card's write, a fetch that read it live
                    // while the block waited) ends here too.
                    duo.endedAt = dependencies.clock.now
                    duo.endedBy = mine
                } else if barred, duo.endedAt == op.createdAt, duo.endedBy == mine {
                    // A ban the phone learned only now, from this very request (availability is not
                    // kept across a launch): the server never ended the duo, so the end this entry
                    // stamped at the tap is taken back, and the banned banner says why. An end the
                    // card had from elsewhere stays. Every other drop keeps the ended card (§10.1).
                    duo.endedAt = nil
                    duo.endedBy = nil
                }
                duo.pendingOp = stillWaiting.map { $0.kind == .block ? .block : .leave }
            }
            // Whatever arrived for the duo between the tap and the landing goes too.
            if host.duo(id)?.hasEnded == true { dependencies.announcer?.removeDelivered(for: id) }
            if succeeded, asksForARefresh { refreshAfterDrain = true }
        case .updateMe:
            if succeeded {
                // The name and the skin the server now holds, and nothing else: the rest of the member
                // record comes from `GET /me`, and a record that does not exist yet is not made here.
                guard let member = sent.member, var info = host.memberInfo else { return }
                info.displayName = member.displayName
                info.skin = member.skin
                if info != host.memberInfo { host.memberInfo = info }
            } else if case .nameRejected = sent.error as? DuoTransportError {
                // The server refused the name: the person is told in the approved words, and the name
                // the next sheet starts from is the one the server holds, unless a later rename is
                // still on its way and says what they want now.
                host.notice = DuoUserMessage.text(for: sent.error ?? DuoTransportError.offline)
                let laterRename = queue.ops.contains { $0.kind == .updateMe }
                if !laterRename, let info = host.memberInfo { host.myDisplayName = info.displayName ?? "" }
            }
        case .registerPush, .unregisterPush:
            dependencies.push?.opFinished(op, succeeded: succeeded)
        }
    }

    // MARK: - The network

    /// Starts watching the network once; later calls do nothing.
    func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = makeMonitor()
        self.monitor = monitor
        monitor.start { [weak self] satisfied in self?.pathChanged(satisfied) }
    }

    /// Drains when the path becomes satisfied after it was not: a connection coming back. Every
    /// other reading (the first, one satisfied path after another as interfaces change, a path
    /// lost) starts nothing, so a phone moving between Wi-Fi and cellular does not drain each time.
    private func pathChanged(_ satisfied: Bool) {
        let previous = lastPathSatisfied
        lastPathSatisfied = satisfied
        guard satisfied, previous == false else { return }
        Task { [weak self] in await self?.drain() }
    }
}

/// `NWPathMonitor`, started on the main queue so each reading reaches the service in order, on
/// the main actor, where the service lives. Kept for as long as the service, which is the app's.
private final class DuoSystemPathMonitor: DuoOpQueueService.PathMonitoring {
    private let monitor = NWPathMonitor()

    func start(_ onPathChange: @escaping @MainActor (_ satisfied: Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            MainActor.assumeIsolated { onPathChange(satisfied) }
        }
        monitor.start(queue: .main)
    }
}
#endif
