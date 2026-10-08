import Foundation
import UserNotifications

/// The Sunday evening nudge that there is a recap waiting.
///
/// Deliberately its own identifier and its own category, outside the reminder prefix,
/// so rebuilding the drinking reminders never disturbs it and it never counts against
/// the slots those reminders are rationing.
final class WeeklyRecapNotifier {
    static let shared = WeeklyRecapNotifier()

    static let categoryIdentifier = "HYDRO_WEEKLY_RECAP"
    private let identifier = "hydrodrop.weeklyRecap"
    private let center = UNUserNotificationCenter.current()

    /// Sunday, in `DateComponents` terms, where the week starts on Sunday as weekday 1.
    private let weekday = 1
    private let hour = 19

    private init() {}

    /// Installs or removes the weekly notification to match the current setting.
    ///
    /// Safe to call as often as anything changes: it is one repeating request under a
    /// fixed identifier, so re-adding it replaces rather than stacks.
    func refresh() {
        assert(Thread.isMainThread, "AppSettings is main-actor state; snapshot it on the main thread")
        let wanted = AppSettings.shared.weeklyRecapActive && AppSettings.shared.remindersEnabled

        guard wanted else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }

        Task { await install() }
    }

    private func install() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your week in water"
        content.body = "See how the last seven days went."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0

        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
            )
        } catch {
            Diagnostics.log("could not schedule the weekly recap: \(error)")
        }
    }
}

/// Where a notification tap wants the app to go.
///
/// A tiny router rather than a deep-link scheme: there is exactly one destination, and
/// the handler that receives the tap has no view to push from.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var showingWeeklyRecap = false
    /// Set by the weekly recap's link. History picks it up and scrolls to Insights.
    @Published var pendingInsights = false

    /// A bottle tag that was tapped or scanned and has not been dealt with yet.
    ///
    /// The Today screen owns logging and the undo toast, so it is the one that picks
    /// this up. It is parked here because the tap can arrive before that screen exists:
    /// a tag read with the app closed launches it straight into this.
    @Published var pendingBottleTagID: UUID?

    /// Settings, which opens as a sheet from the gear at the top of Today and History.
    /// Anything above that has somewhere else to take the user closes it first.
    @Published var showingSettings = false

    #if DUO_V2
    /// A Duo invite that arrived as a link or a scanned QR code and has not been dealt with
    /// yet. Set by `handle(_:)`, which can run before any screen exists; the root view takes it,
    /// closes Settings if it is open, and hands it to `DuoStore.receive(_:)` (final design §4.2).
    @Published var pendingDuoLink: DuoParsedInvite?

    /// Raised to bring the Duo screen forward, from a tapped Duo notification. Settings opens
    /// first, and the Duo row inside it takes this and lowers it again.
    @Published var showingDuoScreen = false

    /// Whether the code-entry sheet, which the Duo screen presents over Settings or over Today, is
    /// up: from when it appears until it has finished leaving. The join sheet the root presents
    /// for the code it just stored waits on this, for the reason `settingsIsOnScreen` exists: a
    /// sheet requested while another is still dismissing is dropped. The Duo screen also closes
    /// Settings from that sheet's `onDismiss`, never in the turn the sheet closes itself, since two
    /// stacked sheets must not be dismissed together.
    @Published var duoEntrySheetIsOnScreen = false
    #endif

    /// Whether the Settings sheet is actually up: from when it appears until it has
    /// finished sliding away, which is after `showingSettings` has already gone false.
    /// Whatever wants to present from underneath waits on this, because a sheet or an
    /// alert asked for while another sheet is still on its way out is dropped, not
    /// queued.
    @Published private(set) var settingsIsOnScreen = false

    func settingsDidAppear() { settingsIsOnScreen = true }
    func settingsDidDismiss() { settingsIsOnScreen = false }

    private init() {}

    /// Takes an address the app was opened with, from a tag read in the background, a
    /// link, or the in-app scanner. Returns false when it is not a bottle tag, so the
    /// caller knows nothing was done with it.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        #if DUO_V2
        if let invite = DuoLink.parse(url) {
            pendingDuoLink = invite
            return true
        }
        #endif
        guard let tagID = BottleTag.tagID(from: url) else { return false }
        pendingBottleTagID = tagID
        return true
    }
}
