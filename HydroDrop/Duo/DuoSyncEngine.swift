#if DUO_V2
import Foundation

/// The read and write path of a shared streak (final design §6.4 to §6.6, §8, §9.5, §9.7, §10,
/// D45, D71 to D73; plan P2 item 3's sync half). What to send and what an answer means is decided
/// by HydroCore's pure steps (`DuoSyncPlan`, `DuoRebase`, `DuoFeedReducer`, `DuoAnnouncements`);
/// this class sequences the requests around them and keeps nothing on disk of its own: the duos,
/// the member record and Diagnostics go through `DuoHost`, the ledger, the refused days and the
/// waiting nudges through `DuoCache`, and everything else here is memory that a relaunch is
/// allowed to forget.
///
/// The rules it keeps, each for a reason that cost something to learn:
///
/// - Consent (§3.1). Nothing is sent without a credential, and `prepare()` is asked only when the
///   cache holds a duo: on a phone sold with the app deleted but the Keychain intact, the first
///   `prepare()` sends `GET /me` under the previous owner's bearer and moves their `last_seen_at`,
///   which keeps their partner's reconnect refused for 72 hours. With no duo cached a refresh only
///   drains a queue that holds something (the Duo screen asks the identity itself, through
///   `DuoStore.duoScreenOpened()`).
/// - A duo is read before it is written (§3.4 step 4, §10.3, KV11), a new install only raises
///   (D71), and an answer that no longer fits the duo is dropped with its verdicts
///   (`DuoSyncPlan.answerFits`): after a reseat, or when a newer answer got there first.
/// - An answer is applied only while the wipe epoch and the identity are what they were when the
///   request was sent (`Ticket`): a late answer after Delete my Duo data, Start fresh or a 401
///   elsewhere would bring back a duo, a partner's name or a forgotten member's record.
/// - Retries wait through `dependencies.sleep`, at most `DuoRetry.maximumAttempts` in a row (a
///   success gives the budget back; a cancelled pass neither spends nor returns it), then for the
///   next foreground. A wait the server asked for (a 429 or a 503) holds every automatic trigger
///   until it is over, and the owed work fires then. A cancelled request schedules nothing.
/// - While a leave or a block waits in the op queue nothing is published to any duo: this phone
///   cannot tell which duos share that partner, and a pair-wide exit ends them all.
/// - It logs nothing. A failure goes to `noteFailure`, which keeps an id, a time and a code.
@MainActor
final class DuoSyncEngine: DuoSyncing {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    /// How long a row the server refused in a way this phone cannot fix (a downgrade it protects,
    /// a reason this build does not know) is held back before it is offered again.
    static let refusedRowHold: TimeInterval = 6 * 60 * 60

    // MARK: - What this engine remembers, in memory only

    private var logReader: DuoLogReading?
    private var monitoringStarted = false
    /// The goal of the last summary this engine was told, for the one-time note on a raise
    /// (§8.6). `DuoStore.logChanged` has replaced `host.latest` by the time the engine hears, so
    /// the store's copy cannot say what the goal was before.
    private var lastGoalML: Int?
    /// The skin the last `PATCH /me` this engine queued carried, so a change is queued once and
    /// not again on every drink until the next `GET /me` says the server has it.
    private var lastQueuedSkin: String?
    private var coalescer = DuoWriteCoalescer()
    /// The wipe epoch this engine's memory belongs to.
    private var epochSeen: Int?

    private var pendingSync: SyncScope?
    private var syncLoop: Task<Void, Never>?
    /// The one read waiting to happen later: a retry, or the owed read at the end of a wait the
    /// server asked for. A new one replaces it.
    private var syncWake: Int?
    private var syncRetries = 0
    private var syncRetriesExhausted = false
    private var readsHeldUntil: Date?

    private var publishLoop: Task<Void, Never>?
    private var publishStale = false
    /// Whether everyone waiting on the running write pass is a background run, which may stop it.
    private var publishOnlyBackground = false
    private var publishWake: Int?
    private var publishRetries = 0
    private var publishRetriesExhausted = false
    private var writesHeldUntil: Date?
    private var owedWrite: Int?
    /// Moves whenever an owed write is overtaken, so one that wakes late does nothing.
    private var owedGeneration = 0
    private var heldRows: [UUID: [HeldRow]] = [:]

    private var backgroundWork: Task<Void, Never>?
    private var backgroundWaiters: [Int: BackgroundWaiter] = [:]
    private var backgroundWaiterCount = 0
    /// Set when the last caller of a background run was cancelled: the run sends nothing more.
    private var backgroundStop = false

    private var nudgesInFlight: Set<String> = []
    private var nudgeRetries: [String: Int] = [:]
    /// The optimistic copies on the cards that this engine knows the server has not confirmed,
    /// by lowercased nudge id: every one it put there, and every one it has found in the in-flight
    /// journal. A copy whose journal entry is gone (the journal keeps one for 23 hours) and that
    /// was never confirmed is taken off its card (`dropAbandonedNudgeCopies`); it used to stay for
    /// up to 48 hours as if it had been sent. Memory only: an entry the journal dropped at launch,
    /// before this engine saw it, still leaves its copy until the duo's nudges are pruned.
    private var nudgeCopies: [String: NudgeCopy] = [:]

    /// A copy is known by its id and its time, the tap's, which the journal entry keeps too. A row
    /// the server confirmed carries the server's own time, so a confirmed nudge is never taken
    /// for its copy.
    private struct NudgeCopy {
        let duoID: UUID
        let createdAt: Date
    }

    /// Announcements iOS refused to take, offered again at the next delivery while they are still
    /// worth showing. Forgetting their ledger key alone would not bring them back: the next feed's
    /// `before` already holds the nudge or the met day, so `plan` would not see them as new.
    private var refusedAnnouncements: [String: RefusedAnnouncement] = [:]
    /// Counts read and write passes, so an announcement iOS refused is offered again in a later
    /// pass, not a moment after the refusal.
    private var passNumber = 0

    private var spawned: [Int: Task<Void, Never>] = [:]
    private var spawnCount = 0

    private struct RefusedAnnouncement {
        let announcement: DuoAnnouncement
        let pass: Int
    }

    private struct HeldRow {
        var row: DuoDayStatus
        var until: Date
        /// The `ver` of the day's row the refusal was judged against, as this phone knows it.
        var against: Int64
    }

    private struct BackgroundWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let before: [DuoState]
        let epoch: Int
    }

    /// What a request was sent under. Its answer is applied only while both are unchanged.
    private struct Ticket: Equatable {
        let epoch: Int
        let deviceID: String?
        let memberID: String?
    }

    private struct UnconfirmedNudge {
        let operation: String
        let duoID: UUID
        let request: DuoWireSendNudgeRequest
        let createdAt: Date
    }

    private enum PassOutcome {
        case clean
        case retry(after: TimeInterval, serverSaid: Bool)
        /// A wait the server asked for is still running: nothing was sent.
        case held(until: Date)
        /// The identity, the standing or a wipe ended the pass.
        case stopped
        case cancelled

        func merged(with retry: TimeInterval, serverSaid: Bool) -> PassOutcome {
            if case .retry(let after, let said) = self { return .retry(after: max(after, retry), serverSaid: said || serverSaid) }
            return .retry(after: retry, serverSaid: serverSaid)
        }
    }

    private enum SyncScope {
        /// A refresh: the queue, `GET /me` when it is due (or `forcesMe`), and every live duo.
        /// `external` is a refresh somebody asked for (a foreground, the Duo screen, a pull, a
        /// background task), as against a retry or a push; `onlyBackground` says that a background
        /// run is all that asked, so its cancellation may stop the pass.
        case everything(forcesMe: Bool, external: Bool, onlyBackground: Bool)
        /// A push for these duos (§6.8, vector KV17).
        case duos(Set<UUID>)

        func merged(with other: SyncScope) -> SyncScope {
            switch (self, other) {
            case let (.everything(a, x, p), .everything(b, y, q)): return .everything(forcesMe: a || b, external: x || y, onlyBackground: p && q)
            case let (.everything(a, x, _), .duos), let (.duos, .everything(a, x, _)): return .everything(forcesMe: a, external: x, onlyBackground: false)
            case let (.duos(a), .duos(b)): return .duos(a.union(b))
            }
        }
    }

    private enum PutResult {
        case written(announcements: [DuoAnnouncement], retry: Bool, held: [DuoDayStatus])
        case skipped
        case failed(DuoRetry.Verdict, serverSaid: Bool)
        case gone
    }

    private enum NudgeAttempt {
        case finished
        case retry
        case kept
    }

    private enum NudgeFailure {
        /// The network or the service: keep the copy and try the same id again.
        case retry
        /// The request may well have landed: keep the copy, schedule nothing, and send the same id
        /// at the next foreground.
        case keep
        /// A refusal: remove the copy.
        case drop
    }

    private var host: DuoHost { dependencies.host }
    private var clock: DuoClock { dependencies.clock }
    private var cache: DuoCache { dependencies.cache }
    private var hasCredential: Bool { dependencies.identity?.credential != nil }

    /// Reads are refused only where the server would refuse them or the person has a question to
    /// answer first: a banned or disconnected phone, or a restore that is not settled. A
    /// disconnected phone stays so until a Reconnect succeeds or the person starts fresh, so no
    /// foreground repeats the 401 that disconnected it.
    private var readsAllowed: Bool {
        switch host.availability {
        case .banned, .disconnected, .needsRestoreChoice: return false
        case .unknown, .available, .maintenance, .upgradeRequired: return true
        }
    }

    /// A leave or a block waits in the op queue (stage E, F9). Until it is sent nothing is written
    /// to any duo: the client has no partner id to tell a sibling duo by, a pair-wide exit ends
    /// every duo of the pair, and the server would refuse the siblings while the person who left
    /// still saw their progress go to the partner they left.
    private var exitQueued: Bool {
        dependencies.ops?.pending.contains { $0.kind == .leave || $0.kind == .block } ?? false
    }

    /// The reader says the store it reads is not the person's log (the App Group's store would
    /// not open, `SwiftDataDuoLogReader`). The app's own summaries come from that same store, so
    /// nothing is published from any summary while it says so; reads go on.
    private var logIsNotThePersons: Bool {
        (logReader as? DuoLogSourceVetting)?.readsThePersonsLog == false
    }

    // MARK: - DuoSyncing

    func activate(logReader: DuoLogReading) {
        self.logReader = logReader
        // Sends nothing itself. The monitor drains on a transition to a satisfied network, and a
        // queue is only ever non-empty once an identity exists, so a phone without one is left
        // entirely alone.
        guard hasCredential else { return }
        startMonitoringOnce()
    }

    func logChanged(_ summary: DuoLogSummary) {
        forgetWhatAWipeTook()
        take(summary)
        requestPublish()
    }

    func refresh() async { await refresh(background: false) }

    func flush() async { await flush(background: false) }

    func backgroundRefresh() async -> Bool {
        let before = host.duos
        let epoch = host.wipeEpoch
        // A granted refresh and a push can land together: both wait on the one piece of work.
        if backgroundWork == nil {
            backgroundStop = false
            backgroundWork = Task { [self] in
                await runBackground()
                backgroundWork = nil
                let waiting = backgroundWaiters
                backgroundWaiters = [:]
                for waiter in waiting.values { waiter.continuation.resume(returning: backgroundAnswer(waiter)) }
            }
        } else {
            backgroundStop = false
        }
        backgroundWaiterCount += 1
        let id = backgroundWaiterCount
        // Stage F's handler awaits this before `setTaskCompleted`, and iOS's expiration handler
        // cancels it: a cancelled caller is answered at once (the network may be hung), and the
        // run sends nothing more once nobody is waiting for it.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                backgroundWaiters[id] = BackgroundWaiter(continuation: continuation, before: before, epoch: epoch)
                if Task.isCancelled { cancelBackgroundWaiter(id) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelBackgroundWaiter(id) }
        }
    }

    func pushArrived(_ payload: DuoPushPayload) async {
        forgetWhatAWipeTook()
        // A push with nothing cached is not a reason to ask `prepare()` (see the header).
        guard !host.duos.isEmpty else { return }
        if let duo = host.duo(payload.duoID) {
            // Only a push ahead of what this phone has read is worth a fetch (§6.8, KV17). Every
            // kind, `ended`, `joined`, `reconnected`, `digest` and ones this build has never
            // heard of included, is only that: a reason to read the feed, whose `handled` list
            // marks a digest's events seen.
            guard !duo.hasEnded, duo.pendingOp == nil, DuoPushGate.shouldFetch(cursor: duo.cursor, seq: payload.seq) else { return }
            await sync(.duos([duo.id]))
        } else {
            // A duo this phone does not hold: `GET /me` lists it, and the refresh reads it.
            await sync(.everything(forcesMe: true, external: false, onlyBackground: false))
        }
    }

    func sendNudge(_ preset: DuoNudgePreset, in stale: DuoState) async {
        forgetWhatAWipeTook()
        guard hasCredential, host.availability.allowsWrites, let duo = host.duo(stale.id), !duo.hasEnded, duo.pendingOp == nil else { return }
        let now = clock.now
        let today = clock.today
        // Judged against the duo as it is now, and the copy appended before anything waits, so
        // two quick taps cannot both be the third of the day.
        let partner = DuoStreak.currentStatus(of: duo.myRole.other, statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
        let limit = host.memberInfo?.nudgesPerDay ?? DuoNudgeRules.dailyLimit
        guard case .allowed = DuoNudgeRules.verdict(for: duo, partnerStatus: partner, now: now, dailyLimit: limit, calendar: clock.calendar) else { return }
        // `nudge-` and an uppercase UUID, as iOS writes them (§6.6), from the injected randomness.
        let nudge = DuoNudge(id: DuoNudge.recordPrefix + dependencies.random.uuid().uuidString, fromRole: duo.myRole,
                             presetID: preset.rawValue, createdAt: now)
        let request = DuoWireSendNudgeRequest(id: nudge.id, presetId: preset.rawValue, senderDay: today)
        host.update(duo.id) { $0.nudges = $0.allNudges + [nudge] }
        // The request is kept in the in-flight journal before it is sent: the nudge's id is its
        // key, so a relaunch sends the very same request again and the server answers a repeat
        // with the row it stored. Kept in memory only, a copy whose request was lost stayed on
        // the card for two days and used up the day's nudges (a low tier has one).
        let operation = Self.nudgeOperation(duoWire: duo.wireID, nudgeID: nudge.id)
        guard let body = try? DuoWireCoding.encode(request) else { return }
        var journal = cache.loadInflight(now: now)
        _ = journal.key(for: operation, body: body, now: now, random: dependencies.random)
        cache.saveInflight(journal)
        nudgeCopies[nudge.id.lowercased()] = NudgeCopy(duoID: duo.id, createdAt: now)
        let epoch = host.wipeEpoch
        guard await isReady(), host.wipeEpoch == epoch else { return }
        let ticket = currentTicket()
        // One attempt here, and the retries (30, 60 and 120 s) on a task of their own: the Duo
        // screen's button must not be held for three and a half minutes.
        if await attemptNudge(operation, ticket: ticket) == .retry { scheduleNudgeRetries(operation, ticket: ticket) }
    }

    // MARK: - Refresh, flush and the background run

    private func refresh(background: Bool) async {
        forgetWhatAWipeTook()
        // A refresh somebody asked for is the "next foreground" a spent run of retries waits
        // for, and replaces a retry still waiting. A wait the server asked for still holds it:
        // the pass then leaves the owed read at its end.
        cancelSpawned(syncWake)
        syncWake = nil
        syncRetries = 0
        syncRetriesExhausted = false
        publishRetriesExhausted = false
        await sync(.everything(forcesMe: false, external: true, onlyBackground: background))
    }

    private func flush(background: Bool) async {
        forgetWhatAWipeTook()
        if !background { rereadLog() } else { ensureLatest() }
        guard hasSomethingUnsent() else { return }
        if let until = heldUntil(writesHeldUntil) {
            schedulePublishWake(after: until.timeIntervalSince(clock.now), replacing: false)
            return
        }
        switch coalescerRequest() {
        case .writeNow: await publish(background: background)
        case .wait(let until): scheduleOwedWrite(until: until)
        case .alreadyWaiting: break
        }
    }

    private func runBackground() async {
        forgetWhatAWipeTook()
        // Drinks logged from a widget or the watch while the app was closed reach the partner
        // too. A summary with no goal is a log that could not be read, not an empty one, and is
        // never published (`DuoSyncPlan.write`).
        if let reader = logReader {
            let summary = reader.read(now: clock.now)
            if summary.goalML > 0 {
                if host.latest != summary { host.latest = summary }
                take(summary)
            }
        }
        // Publish, then fetch (§10.6): the write's own answer is a feed, and a duo that has not
        // been read is skipped by the write and read by the refresh.
        guard !backgroundStop else { return }
        await flush(background: true)
        guard !backgroundStop else { return }
        await refresh(background: true)
    }

    /// True when the duos changed during the run, and never for a wipe: iOS is told about new
    /// data, and a wipe is not that.
    private func backgroundAnswer(_ waiter: BackgroundWaiter) -> Bool {
        host.wipeEpoch == waiter.epoch && host.duos != waiter.before
    }

    private func cancelBackgroundWaiter(_ id: Int) {
        guard let waiter = backgroundWaiters.removeValue(forKey: id) else { return }
        if backgroundWaiters.isEmpty { backgroundStop = true }
        waiter.continuation.resume(returning: backgroundAnswer(waiter))
    }

    private func stopRequested(_ scope: SyncScope) -> Bool {
        if case .everything(_, _, true) = scope { return backgroundStop }
        return false
    }

    // MARK: - The log

    /// What every new summary is checked for, whichever way it arrived.
    private func take(_ summary: DuoLogSummary) {
        noteGoal(summary.goalML)
        queueSkinChangeIfNeeded()
    }

    /// The one-time note on a goal raise (§8.6, vector X5): shown once ever, and only to someone
    /// with a live duo this phone has read, since the re-judged week is what it is about. The
    /// re-judging itself is the outbox's (`DuoOutbox.unsent` against the new goal).
    private func noteGoal(_ goal: Int) {
        defer { if goal > 0 { lastGoalML = goal } }
        guard goal > 0, let previous = lastGoalML, goal > previous, !cache.goalRaiseNoticeShown,
              host.duos.contains(where: { !$0.hasEnded && $0.syncedOnce }) else { return }
        host.notice = DuoCopy.goalRaiseNotice
        cache.goalRaiseNoticeShown = true
    }

    /// A skin the server does not have yet goes out as a queued `PATCH /me`, so an offline change
    /// lands later (§10.1). Only while writes are allowed and a live duo is held with no leave or
    /// block waiting: a skin is shown only to a partner, and one queued from a phone that is
    /// disconnected, banned or leaving would go out under an identity with nobody to show it to.
    /// Compared with what the server will hold once the queue has drained: a skin already waiting
    /// in the queue, the one this engine queued last, or `GET /me`'s.
    private func queueSkinChangeIfNeeded() {
        guard hasCredential, host.availability.allowsWrites, host.duos.contains(where: { !$0.hasEnded && $0.pendingOp == nil }),
              let ops = dependencies.ops, let held = host.memberInfo?.skin else { return }
        let skin = dependencies.activeSkin()
        let waiting = ops.pending.reversed().lazy.compactMap { op -> String? in
            guard op.kind == .updateMe, let request = try? DuoWireCoding.decode(DuoWireUpdateMeRequest.self, from: op.body),
                  case .value(let queued) = request.skin else { return nil }
            return queued
        }.first
        guard skin != (waiting ?? lastQueuedSkin ?? held) else { return }
        guard let op = try? DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(skin: .value(skin)),
                                                 key: DuoIdempotencyKey.make(random: dependencies.random).value, now: clock.now) else { return }
        ops.enqueue(op)
        lastQueuedSkin = skin
    }

    /// A refresh with nobody looking (after a notification, say) still has the log to publish.
    private func ensureLatest() {
        guard host.latest == nil, let reader = logReader else { return }
        let summary = reader.read(now: clock.now)
        guard summary.goalML > 0 else { return }
        host.latest = summary
        take(summary)
    }

    /// D73: a refresh reads the log again while a live duo is held, so a deleted or edited drink,
    /// a goal change, a drink from another device or the end of an iCloud import reaches the duo
    /// without waiting for the next drink logged in the app.
    private func rereadLog() {
        guard let reader = logReader, host.duos.contains(where: { !$0.hasEnded }) else {
            ensureLatest()
            return
        }
        let summary = reader.read(now: clock.now)
        guard summary.goalML > 0 else { return }
        if host.latest != summary { host.latest = summary }
        take(summary)
    }

    private func coverageStart(_ latest: DuoLogSummary) -> String {
        DuoCoverage.start(installDay: dependencies.identity?.installDay ?? DuoCoverage.coversNoPastDay, earliestEntryDay: latest.earliestEntryDay)
    }

    private func installAge() -> TimeInterval {
        guard let day = dependencies.identity?.installDay else { return 0 }
        return DuoCoverage.installAge(installDay: day, now: clock.now, calendar: clock.calendar)
    }

    // MARK: - Reading

    /// Every read goes through here, one pass at a time. A request that arrives while a pass
    /// runs is merged into the next one, which runs once after it, and its caller returns when
    /// that pass is over.
    private func sync(_ scope: SyncScope) async {
        pendingSync = pendingSync.map { $0.merged(with: scope) } ?? scope
        if let running = syncLoop {
            await running.value
            return
        }
        let loop = Task { [self] in
            while let next = pendingSync {
                pendingSync = nil
                afterSync(await syncPass(next))
            }
            syncLoop = nil
        }
        syncLoop = loop
        await loop.value
    }

    /// One read: the identity, the queue, `GET /me` when due, each duo's feed with its
    /// announcements delivered right after it, and then whatever is owed.
    private func syncPass(_ scope: SyncScope) async -> PassOutcome {
        forgetWhatAWipeTook()
        passNumber += 1
        guard readsAllowed else { return .stopped }
        guard !host.duos.isEmpty else {
            // A credential with no duo (a Create that failed, everything cleared) sends nothing
            // but what its queue already holds: `GET /me` here would go out on every launch and
            // keep `last_seen_at` fresh, which §12.1 uses to delete a member who never joined a
            // duo 30 days after they last used it.
            if case .everything = scope, hasCredential, let ops = dependencies.ops, !ops.pending.isEmpty { await ops.drain() }
            return .clean
        }
        if let until = heldUntil(readsHeldUntil) { return .held(until: until) }
        // The epoch is read before the identity is asked: a wipe while `prepare()` runs ends the pass.
        let epoch = host.wipeEpoch
        guard await isReady(), host.wipeEpoch == epoch, readsAllowed else { return .stopped }
        let ticket = currentTicket()
        guard ticket.deviceID != nil else { return .stopped }
        startMonitoringOnce()
        if case .everything(let forcesMe, _, _) = scope {
            guard !stopRequested(scope) else { return .stopped }
            await dependencies.ops?.drain()
            guard isCurrent(ticket), readsAllowed, !stopRequested(scope) else { return .stopped }
            guard await refreshMember(force: forcesMe, ticket: ticket) else { return .stopped }
        }

        var outcome = PassOutcome.clean
        let targets: [UUID]
        switch scope {
        case .everything: targets = host.duos.map(\.id)
        case .duos(let ids): targets = host.duos.map(\.id).filter(ids.contains)
        }
        reads: for id in targets {
            guard isCurrent(ticket), readsAllowed, !stopRequested(scope) else { return .stopped }
            guard let duo = host.duo(id), !duo.hasEnded, duo.pendingOp == nil else { continue }
            // A duo not read since a reinstall, reconnect or link is read whole (§10.3).
            let since = duo.syncedOnce ? duo.cursor : 0
            do {
                let changes = try await dependencies.transport.fetchChanges(duoID: duo.wireID, since: since)
                guard isCurrent(ticket) else { return .stopped }
                dependencies.noteSuccess()
                let applied = await apply(changes, to: id, since: since, ticket: ticket, recordsFetch: true)
                // Delivered now, before the next duo's request: marked seen and then lost with a
                // pass that never finished (iOS ending a background task) is never announced.
                await deliver(applied.announcements, ticket: ticket)
            } catch {
                guard isCurrent(ticket) else { return .stopped }
                switch dependencies.noteFailure(error, duoID: id) {
                case .ended:
                    endLocally(id)
                case .retry(let after):
                    let serverSaid = Self.serverAskedToWait(error)
                    outcome = outcome.merged(with: after, serverSaid: serverSaid)
                    // The server asked this phone to wait: the other duos wait with it.
                    if serverSaid { break reads }
                case .cancelled:
                    return .cancelled
                case .reidentify, .disconnected, .banned:
                    return .stopped
                case .upgradeRequired, .termsRequired, .fail:
                    break
                }
            }
        }
        await deliver([], ticket: ticket)
        guard isCurrent(ticket) else { return .stopped }
        if case .everything(_, true, _) = scope { resumeUnconfirmedNudges(ticket: ticket) }
        if case .everything(_, _, true) = scope { ensureLatest() } else { rereadLog() }
        requestPublish(background: { if case .everything(_, _, true) = scope { return true }; return false }())
        return outcome
    }

    private func afterSync(_ outcome: PassOutcome) {
        switch outcome {
        case .clean:
            syncRetries = 0
            syncRetriesExhausted = false
        case .cancelled, .stopped:
            break
        case .held(let until):
            scheduleSyncWake(after: until.timeIntervalSince(clock.now), retry: false)
        case .retry(let after, let serverSaid):
            if serverSaid { readsHeldUntil = clock.now.addingTimeInterval(after) }
            guard !syncRetriesExhausted else { return }
            guard syncRetries < DuoRetry.maximumAttempts else {
                // Left for the next foreground, which starts again from the cache.
                syncRetries = 0
                syncRetriesExhausted = true
                return
            }
            syncRetries += 1
            scheduleSyncWake(after: after, retry: true)
        }
    }

    /// A retry replaces the read waiting to happen; an owed read at the end of a hold is added
    /// only when none is waiting.
    private func scheduleSyncWake(after delay: TimeInterval, retry: Bool) {
        guard retry || syncWake == nil else { return }
        cancelSpawned(syncWake)
        // A wake that sleeps through a wipe belongs to the identity that is gone: it wakes into a
        // phone that may already hold another, with nothing having called the engine between.
        let epoch = host.wipeEpoch
        var me = 0
        me = spawn { [self] in
            do { try await dependencies.sleep(max(0, delay)) } catch { return }
            guard !Task.isCancelled, host.wipeEpoch == epoch else { return }
            if syncWake == me { syncWake = nil }
            await sync(.everything(forcesMe: false, external: false, onlyBackground: false))
        }
        syncWake = me
    }

    /// `GET /me`, when a duo is cached and the last answer is an hour old or there is none
    /// (§3.4), or when a push named a duo this phone does not hold. False when the pass must
    /// stop: the identity is gone, disconnected, banned or replaced, the task was cancelled, or a
    /// wipe ran.
    private func refreshMember(force: Bool, ticket: Ticket) async -> Bool {
        if !force, let info = host.memberInfo {
            // A clock that moved back past the last answer reads as stale, not as fresh forever.
            let age = clock.now.timeIntervalSince(info.updatedAt)
            if age >= 0, age < DuoProtocolConstants.meRefreshInterval { return true }
        }
        do {
            let me = try await dependencies.transport.me()
            // The member record is the identity's: an answer that lands after a 401 elsewhere
            // forgot it, or after a tap stored another, would write the forgotten member, its
            // device list and its duos back.
            guard isCurrent(ticket) else { return false }
            dependencies.noteSuccess()
            let now = clock.now
            let member = DuoMapping.member(me, now: now)
            host.memberInfo = member
            lastQueuedSkin = nil
            noticeNewDevices(member.devices)
            for header in me.duos {
                // The server lists an ended duo for 30 days, and a Clear is local only (§12.2), so
                // an ended or a cleared one would come straight back as a card. A new one is
                // unread (`syncedOnce` false): the fetch below reads it whole before anything is
                // written to it.
                guard let id = UUID(uuidString: header.id), host.duo(id) == nil, header.state != .ended,
                      !cache.isCleared(id, now: now), let duo = DuoMapping.duo(from: header, previous: nil, now: now) else { continue }
                host.upsert(duo)
            }
            return true
        } catch {
            guard isCurrent(ticket) else { return false }
            switch dependencies.noteFailure(error) {
            case .reidentify, .disconnected, .banned, .cancelled: return false
            case .ended, .retry, .upgradeRequired, .termsRequired, .fail: return true
            }
        }
    }

    /// D45: a `link_device` redeem tells nobody, so the app compares the devices `GET /me` lists
    /// with the ones the person was last told about. The first list is saved silently; after
    /// that a device that is neither superseded nor this phone and was not in it raises the
    /// notice, which the screen shows and `DuoStore.dismissNewDeviceNotice()` settles. This phone
    /// is left out because after a 401 the saved list is the forgotten member's, and this phone's
    /// own new device would otherwise read as somebody else's.
    private func noticeNewDevices(_ devices: [DuoDeviceInfo]) {
        guard let seen = cache.loadSeenDeviceIDs() else {
            cache.saveSeenDeviceIDs(devices.map(\.id))
            return
        }
        let known = Set(seen)
        if devices.contains(where: { !$0.superseded && !$0.thisDevice && !known.contains($0.id) }) { host.newDeviceNotice = true }
    }

    /// Applies a feed, a fetch's or a write's answer, through the one pure step, and returns what
    /// it is worth announcing. The ledger is read and the duo committed in one stretch with no
    /// wait in it, after the announcer has been asked which events already have a remote
    /// notification on this phone (X14), so a fetch and a write that cross cannot both announce
    /// one event. Nothing waits after the commit, so a caller can re-base on it at once.
    private func apply(_ changes: DuoWireChanges, to id: UUID, since: Int64, ticket: Ticket,
                       recordsFetch: Bool) async -> (applied: Bool, announcements: [DuoAnnouncement]) {
        var delivered: [String: Bool] = [:]
        for round in 1...3 {
            guard isCurrent(ticket), let before = host.duo(id), DuoSyncPlan.answerFits(changes, since: since, before: before),
                  let planned = DuoSyncPlan.process(changes: changes, before: before, ledger: cache.loadLedger(),
                                                    deliveredRemoteKeys: Set(delivered.filter(\.value).keys), myToday: clock.today,
                                                    now: clock.now, calendar: clock.calendar, since: since) else { return (false, []) }
            let unasked = planned.announcements.map(\.key).filter { delivered[$0] == nil }
            if unasked.isEmpty || round == 3 || dependencies.announcer == nil {
                let hadLive = host.duos.contains { !$0.hasEnded }
                host.update(id) { $0 = withWaitingNudges(planned.duo) }
                cache.saveLedger(planned.ledger)
                confirmNudges(in: changes, for: id)
                if recordsFetch {
                    host.diagnostics.recordFetch(duoID: id, seq: changes.duo.seq, cursor: planned.duo.cursor, at: clock.now)
                }
                if hadLive, !host.duos.contains(where: { !$0.hasEnded }) { dependencies.push?.noLiveDuoRemains() }
                return (true, planned.announcements)
            }
            for key in unasked {
                delivered[key] = await dependencies.announcer?.hasDeliveredRemote(forKey: key) ?? false
            }
        }
        return (false, [])
    }

    /// A full feed replaces every nudge the duo held, the optimistic copies of nudges still on
    /// their way included. They are put back: dropped, the day's limit was judged without them
    /// and a fourth nudge could go out for a limit of three.
    private func withWaitingNudges(_ duo: DuoState) -> DuoState {
        let waiting = unconfirmedNudges().filter { $0.duoID == duo.id }
        guard !waiting.isEmpty else { return duo }
        var restored = duo
        var nudges = duo.allNudges
        for copy in waiting where !nudges.contains(where: { $0.id == copy.request.id }) {
            nudges.append(DuoNudge(id: copy.request.id, fromRole: duo.myRole, presetID: copy.request.presetId, createdAt: copy.createdAt))
        }
        restored.nudges = nudges
        return restored
    }

    /// `duo_unknown` or `duo_ended` for a duo this phone holds: the server has no live duo there
    /// any more. The card says it ended, with no alert (§6.7), its notifications go (§9.7), and the
    /// push token is let go when nothing live is left (§3.1).
    private func endLocally(_ id: UUID) {
        let hadLive = host.duos.contains { !$0.hasEnded }
        let now = clock.now
        host.update(id) { duo in
            guard duo.endedAt == nil else { return }
            duo.endedAt = now
            duo.endedBy = .unknown
            duo.invite = nil
            duo.openInviteExpiresAt = nil
        }
        dependencies.announcer?.removeDelivered(for: id)
        for copy in unconfirmedNudges() where copy.duoID == id { forgetNudge(copy.operation) }
        nudgeCopies = nudgeCopies.filter { $0.value.duoID != id }
        refusedAnnouncements = refusedAnnouncements.filter { $0.value.announcement.duoID != id }
        heldRows[id] = nil
        if hadLive, !host.duos.contains(where: { !$0.hasEnded }) { dependencies.push?.noLiveDuoRemains() }
    }

    // MARK: - Announcing

    /// Hands what a pass found to the notifier, with anything iOS refused earlier that is still
    /// worth showing. What iOS refuses this time is taken back out of the ledger and kept to be
    /// offered again (§9.5); turned off is an answer, not a refusal, and is the notifier's to say.
    private func deliver(_ fresh: [DuoAnnouncement], ticket: Ticket) async {
        guard isCurrent(ticket) else { return }
        var batch = fresh
        let now = clock.now
        var ledger = cache.loadLedger()
        var ledgerChanged = false
        for (key, refusal) in refusedAnnouncements where refusal.pass < passNumber {
            refusedAnnouncements[key] = nil
            let held = refusal.announcement
            // Not again if a push has since said it (a `handled` list marked it seen), if the duo is
            // over, or if it has gone stale the way a fresh one would have been left unannounced.
            guard !batch.contains(where: { $0.key == key }), !ledger.hasSeen(key), let duo = host.duo(held.duoID), !duo.hasEnded,
                  Self.stillWorthShowing(held, in: duo, now: now) else { continue }
            if ledger.markSeen(key) { ledgerChanged = true }
            batch.append(held)
        }
        if ledgerChanged { cache.saveLedger(ledger) }
        guard !batch.isEmpty else { return }
        let refused: [String]
        if let announcer = dependencies.announcer {
            refused = await announcer.deliver(batch, now: now)
        } else {
            refused = batch.map(\.key)
        }
        // A wipe while the notifier worked took the ledger with it: nothing is written back.
        guard isCurrent(ticket), !refused.isEmpty else { return }
        var after = cache.loadLedger()
        for key in Set(refused) {
            after.forget(key)
            if let announcement = batch.first(where: { $0.key == key }) {
                refusedAnnouncements[key] = RefusedAnnouncement(announcement: announcement, pass: passNumber)
            }
        }
        cache.saveLedger(after)
    }

    /// A nudge is worth announcing for 12 hours after it was sent (§8.2), and a goal until its
    /// day is over everywhere (§9.5), the same bounds a fresh one is judged by.
    private static func stillWorthShowing(_ announcement: DuoAnnouncement, in duo: DuoState, now: Date) -> Bool {
        switch announcement.kind {
        case .nudge:
            guard let nudge = duo.allNudges.first(where: { $0.id == announcement.key }) else { return false }
            return now.timeIntervalSince(nudge.createdAt) <= DuoNudgeRules.announceWithin
        case .partnerMetGoal:
            guard let day = announcement.key.split(separator: "|").last.map(String.init), DuoStreak.isDayKey(day) else { return false }
            return !DuoStreak.isOverEverywhere(day, now: now)
        }
    }

    // MARK: - Publishing

    /// Asked far more often than there is anything to say: every drink, every foreground, every
    /// change of goal. Only an actual difference costs a write, or counts towards the thirty
    /// seconds (§10.1, V12), and none goes out while the server's wait runs.
    private func requestPublish(background: Bool = false) {
        guard hasSomethingUnsent() else { return }
        if let until = heldUntil(writesHeldUntil) {
            schedulePublishWake(after: until.timeIntervalSince(clock.now), replacing: false)
            return
        }
        switch coalescerRequest() {
        case .writeNow: spawn { [self] in await publish(background: background) }
        case .wait(let until): scheduleOwedWrite(until: until)
        case .alreadyWaiting: break
        }
    }

    /// The coalescer, asked with two things it cannot see: a clock set back since the last write
    /// (the last write is then in the future, and its thirty seconds would last until the clock
    /// caught up, every request meanwhile `alreadyWaiting`), and an owed write a later write has
    /// overtaken, which must not wake and write again inside the thirty seconds.
    private func coalescerRequest() -> DuoWriteCoalescer.Decision {
        if let last = coalescer.lastWriteAt, last > clock.now {
            cancelOwedWrite()
            coalescer = DuoWriteCoalescer()
        }
        let decision = coalescer.request(now: clock.now)
        if case .writeNow = decision { cancelOwedWrite() }
        return decision
    }

    private func scheduleOwedWrite(until: Date) {
        // Never longer than the coalescer's own interval, whatever the clock says.
        let delay = min(max(0, until.timeIntervalSince(clock.now)), DuoWriteCoalescer.minimumInterval)
        owedGeneration += 1
        let generation = owedGeneration
        let epoch = host.wipeEpoch
        owedWrite = spawn { [self] in
            do {
                try await dependencies.sleep(delay)
            } catch {
                // Never left waiting: a coalescer that thinks a write is owed answers
                // `alreadyWaiting` to every later request. An overtaken one has nothing to undo.
                if generation == owedGeneration { coalescer.waitEnded(now: clock.now) }
                return
            }
            guard generation == owedGeneration, host.wipeEpoch == epoch else { return }
            owedWrite = nil
            // The time it actually woke, which can be well after `until` (KV19).
            coalescer.waitEnded(now: clock.now)
            await publish(background: false)
        }
    }

    private func cancelOwedWrite() {
        owedGeneration += 1
        cancelSpawned(owedWrite)
        owedWrite = nil
    }

    /// The thirty seconds are between requests, not between the coalescer's yeses. A pass can
    /// wait a long time between being let through and sending (the identity being asked, a write
    /// to another duo held up), and the coalescer used to count from the yes: a pass let through
    /// at 114 s that sent at 147 s was followed by one let through at 147 s, whose write and
    /// conflict retry made three requests to one duo in the same second. So every request counts
    /// the spacing again from when it goes out, and a write owed meanwhile moves with it.
    private func countSpacingFromNow() {
        if let last = coalescer.lastWriteAt, last >= clock.now { return }
        let owed = coalescer.isWaiting
        coalescer.waitEnded(now: clock.now)
        guard owed else { return }
        cancelOwedWrite()
        if case .wait(let until) = coalescer.request(now: clock.now) { scheduleOwedWrite(until: until) }
    }

    /// Whether any duo is owed a write right now. Asks nothing of the network, and reads the
    /// install day only with a credential and a duo that could be written (reading it makes the
    /// install file, which a phone holding someone else's old credential and no duo should not get
    /// from a drink).
    private func hasSomethingUnsent() -> Bool {
        guard hasCredential, host.availability.allowsWrites, !exitQueued, !logIsNotThePersons, let latest = host.latest, latest.goalML > 0 else { return false }
        let writable = host.duos.filter { !$0.hasEnded && $0.pendingOp == nil && $0.syncedOnce }
        guard !writable.isEmpty else { return false }
        let coverage = coverageStart(latest)
        let age = installAge()
        let refused = cache.loadRejectedDays()
        let today = clock.today, now = clock.now, calendar = clock.calendar
        return writable.contains { duo in
            DuoSyncPlan.write(for: duo, summary: latest, coverageStart: coverage, rejectedDays: refused[duo.wireID] ?? DuoRejectedDays(),
                              holding: held(for: duo.id), installAge: age, myToday: today, now: now, calendar: calendar).write != nil
        }
    }

    /// The writes themselves, one pass at a time. A request that arrives while a pass runs goes
    /// back through the coalescer when it is over, so the thirty seconds still hold.
    private func publish(background: Bool) async {
        if let running = publishLoop {
            publishStale = true
            if !background { publishOnlyBackground = false }
            await running.value
            return
        }
        publishOnlyBackground = background
        let loop = Task { [self] in
            afterPublish(await publishPass())
            publishLoop = nil
            if publishStale {
                publishStale = false
                requestPublish()
            }
        }
        publishLoop = loop
        await loop.value
    }

    private func publishPass() async -> PassOutcome {
        forgetWhatAWipeTook()
        passNumber += 1
        ensureLatest()
        guard hasSomethingUnsent() else { return .clean }
        if let until = heldUntil(writesHeldUntil) { return .held(until: until) }
        let epoch = host.wipeEpoch
        guard await isReady(), host.wipeEpoch == epoch, host.availability.allowsWrites else { return .stopped }
        let ticket = currentTicket()
        guard ticket.deviceID != nil else { return .stopped }

        var outcome = PassOutcome.clean
        duos: for id in host.duos.map(\.id) {
            // One write, and at most one more in the same slot when a conflict was re-based and
            // the re-diff still holds something (§10.3). A replay whose `current` is what is
            // wanted re-diffs to nothing, so there is no third request (X7).
            for attempt in 0..<2 {
                guard isCurrent(ticket), host.availability.allowsWrites, !exitQueued, let latest = host.latest else { return .stopped }
                if publishOnlyBackground, backgroundStop { return .stopped }
                guard let duo = host.duo(id) else { continue duos }
                let planned = DuoSyncPlan.write(for: duo, summary: latest, coverageStart: coverageStart(latest),
                                                rejectedDays: cache.loadRejectedDays()[duo.wireID] ?? DuoRejectedDays(), holding: held(for: id),
                                                installAge: installAge(), myToday: clock.today, now: clock.now, calendar: clock.calendar)
                saveRejectedDays(planned.rejectedDays, for: duo.wireID)
                guard let write = planned.write else { continue duos }
                countSpacingFromNow()
                switch await put(write, to: id, ticket: ticket) {
                case .gone:
                    return .stopped
                case .skipped:
                    continue duos
                case .written(let more, let retry, let refusedRows):
                    hold(refusedRows, for: id)
                    await deliver(more, ticket: ticket)
                    guard retry, attempt == 0 else { continue duos }
                case .failed(let verdict, let serverSaid):
                    switch verdict {
                    case .ended:
                        endLocally(id)
                    case .retry(let after):
                        outcome = outcome.merged(with: after, serverSaid: serverSaid)
                        if serverSaid { break duos }
                    case .cancelled:
                        return .cancelled
                    case .reidentify, .disconnected, .banned, .upgradeRequired, .termsRequired:
                        return .stopped
                    case .fail:
                        break
                    }
                    continue duos
                }
            }
        }
        await deliver([], ticket: ticket)
        return outcome
    }

    /// One `PUT /duos/{id}/statuses` and what its answer means: the feed after the write through
    /// the shared step, then the per-row verdicts re-based on the duo as that left it.
    private func put(_ write: DuoSyncPlan.Write, to id: UUID, ticket: Ticket) async -> PutResult {
        guard let duo = host.duo(id) else { return .skipped }
        do {
            let answer = try await dependencies.transport.pushDayStatuses(duoID: duo.wireID, write.request)
            guard isCurrent(ticket) else { return .gone }
            dependencies.noteSuccess()
            host.diagnostics.recordWrite(duoID: id, at: clock.now)
            let fed = await apply(answer.changes, to: id, since: write.request.since, ticket: ticket, recordsFetch: false)
            guard isCurrent(ticket) else { return .gone }
            guard let current = host.duo(id) else { return .skipped }
            // A feed that could not be applied (the duo was reseated while the write was out, or
            // a newer answer got there first) takes its verdicts with it: a conflict's `current`
            // or an `unchanged` would re-base on rows this phone no longer holds as they were.
            // What the row rules refused is still true of the rows that were sent.
            let verdicts = fed.applied ? answer : DuoWireChangesWithResult(
                changes: answer.changes, accepted: [], unchanged: [],
                rejected: answer.rejected.filter { $0.reason != .verConflict && $0.reason != .downgradeRefused })
            let (rebased, outcome) = DuoRebase.apply(verdicts, sent: write.rows, to: current,
                                                     rejectedDays: cache.loadRejectedDays()[current.wireID] ?? DuoRejectedDays())
            if fed.applied {
                host.update(id) {
                    $0.statuses = rebased.statuses
                    $0.vers = rebased.vers
                }
            }
            saveRejectedDays(outcome.rejectedDays, for: current.wireID)
            // The server's downgrade backstop also refuses a device that has never written this
            // duo, which stops being true the moment any of its rows is accepted (judged on the
            // pre-read, so not yet for the rest of this request): after an accepted row, what was
            // held back, and what this answer refused, go again with the next write, and are held
            // only when a write refuses them with nothing accepted beside them. An `unchanged` row
            // releases what earlier answers held back, but not this answer's refusals: it is most
            // often this phone's own write whose answer was lost, which a retry finds already
            // there, and releasing only on an accepted row kept those rows back for the whole
            // hold. When another device of the member wrote it instead, the next write is refused
            // again and held again, one request more.
            let accepted = fed.applied && !verdicts.accepted.isEmpty
            if accepted || (fed.applied && !verdicts.unchanged.isEmpty) { heldRows[id] = nil }
            return .written(announcements: fed.announcements, retry: fed.applied && outcome.needsRetry, held: accepted ? [] : outcome.heldRows)
        } catch {
            guard isCurrent(ticket) else { return .gone }
            // The whole request refused for its `my_today` (a phone whose clock is days out): the
            // row that request sent for its own `my_today` is poisoned, so it is not sent on every
            // flush until it changes (§10.2). Judged by what was sent, not by the clock when the
            // answer came, which may already be in the next day. The other days go again with the
            // next write and meet the same answer.
            if case .dayOutOfRange(let context)? = error as? DuoTransportError, context.details?.field == "my_today",
               let sent = write.rows.first(where: { $0.day == write.request.myToday }) {
                var refused = cache.loadRejectedDays()[duo.wireID] ?? DuoRejectedDays()
                refused.record(sent)
                saveRejectedDays(refused, for: duo.wireID)
            }
            return .failed(dependencies.noteFailure(error, duoID: id), serverSaid: Self.serverAskedToWait(error))
        }
    }

    private func afterPublish(_ outcome: PassOutcome) {
        switch outcome {
        case .clean:
            publishRetries = 0
            publishRetriesExhausted = false
        case .cancelled, .stopped:
            break
        case .held(let until):
            schedulePublishWake(after: until.timeIntervalSince(clock.now), replacing: false)
        case .retry(let after, let serverSaid):
            if serverSaid { writesHeldUntil = clock.now.addingTimeInterval(after) }
            guard !publishRetriesExhausted else { return }
            guard publishRetries < DuoRetry.maximumAttempts else {
                // The diff is recomputed from the log, so nothing is lost by waiting: the next
                // foreground sends whatever is still missing then.
                publishRetries = 0
                publishRetriesExhausted = true
                return
            }
            publishRetries += 1
            schedulePublishWake(after: after, replacing: true)
        }
    }

    private func schedulePublishWake(after delay: TimeInterval, replacing: Bool) {
        guard replacing || publishWake == nil else { return }
        cancelSpawned(publishWake)
        let epoch = host.wipeEpoch
        var me = 0
        me = spawn { [self] in
            do { try await dependencies.sleep(max(0, delay)) } catch { return }
            guard !Task.isCancelled, host.wipeEpoch == epoch else { return }
            if publishWake == me { publishWake = nil }
            await flush(background: false)
        }
        publishWake = me
    }

    private func saveRejectedDays(_ days: DuoRejectedDays, for wireID: String) {
        var all = cache.loadRejectedDays()
        let before = all[wireID]
        all[wireID] = days.isEmpty ? nil : days
        if all[wireID] != before { cache.saveRejectedDays(all) }
    }

    private func hold(_ rows: [DuoDayStatus], for id: UUID) {
        guard !rows.isEmpty, let duo = host.duo(id) else { return }
        let until = clock.now.addingTimeInterval(Self.refusedRowHold)
        var current = heldRows[id] ?? []
        current.removeAll { held in rows.contains { $0.day == held.row.day } }
        current += rows.map { HeldRow(row: $0, until: until, against: duo.ver(of: duo.myRole, on: $0.day)) }
        heldRows[id] = current
    }

    /// The rows held back for a duo now. A hold whose end is further off than a hold lasts is a
    /// clock that moved back: it is over. So is a hold whose day was written since (its `ver`
    /// moved): the refusal was about the row the server held then. Another device of the member
    /// lowering a day this phone was refused a downgrade of made this phone's row a raise, which
    /// sat held for the rest of the six hours.
    private func held(for id: UUID) -> [DuoDayStatus] {
        let now = clock.now
        guard let duo = host.duo(id) else { return [] }
        return (heldRows[id] ?? []).filter {
            $0.until > now && $0.until.timeIntervalSince(now) <= Self.refusedRowHold && $0.against == duo.ver(of: duo.myRole, on: $0.row.day)
        }.map(\.row)
    }

    /// The end of a wait the server asked for, while it is running. One longer than the longest
    /// wait believed is a clock that moved back, and is over.
    private func heldUntil(_ until: Date?) -> Date? {
        guard let until else { return nil }
        let left = until.timeIntervalSince(clock.now)
        guard left > 0, left <= DuoRetry.maximumDelay else { return nil }
        return until
    }

    /// A 429 or a 503 (or the service answering a 5xx it did not explain): the server asked for
    /// the wait, as against no connection, which says nothing about when the next try may go.
    private static func serverAskedToWait(_ error: Error) -> Bool {
        guard let failure = error as? DuoTransportError else { return false }
        switch failure {
        case .rateLimited, .maintenance: return true
        case .unreadable(let status, _): return status == 429 || status >= 500
        default: return false
        }
    }

    // MARK: - Nudges

    private static let nudgeMarker = "/nudges#"

    /// The in-flight journal's name for a waiting nudge: the method, the path with its duo id, and
    /// the nudge's id, which is the request's key (§6.6). The path alone would let a second nudge
    /// for the same duo replace the first's record (the journal keeps one entry per operation).
    private static func nudgeOperation(duoWire: String, nudgeID: String) -> String {
        "POST /duos/\(duoWire)\(nudgeMarker)\(nudgeID)"
    }

    /// The nudges sent and not yet confirmed, read from the journal: what a relaunch resumes. Each
    /// is noted as a copy this engine knows is unconfirmed, so its card loses it if the journal does.
    private func unconfirmedNudges() -> [UnconfirmedNudge] {
        let waiting: [UnconfirmedNudge] = cache.loadInflight(now: clock.now).entries.compactMap { entry in
            guard entry.operation.hasPrefix("POST /duos/"), let marker = entry.operation.range(of: Self.nudgeMarker) else { return nil }
            let wire = String(entry.operation[entry.operation.index(entry.operation.startIndex, offsetBy: 11)..<marker.lowerBound])
            guard let duoID = UUID(uuidString: wire), let request = try? DuoWireCoding.decode(DuoWireSendNudgeRequest.self, from: entry.body),
                  request.id == String(entry.operation[marker.upperBound...]) else { return nil }
            return UnconfirmedNudge(operation: entry.operation, duoID: duoID, request: request, createdAt: entry.createdAt)
        }
        for copy in waiting { nudgeCopies[copy.request.id.lowercased()] = NudgeCopy(duoID: copy.duoID, createdAt: copy.createdAt) }
        return waiting
    }

    /// Takes off its card every copy this engine knows was never confirmed whose journal entry is
    /// gone. The journal keeps a waiting nudge for 23 hours, and after that nothing sends it again,
    /// so the copy is a nudge that was never sent.
    private func dropAbandonedNudgeCopies() {
        let waiting = Set(unconfirmedNudges().map { $0.request.id.lowercased() })
        for (id, copy) in nudgeCopies where !waiting.contains(id) {
            nudgeCopies[id] = nil
            host.update(copy.duoID) { duo in
                duo.nudges = duo.allNudges.filter { $0.id.lowercased() != id || $0.fromRole != duo.myRole || $0.createdAt != copy.createdAt }
            }
        }
    }

    /// A feed that holds a nudge this phone is still waiting on is the server saying it has it
    /// (a request whose answer was lost, say): the request is forgotten and its retries end, and
    /// the row the feed brought stays on the card when the journal would have dropped it.
    private func confirmNudges(in changes: DuoWireChanges, for id: UUID) {
        let held = Set(changes.nudges.map { $0.id.lowercased() })
        guard !held.isEmpty else { return }
        for copy in unconfirmedNudges() where copy.duoID == id && held.contains(copy.request.id.lowercased()) {
            forgetNudge(copy.operation)
            cancelSpawned(nudgeRetries[copy.operation])
            nudgeRetries[copy.operation] = nil
            nudgeCopies[copy.request.id.lowercased()] = nil
        }
    }

    private func forgetNudge(_ operation: String) {
        var journal = cache.loadInflight(now: clock.now)
        guard journal.entries.contains(where: { $0.operation == operation }) else { return }
        journal.clear(operation: operation)
        cache.saveInflight(journal)
    }

    /// One POST of a waiting nudge. A nudge whose duo ended or has a leave or block waiting is
    /// let go, copy and record; one that cannot go yet (writes off, an exit queued for any duo)
    /// is kept for the next foreground.
    private func attemptNudge(_ operation: String, ticket: Ticket) async -> NudgeAttempt {
        guard isCurrent(ticket) else { return .finished }
        guard let pending = unconfirmedNudges().first(where: { $0.operation == operation }) else {
            // Confirmed, or dropped by the journal after 23 hours. Its copy goes only in the second
            // case: this used to return with the copy left on the card as if it had been sent.
            dropAbandonedNudgeCopies()
            return .finished
        }
        guard let duo = host.duo(pending.duoID), !duo.hasEnded, duo.pendingOp == nil else {
            nudgeCopies[pending.request.id.lowercased()] = nil
            forgetNudge(operation)
            host.update(pending.duoID) { $0.nudges = $0.allNudges.filter { $0.id != pending.request.id } }
            return .finished
        }
        guard host.availability.allowsWrites, !exitQueued else { return .kept }
        guard nudgesInFlight.insert(operation).inserted else { return .kept }
        defer { nudgesInFlight.remove(operation) }
        do {
            let result = try await dependencies.transport.sendNudge(duoID: duo.wireID, pending.request)
            guard isCurrent(ticket) else { return .finished }
            dependencies.noteSuccess()
            forgetNudge(operation)
            nudgeCopies[pending.request.id.lowercased()] = nil
            // The server's row, with the server's time, in place of the optimistic copy (§8.2).
            if let confirmed = DuoMapping.nudge(result.response.nudge) { replaceNudge(pending.request.id, with: confirmed, in: pending.duoID) }
            return .finished
        } catch {
            guard isCurrent(ticket) else { return .finished }
            let verdict = dependencies.noteFailure(error, duoID: pending.duoID)
            switch Self.nudgeFailure(error) {
            case .retry:
                return .retry
            case .keep:
                return .kept
            case .drop:
                forgetNudge(operation)
                nudgeCopies[pending.request.id.lowercased()] = nil
                host.update(pending.duoID) { $0.nudges = $0.allNudges.filter { $0.id != pending.request.id } }
                if verdict == .ended { endLocally(pending.duoID) }
                if let failure = error as? DuoTransportError {
                    switch failure {
                    case .partnerAlreadyMet, .nudgeLimit:
                        host.notice = DuoUserMessage.text(for: failure, context: .nudge(partner: duo.displayName(of: duo.myRole.other)))
                    default:
                        // `duo_pending` is "nobody to nudge", which the button already says; the
                        // rest are noted in Diagnostics by `noteFailure`.
                        break
                    }
                }
                return .finished
            }
        }
    }

    /// The same id again after each of 30, 60 and 120 seconds, while the network or the service
    /// is the problem, then at the next foreground (§6.6, AND F16). The ticket is the one the first
    /// attempt was made under, taken once: a wipe while it waits ends it, whatever duo comes back.
    private func scheduleNudgeRetries(_ operation: String, ticket: Ticket) {
        cancelSpawned(nudgeRetries[operation])
        var me = 0
        me = spawn { [self] in
            defer { if nudgeRetries[operation] == me { nudgeRetries[operation] = nil } }
            for delay in DuoProtocolConstants.nudgeRetryDelays {
                do { try await dependencies.sleep(delay) } catch { return }
                guard !Task.isCancelled, isCurrent(ticket) else { return }
                guard await attemptNudge(operation, ticket: ticket) == .retry else { return }
            }
        }
        nudgeRetries[operation] = me
    }

    /// The next foreground: every nudge still waiting, kept across a relaunch by the journal, is
    /// sent again with its id, unless it is being sent or is between its retries already.
    private func resumeUnconfirmedNudges(ticket: Ticket) {
        dropAbandonedNudgeCopies()
        for copy in unconfirmedNudges() where !nudgesInFlight.contains(copy.operation) && nudgeRetries[copy.operation] == nil {
            let operation = copy.operation
            spawn { [self] in
                if await attemptNudge(operation, ticket: ticket) == .retry { scheduleNudgeRetries(operation, ticket: ticket) }
            }
        }
    }

    private static func nudgeFailure(_ error: Error) -> NudgeFailure {
        if error is CancellationError { return .keep }
        guard let failure = error as? DuoTransportError else { return .drop }
        switch failure {
        case .offline, .maintenance:
            // `maintenance` is also what a captive portal's 401 or 403 and a redirect read as:
            // not the server saying no (D63).
            return .retry
        case .unreadable(let status, _):
            if status >= 500 { return .retry }
            if status == 0 || (200..<300).contains(status) { return .keep }
            return .drop
        default:
            // Every code the server judged, `rate_limited` and `nudge_limit` (429s) among them.
            return .drop
        }
    }

    private func replaceNudge(_ localID: String, with confirmed: DuoNudge, in duoID: UUID) {
        host.update(duoID) { duo in
            var nudges = duo.allNudges.filter { $0.id != confirmed.id || $0.id == localID }
            if let index = nudges.firstIndex(where: { $0.id == localID }) { nudges[index] = confirmed } else { nudges.append(confirmed) }
            duo.nudges = nudges
        }
    }

    // MARK: - Plumbing

    private func isReady() async -> Bool {
        guard let identity = dependencies.identity else { return false }
        return await identity.prepare() == .ready
    }

    private func currentTicket() -> Ticket {
        let credential = dependencies.identity?.credential
        return Ticket(epoch: host.wipeEpoch, deviceID: credential?.deviceID, memberID: credential?.memberID)
    }

    private func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.deviceID != nil && currentTicket() == ticket
    }

    private func startMonitoringOnce() {
        guard !monitoringStarted, hasCredential, let ops = dependencies.ops else { return }
        monitoringStarted = true
        ops.startMonitoring()
    }

    /// What this engine holds in memory about the identity a wipe just forgot goes with it: the
    /// refused announcements (they name a partner), the held rows, the waits the server asked
    /// for, every retry and owed write still waiting, the retry budget, the coalescer and the
    /// skin last queued (the queue went too). The waiting nudges went with the journal. A wipe
    /// does not call the engine, so this runs at the next thing that does; anything that woke
    /// before then checks the epoch it was scheduled under and does nothing.
    private func forgetWhatAWipeTook() {
        let epoch = host.wipeEpoch
        guard epochSeen != epoch else { return }
        if epochSeen != nil {
            refusedAnnouncements = [:]
            heldRows = [:]
            lastQueuedSkin = nil
            readsHeldUntil = nil
            writesHeldUntil = nil
            cancelSpawned(syncWake)
            syncWake = nil
            cancelSpawned(publishWake)
            publishWake = nil
            cancelOwedWrite()
            // An owed write that woke into the wipe did nothing, and left the coalescer owing it.
            // When the last write went is kept: the thirty seconds are this phone's whoever it is
            // now, and a fresh coalescer let a write through in the same second as the two
            // before the wipe.
            if let last = coalescer.lastWriteAt { coalescer.waitEnded(now: last) } else { coalescer = DuoWriteCoalescer() }
            for id in nudgeRetries.values { cancelSpawned(id) }
            nudgeRetries = [:]
            nudgeCopies = [:]
            syncRetries = 0
            syncRetriesExhausted = false
            publishRetries = 0
            publishRetriesExhausted = false
        }
        epochSeen = epoch
    }

    @discardableResult
    private func spawn(_ work: @escaping @MainActor () async -> Void) -> Int {
        spawnCount += 1
        let id = spawnCount
        spawned[id] = Task { [self] in
            await work()
            spawned[id] = nil
        }
        return id
    }

    private func cancelSpawned(_ id: Int?) {
        guard let id else { return }
        spawned[id]?.cancel()
    }

    /// For tests: returns once nothing this engine started is running or waiting to run (every
    /// retry, owed write and resent nudge has finished, with the sleeper returning at once).
    func waitUntilIdle() async {
        for _ in 0..<1_000 {
            let tasks = Array(spawned.values) + [syncLoop, publishLoop, backgroundWork].compactMap { $0 }
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }
}

/// A log reader that can say the store it reads is not the person's own log. The sync engine
/// publishes nothing while its reader says so (C24).
@MainActor
protocol DuoLogSourceVetting: AnyObject {
    var readsThePersonsLog: Bool { get }
}
#endif
