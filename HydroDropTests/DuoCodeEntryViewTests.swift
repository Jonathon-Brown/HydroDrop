#if DUO_V2
// A session is started on another queue in one test; AVFoundation's types predate Sendable.
@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import HydroDrop

// Stage L: the code-entry sheet ("Have an invite code?") and its QR scanner. A good code reaches
// `DuoStore.receive` once, the sheet closes, and nothing else is called; a bad one never does; a
// refused person and a phone that may not join keep nothing and are told why; the camera is asked
// for only by the Scan tap; the capture session reads QR codes and nothing else and is let go
// whenever the scanner goes. The camera itself cannot run on a simulator, so the scanner's rules
// run against a fake session, and the real session's configuration is checked for what it adds.
//
// The sheet is also put on screen and driven the way a person drives it: its controls are found
// by their accessibility identifiers and tapped through accessibility, so a test sees what is
// drawn, what is enabled and whether the sheet closed. The first version's tests drew the sheet
// off screen only, which no change to the view could fail, and its reviewers' mutants of the
// view's wiring survived.

// MARK: - Helpers (stage L, shared with DuoReconnectSheetTests)

/// A camera whose presence and answer the test sets, counting what the sheet asked of it.
final class LFakeCamera: DuoCameraAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var requests = 0
    let present: Bool
    let status: Int
    let grants: Bool
    /// Holds the first question open until the test lets it go. A later one is answered at once,
    /// so a bug that asks twice fails its assertion instead of hanging the test.
    var holdsTheQuestion = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(present: Bool = true, status: Int = 0, grants: Bool = true) {
        self.present = present
        self.status = status
        self.grants = grants
    }

    var statusReads: Int { lock.withLock { reads } }
    var requestCount: Int { lock.withLock { requests } }
    var isAsking: Bool { lock.withLock { waiting != nil } }

    var hasCamera: Bool { present }
    var rawStatus: Int { lock.withLock { reads += 1 }; return status }

    func requestAccess() async -> Bool {
        let first = lock.withLock { () -> Bool in
            requests += 1
            return requests == 1
        }
        if holdsTheQuestion, first {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { waiting = continuation }
            }
        }
        return grants
    }

    /// Answers the question that is up, once.
    func answer() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// A capture session that reads what the test hands it. The closures the scanner gave it are kept
/// even after `stop()`, so a test can hand it a frame that was already on its way when the camera
/// stopped, as a real delegate callback can be.
@MainActor
final class LFakeCapture: DuoQRCapturing {
    private(set) var starts = 0
    private(set) var stops = 0
    private var handedOn: (@MainActor (String) -> Void)?
    private var endedHandler: (@MainActor (DuoQRCaptureEnd) -> Void)?
    private var live = false
    let layer = CALayer()

    var previewLayer: CALayer? { live ? layer : nil }

    func start(delivering payload: @escaping @MainActor (String) -> Void, ended: @escaping @MainActor (DuoQRCaptureEnd) -> Void) {
        starts += 1
        handedOn = payload
        endedHandler = ended
        live = true
    }

    func stop() {
        stops += 1
        live = false
    }

    /// A frame with this payload in it, delivered whether or not the camera has stopped.
    func frame(_ payload: String) { handedOn?(payload) }

    /// The camera stops on its own, as a real one does when it cannot start or is interrupted.
    func end(_ reason: DuoQRCaptureEnd) {
        live = false
        endedHandler?(reason)
    }
}

/// Presents a sheet the way the Duo screen does, so a test can see it close and close it the way
/// a person does.
@MainActor
final class LPresenter: ObservableObject {
    @Published var showing = true
    @Published var dismissals = 0
}

struct LSheetHost<Sheet: View>: View {
    @ObservedObject var presenter: LPresenter
    @ViewBuilder var sheet: () -> Sheet

    var body: some View {
        Color.clear.sheet(isPresented: $presenter.showing, onDismiss: { presenter.dismissals += 1 }) { sheet() }
    }
}

@MainActor
func lSpin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Turns the run loop until `condition` holds or `timeout` passes; answers whether it held.
@MainActor
@discardableResult
func lWait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        lSpin(0.05)
    }
    return condition()
}

/// SwiftUI builds its accessibility elements only while an assistive technology asks for them;
/// UI tests switch that on for the app under test, and a unit test does it here, through the same
/// private switch XCUITest and KIF use. Off again when the test ends.
@MainActor
func lAccessibility(_ on: Bool) {
    guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
          let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
    typealias Setter = @convention(c) (Int32) -> Void
    unsafeBitCast(symbol, to: Setter.self)(on ? 1 : 0)
}

/// A view on the test host's screen, in a window of its own, whose controls a test can find by
/// their accessibility identifiers and tap.
@MainActor
final class LScreen {
    let window: UIWindow
    /// The integrated reconnect explainer is longer than the stage-local stub. Its Form creates
    /// offscreen rows lazily, so those tests must scroll to find controls as a person would.
    var scrollsToFindElements = false

    init<V: View>(_ view: V, test: XCTestCase) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        lAccessibility(true)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        lSpin(0.3)
        let window = self.window
        test.addTeardownBlock { @MainActor in
            window.rootViewController?.dismiss(animated: false)
            lSpin(0.2)
            window.isHidden = true
            window.rootViewController = nil
            lAccessibility(false)
            lSpin(0.1)
        }
    }

    /// The presented sheet, once it is up and not on its way out.
    var sheet: UIViewController? {
        guard let presented = window.rootViewController?.presentedViewController, !presented.isBeingDismissed else { return nil }
        return presented
    }

    /// Every accessibility element on screen, with its identifier.
    func elements() -> [(id: String, element: NSObject)] {
        var found: [(String, NSObject)] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            // A list keeps the cells of rows it removed, hidden, for reuse; what they hold is not on screen.
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let id = (object.responds(to: selector) ? object.value(forKey: "accessibilityIdentifier") as? String : nil) ?? ""
            if !id.isEmpty || object.isAccessibilityElement { found.append((id, object)) }
            if let children = object.accessibilityElements as? [NSObject], !children.isEmpty {
                children.forEach { walk($0, depth + 1) }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }.forEach { walk($0, depth + 1) }
                }
            }
            (object as? UIView)?.subviews.forEach { walk($0, depth + 1) }
        }
        walk(window, 0)
        return found
    }

    func find(_ id: String) -> NSObject? {
        if let element = elements().first(where: { $0.id == id })?.element { return element }
        guard scrollsToFindElements else { return nil }
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            guard !view.isHidden, view.alpha >= 0.01 else { return [] }
            return ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        for scroll in scrollViews(window) where scroll.contentSize.height > scroll.bounds.height {
            let original = scroll.contentOffset
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let step = max(100, scroll.bounds.height * 0.7)
            // Bound the search even if a regression creates an unexpectedly large collection.
            for index in 0..<30 {
                let offset = min(bottom, top + CGFloat(index) * step)
                scroll.setContentOffset(CGPoint(x: original.x, y: offset), animated: false)
                scroll.layoutIfNeeded()
                lSpin(0.05)
                if let element = elements().first(where: { $0.id == id })?.element { return element }
                if offset == bottom { break }
            }
            scroll.setContentOffset(original, animated: false)
            scroll.layoutIfNeeded()
            lSpin(0.05)
        }
        return nil
    }
    func has(_ id: String) -> Bool { find(id) != nil }

    /// Whether the control with this identifier is drawn and enabled.
    func isEnabled(_ id: String) -> Bool? {
        guard let element = find(id) else { return nil }
        if let control = element as? UIControl { return control.isEnabled }
        return !element.accessibilityTraits.contains(.notEnabled)
    }

    func label(_ id: String) -> String? { find(id)?.accessibilityLabel }

    /// Taps the control with this identifier the way VoiceOver does; a toolbar button, which lives in
    /// UIKit's navigation bar, is sent its bar item's action as a tap there would. A disabled control
    /// is not tapped (`activate` says so), which is what a test of a disabled button relies on.
    @discardableResult
    func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let done = tryTap(id)
        XCTAssertTrue(done, "\(id) could not be tapped", file: file, line: line)
        return done
    }

    func tryTap(_ id: String) -> Bool {
        var done = false
        if let item = barItem(id) {
            if item.isEnabled, let action = item.action { done = UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) }
        } else if let control = find(id) as? UIControl {
            if control.isEnabled { control.sendActions(for: .touchUpInside); done = true }
        } else if let element = find(id) {
            done = element.accessibilityActivate()
        }
        lSpin(0.2)
        return done
    }

    private func barItem(_ id: String) -> UIBarButtonItem? {
        func bars(_ view: UIView) -> [UINavigationBar] {
            if view.isHidden { return [] }
            return ((view as? UINavigationBar).map { [$0] } ?? []) + view.subviews.flatMap(bars)
        }
        for bar in bars(window) {
            let items = (bar.topItem?.leftBarButtonItems ?? []) + (bar.topItem?.rightBarButtonItems ?? [])
                + (bar.topItem?.leadingItemGroups.flatMap(\.barButtonItems) ?? []) + (bar.topItem?.trailingItemGroups.flatMap(\.barButtonItems) ?? [])
            if let item = items.first(where: { $0.accessibilityIdentifier == id }) { return item }
        }
        return nil
    }

    /// The text field with this identifier, waiting a moment for it to come on screen.
    func textField(_ id: String, wait: TimeInterval = 2) -> UITextField? {
        var field: UITextField?
        lWait(wait) {
            if scrollsToFindElements { _ = find(id) }
            field = elements().first { $0.id == id && $0.element is UITextField }?.element as? UITextField
            return field != nil
        }
        return field
    }
}

/// A value a closure can change and a test can read afterwards.
final class LBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

let lSecret = "ABCDEFGHJKMNPQRSTVWXYZ0123"
let lLink = "https://hydrodrop.us/duo#H7K39QWX.\(lSecret)"
let lRestore = DuoAvailability.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))

/// A real store over fakes, old enough unless said otherwise. The kit's own defaults suite is the
/// foundation's to clear (`DuoSuiteJanitor`); these tests make none of their own.
@MainActor
func lKit(age: DuoAgeStatus? = .allowed, credential: DuoCredential? = nil, secretStore: DuoMemorySecretStore = DuoMemorySecretStore()) -> DuoTestKit {
    let kit = DuoTestKit(credential: credential, secretStore: secretStore)
    if credential != nil { kit.identity.launch = .ready }
    if age == .allowed { kit.store.recordBirthYear(1990, month: 1, now: kit.clock.now) }
    return kit
}

@MainActor
final class DuoCodeEntryViewTests: XCTestCase {

    /// Nothing but the one call: no request, no identity, no sync, no exit, nothing kept.
    private func assertNothingElseWasAsked(_ kit: DuoTestKit, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(kit.transport.calls, [], "the sheet sends nothing", file: file, line: line)
        XCTAssertEqual(kit.identity.prepared, 0, "nor asks the identity", file: file, line: line)
        XCTAssertEqual(kit.identity.stored, [], file: file, line: line)
        XCTAssertEqual(kit.sync.calls, [], file: file, line: line)
        XCTAssertEqual(kit.exiting.calls, [], file: file, line: line)
        XCTAssertEqual(kit.attester.attestedNewKeys, 0, file: file, line: line)
        XCTAssertEqual(kit.secretStore.accounts(service: DuoSecrets.service), [], "nothing is written to the Keychain", file: file, line: line)
    }

    /// The Scan tap, from a test that is not async (one that puts a view on screen).
    private func scan(_ controller: DuoCodeEntryController, in store: DuoStore) {
        let done = expectation(description: "scan tapped")
        Task { await controller.scanTapped(in: store); done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// The sheet presented as the Duo screen presents it, with a controller and camera the test holds.
    private func present(_ kit: DuoTestKit, _ controller: DuoCodeEntryController, capture: LFakeCapture? = nil,
                         openURL: ((URL) -> Void)? = nil) throws -> (LScreen, LPresenter) {
        let capture = capture ?? LFakeCapture()
        let presenter = LPresenter()
        let screen = try LScreen(LSheetHost(presenter: presenter) {
            DuoCodeEntrySheet(duoStore: kit.store, controller: controller, makeCapture: { capture })
                .environment(\.openURL, OpenURLAction { url in openURL?(url); return .handled })
        }, test: self)
        XCTAssertTrue(lWait { screen.sheet != nil }, "the sheet came up")
        lSpin(0.5)
        return (screen, presenter)
    }

    // MARK: - Continue

    func testAGoodCodeIsReceivedOnceAndTheSheetCloses() {
        for typed in ["h7k3-9qwx", "H7K3 9QWX", "H7KO-9QWL", "  h7k39qwx  ", "h7k39qwx\n"] {
            let kit = lKit()
            let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
            controller.text = typed
            XCTAssertTrue(controller.continueTapped(in: kit.store), typed)
            let canonical = DuoInviteCode.normalize(DuoCodeEntryModel.trimmed(typed))!
            XCTAssertEqual(kit.joining.calls, ["receive:\(canonical)"], "received once and nothing else: \(typed)")
            XCTAssertFalse(controller.showsNotACode)
            assertNothingElseWasAsked(kit)
        }
    }

    func testAPastedLinkKeepsItsSecretOnlyInThePendingInviteAndSendsNothing() throws {
        let kit = lKit()
        // The real joining service, whose `receive` is what keeps the pending invite.
        kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        controller.text = "https://hydrodrop.us/duo#h7k39qwx.\(lSecret)"
        XCTAssertTrue(controller.continueTapped(in: kit.store))
        let pending = try XCTUnwrap(kit.store.pendingInvite)
        XCTAssertEqual(pending.code, "H7K39QWX")
        XCTAssertEqual(pending.k, lSecret, "the secret goes on with the code, verbatim")
        let saved = try XCTUnwrap(kit.defaults.data(forKey: DuoCache.pendingInviteKey))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(lSecret), "the secret is never written to the App Group defaults")
        assertNothingElseWasAsked(kit)
    }

    func testABadCodeSaysSoAndIsNeverReceived() {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        for bad in ["H7K39QW", "H7K39QWXY", "H7K3-9QWU", "https://example.com/duo#H7K39QWX", "hydrodrop.us/duo#H7K39QWX",
                    "https://hydrodrop.us/duo?c=H7K39QWX", "\u{1F4A7}\u{1F4A7}\u{1F4A7}"] {
            controller.text = bad
            XCTAssertFalse(controller.continueTapped(in: kit.store), bad)
            XCTAssertTrue(controller.showsNotACode, bad)
        }
        XCTAssertEqual(kit.joining.calls, [], "a bad code is never received")
        assertNothingElseWasAsked(kit)
        controller.text = "H7K39QWX"
        XCTAssertFalse(controller.showsNotACode, "editing the field takes the line away again")
    }

    func testAnEmptyFieldDoesNothingAndSaysNothing() {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        for blank in ["", "   ", "\n"] {
            controller.text = blank
            XCTAssertFalse(controller.continueTapped(in: kit.store))
            XCTAssertFalse(controller.showsNotACode, "nothing typed is not a wrong code")
        }
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testAnUnknownAgeStillStoresTheCodeForTheJoinSheetsGateToAskAbout() {
        let kit = lKit(age: nil)
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        controller.text = "H7K39QWX"
        XCTAssertTrue(controller.continueTapped(in: kit.store))
        XCTAssertEqual(kit.joining.calls, ["receive:H7K39QWX"])
        assertNothingElseWasAsked(kit)
    }

    func testARefusedPersonIsReceivedNothing() {
        let kit = lKit(age: nil)
        XCTAssertEqual(kit.store.recordBirthYear(2024, month: 1, now: kit.clock.now), .refused)
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        controller.text = "H7K39QWX"
        XCTAssertFalse(controller.continueTapped(in: kit.store), "the sheet stays, showing the refusal")
        XCTAssertFalse(controller.scanned(DuoParsedInvite(code: "H7K39QWX"), in: kit.store))
        XCTAssertEqual(kit.joining.calls, [], "nothing is kept for someone who was refused")
        XCTAssertNil(kit.store.pendingInvite)
    }

    /// A refusal only the Keychain remembers (the defaults lost it, or could not be read when the
    /// store was made): the memory says allowed, `receive` finds the refusal, keeps nothing and
    /// publishes it, and the sheet must stay on it rather than close as if the code went through.
    func testARefusalOnlyTheKeychainRemembersKeepsTheSheetOpen() throws {
        let kit = lKit()
        XCTAssertEqual(kit.store.ageStatus, .allowed)
        try kit.dependencies.secrets.markAgeRefused()
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        controller.text = "H7K39QWX"
        XCTAssertFalse(controller.continueTapped(in: kit.store), "the sheet does not close on a code that was not kept")
        XCTAssertEqual(kit.store.ageStatus, .refused, "the refusal is now what the sheet draws")
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testWhileThePhoneMayNotJoinNoCodeIsTaken() {
        for availability in [DuoAvailability.disconnected, lRestore, .upgradeRequired, .banned] {
            let kit = lKit()
            let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
            scan(controller, in: kit.store)
            XCTAssertEqual(controller.mode, .scanning)
            kit.store.availability = availability
            controller.text = "H7K39QWX"
            XCTAssertFalse(controller.continueTapped(in: kit.store), "\(availability)")
            XCTAssertFalse(controller.scanned(DuoParsedInvite(code: "H7K39QWX"), in: kit.store), "\(availability)")
            XCTAssertEqual(controller.mode, .typing, "a code the phone could not take still ends the scan: \(availability)")
            XCTAssertEqual(kit.joining.calls, [], "\(availability)")
        }
        for availability in [DuoAvailability.unknown, .available, .maintenance] {
            let kit = lKit()
            kit.store.availability = availability
            let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
            controller.text = "H7K39QWX"
            XCTAssertTrue(controller.continueTapped(in: kit.store), "\(availability)")
            XCTAssertEqual(kit.joining.calls, ["receive:H7K39QWX"], "\(availability)")
        }
    }

    func testAScannedLinkGoesTheSameWayAsATypedOne() {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        XCTAssertTrue(controller.scanned(DuoParsedInvite(code: "H7K39QWX", k: lSecret), in: kit.store))
        XCTAssertEqual(controller.mode, .typing)
        XCTAssertEqual(kit.joining.calls, ["receive:H7K39QWX"])
        assertNothingElseWasAsked(kit)
    }

    // MARK: - The camera permission

    func testScanAsksOnceWhenNeverAskedAndOpensTheScannerOnAYes() async {
        let kit = lKit()
        let camera = LFakeCamera(status: 0, grants: true)
        let controller = DuoCodeEntryController(camera: camera)
        XCTAssertEqual(camera.requestCount, 0)
        await controller.scanTapped(in: kit.store)
        XCTAssertEqual(camera.requestCount, 1)
        XCTAssertEqual(controller.mode, .scanning)
        XCTAssertEqual(controller.cameraLine, .none)
    }

    func testReturningToTypingWhilePermissionWaitsRequiresANewScanTap() async {
        let kit = lKit()
        let camera = LFakeCamera(status: 0, grants: true)
        camera.holdsTheQuestion = true
        defer { camera.answer() }
        let controller = DuoCodeEntryController(camera: camera)
        let tap = Task { await controller.scanTapped(in: kit.store) }
        for _ in 0..<1000 {
            if camera.isAsking { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard camera.isAsking else { return XCTFail("the permission request began") }
        controller.backToTyping()
        camera.answer()
        await tap.value
        XCTAssertEqual(controller.mode, .typing, "a late permission grant must not resume the cancelled scan")
        await controller.scanTapped(in: kit.store)
        XCTAssertEqual(controller.mode, .scanning, "a fresh explicit tap can still scan")
    }

    func testClosingTheSheetInvalidatesAnAwaitedCameraGrant() throws {
        let kit = lKit()
        let camera = LFakeCamera(status: 0, grants: true)
        camera.holdsTheQuestion = true
        defer { camera.answer() }
        let controller = DuoCodeEntryController(camera: camera)
        let (screen, presenter) = try present(kit, controller)
        screen.tap("duo.code.scan")
        XCTAssertTrue(lWait { camera.isAsking })
        presenter.showing = false
        XCTAssertTrue(lWait { presenter.dismissals == 1 })
        camera.answer()
        XCTAssertTrue(lWait { !controller.isAskingForTheCamera })
        XCTAssertEqual(controller.mode, .typing, "an off-screen sheet must not arm its scanner")
    }

    func testANoToTheQuestionSaysTheCameraIsOffAndKeepsTheField() async {
        let kit = lKit()
        let camera = LFakeCamera(status: 0, grants: false)
        let controller = DuoCodeEntryController(camera: camera)
        await controller.scanTapped(in: kit.store)
        XCTAssertEqual(camera.requestCount, 1)
        XCTAssertEqual(controller.mode, .typing)
        XCTAssertEqual(controller.cameraLine, .off)
    }

    func testADeniedOrRestrictedCameraIsNotAskedAgainAndIsSaidInItsOwnWords() async {
        for (status, line) in [(1, DuoCodeEntryModel.CameraLine.restricted), (2, .off), (7, .off)] {
            let kit = lKit()
            let camera = LFakeCamera(status: status)
            let controller = DuoCodeEntryController(camera: camera)
            await controller.scanTapped(in: kit.store)
            XCTAssertEqual(camera.requestCount, 0, "\(status)")
            XCTAssertEqual(controller.mode, .typing, "\(status)")
            XCTAssertEqual(controller.cameraLine, line, "\(status)")
        }
    }

    func testAnAllowedCameraOpensTheScannerWithoutAsking() async {
        let kit = lKit()
        let camera = LFakeCamera(status: 3)
        let controller = DuoCodeEntryController(camera: camera)
        await controller.scanTapped(in: kit.store)
        XCTAssertEqual(camera.requestCount, 0)
        XCTAssertEqual(controller.mode, .scanning)
        controller.backToTyping()
        XCTAssertEqual(controller.mode, .typing)
    }

    func testWithoutACameraThereIsNoScanAndNothingIsAsked() async {
        let kit = lKit()
        let camera = LFakeCamera(present: false, status: 0)
        let controller = DuoCodeEntryController(camera: camera)
        XCTAssertFalse(controller.hasCamera)
        await controller.scanTapped(in: kit.store)
        XCTAssertEqual(camera.requestCount, 0)
        XCTAssertEqual(camera.statusReads, 0)
        XCTAssertEqual(controller.mode, .typing)
        XCTAssertEqual(controller.cameraLine, .none)
    }

    func testNoCameraIsAskedForSomeoneWhoWasRefusedOrAPhoneThatMayNotJoin() async {
        let refused = lKit(age: nil)
        refused.store.recordBirthYear(2024, month: 1, now: refused.clock.now)
        let blocked = lKit()
        blocked.store.availability = .disconnected
        for kit in [refused, blocked] {
            let camera = LFakeCamera(status: 0)
            let controller = DuoCodeEntryController(camera: camera)
            await controller.scanTapped(in: kit.store)
            XCTAssertEqual(camera.requestCount, 0)
            XCTAssertEqual(camera.statusReads, 0)
            XCTAssertEqual(controller.mode, .typing)
        }
    }

    func testASecondTapWhileTheQuestionIsUpDoesNotAskAgain() async {
        let kit = lKit()
        let camera = LFakeCamera(status: 0, grants: true)
        camera.holdsTheQuestion = true
        let controller = DuoCodeEntryController(camera: camera)
        let first = Task { await controller.scanTapped(in: kit.store) }
        while !camera.isAsking { await Task.yield() }
        XCTAssertTrue(controller.isAskingForTheCamera)
        XCTAssertFalse(controller.layout(in: kit.store).scanButtonIsEnabled, "the button is off while the question is up")
        await controller.scanTapped(in: kit.store)
        XCTAssertEqual(camera.requestCount, 1, "one question, however many taps")
        camera.answer()
        await first.value
        XCTAssertEqual(controller.mode, .scanning)
        XCTAssertFalse(controller.isAskingForTheCamera)
    }

    /// The question can stay up as long as the person likes. A phone that stopped taking codes
    /// meanwhile (a 426 from a background refresh, say) must not be left with the scanner chosen,
    /// or the camera would come on by itself once the reason went away (review probe P7).
    func testAYesAfterThePhoneStoppedTakingCodesDoesNotArmTheScanner() async {
        let kit = lKit()
        let camera = LFakeCamera(status: 0, grants: true)
        camera.holdsTheQuestion = true
        let controller = DuoCodeEntryController(camera: camera)
        let tap = Task { await controller.scanTapped(in: kit.store) }
        while !camera.isAsking { await Task.yield() }
        kit.store.availability = .upgradeRequired
        camera.answer()
        await tap.value
        XCTAssertEqual(controller.mode, .typing)
        kit.store.availability = .available
        XCTAssertFalse(controller.layout(in: kit.store).showsScanner, "the scanner does not come on by itself")
    }

    /// The four statuses `DuoCameraAccess` reads by number are AVFoundation's own.
    func testTheRawStatusesAreAVFoundations() {
        XCTAssertEqual(AVAuthorizationStatus.notDetermined.rawValue, 0)
        XCTAssertEqual(AVAuthorizationStatus.restricted.rawValue, 1)
        XCTAssertEqual(AVAuthorizationStatus.denied.rawValue, 2)
        XCTAssertEqual(AVAuthorizationStatus.authorized.rawValue, 3)
        XCTAssertEqual(DuoLiveCameraAuthorization().rawStatus, AVCaptureDevice.authorizationStatus(for: .video).rawValue)
    }

    // MARK: - The scanner's rules, with a fake camera

    private final class LCount { var value = 0 }

    private func scanController(_ capture: LFakeCapture, center: NotificationCenter = NotificationCenter(),
                                takes: Bool = true, invites: @escaping (DuoParsedInvite) -> Void = { _ in },
                                closed: @escaping (DuoCodeEntryModel.CameraLine) -> Void = { _ in },
                                haptics: LCount = LCount()) -> DuoQRScanController {
        DuoQRScanController(capture: capture, notificationCenter: center, succeeded: { haptics.value += 1 },
                            onInvite: { invites($0); return takes }, onClosed: closed)
    }

    func testTheFirstDuoLinkIsUsedOnceTheCameraHasStoppedAndLaterFramesAreIgnored() {
        let capture = LFakeCapture()
        var invites: [DuoParsedInvite] = []
        var stopsWhenHandedOn: [Int] = []
        let haptics = LCount()
        let controller = scanController(capture, invites: { invites.append($0); stopsWhenHandedOn.append(capture.stops) }, haptics: haptics)
        XCTAssertNotNil(controller.start(), "the preview is shown")
        XCTAssertEqual(capture.starts, 1)
        XCTAssertTrue(controller.isObservingBackground)
        for other in ["https://example.com/menu", "Hello", "WIFI:S:Home;;", "https://example.com/duo#H7K39QWX", "H7K39QWX", "H7K3-9QWX"] {
            capture.frame(other)
        }
        XCTAssertEqual(invites, [], "anything that is not a duo link is ignored without a word, a bare code included")
        XCTAssertEqual(capture.stops, 0, "and the camera keeps looking")
        capture.frame(lLink)
        XCTAssertEqual(invites, [DuoParsedInvite(code: "H7K39QWX", k: lSecret)])
        XCTAssertEqual(stopsWhenHandedOn, [1], "the camera stopped before the code was handed on")
        XCTAssertEqual(haptics.value, 1)
        XCTAssertFalse(controller.isObservingBackground, "stopping let the background observer go too")
        capture.frame("https://hydrodrop.us/duo#AAAABBBB")
        capture.frame(lLink)
        XCTAssertEqual(invites.count, 1, "frames after the first code are ignored")
        XCTAssertEqual(haptics.value, 1)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.start(), "a scanner that has read its code never starts again")
        XCTAssertEqual(capture.starts, 1)
    }

    /// Words on a QR code that happen to be eight letters of the alphabet are not a code (D88): the
    /// first version kept "PASSWORD" as the pending invite `PASSW0RD` and peeked it at the server.
    func testAWordOnAQRCodeNeverReachesTheStore() {
        for payload in ["PASSWORD", "12345678", "WELCOME1", "SHIPMENT", "A B C D E F G H", "H7K3-9QWX"] {
            let kit = lKit()
            let entry = DuoCodeEntryController(camera: LFakeCamera(status: 3))
            let capture = LFakeCapture()
            let scanner = DuoQRScanController(capture: capture, notificationCenter: NotificationCenter(), succeeded: {},
                                              onInvite: { entry.scanned($0, in: kit.store) }, onClosed: { _ in })
            _ = scanner.start()
            capture.frame(payload)
            XCTAssertEqual(kit.joining.calls, [], payload)
            XCTAssertNil(kit.store.pendingInvite, payload)
            XCTAssertTrue(scanner.isRunning, "the camera keeps looking: \(payload)")
            XCTAssertEqual(kit.transport.calls, [], payload)
        }
    }

    func testTheHapticPlaysOnlyWhenTheCodeIsTaken() {
        let capture = LFakeCapture()
        let haptics = LCount()
        let controller = scanController(capture, takes: false, haptics: haptics)
        _ = controller.start()
        capture.frame(lLink)
        XCTAssertFalse(controller.isRunning, "the camera stops either way")
        XCTAssertEqual(haptics.value, 0, "a code the sheet did not take is not celebrated")
    }

    func testACameraThatCannotStartOrIsTakenAwayGoesBackToTypingAndSaysSo() {
        for reason in [DuoQRCaptureEnd.couldNotStart, .interrupted] {
            let capture = LFakeCapture()
            var closed: [DuoCodeEntryModel.CameraLine] = []
            var invites: [DuoParsedInvite] = []
            let controller = scanController(capture, invites: { invites.append($0) }, closed: { closed.append($0) })
            _ = controller.start()
            capture.end(reason)
            XCTAssertEqual(closed, [.unavailableNow], "\(reason)")
            XCTAssertFalse(controller.isRunning, "\(reason)")
            XCTAssertEqual(capture.stops, 1, "\(reason)")
            XCTAssertFalse(controller.isObservingBackground, "\(reason)")
            capture.frame(lLink)
            XCTAssertEqual(invites, [], "\(reason)")
            capture.end(reason)
            XCTAssertEqual(closed.count, 1, "said once: \(reason)")
        }
    }

    func testGoingToTheBackgroundStopsTheCameraAndGoesBackToTyping() {
        let capture = LFakeCapture()
        let center = NotificationCenter()
        var closed: [DuoCodeEntryModel.CameraLine] = []
        var invites: [DuoParsedInvite] = []
        let controller = scanController(capture, center: center, invites: { invites.append($0) }, closed: { closed.append($0) })
        XCTAssertNotNil(controller.start())
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(closed, [.none], "the person left the app; nothing to say when they come back")
        XCTAssertFalse(controller.isRunning)
        capture.frame(lLink)
        XCTAssertEqual(invites, [], "a frame after the camera went is ignored")
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(capture.stops, 1, "the observer went with the camera")
        XCTAssertEqual(closed.count, 1)
    }

    func testStoppingIsFinalAndSafeToRepeat() {
        let capture = LFakeCapture()
        let controller = scanController(capture)
        XCTAssertNotNil(controller.start())
        controller.stop()
        controller.stop()
        XCTAssertEqual(capture.stops, 1, "the session was let go on the first stop")
        XCTAssertFalse(controller.isObservingBackground)
        XCTAssertNil(controller.start())
        XCTAssertEqual(capture.starts, 1)
    }

    func testTakingTheScannerViewApartStopsTheCamera() {
        let capture = LFakeCapture()
        let controller = scanController(capture)
        let view = DuoQRPreviewView()
        view.previewLayer = controller.start()
        XCTAssertEqual(view.layer.sublayers?.contains(capture.layer), true)
        DuoQRScannerView.dismantleUIView(view, coordinator: controller)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertNil(view.previewLayer)
        XCTAssertEqual(view.layer.sublayers?.contains(capture.layer) ?? false, false)
    }

    // MARK: - The real session, as far as a simulator can go

    func testAScannerSessionIsGivenOneOutputThatReadsQRCodesOnTheMainQueue() {
        XCTAssertEqual(DuoLiveQRCapture.readsOnly, [.qr])
        let session = AVCaptureSession()
        let delegate = DuoLiveQRCapture()
        let configured = DuoLiveQRCapture.configure(session, input: nil, delegate: delegate)
        XCTAssertFalse(configured, "a session with no camera offers no QR codes and must not be started")
        XCTAssertEqual(session.outputs.count, 1, "one output and no other")
        for output in session.outputs {
            XCTAssertTrue(type(of: output) == AVCaptureMetadataOutput.self, "\(type(of: output)) may not be added to a scanner session")
        }
        let metadata = session.outputs.first as? AVCaptureMetadataOutput
        XCTAssertTrue(metadata?.metadataObjectsDelegate === delegate)
        XCTAssertTrue(metadata?.metadataObjectsCallbackQueue === DispatchQueue.main, "the delegate assumes the main actor")
        XCTAssertEqual(metadata?.metadataObjectTypes ?? [], [])
        DuoLiveQRCapture.release(session)
        XCTAssertEqual(session.outputs.count, 0)
    }

    func testTheOutputIsAskedForQRCodesAlone() {
        XCTAssertEqual(DuoLiveQRCapture.typesToRead(available: [.ean13, .qr, .face, .aztec]), [.qr])
        XCTAssertEqual(DuoLiveQRCapture.typesToRead(available: [.qr]), [.qr])
        XCTAssertNil(DuoLiveQRCapture.typesToRead(available: [.ean13, .face]))
        XCTAssertNil(DuoLiveQRCapture.typesToRead(available: []))
    }

    func testOnlyQRPayloadsAreHandedOn() {
        let read: [(type: AVMetadataObject.ObjectType, text: String?)] = [
            (.ean13, "4006381333931"), (.qr, lLink), (.aztec, "H7K39QWX"), (.qr, nil), (.face, nil), (.qr, "second"),
        ]
        XCTAssertEqual(DuoLiveQRCapture.qrPayloads(read), [lLink, "second"])
    }

    /// `release` empties a session, so nothing of the camera stays reachable. (Whether it stops a
    /// running one, interrupted or not, needs a camera: a by-hand check on a phone.)
    func testReleaseEmptiesASession() {
        let session = AVCaptureSession()
        let delegate = DuoLiveQRCapture()
        DuoLiveQRCapture.configure(session, input: nil, delegate: delegate)
        XCTAssertEqual(session.outputs.count, 1)
        DuoLiveQRCapture.release(session)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.outputs.count, 0)
        XCTAssertEqual(session.inputs.count, 0)
    }

    func testWithoutACameraTheRealSessionSaysItCouldNotStartAndHoldsNothing() throws {
        try XCTSkipIf(AVCaptureDevice.default(for: .video) != nil, "only meaningful where there is no camera; never start a real one in a test")
        XCTAssertFalse(DuoLiveCameraAuthorization().hasCamera)
        let capture = DuoLiveQRCapture()
        let ended = LBox<[DuoQRCaptureEnd]>([])
        capture.start(delivering: { _ in XCTFail("nothing can be read without a camera") }, ended: { ended.value.append($0) })
        XCTAssertTrue(lWait { !ended.value.isEmpty }, "the failure is said, a turn later")
        XCTAssertEqual(ended.value, [.couldNotStart])
        XCTAssertFalse(capture.isHoldingSession)
        XCTAssertNil(capture.previewLayer)
        capture.stop()
        XCTAssertFalse(capture.isHoldingSession)
    }

    func testOpenSettingsGoesToThisAppsSettings() {
        XCTAssertEqual(DuoCodeEntrySheet.settingsURL, URL(string: UIApplication.openSettingsURLString))
    }

    // MARK: - On screen

    func testTheSheetAsksTheCameraNothingAndSendsNothingWhenItAppears() throws {
        let kit = lKit()
        let camera = LFakeCamera(status: 0)
        _ = try present(kit, DuoCodeEntryController(camera: camera))
        XCTAssertEqual(camera.requestCount, 0, "the permission is never asked on appear")
        XCTAssertEqual(camera.statusReads, 0, "nor is the status read")
        assertNothingElseWasAsked(kit)
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testContinueStoresTheCodeAndClosesTheSheet() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 0))
        let (screen, presenter) = try present(kit, controller)
        let field = try XCTUnwrap(screen.textField("duo.code.field"))
        field.text = "h7k3-9qwx"
        field.sendActions(for: .editingChanged)
        lSpin(0.2)
        XCTAssertEqual(controller.text, "h7k3-9qwx")
        screen.tap("duo.code.continue")
        XCTAssertTrue(lWait { presenter.dismissals == 1 }, "the sheet closed itself")
        XCTAssertEqual(kit.joining.calls, ["receive:H7K39QWX"])
        assertNothingElseWasAsked(kit)
    }

    func testABadCodeKeepsTheSheetOpenAndSaysSoUnderTheField() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 0))
        controller.text = "H7K39QW"
        let (screen, presenter) = try present(kit, controller)
        XCTAssertFalse(screen.has("duo.code.error"))
        screen.tap("duo.code.continue")
        XCTAssertTrue(lWait { screen.has("duo.code.error") })
        XCTAssertEqual(screen.label("duo.code.error"), DuoCopy.notACode)
        lSpin(0.3)
        XCTAssertEqual(presenter.dismissals, 0)
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testAScannedLinkStoresTheCodeAndClosesTheSheet() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        scan(controller, in: kit.store)
        let capture = LFakeCapture()
        let (screen, presenter) = try present(kit, controller, capture: capture)
        XCTAssertTrue(lWait { capture.starts == 1 }, "the camera starts when the scanner is on screen")
        XCTAssertTrue(screen.has("duo.code.scanner"))
        capture.frame(lLink)
        XCTAssertTrue(lWait { presenter.dismissals == 1 }, "the sheet closed itself")
        XCTAssertEqual(kit.joining.calls, ["receive:H7K39QWX"])
        XCTAssertGreaterThanOrEqual(capture.stops, 1)
    }

    func testARefusedPersonIsShownTheRefusalAndNoForm() throws {
        let kit = lKit(age: nil)
        kit.store.recordBirthYear(2024, month: 1, now: kit.clock.now)
        let camera = LFakeCamera(status: 3)
        let (screen, _) = try present(kit, DuoCodeEntryController(camera: camera))
        XCTAssertNil(screen.textField("duo.code.field", wait: 0.3), "no field to type into")
        XCTAssertFalse(screen.has("duo.code.continue"))
        XCTAssertFalse(screen.has("duo.code.scan"))
        XCTAssertEqual(camera.statusReads, 0)
    }

    /// A refusal kept only in the Keychain is found when the sheet appears (`recheckAge`), before the
    /// person types or the camera is asked for.
    func testTheSheetFindsARefusalOnlyTheKeychainKept() throws {
        let kit = lKit()
        try kit.dependencies.secrets.markAgeRefused()
        XCTAssertEqual(kit.store.ageStatus, .allowed)
        let (screen, _) = try present(kit, DuoCodeEntryController(camera: LFakeCamera(status: 3)))
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertTrue(lWait { screen.textField("duo.code.field", wait: 0) == nil }, "the refusal replaced the form")
        XCTAssertFalse(screen.has("duo.code.scan"))
    }

    func testThePhonesReasonIsDrawnWhenItMayNotJoin() throws {
        let kit = lKit()
        kit.store.availability = .disconnected
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        controller.text = "H7K39QWX"
        let (screen, _) = try present(kit, controller)
        XCTAssertEqual(screen.label("duo.entry.notice")?.contains("This phone was disconnected from the duo"), true)
        XCTAssertEqual(screen.textField("duo.code.field")?.isEnabled, false, "nothing can be typed")
        XCTAssertEqual(screen.isEnabled("duo.code.continue"), false)
        XCTAssertFalse(screen.has("duo.code.scan"), "no camera for a phone that cannot join")
        kit.store.availability = .available
        XCTAssertTrue(lWait { !screen.has("duo.entry.notice") }, "the reason goes with the cause")
        XCTAssertEqual(screen.textField("duo.code.field")?.isEnabled, true)
        XCTAssertEqual(screen.isEnabled("duo.code.continue"), true)
    }

    func testContinueIsOffUntilSomethingIsTyped() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 0))
        let (screen, _) = try present(kit, controller)
        XCTAssertEqual(screen.isEnabled("duo.code.continue"), false)
        controller.text = "x"
        XCTAssertTrue(lWait { screen.isEnabled("duo.code.continue") == true })
        controller.text = "   "
        XCTAssertTrue(lWait { screen.isEnabled("duo.code.continue") == false })
    }

    func testScanIsDrawnOnlyWithACamera() throws {
        let without = lKit()
        let (screen, _) = try present(without, DuoCodeEntryController(camera: LFakeCamera(present: false)))
        XCTAssertTrue(screen.has("duo.code.continue"))
        XCTAssertFalse(screen.has("duo.code.scan"))
        let with = lKit()
        let (other, _) = try present(with, DuoCodeEntryController(camera: LFakeCamera(status: 0)))
        XCTAssertTrue(other.has("duo.code.scan"))
    }

    func testCancelWhileScanningPutsTheCameraAwayAndKeepsTheSheet() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        scan(controller, in: kit.store)
        let capture = LFakeCapture()
        let (screen, presenter) = try present(kit, controller, capture: capture)
        XCTAssertTrue(lWait { capture.starts == 1 })
        screen.tap("duo.code.cancel")
        XCTAssertTrue(lWait { capture.stops >= 1 }, "the camera went")
        XCTAssertEqual(controller.mode, .typing)
        lSpin(0.3)
        XCTAssertEqual(presenter.dismissals, 0, "the sheet stays, on the field")
        XCTAssertNotNil(screen.textField("duo.code.field"))
        screen.tap("duo.code.cancel")
        XCTAssertTrue(lWait { presenter.dismissals == 1 }, "Cancel on the field closes the sheet")
    }

    /// A phone that stops being able to take a code while it scans goes back to the form, and the
    /// camera does not come back on by itself when the reason goes away.
    func testTheScannerDoesNotComeBackByItself() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        scan(controller, in: kit.store)
        let captures = LBox<[LFakeCapture]>([])
        let presenter = LPresenter()
        let screen = try LScreen(LSheetHost(presenter: presenter) {
            DuoCodeEntrySheet(duoStore: kit.store, controller: controller, makeCapture: {
                let capture = LFakeCapture()
                captures.value.append(capture)
                return capture
            })
        }, test: self)
        XCTAssertTrue(lWait { captures.value.first?.starts == 1 })
        kit.store.availability = .upgradeRequired
        XCTAssertTrue(lWait { (captures.value.first?.stops ?? 0) >= 1 }, "the camera went")
        XCTAssertTrue(lWait { screen.has("duo.entry.notice") }, "the form and its reason came back")
        kit.store.availability = .available
        lSpin(0.6)
        XCTAssertEqual(captures.value.count, 1, "no second camera")
        XCTAssertEqual(controller.mode, .typing)
        XCTAssertFalse(screen.has("duo.code.scanner"))
        XCTAssertEqual(presenter.dismissals, 0)
    }

    func testACameraThatCannotStartLeavesTheFieldAndALine() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        scan(controller, in: kit.store)
        let capture = LFakeCapture()
        let (screen, presenter) = try present(kit, controller, capture: capture)
        XCTAssertTrue(lWait { capture.starts == 1 })
        capture.end(.couldNotStart)
        XCTAssertTrue(lWait { screen.has("duo.code.cameraUnavailable") })
        XCTAssertNotNil(screen.textField("duo.code.field"))
        XCTAssertFalse(screen.has("duo.code.openSettings"))
        XCTAssertEqual(presenter.dismissals, 0)
    }

    func testADeniedCameraOffersSettingsAndARestrictedOneDoesNot() throws {
        let kit = lKit()
        var opened: [URL] = []
        let (screen, _) = try present(kit, DuoCodeEntryController(camera: LFakeCamera(status: 2)), openURL: { opened.append($0) })
        screen.tap("duo.code.scan")
        XCTAssertTrue(lWait { screen.has("duo.code.openSettings") })
        XCTAssertTrue(screen.has("duo.code.cameraOff"))
        screen.tap("duo.code.openSettings")
        XCTAssertTrue(lWait { !opened.isEmpty })
        XCTAssertEqual(opened, [URL(string: UIApplication.openSettingsURLString)!], "this app's page in Settings, nowhere else")

        let restricted = lKit()
        let (other, _) = try present(restricted, DuoCodeEntryController(camera: LFakeCamera(status: 1)))
        other.tap("duo.code.scan")
        XCTAssertTrue(lWait { other.has("duo.code.cameraRestricted") })
        XCTAssertFalse(other.has("duo.code.openSettings"), "Settings cannot lift a restriction someone else set")
    }

    /// The sheet's scanner on screen: going back to typing takes it off the screen, which stops the
    /// camera, and closing the sheet mid-scan stops it the same way.
    func testTheSheetsScannerStopsTheCameraWhenItLeavesTheScreen() throws {
        let kit = lKit()
        let controller = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        scan(controller, in: kit.store)
        let capture = LFakeCapture()
        let (_, presenter) = try present(kit, controller, capture: capture)
        XCTAssertTrue(lWait { capture.starts == 1 })
        XCTAssertEqual(capture.stops, 0)
        controller.backToTyping()
        XCTAssertTrue(lWait { capture.stops == 1 }, "going back to typing stopped it")

        let closing = LFakeCapture()
        let again = DuoCodeEntryController(camera: LFakeCamera(status: 3))
        scan(again, in: kit.store)
        let (_, closer) = try present(kit, again, capture: closing)
        XCTAssertTrue(lWait { closing.starts == 1 })
        closer.showing = false
        XCTAssertTrue(lWait { closer.dismissals == 1 })
        XCTAssertTrue(lWait { closing.stops == 1 }, "closing the sheet stopped it")
        XCTAssertEqual(presenter.dismissals, 0)
        XCTAssertEqual(kit.joining.calls, [])
    }

    /// The code-entry sheet over Settings, as the Duo screen presents it (review probe P6): Continue
    /// closes the entry sheet alone; Settings closes from its `onDismiss`, a turn later; then the
    /// join sheet comes up for the code. One sheet at a time, and nothing sent.
    func testContinueClosesOnlyTheEntrySheetAndTheJoinSheetFollowsOnce() throws {
        let kit = lKit(age: nil)
        kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
        let root = LRoot()
        let controller = DuoCodeEntryController(camera: LFakeCamera(present: false))
        let screen = try LScreen(LRootView(root: root, store: kit.store, controller: controller), test: self)
        XCTAssertTrue(lWait(6) { screen.has("duo.code.continue") }, "the entry sheet is up over Settings")
        controller.text = "h7k3-9qwx"
        lSpin(0.2)
        screen.tap("duo.code.continue")
        XCTAssertTrue(lWait(8) { root.joinShown }, "the join sheet came up")
        XCTAssertEqual(root.entryDismissals, 1)
        XCTAssertFalse(root.showingSettings)
        XCTAssertEqual(root.joinsShown, 1, "once")
        XCTAssertEqual(kit.store.pendingInvite?.code, "H7K39QWX")
        XCTAssertEqual(kit.transport.calls, [], "nothing sent: the age is still unknown")
    }

    // MARK: - The source

    /// Swift source with its comments taken out and its string literals kept: a `//` inside a string
    /// is not a comment, so nothing after it on that line can hide (the first version cut every line
    /// at its first `//`, which let `let s = "https://..."; print(payload)` through).
    private func code(of url: URL) throws -> String {
        let text = Array(try String(contentsOf: url, encoding: .utf8))
        var out = ""
        var index = 0
        var inString = false
        var multiline = false
        func at(_ offset: Int) -> Character? { index + offset < text.count ? text[index + offset] : nil }
        while index < text.count {
            let character = text[index]
            if inString {
                out.append(character)
                if character == "\\" { if let next = at(1) { out.append(next) }; index += 2; continue }
                if multiline {
                    if character == "\"", at(1) == "\"", at(2) == "\"" { out += "\"\""; index += 3; inString = false; continue }
                } else if character == "\"" || character == "\n" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "/", at(1) == "/" {
                while index < text.count, text[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", at(1) == "*" {
                index += 2
                while index < text.count, !(text[index] == "*" && at(1) == "/") { index += 1 }
                index += 2
                continue
            }
            if character == "\"" {
                inString = true
                multiline = at(1) == "\"" && at(2) == "\""
                if multiline { out += "\"\"\""; index += 3; continue }
            }
            out.append(character)
            index += 1
        }
        return out
    }

    /// What the camera usage string promises, held against the source: the scanner names only the
    /// AVFoundation types it needs, adds no output but the one metadata output, takes no picture,
    /// draws nothing out of the preview, reaches nothing by name through the Objective-C runtime,
    /// logs and keeps nothing; the sheets show a prefilled takeover code without letting it be
    /// copied; and nothing else in the app touches the camera, scans documents or shows the scanner.
    /// Xcode Cloud runs tests where the source checkout is not, so the test is skipped there.
    func testTheSourceKeepsTheCameraToReadingQRCodes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let appFolder = root.appendingPathComponent("HydroDrop")
        let scannerURL = appFolder.appendingPathComponent("Views/DuoQRScannerView.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: scannerURL.path), "the source checkout is not on this machine")
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

        let scanner = try code(of: scannerURL)
        let sheet = try code(of: appFolder.appendingPathComponent("Views/DuoCodeEntrySheet.swift"))
        let reconnect = try code(of: appFolder.appendingPathComponent("Views/DuoReconnectSheet.swift"))

        // Every AVFoundation name the scanner uses is on this list; a photo, video-frame, movie,
        // audio or depth output, a synchroniser or anything else has to be argued onto it.
        let allowed: Set<String> = [
            "AVFoundation", "AVCaptureDevice", "AVCaptureDeviceInput", "AVCaptureInput", "AVCaptureSession", "AVCaptureMetadataOutput",
            "AVCaptureMetadataOutputObjectsDelegate", "AVCaptureVideoPreviewLayer", "AVCaptureConnection", "AVMetadataObject",
            "AVMetadataMachineReadableCodeObject",
        ]
        let avName = try Regex("\\bAV[A-Za-z]+")
        let names = Set(scanner.matches(of: avName).map { String(scanner[$0.range]) })
        XCTAssertEqual(names.subtracting(allowed), [], "AVFoundation names the scanner may not use")
        XCTAssertFalse(sheet.contains("AVCapture") || sheet.contains("AVFoundation"), "the sheet reaches the camera only through the scanner")

        let forbidden = [
            "PhotoOutput", "VideoDataOutput", "MovieFileOutput", "AudioDataOutput", "StillImageOutput", "DepthDataOutput", "FileOutput",
            "addOutputWithNoConnections", "AssetWriter", "SampleBuffer", "PixelBuffer", "CIImage", "CGImage", "UIImage",
            "ImageRenderer", "drawHierarchy", "snapshotView", "render(in", "UIGraphicsImageRenderer", "PHPhotoLibrary",
            "SavedPhotosAlbum", "import Vision", "VisionKit", "DataScanner", "VNDetect", "VNImageRequest", "VNDocumentCamera",
            "UIImagePickerController", "perform(", "NSClassFromString", "NSSelectorFromString", "value(forKey", "setValue(",
            "print(", "NSLog", "os_log", "Logger", "debugPrint", "dump(", "fputs", "stderr", "stdout", "FileHandle",
            "URLSession", "URLRequest", "UserDefaults", "NSUbiquitousKeyValueStore", "FileManager", ".write(", "SecItem",
            "Keychain", "DuoTransport", "UIPasteboard", "static var", "requestAccess(for: .audio",
        ]
        for (name, text) in [("DuoQRScannerView", scanner), ("DuoCodeEntrySheet", sheet), ("DuoReconnectSheet", reconnect)] {
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(name) must not use \(word)")
            }
        }
        XCTAssertEqual(count("addOutput(", in: scanner), 1, "one output is added, in `configure`")
        XCTAssertEqual(count("addInput(", in: scanner), 1, "one input is added, in `configure`")
        XCTAssertEqual(count("AVCaptureMetadataOutput()", in: scanner), 1)
        XCTAssertEqual(count("metadataObjectTypes =", in: scanner), 1)
        XCTAssertEqual(count("availableMetadataObjectTypes", in: scanner), 1, "read once, and only to pick QR codes out of it")
        XCTAssertEqual(count("setMetadataObjectsDelegate(", in: scanner), 1)
        XCTAssertTrue(scanner.contains("setMetadataObjectsDelegate(delegate, queue: .main)"), "the delegate assumes the main actor")
        XCTAssertEqual(count("AVCaptureDevice.requestAccess(", in: scanner), 1, "the live camera's one question")
        XCTAssertEqual(count("requestAccess(", in: sheet), 1, "asked by the Scan tap and nowhere else in the sheet")
        XCTAssertFalse(reconnect.contains("Camera") || reconnect.contains("Capture") || reconnect.contains("QRScanner"),
                       "the reconnect sheet has no camera")
        XCTAssertFalse(reconnect.contains("textSelection"), "a prefilled takeover code cannot be selected and copied (D79)")
        XCTAssertTrue(sheet.contains("openURL(url)") && sheet.contains("UIApplication.openSettingsURLString"),
                      "Open Settings opens this app's Settings page")

        // Nothing else in the app touches the camera, scans, or shows the scanner.
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let text = try code(of: url)
            for word in ["UIImagePickerController", "DataScannerViewController", "VNDocumentCameraViewController", "import VisionKit"] {
                XCTAssertFalse(text.contains(word), "\(name) uses \(word)")
            }
            if name != "DuoQRScannerView.swift" {
                XCTAssertFalse(text.contains("AVCapture"), "\(name) touches the camera")
                XCTAssertFalse(text.contains("requestAccess(for: .video"), "\(name) asks for the camera")
            }
            if name != "DuoCodeEntrySheet.swift" && name != "DuoQRScannerView.swift" {
                XCTAssertFalse(text.contains("DuoQRScannerView(") || text.contains("DuoQRScanController("), "\(name) shows the scanner")
            }
        }
    }

    /// The source reader itself: a `//` inside a string does not hide what follows it.
    func testTheSourceReaderKeepsStringsAndDropsComments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("duo-l-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Sample.swift")
        let sample = "let s = \"https://x\"; print(payload) // a comment with UIImage\n/* PhotoOutput */ let t = \"\"\"\n// kept\n\"\"\"\n"
        try sample.write(to: file, atomically: true, encoding: .utf8)
        let read = try code(of: file)
        XCTAssertTrue(read.contains("print(payload)"))
        XCTAssertTrue(read.contains("\"https://x\""))
        XCTAssertFalse(read.contains("UIImage"))
        XCTAssertFalse(read.contains("PhotoOutput"))
        XCTAssertTrue(read.contains("// kept"), "a multi-line string keeps its text")
    }
}

/// A stand-in for the root, Settings and the Duo screen: Settings is a sheet; the code-entry sheet
/// is presented from it; its `onDismiss` closes Settings when a code was kept (stage H's rule); the
/// join sheet is presented from the root only once Settings has gone (stage K's).
@MainActor
final class LRoot: ObservableObject {
    @Published var showingSettings = true
    @Published var showingEntry = false
    @Published var settingsOnScreen = false
    @Published var entryDismissals = 0
    @Published var joinShown = false
    var joinsShown = 0
    var before: DuoPendingInvite?
}

struct LRootView: View {
    @ObservedObject var root: LRoot
    @ObservedObject var store: DuoStore
    let controller: DuoCodeEntryController

    private var joinItem: Binding<DuoPendingInvite?> {
        Binding(get: { root.settingsOnScreen || root.showingEntry ? nil : store.pendingInvite }, set: { if $0 == nil { store.pendingInvite = nil } })
    }

    var body: some View {
        Color.clear
            .sheet(isPresented: $root.showingSettings, onDismiss: { root.settingsOnScreen = false }) {
                Color.clear
                    .onAppear { root.settingsOnScreen = true; root.before = store.pendingInvite; root.showingEntry = true }
                    .sheet(isPresented: $root.showingEntry, onDismiss: {
                        root.entryDismissals += 1
                        if store.pendingInvite != root.before { root.showingSettings = false }
                    }) {
                        DuoCodeEntrySheet(duoStore: store, controller: controller)
                    }
            }
            .sheet(item: joinItem) { _ in
                Color.clear.onAppear { root.joinShown = true; root.joinsShown += 1 }
            }
    }
}
#endif
