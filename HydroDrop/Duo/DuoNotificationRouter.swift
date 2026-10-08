#if DUO_V2
import UserNotifications

/// Where a tapped Duo notification takes the app: what `AppRouter` offers for it.
@MainActor
protocol DuoNotificationRouting: AnyObject {
    var showingDuoScreen: Bool { get set }
}

extension AppRouter: DuoNotificationRouting {}

/// Duo's part of the notification centre's delegate (`NotificationActionHandler`): a tap on a Duo
/// notification, and a Duo push that arrives while the app is on screen (final design §9.2, §9.7).
/// Local and remote ones are read the same way, through `DuoPushPayload.parse(userInfo:)`, since
/// `DuoNotifier` gives a local one a remote one's `userInfo`.
///
/// Anything that is not a Duo notification is left alone, which is what keeps the reminders, the
/// snooze and the weekly recap exactly as they were. CloudKit's silent pushes never come this way
/// at all: they reach the app delegate, which Duo does not answer (`DuoAppDelegate`).
@MainActor
enum DuoNotificationRouter {
    /// A Duo push in the foreground is shown as it would be in the background, banner, list and
    /// sound, since the person asked to be told.
    static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    /// True if the tap was Duo's and has been dealt with, so the existing handler stops. It returns
    /// as soon as it has asked for the screen and started the fetch. The router and the store are
    /// the app's unless a test hands it others.
    static func handle(_ response: UNNotificationResponse, router: DuoNotificationRouting? = nil, store: DuoStore? = nil) async -> Bool {
        route(userInfo: response.notification.request.content.userInfo, actionIdentifier: response.actionIdentifier,
              router: router ?? AppRouter.shared, store: store ?? DuoStore.shared) != nil
    }

    /// The options for a Duo notification arriving with the app on screen, or nil for anyone else's.
    static func willPresent(_ notification: UNNotification, store: DuoStore? = nil) async -> UNNotificationPresentationOptions? {
        willPresent(userInfo: notification.request.content.userInfo, isPush: isPush(notification.request.trigger),
                    store: store ?? DuoStore.shared)?.options
    }

    /// Whether a notification came from APNs, which is the only kind a fetch is wanted for. A local
    /// announcement has a time-interval trigger, or none when it was shown at once.
    static func isPush(_ trigger: UNNotificationTrigger?) -> Bool {
        trigger is UNPushNotificationTrigger
    }

    /// A tap: nil if it was not Duo's to answer, else the fetch it started.
    ///
    /// It asks for one thing, the Duo screen, and leaves the order of getting there to the root,
    /// which opens Settings when nothing else is up and Settings' Duo row then reads and lowers the
    /// flag. It used to raise Settings itself in the same turn, whatever was on screen, and a sheet
    /// asked for from under another one, or while one is leaving, is dropped (CLAUDE.md).
    ///
    /// The fetch is started and not waited for: `didReceive` keeps the app awake until it returns,
    /// and the screen being opened refreshes on its own.
    @discardableResult
    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String, router: DuoNotificationRouting,
                      store: DuoStore) -> Task<Void, Never>? {
        guard let payload = DuoPushPayload.parse(userInfo: userInfo) else { return nil }
        // A nudge carries the reminder's Log a glass and Snooze buttons, which are the reminder
        // handler's to answer; only a plain tap opens Duo.
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        router.showingDuoScreen = true
        // A tapped notification is a reason to fetch (§9.7).
        return Task { await store.pushArrived(payload) }
    }

    /// The options, and the fetch the push is a reason for, if it is one. The fetch is not waited
    /// for: iOS holds the banner until this answers, and a fetch can take as long as the network
    /// does. A local announcement shown in the foreground starts no fetch: a fetch is what just
    /// made it, and its payload has no `seq`, which the push gate reads as "always fetch".
    static func willPresent(userInfo: [AnyHashable: Any], isPush: Bool,
                            store: DuoStore) -> (options: UNNotificationPresentationOptions, fetch: Task<Void, Never>?)? {
        guard let payload = DuoPushPayload.parse(userInfo: userInfo) else { return nil }
        return (foregroundPresentation, isPush ? Task { await store.pushArrived(payload) } : nil)
    }
}
#endif
