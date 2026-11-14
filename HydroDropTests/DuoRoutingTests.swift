#if DUO_V2
import UIKit
import XCTest
@testable import HydroDrop

/// Duo links through `AppRouter.handle(_:)`, the one place every address the app is opened with
/// arrives (a universal link, a QR code read by the Camera, a tag, the in-app scanner), and bottle
/// tags still reaching Today unaffected (final design §4.1's strict parser, vector KV1).
///
/// The router is the app's singleton, and the app's own root view observes it while these run (the
/// tests are hosted by the app). Every test is synchronous and puts the router back before it
/// returns, so the root never sees a value between two of its updates and never acts on one: a link
/// left standing would have it store an invite in the simulator's real Duo store.
@MainActor
final class DuoRoutingTests: XCTestCase {
    private let k = "ABCDEFGHJKMNPQRSTVWXYZ0123"
    private let tagID = UUID(uuidString: "6B1E7F70-0000-4000-8000-00000000ABCD")!

    override func setUp() {
        super.setUp()
        kReset()
    }

    override func tearDown() {
        kReset()
        super.tearDown()
    }

    private func kReset() {
        AppRouter.shared.pendingDuoLink = nil
        AppRouter.shared.pendingBottleTagID = nil
    }

    /// Hands `address` to the router and says what it kept, then puts the router back.
    private func route(_ address: String, file: StaticString = #filePath, line: UInt = #line)
        -> (handled: Bool, link: DuoParsedInvite?, tag: UUID?) {
        guard let url = URL(string: address) else {
            XCTFail("not a URL: \(address)", file: file, line: line)
            return (false, nil, nil)
        }
        let handled = AppRouter.shared.handle(url)
        let result = (handled, AppRouter.shared.pendingDuoLink, AppRouter.shared.pendingBottleTagID)
        kReset()
        return result
    }

    // MARK: - Good links

    func testALinkWithoutASecretIsKeptAsAPendingDuoLink() {
        let routed = route("https://hydrodrop.us/duo#H7K39QWX")
        XCTAssertTrue(routed.handled)
        XCTAssertEqual(routed.link, DuoParsedInvite(code: "H7K39QWX", k: nil))
        XCTAssertNil(routed.tag)
    }

    func testALinkWithItsSecretKeepsTheSecretVerbatim() {
        let routed = route("https://hydrodrop.us/duo#H7K39QWX.\(k)")
        XCTAssertTrue(routed.handled)
        XCTAssertEqual(routed.link?.code, "H7K39QWX")
        XCTAssertEqual(routed.link?.k, k)
        XCTAssertNil(routed.tag)
    }

    func testTheCodeIsNormalisedButTheSecretIsNot() {
        // A link retyped in lower case, with the display hyphen, still works: the code is
        // normalised. The secret is taken exactly as it is or not at all.
        XCTAssertEqual(route("https://hydrodrop.us/duo#h7k3-9qwx").link, DuoParsedInvite(code: "H7K39QWX"))
        XCTAssertEqual(route("https://hydrodrop.us/duo#H7K3-9QWX.\(k)").link, DuoParsedInvite(code: "H7K39QWX", k: k))
        XCTAssertNil(route("https://hydrodrop.us/duo#H7K39QWX.\(k.lowercased())").link)
        // `O`, `I` and `L` read as `0`, `1` and `1` in the code.
        XCTAssertEqual(route("https://hydrodrop.us/duo#HOKI9QWL").link?.code, "H0K19QW1")
        // Case is folded for the scheme and host only, as URLs do.
        XCTAssertEqual(route("HTTPS://HydroDrop.US/duo#H7K39QWX").link?.code, "H7K39QWX")
    }

    // MARK: - Everything else is not a Duo link

    func testEveryOtherShapeIsRefused() {
        let refused = [
            // Scheme
            "http://hydrodrop.us/duo#H7K39QWX",
            "hydrodrop://duo#H7K39QWX",
            "ftp://hydrodrop.us/duo#H7K39QWX",
            // Host
            "https://www.hydrodrop.us/duo#H7K39QWX",
            "https://evil.example/duo#H7K39QWX",
            "https://hydrodrop.us.evil.example/duo#H7K39QWX",
            "https://hydrodrop.com/duo#H7K39QWX",
            "https://user@evil.example/duo#H7K39QWX",
            // Path. (`/duo/` is not here: `URL.path` drops a trailing slash, so the foundation's
            // parser reads it as `/duo`. Stage K reported it; the parser and KV1 are not K's.)
            "https://hydrodrop.us/Duo#H7K39QWX",
            "https://hydrodrop.us/duo.html#H7K39QWX",
            "https://hydrodrop.us/duos#H7K39QWX",
            "https://hydrodrop.us/#H7K39QWX",
            "https://hydrodrop.us/tap#H7K39QWX",
            // A query string, even an empty one
            "https://hydrodrop.us/duo?code=H7K39QWX#H7K39QWX",
            "https://hydrodrop.us/duo?#H7K39QWX",
            // No fragment, an empty one, a malformed one
            "https://hydrodrop.us/duo",
            "https://hydrodrop.us/duo#",
            "https://hydrodrop.us/duo#.",
            "https://hydrodrop.us/duo#H7K39QWX.",
            "https://hydrodrop.us/duo#.\(k)",
            "https://hydrodrop.us/duo#H7K39QWX.\(k).",
            "https://hydrodrop.us/duo#H7K39QWX.\(k).\(k)",
            "https://hydrodrop.us/duo#H7K39QWX..\(k)",
            "https://hydrodrop.us/duo#H7K3%209QWX",
            // The code's length
            "https://hydrodrop.us/duo#H7K39QW",
            "https://hydrodrop.us/duo#H7K39QWXY",
            "https://hydrodrop.us/duo#H7K39QW.\(k)",
            // The secret's length and alphabet
            "https://hydrodrop.us/duo#H7K39QWX.\(k)A",
            "https://hydrodrop.us/duo#H7K39QWX.\(k.dropLast())",
            "https://hydrodrop.us/duo#H7K39QWX.ABCDEFGHJKMNPQRSTVWXYZ012U",
            "https://hydrodrop.us/duo#H7K39QWX.ABCDEFGHJKMNPQRSTVWXYZ012I",
            // Letters outside the code's alphabet
            "https://hydrodrop.us/duo#H7K39QWU",
        ]
        for address in refused {
            let routed = route(address)
            XCTAssertNil(routed.link, address)
            XCTAssertNil(routed.tag, address)
            XCTAssertFalse(routed.handled, address)
        }
    }

    func testASevenCharacterCodeAndATwentySevenCharacterSecretAreRefused() {
        XCTAssertEqual(k.count, 26)
        XCTAssertNil(route("https://hydrodrop.us/duo#H7K39QW").link)
        XCTAssertNil(route("https://hydrodrop.us/duo#H7K39QWX.\(k)Z").link)
        // ...where the same link with the right lengths is a Duo link, so the refusal is the length's.
        XCTAssertNotNil(route("https://hydrodrop.us/duo#H7K39QWX").link)
        XCTAssertNotNil(route("https://hydrodrop.us/duo#H7K39QWX.\(k)").link)
    }

    // MARK: - Bottle tags are unaffected

    func testABottleTagStillReachesTodayAndIsNotADuoLink() {
        let routed = route("https://hydrodrop.us/tap?b=\(tagID.uuidString)")
        XCTAssertTrue(routed.handled)
        XCTAssertEqual(routed.tag, tagID)
        XCTAssertNil(routed.link)

        let page = route("https://hydrodrop.us/tap.html?b=\(tagID.uuidString)")
        XCTAssertEqual(page.tag, tagID)
        XCTAssertNil(page.link)
    }

    func testABottleTagWithAFragmentIsStillOnlyABottleTag() {
        let routed = route("https://hydrodrop.us/tap?b=\(tagID.uuidString)#H7K39QWX")
        XCTAssertEqual(routed.tag, tagID)
        XCTAssertNil(routed.link)
    }

    func testADuoPathWithATagQueryIsNeither() {
        let routed = route("https://hydrodrop.us/duo?b=\(tagID.uuidString)#H7K39QWX")
        XCTAssertFalse(routed.handled)
        XCTAssertNil(routed.tag)
        XCTAssertNil(routed.link)
    }

    func testOneKindOfAddressNeverClearsTheOther() {
        // A tag tapped while an invite is waiting for the root (or the other way round) leaves the
        // first where it is: each is taken by its own screen.
        XCTAssertTrue(AppRouter.shared.handle(URL(string: "https://hydrodrop.us/duo#H7K39QWX")!))
        XCTAssertTrue(AppRouter.shared.handle(URL(string: "https://hydrodrop.us/tap?b=\(tagID.uuidString)")!))
        let link = AppRouter.shared.pendingDuoLink
        let tag = AppRouter.shared.pendingBottleTagID
        kReset()
        XCTAssertEqual(link, DuoParsedInvite(code: "H7K39QWX"))
        XCTAssertEqual(tag, tagID)
    }

    func testARefusedAddressLeavesAWaitingLinkAlone() {
        XCTAssertTrue(AppRouter.shared.handle(URL(string: "https://hydrodrop.us/duo#H7K39QWX.\(k)")!))
        XCTAssertFalse(AppRouter.shared.handle(URL(string: "https://evil.example/duo#ZZZZZZZZ")!))
        let link = AppRouter.shared.pendingDuoLink
        kReset()
        XCTAssertEqual(link, DuoParsedInvite(code: "H7K39QWX", k: k))
    }

    // MARK: - Taking a link (K4)

    func testALinkIsReceivedAndClosesSettings() async {
        let kit = DuoTestKit()
        defer { for key in kit.defaults.dictionaryRepresentation().keys { kit.defaults.removeObject(forKey: key) } }
        let link = DuoParsedInvite(code: "H7K39QWX", k: k)
        AppRouter.shared.pendingDuoLink = link
        let shown = RootTabView.duoTake(link, router: AppRouter.shared, store: kit.store, now: Date())
        let settings = AppRouter.shared.showingSettings
        let left = AppRouter.shared.pendingDuoLink
        kReset()
        XCTAssertNil(shown)
        XCTAssertNil(left)
        XCTAssertFalse(settings)
        XCTAssertEqual(kit.joining.calls, ["receive:H7K39QWX"])
    }

    func testARefusedPersonsLinkIsKeptNowhereButComesBackToShowTheRefusal() async {
        let kit = DuoTestKit()
        defer { for key in kit.defaults.dictionaryRepresentation().keys { kit.defaults.removeObject(forKey: key) } }
        kit.store.recordBirthYear(Calendar(identifier: .gregorian).component(.year, from: Date()) - 5, month: 1)
        XCTAssertEqual(kit.store.ageStatus, .refused)
        let now = Date()
        let shown = RootTabView.duoTake(DuoParsedInvite(code: "H7K39QWX", k: k), router: AppRouter.shared, store: kit.store, now: now)
        let settings = AppRouter.shared.showingSettings
        kReset()
        // Settings closes so the refusal can come up; nothing is received or kept, and the secret is
        // not held even in memory.
        XCTAssertEqual(shown, DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: now))
        XCTAssertFalse(settings)
        XCTAssertEqual(kit.joining.calls, [])
        XCTAssertNil(kit.store.pendingInvite)
    }
}

// MARK: - The app's own root (hosted)

@MainActor
fileprivate func kRootWindow() -> UIWindow? {
    // The app's own window: the key one (a test's window is only ever made visible, never key), or
    // the first if none is.
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    return windows.first { $0.isKeyWindow } ?? windows.first
}

@MainActor
fileprivate func kChain() -> [UIViewController] {
    var chain: [UIViewController] = []
    var presented = kRootWindow()?.rootViewController?.presentedViewController
    while let controller = presented {
        chain.append(controller)
        presented = controller.presentedViewController
    }
    return chain
}

@MainActor
fileprivate func kTitles(_ controller: UIViewController) -> Set<String> {
    var titles = Set<String>()
    func walk(_ node: UIViewController) {
        if let navigation = node as? UINavigationController {
            titles.formUnion(navigation.viewControllers.compactMap { $0.navigationItem.title })
            if let title = navigation.navigationBar.topItem?.title { titles.insert(title) }
        }
        if let title = node.navigationItem.title { titles.insert(title) }
        node.children.forEach(walk)
    }
    walk(controller)
    return titles
}

@MainActor
fileprivate func kShowing(_ title: String) -> Bool { kChain().contains { kTitles($0).contains(title) } }

@MainActor
fileprivate func kAlertUp() -> Bool { kChain().contains { $0 is UIAlertController } }

@MainActor
fileprivate func kDescribe() -> String {
    let router = AppRouter.shared
    let chain = kChain().map { "\(type(of: $0))\($0 is UIAlertController ? "" : "\(kTitles($0).sorted())")" }.joined(separator: " > ")
    let root = kRootWindow()?.rootViewController.map { String(describing: type(of: $0)).prefix(60) } ?? "no window"
    return "\(root) [\(chain)] settings=\(router.showingSettings)/\(router.settingsIsOnScreen) recap=\(router.showingWeeklyRecap) "
        + "duo=\(router.showingDuoScreen) invite=\(DuoStore.shared.pendingInvite?.code ?? "nil") notice=\(DuoStore.shared.notice != nil) "
        + "otherModals=\(router.otherModalCount) subscribed=\(StoreManager.shared.isSubscribed)"
}

/// Unknown-age routing must present the real birth-year gate, not the form's old title.
/// Looking inside the presented controller also proves a missing/bypassed gate cannot pass.
@MainActor
private func kShowingJoinGate() -> Bool {
    for controller in kChain() {
        var pending: [NSObject] = [controller.view]
        var seen = Set<ObjectIdentifier>()
        while let object = pending.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            var identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
            if identifier == nil {
                let selector = NSSelectorFromString("accessibilityIdentifier")
                if object.responds(to: selector) {
                    identifier = object.perform(selector)?.takeUnretainedValue() as? String
                }
            }
            if identifier == "duo.agegate.year" { return true }
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = object.accessibilityElements as? [NSObject] {
                pending.append(contentsOf: children)
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    pending.append(contentsOf: (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject })
                }
            }
        }
    }
    return false
}

private enum KRoutingAutomation {
    private typealias Getter = @convention(c) () -> UInt8
    private typealias Setter = @convention(c) (UInt8) -> Void
    nonisolated(unsafe) private static var previous: UInt8?
    private static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
    static func enable() -> Bool {
        guard let library, let get = dlsym(library, "_AXSAutomationEnabled"), let set = dlsym(library, "_AXSSetAutomationEnabled") else { return false }
        previous = unsafeBitCast(get, to: Getter.self)()
        unsafeBitCast(set, to: Setter.self)(1)
        return unsafeBitCast(get, to: Getter.self)() != 0
    }
    static func restore() {
        guard let previous, let library, let set = dlsym(library, "_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(set, to: Setter.self)(previous)
        self.previous = nil
    }
}
private let kRecapTitle = "Your week"
private let kSettingsTitle = "Settings"

/// The app's own `RootTabView`, the one in the window this test bundle runs in, driven through
/// `AppRouter.shared` and `DuoStore.shared`, with what UIKit actually has presented read back after
/// each step (ported from stage K's routing review). Only the live store's published values are set:
/// no birth year is ever recorded on it, so its join sheet never peeks and nothing is sent, and every
/// test skips when the live store already has an age answer. Each test ends by showing that nothing
/// is wedged: the gear still opens Settings and closing it leaves nothing on screen.
@MainActor
final class DuoRoutingRootTests: XCTestCase {
    private var router: AppRouter { .shared }
    private var duoStore: DuoStore { .shared }
    private let invite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: Date())

    private func kSettle(_ seconds: Double = 6, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func kClean() async throws {
        guard duoStore.ageStatus == .unknown else { throw XCTSkip("the live Duo store has an age answer, so its join sheet could peek") }
        router.pendingDuoLink = nil
        router.showingDuoScreen = false
        router.showingWeeklyRecap = false
        router.showingSettings = false
        router.duoEntrySheetIsOnScreen = false
        duoStore.pendingInvite = nil
        duoStore.notice = nil
        AppSettings.shared.hasCompletedOnboarding = true
        let clean = await kSettle(10) { kChain().isEmpty && !self.router.settingsIsOnScreen }
        XCTAssertTrue(clean, "could not clear the root: \(kDescribe())")
        // Whatever was leaving (the notice's wait for its alert) has finished.
        _ = await kSettle(2) { false }
    }

    override func setUp() async throws {
        try await super.setUp()
        // These cases include the subscriber-only weekly recap, which the root refuses a free
        // user. They used to need the host launched with -UITestForceSubscribed, which nothing
        // passed, so a plain run failed every one of them; they now take the subscription
        // themselves and give it back in tearDown. This does not bypass the Duo age or consent
        // gates. Never run them with -DuoPreview or -DuoClientVersion.
        await StoreManager.shared.forceSubscriptionForTests(true)
        XCTAssertTrue(StoreManager.shared.isSubscribed)
        XCTAssertTrue(KRoutingAutomation.enable(), "the real consent gate must be observable")
        try await kClean()
    }

    override func tearDown() async throws {
        try? await kClean()
        KRoutingAutomation.restore()
        await StoreManager.shared.forceSubscriptionForTests(false)
        try await super.tearDown()
    }

    /// Nothing is wedged: Settings opens from the gear and closes, leaving nothing on screen.
    private func kGearStillWorks(file: StaticString = #filePath, line: UInt = #line) async {
        router.showingSettings = true
        let opened = await kSettle { kShowing(kSettingsTitle) && self.router.settingsIsOnScreen }
        XCTAssertTrue(opened, "the gear opens nothing: \(kDescribe())", file: file, line: line)
        router.showingSettings = false
        let closed = await kSettle { kChain().isEmpty && !self.router.settingsIsOnScreen }
        XCTAssertTrue(closed, "Settings did not close cleanly: \(kDescribe())", file: file, line: line)
    }

    private func kOpenSettings() async {
        router.showingSettings = true
        let up = await kSettle { kShowing(kSettingsTitle) && self.router.settingsIsOnScreen }
        XCTAssertTrue(up, kDescribe())
    }

    private func kShowJoinSheet() async {
        duoStore.pendingInvite = invite
        let up = await kSettle { kShowingJoinGate() }
        XCTAssertTrue(up, kDescribe())
    }

    // MARK: - Links and the join sheet

    func testALinkWithSettingsOpenClosesSettingsThenShowsTheSheet() async {
        await kOpenSettings()
        XCTAssertTrue(router.handle(URL(string: "https://hydrodrop.us/duo#H7K39QWX")!))
        let shown = await kSettle(8) { kShowingJoinGate() && !self.router.settingsIsOnScreen }
        XCTAssertTrue(shown, kDescribe())
        XCTAssertNil(router.pendingDuoLink)
        XCTAssertEqual(duoStore.pendingInvite?.code, "H7K39QWX")
        duoStore.pendingInvite = nil
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testDismissingTheSheetDropsTheInvite() async {
        await kShowJoinSheet()
        kChain().first?.dismiss(animated: false)
        let gone = await kSettle { !kShowingJoinGate() }
        XCTAssertTrue(gone)
        _ = await kSettle(1) { false }
        XCTAssertNil(duoStore.pendingInvite, "the invite outlived its sheet")
        XCTAssertFalse(kShowingJoinGate(), "the sheet came back: \(kDescribe())")
        await kGearStillWorks()
    }

    func testAnInviteComesUpOnlyAfterTheIntro() async {
        AppSettings.shared.hasCompletedOnboarding = false
        _ = await kSettle { !kChain().isEmpty }
        duoStore.pendingInvite = invite
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kShowingJoinGate(), "join sheet over the intro: \(kDescribe())")
        AppSettings.shared.hasCompletedOnboarding = true
        let shown = await kSettle(8) { kShowingJoinGate() }
        XCTAssertTrue(shown, kDescribe())
    }

    func testAnInviteWaitsForTheEntrySheet() async {
        router.duoEntrySheetIsOnScreen = true
        duoStore.pendingInvite = invite
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kShowingJoinGate(), kDescribe())
        router.duoEntrySheetIsOnScreen = false
        let shown = await kSettle { kShowingJoinGate() }
        XCTAssertTrue(shown, kDescribe())
    }

    /// Today and History keep a modal counted until its onDismiss, rather than until its
    /// binding goes false. Drive those real router hooks here while observing the app's root:
    /// a link must survive both sheets leaving instead of being consumed by a dropped sheet.
    func testAnInviteWaitsUntilEveryTabModalHasFinishedLeaving() async {
        var heldModals = 2
        router.modalDidAppear()
        router.modalDidAppear()
        defer { for _ in 0..<heldModals { router.modalDidDismiss() } }
        XCTAssertTrue(router.handle(URL(string: "https://hydrodrop.us/duo#H7K39QWX")!))
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kShowingJoinGate(), kDescribe())
        XCTAssertEqual(duoStore.pendingInvite?.code, "H7K39QWX")

        router.modalDidDismiss()
        heldModals -= 1
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kShowingJoinGate(), "the last tab sheet is still leaving: \(kDescribe())")
        router.modalDidDismiss()
        heldModals -= 1
        let shown = await kSettle(8) { kShowingJoinGate() }
        XCTAssertTrue(shown, "the waiting invite never appeared: \(kDescribe())")
        duoStore.pendingInvite = nil
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testARecapAskedForUnderTheJoinSheetWaitsForIt() async {
        await kShowJoinSheet()
        let sheet = kChain().first
        router.showingWeeklyRecap = true
        _ = await kSettle(1.5) { false }
        XCTAssertTrue(kChain().first === sheet && kShowingJoinGate(), "the recap replaced the join sheet: \(kDescribe())")
        duoStore.pendingInvite = nil
        let recap = await kSettle(8) { kShowing(kRecapTitle) }
        XCTAssertTrue(recap, kDescribe())
        router.showingWeeklyRecap = false
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    // MARK: - A tapped Duo notification

    func testADuoTapWaitsForATabModalThenOpensSettings() async {
        var modalHeld = true
        router.modalDidAppear()
        defer { if modalHeld { router.modalDidDismiss() } }
        router.showingDuoScreen = true
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(router.showingSettings, "Settings was requested beneath a tab sheet")
        XCTAssertFalse(router.settingsIsOnScreen, kDescribe())

        router.modalDidDismiss()
        modalHeld = false
        let opened = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(opened, "the waiting notification never opened Settings: \(kDescribe())")
        router.showingSettings = false
        _ = await kSettle { kChain().isEmpty && !self.router.settingsIsOnScreen }
        await kGearStillWorks()
    }

    func testADuoTapWaitsForTheJoinSheetThenOpensSettings() async {
        await kShowJoinSheet()
        router.showingDuoScreen = true
        _ = await kSettle(1.5) { false }
        XCTAssertTrue(kShowingJoinGate(), "the join sheet was taken down: \(kDescribe())")
        XCTAssertFalse(router.showingSettings)
        duoStore.pendingInvite = nil
        let settings = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(settings, kDescribe())
        router.showingSettings = false
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testADuoTapRightAfterALinkWaitsForTheSheetTheLinkBrings() async {
        XCTAssertTrue(router.handle(URL(string: "https://hydrodrop.us/duo#H7K39QWX")!))
        router.showingDuoScreen = true
        let join = await kSettle(8) { kShowingJoinGate() }
        XCTAssertTrue(join, kDescribe())
        _ = await kSettle(1) { false }
        XCTAssertFalse(router.showingSettings, "Settings was asked for over the join sheet: \(kDescribe())")
        duoStore.pendingInvite = nil
        let settings = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(settings, kDescribe())
        router.showingSettings = false
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testADuoTapClosesTheRecapThenOpensSettings() async {
        router.showingWeeklyRecap = true
        let recap = await kSettle { kShowing(kRecapTitle) }
        XCTAssertTrue(recap, kDescribe())
        router.showingDuoScreen = true
        // Settings is asked for only once the recap has gone, never while it is still on its way out.
        var askedOverTheRecap = false
        let settings = await kSettle(8) {
            if self.router.showingSettings && kShowing(kRecapTitle) { askedOverTheRecap = true }
            return self.router.settingsIsOnScreen && kShowing(kSettingsTitle) && !kShowing(kRecapTitle)
        }
        XCTAssertTrue(settings, kDescribe())
        XCTAssertFalse(askedOverTheRecap, "Settings was asked for while the recap was still on screen")
        router.showingSettings = false
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testARecapAndADuoTapInOneTurnOpenSettingsAlone() async {
        // The recap is asked for and closed before it ever comes up, so it has no onDismiss to wait
        // for: Settings opens straight away instead, and the recap never shows.
        var recapShown = false
        router.showingWeeklyRecap = true
        router.showingDuoScreen = true
        let settings = await kSettle(8) {
            if kShowing(kRecapTitle) { recapShown = true }
            return self.router.settingsIsOnScreen && kShowing(kSettingsTitle)
        }
        XCTAssertTrue(settings, kDescribe())
        XCTAssertFalse(recapShown, "the recap came up for a tap that wanted the Duo screen")
        XCTAssertFalse(router.showingWeeklyRecap)
        router.showingSettings = false
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testADuoTapWhileSettingsLeavesOpensItAgain() async {
        await kOpenSettings()
        router.showingSettings = false
        router.showingDuoScreen = true
        _ = await kSettle(8) { !self.router.settingsIsOnScreen }
        let reopened = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(reopened, kDescribe())
        router.showingSettings = false
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    /// Settings asked to close while its own notice alert is entering. Closing both together
    /// crashed UIKit on iOS 27, so Settings waits until no alert is up
    /// (`RootTabView.duoAnAlertIsUp`), and the notice then shows at the root. This does not prove
    /// the guard: with it switched off, the iOS 27.0 simulator still let the alert leave first and
    /// did not crash (tried 2026-11-12), so the guard itself needs the device check in its comment.
    func testClosingSettingsWhileItsNoticeEntersWaitsForTheAlert() async {
        await kOpenSettings()
        duoStore.notice = "probe notice"
        let entering = await kSettle(8) {
            guard let alert = kChain().compactMap({ $0 as? UIAlertController }).last else { return false }
            return alert.isBeingPresented || alert.transitionCoordinator != nil
        }
        XCTAssertTrue(entering, "the close must land during the alert's entrance: \(kDescribe())")
        guard entering else { return }
        router.showingSettings = false
        var alertLeftFirst = false
        let closed = await kSettle(8) {
            if kShowing(kSettingsTitle), !kAlertUp() { alertLeftFirst = true }
            return !self.router.settingsIsOnScreen && !kShowing(kSettingsTitle)
        }
        XCTAssertTrue(closed, kDescribe())
        XCTAssertTrue(alertLeftFirst, "Settings closed with its alert still on it: \(kDescribe())")
        let atRoot = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(atRoot, "the notice did not come back at the root: \(kDescribe())")
        duoStore.notice = nil
        let cleared = await kSettle(8) { kChain().isEmpty }
        XCTAssertTrue(cleared, kDescribe())
        await kGearStillWorks()
    }

    func testSettingsOpenedForATapStaysClosedOnceClosedAndTheFlagGoes() async {
        router.showingDuoScreen = true
        let opened = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(opened, kDescribe())
        router.showingSettings = false
        let closed = await kSettle { kChain().isEmpty && !self.router.settingsIsOnScreen }
        XCTAssertTrue(closed, kDescribe())
        // Stage H takes the flag while Settings is up; dismissing Settings must not replay it.
        XCTAssertFalse(router.showingDuoScreen)
        _ = await kSettle(2) { false }
        XCTAssertTrue(kChain().isEmpty, "Settings came back by itself: \(kDescribe())")
        await kGearStillWorks()
    }

    func testATapWithSettingsUpPushesDuoOnceAndConsumesTheFlag() async {
        await kOpenSettings()
        let settings = kChain().first
        router.showingDuoScreen = true
        let pushed = await kSettle { kShowing("Duo Streaks") && !self.router.showingDuoScreen }
        XCTAssertTrue(kChain().first === settings, "Settings was re-presented: \(kDescribe())")
        XCTAssertTrue(pushed, "the existing Settings navigation stack pushes Duo")
        XCTAssertFalse(router.showingDuoScreen, "Stage H consumes the request once")
        router.showingSettings = false
        let closed = await kSettle { kChain().isEmpty && !self.router.settingsIsOnScreen }
        XCTAssertTrue(closed, kDescribe())
        XCTAssertFalse(router.showingDuoScreen, "a consumed flag must not replay on the next visit")
        await kGearStillWorks()
    }

    func testGoingToTheBackgroundDropsAWaitingTap() async {
        await kShowJoinSheet()
        router.showingDuoScreen = true
        _ = await kSettle(1) { false }
        // The simulator remains foreground while this test broadcasts background. Pair that
        // synthetic event before exercising foreground UI, including if this test exits early.
        var needsForeground = true
        func restoreForeground() {
            guard needsForeground else { return }
            needsForeground = false
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        }
        defer { restoreForeground() }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        _ = await kSettle(0.5) { false }
        duoStore.pendingInvite = nil
        _ = await kSettle(3) { false }
        XCTAssertFalse(router.showingSettings, "Settings opened for a tap the person had left behind: \(kDescribe())")
        XCTAssertFalse(router.showingDuoScreen)
        restoreForeground()
        await kGearStillWorks()
    }

    // MARK: - The notice alert and the sheets, one at a time (K1)

    func testANoticeWaitsForATabModalThenShows() async {
        var modalHeld = true
        router.modalDidAppear()
        defer { if modalHeld { router.modalDidDismiss() } }
        duoStore.notice = "probe notice behind a tab sheet"
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kAlertUp(), "notice appeared beneath a tab sheet: \(kDescribe())")
        XCTAssertEqual(duoStore.notice, "probe notice behind a tab sheet")

        router.modalDidDismiss()
        modalHeld = false
        let shown = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(shown, "the waiting notice never appeared: \(kDescribe())")
        duoStore.notice = nil
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testANoticeWaitsForTheJoinSheetThenShows() async {
        await kShowJoinSheet()
        duoStore.notice = "probe notice"
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kAlertUp(), "alert over the join sheet: \(kDescribe())")
        duoStore.pendingInvite = nil
        let alert = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(alert, kDescribe())
        duoStore.notice = nil
        _ = await kSettle { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testNotNowWithATapAndANoticeWaitingWedgesNothing() async {
        await kShowJoinSheet()
        router.showingDuoScreen = true
        duoStore.notice = "probe notice"
        _ = await kSettle(1.5) { false }
        duoStore.pendingInvite = nil
        let settings = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(settings, kDescribe())
        XCTAssertFalse(kAlertUp())
        router.showingSettings = false
        let alert = await kSettle(8) { kAlertUp() && !self.router.settingsIsOnScreen }
        XCTAssertTrue(alert, "the notice never came once Settings had gone: \(kDescribe())")
        // OK, the way a person taps it.
        kChain().last?.dismiss(animated: true)
        let cleared = await kSettle(8) { kChain().isEmpty && self.duoStore.notice == nil }
        XCTAssertTrue(cleared, kDescribe())
        await kGearStillWorks()
    }

    func testANoticeClearedWhileItsAlertEntersFinishesDismissing() async {
        duoStore.notice = "failure removed by a wipe"
        let entering = await kSettle(8) {
            guard let alert = kChain().compactMap({ $0 as? UIAlertController }).last else { return false }
            return alert.isBeingPresented || alert.transitionCoordinator != nil
        }
        XCTAssertTrue(entering, "the regression must remove the notice during its actual entrance: \(kDescribe())")
        guard entering else { return }
        // A wipe can clear the store at any time, including before UIKit enables the alert.
        duoStore.notice = nil
        let closed = await kSettle(8) { kChain().isEmpty }
        XCTAssertTrue(closed, "a notice removed during entrance must finish leaving: \(kDescribe())")
        XCTAssertNil(duoStore.notice)
        await kGearStillWorks()
    }

    func testANewerNoticeSurvivesAnOlderAlertsDismissal() async {
        duoStore.notice = "first failure"
        let shown = await kSettle(8) {
            guard let alert = kChain().compactMap({ $0 as? UIAlertController }).last else { return false }
            return !alert.isBeingPresented && !alert.isBeingDismissed && alert.transitionCoordinator == nil
        }
        XCTAssertTrue(shown, kDescribe())
        guard shown else { return }
        guard let oldAlert = kChain().compactMap({ $0 as? UIAlertController }).last else {
            XCTFail("the first notice was not presented")
            return
        }
        // Queue UIKit's dismissal callback, then replace the notice before yielding. The old
        // binding must only acknowledge the failure it displayed, not this new failure.
        oldAlert.dismiss(animated: true)
        duoStore.notice = "second failure"
        let replaced = await kSettle(8) {
            !kChain().contains(where: { $0 === oldAlert })
                && kChain().compactMap({ $0 as? UIAlertController }).contains {
                    $0.message == "second failure" && !$0.isBeingPresented && !$0.isBeingDismissed
                        && $0.transitionCoordinator == nil
                }
        }
        XCTAssertTrue(replaced, kDescribe())
        XCTAssertEqual(duoStore.notice, "second failure")
        guard replaced else { return }
        duoStore.notice = nil
        let closed = await kSettle(8) { kChain().isEmpty }
        XCTAssertTrue(closed, kDescribe())
        await kGearStillWorks()
    }

    func testANoticeAndSettingsInOneTurnWedgeNothing() async {
        duoStore.notice = "probe notice"
        router.showingSettings = true
        let settings = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(settings, kDescribe())
        XCTAssertFalse(kAlertUp())
        router.showingSettings = false
        let alert = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(alert, kDescribe())
        duoStore.notice = nil
        let cleared = await kSettle(8) { kChain().isEmpty }
        XCTAssertTrue(cleared, kDescribe())
        await kGearStillWorks()
    }

    func testARecapClosedByATapWithANoticeHeldWedgesNothing() async {
        router.showingWeeklyRecap = true
        _ = await kSettle { kShowing(kRecapTitle) }
        duoStore.notice = "probe notice"
        _ = await kSettle(1.5) { false }
        XCTAssertFalse(kAlertUp(), "alert over the recap: \(kDescribe())")
        router.showingDuoScreen = true
        let settings = await kSettle(8) { self.router.settingsIsOnScreen && kShowing(kSettingsTitle) }
        XCTAssertTrue(settings, kDescribe())
        router.showingSettings = false
        let alert = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(alert, kDescribe())
        duoStore.notice = nil
        _ = await kSettle(8) { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testALinkReleasesTheJoinSheetAndTheAlertOneAtATime() async {
        await kOpenSettings()
        duoStore.notice = "probe notice"
        _ = await kSettle(1) { false }
        XCTAssertTrue(router.handle(URL(string: "https://hydrodrop.us/duo#H7K39QWX")!))
        let join = await kSettle(8) { kShowingJoinGate() }
        XCTAssertTrue(join, kDescribe())
        XCTAssertFalse(kAlertUp())
        duoStore.pendingInvite = nil
        let alert = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(alert, kDescribe())
        duoStore.notice = nil
        _ = await kSettle(8) { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testARecapAndTheAlertAreReleasedOneAtATime() async {
        await kOpenSettings()
        duoStore.notice = "probe notice"
        _ = await kSettle(1) { false }
        router.showingWeeklyRecap = true
        let recap = await kSettle(8) { kShowing(kRecapTitle) }
        XCTAssertTrue(recap, kDescribe())
        XCTAssertFalse(kAlertUp())
        router.showingWeeklyRecap = false
        let alert = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(alert, kDescribe())
        duoStore.notice = nil
        _ = await kSettle(8) { kChain().isEmpty }
        await kGearStillWorks()
    }

    func testASheetWaitingBehindTheAlertComesOnceItHasGone() async {
        duoStore.notice = "probe notice"
        let alert = await kSettle(8) { kAlertUp() }
        XCTAssertTrue(alert, kDescribe())
        duoStore.pendingInvite = invite
        _ = await kSettle(1) { false }
        XCTAssertFalse(kShowingJoinGate(), "the join sheet was asked for under the alert: \(kDescribe())")
        duoStore.notice = nil
        // The sheet comes once the alert has left the screen, never beside it.
        var besideTheAlert = false
        let join = await kSettle(8) {
            if kShowingJoinGate() && kAlertUp() { besideTheAlert = true }
            return kShowingJoinGate() && !kAlertUp()
        }
        XCTAssertTrue(join, kDescribe())
        XCTAssertFalse(besideTheAlert, "the join sheet was shown with the alert still up")
        duoStore.pendingInvite = nil
        _ = await kSettle(8) { kChain().isEmpty }
        await kGearStillWorks()
    }
}
#endif
