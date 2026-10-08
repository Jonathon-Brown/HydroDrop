#if DUO_V2
import Foundation
import UserNotifications

/// One notification, waiting or on screen, as much of it as Duo reads. `UNNotification` has no
/// initialiser a test can call, so the notifier reads this instead and the system's own types stay
/// in `DuoSystemNotificationCenter`.
struct DuoNotificationRecord {
    var identifier: String
    var threadIdentifier: String
    var userInfo: [AnyHashable: Any]
}

/// The few things the notifier asks of `UNUserNotificationCenter`.
@MainActor
protocol DuoNotificationCentering: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
    func pendingRecords() async -> [DuoNotificationRecord]
    func deliveredRecords() async -> [DuoNotificationRecord]
    func removePending(withIdentifiers identifiers: [String])
    func removeDelivered(withIdentifiers identifiers: [String])
}

@MainActor
final class DuoSystemNotificationCenter: DuoNotificationCentering {
    private let center = UNUserNotificationCenter.current()

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }

    func pendingRecords() async -> [DuoNotificationRecord] {
        await center.pendingNotificationRequests().map {
            DuoNotificationRecord(identifier: $0.identifier, threadIdentifier: $0.content.threadIdentifier, userInfo: $0.content.userInfo)
        }
    }

    func deliveredRecords() async -> [DuoNotificationRecord] {
        await center.deliveredNotifications().map {
            DuoNotificationRecord(identifier: $0.request.identifier, threadIdentifier: $0.request.content.threadIdentifier,
                                  userInfo: $0.request.content.userInfo)
        }
    }

    func removePending(withIdentifiers identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(withIdentifiers identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

/// Duo's local notifications (final design §9.2, §9.4, §9.5, §12.2, §12.3): the fallback for news
/// the server's pushes did not bring (no token yet, a push Apple dropped), held to the waking
/// window, and the tidying of the Duo notifications already on the phone, local and remote alike.
///
/// Everything Duo posts or reads is named the server's way, so one rule finds both: the thread is
/// `hydrodrop.duo.<lowercase duo id>`, the APNs payload's `thread-id`, and a local request is
/// `hydrodrop.duo.` and the event's ledger key, so the same news announced twice is one request.
/// A local one's `userInfo` is shaped like a remote payload, so a tap on either is read by the one
/// parser (`DuoPushPayload.parse(userInfo:)`). The words are HydroCore's (`DuoAnnouncement.title`
/// and `body`); a push's come from `Localizable.strings` and say the same.
///
/// `LegacyDuoCleanup` withdraws every notification named `hydrodrop.duo.` on a phone that ran the
/// iCloud Duo's TestFlight builds. It does that once per phone (its local half, behind
/// `legacyDuoCleanup.v1.localDone`), so it can never take a held announcement made here.
@MainActor
final class DuoNotifier: DuoAnnouncing {
    static let prefix = "hydrodrop.duo."

    private let dependencies: DuoDependencies
    private let center: DuoNotificationCentering
    /// Removals the synchronous entry points started, so a delivery waits for them: a removal that
    /// read the list before a new announcement went in and removed after would take it too.
    private var removals: [Task<Void, Never>] = []

    convenience init(dependencies: DuoDependencies) {
        self.init(dependencies: dependencies, center: DuoSystemNotificationCenter())
    }

    init(dependencies: DuoDependencies, center: DuoNotificationCentering) {
        self.dependencies = dependencies
        self.center = center
    }

    // MARK: - DuoAnnouncing

    func deliver(_ announcements: [DuoAnnouncement], now: Date) async -> [String] {
        // Turned off is an answer, not a refusal: nothing is posted and nothing is handed back to
        // be tried again.
        guard dependencies.cache.notificationsEnabled, !announcements.isEmpty else { return [] }
        // Read before the first `await`: these announcements were made before it, so a wipe that
        // lands while an earlier removal is still running took their duo and its partner's name
        // too. Read after the wait, it saw only wipes made later, and a nudge naming the partner
        // could go on screen after Delete my Duo data.
        // The toggle is read again at each of the same points, for the same reason: turned off while
        // an earlier removal held this delivery up, it withdrew what was held then, and a nudge added
        // after it would still have come up at 08:00.
        let epoch = dependencies.host.wipeEpoch
        await waitForRemovals()
        guard dependencies.host.wipeEpoch == epoch, dependencies.cache.notificationsEnabled else { return [] }
        let window = dependencies.wakingWindow()
        let calendar = dependencies.clock.calendar
        var refused: [String] = []
        for announcement in announcements {
            // A wipe while these were going in (Delete my Duo data, Start fresh) took the duo and
            // its partner's name: nothing more of it goes on screen. Duo's toggle turned off means
            // the person does not want the rest either.
            guard dependencies.host.wipeEpoch == epoch, dependencies.cache.notificationsEnabled else { break }
            // A nudge whose hold would end more than 12 hours after it was sent is not shown at
            // all, which is what the server does with a push it held that long (§9.5's drop at fire
            // time): it is old news by then. That is an answer, not a refusal, so it is not handed
            // back to be tried again. Its sending time is the cached duo's; a nudge the cache does
            // not hold yet is taken to have been sent now, the latest it can have been.
            if case .nudge = announcement.kind {
                let sentAt = dependencies.host.duo(announcement.duoID)?.allNudges.first { $0.id == announcement.key }?.createdAt ?? now
                if Self.holdOutlivesTheNudge(sentAt: sentAt, now: now, window: window, calendar: calendar) { continue }
            }
            let request = Self.request(for: announcement, now: now, window: window, calendar: calendar)
            do {
                try await center.add(request)
            } catch {
                refused.append(announcement.key)
                continue
            }
            if dependencies.host.wipeEpoch != epoch {
                // The wipe's own removal may have read the list before this one went in.
                center.removePending(withIdentifiers: [request.identifier])
                center.removeDelivered(withIdentifiers: [request.identifier])
            } else if !dependencies.cache.notificationsEnabled {
                // So may the toggle's, which takes only what is still held (`removeAllPending`).
                center.removePending(withIdentifiers: [request.identifier])
            }
        }
        return refused
    }

    func hasDeliveredRemote(forKey key: String) async -> Bool {
        await center.deliveredRecords().contains { record in
            DuoPushPayload.parse(userInfo: record.userInfo)?.ledgerKeys.contains(key) == true
        }
    }

    /// Everything on the duo's thread, waiting or on screen, except a delivered notice that the duo
    /// ended (D75). The app ends a duo locally when the server says it has (a flush that meets
    /// `409 duo_ended`, a fetch), and taking the thread down then took the pushed "Your duo has
    /// ended" with it, often before the person saw it: the one notice D36 promises even with
    /// Duo's notifications off. `removeAllDelivered()` still takes everything.
    func removeDelivered(for duoID: UUID) {
        // Lowercase is the server's spelling and this one's; the iCloud Duo named its threads with
        // the uppercase `uuidString`, which a tester's phone may still have on screen.
        let threads: Set<String> = [Self.threadIdentifier(for: duoID), Self.prefix + duoID.uuidString]
        startRemoval(pending: { threads.contains($0.threadIdentifier) },
                     delivered: { threads.contains($0.threadIdentifier) && !Self.isEndedNotice($0) })
    }

    /// Everything on the duo's thread, the delivered `ended` notice too: Clear, the person taking an
    /// ended duo off the screen on purpose (§12.2), after which nothing of it should stay.
    func removeDeliveredIncludingEnded(for duoID: UUID) {
        let threads: Set<String> = [Self.threadIdentifier(for: duoID), Self.prefix + duoID.uuidString]
        let onThread: (DuoNotificationRecord) -> Bool = { threads.contains($0.threadIdentifier) }
        startRemoval(pending: onThread, delivered: onThread)
    }

    func removeAllDelivered() {
        let isDuos: (DuoNotificationRecord) -> Bool = { $0.threadIdentifier.hasPrefix(Self.prefix) || $0.identifier.hasPrefix(Self.prefix) }
        startRemoval(pending: isDuos, delivered: isDuos)
    }

    /// Turning Duo's notifications off: an announcement still held for the morning is withdrawn,
    /// so nothing the person has just said they do not want appears at 08:00. What is already on
    /// screen stays: it was shown while they wanted it.
    func removeAllPending() {
        startRemoval(pending: { $0.threadIdentifier.hasPrefix(Self.prefix) || $0.identifier.hasPrefix(Self.prefix) }, delivered: nil)
    }

    // MARK: - Building a notification

    static func threadIdentifier(for duoID: UUID) -> String { prefix + duoID.uuidString.lowercased() }

    /// Whether a nudge sent at `sentAt` would, held to the waking window, be shown more than 12 hours
    /// after it was sent (`DuoNudgeRules.announceWithin`, the bound the server's own drop uses, which
    /// keeps a nudge exactly 12 hours old).
    static func holdOutlivesTheNudge(sentAt: Date, now: Date, window: (start: Int, end: Int), calendar: Calendar) -> Bool {
        guard let shownAt = DuoQuietHours.holdUntil(now, startMinutes: window.start, endMinutes: window.end, calendar: calendar) else { return false }
        return shownAt.timeIntervalSince(sentAt) > DuoNudgeRules.announceWithin
    }

    /// A delivered push saying the duo ended.
    private static func isEndedNotice(_ record: DuoNotificationRecord) -> Bool {
        if case .ended = DuoPushPayload.parse(userInfo: record.userInfo)?.kind { return true }
        return false
    }

    static func request(for announcement: DuoAnnouncement, now: Date, window: (start: Int, end: Int), calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = announcement.title
        content.body = announcement.body
        content.sound = .default
        content.threadIdentifier = threadIdentifier(for: announcement.duoID)
        // Only a nudge carries the reminder's Log a glass and Snooze buttons, as a pushed one does.
        if announcement.isActionable { content.categoryIdentifier = ReminderManager.reminderCategoryIdentifier }
        content.userInfo = userInfo(for: announcement)
        // Held, not dropped, until the waking window opens (§9.4), by the rule the server holds its
        // pushes by. A time-interval trigger, since the hold is an instant and a calendar trigger
        // would be read again in whatever zone the phone is in when it fires.
        let trigger = DuoQuietHours.holdUntil(now, startMinutes: window.start, endMinutes: window.end, calendar: calendar).map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSince(now)), repeats: false)
        }
        return UNNotificationRequest(identifier: prefix + announcement.key, content: content, trigger: trigger)
    }

    /// What a remote payload of the same kind carries (§9.2): `v`, `t`, the lowercase duo id and the
    /// nudge's `id` or the goal's `day`. No `seq`, which a local announcement has none of, so a tap
    /// always fetches (KV17).
    static func userInfo(for announcement: DuoAnnouncement) -> [String: Any] {
        var info: [String: Any] = ["v": 1, "duo": announcement.duoID.uuidString.lowercased()]
        switch announcement.kind {
        case .nudge:
            info["t"] = "nudge"
            info["id"] = announcement.key
        case .partnerMetGoal:
            info["t"] = "goal_met"
            // The key is `met|<duo id>|<day>` (`DuoLedger.goalKey`).
            if let day = announcement.key.split(separator: "|").last { info["day"] = String(day) }
        }
        return info
    }

    // MARK: - Removing

    /// Removes what each matcher picks from the waiting and the delivered lists; a nil matcher leaves
    /// that list alone.
    private func startRemoval(pending pendingMatch: ((DuoNotificationRecord) -> Bool)?,
                              delivered deliveredMatch: ((DuoNotificationRecord) -> Bool)?) {
        let center = center
        removals.append(Task {
            if let pendingMatch {
                let pending = await center.pendingRecords().filter(pendingMatch).map(\.identifier)
                if !pending.isEmpty { center.removePending(withIdentifiers: pending) }
            }
            if let deliveredMatch {
                let delivered = await center.deliveredRecords().filter(deliveredMatch).map(\.identifier)
                if !delivered.isEmpty { center.removeDelivered(withIdentifiers: delivered) }
            }
        })
    }

    /// Returns once every removal started so far has finished. A delivery waits on it, and so can a test.
    func waitForRemovals() async {
        while !removals.isEmpty {
            let running = removals
            removals = []
            for removal in running { await removal.value }
        }
    }
}
#endif
