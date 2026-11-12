#if DUO_V2
import SwiftUI
import UIKit
import UserNotifications
import XCTest
@testable import HydroDrop

// Stage H: the Duo screen and its Settings row, hosted in a real window of the test host and
// driven the way a screen reader drives them: each control is found by its accessibility id and
// activated, the dialog that comes up is read (title, words, buttons) and its button pressed, and
// what reached the services is checked, for the right duo. `ImageRenderer` cannot draw a List, so
// nothing here relies on it.

// MARK: - Doubles (stage H)

/// The router's three Duo flags, apart from the app's own router: raising its `showingSettings`
/// here would make the test host present the real Settings sheet.
@MainActor
fileprivate final class HRouterFlags: ObservableObject, DuoScreenRouterFlags {
    @Published var showingDuoScreen = false
    @Published var showingSettings = false
    @Published var duoEntrySheetIsOnScreen = false
}

/// Every exit, with the duo it was for (the kit's `FakeExiting` records only the kind). It can also
/// set a notice the way the real service does when it refuses.
@MainActor
fileprivate final class HRecordingExiting: DuoExiting {
    weak var host: DuoStore?
    private(set) var calls: [String] = []
    var noticeOnClear: String?
    var deleteResult = true

    func leave(_ duo: DuoState) async { calls.append("leave:\(duo.id)") }
    func block(_ duo: DuoState) async { calls.append("block:\(duo.id)") }
    func clear(_ duo: DuoState) {
        calls.append("clear:\(duo.id)")
        if let noticeOnClear { host?.notice = noticeOnClear }
    }
    func deleteMyData() async -> Bool { calls.append("deleteMyData"); return deleteResult }
    func startFresh() { calls.append("startFresh") }
}

/// The sync seam, recording the nudge's duo too (the kit's `FakeSyncing` records only the line).
@MainActor
fileprivate final class HRecordingSyncing: DuoSyncing {
    private(set) var calls: [String] = []
    func activate(logReader: DuoLogReading) { calls.append("activate") }
    func logChanged(_ summary: DuoLogSummary) { calls.append("logChanged") }
    func refresh() async { calls.append("refresh") }
    func flush() async { calls.append("flush") }
    func backgroundRefresh() async -> Bool { calls.append("backgroundRefresh"); return false }
    func pushArrived(_ payload: DuoPushPayload) async { calls.append("pushArrived") }
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async { calls.append("sendNudge:\(preset.rawValue):\(duo.id)") }
}

/// A block that is queued and then refused, queued and then sent, or still waiting, as the real
/// exit service and queue leave the card in each case.
@MainActor
fileprivate final class HBlockOutcomeExiting: DuoExiting {
    enum Outcome { case went, endedWithoutProof, refusedWithNotice, stillQueued }
    weak var host: DuoStore?
    let outcome: Outcome
    init(_ outcome: Outcome) { self.outcome = outcome }

    func leave(_ duo: DuoState) async {}
    func block(_ duo: DuoState) async {
        host?.update(duo.id) { $0.pendingOp = .block; if $0.endedAt == nil { $0.endedAt = Date() } }
        await Task.yield()
        switch outcome {
        case .went:
            host?.update(duo.id) { $0.pendingOp = nil }
            host?.rememberConfirmedBlock(duo.id)
        case .endedWithoutProof: host?.update(duo.id) { $0.pendingOp = nil }
        case .refusedWithNotice: host?.update(duo.id) { $0.pendingOp = nil }; host?.notice = DuoUserMessage.generic
        case .stillQueued: break
        }
    }
    func clear(_ duo: DuoState) {}
    func deleteMyData() async -> Bool { true }
    func startFresh() {}
}

// MARK: - The harness (stage H; J's and M's tests use the same approach)

/// SwiftUI builds its accessibility tree only while something is listening for it. These tests turn
/// the simulator's accessibility automation on through libAccessibility (the switch XCUITest uses)
/// and put it back afterwards. Test code only; if a later iOS drops the switch, `enable()` says so
/// and the tests fail loudly rather than pass on an empty tree.
fileprivate enum HAutomation {
    private typealias Getter = @convention(c) () -> UInt8
    private typealias Setter = @convention(c) (UInt8) -> Void
    nonisolated(unsafe) private static var before: UInt8?
    private static var library: UnsafeMutableRawPointer? { dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) }

    @discardableResult
    static func enable() -> Bool {
        guard let library, let get = dlsym(library, "_AXSAutomationEnabled"), let set = dlsym(library, "_AXSSetAutomationEnabled") else { return false }
        if before == nil { before = unsafeBitCast(get, to: Getter.self)() }
        unsafeBitCast(set, to: Setter.self)(1)
        return unsafeBitCast(get, to: Getter.self)() != 0
    }

    static func restore() {
        guard let previous = before, let library, let set = dlsym(library, "_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(set, to: Setter.self)(previous)
        before = nil
    }
}

fileprivate func hIdentifier(of element: NSObject) -> String? {
    if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
    let selector = NSSelectorFromString("accessibilityIdentifier")
    guard element.responds(to: selector) else { return nil }
    return element.perform(selector)?.takeUnretainedValue() as? String
}

@MainActor
fileprivate func hWait(_ seconds: Double = 8, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return condition()
}

@MainActor
fileprivate func hSettle(_ seconds: Double = 0.6) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// A view in a real window of the test host: tall, so every row of the list is laid out at once.
@MainActor
fileprivate final class HHosted {
    let window: UIWindow

    init<Content: View>(_ view: Content, height: CGFloat? = 3000) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "the test host has a scene")
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height ?? scene.coordinateSpace.bounds.height)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    func trace(_ phase: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DUO_TRANSITION_TRACE"] == "1" else { return }
        print("H_TRACE \(ProcessInfo.processInfo.systemUptime) \(phase)\n\(presentationDescription())")
        #endif
    }

    func presented() -> [UIViewController] {
        var chain: [UIViewController] = []
        var top = window.rootViewController
        while let next = top?.presentedViewController { chain.append(next); top = next }
        return chain
    }

    func alert() -> UIAlertController? { presented().compactMap { $0 as? UIAlertController }.last }

    var alertIsReady: Bool {
        guard let alert = alert() else { return false }
        return alert.viewIfLoaded?.window === window && !alert.isBeingPresented && !alert.isBeingDismissed
    }

    func presentationDescription() -> String {
        func describe(_ controller: UIViewController, depth: Int) -> [String] {
            let transition = controller.transitionCoordinator.map {
                "\(type(of: $0)) percent=\($0.percentComplete) cancelled=\($0.isCancelled)"
            } ?? "none"
            var lines = ["\(String(repeating: " ", count: depth))\(type(of: controller)) attached=\(controller.viewIfLoaded?.window != nil) presenting=\(controller.isBeingPresented) dismissing=\(controller.isBeingDismissed) transition=\(transition) title=\(controller.title ?? "nil")"]
            for child in controller.children { lines += describe(child, depth: depth + 1) }
            if let shown = controller.presentedViewController { lines += describe(shown, depth: depth + 1) }
            return lines
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { scene in
            scene.windows.map { candidate in
                let head = "window owned=\(candidate === window) hidden=\(candidate.isHidden) key=\(candidate.isKeyWindow) alpha=\(candidate.alpha) scene=\(scene.activationState.rawValue)"
                return ([head] + (candidate.rootViewController.map { describe($0, depth: 1) } ?? []) ).joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    func walk(_ root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [root]
        var seen = Set<ObjectIdentifier>()
        while let next = queue.popLast() {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            found.append(next)
            if let view = next as? UIView { queue.append(contentsOf: view.subviews) }
            if let children = next.accessibilityElements as? [NSObject] {
                queue.append(contentsOf: children)
            } else {
                let count = next.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    queue.append(contentsOf: (0..<count).compactMap { next.accessibilityElement(at: $0) as? NSObject })
                }
            }
        }
        return found
    }

    /// The elements with `identifier`, top of the screen first.
    func elements(_ identifier: String) -> [NSObject] {
        walk(window).filter { hIdentifier(of: $0) == identifier }.sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY }
    }

    func has(_ identifier: String) -> Bool { !elements(identifier).isEmpty }

    func labels() -> [String] { walk(window).compactMap(\.accessibilityLabel) }

    /// A List can virtualize its final section even in the tall all-rows fixture. Check other
    /// rows first, then reveal the footer through its real scroll view rather than assume a
    /// fixed delay has caused UIKit to materialize every accessibility element.
    func revealFooter(_ identifier: String) async -> Bool {
        if has(identifier) { return true }
        guard let list = walk(window).compactMap({ $0 as? UICollectionView }).first else { return false }
        let before = "offset=\(list.contentOffset) content=\(list.contentSize) bounds=\(list.bounds.size)"
        let bottom = max(-list.adjustedContentInset.top,
                         list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: bottom), animated: false)
        list.layoutIfNeeded()
        let visible = await hWait { self.has(identifier) }
        print("H_FOOTER \(identifier) missing before: \(before); after offset=\(list.contentOffset) content=\(list.contentSize) visible=\(visible)")
        return visible
    }

    /// A screen reader's double tap on the `index`th element with `identifier`, from the top.
    @discardableResult
    func activate(_ identifier: String, index: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let found = elements(identifier)
        guard found.indices.contains(index) else {
            XCTFail("no element \(identifier) #\(index) (found \(found.count))", file: file, line: line)
            return false
        }
        return found[index].accessibilityActivate()
    }

    /// Presses the button titled `title` in the dialog or alert on top, as a screen reader would.
    @discardableResult
    func press(_ title: String) -> Bool {
        // A direct handler call bypasses UIKit's interaction gate. Never manufacture a tap
        // while the alert is still entering or leaving; the caller waits for actual readiness.
        guard alertIsReady, let alert = alert() else { return false }
        trace("before press \(title)")
        if let button = walk(alert.view).first(where: { $0.accessibilityLabel == title && $0.accessibilityTraits.contains(.button) }),
           button.accessibilityActivate() {
            trace("press used accessibility activation: \(title)")
            return true
        }
        // Fallback: the action's own handler, then the dismissal the button would make.
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        guard let action = alert.actions.first(where: { $0.title == title }), let block = action.value(forKey: "handler") else { return false }
        trace("press uses direct handler fallback: \(title)")
        unsafeBitCast(block as AnyObject, to: Handler.self)(action)
        alert.dismiss(animated: false)
        trace("after direct handler dismissal: \(title)")
        return true
    }

    @discardableResult
    func goBack() -> Bool {
        func find(_ controller: UIViewController?) -> UINavigationController? {
            guard let controller else { return nil }
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.compactMap { find($0) }.first
        }
        return find(window.rootViewController)?.popViewController(animated: true) != nil
    }

    /// Accessibility nodes exist during a navigation push, before UIKit permits a real tap.
    /// Read only this host's navigation hierarchy so the fixture does not manufacture one early.
    var navigationIsReady: Bool {
        func settled(_ controller: UIViewController) -> Bool {
            if let navigation = controller as? UINavigationController {
                return navigation.transitionCoordinator == nil
                    && navigation.viewControllers.allSatisfy {
                        !$0.isBeingPresented && !$0.isBeingDismissed
                            && !$0.isMovingToParent && !$0.isMovingFromParent
                            && $0.transitionCoordinator == nil
                    }
            }
            return controller.children.allSatisfy(settled)
        }
        guard let root = window.rootViewController, root.viewIfLoaded?.window === window else { return false }
        return settled(root)
    }

    /// The depth of the first navigation stack in the window.
    func navigationDepth() -> Int {
        func find(_ controller: UIViewController?) -> UINavigationController? {
            guard let controller else { return nil }
            if let navigation = controller as? UINavigationController { return navigation }
            for child in controller.children { if let found = find(child) { return found } }
            return nil
        }
        return find(window.rootViewController)?.viewControllers.count ?? 0
    }

    func sectionCount() -> Int? {
        func find(_ view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(window).map { $0.numberOfSections }
    }

    func textFields() -> [UITextField] {
        func find(_ view: UIView) -> [UITextField] { (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(find) }
        return find(window)
    }

    /// Covers the window's root with a full-screen controller: the screen disappears and appears
    /// again with its state kept, as it does under a pushed Diagnostics screen.
    func cover() -> UIViewController {
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(cover, animated: false)
        return cover
    }

    func close(testName: String) async {
        guard let root = window.rootViewController else { return }
        // A recorded service call does not mean its dialog has finished leaving. Keep the
        // host installed until UIKit has completed any presentation or navigation lifecycle.
        // A timed-out cleanup still removes our window, but records a failure first so the
        // run cannot be accepted as evidence of safe teardown.
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func settled(_ controller: UIViewController) -> Bool {
            !controller.isBeingPresented && !controller.isBeingDismissed
                && !controller.isMovingToParent && !controller.isMovingFromParent
                && controller.children.allSatisfy(settled)
                && (controller.presentedViewController.map(settled) ?? true)
        }
        let ready = await hWait { settled(root) }
        XCTAssertTrue(ready, "\(testName): teardown began during an unfinished transition\n\(presentationDescription())")
        guard ready else { return }
        if !presented().isEmpty {
            var completed = false
            root.dismiss(animated: false) { completed = true }
            let dismissed = await hWait { completed && self.presented().isEmpty && settled(root) }
            XCTAssertTrue(dismissed, "\(testName): teardown dismissal did not complete\n\(presentationDescription())")
        }
    }
}

/// What Settings puts round the Duo screen, built from the same row and modifiers Settings uses.
fileprivate struct HSettingsHost: View {
    @ObservedObject var router: HRouterFlags
    let store: DuoStore
    @State private var showingDuo = false

    var body: some View {
        NavigationStack {
            List {
                DuoSettingsRow(duoStore: store, showingDuo: $showingDuo)
                NavigationLink("Other settings") { Text("Other settings detail").accessibilityIdentifier("settings.other.detail") }
                    .accessibilityIdentifier("settings.other")
            }
            .modifier(DuoSettingsHooks(router: router, showingDuo: $showingDuo) {
                DuoScreen(duoStore: store, router: router, notificationStatus: { .authorized })
            })
            .modifier(DuoSettingsNoticeAlert(router: router, duoStore: store))
        }
    }
}

// MARK: - The tests

@MainActor
final class DuoViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let otherID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
    private var hosted: [HHosted] = []

    override func setUp() {
        super.setUp()
        XCTAssertTrue(HAutomation.enable(), "accessibility automation must be on, or the tree is empty")
    }

    override func tearDown() async throws {
        for window in hosted { await window.close(testName: self.name) }
        hosted = []
        HAutomation.restore()
        try await super.tearDown()
    }

    // MARK: Helpers

    private struct Rig {
        let kit: DuoTestKit
        let exiting: HRecordingExiting
        let sync: HRecordingSyncing
        var store: DuoStore { kit.store }
    }

    /// A kit whose exits and sync record the duo they were for, with these duos in its store.
    private func rig(credential: DuoCredential? = DuoFixtures.credential(), duos: [DuoState] = []) -> Rig {
        let kit = DuoTestKit(now: Date(), credential: credential)
        kit.identity.launch = credential == nil ? .none : .ready
        let exiting = HRecordingExiting()
        exiting.host = kit.store
        let sync = HRecordingSyncing()
        kit.dependencies.exiting = exiting
        kit.dependencies.sync = sync
        for duo in duos { kit.store.upsert(duo) }
        return Rig(kit: kit, exiting: exiting, sync: sync)
    }

    private func live(_ id: UUID = DuoFixtures.duoID, partner: String = "Sam") -> DuoState {
        DuoFixtures.duo(id: id, partner: partner, now: Date())
    }

    private func ended(_ id: UUID = DuoFixtures.duoID, partner: String = "Sam") -> DuoState {
        DuoFixtures.duo(id: id, ended: true, partner: partner, now: Date())
    }

    private func host<Content: View>(_ view: Content, height: CGFloat? = 3000) async throws -> HHosted {
        let made = try HHosted(view, height: height)
        hosted.append(made)
        await hSettle(0.8)
        return made
    }

    /// The screen on its own, in a navigation stack, as Today pushes it (or Settings, with
    /// `router.showingSettings` raised). Optional parameters: a default argument is built off the
    /// main actor.
    private func screen(_ store: DuoStore, router: HRouterFlags? = nil,
                        status: UNAuthorizationStatus = .authorized) async throws -> HHosted {
        let router = router ?? HRouterFlags()
        return try await host(NavigationStack { DuoScreen(duoStore: store, router: router, notificationStatus: { status }) })
    }

    private func context(_ store: DuoStore) -> DuoScreenModel.Context {
        DuoScreenModel.Context(duos: store.duos, availability: store.availability, nudgesPerDay: store.nudgesPerDay,
                               hasIdentity: store.hasIdentity, credentialIsAThrowaway: store.hCredentialIsAThrowaway,
                               isSubscribed: false, blocksSent: store.blockedDuoIDs, now: Date(), myToday: DayKey.key(for: Date()))
    }

    /// Activates `id`, waits for its dialog and checks its words and buttons; nothing is acted on.
    private func openDialog(_ window: HHosted, _ id: String, index: Int = 0, title: String, message: String? = nil,
                            buttons: [String], file: StaticString = #filePath, line: UInt = #line) async -> UIAlertController? {
        window.trace("before waiting for navigation: \(id)")
        let navigationReady = await hWait { window.navigationIsReady }
        XCTAssertTrue(navigationReady, "navigation must finish before the dialog row can be tapped", file: file, line: line)
        guard navigationReady else { return nil }
        window.trace("before openDialog \(id)")
        window.activate(id, index: index, file: file, line: line)
        let shown = await hWait { window.alertIsReady }
        XCTAssertTrue(shown, "\(id) brought up no dialog", file: file, line: line)
        guard window.alertIsReady, let alert = window.alert() else { return nil }
        window.trace("openDialog alert exists: \(id)")
        XCTAssertEqual(alert.title, title, file: file, line: line)
        if let message { XCTAssertEqual(alert.message, message, file: file, line: line) }
        XCTAssertEqual(alert.actions.map { $0.title ?? "" }, buttons, file: file, line: line)
        return alert
    }

    // MARK: Every row asks first, then acts once for its own duo

    func testLeaveAsksWithItsWordsThenLeavesTheDuoItWasFor() async throws {
        let rig = rig(duos: [live(), live(otherID, partner: "Alex")])
        let window = try await screen(rig.store)
        let alex = try XCTUnwrap(rig.store.duo(otherID))
        // The lower of the two Leave rows is Alex's (the store keeps the order they arrived in).
        _ = await openDialog(window, "duo.leave", index: 1, title: "Leave this duo?",
                             message: DuoScreenModel.leaveConfirmation(for: alex).message, buttons: ["Leave duo", "Cancel"])
        await hSettle(0.3)
        XCTAssertEqual(rig.exiting.calls, [], "the row only asked")
        XCTAssertTrue(window.press("Leave duo"))
        let left = await hWait { rig.exiting.calls == ["leave:\(otherID)"] }
        XCTAssertTrue(left, "\(rig.exiting.calls)")
    }

    func testCancelActsOnNothing() async throws {
        let rig = rig(duos: [live()])
        let window = try await screen(rig.store)
        _ = await openDialog(window, "duo.leave", title: "Leave this duo?", buttons: ["Leave duo", "Cancel"])
        XCTAssertTrue(window.press("Cancel"))
        let dismissed = await hWait { window.alert() == nil }
        XCTAssertTrue(dismissed, "Cancel finishes dismissing the confirmation")
        XCTAssertEqual(rig.exiting.calls, [])
    }

    func testBlockAsksWithItsWordsThenBlocksTheDuoItWasFor() async throws {
        let rig = rig(duos: [live(), ended(otherID, partner: "Alex")])
        let window = try await screen(rig.store)
        let alex = try XCTUnwrap(rig.store.duo(otherID))
        let dialog = DuoScreenModel.blockConfirmation(for: alex)
        _ = await openDialog(window, "duo.block", index: 1, title: dialog.title, message: dialog.message, buttons: ["Block", "Cancel"])
        XCTAssertEqual(rig.exiting.calls, [])
        XCTAssertTrue(window.press("Block"))
        let blocked = await hWait { rig.exiting.calls == ["block:\(otherID)"] }
        XCTAssertTrue(blocked, "\(rig.exiting.calls)")
    }

    func testClearAsksThenClearsTheEndedDuo() async throws {
        let rig = rig(duos: [live(), ended(otherID, partner: "Alex")])
        let window = try await screen(rig.store)
        _ = await openDialog(window, "duo.clear", title: "Clear this duo?", message: DuoCopy.clearMessage, buttons: ["Clear", "Cancel"])
        XCTAssertEqual(rig.exiting.calls, [])
        XCTAssertTrue(window.press("Clear"))
        let cleared = await hWait { rig.exiting.calls == ["clear:\(otherID)"] }
        XCTAssertTrue(cleared, "\(rig.exiting.calls)")
    }

    func testDeleteAsksWithTheApprovedWordsThenDeletesOnce() async throws {
        let rig = rig(duos: [live()])
        let window = try await screen(rig.store)
        _ = await openDialog(window, "duo.delete", title: "Delete my Duo data", message: DuoCopy.deleteMessage,
                             buttons: ["Delete my Duo data", "Cancel"])
        await hSettle(0.3)
        XCTAssertEqual(rig.exiting.calls, [], "the row only asked")
        XCTAssertTrue(window.press("Delete my Duo data"))
        let deleted = await hWait { rig.exiting.calls == ["deleteMyData"] }
        XCTAssertTrue(deleted, "\(rig.exiting.calls)")
    }

    /// Teardown must keep the presenter installed until UIKit finishes the dismissal that
    /// the user's action already started. A service recording its action is too early.
    func testClosingTheHostWaitsForAnAlreadyDismissingAlert() async throws {
        let window = try await host(Text("Teardown lifecycle"), height: nil)
        let root = try XCTUnwrap(window.window.rootViewController)
        let alert = UIAlertController(title: "Teardown lifecycle", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var presented = false
        root.present(alert, animated: true) { presented = true }
        let ready = await hWait { presented && window.alertIsReady }
        XCTAssertTrue(ready, "the regression requires a fully presented alert")
        guard ready else { return }

        var dismissed = false
        var presenterWasInstalledAtCompletion = false
        alert.dismiss(animated: true) {
            presenterWasInstalledAtCompletion = window.window.rootViewController === root
                && !window.window.isHidden
            dismissed = true
        }
        XCTAssertTrue(alert.isBeingDismissed, "the regression must enter cleanup during dismissal")
        await window.close(testName: self.name)
        XCTAssertTrue(dismissed, "cleanup returned before UIKit completed dismissal")
        XCTAssertTrue(presenterWasInstalledAtCompletion, "cleanup removed the presenter too early")
        XCTAssertNil(window.window.rootViewController)
        XCTAssertTrue(window.window.isHidden)
        let drained = await hWait { dismissed }
        XCTAssertTrue(drained, "the dismissal callback must drain even in the negative control")
    }

    func testADeleteWhoseWordsNoLongerHoldAsksAgainInsteadOfDeleting() async throws {
        let rig = rig(duos: [live()])
        let window = try await screen(rig.store)
        _ = await openDialog(window, "duo.delete", title: "Delete my Duo data", buttons: ["Delete my Duo data", "Cancel"])
        // While the dialog is up the stored credential becomes a Reconnect's throwaway (D68).
        rig.kit.dependencies.cache.throwawayDeviceID = DuoFixtures.credential().deviceID
        XCTAssertTrue(window.press("Delete my Duo data"))
        let askedAgain = await hWait { window.alertIsReady && window.alert()?.title == "Delete my Duo data from this phone" }
        XCTAssertTrue(askedAgain, "the dialog came back with the throwaway's words")
        XCTAssertEqual(window.alert()?.message, DuoScreenModel.deleteFromThisPhoneMessage)
        XCTAssertEqual(rig.exiting.calls, [], "nothing was deleted under the wrong words")
        XCTAssertTrue(window.press("Delete my Duo data from this phone"))
        let deleted = await hWait { rig.exiting.calls == ["deleteMyData"] }
        XCTAssertTrue(deleted, "\(rig.exiting.calls)")
    }

    func testANudgeAsksForALineThenSendsThatLineToTheDuoItWasFor() async throws {
        let rig = rig(duos: [live(), live(otherID, partner: "Alex")])
        let window = try await screen(rig.store)
        let buttons = DuoNudgePreset.allCases.map(\.text) + ["Cancel"]
        _ = await openDialog(window, "duo.nudge", index: 1, title: "Send a nudge", message: "Your partner will see it.", buttons: buttons)
        XCTAssertEqual(rig.sync.calls.filter { $0.hasPrefix("sendNudge") }, [], "the row only asked")
        XCTAssertTrue(window.press(DuoNudgePreset.cheers.text))
        let sent = await hWait { rig.sync.calls.contains("sendNudge:cheers:\(otherID)") }
        XCTAssertTrue(sent, "\(rig.sync.calls)")
        XCTAssertEqual(rig.sync.calls.filter { $0.hasPrefix("sendNudge") }.count, 1)
    }

    func testStartFreshAsksThenStartsFreshForTheStuckCard() async throws {
        var stuck = ended()
        stuck.pendingOp = .leave
        let rig = rig(credential: nil, duos: [stuck])
        let window = try await screen(rig.store)
        _ = await openDialog(window, "duo.startFresh", title: "Start fresh?", message: DuoScreenModel.startFreshMessage,
                             buttons: ["Start fresh", "Cancel"])
        XCTAssertEqual(rig.exiting.calls, [])
        XCTAssertTrue(window.press("Start fresh"))
        let fresh = await hWait { rig.exiting.calls == ["startFresh"] }
        XCTAssertTrue(fresh, "\(rig.exiting.calls)")
    }

    func testNothingCanBeTappedWhileTheStoreIsWorking() async throws {
        let rig = rig(duos: [live()])
        rig.store.isWorking = true
        let window = try await screen(rig.store)
        window.activate("duo.leave")
        await hSettle(1.0)
        XCTAssertNil(window.alert(), "a disabled screen brings up no dialog")
        XCTAssertTrue(window.labels().contains(DuoScreenModel.workingLabel), "the spinner says what it is")
    }

    // MARK: What each state draws

    func testEveryPreviewScenarioDrawsItsRows() async throws {
        let expected: [String: (has: [String], hasNot: [String])] = [
            "sample": (["duo.nudge", "duo.leave", "duo.block", "duo.clear", "duo.invite.show", "duo.nickname", "duo.report",
                        "duo.notifications", "duo.diagnostics", "duo.delete", "duo.haveCode", "duo.terms.link"], ["duo.startFresh"]),
            "empty": (["duo.start", "duo.haveCode", "duo.terms.link"], ["duo.delete", "duo.notifications", "duo.leave"]),
            "banned": (["duo.clear", "duo.delete", "duo.diagnostics"], ["duo.leave", "duo.block", "duo.invite.show", "duo.haveCode", "duo.start"]),
            "restore": (["duo.terms.link"], ["duo.delete", "duo.haveCode", "duo.start"]),
            // The test host is not subscribed: five live duos show the lock row.
            "full": (["duo.start.locked", "duo.haveCode"], ["duo.start", "duo.start.full"]),
            "disconnected": (["duo.leave", "duo.delete"], ["duo.haveCode", "duo.start"]),
        ]
        for name in DuoStore.previewScenarioNames {
            let store = DuoStore.makePreview(scenario: name, now: Date())
            let window = try await screen(store)
            XCTAssertTrue(window.has("duo.screen") || window.has("duo.terms.link"), "\(name) drew nothing")
            if let rule = expected[name] {
                for id in rule.has { XCTAssertTrue(window.has(id), "\(name) lacks \(id)") }
                for id in rule.hasNot { XCTAssertFalse(window.has(id), "\(name) has \(id)") }
            }
            let footerShown = await window.revealFooter("duo.terms.link")
            XCTAssertTrue(footerShown, "\(name) lacks its terms footer after scrolling")
            await window.close(testName: self.name)
        }
    }

    func testLeaveBlockAndDeleteAreNotOfferedWhereTheyCannotWork() async throws {
        // No credential: Leave and Block could never be sent.
        let restored = rig(credential: nil, duos: [live(), ended(otherID)])
        let noCredential = try await screen(restored.store)
        XCTAssertFalse(noCredential.has("duo.leave"))
        XCTAssertFalse(noCredential.has("duo.block"))
        XCTAssertTrue(noCredential.has("duo.clear"))
        await noCredential.close(testName: self.name)
        // The Reconnect throwaway: the same, and Delete says this phone.
        let throwaway = rig(duos: [live()])
        throwaway.kit.dependencies.cache.throwawayDeviceID = DuoFixtures.credential().deviceID
        let window = try await screen(throwaway.store)
        XCTAssertFalse(window.has("duo.leave"))
        XCTAssertFalse(window.has("duo.block"))
        XCTAssertTrue(window.labels().contains("Delete my Duo data from this phone"))
        await window.close(testName: self.name)
        // The restore question: no Delete.
        let restoring = rig(duos: [])
        restoring.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let question = try await screen(restoring.store)
        XCTAssertFalse(question.has("duo.delete"))
        XCTAssertTrue(question.has("duo.diagnostics"))
    }

    // MARK: Appearing

    func testAppearingAsksAboutTheIdentityOnceAndRefreshesNothingElse() async throws {
        let rig = rig(duos: [live()])
        let window = try await screen(rig.store)
        let opened = await hWait { rig.kit.identity.prepared == 1 && rig.sync.calls == ["refresh"] }
        XCTAssertTrue(opened, "prepare \(rig.kit.identity.prepared), sync \(rig.sync.calls)")
        XCTAssertEqual(rig.exiting.calls, [])
        XCTAssertEqual(rig.kit.transport.calls, [])
        // Covered and uncovered (as under a pushed Diagnostics screen): not asked again.
        let cover = window.cover()
        await hSettle(0.6)
        cover.dismiss(animated: false)
        await hSettle(1.0)
        XCTAssertEqual(rig.kit.identity.prepared, 1)
        XCTAssertEqual(rig.sync.calls, ["refresh"])
    }

    // MARK: The notice alert (D87)

    func testANoticeRaisedOnThePushedDuoScreenIsShownThere() async throws {
        let rig = rig(duos: [ended()])
        rig.exiting.noticeOnClear = "That did not work. Please try again."
        let router = HRouterFlags()
        router.showingSettings = true
        // Scene-sized snapshots avoid the all-rows fixture's 1170×9000 image allocations.
        let window = try await host(HSettingsHost(router: router, store: rig.store), height: nil)
        window.activate("settings.duo")
        let pushed = await hWait { window.has("duo.clear") }
        XCTAssertTrue(pushed)
        _ = await openDialog(window, "duo.clear", title: "Clear this duo?", buttons: ["Clear", "Cancel"])
        XCTAssertTrue(window.press("Clear"))
        let shown = await hWait { window.alertIsReady && window.alert()?.title == "Duo Streaks" }
        XCTAssertTrue(shown, "notice=\(rig.store.notice ?? "nil") working=\(rig.store.isWorking) settings=\(router.showingSettings) entry=\(router.duoEntrySheetIsOnScreen) navigationDepth=\(window.navigationDepth())\n\(window.presentationDescription())")
        XCTAssertEqual(window.alert()?.message, "That did not work. Please try again.")
        XCTAssertEqual(window.navigationDepth(), 2, "still on the Duo screen")
        XCTAssertTrue(window.press("OK"))
        let gone = await hWait { rig.store.notice == nil }
        XCTAssertTrue(gone)
    }

    func testTheDuoScreenSaysNothingWhenItWasPushedFromToday() async throws {
        let rig = rig(duos: [live()])
        let router = HRouterFlags()
        router.showingSettings = false
        let window = try await screen(rig.store, router: router)
        rig.store.notice = "That did not work. Please try again."
        await hSettle(1.5)
        XCTAssertNil(window.alert(), "the root's alert says it there")
    }

    func testANoticeWaitsUnderTheAgeRecheckSheet() async throws {
        let rig = rig(credential: nil, duos: [])
        rig.store.cache.defaults.set("allowed", forKey: DuoCache.ageStatusKey)
        rig.store.cache.defaults.removeObject(forKey: DuoCache.agePolicyKey)
        rig.store.recheckAge()
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await screen(rig.store, router: router)
        window.activate("duo.agegate.recheck")
        let up = await hWait { !window.presented().isEmpty }
        XCTAssertTrue(up)
        rig.store.notice = "That did not work. Please try again."
        await hSettle(1.5)
        XCTAssertNil(window.alert())
        XCTAssertEqual(window.presented().count, 1)
        window.presented().first?.dismiss(animated: true)
        let said = await hWait { window.alertIsReady && window.alert()?.title == "Duo Streaks" }
        XCTAssertTrue(said)
        XCTAssertTrue(rig.store.needsAgeRecheck, "dismissal is not an age answer")
    }

    /// Finding 5: a phone holding an identity without the rules (a reinstall clears them) is asked
    /// for them on the Duo screen, through the consent gate, and once they are accepted the sheet
    /// closes and sharing resumes: the identity is asked about again. Answering the age alone used
    /// to leave the identity suspended for good.
    func testTheRecheckAsksForTheRulesAndResumesOnceAccepted() async throws {
        let rig = rig(duos: [])
        rig.store.recordBirthYear(1990, month: 1)
        XCTAssertTrue(rig.store.needsTermsAgain)
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await screen(rig.store, router: router)
        let opened = await hWait { rig.kit.identity.prepared >= 1 }
        XCTAssertTrue(opened)
        let before = rig.kit.identity.prepared
        XCTAssertTrue(window.labels().contains(DuoScreenModel.recheckTermsRow))
        XCTAssertTrue(window.activate("duo.agegate.recheck"))
        let rules = await hWait { window.has("duo.terms.accept") }
        XCTAssertTrue(rules, "the rules, not the age screen alone")
        XCTAssertTrue(window.has("duo.terms.cancel"), "with a way out")
        XCTAssertTrue(window.activate("duo.terms.accept"))
        let closed = await hWait { window.presented().isEmpty }
        XCTAssertTrue(closed, "the sheet closes once both are answered")
        let resumed = await hWait { rig.kit.identity.prepared > before }
        XCTAssertTrue(resumed, "sharing resumes")
        // What the row is drawn from. This window's walk also finds the hidden cells a List keeps
        // for reuse, so the row's absence is not read from the tree.
        XCTAssertFalse(rig.store.needsTermsAgain, "the row goes with the question")
        XCTAssertFalse(rig.store.needsAgeRecheck)
    }

    func testANoticeWaitsUnderTheCodeEntrySheetAndLeavesItAlone() async throws {
        let rig = rig(credential: nil, duos: [])
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await screen(rig.store, router: router)
        window.activate("duo.haveCode")
        let up = await hWait { !window.presented().isEmpty }
        XCTAssertTrue(up)
        rig.store.notice = "That did not work. Please try again."
        await hSettle(1.5)
        XCTAssertNil(window.alert(), "nothing is presented over the sheet")
        XCTAssertEqual(window.presented().count, 1, "the sheet stays")
        XCTAssertTrue(router.duoEntrySheetIsOnScreen)
        // Exercise the real dismissal transition: the notice must wait until the sheet is gone.
        window.presented().first?.dismiss(animated: true)
        let said = await hWait { window.alertIsReady && window.alert()?.title == "Duo Streaks" }
        XCTAssertTrue(said)
    }

    func testTheSettingsIndexStillSaysANoticeAndOnlyWhileSettingsIsUp() async throws {
        let rig = rig(duos: [live()])
        let router = HRouterFlags()
        router.showingSettings = true
        // Scene-sized snapshots avoid the all-rows fixture's 1170×9000 image allocations.
        let window = try await host(HSettingsHost(router: router, store: rig.store), height: nil)
        window.activate("settings.other")
        let detail = await hWait { window.has("settings.other.detail") }
        XCTAssertTrue(detail)
        rig.store.notice = "No connection right now. Try again in a bit."
        await hSettle(1)
        XCTAssertNil(window.alert(), "the covered index cannot own an alert")
        XCTAssertEqual(rig.store.notice, "No connection right now. Try again in a bit.")
        XCTAssertTrue(window.goBack())
        let index = await hWait { window.navigationDepth() == 1 && window.has("settings.duo") }
        XCTAssertTrue(index)
        let shown = await hWait { window.alertIsReady && window.alert()?.title == "Duo Streaks" }
        XCTAssertTrue(shown)
        XCTAssertTrue(window.press("OK"))
        _ = await hWait { window.alert() == nil }
        router.showingSettings = false
        rig.store.notice = "No connection right now. Try again in a bit."
        await hSettle(1.5)
        XCTAssertNil(window.alert(), "Settings on its way out: the root takes over")
    }

    // MARK: The Settings row and a tapped notification

    func testTheSettingsRowPushesTheDuoScreenAndSaysHowManyDuosAreLive() async throws {
        let rig = rig(duos: [live(), DuoFixtures.duo(id: otherID, joined: false, partner: "", now: Date()),
                             ended(UUID(uuidString: "6d2a0000-0000-4000-8000-000000000003")!)])
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await host(HSettingsHost(router: router, store: rig.store))
        let row = try XCTUnwrap(window.elements("settings.duo").first)
        XCTAssertTrue((row.accessibilityLabel ?? "").contains("2 duos") || (row.accessibilityValue ?? "").contains("2 duos"),
                      "live and pending count, ended does not: \(row.accessibilityLabel ?? "") \(row.accessibilityValue ?? "")")
        window.activate("settings.duo")
        let pushed = await hWait { window.navigationDepth() == 2 && window.has("duo.screen") }
        XCTAssertTrue(pushed)
        // A notification tapped meanwhile pushes no second Duo screen.
        router.showingDuoScreen = true
        let consumed = await hWait { !router.showingDuoScreen }
        XCTAssertTrue(consumed, "the covered index consumes the notification request")
        XCTAssertEqual(window.navigationDepth(), 2)
        XCTAssertFalse(router.showingDuoScreen, "taken and lowered")
    }

    func testTheSettingsRowSaysOffWithNoDuo() async throws {
        let rig = rig(duos: [ended()])
        let window = try await host(HSettingsHost(router: HRouterFlags(), store: rig.store))
        let row = try XCTUnwrap(window.elements("settings.duo").first)
        XCTAssertTrue(((row.accessibilityLabel ?? "") + (row.accessibilityValue ?? "")).contains("Off"))
    }

    func testANotificationRaisedBeforeSettingsOpenedIsTakenOnAppear() async throws {
        let rig = rig(duos: [live()])
        let router = HRouterFlags()
        router.showingSettings = true
        router.showingDuoScreen = true
        let window = try await host(HSettingsHost(router: router, store: rig.store))
        let pushed = await hWait { window.navigationDepth() == 2 }
        XCTAssertTrue(pushed)
        XCTAssertFalse(router.showingDuoScreen)
    }

    func testANotificationRaisedWhileSettingsIsUpIsTakenAtOnce() async throws {
        let rig = rig(duos: [live()])
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await host(HSettingsHost(router: router, store: rig.store))
        XCTAssertEqual(window.navigationDepth(), 1)
        router.showingDuoScreen = true
        let pushed = await hWait { window.navigationDepth() == 2 }
        XCTAssertTrue(pushed)
        XCTAssertFalse(router.showingDuoScreen)
    }

    func testANotificationTappedWhileSettingsSlidesAwayIsLeftForTheRoot() async throws {
        let rig = rig(duos: [live()])
        let router = HRouterFlags()
        router.showingSettings = false
        let window = try await host(HSettingsHost(router: router, store: rig.store))
        router.showingDuoScreen = true
        await hSettle(1.0)
        XCTAssertEqual(window.navigationDepth(), 1, "nothing pushed into a leaving sheet")
        XCTAssertTrue(router.showingDuoScreen, "the flag stays up for the root")
    }

    // MARK: The code-entry sheet

    func testACodePublishedFromTheEntrySheetClosesSettingsOnceTheSheetHasGone() async throws {
        let rig = rig(credential: nil, duos: [])
        rig.kit.dependencies.joining = DuoJoiningService(dependencies: rig.kit.dependencies)
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await screen(rig.store, router: router)
        window.activate("duo.haveCode")
        let up = await hWait { router.duoEntrySheetIsOnScreen }
        XCTAssertTrue(up, "the root is told the entry sheet is up")
        rig.store.receive(DuoParsedInvite(code: "H7K39QWX"), now: Date())
        XCTAssertTrue(router.showingSettings, "not in the turn the sheet is still up")
        window.presented().first?.dismiss(animated: false)
        let closed = await hWait { !router.showingSettings }
        XCTAssertTrue(closed)
        XCTAssertFalse(router.duoEntrySheetIsOnScreen)
    }

    func testAnEntrySheetCancelledOverAnOlderInviteLeavesSettingsOpen() async throws {
        let rig = rig(credential: nil, duos: [])
        rig.kit.dependencies.joining = DuoJoiningService(dependencies: rig.kit.dependencies)
        rig.store.receive(DuoParsedInvite(code: "H7K39QWX"), now: Date().addingTimeInterval(-600))
        XCTAssertNotNil(rig.store.pendingInvite)
        let router = HRouterFlags()
        router.showingSettings = true
        let window = try await screen(rig.store, router: router)
        window.activate("duo.haveCode")
        let up = await hWait { router.duoEntrySheetIsOnScreen }
        XCTAssertTrue(up)
        window.presented().first?.dismiss(animated: false)
        let down = await hWait { !router.duoEntrySheetIsOnScreen }
        XCTAssertTrue(down)
        await hSettle(0.5)
        XCTAssertTrue(router.showingSettings, "an invite older than the sheet is not the sheet's")
    }

    func testTheLockedRowOpensThePaywallNotTheSetupSheet() async throws {
        let rig = rig(duos: [live()])
        let window = try await screen(rig.store)
        XCTAssertFalse(window.has("duo.start"))
        window.activate("duo.start.locked")
        let paywall = await hWait { window.labels().contains("Restore Purchases") }
        XCTAssertTrue(paywall, "the paywall came up")
    }

    // MARK: Notifications, nickname

    func testTheToggleIsBoundToTheStore() async throws {
        let rig = rig(duos: [live()])
        rig.store.notificationsEnabled = true
        let window = try await screen(rig.store)
        window.activate("duo.notifications")
        let off = await hWait { !rig.store.notificationsEnabled }
        XCTAssertTrue(off, "the switch is the store's")
        window.activate("duo.notifications")
        let on = await hWait { rig.store.notificationsEnabled }
        XCTAssertTrue(on)
    }

    func testTheScreenSaysWhenIOSHasNotificationsOffOnlyWhileTheSwitchIsOn() async throws {
        // Each state hosted fresh: SwiftUI's accessibility tree lags behind a row's removal.
        for (enabled, status, warns) in [(true, UNAuthorizationStatus.denied, true), (false, .denied, false), (true, .authorized, false),
                                          (true, .notDetermined, false)] {
            let rig = rig(duos: [live()])
            rig.store.notificationsEnabled = enabled
            let window = try await screen(rig.store, status: status)
            let warned = await hWait(2) { window.has("duo.notifications.denied") }
            XCTAssertEqual(warned, warns, "on \(enabled), \(status.rawValue)")
            if warns { XCTAssertTrue(window.labels().contains("Notifications are disabled in iOS Settings.")) }
            await window.close(testName: self.name)
        }
    }

    func testTheNicknameIsSavedWhenTheScreenGoesAwayAndLimitedAsItIsTyped() async throws {
        let rig = rig(duos: [live()])
        let window = try await screen(rig.store)
        let field = try XCTUnwrap(window.textFields().first)
        XCTAssertEqual(window.elements("duo.nickname").first?.accessibilityLabel, DuoCopy.showAs, "the field says what it is")
        field.becomeFirstResponder()
        await hSettle(0.3)
        field.insertText(String(repeating: "x", count: 40))
        await hSettle(0.5)
        XCTAssertEqual(field.text?.count, DuoState.maximumNameLength, "cut as it is typed")
        for _ in 0..<40 { field.deleteBackward() }
        field.insertText("Bestie")
        await hSettle(0.3)
        XCTAssertNil(rig.store.duo(DuoFixtures.duoID)?.partnerNickname, "not saved while typing")
        await window.close(testName: self.name)
        let saved = await hWait { rig.store.duo(DuoFixtures.duoID)?.partnerNickname == "Bestie" }
        XCTAssertTrue(saved, "saved when the screen went away with the field still focused")
    }

    // MARK: A block that went (D87)

    func testABlockCountsAsDoneOnlyWhenTheStoreHasServerProof() async throws {
        for (outcome, remembered) in [(HBlockOutcomeExiting.Outcome.went, true), (.endedWithoutProof, false), (.refusedWithNotice, false), (.stillQueued, false)] {
            let kit = DuoTestKit(now: Date(), credential: DuoFixtures.credential())
            let exiting = HBlockOutcomeExiting(outcome)
            exiting.host = kit.store
            kit.dependencies.exiting = exiting
            kit.store.upsert(ended())
            await DuoScreenActions(duoStore: kit.store).perform(.block(DuoFixtures.duoID))
            XCTAssertEqual(kit.store.blockedDuoIDs.contains(DuoFixtures.duoID), remembered, "\(outcome)")
            let card = try XCTUnwrap(kit.store.duo(DuoFixtures.duoID))
            let rows = DuoScreenModel.rows(for: card, verdict: .nobodyToNudge, in: context(kit.store))
            XCTAssertEqual(rows.block == nil, outcome == .went || outcome == .stillQueued, "\(outcome): hidden when it went or while it waits")
        }
    }

    func testABlockSentAndAnsweredInsideTheCallIsRememberedThroughTheRealService() async throws {
        let kit = DuoTestKit(now: Date(), credential: DuoFixtures.credential())
        kit.identity.launch = .ready
        kit.dependencies.sleep = { _ in throw CancellationError() }
        kit.dependencies.ops = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.transport.onBlock = { _, _ in }
        kit.store.upsert(ended())
        await DuoScreenActions(duoStore: kit.store).perform(.block(DuoFixtures.duoID))
        XCTAssertNil(kit.store.duo(DuoFixtures.duoID)?.pendingOp, "it went")
        XCTAssertNil(kit.store.notice)
        XCTAssertEqual(kit.store.blockedDuoIDs, [DuoFixtures.duoID], "only the service records a validated successful block")
    }

    // MARK: The router hand-offs

    func testATappedNotificationsFlagIsTakenOnceAndOnlyWhileSettingsIsUp() {
        let router = HRouterFlags()
        router.showingSettings = true
        XCTAssertFalse(DuoScreenRouting.takeDuoScreenRequest(from: router), "nothing asked")
        router.showingDuoScreen = true
        XCTAssertTrue(DuoScreenRouting.takeDuoScreenRequest(from: router))
        XCTAssertFalse(router.showingDuoScreen, "lowered as it is taken")
        XCTAssertFalse(DuoScreenRouting.takeDuoScreenRequest(from: router), "an old request never pushes the screen again")
        router.showingDuoScreen = true
        router.showingSettings = false
        XCTAssertFalse(DuoScreenRouting.takeDuoScreenRequest(from: router), "Settings is on its way out")
        XCTAssertTrue(router.showingDuoScreen, "left up for the root")
    }

    func testTheCodeEntrySheetClosesSettingsFromItsDismissalOnlyForACodeItPublished() {
        let router = HRouterFlags()
        router.showingSettings = true
        DuoScreenRouting.entrySheetDidAppear(router: router)
        XCTAssertTrue(router.duoEntrySheetIsOnScreen)
        DuoScreenRouting.entrySheetDidDismiss(router: router, pendingInvite: nil, before: nil)
        XCTAssertFalse(router.duoEntrySheetIsOnScreen)
        XCTAssertTrue(router.showingSettings)
        let old = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: now.addingTimeInterval(-60))
        DuoScreenRouting.entrySheetDidDismiss(router: router, pendingInvite: old, before: old)
        XCTAssertTrue(router.showingSettings)
        DuoScreenRouting.entrySheetDidDismiss(router: router, pendingInvite: DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: now), before: old)
        XCTAssertFalse(router.showingSettings)
    }

    func testTheThrowawayIsReadFromTheStoredCredential() {
        let kit = DuoTestKit(now: now, credential: DuoFixtures.credential())
        XCTAssertFalse(kit.store.hCredentialIsAThrowaway)
        kit.dependencies.cache.throwawayDeviceID = DuoFixtures.credential().deviceID
        XCTAssertTrue(kit.store.hCredentialIsAThrowaway)
        kit.dependencies.cache.throwawayDeviceID = "6d2a0000-0000-4000-8000-0000000000cc"
        XCTAssertFalse(kit.store.hCredentialIsAThrowaway, "a marker for another device is not this credential")
        XCTAssertFalse(DuoStore.makePreview(scenario: "sample", now: now).hCredentialIsAThrowaway, "the preview store has no services")
    }
}
@MainActor
private final class HTransitionCoordinator: NSObject, UIViewControllerTransitionCoordinator {
    var requests = 0
    var completeFirst = false
    private var pending: ((UIViewControllerTransitionCoordinatorContext) -> Void)?
    var isAnimated: Bool { true }
    var presentationStyle: UIModalPresentationStyle { .fullScreen }
    var initiallyInteractive: Bool { false }
    var isInterruptible: Bool { false }
    var isInteractive: Bool { false }
    var isCancelled: Bool { false }
    var transitionDuration: TimeInterval { 0.25 }
    var percentComplete: CGFloat { 0 }
    var completionVelocity: CGFloat { 1 }
    var completionCurve: UIView.AnimationCurve { .easeInOut }
    var containerView = UIView()
    var targetTransform: CGAffineTransform { .identity }
    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }
    func animate(alongsideTransition animation: ((UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool {
        requests += 1
        pending = completion
        if completeFirst && requests == 1 { finish() }
        return true
    }
    func animateAlongsideTransition(in view: UIView?, animation: ((UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool {
        animate(alongsideTransition: animation, completion: completion)
    }
    func notifyWhenInteractionEnds(_ handler: @escaping (UIViewControllerTransitionCoordinatorContext) -> Void) {}
    func notifyWhenInteractionChanges(_ handler: @escaping (UIViewControllerTransitionCoordinatorContext) -> Void) {}
    func finish() {
        let callback = pending
        pending = nil
        callback?(self)
    }
}

@MainActor
private final class HTransitionController: UIViewController {
    let testCoordinator = HTransitionCoordinator()
    override var transitionCoordinator: UIViewControllerTransitionCoordinator? { testCoordinator }
}

@MainActor
final class DuoPresentationTransitionTests: XCTestCase {
    private func check(hidden: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = HTransitionController()
        controller.testCoordinator.completeFirst = !hidden
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        controller.view.layoutIfNeeded()
        window.isHidden = hidden
        let finished = expectation(description: "only visible unfinished transitions delay the notice")
        let waiter = Task { @MainActor in
            await DuoPresentationTransitions.waitUntilSettled()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(controller.testCoordinator.requests, hidden ? 0 : 1)
        // Even the before-fix failure releases its deliberately suspended callback.
        waiter.cancel()
        controller.testCoordinator.finish()
        await waiter.value
        if !hidden {
            // A new notice starts a new SwiftUI task while UIKit can still expose the old
            // coordinator. The already observed completion must remain sufficient then.
            let nextFinished = expectation(description: "a second wait remembers the same coordinator completed")
            let nextWaiter = Task { @MainActor in
                await DuoPresentationTransitions.waitUntilSettled()
                nextFinished.fulfill()
            }
            await fulfillment(of: [nextFinished], timeout: 5)
            XCTAssertEqual(controller.testCoordinator.requests, 1, "do not register again after an observed completion")
            // Release the before-fix suspended callback as well, so a failing test leaves no task.
            nextWaiter.cancel()
            controller.testCoordinator.finish()
            await nextWaiter.value
        }
        window.isHidden = true
        window.rootViewController = nil
    }

    func testCancellingARegisteredWaitDoesNotNeedUIKitCompletion() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = HTransitionController()
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        controller.view.layoutIfNeeded()
        let finished = expectation(description: "cancellation releases the waiter without UIKit completing")
        let waiter = Task { @MainActor in
            await DuoPresentationTransitions.waitUntilSettled()
            finished.fulfill()
        }
        let registered = await hWait { controller.testCoordinator.requests == 1 }
        XCTAssertTrue(registered)
        waiter.cancel()
        // Do not finish the coordinator until this assertion has established cancellation works.
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(controller.testCoordinator.requests, 1)
        // Release the old implementation after its timeout and exercise harmless late completion.
        controller.testCoordinator.finish()
        await waiter.value
        window.isHidden = true
        window.rootViewController = nil
    }

    func testHiddenWindowDoesNotDelayANotice() async throws { try await check(hidden: true) }
    func testCompletedCoordinatorIsNotAwaitedAgainWhileUIKitStillExposesIt() async throws { try await check(hidden: false) }
}

#endif
