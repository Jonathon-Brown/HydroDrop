#if DUO_V2
import ObjectiveC
import UIKit
import UserNotifications
import XCTest
@testable import HydroDrop

@MainActor
private final class FRouter: DuoNotificationRouting {
    var showingDuoScreen = false
}

/// Real `UNNotification`, `UNNotificationResponse` and `UNPushNotificationTrigger` objects, which
/// have no public initialiser, made through the class methods UserNotifications makes them with (the
/// re-verifier's way). A test skips, rather than crashes, on a system that no longer has one.
private enum FNotes {
    static func pushTrigger() throws -> UNNotificationTrigger {
        let selector = NSSelectorFromString("triggerWithContentAvailable:mutableContent:")
        guard let method = class_getClassMethod(UNPushNotificationTrigger.self, selector) else { throw XCTSkip("no push trigger maker on this system") }
        typealias Maker = @convention(c) (AnyClass, Selector, Bool, Bool) -> Unmanaged<AnyObject>
        let made = unsafeBitCast(method_getImplementation(method), to: Maker.self)(UNPushNotificationTrigger.self, selector, false, false)
        return try XCTUnwrap(made.takeUnretainedValue() as? UNNotificationTrigger)
    }

    static func notification(_ userInfo: [AnyHashable: Any], trigger: UNNotificationTrigger?, category: String = "") throws -> UNNotification {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        content.categoryIdentifier = category
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        let selector = NSSelectorFromString("notificationWithRequest:date:")
        guard (UNNotification.self as AnyObject).responds(to: selector) else { throw XCTSkip("no notification maker on this system") }
        return try XCTUnwrap((UNNotification.self as AnyObject).perform(selector, with: request, with: Date())?.takeUnretainedValue() as? UNNotification)
    }

    static func response(_ notification: UNNotification, action: String) throws -> UNNotificationResponse {
        let selector = NSSelectorFromString("responseWithNotification:actionIdentifier:")
        guard (UNNotificationResponse.self as AnyObject).responds(to: selector) else { throw XCTSkip("no response maker on this system") }
        return try XCTUnwrap((UNNotificationResponse.self as AnyObject).perform(selector, with: notification, with: action)?.takeUnretainedValue()
            as? UNNotificationResponse)
    }
}

/// A sync whose fetch for a push waits until the test lets it go.
@MainActor
private final class FHeldSync: DuoSyncing {
    let gate = DuoFirstOf()
    private(set) var arrivals = 0
    private(set) var finished = 0
    func activate(logReader: DuoLogReading) {}
    func logChanged(_ summary: DuoLogSummary) {}
    func refresh() async {}
    func flush() async {}
    func backgroundRefresh() async -> Bool { false }
    func pushArrived(_ payload: DuoPushPayload) async {
        arrivals += 1
        await gate.wait()
        finished += 1
    }
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async {}
}

/// Taps on Duo notifications and Duo pushes in the foreground (final design §9.2, §9.7), and the
/// notification centre's delegate leaving everything else alone.
@MainActor
final class DuoNotificationRouterTests: XCTestCase {
    private let nudgeID = "nudge-8F2A0000-0000-4000-8000-000000000002"

    /// What a pushed nudge's payload holds besides `aps` (§9.2's iOS example).
    private var pushedNudge: [AnyHashable: Any] {
        ["aps": ["alert": ["title-loc-key": "duo.nudge.title", "title-loc-args": ["Alex"], "loc-key": "duo.nudge.sipWithMe"],
                 "sound": "default", "thread-id": "hydrodrop.duo.6d2a0000-0000-4000-8000-000000000001", "category": "HYDRO_REMINDER"],
         "v": 1, "t": "nudge", "duo": "6d2a0000-0000-4000-8000-000000000001", "id": nudgeID, "seq": 419]
    }

    func testATapOnADuoNotificationAsksForTheDuoScreenAndFetches() async throws {
        let kit = DuoTestKit()
        let router = FRouter()
        let fetch = try XCTUnwrap(DuoNotificationRouter.route(userInfo: pushedNudge, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                              router: router, store: kit.store))
        XCTAssertTrue(router.showingDuoScreen)
        await fetch.value
        XCTAssertEqual(kit.sync.calls, ["pushArrived"], "a tap is a reason to fetch (§9.7)")
    }

    /// One intent and nothing else (review F2): the root opens Settings when nothing else is up, and
    /// the Duo row inside it reads and lowers the flag. Raising Settings here, in the same turn and
    /// whatever was on screen, is what a sheet asked for from under another one loses. Every flag is
    /// set to a known value first: compared with whatever an earlier test left, a regression that
    /// raises Settings went unseen once Settings was already up (review F18).
    func testATapRaisesOnlyTheDuoScreensFlag() async throws {
        let router = AppRouter.shared
        let saved = (router.showingSettings, router.showingWeeklyRecap, router.pendingInsights, router.pendingBottleTagID, router.showingDuoScreen)
        defer {
            router.showingSettings = saved.0
            router.showingWeeklyRecap = saved.1
            router.pendingInsights = saved.2
            router.pendingBottleTagID = saved.3
            router.showingDuoScreen = saved.4
        }
        for recapUp in [false, true] {
            router.showingSettings = false
            router.showingWeeklyRecap = recapUp
            router.pendingInsights = false
            router.pendingBottleTagID = nil
            router.showingDuoScreen = false
            let kit = DuoTestKit()
            let fetch = try XCTUnwrap(DuoNotificationRouter.route(userInfo: pushedNudge, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                                  router: router, store: kit.store))
            await fetch.value
            XCTAssertTrue(router.showingDuoScreen)
            XCTAssertFalse(router.showingSettings, "Settings is the root's to open, in its order")
            XCTAssertEqual(router.showingWeeklyRecap, recapUp, "a sheet that is up is left up")
            XCTAssertFalse(router.pendingInsights)
            XCTAssertNil(router.pendingBottleTagID)
        }
    }

    // MARK: - The real entry points, with real notification objects (review F19)

    /// `handle(_:)` as iOS calls it, through a real `UNNotificationResponse`: it reads the payload and
    /// the action from the response, raises the flag, and returns before the fetch has finished.
    func testTheRealHandleReadsTheResponseAndReturnsBeforeTheFetch() async throws {
        let kit = DuoTestKit()
        let sync = FHeldSync()
        kit.dependencies.sync = sync
        let router = FRouter()
        let tap = try FNotes.response(try FNotes.notification(pushedNudge, trigger: try FNotes.pushTrigger(), category: "HYDRO_REMINDER"),
                                      action: UNNotificationDefaultActionIdentifier)
        // The fetch would end a second from now.
        let release = Task { try? await Task.sleep(nanoseconds: 1_000_000_000); sync.gate.open() }
        let start = Date()
        let handled = await DuoNotificationRouter.handle(tap, router: router, store: kit.store)
        let took = Date().timeIntervalSince(start)
        XCTAssertTrue(handled)
        XCTAssertTrue(router.showingDuoScreen)
        XCTAssertLessThan(took, 0.5, "didReceive waited \(took) s for the fetch")
        XCTAssertEqual(sync.finished, 0)
        await release.value
        for _ in 0..<50 where sync.finished == 0 { await Task.yield() }
        XCTAssertEqual(sync.arrivals, 1, "the fetch was still started")
        XCTAssertEqual(sync.finished, 1)

        let glass = try FNotes.response(try FNotes.notification(pushedNudge, trigger: try FNotes.pushTrigger(), category: "HYDRO_REMINDER"),
                                        action: ReminderManager.logGlassActionIdentifier)
        let other = FRouter()
        let glassHandled = await DuoNotificationRouter.handle(glass, router: other, store: kit.store)
        XCTAssertFalse(glassHandled, "Log a glass is the reminder handler's")
        XCTAssertFalse(other.showingDuoScreen)
    }

    /// `willPresent(_:)` as iOS calls it: a push from APNs is shown and fetched; a local announcement,
    /// shown at once or held, is shown and not fetched; anyone else's gets nothing.
    func testTheRealWillPresentFetchesOnlyForAPush() async throws {
        let local = DuoNotifier.userInfo(for: DuoAnnouncement(key: nudgeID, duoID: DuoFixtures.duoID, partnerName: "Sam", kind: .nudge(presetID: "cheers")))
        let cases: [(String, [AnyHashable: Any], UNNotificationTrigger?, UNNotificationPresentationOptions?, Int)] = [
            ("a Duo push", pushedNudge, try FNotes.pushTrigger(), [.banner, .list, .sound], 1),
            ("a local announcement shown at once", local, nil, [.banner, .list, .sound], 0),
            ("a local announcement held to the morning", local, UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false), [.banner, .list, .sound], 0),
            ("a reminder", [:], UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false), nil, 0),
            ("a CloudKit push", ["ck": ["ce": 2], "aps": ["content-available": 1]], try FNotes.pushTrigger(), nil, 0),
        ]
        for (label, info, trigger, expected, fetches) in cases {
            let kit = DuoTestKit()
            let options = await DuoNotificationRouter.willPresent(try FNotes.notification(info, trigger: trigger), store: kit.store)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(options, expected, label)
            XCTAssertEqual(kit.sync.calls.filter { $0 == "pushArrived" }.count, fetches, label)
        }
    }

    func testOnlyAnAPNsTriggerIsAPush() throws {
        XCTAssertTrue(DuoNotificationRouter.isPush(try FNotes.pushTrigger()))
        XCTAssertFalse(DuoNotificationRouter.isPush(nil), "a local one shown at once has no trigger")
        XCTAssertFalse(DuoNotificationRouter.isPush(UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
        XCTAssertFalse(DuoNotificationRouter.isPush(UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 8), repeats: false)))
    }

    /// The delegate itself: `?? []` for anything not Duo's, which is what iOS did while the delegate
    /// did not implement `willPresent`, and the banner for a Duo push.
    func testTheDelegatesWillPresentAnswersNothingForAnyoneElse() async throws {
        let handler = NotificationActionHandler.shared
        let center = UNUserNotificationCenter.current()
        let reminder = try FNotes.notification([:], trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false),
                                               category: ReminderManager.reminderCategoryIdentifier)
        let recap = try FNotes.notification(["kind": "recap"], trigger: nil, category: WeeklyRecapNotifier.categoryIdentifier)
        let cloudKit = try FNotes.notification(["ck": ["ce": 2], "aps": ["content-available": 1]], trigger: try FNotes.pushTrigger())
        for notification in [reminder, recap, cloudKit] {
            let options = await handler.userNotificationCenter(center, willPresent: notification)
            XCTAssertEqual(options, [], "\(notification.request.content.categoryIdentifier)")
        }
        let duo = try FNotes.notification(pushedNudge, trigger: try FNotes.pushTrigger(), category: "HYDRO_REMINDER")
        let duoOptions = await handler.userNotificationCenter(center, willPresent: duo)
        XCTAssertEqual(duoOptions, [.banner, .list, .sound])
    }

    /// A Duo tap through the delegate raises the Duo screen's flag and nothing else, and leaves the
    /// recap's own tap to open the recap.
    func testATapThroughTheDelegateRaisesOnlyTheDuoFlag() async throws {
        let router = AppRouter.shared
        let saved = (router.showingSettings, router.showingWeeklyRecap, router.showingDuoScreen)
        defer {
            router.showingSettings = saved.0
            router.showingWeeklyRecap = saved.1
            router.showingDuoScreen = saved.2
        }
        router.showingSettings = false
        router.showingWeeklyRecap = false
        router.showingDuoScreen = false
        let handler = NotificationActionHandler.shared
        let center = UNUserNotificationCenter.current()
        let tap = try FNotes.response(try FNotes.notification(pushedNudge, trigger: try FNotes.pushTrigger(), category: "HYDRO_REMINDER"),
                                      action: UNNotificationDefaultActionIdentifier)
        await handler.userNotificationCenter(center, didReceive: tap)
        XCTAssertTrue(router.showingDuoScreen)
        XCTAssertFalse(router.showingSettings)
        XCTAssertFalse(router.showingWeeklyRecap)
        router.showingDuoScreen = false
        let recap = try FNotes.response(try FNotes.notification(["kind": "recap"], trigger: nil, category: WeeklyRecapNotifier.categoryIdentifier),
                                        action: UNNotificationDefaultActionIdentifier)
        await handler.userNotificationCenter(center, didReceive: recap)
        XCTAssertTrue(router.showingWeeklyRecap, "the recap's tap is still the recap's")
        XCTAssertFalse(router.showingDuoScreen)
    }

    /// `didReceive` keeps the app awake until it returns, so the tap does not wait for the network
    /// (review F10): the fetch is started and handed back, and the route has returned before it runs.
    func testATapDoesNotWaitForTheFetch() async throws {
        let kit = DuoTestKit()
        let fetch = try XCTUnwrap(DuoNotificationRouter.route(userInfo: pushedNudge, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                              router: FRouter(), store: kit.store))
        XCTAssertTrue(kit.sync.calls.isEmpty, "returned before the fetch began")
        await fetch.value
        XCTAssertEqual(kit.sync.calls, ["pushArrived"])
    }

    func testEveryKindIsATapToTheDuoScreen() async {
        let duo = "6d2a0000-0000-4000-8000-000000000001"
        let payloads: [[AnyHashable: Any]] = [
            ["v": 1, "t": "goal_met", "duo": duo, "day": "2026-09-21", "seq": 3],
            ["v": 1, "t": "joined", "duo": duo, "seq": 1],
            ["v": 1, "t": "ended", "duo": duo, "seq": 9],
            ["v": 1, "t": "reconnected", "duo": duo, "seq": 9],
            ["v": 1, "t": "digest", "duo": duo, "kinds": ["goal_met", "nudge"], "seq": 9],
            ["v": 1, "t": "from_a_newer_server", "duo": duo],
        ]
        for payload in payloads {
            let kit = DuoTestKit()
            let router = FRouter()
            let fetch = DuoNotificationRouter.route(userInfo: payload, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                    router: router, store: kit.store)
            XCTAssertNotNil(fetch, "\(payload["t"] ?? "")")
            await fetch?.value
            XCTAssertTrue(router.showingDuoScreen)
        }
    }

    /// `DuoNotifier` gives a local announcement a remote payload's shape, so a tap reads the same.
    func testATapOnALocalAnnouncementIsReadTheSameWay() async {
        let kit = DuoTestKit()
        let router = FRouter()
        let info = DuoNotifier.userInfo(for: DuoAnnouncement(key: nudgeID, duoID: DuoFixtures.duoID, partnerName: "Sam", kind: .nudge(presetID: "cheers")))
        let fetch = DuoNotificationRouter.route(userInfo: info, actionIdentifier: UNNotificationDefaultActionIdentifier, router: router, store: kit.store)
        XCTAssertNotNil(fetch)
        await fetch?.value
        XCTAssertTrue(router.showingDuoScreen)
    }

    /// A nudge carries the reminder's buttons, and those are the reminder handler's to answer.
    func testTheLogAGlassAndSnoozeButtonsAreLeftToTheReminderHandler() async {
        for action in [ReminderManager.logGlassActionIdentifier, ReminderManager.snoozeActionIdentifier, UNNotificationDismissActionIdentifier] {
            let kit = DuoTestKit()
            let router = FRouter()
            let fetch = DuoNotificationRouter.route(userInfo: pushedNudge, actionIdentifier: action, router: router, store: kit.store)
            XCTAssertNil(fetch, action)
            XCTAssertFalse(router.showingDuoScreen, action)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(kit.sync.calls.isEmpty, action)
        }
    }

    func testAnythingThatIsNotDuosIsLeftAlone() async {
        let notDuo: [[AnyHashable: Any]] = [
            [:],
            ["aps": ["alert": "Time for a sip!"]],
            ["t": "nudge", "duo": "not-a-duo-id", "id": nudgeID],
            ["duo": "6d2a0000-0000-4000-8000-000000000001"],
            // A CloudKit push's payload, should one ever be routed here.
            ["ck": ["ce": 2, "cid": "iCloud.com.jonathonbrown.HydroDrop", "nid": "x"], "aps": ["content-available": 1]],
        ]
        for payload in notDuo {
            let kit = DuoTestKit()
            let router = FRouter()
            XCTAssertNil(DuoNotificationRouter.route(userInfo: payload, actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                     router: router, store: kit.store))
            XCTAssertFalse(router.showingDuoScreen)
            XCTAssertNil(DuoNotificationRouter.willPresent(userInfo: payload, isPush: true, store: kit.store), "\(payload)")
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(kit.sync.calls.isEmpty)
        }
    }

    func testADuoPushInTheForegroundIsShownAndFetched() async throws {
        let kit = DuoTestKit()
        let presented = try XCTUnwrap(DuoNotificationRouter.willPresent(userInfo: pushedNudge, isPush: true, store: kit.store))
        XCTAssertEqual(presented.options, [.banner, .list, .sound])
        await presented.fetch?.value
        XCTAssertEqual(kit.sync.calls, ["pushArrived"])
    }

    /// A local announcement shown in the foreground was made by a fetch that has just run, and its
    /// payload has no `seq`, which the push gate reads as "fetch": shown, but no fetch (review F10).
    func testALocalAnnouncementInTheForegroundIsShownWithoutAnotherFetch() async throws {
        let kit = DuoTestKit()
        let info = DuoNotifier.userInfo(for: DuoAnnouncement(key: nudgeID, duoID: DuoFixtures.duoID, partnerName: "Sam", kind: .nudge(presetID: "cheers")))
        let presented = try XCTUnwrap(DuoNotificationRouter.willPresent(userInfo: info, isPush: false, store: kit.store))
        XCTAssertEqual(presented.options, [.banner, .list, .sound])
        XCTAssertNil(presented.fetch)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(kit.sync.calls.isEmpty)
    }

    /// The delegate gained `willPresent`, which it did not implement before; for anything not Duo's
    /// it answers what iOS did then, no options.
    func testTheDelegateAnswersForegroundPushesNowAndStillHandlesTaps() {
        let handler = NotificationActionHandler.shared
        XCTAssertTrue(handler.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
        XCTAssertTrue(handler.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))))
    }
}

/// The app delegate Duo adds answers the push token and nothing else.
@MainActor
final class DuoAppDelegateTests: XCTestCase {
    func testItNeverTakesCloudKitsSilentPushes() {
        // SwiftData's CloudKit mirror is woken by these; an app delegate that implemented this would
        // stand between it and its pushes, and Duo sends none (§9.7).
        XCTAssertFalse(DuoAppDelegate().responds(to: #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))))
    }

    func testItAnswersTheTokenCallbacks() {
        let delegate = DuoAppDelegate()
        XCTAssertTrue(delegate.responds(to: #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))))
        XCTAssertTrue(delegate.responds(to: #selector(UIApplicationDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:))))
    }

    /// The app had no delegate before Duo, so anything else here would change what the app does.
    func testItAnswersNothingElse() {
        let delegate = DuoAppDelegate()
        let others: [Selector] = [
            #selector(UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)),
            #selector(UIApplicationDelegate.application(_:willFinishLaunchingWithOptions:)),
            #selector(UIApplicationDelegate.applicationDidBecomeActive(_:)),
            #selector(UIApplicationDelegate.applicationWillResignActive(_:)),
            #selector(UIApplicationDelegate.applicationDidEnterBackground(_:)),
            #selector(UIApplicationDelegate.application(_:open:options:)),
            #selector(UIApplicationDelegate.application(_:continue:restorationHandler:)),
            #selector(UIApplicationDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)),
            #selector(UIApplicationDelegate.application(_:configurationForConnecting:options:)),
        ]
        for selector in others {
            XCTAssertFalse(delegate.responds(to: selector), "\(selector)")
        }
        XCTAssertFalse((delegate as AnyObject) is UNUserNotificationCenterDelegate, "the notification centre's delegate stays NotificationActionHandler")
    }
}
#endif
