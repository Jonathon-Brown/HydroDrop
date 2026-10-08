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
    @Published var needsTerms = false
    @Published private(set) var ageStatus: DuoAgeStatus
    @Published private(set) var acceptedTermsVersion: Int
    /// The Duo notifications toggle (§9.6). Turning it off changes what is uploaded, not the token.
    @Published var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            cache.notificationsEnabled = notificationsEnabled
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
        duos = cache.loadDuos()
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
        refusedNow()
        // A Reconnect that was refused or cut short left the throwaway it minted as the stored
        // credential, behind duos that belong to another member. It is still disconnected from
        // them: say so before anything reads with the stranger's bearer and ends them.
        if let throwaway = cache.throwawayDeviceID {
            if dependencies.identity?.credential?.deviceID == throwaway {
                if duos.contains(where: { !$0.hasEnded }) { availability = .disconnected }
            } else {
                cache.throwawayDeviceID = nil
            }
        }
    }

    /// Whether this person was refused, asked of every place the refusal is kept rather than of
    /// memory alone: a process that started before the first unlock after a restart could read
    /// neither the defaults nor the Keychain and said "unknown". A refusal found in one place is
    /// written to the others (the Keychain write is `try?`, so a first failure used to leave a
    /// refusal that deleting and reinstalling the app would undo), and any invite the person was
    /// holding goes with it, since nothing is kept for someone who was refused.
    @discardableResult
    private func refusedNow() -> Bool {
        let inKeychain = dependencies?.secrets.isAgeRefused() == true
        guard ageStatus == .refused || cache.ageStatus == .refused || inKeychain else { return false }
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
        guard duos.contains(where: { $0.id == id }) else { return }
        duos.removeAll { $0.id == id }
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
            if trimmed != ledger { cache.saveLedger(trimmed) }
        }
        save()
    }

    func replaceAll(with duos: [DuoState]) {
        guard self.duos != duos else { return }
        self.duos = duos
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
    var lastRequestID: String? { diagnostics.recentRequests.first?.requestID }

    /// How many requests are waiting in the op queue, for Diagnostics.
    var queuedOpCount: Int { dependencies?.ops?.pending.count ?? 0 }

    /// Whether the Support ID, the Diagnostics screen and Delete my Duo data have anything to
    /// act on: this phone holds a credential. The preview store has no services and so no
    /// credential, so it answers for a phone that has duos: otherwise those rows could never be
    /// drawn, looked at or tested there (the `empty` and `restore` scenarios have none).
    var hasIdentity: Bool {
        usesServer ? dependencies?.identity?.credential != nil : !duos.isEmpty
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
        let horizon = now.addingTimeInterval(-Double(DuoStreak.correctionWindowDays + 2) * 86_400)
        let recent = entries.filter { $0.timestamp >= horizon }
        let earliest = entries.map(\.timestamp).min().map { DayKey.key(for: $0) }
        let summary = DuoLogSummary(totalsByDay: StreakCalculator.totalsByDay(recent), goalML: goalML, earliestEntryDay: earliest)
        if summary != latest { latest = summary }
        dependencies?.sync?.logChanged(summary)
    }

    func activate(logReader: DuoLogReading) {
        dependencies?.sync?.activate(logReader: logReader)
    }

    // MARK: - Reading and publishing

    func refresh() async { await dependencies?.sync?.refresh() }

    /// The Duo screen has come on screen (final design §3.4 step 2). Along with a cached duo, this
    /// is the one time the phone's identity is asked about without a tap: a phone that was
    /// restored or reinstalled with a credential and no duo cached finds out here whether to ask
    /// "Continue as <name>?". `refresh()` alone cannot do it, because it cannot tell this from a
    /// foreground or a background task, and the first `prepare()` of an unsettled phone sends
    /// `GET /me` under the previous owner's bearer, which moves their `last_seen_at`. Anything
    /// else that is on screen with no duo (the Today section, a card) calls `refresh()`, not this.
    func duoScreenOpened() async {
        _ = await dependencies?.identity?.prepare()
        await refresh()
    }
    func flush() async { await dependencies?.sync?.flush() }
    func backgroundRefresh() async -> Bool { await dependencies?.sync?.backgroundRefresh() ?? false }
    func scheduleBackgroundRefresh() { dependencies?.background?.scheduleRefresh() }
    func pushArrived(_ payload: DuoPushPayload) async { await dependencies?.sync?.pushArrived(payload) }
    func pushTokenArrived(_ token: Data, environment: DuoAPNsEnvironment) { dependencies?.push?.tokenArrived(token, environment: environment) }
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async { await dependencies?.sync?.sendNudge(preset, in: duo) }

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

    func newInvite(for duo: DuoState) async -> DuoInvite? { await dependencies?.joining?.newInvite(for: duo) }
    func createReconnectCode(for duo: DuoState) async -> DuoInvite? { await dependencies?.joining?.createReconnectCode(for: duo) }
    func createLinkCode() async -> DuoInvite? { await dependencies?.joining?.createLinkCode() }
    func reconnect(code: String) async -> Bool {
        guard !refusedNow() else { return false }
        return await dependencies?.joining?.reconnect(code: code) ?? false
    }
    func changeMyName(_ name: String?) async { await dependencies?.joining?.changeMyName(name) }

    /// The person accepted the terms on a sheet: recorded here, then sent as `terms_version`.
    func acceptTerms() async -> Bool {
        guard !refusedNow() else { return false }
        cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
        acceptedTermsVersion = DuoProtocolConstants.termsVersion
        return await dependencies?.joining?.acceptTerms() ?? true
    }

    /// The neutral birth-year screen's answer. Only the status is kept, never the year.
    @discardableResult
    func recordBirthYear(_ year: Int, now: Date = Date()) -> DuoAgeStatus {
        // A refusal is final, and it is read from every place it is kept rather than trusted from
        // memory (see `refusedNow`): an adult year given afterwards must not overwrite it.
        if refusedNow() { return .refused }
        let status = DuoAgeGate.decide(birthYear: year, now: now, calendar: .current)
        // An unreadable year is not an answer: the screen asks again.
        guard status != .unknown else { return ageStatus }
        cache.ageStatus = status
        ageStatus = status
        // The refusing answer itself: keep it in the Keychain too, and let go of any invite the
        // person was holding (`refusedNow` does both, now that every place says refused).
        if status == .refused { refusedNow() }
        return status
    }

    // MARK: - Leaving

    func leave(_ duo: DuoState) async { await dependencies?.exiting?.leave(duo) }
    func block(_ duo: DuoState) async { await dependencies?.exiting?.block(duo) }
    func clear(_ duo: DuoState) { dependencies?.exiting?.clear(duo) }
    func deleteMyData() async -> Bool { await dependencies?.exiting?.deleteMyData() ?? false }
    func startFresh() { dependencies?.exiting?.startFresh() }
    func continueAsRestored() async { await dependencies?.identity?.continueAsRestored() }

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
    func removeNotifications(for duo: DuoState) { dependencies?.announcer?.removeDelivered(for: duo.id) }
}
#endif
