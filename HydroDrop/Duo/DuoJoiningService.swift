#if DUO_V2
import Foundation

/// Every flow that makes or changes who this phone is in a duo (plan P2 stage D; final design
/// §3.1, §3.4, §3.5, §4.1 to §4.4, §6.0, §6.2, §6.3, §10.1, §11.8): starting a duo, looking at a
/// code, joining, a new code for a pending duo, a reconnect code for a partner who has gone
/// quiet, a code to link a second device, taking an identity over by reconnecting, a new name,
/// and the terms. It draws nothing: the sheets of stages G to M call it and show what it leaves
/// in `sheetError`, `needsTerms` and the duos.
///
/// Consent (§3.1). Create and invite, Join and Reconnect are each the first request of a consent
/// the person has just given by tapping a button on a sheet that showed the explainer. Nothing is
/// sent, attested, asked of DeviceCheck or written to the Keychain before one of those taps; the
/// one earlier request is the peek of a code the person opened, which carries this phone's bearer
/// only if it already has an identity, and never makes one. Each of the three is refused, silently
/// and with nothing sent, unless writes are allowed (a reconnect is allowed from a disconnected
/// phone too, since that is the phone it is for), the birth-year screen has said the person is old
/// enough and no refusal is kept anywhere, and the rules have been accepted on their own screen.
/// Rules not yet accepted ask the sheet that is up to show them (`needsTerms`). The contract's
/// `terms_version` on `POST /devices` is the version the person accepted, so a tap on Create or
/// Join is never taken for an acceptance of rules it did not show, and this service never records
/// an acceptance itself.
///
/// The in-flight journal (§6.0). Every idempotent request here is written down, key and exact
/// bytes, before it is sent, and replayed byte for byte on the next tap that builds the same
/// request, so a lost answer is answered from the server's record instead of making a second duo
/// or a second join. The record is dropped only on an answer that settles the request: a 2xx that
/// was read, or a refusal a retry would only repeat. After a cancelled task, no connection, an
/// answer that could not be read (at any status), a 5xx, a WAF page or a rate limit it is kept,
/// because the request may well have landed. Operations are named by the request's method and
/// path with every id in it (`POST /duos/<id>/invites`): the server judges a replay by method,
/// path and body together, and the body of an invite is the same for every duo. No invite code is
/// ever part of a name (amendments). The redeem is the one request whose bytes change on every
/// attempt (its body carries a fresh DeviceCheck token), so it is matched on the request without
/// the token and replays the recorded bytes, old token and all (D62: the token sits on the phone
/// only inside a request still waiting for its answer, 23 hours at most, and goes with the record).
///
/// A lost join (D70). The journal holds one redeem at a time and a changed tap (a new name, a new
/// day, a link opened again after a relaunch, which loses `k`) builds new bytes, so a lost 201 is
/// not always replayed. A seat that a lost answer took shows itself instead as `invite_unknown` or
/// `invite_taken` on the next attempt, so every such answer (and any 404) to a phone that already
/// holds an identity asks `GET /me` and keeps every live duo it lists that this phone lacks. No
/// memory of an earlier attempt is needed, so none can be lost.
///
/// A wipe. Delete my Duo data or Start fresh can run while a request is out. Each flow reads
/// `wipeEpoch` before it sends and compares after every wait; if it moved, the answer is dropped
/// whole and nothing is written back (not the duo, not the credential, not the journal, not an
/// error, not `isWorking`), since a late answer would bring back a duo and a partner's name the
/// person had just deleted.
///
/// Nothing here logs. A body holds a name, a code or a token, and Diagnostics keeps only what
/// `noteFailure` records (a code, a status and a request id). The link secret `k` never leaves the
/// phone: it goes to the Keychain once the duo it belongs to is known, and is never put in a request.
@MainActor
final class DuoJoiningService: DuoJoining {
    private let dependencies: DuoDependencies

    /// The flow that sends, if one is running, and the wipe it started under. A second tap while the
    /// first is still out is refused rather than run beside it: two Create or Join taps at once would
    /// each find no credential and mint two identities, the second one left orphaned on the server,
    /// and an Accept during a Create's request can make that Create meet `428` again. A flow that a
    /// wipe overtook no longer counts: its answer will be dropped, and leaving it in the way refused
    /// the person's first tap after Delete my Duo data or Start fresh without a word.
    private var runningFlow: (id: Int, epoch: Int)?
    private var flowsStarted = 0

    /// Keeps the app running for a little while if it is sent to the background mid-mint, so the one
    /// answer that carries the new identity's secret is more likely to be read and kept. The identity
    /// holds its rotate the same way (`DuoIdentity.rotateAndSave`) and this is its helper. A test
    /// replaces it.
    var holdInBackground: DuoIdentity.BackgroundHold = DuoIdentity.expiringActivity

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    private var host: DuoHost { dependencies.host }

    // MARK: - Names

    /// The journal's operation names (amendments of 2026-10-07): the method and the path, every id
    /// included, so one duo's key is never replayed on another duo's path.
    private static let createOperation = "POST /duos"
    private static let redeemOperation = "POST /invites/redeem"
    private static let reconnectOperation = "POST /invites/reconnect"
    private static func inviteOperation(duoID: String) -> String { "POST /duos/\(duoID)/invites" }

    /// A `link_device` code's path names no duo the server reads (§3.5: "the nil UUID will do").
    private static let linkDeviceDuoID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).uuidString.lowercased()

    /// `limits.nudges_per_day` at the low tier (§6.2: "3|1", set by the tier). Used only for the
    /// partial member record a mint leaves until the next `GET /me` fills it in.
    private static let lowTierNudgesPerDay = 1

    // MARK: - The running flow

    private func beginFlow() -> Int? {
        if let running = runningFlow, running.epoch == host.wipeEpoch { return nil }
        flowsStarted += 1
        runningFlow = (flowsStarted, host.wipeEpoch)
        return flowsStarted
    }

    private func endFlow(_ id: Int) {
        if runningFlow?.id == id { runningFlow = nil }
    }

    /// `isWorking` is handed back only by a flow the wipe did not overtake: the wipe has already put
    /// it down, and a newer flow may have raised it again since.
    private func stopWorking(_ epoch: Int) {
        if host.wipeEpoch == epoch { host.isWorking = false }
    }

    // MARK: - Create

    func createDuo(named: String?, skin: String) async -> DuoState? {
        guard let flow = beginFlow() else { return nil }
        defer { endFlow(flow) }
        host.sheetError = nil
        guard mayStart(.create) else { return nil }
        let epoch = host.wipeEpoch
        host.isWorking = true
        defer { stopWorking(epoch) }
        guard await noExitIsStillQueued(for: .create, epoch: epoch) else { return nil }
        guard await ensureIdentity(for: .create, epoch: epoch) != nil else { return nil }

        let now = dependencies.clock.now
        let cleaned = dependencies.cleanedNameOrNil(named)
        // A link or a QR code carries the secret, so every duo started here is e2ee capable (§4.1).
        let request = DuoWireCreateDuoRequest(displayName: cleaned, skin: skin, myToday: dependencies.clock.today, e2eeCapable: true,
                                              statuses: dependencies.firstRows(role: .owner, now: now))
        let response: DuoWireCreateDuoResponse
        do {
            response = try await journaled(Self.createOperation, request, epoch: epoch) { key in
                try await self.dependencies.transport.createDuo(request, key: key)
            }
        } catch {
            guard host.wipeEpoch == epoch else { return nil }
            // A create whose answer was lost made a pending duo, and a second tap with other bytes
            // (a new name, a day that moved on) meets it here: it is adopted rather than left where
            // the person cannot see it (AND F11).
            if case .pendingExists(let context) = error as? DuoTransportError {
                return await adoptPendingDuo(context, refusal: error, typedName: cleaned, epoch: epoch)
            }
            fail(error, context: .invite)
            return nil
        }
        guard host.wipeEpoch == epoch else { return nil }

        guard var duo = DuoMapping.duo(from: response.duo, previous: nil, now: now) else {
            host.sheetError = DuoUserMessage.generic
            return nil
        }
        // The create is the duo's first accepted batch (§6.3, §6.8), so nothing is left to read
        // first: the rows the server took are mine as sent, every accepted one inserted at ver 1,
        // and the cursor is the duo's seq.
        let accepted = Set(response.accepted)
        let unchanged = Set(response.unchanged)
        var vers: [String: Int64] = [:]
        for row in request.statuses where accepted.contains(row.day) || unchanged.contains(row.day) {
            let status = DuoDayStatus(role: duo.myRole, day: row.day, goalMet: row.goalMet, progressBucket: row.progressBucket, updatedAt: now)
            duo.upsert(status)
            if accepted.contains(row.day) { vers[status.recordName] = 1 }
        }
        duo.vers = vers
        duo.invite = DuoMapping.invite(response.invite)
        duo.openInviteExpiresAt = response.invite.expiresAt
        duo.e2eeCapable = true
        duo.cursor = response.duo.seq
        duo.syncedOnce = true
        recordRejected(response.rejected, sent: request.statuses, role: duo.myRole, duoID: duo.id, now: now)
        // The secret the link carries, made on this phone and kept in its Keychain only (§4.1). One
        // already kept for this duo is the one any link shared so far carries, so it stays.
        if dependencies.secrets.linkSecret(forDuo: duo.id) == nil {
            try? dependencies.secrets.saveLinkSecret(DuoLinkSecret.make(random: dependencies.random), forDuo: duo.id)
        }
        host.upsert(duo)
        host.myDisplayName = cleaned ?? ""
        identityNowHoldsADuo()
        dependencies.push?.reevaluate(.duoStarted)
        dependencies.ops?.startMonitoring()
        dependencies.noteSuccess()
        return host.duo(duo.id) ?? duo
    }

    /// `409 pending_exists`: this person already has a pending duo, which only a lost answer to an
    /// earlier create can have made from this phone. It is read whole and kept. It has no code, since
    /// the server never gives one back (§4.1, SEC F9), so the card offers Make a new code.
    private func adoptPendingDuo(_ context: DuoErrorContext, refusal: Error, typedName: String?, epoch: Int) async -> DuoState? {
        guard let raw = context.details?.duoId, let id = UUID(uuidString: raw) else {
            fail(refusal, context: .invite)
            return nil
        }
        let changes: DuoWireChanges
        do {
            changes = try await dependencies.transport.fetchChanges(duoID: id.uuidString.lowercased(), since: 0)
        } catch {
            guard host.wipeEpoch == epoch else { return nil }
            fail(error, context: .invite, duoID: id)
            return nil
        }
        guard host.wipeEpoch == epoch else { return nil }
        let now = dependencies.clock.now
        guard var duo = DuoFeedReducer.apply(changes, to: host.duo(id), myToday: dependencies.clock.today, now: now)?.duo else {
            host.sheetError = DuoUserMessage.generic
            return nil
        }
        // Every create this app sends says e2ee capable (§4.1), the lost one included.
        duo.e2eeCapable = true
        host.upsert(duo)
        identityNowHoldsADuo()
        dependencies.push?.reevaluate(.duoStarted)
        dependencies.ops?.startMonitoring()
        dependencies.noteSuccess()
        // The lost create carried the name typed then; the duo is shown with that one. The name typed
        // for this tap is the person's latest word, so it is sent after it (§10.1).
        await keepTheTypedName(typedName, serverHas: duo.ownerDisplayName, epoch: epoch)
        return host.duo(duo.id) ?? duo
    }

    // MARK: - Looking at a code

    func peek(code: String) async -> DuoPeek? {
        host.sheetError = nil
        guard let canonical = DuoInviteCode.normalize(code) else {
            host.sheetError = DuoCopy.notACode
            return nil
        }
        let epoch = host.wipeEpoch
        // A phone with an identity peeks with its bearer (D34: the pair row is applied, so a person
        // someone blocked sees nothing of them), which makes this a bearer request like any other:
        // it waits for the launch's answer and is not sent while the restore question is up, when
        // the bearer may be a previous owner's. A disconnected phone's credential is one another
        // phone took over, which earns nothing but `device_revoked`, and the transport sends the
        // bearer whenever a credential is stored, so it is not asked at all: the Duo screen already
        // says the phone was disconnected. The throwaway a Reconnect minted is a fresh member with
        // no pair rows, as good as anonymous, and goes. A phone with no identity peeks anonymously
        // and nothing is asked of the identity.
        if let credential = dependencies.identity.credential {
            if host.availability == .disconnected, credential.deviceID != dependencies.cache.throwawayDeviceID { return nil }
            let launch = await dependencies.identity.prepare()
            guard host.wipeEpoch == epoch else { return nil }
            if launch != .ready, dependencies.identity.credential != nil {
                stop(for: launch)
                return nil
            }
        }
        var retriedAnonymously = false
        while true {
            do {
                let wire = try await dependencies.transport.peekInvite(code: canonical)
                guard host.wipeEpoch == epoch else { return nil }
                dependencies.noteSuccess()
                return DuoMapping.peek(wire)
            } catch {
                guard host.wipeEpoch == epoch else { return nil }
                let verdict = dependencies.noteFailure(error)
                // A stale credential (the identity was deleted from another copy): `noteFailure` has
                // discarded it, so the one retry goes anonymously, as a phone with no identity
                // peeks. It is the only retry this service makes of its own.
                if verdict == .reidentify, !retriedAnonymously, dependencies.identity.credential == nil {
                    retriedAnonymously = true
                    continue
                }
                if verdict != .cancelled { host.sheetError = DuoUserMessage.text(for: error, context: .invite) }
                return nil
            }
        }
    }

    func receive(_ invite: DuoParsedInvite, now: Date) {
        // Kept (and saved by the store) before anything else, so a kill during onboarding loses
        // nothing (§4.1); the store drops it after 48 hours, and a join drops it. `k` stays in memory.
        host.pendingInvite = DuoPendingInvite(code: invite.code, k: invite.k, receivedAt: now)
    }

    func discardPendingInvite() {
        host.pendingInvite = nil
    }

    // MARK: - Join

    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState? {
        guard let flow = beginFlow() else { return nil }
        defer { endFlow(flow) }
        host.sheetError = nil
        guard mayStart(.join) else { return nil }
        guard let code = DuoInviteCode.normalize(invite.code) else {
            host.sheetError = DuoCopy.notACode
            return nil
        }
        let epoch = host.wipeEpoch
        host.isWorking = true
        defer { stopWorking(epoch) }
        guard await noExitIsStillQueued(for: .join, epoch: epoch) else { return nil }
        guard let identity = await ensureIdentity(for: .join, epoch: epoch) else { return nil }

        let now = dependencies.clock.now
        let cleaned = dependencies.cleanedNameOrNil(named)
        // A typed code has no `k`, and a duo joined without one says so (§4.1), so a later version
        // knows which duos need pairing again before anything is encrypted.
        let request = DuoWireRedeemRequest(code: code, displayName: cleaned, skin: skin, myToday: dependencies.clock.today,
                                           e2eeCapable: invite.k != nil, statuses: dependencies.firstRows(role: .partner, now: now))
        do {
            guard let outcome = try await redeem(request, epoch: epoch), host.wipeEpoch == epoch else { return nil }
            let (result, sent) = outcome
            let previous = UUID(uuidString: result.changes.duo.id).flatMap { host.duo($0) }
            // The 201 is the whole duo as this person now sees it (§4.3 step 9): both sides' rows,
            // each with its ver, and the nudges, so the card is live at once and nothing is left to
            // read before this phone writes.
            guard var joined = DuoFeedReducer.apply(result.changes, to: previous, myToday: dependencies.clock.today, now: now)?.duo else {
                host.sheetError = DuoUserMessage.generic
                return nil
            }
            recordRejected(result.rejected, sent: sent.statuses, role: joined.myRole, duoID: joined.id, now: now)
            joined.e2eeCapable = sent.e2eeCapable
            if sent.e2eeCapable, let k = invite.k { try? dependencies.secrets.saveLinkSecret(k, forDuo: joined.id) }
            host.upsert(joined)
            finishJoin(code: code, name: sent.displayName)
            return host.duo(joined.id) ?? joined
        } catch {
            guard host.wipeEpoch == epoch else { return nil }
            // The seat a lost answer took shows itself as the code gone or taken (D70). An identity
            // made in this very tap has never redeemed anything, so it has no seat to find.
            if Self.mayMeanASeatIsTaken(error) {
                guard identity == .existing else {
                    if Self.settles(error) { settleJournal(Self.redeemOperation, epoch: epoch) }
                    fail(error, context: .invite)
                    return nil
                }
                switch await findLostSeats(typedName: cleaned, epoch: epoch) {
                case .found(let duo):
                    settleJournal(Self.redeemOperation, epoch: epoch)
                    finishJoin(code: code, name: cleaned)
                    return host.duo(duo.id) ?? duo
                case .none:
                    if Self.settles(error) { settleJournal(Self.redeemOperation, epoch: epoch) }
                case .unknown:
                    // Not known either way: the record and the pending invite stay, so the next tap
                    // asks again. `findLostSeats` said why (or nothing, for a cancelled task); the
                    // refusal itself goes in Diagnostics, the once it is noted.
                    dependencies.noteFailure(error)
                    return nil
                case .dropped:
                    return nil
                }
            }
            // D34: a refusal from the creator's side alone is `invite_unknown`, and `blocked` is only
            // ever the caller's own bit; the words for each never say who blocked whom.
            fail(error, context: .invite)
            return nil
        }
    }

    /// What every successful join leaves, from a 201 or from the seats a lost one took.
    private func finishJoin(code: String, name: String?) {
        // The pending invite is dropped whatever spelling it was kept in (a pasted link keeps the
        // canonical code, but nothing stops a caller passing what the person typed).
        if let pending = host.pendingInvite, DuoInviteCode.normalize(pending.code) == code { host.pendingInvite = nil }
        host.myDisplayName = name ?? ""
        identityNowHoldsADuo()
        dependencies.push?.reevaluate(.duoStarted)
        dependencies.ops?.startMonitoring()
        dependencies.noteSuccess()
    }

    private enum SeatSearch {
        /// A partner seat a lost join took: the join happened.
        case found(DuoState)
        /// No partner seat this phone lacks: the refusal stands. A pending duo of the person's own
        /// that a lost create made has been kept all the same, with no words of its own.
        case none
        /// `GET /me` did not answer, or a 401 met while reading a seat took the identity away; the
        /// failure has been noted and said.
        case unknown
        /// A wipe happened meanwhile.
        case dropped
    }

    /// After `invite_unknown` or `invite_taken` (or any 404) to a phone with an identity: `GET /me`
    /// says whether a lost answer already seated this person. Every live duo it lists that this
    /// phone lacks is kept, all of them: two lost joins can have seated a free person in two duos,
    /// which the server has already allowed, and leaving either out would hide a duo its partner
    /// sees as live. Only a partner seat is the join, though. The person's own pending duo (a create
    /// whose answer was lost) used to be returned when no seat was found, so a Join of a code that
    /// was really gone closed the sheet as if the friend's invite had worked and dropped the invite;
    /// it is kept now without a word, and the refusal is said.
    ///
    /// No duo kept here is end-to-end capable or given this invite's `k`. `GET /me` cannot say
    /// which code a seat came by, and the one seat found used to be given this invite's secret,
    /// which a seat taken through another invite (a typed code, another link) would then hold
    /// though its partner never had it. Each reads as joined without one, the safe side, which a
    /// later version pairs again before anything is encrypted (§4.1).
    private func findLostSeats(typedName: String?, epoch: Int) async -> SeatSearch {
        let me: DuoWireGetMeResponse
        do {
            me = try await dependencies.transport.me()
        } catch {
            guard host.wipeEpoch == epoch else { return .dropped }
            if dependencies.noteFailure(error) != .cancelled { host.sheetError = DuoUserMessage.text(for: error, context: .invite) }
            return .unknown
        }
        guard host.wipeEpoch == epoch else { return .dropped }
        let now = dependencies.clock.now
        let lost = me.duos.filter { header in
            guard header.state != .ended, let id = UUID(uuidString: header.id) else { return false }
            return host.duo(id) == nil && !dependencies.cache.isCleared(id, now: now)
        }
        var adopted: [DuoState] = []
        for header in lost {
            guard let id = UUID(uuidString: header.id) else { continue }
            var read: DuoState?
            do {
                let changes = try await dependencies.transport.fetchChanges(duoID: id.uuidString.lowercased(), since: 0)
                guard host.wipeEpoch == epoch else { return .dropped }
                read = DuoFeedReducer.apply(changes, to: nil, myToday: dependencies.clock.today, now: now)?.duo
            } catch {
                guard host.wipeEpoch == epoch else { return .dropped }
                // A 401 has just forgotten the identity and ended the duos it held, so a seat kept
                // now would be a live card with no identity behind it, which this used to leave.
                if dependencies.noteFailure(error, duoID: id) == .reidentify {
                    host.sheetError = DuoUserMessage.text(for: error, context: .invite)
                    return .unknown
                }
            }
            // The seat is real even when its rows could not be read just now: the header's duo is
            // kept, with `syncedOnce` false, so nothing is written for it before a whole read (§10.3).
            if let duo = read ?? DuoMapping.duo(from: header, previous: nil, now: now) { adopted.append(duo) }
        }
        guard !adopted.isEmpty else { return .none }
        for var duo in adopted {
            duo.e2eeCapable = false
            host.upsert(duo)
        }
        guard let seat = adopted.first(where: { $0.myRole == .partner }) else {
            // What a create leaves, without its words: the join's refusal is what the sheet says.
            identityNowHoldsADuo()
            dependencies.push?.reevaluate(.duoStarted)
            dependencies.ops?.startMonitoring()
            return .none
        }
        await keepTheTypedName(typedName, serverHas: me.member.displayName ?? "", epoch: epoch)
        guard host.wipeEpoch == epoch else { return .dropped }
        return .found(seat)
    }

    /// A lost answer's duo shows the name the lost request carried, which the server keeps (D6). The
    /// name typed for this tap is the person's latest word, so it is queued as `PATCH /me` when it
    /// differs: through the op queue like any rename, so an offline phone sends it later.
    private func keepTheTypedName(_ typed: String?, serverHas server: String, epoch: Int) async {
        guard host.wipeEpoch == epoch else { return }
        host.myDisplayName = typed ?? ""
        guard (typed ?? "") != server else { return }
        await queueName(typed, epoch: epoch)
    }

    nonisolated private static func mayMeanASeatIsTaken(_ error: Error) -> Bool {
        guard let error = error as? DuoTransportError else { return false }
        switch error {
        case .inviteUnknown, .inviteTaken:
            return true
        case .unreadable(let status, _):
            return status == 404
        default:
            return error.context?.httpStatus == 404
        }
    }

    // MARK: - The redeem and its replay

    private struct RedeemAttempt {
        var key: DuoIdempotencyKey
        var request: DuoWireRedeemRequest
        /// The recorded bytes of an earlier attempt, sent again.
        var isReplay: Bool
    }

    /// Sends the redeem, through the journal. Nil when a wipe happened meanwhile.
    ///
    /// A replay refused for its attestation (`attest_*`) is redeemed once more as a new request.
    /// The server answers a request it recorded from the record, never judging its header (§11.2),
    /// so a replay that is judged at all is one that never landed; it goes again fresh, with a new
    /// key and a fresh DeviceCheck token, rather than being refused once more for the old bytes.
    private func redeem(_ request: DuoWireRedeemRequest, epoch: Int) async throws -> (DuoWireChangesWithResult, DuoWireRedeemRequest)? {
        guard let first = try await redeemAttempt(request, epoch: epoch) else { return nil }
        do {
            return try await send(first, epoch: epoch)
        } catch {
            guard first.isReplay, Self.isAttestRefusal(error), host.wipeEpoch == epoch else { throw error }
        }
        // The refusal settled the request, so `send` has cleared its record and this attempt is new.
        guard let fresh = try await redeemAttempt(request, epoch: epoch) else { return nil }
        return try await send(fresh, epoch: epoch)
    }

    /// The code gone or taken settles the redeem only once `GET /me` has said there is no seat to
    /// find, so it is left to the join (D70).
    private func send(_ attempt: RedeemAttempt, epoch: Int) async throws -> (DuoWireChangesWithResult, DuoWireRedeemRequest) {
        do {
            let result = try await dependencies.transport.redeemInvite(attempt.request, key: attempt.key)
            settleJournal(Self.redeemOperation, epoch: epoch)
            return (result, attempt.request)
        } catch {
            if Self.settles(error), !Self.mayMeanASeatIsTaken(error) { settleJournal(Self.redeemOperation, epoch: epoch) }
            throw error
        }
    }

    /// The key and the request to send, recorded before anything is sent.
    ///
    /// `key(for:body:)` would give every attempt at a redeem a new key, since its token makes the
    /// bytes new each time, and the server's replay of a lost 201 would never happen; the old key
    /// with new bytes would be `422 idempotency_mismatch`. So the request without its token is what
    /// says whether two attempts are the same (`replayable`), and a match replays the recorded bytes,
    /// old token and all, under the recorded key. DeviceCheck is asked for a token only when the
    /// request is a new one.
    private func redeemAttempt(_ request: DuoWireRedeemRequest, epoch: Int) async throws -> RedeemAttempt? {
        var bare = request
        bare.deviceCheckToken = nil
        let identity = try DuoWireCoding.encode(bare)
        let cache = dependencies.cache
        var journal = cache.loadInflight(now: dependencies.clock.now)
        var recordedBody: Data?
        if let recorded = journal.entries.first(where: { $0.operation == Self.redeemOperation && $0.identity == identity }) {
            // The typed transport writes the request out again, so the recorded bytes must come back
            // out of it unchanged; a record that would not (written by another build, say) is let go
            // rather than sent as something else under its key.
            if let decoded = try? DuoWireCoding.decode(DuoWireRedeemRequest.self, from: recorded.body),
               (try? DuoWireCoding.encode(decoded)) == recorded.body {
                recordedBody = recorded.body
            } else {
                journal.clear(operation: Self.redeemOperation)
                cache.saveInflight(journal)
            }
        }
        let body: Data
        if let recordedBody {
            body = recordedBody
        } else {
            var fresh = request
            fresh.deviceCheckToken = await dependencies.deviceCheck.token()
            guard host.wipeEpoch == epoch else { return nil }
            body = try DuoWireCoding.encode(fresh)
            journal = cache.loadInflight(now: dependencies.clock.now)
        }
        let recorded = journal.replayable(for: Self.redeemOperation, identity: identity, body: body, now: dependencies.clock.now,
                                          random: dependencies.random)
        cache.saveInflight(journal)
        let toSend = try DuoWireCoding.decode(DuoWireRedeemRequest.self, from: recorded.body)
        return RedeemAttempt(key: recorded.key, request: toSend, isReplay: recordedBody != nil)
    }

    nonisolated private static func isAttestRefusal(_ error: Error) -> Bool {
        switch error as? DuoTransportError {
        case .attestRequired?, .attestInvalid?: return true
        default: return false
        }
    }

    // MARK: - Codes for a duo that already exists

    func newInvite(for duo: DuoState) async -> DuoInvite? {
        guard let flow = beginFlow() else { return nil }
        defer { endFlow(flow) }
        host.sheetError = nil
        // Only a pending duo of mine has a code to replace; a live or ended one has none to offer.
        guard let current = host.duo(duo.id), current.isPending else { return nil }
        let epoch = host.wipeEpoch
        guard let wire = await makeCode(duoID: current.wireID, purpose: .invite, for: current.id, epoch: epoch) else { return nil }
        // The link carries the secret this phone already keeps for the duo, so links shared before
        // and after are alike; a reinstalled owner has none, and a new one is made (§4.1).
        if dependencies.secrets.linkSecret(forDuo: current.id) == nil {
            try? dependencies.secrets.saveLinkSecret(DuoLinkSecret.make(random: dependencies.random), forDuo: current.id)
        }
        let invite = DuoMapping.invite(wire)
        // The new code replaces the old one, which the server has just made void (§4.1).
        host.update(current.id) {
            $0.invite = invite
            $0.openInviteExpiresAt = wire.expiresAt
        }
        return invite
    }

    func createReconnectCode(for duo: DuoState) async -> DuoInvite? {
        guard let flow = beginFlow() else { return nil }
        defer { endFlow(flow) }
        host.sheetError = nil
        // Offered only when the partner's phone has been silent more than three days (§3.5), which
        // is also about the least the server asks (72 hours unseen, else `target_active`).
        guard let current = host.duo(duo.id), current.offersReconnect(myToday: dependencies.clock.today) else { return nil }
        let epoch = host.wipeEpoch
        // Shown, not kept on the duo: it is for the partner's new phone, not this duo's invite.
        return await makeCode(duoID: current.wireID, purpose: .reconnect, for: current.id, epoch: epoch).map(DuoMapping.invite)
    }

    func createLinkCode() async -> DuoInvite? {
        guard let flow = beginFlow() else { return nil }
        defer { endFlow(flow) }
        host.sheetError = nil
        // No screen asks for this in P2 ("Link this device" is phase 4): it is here so the contract's
        // `link_device` is exercised. `409 device_limit` carries `details.max`, 5 (D49, D52).
        let epoch = host.wipeEpoch
        return await makeCode(duoID: Self.linkDeviceDuoID, purpose: .linkDevice, for: nil, epoch: epoch).map(DuoMapping.invite)
    }

    /// `POST /duos/{id}/invites`, through the journal: a lost 201 is answered from the server's
    /// record on the next tap, with the very code it made, rather than voided by a second one. Not
    /// for someone the birth-year screen refused: nothing is kept or sent for them, whatever
    /// identity the phone still holds.
    private func makeCode(duoID: String, purpose: DuoWireInvitePurpose, for localDuo: UUID?, epoch: Int) async -> DuoWireInvite? {
        guard host.availability.allowsWrites, !ageRefused() else { return nil }
        host.isWorking = true
        defer { stopWorking(epoch) }
        guard await readyIdentity(epoch: epoch) else { return nil }
        do {
            let wire = try await journaled(Self.inviteOperation(duoID: duoID), DuoWireCreateInviteRequest(purpose: purpose), epoch: epoch) { key in
                try await self.dependencies.transport.createInvite(duoID: duoID, purpose: purpose, key: key)
            }
            guard host.wipeEpoch == epoch else { return nil }
            dependencies.noteSuccess()
            return wire
        } catch {
            guard host.wipeEpoch == epoch else { return nil }
            // `duo_ended` and `duo_unknown`: the duo is over, and the card says so, with no words of
            // its own (§6.7: "mark ended locally, no alert"). `conflict` (an invite asked for a duo
            // that went live meanwhile) leaves it as it is, for the next read to show live.
            // `not_partner`, `target_active` and `device_limit` have no approved words yet and read as
            // the general line with its reference.
            if fail(error, context: .general, duoID: localDuo, silentWhenEnded: true) == .ended, let localDuo { markEnded(localDuo) }
            return nil
        }
    }

    /// A duo the server says is over or unknown: ended here, with nothing to say who ended it
    /// (§6.7), and the push token let go if no live duo is left (§3.1).
    private func markEnded(_ id: UUID) {
        let now = dependencies.clock.now
        host.update(id) {
            if $0.endedAt == nil { $0.endedAt = now }
            if $0.endedBy == nil { $0.endedBy = .unknown }
            $0.invite = nil
            $0.openInviteExpiresAt = nil
        }
        if !host.duos.contains(where: { !$0.hasEnded }) { dependencies.push?.noLiveDuoRemains() }
    }

    // MARK: - Reconnect

    func reconnect(code: String) async -> Bool {
        guard let flow = beginFlow() else { return false }
        defer { endFlow(flow) }
        host.sheetError = nil
        guard mayStart(.reconnect) else { return false }
        guard let canonical = DuoInviteCode.normalize(code) else {
            host.sheetError = DuoCopy.notACode
            return false
        }
        let epoch = host.wipeEpoch
        host.isWorking = true
        defer { stopWorking(epoch) }
        let disconnectedAtTheTap = host.availability == .disconnected
        // Before any mint: a Leave queued by a disconnected phone goes out under the credential it was
        // made with, which a superseded device keeps for its exits (§3.5), not under the throwaway.
        guard await noExitIsStillQueued(for: .reconnect, epoch: epoch) else {
            if host.wipeEpoch == epoch, disconnectedAtTheTap { keepDisconnected() }
            return false
        }
        // Judged after the drain, which can itself learn that another phone took the identity (an
        // exit answered `device_revoked`).
        var disconnected = host.availability == .disconnected
        var identity: IdentitySource = .existing
        // "I had a duo" on a disconnected phone (§3.4): another phone took this identity, so every
        // call with the stored credential answers `device_revoked`. A throwaway identity is minted to
        // carry the reconnect, as on a fresh install: the redeem needs a member with no duos and one
        // device (§3.5). It is stored before the reconnect is sent and stays the stored credential,
        // remembered by `throwawayDeviceID`, until a reconnect answers 200 or Start fresh (D68):
        // stored first, a reconnect that lands and loses its answer cannot leave the phone without
        // the identity it now carries, and a relaunch reads the phone as disconnected again
        // (`DuoStore.install`) and reuses it. A second mint would cost the day, since a disconnected
        // phone's mint is a returning one (§11.3: one a UTC day per address). The revoked credential
        // stays stored until the throwaway replaces it, so a mint that fails gives up nothing.
        var mintsAThrowaway = disconnected && !holdsTheThrowaway()
        if !mintsAThrowaway {
            if let ready = await ensureIdentity(for: .reconnect, epoch: epoch) {
                identity = ready
            } else {
                guard host.wipeEpoch == epoch else { return false }
                // The launch this very tap asked can be the one that learns another phone took the
                // identity (`device_revoked` on the way). That is the phone "I had a duo" is for, so
                // the tap goes on as a disconnected phone's would, rather than sending nothing and
                // saying nothing and leaving the person to tap again. Only a credential the launch
                // judged: with none, `ensureIdentity` has already minted (or tried to), and a second
                // mint in one tap would cost the day, as would minting over a throwaway.
                guard !disconnected, host.availability == .disconnected, dependencies.identity.credential != nil, !holdsTheThrowaway() else {
                    if disconnected { keepDisconnected() }
                    return false
                }
                disconnected = true
                mintsAThrowaway = true
            }
        }
        if mintsAThrowaway {
            let revoked = dependencies.identity.credential
            guard await mint(epoch: epoch, throwaway: true, replacing: revoked) else {
                if host.wipeEpoch == epoch { keepDisconnected() }
                return false
            }
            identity = .minted
        }
        guard let sentAs = dependencies.identity.credential else { return false }

        let request = DuoWireReconnectRequest(code: canonical)
        let response: DuoWireReconnectResponse
        do {
            response = try await journaled(Self.reconnectOperation, request, epoch: epoch,
                                           settlesNow: { Self.settles($0) && !Self.mayMeanASeatIsTaken($0) }) { key in
                try await self.dependencies.transport.reconnect(request, key: key)
            }
        } catch {
            guard host.wipeEpoch == epoch else { return false }
            if Self.mayMeanASeatIsTaken(error) {
                // A reconnect that landed and lost its answer moved this device already; a later
                // attempt (another code, a code that has since lapsed) then hears the code is gone.
                // `GET /me` answers as the member the device now belongs to (D70). A throwaway minted
                // in this tap has never been sent before, so it cannot have been moved.
                var check = ReconnectCheck.notLanded
                if identity == .existing { check = await reconnectLanded(sentAs: sentAs, epoch: epoch) }
                switch check {
                case .landed(let me):
                    settleJournal(Self.reconnectOperation, epoch: epoch)
                    finishReconnect(memberID: me.member.id, supportID: me.member.supportId, duos: me.duos, sentAs: sentAs)
                    host.memberInfo = DuoMapping.member(me, now: dependencies.clock.now)
                    await sendTheHeldExits()
                    return true
                case .notLanded:
                    if Self.settles(error) { settleJournal(Self.reconnectOperation, epoch: epoch) }
                case .unknown:
                    dependencies.noteFailure(error)
                    if disconnected { keepDisconnected() }
                    return false
                case .dropped:
                    return false
                }
            }
            // `member_not_fresh`, `invite_unknown`, `rate_limited`, the invite breaker's 503 and the
            // attestation refusals each have their words. `wrong_purpose` here is a duo invite typed
            // into the reconnect field, where "Ask for a duo invite" would send the person the wrong
            // way, and `device_limit` has no approved words yet: both read as the general line.
            if case .wrongPurpose(let context) = error as? DuoTransportError {
                fail(error, context: .invite, saidAs: DuoTransportError.conflict(context))
            } else {
                fail(error, context: .invite)
            }
            if disconnected { keepDisconnected() }
            return false
        }
        // The answer is about the device the request went as; if the identity changed under it, it
        // is not this phone's to keep.
        guard host.wipeEpoch == epoch, dependencies.identity.credential?.deviceID == sentAs.deviceID else { return false }
        finishReconnect(memberID: response.memberId, supportID: response.supportId, duos: response.duos, sentAs: sentAs)
        await sendTheHeldExits()
        // Best effort: the rest of the member record (the name, the limits, the devices) comes from
        // `GET /me`, and whatever reads it when stale asks again later if this one fails.
        if host.wipeEpoch == epoch { await refreshMember(epoch: epoch) }
        return true
    }

    /// A Leave or a Block tapped while the throwaway was the stored credential is held by the queue
    /// (stage E): sent as the throwaway, it would meet `404 duo_unknown`, count as done, and leave
    /// the server's duo live (a Block never applied). The marker is gone once `finishReconnect` has
    /// run, so the queue is drained now, and the exits go under the member they were tapped for.
    private func sendTheHeldExits() async {
        await dependencies.ops?.drain()
    }

    /// The device now belongs to the member the code is for. Nothing rotates (§3.5): the same id and
    /// secret, under that member. The member id in the credential is kept, never sent, so a Keychain
    /// that refuses this write leaves a bearer that still works. The throwaway is one no longer.
    private func finishReconnect(memberID: String, supportID: String, duos: [DuoWireHeader], sentAs: DuoCredential) {
        try? dependencies.identity.store(DuoCredential(memberID: memberID, deviceID: sentAs.deviceID,
                                                       deviceSecret: sentAs.deviceSecret, secretVersion: sentAs.secretVersion))
        dependencies.cache.throwawayDeviceID = nil
        let now = dependencies.clock.now
        for header in duos {
            guard let id = UUID(uuidString: header.id), !dependencies.cache.isCleared(id, now: now) else { continue }
            var previous = host.duo(id)
            // A duo this phone ended on its own guess (a `duo_unknown` or a 401 while it held another
            // identity, `ended_by = unknown`, §6.7) comes back when the server lists it live: the
            // mapping never revives an ended duo, which is right for a Leave that has not reached the
            // server yet (`pendingOp`, `ended_by` mine) and wrong for a guess the server contradicts.
            if header.state != .ended, var guessed = previous, guessed.hasEnded, guessed.endedBy == .unknown, guessed.pendingOp == nil {
                guessed.endedAt = nil
                guessed.endedBy = nil
                previous = guessed
            }
            guard let mapped = DuoMapping.duo(from: header, previous: previous, now: now) else { continue }
            // Every duo comes back to be read whole before this phone writes for it: the rows a
            // cached one holds were read by an older identity, and writing first could lower a day
            // the other phone has moved on (§10.3, KV11). A new one has read nothing yet either.
            host.upsert(DuoMapping.reseated(mapped))
        }
        if host.memberInfo?.memberID != memberID {
            let known = host.memberInfo
            host.memberInfo = partialMember(memberID: memberID, supportID: supportID, tier: known?.tier ?? .low,
                                            termsVersion: known?.termsVersion ?? dependencies.cache.acceptedTermsVersion)
        }
        if host.availability == .disconnected { host.availability = .available }
        dependencies.noteSuccess()
        dependencies.push?.reevaluate(.duoStarted)
        dependencies.ops?.startMonitoring()
    }

    private enum ReconnectCheck {
        case landed(DuoWireGetMeResponse)
        case notLanded
        case unknown
        case dropped
    }

    /// Whether the device a refused reconnect went as already belongs to another member: then an
    /// earlier attempt landed and lost its answer.
    private func reconnectLanded(sentAs: DuoCredential, epoch: Int) async -> ReconnectCheck {
        do {
            let me = try await dependencies.transport.me()
            guard host.wipeEpoch == epoch else { return .dropped }
            return me.member.id != sentAs.memberID ? .landed(me) : .notLanded
        } catch {
            guard host.wipeEpoch == epoch else { return .dropped }
            if dependencies.noteFailure(error) != .cancelled { host.sheetError = DuoUserMessage.text(for: error, context: .invite) }
            return .unknown
        }
    }

    private func holdsTheThrowaway() -> Bool {
        guard let throwaway = dependencies.cache.throwawayDeviceID else { return false }
        return dependencies.identity.credential?.deviceID == throwaway
    }

    /// A reconnect that failed leaves the phone disconnected, so its card keeps "I had a duo" (§3.4).
    /// `noteFailure` reads a 503 as the service being paused, which would take the card's question
    /// away and leave a throwaway identity behind cached duos that are not its own. What says more
    /// than that (banned, an update needed) stands.
    private func keepDisconnected() {
        switch host.availability {
        case .unknown, .available, .maintenance: host.availability = .disconnected
        case .disconnected, .upgradeRequired, .banned, .needsRestoreChoice: break
        }
    }

    private func refreshMember(epoch: Int) async {
        do {
            let me = try await dependencies.transport.me()
            guard host.wipeEpoch == epoch else { return }
            host.memberInfo = DuoMapping.member(me, now: dependencies.clock.now)
        } catch {
            guard host.wipeEpoch == epoch else { return }
            dependencies.noteFailure(error)
        }
    }

    // MARK: - Name and terms

    func changeMyName(_ name: String?) async {
        // Nothing is kept or sent for someone the birth-year screen refused.
        guard !ageRefused() else { return }
        let cleaned = dependencies.cleanedNameOrNil(name)
        host.myDisplayName = cleaned ?? ""
        // Without an identity the name is only kept here, and goes with the next create or join.
        await queueName(cleaned, epoch: host.wipeEpoch)
    }

    /// `PATCH /me` with this name and the active skin, through the op queue (§10.1), so a change made
    /// offline lands later; the server's name rule decides, and a refusal is shown by whatever shows
    /// the queue's results. Queued only for an identity the launch says is ready and only while writes
    /// are allowed: during the restore question the credential may be a previous owner's, and on a
    /// disconnected or out-of-date phone the request could only be refused and dropped. Otherwise the
    /// name stays on this phone.
    private func queueName(_ cleaned: String?, epoch: Int) async {
        guard dependencies.identity.credential != nil, let ops = dependencies.ops else { return }
        let launch = await dependencies.identity.prepare()
        guard host.wipeEpoch == epoch, launch == .ready, host.availability.allowsWrites, dependencies.identity.credential != nil else { return }
        let request = DuoWireUpdateMeRequest(displayName: cleaned.map { DuoWireField<String>.value($0) } ?? .null,
                                             skin: .value(dependencies.activeSkin()))
        guard let op = try? DuoQueuedOp.updateMe(request, key: DuoIdempotencyKey.make(random: dependencies.random).value,
                                                 now: dependencies.clock.now) else { return }
        ops.enqueue(op)
        await ops.drain()
    }

    func acceptTerms() async -> Bool {
        // A Create sent while this request is out could meet `428` again, so it waits its turn.
        guard let flow = beginFlow() else { return false }
        defer { endFlow(flow) }
        // An earlier failure's words would otherwise stay up after an Accept that works.
        host.sheetError = nil
        // The store has already recorded the acceptance. Without an identity nothing is sent: the
        // mint carries `terms_version` (§6.2).
        guard dependencies.identity.credential != nil else {
            host.needsTerms = false
            return true
        }
        let epoch = host.wipeEpoch
        let launch = await dependencies.identity.prepare()
        guard host.wipeEpoch == epoch else { return false }
        guard dependencies.identity.credential != nil else {
            host.needsTerms = false
            return true
        }
        guard launch == .ready else {
            stop(for: launch)
            return false
        }
        do {
            let member = try await dependencies.transport.updateMe(DuoWireUpdateMeRequest(termsVersion: .value(DuoProtocolConstants.termsVersion)))
            guard host.wipeEpoch == epoch else { return false }
            host.needsTerms = false
            if var info = host.memberInfo {
                info.termsVersion = member.termsVersion
                host.memberInfo = info
            }
            dependencies.noteSuccess()
            return true
        } catch {
            guard host.wipeEpoch == epoch else { return false }
            fail(error, context: .general)
            return false
        }
    }

    // MARK: - A Leave still on its way

    /// A Leave or a Block the op queue has not sent yet stands in the way of a new start (D9). Both
    /// are pair-wide: one that lands after a join with the same partner ends the new duo too (§7.5),
    /// and one that lands first makes refused an invite that partner made earlier (D35). So the
    /// queue is drained once, and if an exit is still waiting (offline, rate limited) nothing is
    /// started and the general line is said: the screen already shows the duo ended, and the start
    /// can come once the queue has caught up.
    ///
    /// Only an exit the stored credential could send stands in the way. With no credential (a
    /// backup that brought the App Group's defaults without the Keychain item), or with the
    /// throwaway a Reconnect minted, the queue holds the exit for the Reconnect that brings its
    /// member back (stage E), so refusing that Reconnect, as this used to, refused every start on
    /// the phone for good. The drain can also learn that this phone may not write at all (a ban,
    /// an update needed), which stops the flow here with nothing sent, as `mayStart` would have.
    private func noExitIsStillQueued(for flow: ConsentFlow, epoch: Int) async -> Bool {
        guard let ops = dependencies.ops else { return true }
        await ops.drain()
        guard host.wipeEpoch == epoch else { return false }
        guard writesAllowed(for: flow) else { return false }
        guard dependencies.identity.credential != nil, !dependencies.credentialIsAThrowaway else { return true }
        guard ops.pending.contains(where: { $0.kind == .leave || $0.kind == .block }) else { return true }
        host.sheetError = DuoUserMessage.generic
        return false
    }

    // MARK: - Consent and identity

    private enum ConsentFlow {
        case create
        case join
        case reconnect
    }

    /// Where the identity a flow sends with came from: one this phone already had, or one minted
    /// in this very tap, which has never redeemed anything and so has no lost seat to look for.
    private enum IdentitySource {
        case existing
        case minted
    }

    /// A refusal is believed wherever it is kept: the cache, or the Keychain, which outlives a
    /// reinstall (D60). The store asks the same before it calls this service; asking here too means
    /// no caller that comes straight to the service can send for someone who was refused.
    private func ageRefused() -> Bool {
        dependencies.cache.ageStatus == .refused || dependencies.secrets.isAgeRefused()
    }

    /// The preconditions a consent flow must meet before it may send anything at all. Each one that
    /// fails refuses with nothing sent; only the rules ask for something (`needsTerms`, so the sheet
    /// that is up shows them), and only the duo limit and a phone holding orphaned duos say why.
    private func mayStart(_ flow: ConsentFlow) -> Bool {
        guard writesAllowed(for: flow) else { return false }
        // The birth-year screen is the UI's (§12.6); until it has said yes, nothing is sent.
        guard dependencies.cache.ageStatus == .allowed, !dependencies.secrets.isAgeRefused() else { return false }
        guard dependencies.cache.acceptedTermsVersion >= DuoProtocolConstants.termsVersion else {
            host.needsTerms = true
            return false
        }
        guard flow != .reconnect else { return true }
        // Live duos cached with no credential to act for them (a backup brought the App Group's
        // defaults without the Keychain item): they are not this person's to count against a limit,
        // and the way back is "I had a duo", which the Duo screen offers once the identity has been
        // asked. A new duo started under a new identity now would strand them. The general line,
        // since none of the limit's words is true.
        if dependencies.identity.credential == nil, host.duos.contains(where: { !$0.hasEnded }) {
            host.sheetError = DuoUserMessage.generic
            return false
        }
        if !DuoLimit.canAddDuo(existing: host.duos, isSubscribed: dependencies.isSubscribed()) {
            // The server's own refusal, said without asking it: `duo_limit` with how many duos are
            // live and the most this person may have.
            let active = host.duos.filter { !$0.hasEnded }.count
            let details = DuoWireErrorDetails(max: DuoLimit.maximum(isSubscribed: dependencies.isSubscribed()), activeDuos: active)
            host.sheetError = DuoUserMessage.text(for: DuoTransportError.duoLimit(DuoErrorContext(httpStatus: 0, details: details)), context: .invite)
            return false
        }
        return true
    }

    private func writesAllowed(for flow: ConsentFlow) -> Bool {
        flow == .reconnect ? host.availability.allowsReconnect : host.availability.allowsWrites
    }

    /// An identity to send a consent flow's request with: the one this phone has, once the launch
    /// says it is ready, or a new one minted now, the tap being the consent (§3.1, §3.4). Nil when
    /// there is none to send with.
    ///
    /// The launch is asked even with no credential in sight: a credential the Keychain could not
    /// read (the first unlock after a restart) is answered `.unavailable`, not `.none`, and minting
    /// then would put a second identity beside the real one. Asking may itself change what is
    /// allowed (a phone with live cached duos and no credential is the disconnected question), so
    /// writes are judged again after it.
    private func ensureIdentity(for flow: ConsentFlow, epoch: Int) async -> IdentitySource? {
        let identity: DuoIdentityProviding = dependencies.identity
        let launch = await identity.prepare()
        guard host.wipeEpoch == epoch else { return nil }
        if identity.credential != nil {
            guard launch == .ready else {
                stop(for: launch)
                return nil
            }
            return .existing
        }
        guard launch == .none || launch == .ready else {
            stop(for: launch)
            return nil
        }
        guard writesAllowed(for: flow) else { return nil }
        return await mint(epoch: epoch, throwaway: flow == .reconnect, replacing: nil) ? .minted : nil
    }

    /// For a request that needs the identity this phone already has: never mints.
    private func readyIdentity(epoch: Int) async -> Bool {
        guard dependencies.identity.credential != nil else { return false }
        let launch = await dependencies.identity.prepare()
        guard host.wipeEpoch == epoch, dependencies.identity.credential != nil else { return false }
        guard launch == .ready else {
            stop(for: launch)
            return false
        }
        return true
    }

    /// The launch said something other than ready. The restore question and the disconnected one
    /// are the screen's to ask (the identity has set `availability`). A launch that could not tell
    /// (offline, maintenance, a Keychain not yet readable) leaves the person the general line, so a
    /// tap is never met with nothing at all.
    private func stop(for launch: DuoIdentityLaunch) {
        if launch == .unavailable { host.sheetError = DuoUserMessage.generic }
    }

    /// `POST /devices`: a member and a device, made at the tap, and kept.
    ///
    /// Not idempotent and never sent again here, and a lost answer costs more than the identity the
    /// server's 30-day unpaired purge removes: the first mint sets this phone's DeviceCheck
    /// "returning" bit, so the next one starts at the low tier and is held to one returning mint per
    /// address in a UTC day (§11.2, §11.3). The request and the save of its answer are held against
    /// the app being suspended in between, as the identity holds its rotate; contract 1.1 (D65)
    /// is to make the mint safe to repeat.
    ///
    /// `throwaway` marks one minted to carry a Reconnect (D68). `replacing` is the credential it
    /// takes the place of, a disconnected phone's revoked one: given up only now that the new one
    /// is stored, with its attestation key and the devices the person was told about (D45), which
    /// belonged to that identity and would make this phone's own device look like an added one.
    private func mint(epoch: Int, throwaway: Bool, replacing replaced: DuoCredential?) async -> Bool {
        let token = await dependencies.deviceCheck.token()
        guard host.wipeEpoch == epoch else { return false }
        // The version the person accepted on the rules screen, which `mayStart` found recorded: the
        // store records exactly this build's version, and nothing here records it for them.
        let request = DuoWireCreateDeviceRequest(appVersion: dependencies.client.appVersion, termsVersion: DuoProtocolConstants.termsVersion,
                                                 deviceCheckToken: token)
        let release = holdInBackground("Saving this phone's Duo identity")
        defer { release() }
        let response: DuoWireCreateDeviceResponse
        do {
            response = try await dependencies.transport.createDevice(request)
        } catch {
            guard host.wipeEpoch == epoch else { return false }
            fail(error, context: .invite)
            return false
        }
        guard host.wipeEpoch == epoch else { return false }
        // The throwaway's marker goes down before the throwaway is stored. The other way round, a
        // kill between the two left the throwaway stored with nothing to say what it was, behind
        // another member's duos, which the next launch could read with as the person's own and
        // end. A marker that names a device never stored is harmless: the store drops one
        // that names some other credential it can read (`DuoStore.applyThrowawayMarker`).
        let earlierMarker = dependencies.cache.throwawayDeviceID
        if throwaway { dependencies.cache.throwawayDeviceID = response.deviceId }
        do {
            try dependencies.identity.store(DuoCredential(memberID: response.memberId, deviceID: response.deviceId,
                                                          deviceSecret: response.deviceSecret))
        } catch {
            // An identity that cannot be kept is not used: the next tap mints again.
            if throwaway { dependencies.cache.throwawayDeviceID = earlierMarker }
            host.sheetError = DuoUserMessage.generic
            return false
        }
        // A rename or a push-token upload queued under an earlier identity would go out under this
        // new member; a Leave or a Block stays, being right only for the member it names (D8).
        dependencies.ops?.discardIdentityBound()
        if let replaced, replaced.deviceID != response.deviceId {
            dependencies.attester.forgetKeys(forDevice: replaced.deviceID)
            dependencies.cache.forgetSeenDeviceIDs()
        }
        // What the last push upload said belonged to an older device. This one has uploaded nothing,
        // and a record left behind would tell the push service it had (§6.2).
        dependencies.cache.savePushUpload(nil)
        host.memberInfo = partialMember(memberID: response.memberId, supportID: response.supportId, tier: response.tier,
                                        termsVersion: request.termsVersion)
        dependencies.noteSuccess()
        return true
    }

    /// A throwaway that now holds a duo of its own (a Create or a Join it carried) is this person's
    /// identity, not a stand-in behind another member's duos.
    private func identityNowHoldsADuo() {
        if holdsTheThrowaway() { dependencies.cache.throwawayDeviceID = nil }
    }

    /// The member record as far as a mint or a reconnect says: the Support ID and the tier. It is
    /// dated the distant past so whatever reads `GET /me` when the record is stale reads it at the
    /// next chance and fills in the rest (the name, the devices, the server's limits).
    private func partialMember(memberID: String, supportID: String, tier: DuoTier, termsVersion: Int) -> DuoMemberInfo {
        DuoMemberInfo(memberID: memberID, displayName: nil, skin: nil, supportID: supportID, tier: tier, termsVersion: termsVersion,
                      nudgesPerDay: tier == .low ? Self.lowTierNudgesPerDay : DuoNudgeRules.dailyLimit,
                      maxActiveDuos: DuoLimit.plusDuoCount, devices: [], minClientIOS: nil, updatedAt: .distantPast)
    }

    // MARK: - Failures

    /// A failure the sheet says in place: noted once (`noteFailure`: Diagnostics, and whatever it
    /// says about this phone's standing), then put in `DuoUserMessage`'s words, for `saidAs` where
    /// the failure's own words would mislead. A cancelled task changes nothing and says nothing. A
    /// 428 says nothing either, since the sheet shows the terms again (`needsTerms`), unless the
    /// terms are newer than this build can record, which is an update the sheet says the app needs.
    /// `silentWhenEnded`: a duo the server says is over is shown ended, with no words of its own.
    @discardableResult
    private func fail(_ error: Error, context: DuoMessageContext, duoID: UUID? = nil, saidAs: Error? = nil,
                      silentWhenEnded: Bool = false) -> DuoRetry.Verdict {
        let verdict = dependencies.noteFailure(error, duoID: duoID)
        switch verdict {
        case .cancelled:
            break
        case .termsRequired:
            if host.availability == .upgradeRequired { host.sheetError = DuoAvailability.upgradeRequired.bannerMessage }
        case .ended where silentWhenEnded:
            break
        default:
            host.sheetError = DuoUserMessage.text(for: saidAs ?? error, context: context)
        }
        return verdict
    }

    /// Rows the server refused for a reason that will not change by itself are kept per duo, so the
    /// outbox does not send them again on every flush (§10.2, KV10). Never `ver_conflict` or
    /// `downgrade_refused`, which re-base instead.
    private func recordRejected(_ rejected: [DuoWireRejected], sent: [DuoWireStatusIn], role: DuoRole, duoID: UUID, now: Date) {
        let lasting: Set<DuoWireRejectReason> = [.dayOutOfRange, .dayAfterToday, .statusInconsistent]
        let key = duoID.uuidString.lowercased()
        var all = dependencies.cache.loadRejectedDays()
        var days = all[key] ?? DuoRejectedDays()
        var recorded = false
        for refusal in rejected where lasting.contains(refusal.reason) {
            guard let row = sent.last(where: { $0.day == refusal.day }) else { continue }
            days.record(DuoDayStatus(role: role, day: row.day, goalMet: row.goalMet, progressBucket: row.progressBucket, updatedAt: now))
            recorded = true
        }
        guard recorded else { return }
        all[key] = days
        dependencies.cache.saveRejectedDays(all)
    }

    // MARK: - The journal

    /// Sends an idempotent request whose bytes are the same on every attempt, recorded first.
    /// `settlesNow` says which failures take the record at once; one that needs `GET /me` first (a
    /// reconnect told its code is gone) is settled by its caller.
    private func journaled<Request: Encodable, Response>(_ operation: String, _ request: Request, epoch: Int,
                                                          settlesNow: (Error) -> Bool = DuoJoiningService.settles,
                                                          send: (DuoIdempotencyKey) async throws -> Response) async throws -> Response {
        let body = try DuoWireCoding.encode(request)
        let cache = dependencies.cache
        var journal = cache.loadInflight(now: dependencies.clock.now)
        let key = journal.key(for: operation, body: body, now: dependencies.clock.now, random: dependencies.random)
        cache.saveInflight(journal)
        do {
            let response = try await send(key)
            settleJournal(operation, epoch: epoch)
            return response
        } catch {
            if settlesNow(error) { settleJournal(operation, epoch: epoch) }
            throw error
        }
    }

    /// Whether a failure settles the request: a refusal the server judged, which a replay would
    /// only repeat. Not a cancelled task, no connection, an answer that could not be read (a 2xx
    /// among them: the request landed and its answer is lost), a 5xx or a WAF page (`maintenance`,
    /// a 401 without the server's envelope included, D63) or a rate limit, each of which says "not
    /// now" or nothing, never "no"; and not the client's own "no credential", which never left the
    /// phone.
    nonisolated private static func settles(_ error: Error) -> Bool {
        guard let error = error as? DuoTransportError else { return false }
        switch error {
        case .offline, .unreadable, .maintenance, .rateLimited:
            return false
        case .unauthenticated(let context):
            return context.httpStatus != 0
        default:
            return true
        }
    }

    /// Takes a settled operation out of the journal, reading it again first, since `noteFailure` may
    /// have emptied it meanwhile (a 401 `unauthenticated` takes every record with the identity).
    /// After a wipe it writes nothing: the wipe took the journal, and a write now would put the key
    /// back on disk.
    private func settleJournal(_ operation: String, epoch: Int) {
        guard host.wipeEpoch == epoch else { return }
        var journal = dependencies.cache.loadInflight(now: dependencies.clock.now)
        guard journal.entries.contains(where: { $0.operation == operation }) else { return }
        journal.clear(operation: operation)
        dependencies.cache.saveInflight(journal)
    }
}
#endif
