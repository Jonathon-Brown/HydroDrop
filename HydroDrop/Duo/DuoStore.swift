#if DUO_V2
import Foundation
import SwiftUI
import WidgetKit

/// The duos this phone is part of, and everything the Duo screen draws them from.
///
/// Views read this and nothing below it. It holds the state, saves it and tells the widget;
/// everything it *does* it asks of a service (`DuoServices.swift`), so it carries no network
/// code, no Keychain and no notification code, and a view's tests can build one with no
/// services at all. Final design §14: the public surface `DuoStore` had before, plus block,
/// delete, reconnect, link, clear and diagnostics.
@MainActor
final class DuoStore: ObservableObject, DuoHost {
    /// The one the app uses, wired by `DuoComposition`. Replaced in a test by building a
    /// store of one's own, never by changing this.
    static let shared: DuoStore = DuoComposition.makeLiveStore()

    // MARK: - What the screen is drawn from

    @Published private(set) var duos: [DuoState]
    @Published var availability: DuoAvailability = .unknown
    /// Something worth telling the person once, in an alert.
    @Published var notice: String?
    /// The same, for the setup and join sheets, which say it in place.
    @Published var sheetError: String?
    /// Starting, joining, leaving or deleting is under way.
    @Published var isWorking = false
    /// The last week of the log, as of the last time it changed. Published because my own
    /// side of every card is drawn from it.
    @Published var latest: DuoLogSummary?
    /// What `GET /me` last said. Saved like the two below, so the Support ID, the tier and the
    /// nudge limit are known at launch before (or without) the next fetch, and the sync engine
    /// asks for `GET /me` only when it is stale rather than on every launch.
    @Published var memberInfo: DuoMemberInfo? {
        didSet { if memberInfo != oldValue { cache.saveMember(memberInfo) } }
    }
    /// An invite that has been received and is waiting for a name and a yes.
    @Published var pendingInvite: DuoPendingInvite? {
        didSet { if pendingInvite != oldValue { cache.savePendingInvite(pendingInvite) } }
    }
    @Published var diagnostics: DuoDiagnostics {
        didSet { if diagnostics != oldValue { cache.saveDiagnostics(diagnostics) } }
    }
    /// True after `GET /me` showed a device this phone had not been told about (D45).
    @Published var newDeviceNotice = false
    /// Publishes changes to the identity's memory snapshot without making rendering read Keychain.
    @Published private var lastObservedIdentityPresence = false
    /// Only a successful server response records this; both Today and Settings read the same set.
    @Published private(set) var blockedDuoIDs: Set<UUID> {
        didSet { if blockedDuoIDs != oldValue { cache.saveBlockedDuoIDs(blockedDuoIDs) } }
    }
    @Published var needsTerms = false
    /// What the one `DELETE /me` sent at a refusal came to (decision a), for the refusal screen.
    /// Nil when none was sent: no identity, or one nobody on this phone has said is theirs.
    enum RefusalDeletion: Equatable { case deleting, deleted, removedFromThisPhone, failed }
    @Published private(set) var refusalDeletion: RefusalDeletion?
    /// That request's work, so a test can wait for it.
    private(set) var refusalDeletionTask: Task<Void, Never>?
    @Published private(set) var ageStatus: DuoAgeStatus
    @Published private(set) var ageCheckUnavailable = false
    @Published private(set) var acceptedTermsVersion: Int
    /// The Duo notifications toggle (§9.6). Turning it off changes what is uploaded, not the token.
    @Published var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            cache.notificationsEnabled = notificationsEnabled
            if !notificationsEnabled { dependencies?.announcer?.removeAllPending() }
            dependencies?.push?.reevaluate(.toggleChanged)
        }
    }
    /// What this person typed as their own name, kept so the next sheet starts from it.
    @Published var myDisplayName: String {
        didSet { if myDisplayName != oldValue { cache.myDisplayName = myDisplayName } }
    }

    /// Counts the times everything was forgotten. A service that sends a request reads it first
    /// and compares it when the answer comes back, and drops the answer if it moved: otherwise a
    /// `GET /me` that was in flight when Delete my Duo data ran would write a duo, and its
    /// partner's name, back onto a phone that had just forgotten them.
    private(set) var wipeEpoch = 0

    // MARK: - Plumbing

    let cache: DuoCache
    private(set) var dependencies: DuoDependencies?
    /// False only for the DEBUG preview, which draws sample duos and talks to nobody.
    let usesServer: Bool
    private let reloadWidget: () -> Void

    init(cache: DuoCache = .live, usesServer: Bool = true, reloadWidget: @escaping () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: DuoCache.widgetKind)
    }) {
        self.cache = cache
        self.usesServer = usesServer
        self.reloadWidget = reloadWidget
        let cachedDuos = cache.loadDuos()
        duos = cachedDuos
        let savedBlocks = cache.loadBlockedDuoIDs()
        let keptBlocks = savedBlocks.intersection(Set(cachedDuos.map(\.id)))
        blockedDuoIDs = keptBlocks
        if savedBlocks != keptBlocks { cache.saveBlockedDuoIDs(keptBlocks) }
        diagnostics = cache.loadDiagnostics()
        memberInfo = cache.loadMember()
        ageStatus = cache.ageStatus
        acceptedTermsVersion = cache.acceptedTermsVersion
        notificationsEnabled = cache.notificationsEnabled
        myDisplayName = cache.myDisplayName
        if let saved = cache.loadPendingInvite() {
            // An invite older than 48 hours is dropped from disk as well as from memory (§4.1):
            // skipping it here alone left its code on the phone indefinitely.
            if saved.isExpired(now: Date()) { cache.savePendingInvite(nil) } else { pendingInvite = saved }
        }
        // Reading the journal drops what is past its lifetime, from disk too.
        _ = cache.loadInflight()
    }

    /// Given the services, once, by `DuoComposition`. A refusal the Keychain remembers is taken
    /// in here, so deleting the app and installing it again does not give the person a second
    /// try at the birth-year screen (the defaults it was first kept in went with the app).
    func install(_ dependencies: DuoDependencies) {
        self.dependencies = dependencies
        // One initial read belongs to installation, never to Today's body. If it fails,
        // prepare or an explicit credential lookup retries later and publishes its answer.
        _ = dependencies.identity?.credential
        identityPresenceChanged()
        refusedNow()
        dependencies.refreshAgeNetworkState(forceStop: true)
        applyThrowawayMarker()
    }

    /// A Reconnect that was refused or cut short left the throwaway it minted as the stored
    /// credential, behind duos that belong to another member. It is still disconnected from them:
    /// say so before anything reads with the stranger's bearer and ends them. Asked at install and
    /// again at every way into the sync engine, because a process that started before the first
    /// unlock cannot read the credential at install, and the answer changes when it can.
    func applyThrowawayMarker() {
        if let identity = dependencies?.identity as? DuoRecoveryIdentity,
           let record = try? identity.journal.read(), record.active != nil {
            cache.throwawayDeviceID = record.activeRole == .reconnectThrowaway ? record.active?.deviceID : nil
        }
        guard let throwaway = cache.throwawayDeviceID else { return }
        // A credential that reads as nil may only be a Keychain that is not readable yet, so the
        // marker is dropped only for a credential that reads and is some other one.
        guard let stored = dependencies?.identity?.credential?.deviceID else { return }
        if stored == throwaway {
            if duos.contains(where: { !$0.hasEnded }), availability != .disconnected { availability = .disconnected }
        } else {
            cache.throwawayDeviceID = nil
        }
    }

    /// Whether this person was refused, asked of every place the refusal is kept rather than of
    /// memory alone: a process that started before the first unlock after a restart could read
    /// neither the defaults nor the Keychain and said "unknown". A refusal found in one place is
    /// written to the others (the Keychain write is `try?`, so a first failure used to leave a
    /// refusal that deleting and reinstalling the app would undo), and any invite the person was
    /// holding goes with it, since nothing is kept for someone who was refused.
    /// Takes an "allowed" age answer back to unknown; a refusal stays. Only "Not me, start fresh"
    /// calls this (the exit service, after its wipe): the defaults travel with a backup to another
    /// person's phone, and a child on a hand-me-down phone restored from a parent's backup who says
    /// "not me" used to go straight to the rules without being asked. Every other wipe keeps the
    /// answer, as `DuoCache.keptKeys` says: the person is the same one.
    func forgetAnAllowedAge() {
        if cache.ageStatus == .allowed { cache.ageStatus = .unknown }
        if ageStatus == .allowed { ageStatus = .unknown }
    }

    /// The age gate asks this when it appears, so a refusal that was kept only in the Keychain
    /// is found even if this process started before the first unlock and said "unknown".
    func recheckAge() { refusedNow() }

    var needsAgeRecheck: Bool { cache.needsAgeRecheck }

    /// A phone holding a Duo identity whose rules are not accepted here: a reinstall clears them with
    /// the defaults, and `DuoRecoveryIdentity` suspends the identity until they are. Nothing used to
    /// ask for them again, so answering the recheck brought nothing back (finding 5).
    var needsTermsAgain: Bool {
        usesServer && hasIdentity && ageStatus != .refused && acceptedTermsVersion < DuoProtocolConstants.termsVersion
    }

    /// Whether leaves, blocks, nudges and invites can be sent now. False after a refusal, during the
    /// recheck and while the age answer cannot be read: every one of them used to be offered and then
    /// do nothing and say nothing (finding 1). Read from what is already published, never the Keychain.
    var ageAllowsSharing: Bool {
        !usesServer || (ageStatus != .refused && !ageCheckUnavailable && !cache.needsAgeRecheck)
    }

    func ageNetworkStatusChanged() {
        if cache.ageStatus == .refused {
            ageStatus = .refused
            if pendingInvite != nil { pendingInvite = nil }
        }
        if cache.needsAgeRecheck, ageStatus != .refused { ageStatus = .unknown }
        ageCheckUnavailable = cache.ageCheckUnavailable
        if usesServer { reloadWidget() }
    }

    @discardableResult
    private func refusedNow() -> Bool {
        defer {
            if let dependencies {
                dependencies.refreshAgeNetworkState()
                // A second failed credential read may leave the cached flag unchanged, so the
                // dependency callback need not fire. Do not clear the published failure merely
                // because the separate refusal item was readable.
                ageCheckUnavailable = cache.ageCheckUnavailable
            }
        }
        let inKeychain: Bool
        do {
            inKeychain = try dependencies?.secrets.readAgeRefused() == true
            ageCheckUnavailable = false
        } catch {
            // A read failure must neither unlock Duo nor manufacture a permanent refusal.
            // Returning true blocks the guarded actions until a later read succeeds.
            ageCheckUnavailable = true
            ageStatus = ageStatus == .refused || cache.ageStatus == .refused ? .refused : .unknown
            // An unreadable marker does not undo a refusal already known locally. Its invite
            // must go too, just as it does when the Keychain can be read.
            if ageStatus == .refused, pendingInvite != nil { pendingInvite = nil }
            return true
        }
        guard ageStatus == .refused || cache.ageStatus == .refused || inKeychain else {
            if ageStatus == .unknown, cache.ageStatus == .allowed { ageStatus = .allowed }
            return false
        }
        if ageStatus != .refused { ageStatus = .refused }
        if cache.ageStatus != .refused { cache.ageStatus = .refused }
        if !inKeychain { try? dependencies?.secrets.markAgeRefused() }
        if pendingInvite != nil { pendingInvite = nil }
        return true
    }

    // MARK: - DuoHost

    func duo(_ id: UUID) -> DuoState? { duos.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout DuoState) -> Void) {
        guard let index = duos.firstIndex(where: { $0.id == id }) else { return }
        var changed = duos[index]
        change(&changed)
        guard changed != duos[index] else { return }
        duos[index] = changed
        save()
    }

    func upsert(_ duo: DuoState) {
        if let index = duos.firstIndex(where: { $0.id == duo.id }) {
            guard duos[index] != duo else { return }
            duos[index] = duo
        } else {
            duos.append(duo)
        }
        save()
    }

    func remove(_ id: UUID) {
        guard let removed = duos.first(where: { $0.id == id }) else { return }
        duos.removeAll { $0.id == id }
        blockedDuoIDs.remove(id)
        diagnostics.forget(duoID: id)
        if usesServer {
            // Clear takes a duo "together with its vers, rejectedDays and ledger keys" (§12.2).
            // The vers live in the duo itself; the other two live in the cache, and a rejected
            // row holds a progress bucket that nothing else would ever prune.
            var rejected = cache.loadRejectedDays()
            if rejected.removeValue(forKey: id.uuidString.lowercased()) != nil { cache.saveRejectedDays(rejected) }
            let ledger = cache.loadLedger()
            var trimmed = ledger
            trimmed.forget(duoID: id)
            trimmed.forget(nudgeIDs: removed.allNudges.map(\.id))
            if trimmed != ledger { cache.saveLedger(trimmed) }
        }
        save()
    }

    func rememberConfirmedBlock(_ id: UUID) {
        guard duo(id) != nil else { return }
        blockedDuoIDs.insert(id)
    }

    func replaceAll(with duos: [DuoState]) {
        guard self.duos != duos else { return }
        self.duos = duos
        blockedDuoIDs.formIntersection(Set(duos.map(\.id)))
        save()
    }

    private func save() {
        guard usesServer else { return }
        cache.saveDuos(duos)
        reloadWidget()
    }

    /// Forgets everything this phone kept about the person's Duo identity (the wipe of §12.3):
    /// the published values and the cache together. The in-memory values go first, because
    /// their `didSet`s write to the cache, and the cache is cleared last so that what is left
    /// on disk is the removal and never an empty value written back over it. What the
    /// person's own water log says (`latest`) is not Duo data and stays; so do the age answer,
    /// the notifications switch and the one-time suggestion and goal-raise note, as
    /// `DuoCache.keptKeys` says.
    func resetLocalState() {
        blockedDuoIDs = []
        duos = []
        memberInfo = nil
        pendingInvite = nil
        diagnostics = DuoDiagnostics()
        myDisplayName = ""
        needsTerms = false
        newDeviceNotice = false
        // What the screen says about the identity that is gone goes with it: a restore question
        // for someone who just said "not me", and a disconnected or banned phone with nothing left
        // to be disconnected from. `unknown` allows writes, so Create and Join work again; what
        // describes the server or the build (maintenance, an update needed) is still true.
        switch availability {
        case .needsRestoreChoice, .disconnected, .banned: availability = .unknown
        case .unknown, .available, .maintenance, .upgradeRequired: break
        }
        notice = nil
        sheetError = nil
        isWorking = false
        // A service that was waiting on an answer when this ran must not write it back
        // afterwards (a late `GET /me` would bring a duo, and its partner's name, back): it
        // reads this before the request and compares it after.
        wipeEpoch += 1
        cache.clearEverything()
        acceptedTermsVersion = cache.acceptedTermsVersion
        if usesServer { reloadWidget() }
    }

    // MARK: - What the views ask

    var activeDuos: [DuoState] { duos.filter { !$0.hasEnded } }

    func canAddDuo(isSubscribed: Bool) -> Bool {
        DuoLimit.canAddDuo(existing: duos, isSubscribed: isSubscribed)
    }

    /// The nudges this person may send a duo in a day, from `GET /me` (3, or 1 at the low tier).
    var nudgesPerDay: Int { memberInfo?.nudgesPerDay ?? DuoNudgeRules.dailyLimit }

    /// Whether `DuoNoticeCards` has anything to draw: the reinstall question, the disconnected
    /// question, a line about the service or the app version, or a device that was added. The
    /// Duo screen and Today ask this so they leave no empty row where there is nothing to say.
    var hasNoticeCards: Bool {
        if case .needsRestoreChoice = availability { return true }
        return availability.bannerMessage != nil || newDeviceNotice
    }

    /// The id of the last response of any kind, for the small `(ref ...)` line the Duo screen
    /// ends with and the Diagnostics screen's list.
    var lastRequestID: String? { DuoDiagnostics.usableRequestID(diagnostics.recentRequests.first?.requestID) }

    /// How many requests are waiting in the op queue, for Diagnostics.
    var queuedOpCount: Int { dependencies?.ops?.pending.count ?? 0 }

    /// Whether the Support ID, the Diagnostics screen and Delete my Duo data have anything to
    /// act on: this phone holds a credential. The preview store has no services and so no
    /// credential, so it answers for a phone that has duos: otherwise those rows could never be
    /// drawn, looked at or tested there (the `empty` and `restore` scenarios have none).
    var hasIdentity: Bool {
        usesServer ? dependencies?.identity?.cachedCredentialPresence == true : !duos.isEmpty
    }

    func identityPresenceChanged() {
        // Read the current snapshot when this callback runs. A store/discard pair can queue
        // callbacks from different threads; an old captured Boolean must not win later.
        let present = dependencies?.identity?.cachedCredentialPresence == true
        if lastObservedIdentityPresence != present { lastObservedIdentityPresence = present }
    }

    func streak(of duo: DuoState, now: Date = Date()) -> Int {
        DuoStreak.current(statuses: duo.statuses, myRole: duo.myRole, myToday: DayKey.key(for: now), now: now)
    }

    /// Whether the streak has reached the edge of the kept window, which the card and the
    /// widget show as "100+ days" (§8.5).
    func reachedRetentionEdge(of duo: DuoState, now: Date = Date()) -> Bool {
        DuoStreak.reachedRetentionEdge(statuses: duo.statuses, myRole: duo.myRole, myToday: DayKey.key(for: now), now: now)
    }

    /// What to draw for one side of a duo right now. My own side comes from the log as it
    /// stands, not from what was last sent, so my mascot never lags behind my drinks.
    func status(of role: DuoRole, in duo: DuoState, now: Date = Date()) -> DuoDayStatus? {
        let today = DayKey.key(for: now)
        if role == duo.myRole, let latest {
            return DuoProgress.status(role: role, day: today, totalML: latest.totalsByDay[today] ?? 0, goalML: latest.goalML, now: now)
        }
        return DuoStreak.currentStatus(of: role, statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
    }

    func nudgeVerdict(for duo: DuoState, now: Date = Date()) -> DuoNudgeRules.Verdict {
        DuoNudgeRules.verdict(for: duo, partnerStatus: status(of: duo.myRole.other, in: duo, now: now), now: now, dailyLimit: nudgesPerDay)
    }

    /// The link to share for a duo's open invite: `https://hydrodrop.us/duo#<code>.<k>`, with
    /// the secret from this phone's Keychain, or without it for a code typed in by hand.
    func shareURL(for duo: DuoState) -> URL? {
        guard let invite = duo.invite else { return nil }
        let secret = dependencies?.secrets.linkSecret(forDuo: duo.id)
        return DuoLink.url(code: invite.code, k: secret)
    }

    /// The first-run suggestion: shown once, after a few days of a solo streak, to someone with no duo.
    func shouldSuggestDuo(soloStreak: Int) -> Bool {
        DuoInviteMoment.shouldShow(soloStreak: soloStreak, hasAnyDuo: !duos.isEmpty, wasDismissed: cache.inviteMomentDismissed)
    }

    func dismissSuggestion() {
        cache.inviteMomentDismissed = true
        objectWillChange.send()
    }

    // MARK: - The log

    /// Told whenever the log or the goal changes. Keeps the last week and the oldest day, and
    /// hands them to the sync service. The shared streak is measured against the saved goal,
    /// like the solo one, so a bump accepted for today can never cost a partner the streak.
    func logChanged(entries: [WaterEntry], goalML: Int, now: Date = Date()) {
        guard !refusedNow() else { return }
        let horizon = now.addingTimeInterval(-Double(DuoStreak.correctionWindowDays + 2) * 86_400)
        let recent = entries.filter { $0.timestamp >= horizon }
        let earliest = entries.map(\.timestamp).min().map { DayKey.key(for: $0) }
        let summary = DuoLogSummary(totalsByDay: StreakCalculator.totalsByDay(recent), goalML: goalML, earliestEntryDay: earliest)
        if summary != latest { latest = summary }
        dependencies?.sync?.logChanged(summary)
    }

    /// Not behind `refusedNow()`: activating sends nothing, and the app calls this once per process.
    /// A Keychain the age check could not read yet (a launch before the first unlock) used to skip
    /// it for the whole run, so Duo later ran without reading drinks from the widget or the Watch
    /// and lost the guard that keeps a fallback store from publishing (finding 9).
    func activate(logReader: DuoLogReading) {
        dependencies?.sync?.activate(logReader: logReader)
    }

    // MARK: - Reading and publishing

    func refresh() async {
        guard !refusedNow() else { return }
        applyThrowawayMarker(); await dependencies?.sync?.refresh()
    }

    /// The Duo screen has come on screen (final design §3.4 step 2). Along with a cached duo, this
    /// is the one time the phone's identity is asked about without a tap: a phone that was
    /// restored or reinstalled with a credential and no duo cached finds out here whether to ask
    /// "Continue as <name>?". `refresh()` alone cannot do it, because it cannot tell this from a
    /// foreground or a background task, and the first `prepare()` of an unsettled phone sends
    /// `GET /me` under the previous owner's bearer, which moves their `last_seen_at`. Anything
    /// else that is on screen with no duo (the Today section, a card) calls `refresh()`, not this.
    func duoScreenOpened() async {
        guard !refusedNow() else { return }
        _ = await dependencies?.identity?.prepare()
        await refresh()
    }
    func flush() async {
        guard !refusedNow() else { return }
        applyThrowawayMarker(); await dependencies?.sync?.flush()
    }
    func backgroundRefresh() async -> Bool {
        guard !refusedNow() else { return false }
        applyThrowawayMarker(); return await dependencies?.sync?.backgroundRefresh() ?? false
    }
    func scheduleBackgroundRefresh() {
        guard !refusedNow() else { return }
        dependencies?.background?.scheduleRefresh()
    }
    func pushArrived(_ payload: DuoPushPayload) async {
        guard !refusedNow() else { return }
        applyThrowawayMarker(); await dependencies?.sync?.pushArrived(payload)
    }
    func pushTokenArrived(_ token: Data, environment: DuoAPNsEnvironment) {
        guard !refusedNow() else { return }
        dependencies?.push?.tokenArrived(token, environment: environment)
    }
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async {
        guard !refusedNow() else { return }
        await dependencies?.sync?.sendNudge(preset, in: duo)
    }

    // MARK: - Starting, joining, reconnecting

    // A person who gave a birth year under the minimum age is refused Duo (§12.6), which includes
    // looking at an invite: every way in below asks `refusedNow()` first, so nothing is sent for
    // them and nothing is kept, even if only the Keychain remembered the refusal at launch.

    func createDuo(named name: String?) async -> DuoState? {
        guard !refusedNow(), let joining = dependencies?.joining else { return nil }
        return await joining.createDuo(named: name, skin: dependencies?.activeSkin() ?? "classic")
    }

    func peek(code: String) async -> DuoPeek? {
        guard !refusedNow() else { return nil }
        return await dependencies?.joining?.peek(code: code)
    }

    func receive(_ invite: DuoParsedInvite, now: Date = Date()) {
        guard !refusedNow() else { return }
        dependencies?.joining?.receive(invite, now: now)
    }
    func discardPendingInvite() { dependencies?.joining?.discardPendingInvite() }

    func join(_ invite: DuoPendingInvite, named name: String?) async -> DuoState? {
        guard !refusedNow(), let joining = dependencies?.joining else { return nil }
        return await joining.join(invite, named: name, skin: dependencies?.activeSkin() ?? "classic")
    }

    func newInvite(for duo: DuoState) async -> DuoInvite? {
        guard !refusedNow() else { return nil }
        return await dependencies?.joining?.newInvite(for: duo)
    }
    func createReconnectCode(for duo: DuoState) async -> DuoInvite? {
        guard !refusedNow() else { return nil }
        return await dependencies?.joining?.createReconnectCode(for: duo)
    }
    func createLinkCode() async -> DuoInvite? {
        guard !refusedNow() else { return nil }
        return await dependencies?.joining?.createLinkCode()
    }
    func reconnect(code: String) async -> Bool {
        guard !refusedNow() else { return false }
        return await dependencies?.joining?.reconnect(code: code) ?? false
    }
    func changeMyName(_ name: String?) async {
        guard !refusedNow() else { return }
        await dependencies?.joining?.changeMyName(name)
    }

    /// The person accepted the terms on a sheet: recorded here, then sent as `terms_version`.
    func acceptTerms() async -> Bool {
        guard !refusedNow() else { return false }
        cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
        acceptedTermsVersion = DuoProtocolConstants.termsVersion
        return await dependencies?.joining?.acceptTerms() ?? true
    }

    /// The neutral birth-year screen's answer. Only the status is kept, never the year.
    @discardableResult
    func recordBirthYear(_ year: Int, month: Int, now: Date = Date()) -> DuoAgeStatus {
        // A refusal is final, and it is read from every place it is kept rather than trusted from
        // memory (see `refusedNow`): an adult year given afterwards must not overwrite it.
        if refusedNow() || ageCheckUnavailable || (dependencies != nil && cache.ageCheckUnavailable) { return ageStatus }
        let status = DuoAgeGate.decide(birthYear: year, birthMonth: month, now: now, calendar: .current)
        // An unreadable year is not an answer, and nor is the thirteenth-birthday month (decision b):
        // nothing is kept and the screen asks again.
        guard status != .unknown else { return ageStatus }
        cache.recordConfirmedAgeStatus(status)
        ageStatus = status
        // The refusing answer itself: keep it in the Keychain too, and let go of any invite the
        // person was holding (`refusedNow` does both, now that every place says refused).
        if status == .refused { refusedNow() }
        dependencies?.refreshAgeNetworkState()
        if usesServer { reloadWidget() }
        if status == .refused { deleteAfterRefusal() }
        return status
    }

    /// Decision a (2026-11-12, D81): a refusal on a phone that already holds this person's Duo
    /// identity sends `DELETE /me` once, through the deletion exemption the age gate already lets
    /// through. Kept, the identity left the child's name and days on the partner's phone, the
    /// server kept the push token so the partner's nudges still arrived, and the queued Leave or
    /// Block the refusal threw away never went. Only here, at the refusing answer, so it is sent
    /// once; if it fails, Delete my Duo data stays on the Duo screen and the refusal screen says so.
    ///
    /// Never for an identity this install has not answered for, a reinstall's included
    /// (`DuoRecoveryIdentity.refusalMayDeleteIdentity`): it may be someone else's.
    private func deleteAfterRefusal() {
        guard usesServer, hasIdentity, refusalDeletion == nil, dependencies?.exiting != nil else { return }
        if let identity = dependencies?.identity as? DuoRecoveryIdentity, !identity.refusalMayDeleteIdentity() { return }
        refusalDeletion = .deleting
        refusalDeletionTask = Task { [weak self] in
            guard let self else { return }
            let deleted = await self.deleteMyData()
            // The refusal screen says what happened, so the notice the delete left is not said again
            // in an alert once the sheet has gone. Any notice but the "removed from this phone" one
            // means something did not work (the local wipe, say), which the screen calls a failure
            // and answers with the way to delete by hand: never "deleted" on a guess.
            let said = self.notice
            self.notice = nil
            switch (deleted, said) {
            case (true, nil): self.refusalDeletion = .deleted
            case (true, DuoUserMessage.removedFromThisPhoneOnly?): self.refusalDeletion = .removedFromThisPhone
            default: self.refusalDeletion = .failed
            }
        }
    }

    /// Only the recheck sheet calls this after its explicit confirmed answer. Ordinary
    /// refresh resumes existing sharing; this is not a Create/Join or notification permission tap.
    func resumeAfterAgeRecheck() async {
        // The age answer and the recheck sheet's own form can both ask, a moment apart.
        if let resuming { return await resuming.value }
        let task = Task { await resumeOnce() }
        resuming = task
        await task.value
        resuming = nil
    }
    private var resuming: Task<Void, Never>?

    private func resumeOnce() async {
        guard ageStatus == .allowed, !cache.needsAgeRecheck,
              dependencies?.ageNetworkAllowed == true else { return }
        await duoScreenOpened()
        guard dependencies?.ageNetworkAllowed == true else { return }
        await dependencies?.ops?.drain()
        dependencies?.push?.reevaluate(.launch)
        scheduleBackgroundRefresh()
    }

    // MARK: - Leaving

    func leave(_ duo: DuoState) async {
        guard !refusedNow() else { return }
        await dependencies?.exiting?.leave(duo)
    }
    func block(_ duo: DuoState) async {
        guard !refusedNow() else { return }
        await dependencies?.exiting?.block(duo)
    }
    func clear(_ duo: DuoState) { dependencies?.exiting?.clear(duo) }
    func deleteMyData() async -> Bool { await dependencies?.exiting?.deleteMyData() ?? false }
    func startFresh() { dependencies?.exiting?.startFresh() }
    func continueAsRestored() async {
        guard !refusedNow() else { return }
        await dependencies?.identity?.continueAsRestored()
    }

    // MARK: - Local only

    /// "Show as:" (D29): what this person calls their partner. Cleaned the way a name is,
    /// kept on this phone, and used in place of the server's name everywhere this app draws or
    /// announces it. An empty one takes the nickname away.
    func setNickname(_ raw: String, for duoID: UUID) {
        let cleaned = DuoState.cleanedName(raw)
        update(duoID) { $0.partnerNickname = cleaned.isEmpty ? nil : cleaned }
    }

    func dismissNewDeviceNotice() {
        newDeviceNotice = false
        if let devices = memberInfo?.devices { cache.saveSeenDeviceIDs(devices.map(\.id)) }
    }

    /// Takes back every notification, waiting or delivered, on a duo's thread.
    func removeNotifications(for duo: DuoState) { dependencies?.announcer?.removeDeliveredIncludingEnded(for: duo.id) }
}
#endif
