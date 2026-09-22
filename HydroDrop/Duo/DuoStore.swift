import BackgroundTasks
import CloudKit
import SwiftData
import SwiftUI
import WidgetKit

/// The duos this device is part of, and the comings and goings between them and iCloud.
///
/// Views read this and nothing below it. It decides when to write (when the log changes,
/// at most once every thirty seconds), when to read (when the app comes forward, and on
/// a pull to refresh), and what to say when iCloud is not there to talk to.
@MainActor
final class DuoStore: ObservableObject {
    static let shared = DuoStore()

    enum Account: Equatable {
        case unknown
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
    }

    /// An invite that has been opened and is waiting for a first name and a yes.
    struct PendingInvite: Identifiable {
        let id: UUID
        let metadata: CKShare.Metadata
    }

    @Published private(set) var duos: [DuoState]
    @Published private(set) var account: Account = .unknown
    @Published var pendingInvite: PendingInvite?
    /// Something worth telling the user once, in an alert.
    @Published var notice: String?
    /// The same, for the setup and join sheets, which say it in place: an alert raised
    /// from underneath a sheet is never seen.
    @Published var sheetError: String?
    /// Starting, joining or leaving is under way.
    @Published private(set) var isWorking = false

    private let service = DuoService.shared
    /// False only for the DEBUG preview, which draws sample duos and talks to nobody.
    private let usesCloud: Bool
    private var coalescer = DuoWriteCoalescer()
    /// The last week of the log, as of the last time it changed. Published because my
    /// own side of every card is drawn from it.
    @Published private var latest: LogSummary?

    private struct LogSummary: Equatable {
        var totalsByDay: [String: Int]
        var goalML: Int
    }
    private var owedWrite: Task<Void, Never>?
    private var failedAttempts = 0
    private var isRefreshing = false
    private var modelContainer: ModelContainer?
    private var backgroundWork: Task<Bool, Never>?
    // Read from the CKAccountChanged observer's @Sendable closure, so it cannot be
    // main-actor isolated. An immutable String is safe to share as it is.
    private nonisolated static let subscriptionsSavedKey = "duo.subscriptionsSaved"
    private var isFlushing = false
    /// Something changed while a flush was under way, so one more is owed after it.
    private var flushIsStale = false

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DuoPreview") {
            usesCloud = false
            duos = Self.previewDuos()
            account = .available
            return
        }
        #endif
        usesCloud = true
        duos = DuoCache.load()
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            // Subscriptions belong to an iCloud account, so a new account needs its own.
            DuoCache.defaults.removeObject(forKey: Self.subscriptionsSavedKey)
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Given the store so that a refresh with nobody looking, after a silent push or in
    /// a background refresh, can still read the log and send what it finds.
    func activate(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - What the views ask

    var activeDuos: [DuoState] { duos.filter { !$0.hasEnded } }

    func canAddDuo(isSubscribed: Bool) -> Bool {
        DuoLimit.canAddDuo(existing: duos, isSubscribed: isSubscribed)
    }

    func streak(of duo: DuoState, now: Date = Date()) -> Int {
        DuoStreak.current(statuses: duo.statuses, myRole: duo.myRole, myToday: DayKey.key(for: now), now: now)
    }

    /// What to draw for one side of a duo right now. My own side comes from the log as
    /// it stands, not from what was last sent, so my mascot never lags behind my drinks.
    func status(of role: DuoRole, in duo: DuoState, now: Date = Date()) -> DuoDayStatus? {
        let today = DayKey.key(for: now)
        if role == duo.myRole, let latest {
            return DuoProgress.status(
                role: role,
                day: today,
                totalML: latest.totalsByDay[today] ?? 0,
                goalML: latest.goalML,
                now: now
            )
        }
        return DuoStreak.currentStatus(of: role, statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
    }

    /// Why Duo cannot reach iCloud, or nil when it can.
    var accountMessage: String? {
        switch account {
        case .unknown, .available: return nil
        case .noAccount: return "Duo streaks use iCloud. Sign in to iCloud in Settings to start one."
        case .restricted: return "iCloud is restricted on this iPhone, so duo streaks are not available."
        case .temporarilyUnavailable: return "iCloud is not available right now. Your duo will catch up when it is."
        }
    }

    // MARK: - Publishing

    /// Told whenever the log or the goal changes. Works out the last week from the log
    /// and arranges for whatever iCloud has not heard yet to be sent.
    func logChanged(entries: [WaterEntry], goalML: Int, now: Date = Date()) {
        // Kept up to date even with no duo, so that one started or joined a moment from
        // now has today to send straight away.
        let horizon = now.addingTimeInterval(-Double(DuoStreak.correctionWindowDays + 2) * 86_400)
        let recent = entries.filter { $0.timestamp >= horizon }
        let summary = LogSummary(totalsByDay: StreakCalculator.totalsByDay(recent), goalML: goalML)
        if summary != latest { latest = summary }
        requestPublish()
    }

    private func requestPublish() {
        // Asked far more often than there is anything to say: every log, every
        // foreground, every change of goal. Only an actual difference costs a write, or
        // counts towards the thirty seconds.
        guard usesCloud, hasSomethingUnsent() else { return }
        switch coalescer.request(now: Date()) {
        case .writeNow:
            Task { await flush() }
        case .wait(let until):
            owedWrite = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                guard let self, !Task.isCancelled else { return }
                self.coalescer.waitEnded(now: Date())
                await self.flush()
            }
        case .alreadyWaiting:
            break
        }
    }

    private func hasSomethingUnsent(now: Date = Date()) -> Bool {
        guard let latest else { return false }
        let skin = AppSettings.shared.activeMascotSkin.rawValue
        return activeDuos.contains { duo in
            duo.skinRawValue(of: duo.myRole) != skin || !DuoOutbox.unsent(
                role: duo.myRole,
                totalsByDay: latest.totalsByDay,
                goalML: latest.goalML,
                known: duo.statuses,
                myToday: DayKey.key(for: now),
                now: now
            ).isEmpty
        }
    }

    /// Sends every duo whatever it is missing. What is missing is worked out fresh each
    /// time from the log and the cache, so a write that failed, or never happened
    /// because the phone was offline, is simply still missing next time.
    private func flush() async {
        guard usesCloud, let latest else { return }
        // One at a time. Two interleaved would send the same records twice and lose
        // count of the retries between them.
        guard !isFlushing else {
            flushIsStale = true
            return
        }
        isFlushing = true
        defer {
            isFlushing = false
            if flushIsStale {
                flushIsStale = false
                requestPublish()
            }
        }
        let now = Date()
        let today = DayKey.key(for: now)
        let skin = AppSettings.shared.activeMascotSkin.rawValue
        var retryAfter: TimeInterval?

        for duo in activeDuos {
            let unsent = DuoOutbox.unsent(
                role: duo.myRole,
                totalsByDay: latest.totalsByDay,
                goalML: latest.goalML,
                known: duo.statuses,
                myToday: today,
                now: now
            )
            do {
                if !unsent.isEmpty {
                    try await service.write(unsent, in: duo)
                    update(duo.id) { state in unsent.forEach { state.upsert($0) } }
                }
                // The skin held here is the one iCloud is known to have, so a difference
                // means a change of skin, or a name and skin that never got sent at all.
                if duo.skinRawValue(of: duo.myRole) != skin {
                    let held = duo.myRole == .owner ? duo.ownerDisplayName : duo.partnerDisplayName
                    let name = held.isEmpty ? DuoCache.myDisplayName() : held
                    try await service.writeIdentity(name: name, skin: skin, in: duo)
                    update(duo.id) { state in
                        if state.myRole == .owner { state.ownerSkin = skin } else { state.partnerSkin = skin }
                    }
                }
            } catch {
                switch DuoRetry.verdict(for: error) {
                case .ended:
                    markEnded(duo.id)
                case .retry(let after):
                    retryAfter = max(retryAfter ?? 0, after)
                case .fail:
                    Diagnostics.log("could not publish to a duo: \(error)")
                }
            }
        }

        guard let retryAfter else {
            failedAttempts = 0
            return
        }
        failedAttempts += 1
        guard failedAttempts < DuoRetry.maximumAttempts else {
            // Left for the next time the app comes forward, which starts again from the log.
            Diagnostics.log("a duo publish is waiting for the next foreground after \(failedAttempts) tries")
            failedAttempts = 0
            return
        }
        owedWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, retryAfter)))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    // MARK: - Reading

    /// Reads what changed in every duo. Runs when the app comes forward and on a pull to
    /// refresh, then sends anything of mine that iCloud is missing.
    func refresh() async {
        guard usesCloud, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        account = Self.account(from: await service.accountStatus())
        guard account == .available else { return }
        await ensureSubscriptions()

        var ledger = DuoCache.loadLedger()
        var announcements: [DuoAnnouncement] = []

        for duo in activeDuos {
            do {
                let changes = try await service.fetchChanges(in: duo)
                apply(changes, to: duo.id)
                if let after = duos.first(where: { $0.id == duo.id }) {
                    let now = Date()
                    announcements += DuoAnnouncements.plan(
                        before: duo,
                        after: after,
                        isFirstRead: changes.isEverything,
                        ledger: &ledger,
                        myToday: DayKey.key(for: now),
                        now: now
                    )
                }
                guard duo.myRole == .owner else { continue }
                if try await service.settlePartner(in: duo) {
                    update(duo.id) { $0.partnerHasJoined = true }
                } else if duo.partnerHasJoined {
                    // They were here and now they are not: they left.
                    markEnded(duo.id)
                }
            } catch {
                if DuoRetry.verdict(for: error) == .ended {
                    markEnded(duo.id)
                } else {
                    Diagnostics.log("could not refresh a duo: \(error)")
                }
            }
        }

        // Shown first and written down second. Anything iOS would not take is taken
        // back out of the ledger, so it is tried again rather than lost for good.
        let refused = await DuoNotifier.deliver(announcements)
        refused.forEach { ledger.forget($0) }
        DuoCache.save(ledger)
        requestPublish()
    }

    private func apply(_ changes: DuoChanges, to id: UUID) {
        let now = Date()
        update(id) { duo in
            if changes.isEverything {
                duo.statuses = []
                duo.nudges = []
            }
            var nudges = duo.allNudges
            for nudge in changes.nudges where !nudges.contains(where: { $0.id == nudge.id }) {
                nudges.append(nudge)
            }
            nudges.removeAll { changes.deletedStatusNames.contains($0.id) }
            duo.nudges = DuoNudgeRules.current(nudges, now: now)
            if let identity = changes.identity {
                duo.createdAt = identity.createdAt ?? duo.createdAt
                // My own name is mine to say. If iCloud has not heard it yet, what was
                // typed in here stands until it has.
                if duo.myRole != .owner || !identity.ownerDisplayName.isEmpty {
                    duo.ownerDisplayName = identity.ownerDisplayName
                }
                if duo.myRole != .partner || !identity.partnerDisplayName.isEmpty {
                    duo.partnerDisplayName = identity.partnerDisplayName
                }
                duo.ownerSkin = identity.ownerSkin
                duo.partnerSkin = identity.partnerSkin
            }
            changes.statuses.forEach { duo.upsert($0) }
            duo.statuses.removeAll { changes.deletedStatusNames.contains($0.recordName) }
            duo.statuses = DuoStreak.pruned(duo.statuses, myToday: DayKey.key(for: now), now: now)
            if let token = changes.changeToken { duo.changeToken = token }
        }
    }

    // MARK: - Hearing about changes

    /// Asks for silent pushes, once per iCloud account and only once there is a duo to
    /// hear about. Silent pushes need no permission from the user.
    private func ensureSubscriptions() async {
        guard !activeDuos.isEmpty, !DuoCache.defaults.bool(forKey: Self.subscriptionsSavedKey) else { return }
        do {
            try await service.ensureSubscriptions()
            DuoCache.defaults.set(true, forKey: Self.subscriptionsSavedKey)
        } catch {
            // Not fatal: the foreground and the background refresh still fetch.
            Diagnostics.log("could not subscribe to duo changes: \(error)")
        }
    }

    /// Run once a duo exists: silent pushes for the news, and permission to show it.
    /// iOS only asks the permission question if it has never been answered.
    private func startHearingAboutChanges() async {
        await ensureSubscriptions()
        ReminderManager.shared.requestAuthorizationIfNeeded()
    }

    /// True if `userInfo` is one of the duo subscriptions firing, as opposed to the
    /// pushes SwiftData's own sync receives through the same door.
    nonisolated static func isDuoPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID else { return false }
        return DuoService.SubscriptionID.all.contains(id)
    }

    /// A refresh with nobody looking: after a silent push, or when iOS grants a
    /// background refresh. Reads the log first, so drinks logged from a widget while the
    /// app was closed reach the partner too. Returns whether anything changed.
    func backgroundRefresh() async -> Bool {
        guard usesCloud, !activeDuos.isEmpty else { return false }
        // A push and a granted refresh can land together. Both wait on the one piece of
        // work and get its answer, so neither tells iOS "nothing new" about news the
        // other is in the middle of fetching.
        if let inFlight = backgroundWork { return await inFlight.value }
        let work = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let before = self.duos
            self.readLogFromStore()
            await self.refresh()
            await self.flush()
            return self.duos != before
        }
        backgroundWork = work
        let changed = await work.value
        backgroundWork = nil
        return changed
    }

    private func readLogFromStore(now: Date = Date()) {
        guard let modelContainer else { return }
        let horizon = now.addingTimeInterval(-Double(DuoStreak.correctionWindowDays + 2) * 86_400)
        let descriptor = FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.timestamp >= horizon })
        do {
            let entries = try modelContainer.mainContext.fetch(descriptor)
            logChanged(entries: entries, goalML: AppSettings.shared.dailyGoalML, now: now)
        } catch {
            Diagnostics.log("could not read the log for a background duo refresh: \(error)")
        }
    }

    /// The identifier iOS knows the background refresh by. Built from the bundle
    /// identifier, to match `BGTaskSchedulerPermittedIdentifiers` in project.yml.
    nonisolated static var backgroundRefreshIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "HydroDrop").duo.refresh"
    }

    /// Asks iOS for a background refresh some time after half an hour from now. Silent
    /// pushes are throttled, so this is the net underneath them. Only with a duo.
    func scheduleBackgroundRefresh() {
        guard usesCloud, !activeDuos.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Always fails in the simulator, and when Background App Refresh is off.
            Diagnostics.log("could not schedule a duo background refresh: \(error)")
        }
    }

    // MARK: - Nudges

    func nudgeVerdict(for duo: DuoState, now: Date = Date()) -> DuoNudgeRules.Verdict {
        DuoNudgeRules.verdict(for: duo, partnerStatus: status(of: duo.myRole.other, in: duo, now: now), now: now)
    }

    /// Sends one of the ready-made lines, if today's rules still allow one.
    func sendNudge(_ preset: DuoNudgePreset, in stale: DuoState) async {
        // Judged against the duo as it is now, not as it was when the picker opened, so
        // two quick taps cannot both be counted as the third nudge of the day.
        guard usesCloud, let duo = duos.first(where: { $0.id == stale.id }),
              case .allowed = nudgeVerdict(for: duo) else { return }
        let now = Date()
        let nudge = DuoNudge.make(from: duo.myRole, preset: preset, now: now)
        let expired = DuoNudgeRules.expired(sentBy: duo.myRole, nudges: duo.allNudges, now: now)
        // Counted before it is sent, so two quick taps cannot both slip under the limit.
        update(duo.id) { $0.nudges = $0.allNudges + [nudge] }
        do {
            try await service.send(nudge, clearing: expired, in: duo)
        } catch {
            update(duo.id) { state in state.nudges = state.allNudges.filter { $0.id != nudge.id } }
            Diagnostics.log("could not send a nudge: \(error)")
            if DuoRetry.verdict(for: error) == .ended {
                markEnded(duo.id)
            } else {
                notice = Self.message(for: error)
            }
        }
    }

    // MARK: - Starting, joining, leaving

    /// Starts a duo and hands back the share to send. Nil, with a notice, if it could not.
    func createDuo(named rawName: String, isSubscribed: Bool) async -> (duo: DuoState, share: CKShare)? {
        guard usesCloud else { return nil }
        guard canAddDuo(isSubscribed: isSubscribed) else { return nil }
        let name = DuoState.cleanedName(rawName)
        guard !name.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false }

        DuoCache.setMyDisplayName(name)
        do {
            let created = try await service.createDuo(
                id: UUID(),
                ownerName: name,
                ownerSkin: AppSettings.shared.activeMascotSkin.rawValue,
                now: Date()
            )
            duos.append(created.0)
            save()
            requestPublish()
            await startHearingAboutChanges()
            return created
        } catch {
            Diagnostics.log("could not start a duo: \(error)")
            sheetError = Self.message(for: error)
            return nil
        }
    }

    /// The share again, for an invite that has not been answered yet.
    func shareForInvite(to duo: DuoState) async -> CKShare? {
        guard usesCloud else { return nil }
        do {
            return try await service.share(for: duo, makingAgainIfMissing: true)
        } catch {
            Diagnostics.log("could not load a duo's share: \(error)")
            notice = Self.message(for: error)
            return nil
        }
    }

    var container: CKContainer { service.container }

    /// An invite was opened, from a link, with the app running or not.
    func received(_ metadata: CKShare.Metadata) {
        let isSubscribed = StoreManager.shared.isSubscribed
        guard let zone = service.duoZone(of: metadata) else {
            Diagnostics.log("ignored a CloudKit share that is not a duo")
            return
        }
        if metadata.participantRole == .owner {
            notice = "That is your own invite. Send it to the person you want to team up with."
            return
        }
        if duos.contains(where: { $0.id == zone.id && !$0.hasEnded }) {
            Task { await refresh() }
            return
        }
        guard canAddDuo(isSubscribed: isSubscribed) else {
            let most = DuoLimit.maximum(isSubscribed: isSubscribed)
            notice = most == 1
                ? "You are already in a duo. Leave it first, then open the invite again."
                : "You are already in \(most) duos. Leave one first, then open the invite again."
            return
        }
        pendingInvite = PendingInvite(id: zone.id, metadata: metadata)
    }

    /// Says yes to an invite, under the first name given.
    func join(_ invite: PendingInvite, named rawName: String) async -> Bool {
        let name = DuoState.cleanedName(rawName)
        guard usesCloud, !name.isEmpty, let zone = service.duoZone(of: invite.metadata) else { return false }
        isWorking = true
        defer { isWorking = false }

        DuoCache.setMyDisplayName(name)
        let skin = AppSettings.shared.activeMascotSkin.rawValue
        do {
            try await service.accept(invite.metadata)
            // Saved the moment the invite is accepted. iCloud already counts this person
            // in, so whatever happens next, the duo has to be here to carry on from. The
            // skin is left empty, which is how `flush` knows the name and skin are owed.
            let joined = DuoState(
                id: zone.id,
                zoneName: zone.zoneID.zoneName,
                zoneOwnerName: zone.zoneID.ownerName,
                myRole: .partner,
                createdAt: Date(),
                ownerDisplayName: "",
                partnerDisplayName: name,
                ownerSkin: "",
                partnerSkin: "",
                statuses: [],
                shareURL: nil,
                partnerHasJoined: true,
                endedAt: nil
            )
            duos.removeAll { $0.id == joined.id }
            duos.append(joined)
            save()

            // A zone that was accepted a moment ago can take a moment to appear on this
            // side, and "not found" in that moment does not mean the duo is over. Any
            // other failure is not the end of the join either: `flush` sends it later.
            for attempt in 1...3 {
                do {
                    try await service.writeIdentity(name: name, skin: skin, in: joined)
                    update(joined.id) { $0.partnerSkin = skin }
                    break
                } catch {
                    Diagnostics.log("name and skin not sent yet after joining (try \(attempt)): \(error)")
                    guard DuoRetry.verdict(for: error) == .ended, attempt < 3 else { break }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            await refresh()
            requestPublish()
            await startHearingAboutChanges()
            return true
        } catch {
            Diagnostics.log("could not join a duo: \(error)")
            sheetError = DuoRetry.verdict(for: error) == .ended
                ? "That invite is no longer open. Ask for a new one."
                : Self.message(for: error)
            return false
        }
    }

    /// Leaves a duo, or clears one that has already ended. The owner leaving deletes the
    /// zone. A partner leaving takes themselves out of the share.
    func leave(_ duo: DuoState) async {
        guard usesCloud else {
            duos.removeAll { $0.id == duo.id }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            // An ended duo the partner was in has nothing left to leave. One the owner
            // had still has its zone, which goes now.
            if !(duo.hasEnded && duo.myRole == .partner) {
                try await service.leave(duo)
            }
            duos.removeAll { $0.id == duo.id }
            save()
            DuoNotifier.withdrawAll(for: duo.id)
        } catch {
            Diagnostics.log("could not leave a duo: \(error)")
            notice = Self.message(for: error)
        }
    }

    // MARK: - Plumbing

    private func update(_ id: UUID, _ change: (inout DuoState) -> Void) {
        guard let index = duos.firstIndex(where: { $0.id == id }) else { return }
        var duo = duos[index]
        change(&duo)
        guard duo != duos[index] else { return }
        duos[index] = duo
        save()
    }

    private func markEnded(_ id: UUID) {
        update(id) { if $0.endedAt == nil { $0.endedAt = Date() } }
    }

    private func save() {
        guard usesCloud else { return }
        DuoCache.save(duos)
        WidgetCenter.shared.reloadTimelines(ofKind: DuoCache.widgetKind)
    }

    private static func account(from status: CKAccountStatus) -> Account {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .unknown
        @unknown default: return .unknown
        }
    }

    static func message(for error: Error) -> String {
        guard let error = error as? CKError else { return "That did not work. Please try again." }
        switch error.code {
        case .notAuthenticated:
            return "Sign in to iCloud in Settings, then try again."
        case .networkUnavailable, .networkFailure:
            return "No connection right now. Try again in a bit."
        case .quotaExceeded:
            return "Your iCloud storage is full, so this could not be saved."
        case .zoneBusy, .requestRateLimited, .serviceUnavailable:
            return "iCloud is busy right now. Try again in a minute."
        default:
            return "That did not work. Please try again."
        }
    }

    #if DEBUG
    /// Sample duos for looking at the card and the screen where iCloud cannot be signed
    /// in to, which is every simulator. Compiled out of Release.
    private static func previewDuos() -> [DuoState] {
        let now = Date()
        let calendar = Calendar.current
        func day(_ offset: Int) -> String {
            DayKey.key(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
        }
        var statuses: [DuoDayStatus] = []
        for offset in 1...4 {
            for role in DuoRole.allCases {
                statuses.append(DuoDayStatus(role: role, day: day(offset), goalMet: true, progressBucket: 100, updatedAt: now))
            }
        }
        statuses.append(DuoDayStatus(role: .partner, day: day(0), goalMet: false, progressBucket: 50, updatedAt: now))

        func duo(_ partner: String, skin: String, statuses: [DuoDayStatus], joined: Bool, ended: Bool = false) -> DuoState {
            let id = UUID()
            return DuoState(
                id: id,
                zoneName: DuoRecordName.zoneName(for: id),
                zoneOwnerName: CKCurrentUserDefaultName,
                myRole: .owner,
                createdAt: now,
                ownerDisplayName: "Jonathon",
                partnerDisplayName: partner,
                ownerSkin: MascotSkin.classic.rawValue,
                partnerSkin: skin,
                statuses: statuses,
                shareURL: nil,
                partnerHasJoined: joined,
                endedAt: ended ? now : nil
            )
        }
        var sam = duo("Sam", skin: MascotSkin.forest.rawValue, statuses: statuses, joined: true)
        sam.nudges = [DuoNudge.make(from: .partner, preset: .sipWithMe, now: now.addingTimeInterval(-40 * 60))]
        return [
            sam,
            duo("", skin: "", statuses: [], joined: false),
            duo("Alex", skin: MascotSkin.grape.rawValue, statuses: [], joined: true, ended: true),
        ]
    }
    #endif
}
