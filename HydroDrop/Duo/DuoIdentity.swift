#if DUO_V2
import Foundation

/// Who this phone is to the Duo server (final design §3.1 to §3.4): the credential in the
/// Keychain, the install marker beside it, two small files of the install's own (its first day
/// and whether its restore question was settled), and the launch sequence that tells a phone's
/// own credential from one that arrived by restore or outlived a reinstall. Anonymous: no
/// sign-in, no email.
///
/// The API client reads `credential` from whatever thread it runs on, so everything here is
/// behind one lock. The launch sequence runs on the main actor, where the store it writes to
/// lives, and runs once per launch however many services ask for it at once.
///
/// Consent (§3.1): with no credential nothing here writes, attests or sends, ever. A launch only
/// reads the Keychain; the first credential comes from a Create, Join or Reconnect tap
/// (`store`, called by the joining service), never from here.
final class DuoIdentity: DuoIdentityProviding, @unchecked Sendable {
    /// Starts something that keeps the app running for a little while if it is sent to the
    /// background, and returns the call that ends it.
    typealias BackgroundHold = @Sendable (_ reason: String) -> @Sendable () -> Void
    /// Marks a file as one no backup may carry.
    typealias BackupExclusion = @Sendable (_ file: URL) throws -> Void

    private let dependencies: DuoDependencies
    private let installFile: URL
    private let settledFile: URL
    private let holdInBackground: BackgroundHold
    private let excludeFromBackup: BackupExclusion
    private let lock = NSLock()
    private var state = State()

    private struct State {
        /// Nil until the Keychain has been read; then the copy every caller is served, until
        /// `discard()`. A read that fails after a good one is never asked: an identity that
        /// exists must not read as missing for a moment (a nil credential makes a bearer call
        /// fail as `unauthenticated` before it leaves the phone). An unreadable Keychain before
        /// the first good read (the first unlock after a restart) leaves it nil, so the next
        /// read tries again rather than remembering "no credential" and letting a tap mint a
        /// second identity beside the real one.
        var credential: DuoCredential??
        /// A new secret (a rotate's, or one handed to `replaceSecret`) is in `credential` but the
        /// Keychain has not taken it, or the marker after it. The next call retries the save and
        /// only the save: the server already answers the old secret `device_revoked`, so a
        /// second rotate from here would be sent with a secret that no longer works, or would
        /// leave the Keychain two behind.
        var secretUnsaved = false
        /// The launch answer, once it is one. `.unavailable` is never kept: it is retried by
        /// the next call. Follows the identity: `store` and `continueAsRestored` make it
        /// `.ready` and `discard` makes it `.none`.
        var launch: DuoIdentityLaunch?
        /// The launch being worked out, so callers that arrive while it runs wait for the same
        /// answer instead of each sending a request.
        var running: Task<DuoIdentityLaunch, Never>?
        /// Moves whenever the credential changes under a launch or a Continue (`store`,
        /// `discard`, `replaceSecret`, Continue itself). Work that finds it moved drops what it
        /// was about to write: its answer is about a credential that is gone or replaced.
        var generation = 0
        /// The `GET /me` a restore question was asked from, kept in memory until Continue. A
        /// relaunch has no copy and no settled file, so it reads `GET /me` and asks again.
        var restoreAnswer: DuoWireGetMeResponse?
        var installDay: String?
    }

    private enum Presence {
        case present
        case absent
        /// The Keychain answered with an error: not known either way.
        case unreadable
    }

    @MainActor convenience init(dependencies: DuoDependencies) {
        self.init(dependencies: dependencies, directory: Self.defaultDirectory)
    }

    /// `directory` holds `duo.install` and `duo.settled`: Application Support in the app, a
    /// throwaway folder in a test. Nothing is read or written here.
    @MainActor init(dependencies: DuoDependencies, directory: URL,
                    holdInBackground: @escaping BackgroundHold = DuoIdentity.expiringActivity,
                    excludeFromBackup: @escaping BackupExclusion = DuoIdentity.markExcludedFromBackup) {
        self.dependencies = dependencies
        installFile = directory.appendingPathComponent("duo.install", isDirectory: false)
        settledFile = directory.appendingPathComponent("duo.settled", isDirectory: false)
        self.holdInBackground = holdInBackground
        self.excludeFromBackup = excludeFromBackup
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// `performExpiringActivity`: its block runs on a queue of its own and the activity lasts
    /// while the block does, so the block waits until the work is over, or until the system
    /// says the time is up, or 30 seconds at most.
    static let expiringActivity: BackgroundHold = { reason in
        let finished = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: expiringActivityBlock(finished, limit: 30))
        return { finished.signal() }
    }

    /// The block itself, apart so a test can drive it. iOS calls it once with `expired` false and
    /// the activity lasts while that call waits; if it needs the time back it calls it again
    /// with `expired` true, from another thread, and that call has to end the first one's wait.
    static func expiringActivityBlock(_ finished: DispatchSemaphore, limit: TimeInterval) -> @Sendable (Bool) -> Void {
        { expired in
            if expired { finished.signal() } else { _ = finished.wait(timeout: .now() + limit) }
        }
    }

    static let markExcludedFromBackup: BackupExclusion = { file in
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = file
        try target.setResourceValues(excluded)
    }

    // MARK: - The credential

    var credential: DuoCredential? {
        lock.lock(); defer { lock.unlock() }
        return loadedCredential()
    }

    /// Writes a credential just minted or recovered, the install marker if there is none, and
    /// last the settled file: a freshly minted identity has no restore question to ask.
    ///
    /// The marker goes before the credential. A marker left without a credential (the process
    /// killed between the two, or the credential refused) decides nothing: with no credential
    /// the launch is `.none`. The other order would leave a credential without its marker, which
    /// the next launch takes for a restore and rotates. A marker that cannot be written is not an
    /// error here, but it does cost that: with the credential and no marker, the next launch
    /// rotates once, on the person's own phone, before it settles. The settled file is what lets
    /// a launch resume without a rotate, and only when the marker is there too. A credential that
    /// cannot be written is an error: it is not kept in memory either, so the joining service
    /// sees the failure and no identity lives only until the app is closed.
    ///
    /// Called on the main actor in production: its callers (the joining and exit services, and
    /// `noteFailure`) all run there. The identity keeps its own state (the credential, the marker,
    /// the settled file) safe from any thread, but not the store's: what a Continue had already
    /// written to it (the member record, the duos it seeded, the availability) is the caller's to
    /// reset, through the exit service's `resetLocalState()`. So a `discard()` from another thread
    /// in the middle of a Continue stops the Continue and leaves the store's state to its caller.
    func store(_ credential: DuoCredential) throws {
        lock.lock(); defer { lock.unlock() }
        let secrets = dependencies.secrets
        if markerPresence() != .present { try? secrets.writeInstallMarker(random: dependencies.random) }
        try secrets.save(credential)
        state.credential = .some(credential)
        state.secretUnsaved = false
        state.restoreAnswer = nil
        state.launch = DuoIdentityLaunch.ready
        state.generation += 1
        writeSettledFile()
    }

    /// A new secret for the credential this phone holds. Nothing is expected to call it: the
    /// launch's own rotate is the one way a secret changes, through the same locked path, and a
    /// second way to change the secret must not appear. It is kept to the protocol's shape and
    /// made safe rather than left as a door.
    ///
    /// It takes the one path a rotate's answer takes: kept in memory at once (the server already
    /// answers the old secret `device_revoked`), then saved with the marker; a save the Keychain
    /// refuses throws and is retried by the next `prepare()`, which never rotates again for it.
    /// It moves the generation, so a launch whose request went out with the old secret drops its
    /// answer. It refuses a phone with no install marker, a credential restored from another
    /// phone: saving there writes the marker, which would turn the restore's one rotate (the
    /// rotate that locks the copy on the other phone out) into an unsettled launch that never
    /// rotates, and leave that copy working.
    func replaceSecret(_ secret: String, version: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard loadedCredential() != nil else { throw DuoIdentityError.noCredential }
        guard markerPresence() == .present else { throw DuoIdentityError.noInstallMarker }
        state.generation += 1
        try takeNewSecretLocked(secret, version: version)
    }

    /// Forgets the identity: the credential, the install marker, the settled file and the
    /// device's attestation key, the last two items of it deleted here and now from whatever
    /// thread this runs on (the Keychain is safe to call from any). Link secrets are per duo and
    /// the exit service's to take; the install day is about this install, not the identity. The
    /// credential is forgotten for this process even if the Keychain refuses the delete: it is
    /// never read back.
    ///
    /// Called on the main actor in production: its callers (the joining and exit services, and
    /// `noteFailure`) all run there. The identity keeps its own state (the credential, the marker,
    /// the settled file) safe from any thread, but not the store's: what a Continue had already
    /// written to it (the member record, the duos it seeded, the availability) is the caller's to
    /// reset, through the exit service's `resetLocalState()`. So a `discard()` from another thread
    /// in the middle of a Continue stops the Continue and leaves the store's state to its caller.
    func discard() {
        lock.lock(); defer { lock.unlock() }
        let deviceID = loadedCredential()?.deviceID
        let secrets = dependencies.secrets
        try? secrets.deleteCredential()
        try? secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.installMarkerAccount)
        if let deviceID { try? secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: deviceID)) }
        try? secrets.store.delete(service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount)
        try? FileManager.default.removeItem(at: settledFile)
        state.credential = .some(nil)
        state.secretUnsaved = false
        state.restoreAnswer = nil
        state.launch = DuoIdentityLaunch.none
        state.generation += 1
    }

    // MARK: - The install day

    /// The local date of this install's first Duo read, kept as text in `duo.install`, which
    /// is excluded from backup so a restore or a reinstall starts it again from today (§3.2,
    /// §10.5). It is the day as written, never a file date: reading a file's dates is a
    /// required-reason API, and the file would carry its restore date anyway. A missing,
    /// unreadable or malformed file is written again with today.
    var installDay: String {
        lock.lock(); defer { lock.unlock() }
        if let day = state.installDay { return day }
        let day = readInstallDay() ?? writeInstallDay()
        state.installDay = day
        return day
    }

    private func readInstallDay() -> String? {
        guard let data = try? Data(contentsOf: installFile), let text = String(data: data, encoding: .utf8) else { return nil }
        let day = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DuoStreak.isDayKey(day) ? day : nil
    }

    /// Today, written down if it can be. If it cannot (before the first unlock, a full disk) it
    /// still answers for this launch, and the next launch tries again. A file that could not be
    /// kept out of backups is removed rather than left: carried to another phone by a restore,
    /// it would date that phone's install to this one's (§10.5).
    private func writeInstallDay() -> String {
        let today = dependencies.clock.today
        writeExcludedFromBackup(Data(today.utf8), to: installFile)
        return today
    }

    /// Writes `data` and marks the file as one no backup carries; a file that cannot be marked is
    /// removed, so whatever it says can never reach another phone.
    private func writeExcludedFromBackup(_ data: Data, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return
        }
        do {
            try excludeFromBackup(file)
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Whether this install settled its restore question

    /// `duo.settled` says this install has answered for the credential it holds: it minted it,
    /// or it asked "Continue as <name>?" and was told yes, or `GET /me` gave it nothing to ask.
    /// Excluded from backup and gone with the app, so neither a restore nor a reinstall brings
    /// it, and that is how a same-phone reinstall (whose Keychain still holds the credential and
    /// the marker) is told from an ordinary launch without a rotate. Only its existence is read,
    /// which is metadata and works before the first unlock.
    private var isSettled: Bool { FileManager.default.fileExists(atPath: settledFile.path) }

    /// Not settled when the file cannot be written or kept out of backups: the next launch then
    /// reads `GET /me` and settles or asks, which costs a request and never a rotate, while a copy
    /// that a backup could carry would let a restored phone skip the question.
    private func writeSettledFile() {
        writeExcludedFromBackup(Data(), to: settledFile)
    }

    // MARK: - The launch sequence (§3.4)

    /// The launch sequence, once per launch: `.none` with no credential; `.ready` for an
    /// ordinary launch, with nothing sent; one rotate, then `GET /me`, for a credential that
    /// came from another phone; and `GET /me` alone for a credential and marker on an install
    /// that never settled.
    ///
    /// That last case sends a request at once, under the bearer of whoever held the credential:
    /// a phone sold with the app deleted but not erased, or the person's own reinstall. On the
    /// first `prepare()` of such a launch, `GET /me` goes out as the previous owner, and it moves
    /// their `last_seen_at`, which keeps their partner's reconnect refused for 72 hours and their
    /// device seat taken. So callers ask for `prepare()` only with a duo cached or the Duo screen
    /// opening (FD §3.4 step 2), never at app launch, on foreground or from a background task with
    /// nothing cached.
    func prepare() async -> DuoIdentityLaunch {
        switch answerOrRunningLaunch() {
        case .answered(let answer): return answer
        case .running(let task): return await task.value
        }
    }

    private enum LaunchProgress {
        case answered(DuoIdentityLaunch)
        case running(Task<DuoIdentityLaunch, Never>)
    }

    /// The answer if there is one; otherwise the launch already running, or a new one. Under the
    /// lock, so two callers can never both start one. A secret the Keychain has not taken yet is
    /// never left behind a kept answer: the next call runs, and saves it.
    private func answerOrRunningLaunch() -> LaunchProgress {
        lock.lock(); defer { lock.unlock() }
        if let answer = state.launch, !state.secretUnsaved { return .answered(answer) }
        if let running = state.running { return .running(running) }
        let generation = state.generation
        let task = Task { @MainActor in await self.runLaunch(generation: generation) }
        state.running = task
        return .running(task)
    }

    @MainActor private func runLaunch(generation: Int) async -> DuoIdentityLaunch {
        let answer = await launch(generation: generation)
        return finishLaunch(answer, generation: generation)
    }

    private func finishLaunch(_ answer: DuoIdentityLaunch, generation: Int) -> DuoIdentityLaunch {
        lock.lock(); defer { lock.unlock() }
        state.running = nil
        // The identity changed while this ran (a tap stored a new one, "Start fresh" discarded
        // it, or this launch's own 401 did): what that change made the answer is the answer.
        guard state.generation == generation else { return state.launch ?? .unavailable }
        if answer != .unavailable { state.launch = answer }
        return answer
    }

    @MainActor private func launch(generation: Int) async -> DuoIdentityLaunch {
        let epoch = dependencies.host.wipeEpoch
        // A new secret this process holds and the Keychain has not taken: save it, never rotate
        // again. Then the launch is decided from what the Keychain and the files now say.
        if hasUnsavedSecret(), !retryUnsavedSecret(generation: generation) { return .unavailable }
        guard let found = credentialForLaunch() else { return .unavailable }
        guard let credential = found else {
            noteDuosWithoutAnIdentity()
            return .none
        }
        let marker = markerPresence()
        if marker == .unreadable { return .unavailable }

        switch DuoLaunchDecision.decide(hasCredential: true, hasMarker: marker == .present, isSettled: isSettled) {
        case .none: return .none
        case .normal: return .ready
        case .restored: return await restore(credential, generation: generation, epoch: epoch)
        case .unsettled: return await readAndSettle(generation: generation, epoch: epoch)
        }
    }

    /// No credential, yet the cache holds a live duo: an unencrypted backup or a device transfer
    /// brought the App Group's defaults without the Keychain item. Nothing can be sent for those
    /// duos, so the person is offered what a disconnected phone is, "I had a duo" (a reconnect)
    /// or Start fresh. Only for a credential the Keychain says is absent, never for one it could
    /// not read; nothing is sent or written.
    @MainActor private func noteDuosWithoutAnIdentity() {
        let host = dependencies.host
        guard host.duos.contains(where: { !$0.hasEnded }) else { return }
        host.availability = .disconnected
    }

    /// A credential without its marker: it came from another phone. The settled file goes
    /// first, so a copy of it can never pass for this phone's, and a copy that cannot be removed
    /// stops the restore before it starts (the next launch would otherwise take it for settled
    /// and skip the question). Then one rotate, so any other holder of the same secret (a drawer
    /// phone, a cloned backup) is locked out at once, the new secret saved and the marker
    /// written straight after it (§3.4's order: rotate, marker, `GET /me`). From then on this
    /// phone is an unsettled one: whatever happens to `GET /me` or the question, a relaunch
    /// reads and asks again and never rotates again, since a second rotate whose answer was lost
    /// would leave the phone holding a revoked secret.
    @MainActor private func restore(_ credential: DuoCredential, generation: Int, epoch: Int) async -> DuoIdentityLaunch {
        try? FileManager.default.removeItem(at: settledFile)
        guard !isSettled else { return .unavailable }
        switch await rotateAndSave(credential, generation: generation) {
        case .saved:
            dependencies.noteSuccess()
            return await readAndSettle(generation: generation, epoch: epoch)
        case .failed(let error):
            return failed(error, generation: generation)
        case .dropped, .unsaved:
            return .unavailable
        }
    }

    private enum RotationOutcome {
        case saved
        /// The identity changed while the rotate was out: its answer was not kept.
        case dropped
        /// The Keychain refused the new secret or the marker; the secret is held in memory and
        /// the next call saves it.
        case unsaved
        case failed(Error)
    }

    /// The rotate and the save of its answer, held against the app being suspended in between:
    /// an answer the server has given and this phone has not kept is the one loss that cannot be
    /// undone here.
    ///
    /// The rotate is sent as `credential`, the one the launch decided on, never as whatever the
    /// identity holds by the time the request leaves: a Create, Join or Reconnect that stored a
    /// new credential in that gap used to have its own secret rotated by a call meant for the
    /// restored one, and was locked out of the identity it was now using. And it is not sent at
    /// all if the identity has changed since the decision (a `store` or a `discard` from another
    /// thread, or one that ran while this waited for the hold): the decision was about a
    /// credential this phone no longer uses.
    @MainActor private func rotateAndSave(_ credential: DuoCredential, generation: Int) async -> RotationOutcome {
        let release = holdInBackground("Saving this phone's new Duo key")
        defer { release() }
        let rotated: DuoWireRotateResponse
        guard isCurrent(generation) else { return .dropped }
        do {
            rotated = try await dependencies.transport.rotate(as: credential)
        } catch {
            return .failed(error)
        }
        do {
            return try applyRotation(rotated, toDevice: credential.deviceID, generation: generation) ? .saved : .dropped
        } catch {
            return .unsaved
        }
    }

    /// Reads `GET /me` and either asks the restore question or settles. Used after the one
    /// rotate of a restore, and on its own for an install that holds a credential and its marker
    /// but never settled (a same-phone reinstall, or a restore interrupted after its rotate).
    @MainActor private func readAndSettle(generation: Int, epoch: Int) async -> DuoIdentityLaunch {
        let host = dependencies.host
        let me: DuoWireGetMeResponse
        do {
            me = try await dependencies.transport.me()
        } catch {
            return failed(error, generation: generation)
        }
        // A wipe while a request was out (Delete my Duo data, "Start fresh") must not get the
        // duos and the partner's name `GET /me` held written back; nor may an answer about a
        // credential that was replaced or discarded meanwhile.
        guard isCurrent(generation), host.wipeEpoch == epoch else { return .unavailable }
        dependencies.noteSuccess()

        let now = dependencies.clock.now
        let offered = offerable(me, now: now)
        if let prompt = DuoLaunchDecision.restorePrompt(from: offered, cachedDuoCount: host.duos.count) {
            // The member record (the name, the Support ID, the devices) is not written until the
            // question is answered: on a phone sold with the app deleted, it is the seller's.
            guard remember(offered, generation: generation) else { return .unavailable }
            host.availability = .needsRestoreChoice(prompt)
            return .needsRestoreChoice(prompt)
        }
        settle(offered, now: now, generation: generation)
        return .ready
    }

    /// Nothing to ask (no duo listed, or this phone already holds duos, which a backup that
    /// carried the cache brings): the member record, then the listed duos this phone lacks, and
    /// the ones it already held marked to be read whole before anything is written for them,
    /// since they were last read by whatever phone the backup came from, as after a reconnect
    /// (§3.4 step 4, §10.3, vector KV11). The marker and the settled file come last, so a
    /// process killed part way through has settled nothing and the next launch does it all again.
    @MainActor private func settle(_ me: DuoWireGetMeResponse, now: Date, generation: Int) {
        let host = dependencies.host
        host.memberInfo = DuoMapping.member(me, now: now)
        for duo in host.duos where !duo.hasEnded {
            host.update(duo.id) { $0 = DuoMapping.reseated($0) }
        }
        for header in me.duos {
            guard let id = UUID(uuidString: header.id), host.duo(id) == nil,
                  let duo = DuoMapping.duo(from: header, previous: nil, now: now) else { continue }
            host.upsert(duo)
        }
        _ = settleInKeychainAndFile(generation: generation)
    }

    /// Every failure is noted once, where every service notes them. A 401 `unauthenticated`
    /// (the identity was deleted from another copy) forgets the identity; a `device_revoked`
    /// (another phone took it over) is the disconnected question; anything else (offline,
    /// maintenance, banned, an update needed) is not an answer yet, and the next call starts
    /// again from where this one stopped.
    @MainActor private func failed(_ error: Error, generation: Int) -> DuoIdentityLaunch {
        // An answer about a credential that is no longer this phone's says nothing about the
        // one it holds now: acting on a 401 for it would discard the new one. It still goes in
        // Diagnostics, as `noteFailure` would have put it there, without being acted on.
        guard isCurrent(generation) else {
            dependencies.host.diagnostics.record(error, duoID: nil, now: dependencies.clock.now)
            return .unavailable
        }
        switch dependencies.noteFailure(error) {
        case .reidentify:
            discard()
            // `noteFailure` deletes the link secrets of the duos in the cache, but a restore
            // brings the Keychain without them (an empty cache, or one the backup left behind),
            // and their `k.<duo>` items would stay for good. Once the server has forgotten the
            // identity nothing under Duo's service belongs to a live one; the age refusal is
            // under a service of its own and stays (D60). The generation check above means a
            // newer identity is never wiped by an answer about an older one.
            try? dependencies.secrets.deleteEverything()
            return .none
        case .disconnected:
            dependencies.host.availability = .disconnected
            return .disconnected
        default:
            return .unavailable
        }
    }

    // MARK: - Continue

    /// "Continue" on the restore question: the member record and the duos `GET /me` listed are
    /// written, each duo still to be read whole before this phone writes for it (`syncedOnce`
    /// false, §10.3), the restore is settled (the settled file last), and the launch answer is
    /// `.ready`, so whatever was waiting on it goes on. "Not me, start fresh" is the exit
    /// service's `startFresh`, which discards the identity. Every step stops if the identity was
    /// discarded or replaced meanwhile (`discard()` may run on another thread), so a Start fresh
    /// in the middle leaves no marker, no settled file and no `.ready` behind.
    func continueAsRestored() async {
        await continueOnMain()
    }

    @MainActor private func continueOnMain() {
        guard let taken = takeRestoreAnswer() else { return }
        let (answer, generation) = taken
        let host = dependencies.host
        let now = dependencies.clock.now
        guard isCurrent(generation) else { return }
        host.memberInfo = DuoMapping.member(answer, now: now)
        for header in answer.duos {
            guard isCurrent(generation) else { return }
            guard let id = UUID(uuidString: header.id), host.duo(id) == nil, !dependencies.cache.isCleared(id, now: now),
                  let duo = DuoMapping.duo(from: header, previous: nil, now: now) else { continue }
            host.upsert(duo)
        }
        guard settleInKeychainAndFile(generation: generation, andMarkReady: true) else { return }
        host.availability = .available
        // The push service's launch upload stopped at the question; with live duos on the
        // phone there is now a reason to hold a token, as after a join or a reconnect.
        dependencies.push?.reevaluate(.duoStarted)
    }

    // MARK: - Plumbing

    /// What the launch decides from: `.some(nil)` for no credential, nil for a Keychain that
    /// could not be read (not known, so not an answer).
    private func credentialForLaunch() -> DuoCredential?? {
        lock.lock(); defer { lock.unlock() }
        return loadedCredentialStrictly()
    }

    /// The credential, read from the Keychain the first time. Called with the lock held.
    private func loadedCredential() -> DuoCredential? {
        loadedCredentialStrictly() ?? nil
    }

    /// `.some(nil)` for no credential and nil for a Keychain that could not be read. Called
    /// with the lock held. Once known, the answer is served from memory and the Keychain is not
    /// read again.
    private func loadedCredentialStrictly() -> DuoCredential?? {
        if let known = state.credential { return known }
        let data: Data?
        do {
            data = try dependencies.secrets.store.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount)
        } catch {
            return nil
        }
        // Bytes that are not a credential are no credential: nothing can be sent with them,
        // and the next `store` writes over them.
        let credential = data.flatMap { try? JSONDecoder().decode(DuoCredential.self, from: $0) }
        state.credential = .some(credential)
        return .some(credential)
    }

    private func markerPresence() -> Presence {
        do {
            let marker = try dependencies.secrets.store.read(service: DuoSecrets.service, account: DuoSecrets.installMarkerAccount)
            return marker == nil ? .absent : .present
        } catch {
            return .unreadable
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.generation == generation
    }

    private func hasUnsavedSecret() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.secretUnsaved
    }

    /// A rotate's answer, but only into the credential the rotate was asked for: if the identity
    /// was discarded or replaced while the rotate was out, writing it would bring a forgotten
    /// credential back. False when the answer was dropped; throws, with the secret held in
    /// memory, when the Keychain refused it.
    private func applyRotation(_ rotated: DuoWireRotateResponse, toDevice deviceID: String, generation: Int) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.generation == generation, let credential = loadedCredential(), credential.deviceID == deviceID else { return false }
        try takeNewSecretLocked(rotated.deviceSecret, version: rotated.secretVersion)
        return true
    }

    /// The one way a secret changes: into memory first, marked unsaved, then the save and the
    /// marker (in that order: a marker written before a secret the Keychain then refused would
    /// make the next launch read `GET /me` with the revoked old secret). Called with the lock held.
    private func takeNewSecretLocked(_ secret: String, version: Int) throws {
        guard var credential = loadedCredential() else { throw DuoIdentityError.noCredential }
        credential.deviceSecret = secret
        credential.secretVersion = version
        state.credential = .some(credential)
        state.secretUnsaved = true
        try saveSecretLocked(credential)
    }

    /// The save alone, again, for a secret the Keychain refused last time. Held against
    /// suspension like the first attempt.
    private func retryUnsavedSecret(generation: Int) -> Bool {
        let release = holdInBackground("Saving this phone's new Duo key")
        defer { release() }
        lock.lock(); defer { lock.unlock() }
        guard state.generation == generation, state.secretUnsaved, let credential = loadedCredential() else { return false }
        do {
            try saveSecretLocked(credential)
            return true
        } catch {
            return false
        }
    }

    /// Called with the lock held.
    private func saveSecretLocked(_ credential: DuoCredential) throws {
        try dependencies.secrets.save(credential)
        if markerPresence() != .present { try dependencies.secrets.writeInstallMarker(random: dependencies.random) }
        state.secretUnsaved = false
    }

    private func remember(_ answer: DuoWireGetMeResponse, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.generation == generation else { return false }
        state.restoreAnswer = answer
        return true
    }

    /// The remembered answer, once, for a Continue, with the generation it belongs to: nothing
    /// if there was no question, or the identity it was about has gone.
    private func takeRestoreAnswer() -> (DuoWireGetMeResponse, Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let answer = state.restoreAnswer, loadedCredential() != nil else { return nil }
        state.restoreAnswer = nil
        return (answer, state.generation)
    }

    /// The marker if it is somehow missing, then the settled file, last, and for a Continue the
    /// launch answer: all under the lock, and only while the identity is the one the work began
    /// with, so a `discard()` from another thread lands either wholly before (and this writes
    /// nothing) or wholly after (and removes what this wrote).
    private func settleInKeychainAndFile(generation: Int, andMarkReady markReady: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.generation == generation else { return false }
        if markerPresence() != .present { try? dependencies.secrets.writeInstallMarker(random: dependencies.random) }
        writeSettledFile()
        if markReady {
            state.launch = DuoIdentityLaunch.ready
            state.generation += 1
        }
        return true
    }

    /// `GET /me` with the duos the person cleared taken out (a Clear is local only, §12.2) and
    /// any whose id this build cannot hold, so neither is offered nor seeded.
    @MainActor private func offerable(_ me: DuoWireGetMeResponse, now: Date) -> DuoWireGetMeResponse {
        var offered = me
        offered.duos = me.duos.filter { header in
            guard let id = UUID(uuidString: header.id) else { return false }
            return !dependencies.cache.isCleared(id, now: now)
        }
        return offered
    }
}

enum DuoIdentityError: Error, Equatable {
    /// `replaceSecret` with no credential to put the secret in.
    case noCredential
    /// `replaceSecret` on a phone with no install marker: a credential restored from another phone,
    /// whose launch must still make its one rotate.
    case noInstallMarker
}
#endif
