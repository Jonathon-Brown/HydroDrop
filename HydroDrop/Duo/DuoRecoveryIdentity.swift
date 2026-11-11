#if DUO_V2
import Foundation

/// What Delete my Duo data achieved. `removedFromThisPhone` means the phone let go of everything
/// but the server never confirmed a deletion (a 410 for an unfinished setup), so the person is
/// told only that.
enum DuoRecoveryDeletion { case deleted, removedFromThisPhone, failed }

/// Contract 1.1's live identity. The old v1 identity remains available to frozen-contract
/// tests; live composition always installs this implementation and never falls back to mint
/// or rotation through v1. Every request is preceded by a verified durable transition.
final class DuoRecoveryIdentity: DuoIdentityProviding, @unchecked Sendable {
    let journal: DuoRecoveryJournal
    private let dependencies: DuoDependencies
    private let legacyEnvironment: DuoRecoveryEnvironment?
    private let legacyProvenance: (@MainActor (DuoCredential) -> DuoRecoveryEnvironment?)?
    private let directory: URL
    private let presenceChanged: @Sendable () -> Void
    private let presenceLock = NSLock()
    private var presence = false
    @MainActor private var running: Task<DuoIdentityLaunch, Never>?
    @MainActor private var lastState: DuoRecoveryCredentialState?
    @MainActor private var lastConfirmedOperationID: String?
    @MainActor private var retryNotBefore: Date?

    @MainActor init(dependencies: DuoDependencies, environment: DuoRecoveryEnvironment,
                    verifiedLegacyEnvironment: DuoRecoveryEnvironment? = nil, directory: URL = DuoIdentity.defaultDirectory,
                    legacyProvenance: (@MainActor (DuoCredential) -> DuoRecoveryEnvironment?)? = nil) {
        self.dependencies = dependencies; self.legacyEnvironment = verifiedLegacyEnvironment; self.directory = directory
        self.legacyProvenance = legacyProvenance
        let host = dependencies.host
        presenceChanged = { [weak host] in Task { @MainActor in host?.identityPresenceChanged() } }
        journal = DuoRecoveryJournal(store: dependencies.secrets.store, environment: environment)
        // Presence is a local read, independent of whether provenance or a restore choice
        // permits use. Rendering this flag never retries Keychain or starts recovery.
        if let record = try? journal.read() { presence = record.active != nil || record.pending != nil }
        else {
            presence = ((try? journal.readMirror()) != nil) ||
                ((try? dependencies.secrets.store.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount)) != nil)
        }
    }
    var cachedCredentialPresence: Bool { presenceLock.lock(); defer { presenceLock.unlock() }; return presence }
    var credential: DuoCredential? {
        guard let record = try? journal.read(), (try? journal.markerMatches(record)) == true, (try? sentinelMatches(record)) == true else { return nil }
        return record.ordinaryCredential
    }
    var peekCredential: DuoCredential? { credential }
    var installDay: String { DayKey.key(for: Date(), calendar: .current) }
    private func rememberPresence(_ record: DuoRecoveryRecord?) {
        presenceLock.lock(); presence = record?.active != nil || record?.pending != nil; presenceLock.unlock()
        presenceChanged()
    }
    /// Only a verified reassociation of this same bearer may change the member. A caller cannot
    /// import a fresh credential through this legacy-shaped seam or replace a pending operation.
    func store(_ credential: DuoCredential) throws {
        guard var r = try journal.read(), let active = r.active, r.pending == nil, r.intent == .use,
              active.deviceID == credential.deviceID, active.deviceSecret == credential.deviceSecret,
              active.secretVersion == credential.secretVersion else { throw DuoJournalError.changed }
        let revision = r.recordRevision
        r.active = DuoJournalCredential(credential, protocolVersion: active.credentialProtocol); r.activeRole = .established
        r.recordRevision += 1; try journal.replace(r, expectedRevision: revision); try journal.writeMirror(r); rememberPresence(r)
    }
    func replaceSecret(_ secret: String, version: Int) throws { throw DuoJournalError.changed }
    func discard() { _ = abandonLocally() }
    @discardableResult func abandonLocally() -> Bool {
        do { try journal.abandon(random: dependencies.random); rememberPresence(nil); return true }
        catch { return false }
    }

    func prepare() async -> DuoIdentityLaunch { await prepareOnMain() }
    @MainActor private func prepareOnMain() async -> DuoIdentityLaunch {
        if let running { return await running.value }
        let task = Task { @MainActor in await self.launch() }
        running = task; let result = await task.value; running = nil; return result
    }
    @MainActor private var ordinaryAllowed: Bool {
        dependencies.ageNetworkAllowed && dependencies.cache.ageStatus == .allowed && dependencies.cache.hasCurrentAgePolicy &&
        dependencies.cache.acceptedTermsVersion >= DuoProtocolConstants.termsVersion
    }
    @MainActor private func readyForNetwork() throws {
        guard ordinaryAllowed, !Task.isCancelled else { throw DuoJournalError.unavailable }
        try respectBackoff()
    }
    @MainActor private func respectBackoff() throws {
        let now = dependencies.clock.now
        let stored = try journal.retryDeadline()
        if let memory = retryNotBefore, memory > now, stored.map({ $0 < memory }) ?? true {
            // A failed save is retried before any dispatch, never swallowed into permission.
            try journal.saveRetryDeadline(memory, now: now)
        }
        if let deadline = try journal.retryDeadline() {
            guard now >= deadline else { throw DuoJournalError.unavailable }
            try journal.clearRetryDeadline()
        }
        retryNotBefore = nil
    }
    private func replace(_ record: DuoRecoveryRecord, _ change: (inout DuoRecoveryRecord) -> Void) throws -> DuoRecoveryRecord {
        var next = record; change(&next); next.recordRevision = record.recordRevision + 1
        try journal.replace(next, expectedRevision: record.recordRevision); rememberPresence(next); return next
    }
    @MainActor private func launch() async -> DuoIdentityLaunch {
        do {
            guard var r = try loadOrImport() else { rememberPresence(nil); return .none }
            rememberPresence(r)
            if r.phase == .abandoned { try journal.purgeAbandonedSecrets(); return .none }
            guard r.intent == .use else { return .unavailable }
            if r.phase == .promotionPending { r = try finishPromotion(r) }
            if !ordinaryAllowed {
                if r.access != .suspended { _ = try replace(r) { $0.access = .suspended } }
                return .unavailable
            }
            try readyForNetwork()
            if r.access == .suspended { r = try replace(r) { $0.access = $0.restoreConfirmationRequired ? .restoreConfirmationRequired : .eligible } }
            if r.pending != nil { r = try await reconcile(r) }
            if r.restoreRotationRequired {
                r = try await beginRotation(r)
                r = try await reconcile(r)
            }
            if r.restoreConfirmationRequired {
                let prompt = DuoRestorePrompt(partnerName: nil, myName: nil)
                dependencies.host.availability = .needsRestoreChoice(prompt)
                return .needsRestoreChoice(prompt)
            }
            if r.activeRole == .reconnectThrowaway {
                dependencies.cache.throwawayDeviceID = r.active?.deviceID
                if dependencies.host.duos.contains(where: { !$0.hasEnded }) { dependencies.host.availability = .disconnected }
            }
            if r.ordinaryCredential != nil, case .needsRestoreChoice = dependencies.host.availability {
                dependencies.host.availability = .available
            }
            return r.ordinaryCredential == nil ? .unavailable : .ready
        } catch { note(error); return .unavailable }
    }

    /// An unlabelled legacy credential has no trustworthy server provenance. A host selection
    /// cannot supply that fact. Migration is possible only through an explicitly verified mapping.
    @MainActor private func loadOrImport() throws -> DuoRecoveryRecord? {
        if var r = try journal.read() {
            if r.phase == .abandoned { return r }
            let mirror = try journal.readMirror()
            if r.intent == .use {
                // A journal can survive same-phone reinstall even while a request was pending.
                // Preserve its candidate, but never let finishing that operation manufacture
                // consent for a new sandbox installation. A pending CAS confirmation clears
                // rotationRequired in confirm(), while Continue remains an independent choice.
                let sameInstall = try journal.markerMatches(r) && sentinelMatches(r)
                if !sameInstall, !r.restoreRotationRequired || !r.restoreConfirmationRequired {
                    r = try replace(r) { $0.restoreRotationRequired = true; $0.restoreConfirmationRequired = true; $0.access = .restoreConfirmationRequired }
                }
            }
            if [.active, .activeLegacy].contains(r.phase) {
                if mirror?.credential != r.active || mirror?.credentialRole != r.activeRole { try journal.writeMirror(r) }
            }
            return r
        }
        let mirror = try journal.readMirror()
        let legacyData = try dependencies.secrets.store.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount)
        guard mirror != nil || legacyData != nil else { return nil }
        let active: DuoJournalCredential
        let role: DuoCredentialRole
        let rotationRequired: Bool
        let confirmationRequired: Bool
        if let mirror {
            active = mirror.credential; role = mirror.credentialRole; rotationRequired = true; confirmationRequired = true
        } else {
            guard let legacyData else { throw DuoJournalError.legacyProvenanceRequired }
            active = try DuoRecoveryJournal.decodeLegacyCredential(legacyData)
            let old = active.credential
            guard legacyEnvironment == journal.environment || legacyProvenance?(old) == journal.environment else {
                throw DuoJournalError.legacyProvenanceRequired
            }
            if let marker = dependencies.cache.throwawayDeviceID, marker != old.deviceID { throw DuoJournalError.invalid }
            role = dependencies.cache.throwawayDeviceID == old.deviceID ? .reconnectThrowaway : .established
            // Capture the old facts before writing any new marker. Creating a marker is never
            // proof that this is the same installation or that Continue was answered.
            let marker = try dependencies.secrets.store.read(service: DuoSecrets.service, account: DuoSecrets.installMarkerAccount)
            if let marker, marker.count != 16 { throw DuoJournalError.invalid }
            rotationRequired = marker == nil
            confirmationRequired = rotationRequired || !FileManager.default.fileExists(atPath: directory.appendingPathComponent("duo.settled").path)
        }
        var r = DuoRecoveryRecord(environment: journal.environment, installationID: dependencies.random.uuid().uuidString.lowercased(), phase: active.credentialProtocol == "1.0" ? .activeLegacy : .active)
        r.active = active; r.activeRole = role; r.restoreRotationRequired = rotationRequired; r.restoreConfirmationRequired = confirmationRequired
        r.access = confirmationRequired ? .restoreConfirmationRequired : .eligible
        try journal.replace(r, expectedRevision: nil); try journal.writeMirror(r); try journal.writeMarker(r); try writeSentinel(r)
        // Erasing the old record comes last. Downgrade safety is not promised: the old client
        // cannot understand the new journal and must not be run after this migration.
        if legacyData != nil {
            try dependencies.secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.deviceAccount)
            guard try dependencies.secrets.store.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount) == nil else { throw DuoJournalError.unavailable }
        }
        return r
    }

    private var sentinel: URL { directory.appendingPathComponent("duo.install-v1.1.\(journal.environment.rawValue)") }
    private func sentinelMatches(_ record: DuoRecoveryRecord) throws -> Bool {
        guard FileManager.default.fileExists(atPath: sentinel.path) else { return false }
        let bytes = try Data(contentsOf: sentinel)
        guard let id = String(data: bytes, encoding: .utf8), DuoRecoveryWire.isUUID(id) else { throw DuoJournalError.invalid }
        return id == record.installationID
    }
    private func writeSentinel(_ record: DuoRecoveryRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(record.installationID.utf8).write(to: sentinel, options: .atomic)
        try DuoIdentity.markExcludedFromBackup(sentinel)
        guard try sentinelMatches(record) else { throw DuoJournalError.unavailable }
    }

    @MainActor func mint(role: DuoRecoveryPending.Role, replacing: DuoCredential?) async -> DuoRecoveryCredentialState? {
        do {
            try readyForNetwork()
            guard let transport = dependencies.recoveryTransport else { throw DuoJournalError.unavailable }
            var old = try loadOrImport()
            if old?.phase == .abandoned { try journal.purgeAbandonedSecrets() }
            guard old == nil || old?.phase == .abandoned || old?.intent == .use else { throw DuoJournalError.changed }
            if let existing = old, let pending = existing.pending {
                guard pending.kind == .mint, pending.role == role else { throw DuoJournalError.changed }
                let finished = try await reconcile(existing)
                guard let credential = finished.active, finished.ordinaryCredential != nil else { throw DuoJournalError.invalid }
                try readyForNetwork()
                guard finished.intent == .use, try journal.read() == finished else { throw DuoJournalError.changed }
                if let lastState, lastConfirmedOperationID == pending.operationID,
                   lastState.deviceID == credential.deviceID, lastState.memberID == credential.memberID,
                   lastState.secretVersion == credential.secretVersion { return lastState }
                let answer = try await transport.credentialState(as: credential.bearer)
                try answer.validate()
                try readyForNetwork()
                guard try journal.read() == finished, answer.deviceID == credential.deviceID,
                      answer.memberID == credential.memberID, answer.secretVersion == credential.secretVersion,
                      answer.credentialProtocol == credential.credentialProtocol else { throw DuoJournalError.changed }
                return answer
            }
            guard old == nil || old?.phase == .abandoned || (role == .reconnectThrowaway && old?.active?.credential == replacing) else { throw DuoJournalError.changed }
            let capabilities = try await transport.recoveryCapabilities(); try capabilities.validate()
            try readyForNetwork()
            // Reload after capability negotiation: a privacy action may have changed the record.
            guard try journal.read() == old else { throw DuoJournalError.changed }
            let secret = try freshSecret(excluding: old?.active?.deviceSecret)
            var r = DuoRecoveryRecord(environment: journal.environment, installationID: old?.installationID ?? dependencies.random.uuid().uuidString.lowercased(), phase: .prepareReady)
            r.recordRevision = (old?.recordRevision ?? 0) + 1; r.identityGeneration = (old?.identityGeneration ?? 0) + 1
            if role == .reconnectThrowaway, old?.phase != .abandoned { r.active = old?.active; r.activeRole = old?.activeRole }
            r.pending = DuoRecoveryPending(kind: .mint, operationID: dependencies.random.uuid().uuidString.lowercased(), candidateSecret: secret, role: role, acceptedTermsVersion: dependencies.cache.acceptedTermsVersion, appVersion: dependencies.client.appVersion)
            try journal.writeMarker(r); try writeSentinel(r)
            try journal.replace(r, expectedRevision: old?.recordRevision); old = nil
            lastState = nil; lastConfirmedOperationID = nil
            let finished = try await reconcile(r)
            try readyForNetwork()
            guard finished.ordinaryCredential != nil, try journal.read() == finished,
                  lastConfirmedOperationID == r.pending?.operationID else { throw DuoJournalError.changed }
            return lastState
        } catch { note(error); return nil }
    }

    @MainActor private func beginRotation(_ r: DuoRecoveryRecord) async throws -> DuoRecoveryRecord {
        try readyForNetwork()
        guard let transport = dependencies.recoveryTransport, let active = r.active, active.secretVersion < Int(Int32.max), r.pending == nil else { throw DuoJournalError.invalid }
        let capabilities = try await transport.recoveryCapabilities(); try capabilities.validate(); try readyForNetwork()
        let secret = try freshSecret(excluding: active.deviceSecret)
        return try replace(r) {
            var pending = DuoRecoveryPending(kind: .rotation, operationID: dependencies.random.uuid().uuidString.lowercased(), candidateSecret: secret, role: .restore, acceptedTermsVersion: dependencies.cache.acceptedTermsVersion, appVersion: dependencies.client.appVersion)
            pending.reservedDeviceID = active.deviceID; pending.expectedMemberID = active.memberID; pending.expectedSecretVersion = active.secretVersion
            $0.pending = pending; $0.phase = .rotateReady
        }
    }
    private func freshSecret(excluding previous: String?) throws -> String {
        let bytes = dependencies.random.bytes(32)
        guard bytes.count == 32 else { throw DuoJournalError.invalid }
        let secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard DuoRecoveryWire.isSecret(secret), secret != previous else { throw DuoJournalError.invalid }; return secret
    }

    @MainActor private func reconcile(_ initial: DuoRecoveryRecord) async throws -> DuoRecoveryRecord {
        guard let transport = dependencies.recoveryTransport else { throw DuoJournalError.unavailable }
        var r = initial
        for _ in 0..<8 {
            guard r.intent == .use, let p = r.pending else { return r }
            // Local promotion is safe during suspension; it retains the newly committed proof
            // for deletion without granting ordinary traffic or clearing the Continue flag.
            if r.phase == .promotionPending { return try finishPromotion(r) }
            try readyForNetwork()
            guard dependencies.cache.acceptedTermsVersion >= p.acceptedTermsVersion else { throw DuoJournalError.unavailable }
            switch r.phase {
            case .prepareReady:
                let answer = try await transport.prepareDeviceIssuance(DuoRecoveryPrepareRequest(appVersion: p.appVersion, termsVersion: p.acceptedTermsVersion, deviceSecret: p.candidateSecret))
                try answer.validate(); try readyForNetwork()
                r = try replace(r) { $0.pending?.reservedDeviceID = answer.deviceID; $0.pending?.reservationExpiresAt = answer.expiresAt; $0.phase = .reservationSaved }
            case .reservationSaved:
                guard let candidate = p.candidate else { throw DuoJournalError.invalid }
                // Mark before obtaining a token or sending. A crash after this write is handled
                // by the candidate probe, even when the actual send never happened.
                r = try replace(r) { $0.pending?.commitMayHaveRun = true; $0.phase = .commitUncertain }
                let token = await dependencies.deviceCheck.token(); try readyForNetwork()
                guard try journal.read() == r else { throw DuoJournalError.changed }
                let answer = try await transport.commitDevice(DuoRecoveryCommitRequest(deviceID: candidate.deviceID, deviceCheckToken: token), as: candidate)
                r = try confirm(answer, record: r)
            case .commitUncertain:
                guard let candidate = p.candidate else { throw DuoJournalError.invalid }
                do { r = try confirm(try await transport.credentialState(as: candidate), record: r) }
                catch let error as DuoRecoveryError where error.code == .credentialRejected {
                    try readyForNetwork(); guard try journal.read() == r else { throw DuoJournalError.changed }
                    let token = await dependencies.deviceCheck.token(); try readyForNetwork()
                    guard try journal.read() == r else { throw DuoJournalError.changed }
                    r = try confirm(try await transport.commitDevice(DuoRecoveryCommitRequest(deviceID: candidate.deviceID, deviceCheckToken: token), as: candidate), record: r)
                }
            case .rotateReady:
                guard let active = r.active, let version = p.expectedSecretVersion else { throw DuoJournalError.invalid }
                r = try replace(r) { $0.pending?.commitMayHaveRun = true; $0.phase = .rotateUncertain }
                try readyForNetwork()
                r = try confirm(try await transport.rotateCredential(DuoRecoveryRotateRequest(expectedSecretVersion: version, nextDeviceSecret: p.candidateSecret), as: active.bearer), record: r)
            case .rotateUncertain:
                guard let candidate = p.candidate, let active = r.active, let version = p.expectedSecretVersion else { throw DuoJournalError.invalid }
                do { r = try confirm(try await transport.credentialState(as: candidate), record: r) }
                catch let error as DuoRecoveryError where error.code == .credentialRejected {
                    try readyForNetwork(); guard try journal.read() == r else { throw DuoJournalError.changed }
                    let old = try await transport.credentialState(as: active.bearer)
                    try old.validate()
                    guard old.deviceID == active.deviceID, old.memberID == active.memberID, old.secretVersion == version else { throw DuoJournalError.changed }
                    try readyForNetwork(); guard try journal.read() == r else { throw DuoJournalError.changed }
                    r = try confirm(try await transport.rotateCredential(DuoRecoveryRotateRequest(expectedSecretVersion: version, nextDeviceSecret: p.candidateSecret), as: active.bearer), record: r)
                }
            default: throw DuoJournalError.invalid
            }
        }
        throw DuoJournalError.invalid
    }
    @MainActor private func confirm(_ answer: DuoRecoveryCredentialState, record r: DuoRecoveryRecord) throws -> DuoRecoveryRecord {
        try answer.validate()
        guard let p = r.pending, answer.deviceID == p.reservedDeviceID, answer.credentialProtocol == "1.1",
              answer.secretVersion == (p.kind == .mint ? 1 : (p.expectedSecretVersion! + 1)),
              p.expectedMemberID.map({ $0 == answer.memberID }) ?? true else { throw DuoJournalError.invalid }
        let confirmed = DuoJournalCredential(DuoCredential(memberID: answer.memberID, deviceID: answer.deviceID, deviceSecret: p.candidateSecret, secretVersion: answer.secretVersion))
        let next = try replace(r) {
            $0.pending?.confirmed = confirmed; $0.active = confirmed; $0.phase = .promotionPending
            if p.kind == .mint { $0.activeRole = p.role == .reconnectThrowaway ? .reconnectThrowaway : .established }
            if p.kind == .rotation { $0.restoreRotationRequired = false }
            if !ordinaryAllowed { $0.access = .suspended }
        }
        lastState = answer; lastConfirmedOperationID = p.operationID; return next
    }
    @MainActor private func finishPromotion(_ r: DuoRecoveryRecord) throws -> DuoRecoveryRecord {
        // A later failure here only retries these writes. It cannot dispatch another CAS.
        guard try journal.read() == r else { throw DuoJournalError.changed }
        try journal.writeMirror(r); try journal.writeMarker(r); try writeSentinel(r)
        return try replace(r) {
            $0.pending = nil; $0.phase = .active; $0.mirrorWrittenRevision = r.recordRevision
            $0.access = ordinaryAllowed ? ($0.restoreConfirmationRequired ? .restoreConfirmationRequired : .eligible) : .suspended
        }
    }

    func continueAsRestored() async { await continueOnMain() }
    @MainActor private func continueOnMain() async {
        do {
            try readyForNetwork()
            guard let r = try journal.read(), r.restoreConfirmationRequired, !r.restoreRotationRequired, r.pending == nil, r.intent == .use else { return }
            let next = try replace(r) { $0.restoreConfirmationRequired = false; $0.access = .eligible }
            guard next.ordinaryCredential != nil else { throw DuoJournalError.invalid }
            let stillDisconnected = next.activeRole == .reconnectThrowaway && dependencies.host.duos.contains(where: { !$0.hasEnded })
            // Continue is durably answered even when the following hydration is offline. Leaving
            // the old prompt on screen would offer a button that can no longer change anything.
            dependencies.host.availability = stillDisconnected ? .disconnected : .available
            // The user has now chosen this identity; partner/name hydration is allowed only here.
            let epoch = dependencies.host.wipeEpoch
            let me = try await dependencies.transport.me()
            try readyForNetwork(); guard try journal.read() == next, dependencies.host.wipeEpoch == epoch else { return }
            let now = dependencies.clock.now
            dependencies.host.memberInfo = DuoMapping.member(me, now: now)
            for header in me.duos {
                guard let id = UUID(uuidString: header.id), !dependencies.cache.isCleared(id, now: now),
                      let duo = DuoMapping.duo(from: header, previous: dependencies.host.duo(id), now: now) else { continue }
                dependencies.host.upsert(DuoMapping.reseated(duo))
            }
            dependencies.host.availability = stillDisconnected ? .disconnected : .available
            if !stillDisconnected { dependencies.push?.reevaluate(.duoStarted) }
        } catch { note(error) }
    }

    /// Cleanup never asks for ordinary state, attestation or a fresh Apple token. Each cycle
    /// starts with the candidate and permits one old DELETE only after an exact rejection.
    @MainActor func deleteIdentity() async -> DuoRecoveryDeletion {
        do {
            try respectBackoff()
            guard let transport = dependencies.recoveryTransport, var r = try loadOrImport(), r.phase != .abandoned else { return .failed }
            if r.intent == .use {
                r = try replace(r) {
                    if $0.phase == .promotionPending { $0.pending = nil }
                    $0.intent = $0.pending?.kind == .mint ? .cancelSetup : .deleteIdentity
                    $0.access = .cleanupOnly; $0.phase = .cleanupPending
                }
            }
            guard r.phase == .cleanupPending else { return .failed }
            let request = DuoWireDeleteMeRequest(deviceCheckToken: nil)
            let key = DuoIdempotencyKey.make(random: dependencies.random)
            var serverConfirmed = true
            if let p = r.pending, p.kind == .mint {
                if let candidate = p.candidate {
                    var committed = false
                    do {
                        let cancelled = try await transport.cancelDeviceIssuance(deviceID: candidate.deviceID, as: candidate)
                        try cancelled.validate(); guard cancelled.deviceID == candidate.deviceID, try journal.read() == r else { throw DuoJournalError.changed }
                        committed = cancelled.outcome == .committed
                    } catch let error as DuoRecoveryError where error.code == .issuanceUnavailable {
                        // Nothing this phone holds can cancel or delete it any more, and a 410 is
                        // no proof it is gone (D65). Finish the local wipe and say only that, unless
                        // a Reconnect's displaced identity is deleted below: that member holds the
                        // person's data, and its confirmed delete is the answer, as on a retry
                        // that starts from the checkpoint.
                        guard try journal.read() == r else { throw DuoJournalError.changed }
                        serverConfirmed = r.active != nil
                    }
                    if committed {
                        try respectBackoff()
                        try await transport.deleteMe(as: candidate, request, key: key)
                    }
                } else {
                    // No reservation was durably returned, so no commit was dispatchable. A
                    // late preparation response can allocate only an expiring reservation.
                    guard !p.commitMayHaveRun else { throw DuoJournalError.invalid }
                }
                if let old = r.active {
                    // Reconnect may still own the displaced identity's exit credential. Retire
                    // the candidate first, then durably checkpoint that terminal step before
                    // trying the old member. A restart must not need an expired reservation to
                    // prove the already completed candidate cleanup again.
                    r = try replace(r) {
                        $0.abandonedOperationID = p.operationID; $0.pending = nil; $0.intent = .deleteIdentity
                    }
                    try respectBackoff()
                    try await transport.deleteMe(as: old.bearer, request, key: DuoIdempotencyKey.make(random: dependencies.random))
                }
            } else if let p = r.pending, p.kind == .rotation, let candidate = p.candidate {
                do { try await transport.deleteMe(as: candidate, request, key: key) }
                catch let error as DuoRecoveryError where error.code == .credentialRejected {
                    guard try journal.read() == r, let old = r.active else { throw DuoJournalError.changed }
                    try respectBackoff()
                    try await transport.deleteMe(as: old.bearer, request, key: key)
                }
            } else if let active = r.active { try await transport.deleteMe(as: active.bearer, request, key: key) }
            else { throw DuoJournalError.invalid }
            guard try journal.read() == r else { throw DuoJournalError.changed }
            try journal.abandon(random: dependencies.random); rememberPresence(nil)
            return serverConfirmed ? .deleted : .removedFromThisPhone
        } catch { note(error); return .failed }
    }
    @MainActor func establishRole() throws {
        guard let r = try journal.read(), r.pending == nil, let active = r.active else { throw DuoJournalError.changed }
        try store(active.credential)
    }
    @MainActor private func note(_ error: Error) {
        if let recovery = error as? DuoRecoveryError {
            if let delay = recovery.context?.retryAfter, delay >= 0, delay <= Int(Int32.max) {
                let now = dependencies.clock.now
                let deadline = now.addingTimeInterval(TimeInterval(delay))
                retryNotBefore = deadline
                // The in-memory deadline remains restrictive if storage rejects this write;
                // every following dispatch retries the verified save first.
                try? journal.saveRetryDeadline(deadline, now: now)
            }
            switch recovery.code {
            case .banned: dependencies.host.availability = .banned
            case .upgradeRequired: dependencies.host.availability = .upgradeRequired
            case .termsRequired: dependencies.host.needsTerms = true
            default: break
            }
        }
        if !(error is CancellationError) { dependencies.host.sheetError = DuoUserMessage.generic }
    }
}
#endif
