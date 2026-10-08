#if DUO_V2
import CoreImage
import SwiftUI
import UIKit
import XCTest
@testable import HydroDrop

// MARK: - Helpers (stage J)

/// A sheet in a real window of the test host, so its `.task`, its `TimelineView`, its presentation
/// and its accessibility tree behave as they do on a phone, which `ImageRenderer` cannot show.
@MainActor
fileprivate final class JHosted {
    let window: UIWindow

    init<Content: View>(_ view: Content, style: UIUserInterfaceStyle = .light) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "the test host has a scene")
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    /// The controllers presented over the window's root, bottom first.
    func presented() -> [UIViewController] {
        var chain: [UIViewController] = []
        var top = window.rootViewController
        while let next = top?.presentedViewController {
            chain.append(next)
            top = next
        }
        return chain
    }

    /// Covers the window's root with a full-screen controller and takes it away again: the root's
    /// SwiftUI content disappears and appears again with its state kept, which is how a `.task`
    /// comes to be cancelled and run a second time.
    func coverFullScreen() -> UIViewController {
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(cover, animated: false)
        return cover
    }

    /// The system share sheet, if one is up.
    func shareSheet() -> UIActivityViewController? {
        presented().compactMap { $0 as? UIActivityViewController }.first
    }

    /// The window as drawn now, at the screen's scale.
    func snapshot() -> UIImage {
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Every element a screen reader could reach, from the window down.
    func elements() -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [window]
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

    func element(_ identifier: String) -> NSObject? {
        elements().first { jIdentifier(of: $0) == identifier }
    }

    func hasElement(_ identifier: String) -> Bool { element(identifier) != nil }

    /// Every label a screen reader would speak.
    func labels() -> [String] { elements().compactMap(\.accessibilityLabel) }

    /// A screen reader's double tap on the element with `identifier`.
    @discardableResult
    func activate(_ identifier: String) throws -> Bool {
        try XCTUnwrap(element(identifier), "no element \(identifier)").accessibilityActivate()
    }

    func close() {
        window.rootViewController?.presentedViewController?.presentedViewController?.dismiss(animated: false)
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// SwiftUI builds its accessibility tree only while something is listening for it: VoiceOver, or
/// the automation XCUITest turns on. A unit test has neither, and an empty tree would make every
/// "this sheet shows that" assertion pass or fail for the wrong reason. So these tests turn the
/// simulator's accessibility automation on through libAccessibility, the switch XCUITest uses, and
/// put it back as it was afterwards. It is test code only and never reaches the app; if a later
/// iOS drops the switch, `enable()` says so and the tests fail loudly rather than pass on nothing.
fileprivate enum JAutomation {
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

fileprivate func jIdentifier(of element: NSObject) -> String? {
    if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
    let selector = NSSelectorFromString("accessibilityIdentifier")
    guard element.responds(to: selector) else { return nil }
    return element.perform(selector)?.takeUnretainedValue() as? String
}

/// Lets the main run loop turn (SwiftUI's updates, a `.task`, a presentation) until `condition`
/// holds or the time is up, and says whether it held.
@MainActor
fileprivate func jWait(_ seconds: Double = 10, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return condition()
}

/// `jWait` as an assertion: fails the test, at the caller's line, if `condition` never holds.
@MainActor
fileprivate func jExpect(_ message: @autoclosure () -> String = "", seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line,
                         until condition: () -> Bool) async {
    let held = await jWait(seconds, until: condition)
    XCTAssertTrue(held, message(), file: file, line: line)
}

@MainActor
fileprivate func jSettle(_ seconds: Double = 0.6) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// What a QR detector reads in a picture of the screen.
fileprivate func jQRMessages(in image: UIImage) -> [String] {
    guard let cgImage = image.cgImage,
          let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
    return detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
}

/// Presents a sheet the way the Duo screen will, so a sheet that closes itself can be seen to.
@MainActor
fileprivate final class JPresentation: ObservableObject {
    @Published var isPresented = true
}

fileprivate struct JPresenter<Sheet: View>: View {
    @ObservedObject var presentation: JPresentation
    let sheet: () -> Sheet
    var body: some View {
        Color.clear.sheet(isPresented: $presentation.isPresented, content: sheet)
    }
}


/// The app's state as a test says it is, for `DuoAppLifecycle`: in front or not, captured or not,
/// and a notification centre of the test's own.
@MainActor
fileprivate final class JAppState {
    var inFront = true
    var captured = false
    let center = NotificationCenter()

    var lifecycle: DuoAppLifecycle {
        // Held strongly: the view may ask after the test has let go of this object, and nothing it
        // holds points back at the view.
        DuoAppLifecycle(center: center, isInFront: { self.inFront }, isCaptured: { self.captured })
    }

    func post(_ name: Notification.Name) { center.post(name: name, object: nil) }
}


/// A joining double whose first reconnect code waits until its task is cancelled and then gives
/// nothing, and whose later ones come back at once: how a sheet that went away mid-request looks
/// from the inside. The shared `FakeJoining` answers at once and cannot show it.
@MainActor
fileprivate final class JSlowReconnect: DuoJoining {
    private(set) var reconnectAsks = 0
    var code: DuoInvite?

    func createReconnectCode(for duo: DuoState) async -> DuoInvite? {
        reconnectAsks += 1
        if reconnectAsks == 1 {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        return code
    }

    func createDuo(named: String?, skin: String) async -> DuoState? { nil }
    func peek(code: String) async -> DuoPeek? { nil }
    func receive(_ invite: DuoParsedInvite, now: Date) {}
    func discardPendingInvite() {}
    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState? { nil }
    func newInvite(for duo: DuoState) async -> DuoInvite? { nil }
    func createLinkCode() async -> DuoInvite? { nil }
    func reconnect(code: String) async -> Bool { false }
    func changeMyName(_ name: String?) async {}
    func acceptTerms() async -> Bool { true }
}

/// What the system share sheet was given. `UIActivityViewController` keeps its items to itself;
/// this reads them the way the debugger does, in test code only, and fails loudly if a later iOS
/// stops answering, rather than passing on nothing.
fileprivate func jSharedItems(_ sheet: UIActivityViewController) -> [Any]? {
    let selector = NSSelectorFromString("activityItems")
    guard sheet.responds(to: selector) else { return nil }
    return sheet.value(forKey: "activityItems") as? [Any]
}

// MARK: - The tests

/// Stage J: the invite sheet and the reconnect code sheet, in every state, over a real store.
/// `DuoTestKit` gives a store over fakes; where the joining service's own words, its journal or
/// its stored code matter, the real `DuoJoiningService` runs over the fake transport, and where a
/// wipe matters, the real `DuoExitService`. Each test that came out of the stage's review names the
/// finding or mutant it was written to catch.
@MainActor
final class DuoInviteViewTests: XCTestCase {
    private let k = "ABCDEFGHJKMNPQRSTVWXYZ0123"
    private var hosted: [JHosted] = []
    private var pasteboards: [UIPasteboard.Name] = []

    nonisolated override class func setUp() {
        super.setUp()
        JAutomation.enable()
    }

    nonisolated override class func tearDown() {
        JAutomation.restore()
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(JAutomation.enable(), "accessibility automation is on, so SwiftUI builds the tree these tests read")
    }

    override func tearDown() async throws {
        hosted.forEach { $0.close() }
        hosted = []
        pasteboards.forEach { UIPasteboard.remove(withName: $0) }
        pasteboards = []
        try await super.tearDown()
    }

    private func host<Content: View>(_ view: Content, style: UIUserInterfaceStyle = .light) throws -> JHosted {
        let made = try JHosted(view, style: style)
        hosted.append(made)
        return made
    }

    /// A pasteboard of the test's own, never the general one.
    private func pasteboard() throws -> UIPasteboard {
        let name = UIPasteboard.Name("duo.j.test.\(UUID().uuidString)")
        pasteboards.append(name)
        return try XCTUnwrap(UIPasteboard(name: name, create: true))
    }

    /// The sheets read the real clock through their timeline, so codes expire relative to it.
    private func invite(_ code: String = "H7K39QWX", expiringIn interval: TimeInterval = 40 * 3600) -> DuoInvite {
        DuoInvite(code: code, display: DuoInviteCode.display(code), expiresAt: Date().addingTimeInterval(interval))
    }

    private func pendingDuo(_ invite: DuoInvite?) -> DuoState {
        var duo = DuoFixtures.duo(joined: false)
        duo.invite = invite
        duo.openInviteExpiresAt = invite?.expiresAt
        return duo
    }

    /// A live duo whose partner has been silent long enough for the card to offer a reconnect
    /// (the kit's clock says 2026-09-21).
    private func silentDuo() -> DuoState {
        var duo = DuoFixtures.duo()
        duo.partnerLastWriteDay = "2026-09-10"
        return duo
    }

    /// A kit whose joining is the real service, with an identity that answers ready.
    private func realKit() -> DuoTestKit {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.identity.launch = .ready
        kit.dependencies.cache.ageStatus = .allowed
        kit.dependencies.cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
        kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
        return kit
    }

    private func inviteKeys(_ kit: DuoTestKit) -> [DuoIdempotencyKey] {
        kit.transport.calls.compactMap { call in
            if case .createInvite(_, _, let key) = call { return key }
            return nil
        }
    }

    private func render<Content: View>(_ view: Content, _ name: String) {
        let renderer = ImageRenderer(content: AnyView(view.frame(width: 390, height: 844)))
        renderer.proposedSize = ProposedViewSize(width: 390, height: 844)
        XCTAssertNotNil(renderer.uiImage, "\(name) draws")
    }

    // MARK: - Every state draws

    func testEveryStateOfBothSheetsDraws() {
        func inviteSheet(_ duo: DuoState?, configure: (DuoStore) -> Void = { _ in }) -> some View {
            let kit = DuoTestKit()
            if let duo { kit.store.upsert(duo) }
            configure(kit.store)
            return DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID)
        }
        render(inviteSheet(pendingDuo(invite())), "an open code")
        render(inviteSheet(pendingDuo(invite(expiringIn: -60))), "an expired code")
        render(inviteSheet(pendingDuo(nil)), "no code")
        var reinstalled = pendingDuo(nil)
        reinstalled.openInviteExpiresAt = Date().addingTimeInterval(3600)
        render(inviteSheet(reinstalled), "a reinstalled owner")
        render(inviteSheet(pendingDuo(nil)) { $0.isWorking = true }, "making a new code")
        render(inviteSheet(pendingDuo(nil)) { $0.availability = .disconnected; $0.sheetError = DuoUserMessage.generic }, "a refusal")
        render(inviteSheet(DuoFixtures.duo()), "a duo the partner joined")
        render(inviteSheet(nil), "a duo that is gone")

        let kit = DuoTestKit()
        kit.store.upsert(silentDuo())
        render(DuoReconnectCodeSheet(duoStore: kit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()), "a reconnect code on its way")
        render(DuoCodeDisplay(invite: invite("R3C0NN3C"), link: DuoLink.url(code: "R3C0NN3C", k: nil), now: Date(), kind: .reconnect), "a reconnect code")
        render(DuoCodeDisplay(invite: invite(), link: nil, now: Date()), "a code with no link")
    }

    /// The code, the QR and the error states that only a real window shows (a task has to run).
    func testEveryHostedStateDrawsWhatItShould() async throws {
        // An open code: the code, its countdown, the QR of the link with its secret, Copy, Share.
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let open = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { open.hasElement("duo.invite.qr") }
        for id in ["duo.invite.code", "duo.invite.qr", "duo.invite.copy", "duo.invite.share", "duo.invite.newcode", "duo.invite.done"] {
            XCTAssertTrue(open.hasElement(id), "the open code shows \(id)")
        }
        XCTAssertEqual(open.element("duo.invite.code")?.accessibilityLabel, "H7K3-9QWX")
        XCTAssertTrue(open.labels().contains("expires in 40 h"), "the countdown, rounded up")
        XCTAssertTrue(open.labels().contains(DuoCopy.inviteSheetWarning))
        XCTAssertTrue(open.labels().contains("Invite your partner"))
        XCTAssertEqual(jQRMessages(in: open.snapshot()), ["https://hydrodrop.us/duo#H7K39QWX.\(k)"], "the QR is the link, secret and all")
        open.close()

        // An expired code: no code, no QR, the plain line and the button.
        let expiredKit = DuoTestKit()
        expiredKit.store.upsert(pendingDuo(invite(expiringIn: -60)))
        let expired = try host(DuoInviteSheet(duoStore: expiredKit.store, duoID: DuoFixtures.duoID))
        await jExpect { expired.hasElement("duo.invite.newcode") }
        XCTAssertFalse(expired.hasElement("duo.invite.code"))
        XCTAssertFalse(expired.hasElement("duo.invite.qr"))
        XCTAssertFalse(expired.hasElement("duo.invite.copy"))
        XCTAssertFalse(expired.hasElement("duo.invite.share"))
        XCTAssertTrue(expired.labels().contains("This invite is no longer open."))
        XCTAssertEqual(jQRMessages(in: expired.snapshot()), [])
        expired.close()

        // A reconnect code: the warning, the code, the line about a new code, and a QR of the link
        // with no secret in it, though this duo has one (secrets M3, mutant M17).
        let reconnectKit = DuoTestKit()
        reconnectKit.store.upsert(silentDuo())
        try reconnectKit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        reconnectKit.joining.reconnectCodeResult = invite("R3C0NN3C", expiringIn: 48 * 3600)
        let reconnect = try host(DuoReconnectCodeSheet(duoStore: reconnectKit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()))
        await jExpect { reconnect.hasElement("duo.invite.qr") }
        XCTAssertEqual(reconnect.element("duo.invite.code")?.accessibilityLabel, "R3C0-NN3C")
        XCTAssertTrue(reconnect.labels().contains("expires in 48 h"))
        XCTAssertTrue(reconnect.labels().contains("Reconnect your partner"))
        XCTAssertTrue(reconnect.labels().contains("Send this only to your partner's new phone. Anyone who uses it before it expires takes over your partner's place in all their duos, and their old phone stops working."),
                      "the warning says what a stolen code does (secrets M2)")
        XCTAssertTrue(reconnect.labels().contains("Making a new code stops the last one from working."))
        XCTAssertTrue(reconnect.hasElement("duo.invite.share"))
        XCTAssertFalse(reconnect.hasElement("duo.invite.newcode"), "a reconnect code is made from the card, not here")
        XCTAssertEqual(jQRMessages(in: reconnect.snapshot()), ["https://hydrodrop.us/duo#R3C0NN3C"])
        reconnect.close()

        // A reconnect code the store would not make: the general line, never an empty sheet.
        let refusedKit = DuoTestKit()
        refusedKit.store.upsert(silentDuo())
        let refused = try host(DuoReconnectCodeSheet(duoStore: refusedKit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()))
        await jExpect { refused.labels().contains(DuoUserMessage.generic) }
        XCTAssertFalse(refused.hasElement("duo.invite.code"))
        XCTAssertEqual(jQRMessages(in: refused.snapshot()), [])
    }

    /// Probe P11: in dark mode the QR, drawn black on its own white square, still reads.
    func testTheQRReadsInDarkMode() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID), style: .dark)
        await jExpect { sheet.hasElement("duo.invite.qr") }
        await jExpect { jQRMessages(in: sheet.snapshot()) == ["https://hydrodrop.us/duo#H7K39QWX.\(self.k)"] }
    }

    /// Probe P10: at the largest text size every control is still there and inside the width.
    func testEveryControlStaysOnScreenAtTheLargestTextSize() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID).environment(\.dynamicTypeSize, .accessibility5))
        await jExpect { sheet.hasElement("duo.invite.copy") }
        for id in ["duo.invite.code", "duo.invite.qr", "duo.invite.copy", "duo.invite.share", "duo.invite.newcode", "duo.invite.done"] {
            let frame = try XCTUnwrap(sheet.element(id), id).accessibilityFrame
            XCTAssertLessThanOrEqual(frame.maxX, 390.5, "\(id) inside the width")
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, id)
        }
    }

    // MARK: - What each sheet asks the store, and when

    func testOpeningTheInviteSheetAsksForNothingAndATapAsksForOneNewCode() async throws {
        for state in ["open", "none"] {
            let kit = DuoTestKit()
            kit.store.upsert(pendingDuo(state == "open" ? invite() : nil))
            let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
            await jExpect(state) { sheet.hasElement("duo.invite.newcode") }
            await jSettle()
            XCTAssertEqual(kit.joining.calls, [], "opening the sheet asks for no code (\(state))")
            XCTAssertEqual(kit.transport.calls, [], "and sends nothing (\(state))")

            kit.joining.inviteResult = invite("N3WC0DE2")
            XCTAssertTrue(try sheet.activate("duo.invite.newcode"), state)
            await jExpect("one tap, one new code (\(state)): \(kit.joining.calls)") { kit.joining.calls == ["newInvite"] }
            await jSettle()
            XCTAssertEqual(kit.joining.calls, ["newInvite"], "and only one (\(state))")
            sheet.close()
        }
    }

    /// Probe P1, mutant S01: two taps in the same turn, before the button has redrawn as disabled.
    func testTwoTapsInOneTurnAskForOneNewCode() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(nil))
        kit.joining.inviteResult = invite("N3WC0DE2")
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.newcode") }
        let button = try XCTUnwrap(sheet.element("duo.invite.newcode"))
        _ = button.accessibilityActivate()
        _ = button.accessibilityActivate()
        await jSettle()
        XCTAssertEqual(kit.joining.calls, ["newInvite"])
    }

    func testMakeANewCodeIsOffWhileWritesAreAndSaysWhy() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(nil))
        kit.store.availability = .upgradeRequired
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.newcode") }
        let button = try XCTUnwrap(sheet.element("duo.invite.newcode"))
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled), "the store would refuse it without a word")
        XCTAssertTrue(sheet.labels().contains("Update HydroDrop to keep using Duo Streaks."))
        _ = try? sheet.activate("duo.invite.newcode")
        await jSettle()
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testANewCodeFromTheRealServiceShowsAtOnceWithItsLink() async throws {
        let kit = realKit()
        kit.store.upsert(pendingDuo(invite(expiringIn: -60)))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let expiry = Date().addingTimeInterval(48 * 3600)
        kit.transport.onCreateInvite = { _, _, _ in DuoWireInvite(code: "N3WC0DE2", display: "N3WC-0DE2", expiresAt: expiry) }
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.newcode") }
        XCTAssertEqual(kit.transport.calls, [], "nothing is sent by opening it")

        try sheet.activate("duo.invite.newcode")
        await jExpect("the new code is drawn") { sheet.element("duo.invite.code")?.accessibilityLabel == "N3WC-0DE2" }
        XCTAssertEqual(kit.transport.calls.count, 1)
        await jExpect("the QR follows the new code and keeps the duo's secret") {
            jQRMessages(in: sheet.snapshot()) == ["https://hydrodrop.us/duo#N3WC0DE2.\(self.k)"]
        }
        XCTAssertTrue(sheet.labels().contains("expires in 48 h"))
    }

    func testARefusedNewCodeShowsTheServicesLineInPlace() async throws {
        let kit = realKit()
        kit.store.upsert(pendingDuo(nil))
        kit.transport.onCreateInvite = { _, _, _ in throw DuoTransportError.offline }
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.newcode") }
        try sheet.activate("duo.invite.newcode")
        await jExpect("\(sheet.labels())") { sheet.labels().contains("No connection right now. Try again in a bit.") }
        XCTAssertFalse(sheet.hasElement("duo.invite.code"))
    }

    func testATapTheServiceRefusesWithoutAWordStillSaysSomething() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(nil))
        kit.joining.inviteResult = nil
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.newcode") }
        await jSettle()
        XCTAssertFalse(sheet.labels().contains(DuoUserMessage.generic), "nothing is said before a tap")
        try sheet.activate("duo.invite.newcode")
        await jExpect("the general line, not silence: \(sheet.labels())") { sheet.labels().contains(DuoUserMessage.generic) }
        XCTAssertEqual(kit.joining.calls, ["newInvite"])
    }

    func testALineAnotherSheetLeftBehindIsNotShown() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        kit.store.sheetError = "Something the join sheet said"
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.code") }
        XCTAssertNil(kit.store.sheetError)
        XCTAssertFalse(sheet.labels().contains("Something the join sheet said"))
    }

    /// Correctness L2: neither sheet leaves its failure line for the next sheet, which shows a
    /// leftover line on appear.
    func testEachSheetTakesItsLineWithItWhenItCloses() async throws {
        let kit = realKit()
        kit.store.upsert(pendingDuo(nil))
        kit.transport.onCreateInvite = { _, _, _ in throw DuoTransportError.offline }
        let invitePresentation = JPresentation()
        let invitePresenter = try host(JPresenter(presentation: invitePresentation) {
            DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID)
        })
        await jExpect { invitePresenter.hasElement("duo.invite.newcode") }
        try invitePresenter.activate("duo.invite.newcode")
        await jExpect { kit.store.sheetError != nil }
        invitePresentation.isPresented = false
        await jExpect("the invite sheet's line goes with it") { kit.store.sheetError == nil }
        invitePresenter.close()

        let reconnectKit = DuoTestKit()
        reconnectKit.store.upsert(silentDuo())
        let reconnectPresentation = JPresentation()
        let reconnectPresenter = try host(JPresenter(presentation: reconnectPresentation) {
            DuoReconnectCodeSheet(duoStore: reconnectKit.store, duo: self.silentDuo(), memory: DuoReconnectCodeMemory())
        })
        await jExpect { reconnectPresenter.labels().contains(DuoUserMessage.generic) }
        reconnectKit.store.sheetError = "Too many tries. Wait a bit and try again."
        reconnectPresentation.isPresented = false
        await jExpect("the reconnect sheet's line goes with it") { reconnectKit.store.sheetError == nil }
    }

    // MARK: - The reconnect code: asked once, held in memory, never kept

    func testTheReconnectSheetAsksForOneCodeWhenItAppearsAndKeepsItNowhere() async throws {
        let kit = DuoTestKit()
        let duo = silentDuo()
        kit.store.upsert(duo)
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: duo.id)
        kit.joining.reconnectCodeResult = invite("R3C0NN3C", expiringIn: 48 * 3600)
        let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: duo, memory: DuoReconnectCodeMemory()))
        await jExpect { sheet.hasElement("duo.invite.code") }
        XCTAssertEqual(kit.joining.calls, ["createReconnectCode"])

        // Redraws (a change in the store, a tick) never ask again: a second code would void the first.
        kit.store.setNickname("Sammy", for: duo.id)
        kit.store.isWorking = true
        kit.store.isWorking = false
        await jSettle()
        XCTAssertEqual(kit.joining.calls, ["createReconnectCode"], "asked once, on appear, and never again")

        // The code is shown and kept nowhere on disk: not on the duo, not in the cache, not in the
        // App Group's defaults or the app's own (mutant M20), not in the Keychain.
        XCTAssertNil(kit.store.duo(duo.id)?.invite)
        XCTAssertEqual(kit.store.duos.count, 1)
        for (name, defaults) in [("the kit's", kit.defaults), ("the App Group's", UserDefaults(suiteName: AppGroup.identifier)), ("the app's", .standard)] {
            let saved = (defaults?.dictionaryRepresentation().values.map { value -> String in
                if let data = value as? Data { return String(decoding: data, as: UTF8.self) }
                return "\(value)"
            } ?? []).joined()
            XCTAssertFalse(saved.contains("R3C0NN3C") || saved.contains("R3C0-NN3C"), "the reconnect code is not in \(name) defaults")
        }
        XCTAssertEqual(kit.dependencies.secrets.linkSecret(forDuo: duo.id), k, "the duo's own secret is untouched")
    }

    /// Probe P2 inverted, correctness M1, D79: closing the sheet and opening it again shows the same
    /// code and sends nothing; a second request would void the code already sent.
    func testOpeningTheReconnectSheetAgainShowsTheSameCodeAndSendsNothing() async throws {
        let kit = realKit()
        let duo = silentDuo()
        kit.store.upsert(duo)
        let memory = DuoReconnectCodeMemory()
        var made = 0
        kit.transport.onCreateInvite = { _, purpose, _ in
            made += 1
            XCTAssertEqual(purpose, .reconnect)
            return DuoWireInvite(code: made == 1 ? "R3C0NN3C" : "R3C0NN3D", display: "x", expiresAt: Date().addingTimeInterval(48 * 3600))
        }
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) { DuoReconnectCodeSheet(duoStore: kit.store, duo: duo, memory: memory) })
        await jExpect { presenter.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3C" }
        presentation.isPresented = false
        await jExpect { presenter.presented().isEmpty }
        await jSettle(0.3)
        presentation.isPresented = true
        await jExpect { presenter.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3C" }
        await jSettle()
        XCTAssertEqual(inviteKeys(kit).count, 1, "one request for the code, however often the sheet is opened")
        XCTAssertEqual(presenter.element("duo.invite.code")?.accessibilityLabel, "R3C0-NN3C")
    }

    /// D79: a wipe through Start fresh closes both sheets and drops the held code, so the next
    /// opening asks again rather than showing a code from an identity that is gone.
    func testStartFreshClosesBothSheetsAndForgetsTheHeldCode() async throws {
        let kit = DuoTestKit()
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.store.upsert(pendingDuo(invite()))
        let invitePresentation = JPresentation()
        let invitePresenter = try host(JPresenter(presentation: invitePresentation) {
            DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID)
        })
        await jExpect { invitePresenter.hasElement("duo.invite.code") }
        kit.store.startFresh()
        await jExpect("the invite sheet closed on the wipe") { !invitePresentation.isPresented }
        invitePresenter.close()

        let reconnectKit = DuoTestKit()
        reconnectKit.dependencies.exiting = DuoExitService(dependencies: reconnectKit.dependencies)
        reconnectKit.store.upsert(silentDuo())
        reconnectKit.joining.reconnectCodeResult = invite("R3C0NN3C")
        let memory = DuoReconnectCodeMemory()
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) {
            DuoReconnectCodeSheet(duoStore: reconnectKit.store, duo: self.silentDuo(), memory: memory)
        })
        await jExpect { presenter.hasElement("duo.invite.code") }
        XCTAssertNotNil(memory.code(for: DuoFixtures.duoID, in: reconnectKit.store, now: Date()), "held after it was given")
        reconnectKit.store.startFresh()
        await jExpect("the reconnect sheet closed on the wipe") { !presentation.isPresented }
        XCTAssertNil(memory.code(for: DuoFixtures.duoID, in: reconnectKit.store, now: Date()))
        XCTAssertTrue(memory.isEmpty, "and nothing of it is left in memory")

        // The same duo id back after the wipe (a fresh start that rejoined) is asked for again.
        reconnectKit.store.upsert(silentDuo())
        await jExpect { presenter.presented().isEmpty }
        presentation.isPresented = true
        await jExpect { presenter.hasElement("duo.invite.code") }
        XCTAssertEqual(reconnectKit.joining.calls, ["createReconnectCode", "createReconnectCode"])
    }

    /// Mutant M38: a wipe while the sheet is closed, and the same duo id back before it opens again
    /// (the duo read back after a fresh start), still drops the held code: it belonged to the
    /// identity the wipe let go of. Only `wipeEpoch` can tell.
    func testACodeHeldBeforeAWipeIsNotShownForTheSameDuoAfterIt() async throws {
        let kit = DuoTestKit()
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.store.upsert(silentDuo())
        kit.joining.reconnectCodeResult = invite("R3C0NN3C")
        let memory = DuoReconnectCodeMemory()
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) {
            DuoReconnectCodeSheet(duoStore: kit.store, duo: self.silentDuo(), memory: memory)
        })
        await jExpect { presenter.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3C" }
        presentation.isPresented = false
        await jExpect { presenter.presented().isEmpty }

        kit.store.startFresh()
        kit.store.upsert(silentDuo())
        kit.joining.reconnectCodeResult = invite("R3C0NN3D")
        presentation.isPresented = true
        await jExpect("a new code, not the one held before the wipe") { presenter.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3D" }
        XCTAssertEqual(kit.joining.calls, ["createReconnectCode", "createReconnectCode"])
    }

    /// D79, J7: a held code that expires is forgotten, the sheet says so in the reconnect's own
    /// words, and the next opening asks for a new one.
    func testAnExpiredReconnectCodeIsForgottenAndTheSheetSaysSo() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(silentDuo())
        kit.joining.reconnectCodeResult = invite("R3C0NN3C", expiringIn: 1.5)
        let memory = DuoReconnectCodeMemory()
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) {
            DuoReconnectCodeSheet(duoStore: kit.store, duo: self.silentDuo(), memory: memory)
        })
        await jExpect { presenter.hasElement("duo.invite.code") }
        await jExpect("gone within moments of expiring", seconds: 4) {
            presenter.labels().contains("This code is no longer open. Open the card again for a new one.")
        }
        XCTAssertFalse(presenter.hasElement("duo.invite.code"))
        XCTAssertFalse(presenter.labels().contains("This invite is no longer open."), "not the invite's words")
        XCTAssertNil(memory.code(for: DuoFixtures.duoID, in: kit.store, now: Date()))
        presentation.isPresented = false
        await jExpect { presenter.presented().isEmpty }
        kit.joining.reconnectCodeResult = invite("R3C0NN3D", expiringIn: 48 * 3600)
        presentation.isPresented = true
        await jExpect { presenter.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3D" }
        XCTAssertEqual(kit.joining.calls, ["createReconnectCode", "createReconnectCode"])
    }

    /// Mutant S11: the sheet disappearing and appearing again while it keeps its state (something
    /// full screen over it) runs its task again, and a refusal must not be asked for twice.
    func testTheReconnectSheetAsksOnceAcrossDisappearingAndAppearing() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(silentDuo())
        kit.joining.reconnectCodeResult = nil
        let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()))
        await jExpect { sheet.labels().contains(DuoUserMessage.generic) }
        let cover = sheet.coverFullScreen()
        await jSettle()
        cover.dismiss(animated: false)
        await jExpect { sheet.labels().contains(DuoUserMessage.generic) }
        await jSettle()
        XCTAssertEqual(kit.joining.calls, ["createReconnectCode"])
    }

    /// Correctness L3: a request the sheet's going away cancelled is not an answer. It is not shown
    /// as a failure, and the sheet asks again when it is back (the real service sends the same key).
    func testACancelledAskIsAskedAgainNotShownAsAFailure() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(silentDuo())
        let slow = JSlowReconnect()
        slow.code = invite("R3C0NN3C")
        kit.dependencies.joining = slow
        let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()))
        await jExpect { slow.reconnectAsks == 1 }
        await jSettle(0.3)
        let cover = sheet.coverFullScreen()
        await jSettle()
        cover.dismiss(animated: false)
        await jExpect("asked again once back: \(slow.reconnectAsks)") { sheet.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3C" }
        XCTAssertEqual(slow.reconnectAsks, 2)
        XCTAssertFalse(sheet.labels().contains(DuoUserMessage.generic), "a cancel was never shown as a failure")
    }

    /// Mutant S15: a line another sheet left behind is cleared before asking, so a refusal that
    /// says nothing shows the general line, not someone else's.
    func testALeftoverLineDoesNotStandInForTheReconnectAnswer() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(silentDuo())
        kit.store.sheetError = "Left over"
        kit.joining.reconnectCodeResult = nil
        let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()))
        await jExpect { sheet.labels().contains(DuoUserMessage.generic) }
        XCTAssertFalse(sheet.labels().contains("Left over"))
    }

    func testTheReconnectSheetAsksForNothingForADuoThatEndedOrIsGone() async throws {
        var ended = silentDuo()
        ended.endedAt = Date()
        ended.endedBy = .partner
        for (name, stored) in [("ended", Optional(ended)), ("gone", nil)] {
            let kit = DuoTestKit()
            if let stored { kit.store.upsert(stored) }
            kit.joining.reconnectCodeResult = invite("R3C0NN3C")
            let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: silentDuo(), memory: DuoReconnectCodeMemory()))
            await jSettle()
            XCTAssertEqual(kit.joining.calls, [], "no code is asked for a duo that \(name)")
            XCTAssertFalse(sheet.hasElement("duo.invite.code"), name)
            sheet.close()
        }
    }

    func testAReconnectCodeTheServerRefusesShowsTheGeneralLineWithItsReference() async throws {
        let kit = realKit()
        let duo = silentDuo()
        kit.store.upsert(duo)
        kit.transport.onCreateInvite = { _, purpose, _ in
            XCTAssertEqual(purpose, .reconnect)
            throw DuoTransportError.targetActive(DuoErrorContext(httpStatus: 409, requestID: "req-j1"))
        }
        let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: duo, memory: DuoReconnectCodeMemory()))
        await jExpect("\(sheet.labels())") { sheet.labels().contains("That did not work. Please try again. (ref req-j1)") }
        XCTAssertEqual(kit.transport.calls.count, 1, "one request, on appear")
        XCTAssertFalse(sheet.hasElement("duo.invite.code"))
        XCTAssertNil(kit.store.duo(duo.id)?.invite)
    }

    // MARK: - Closing and running out

    func testTheInviteSheetClosesItselfOnceThePartnerJoins() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) {
            DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID)
        })
        await jExpect { presenter.hasElement("duo.invite.code") }
        await jSettle()
        XCTAssertTrue(presentation.isPresented, "a waiting duo keeps the sheet up")

        kit.store.update(DuoFixtures.duoID) {
            $0.partnerHasJoined = true
            $0.invite = nil
        }
        await jExpect("the sheet closed itself") { !presentation.isPresented }
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testTheReconnectSheetClosesItselfWhenTheDuoIsWiped() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(silentDuo())
        kit.joining.reconnectCodeResult = invite("R3C0NN3C")
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) {
            DuoReconnectCodeSheet(duoStore: kit.store, duo: self.silentDuo(), memory: DuoReconnectCodeMemory())
        })
        await jExpect { presenter.hasElement("duo.invite.code") }
        kit.store.resetLocalState()
        await jExpect("nothing is left to reconnect to") { !presentation.isPresented }
    }

    /// Probe P5, correctness L1: a code that runs out leaves the screen within moments, not at the
    /// next minute with a QR anyone could still scan.
    func testACodeThatRunsOutLeavesTheScreenWithinMoments() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite(expiringIn: 1.5)))
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.code") }
        await jExpect("gone by 1.5 s and a little", seconds: 3) { !sheet.hasElement("duo.invite.code") }
        XCTAssertTrue(sheet.labels().contains("This invite is no longer open."))
        XCTAssertEqual(jQRMessages(in: sheet.snapshot()), [])
    }

    /// Probe P12 inverted, correctness M2, D79: the server's open invite expires later than this
    /// phone's code, so a newer code exists and this one is dead: the sheet offers a new one.
    func testAServerExpiryLaterThanThisPhonesCodeShowsNoCode() async throws {
        let kit = DuoTestKit()
        var duo = pendingDuo(invite(expiringIn: 10 * 3600))
        duo.openInviteExpiresAt = Date().addingTimeInterval(47 * 3600)
        kit.store.upsert(duo)
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.newcode") }
        XCTAssertFalse(sheet.hasElement("duo.invite.code"))
        XCTAssertTrue(sheet.labels().contains("This invite is no longer open."))
        XCTAssertEqual(jQRMessages(in: sheet.snapshot()), [])
    }

    // MARK: - Copy

    /// Secrets M3, correctness M3, mutants M1, M4, M5, S17, S18: the Copy button itself puts the
    /// code as shown, and only that, on the pasteboard it was given, and it leaves with the code.
    func testTheCopyButtonPutsOnlyTheShownCodeOnThePasteboardUntilTheCodeExpires() async throws {
        let board = try pasteboard()
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite(expiringIn: 3)))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID, pasteboard: board))
        await jExpect { sheet.hasElement("duo.invite.copy") }
        XCTAssertTrue(try sheet.activate("duo.invite.copy"))
        XCTAssertEqual(board.string, "H7K3-9QWX", "the code as shown, never the link")
        XCTAssertFalse(board.hasURLs)
        XCTAssertEqual(board.items.count, 1)
        XCTAssertEqual(board.items.first?.count, 1, "one representation, the text")
        await jExpect("gone from the pasteboard with the code", seconds: 6) { board.string == nil }

        // The reconnect code's button writes the same way.
        let reconnectBoard = try pasteboard()
        let reconnectKit = DuoTestKit()
        reconnectKit.store.upsert(silentDuo())
        try reconnectKit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        reconnectKit.joining.reconnectCodeResult = invite("R3C0NN3C", expiringIn: 3)
        let reconnect = try host(DuoReconnectCodeSheet(duoStore: reconnectKit.store, duo: silentDuo(), pasteboard: reconnectBoard,
                                                       memory: DuoReconnectCodeMemory()))
        await jExpect { reconnect.hasElement("duo.invite.copy") }
        XCTAssertTrue(try reconnect.activate("duo.invite.copy"))
        XCTAssertEqual(reconnectBoard.string, "R3C0-NN3C")
        XCTAssertFalse(reconnectBoard.hasURLs)
        await jExpect("gone with the code", seconds: 6) { reconnectBoard.string == nil }
    }

    func testTheCopyHelpersAreLocalOnlyAndExpireAsD79Says() throws {
        let code = invite()
        let shown = DuoCodeDisplay.displayCode(for: code)
        XCTAssertEqual(shown, "H7K3-9QWX")

        let items = DuoCodeDisplay.pasteboardItems(code: shown)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.count, 1, "one representation, the text")
        XCTAssertEqual(items.first?.values.first as? String, "H7K3-9QWX")
        XCTAssertFalse(items.flatMap(\.values).contains { "\($0)".contains("hydrodrop.us") }, "never the link")

        let options = DuoCodeDisplay.pasteboardOptions(expiresAt: code.expiresAt)
        XCTAssertEqual(options[.localOnly] as? Bool, true, "never carried to the person's other devices")
        XCTAssertEqual(options[.expirationDate] as? Date, code.expiresAt)
        XCTAssertEqual(options.count, 2)

        XCTAssertEqual(DuoCodeDisplay.Kind.invite.pasteboardLifetime, 48 * 3600)
        XCTAssertEqual(DuoCodeDisplay.Kind.reconnect.pasteboardLifetime, 10 * 60, "a takeover code stays ten minutes at most")

        let board = try pasteboard()
        DuoCodeDisplay.copy(code: shown, expiresAt: code.expiresAt, to: board)
        XCTAssertEqual(board.string, "H7K3-9QWX")
        XCTAssertFalse(board.hasURLs)
        DuoCodeDisplay.copy(code: shown, expiresAt: Date().addingTimeInterval(-1), to: board)
        XCTAssertNil(board.string, "an expiry already past leaves nothing to paste")
    }

    func testTheShownCodeIsMadeFromTheCanonicalCode() {
        XCTAssertEqual(DuoCodeDisplay.displayCode(for: DuoInvite(code: "H7K39QWX", display: "something else", expiresAt: Date())), "H7K3-9QWX")
        XCTAssertEqual(DuoCodeDisplay.displayCode(for: DuoInvite(code: "h7k39qwx", display: "x", expiresAt: Date())), "H7K3-9QWX")
        XCTAssertEqual(DuoCodeDisplay.displayCode(for: DuoInvite(code: "bad!", display: "SERV-ER01", expiresAt: Date())), "SERV-ER01",
                       "a code that is not one falls back to the server's own form")
    }

    // MARK: - Share

    /// Secrets M1, D79, mutants M13 and M17: Share hands the link alone to the system share sheet,
    /// with the share sheet's own Copy, Reading List and the rest taken out; a reconnect link
    /// carries no secret even for a duo that has one.
    func testShareHandsTheLinkAloneToTheShareSheetWithoutItsCopyOrReadingList() async throws {
        let expected: [UIActivity.ActivityType] = [.copyToPasteboard, .addToReadingList, .print, .assignToContact, .saveToCameraRoll,
                                                   .openInIBooks, .markupAsPDF]
        XCTAssertEqual(DuoCodeDisplay.excludedShareActivities, expected)
        let link = try XCTUnwrap(DuoLink.url(code: "H7K39QWX", k: k))
        XCTAssertEqual(DuoCodeDisplay.shareItems(for: link).count, 1)
        XCTAssertEqual(DuoCodeDisplay.shareItems(for: link).first as? URL, link, "the link alone: no subject, no message")
        XCTAssertEqual(DuoCodeDisplay.makeShareSheet(for: link).excludedActivityTypes, expected)

        for (name, isInvite) in [("invite", true), ("reconnect", false)] {
            let kit = DuoTestKit()
            kit.store.upsert(isInvite ? pendingDuo(invite()) : silentDuo())
            try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
            kit.joining.reconnectCodeResult = invite("R3C0NN3C")
            let sheet: JHosted
            if isInvite {
                sheet = try host(JPresenter(presentation: JPresentation()) { DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID) })
            } else {
                sheet = try host(JPresenter(presentation: JPresentation()) {
                    DuoReconnectCodeSheet(duoStore: kit.store, duo: self.silentDuo(), memory: DuoReconnectCodeMemory())
                })
            }
            await jExpect(name) { sheet.hasElement("duo.invite.share") }
            XCTAssertTrue(try sheet.activate("duo.invite.share"), name)
            await jExpect("\(name): the share sheet is up") { sheet.shareSheet() != nil }
            let shareSheet = try XCTUnwrap(sheet.shareSheet())
            XCTAssertEqual(shareSheet.excludedActivityTypes, expected, name)
            let items = try XCTUnwrap(jSharedItems(shareSheet), "\(name): the share sheet's items could not be read")
            let wanted = isInvite ? "https://hydrodrop.us/duo#H7K39QWX.\(k)" : "https://hydrodrop.us/duo#R3C0NN3C"
            XCTAssertEqual(items.count, 1, "\(name): the link alone")
            XCTAssertEqual((items.first as? URL)?.absoluteString, wanted, name)
            XCTAssertFalse(items.contains { $0 is String }, "\(name): no message of ours")
            // A second tap while it is up opens nothing more.
            _ = try? sheet.activate("duo.invite.share")
            await jSettle(0.3)
            XCTAssertEqual(sheet.presented().filter { $0 is UIActivityViewController }.count, 1, name)
            sheet.close()
            await jSettle(0.5)
        }
    }

    /// Probe P14: the partner joins while the share sheet is up. The sheet closes, nothing is left
    /// presented, and it can be opened again.
    func testTheInviteSheetClosesCleanlyWhileTheShareSheetIsUp() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let presentation = JPresentation()
        let presenter = try host(JPresenter(presentation: presentation) { DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID) })
        await jExpect { presenter.hasElement("duo.invite.share") }
        try presenter.activate("duo.invite.share")
        await jExpect { presenter.shareSheet() != nil }
        kit.store.update(DuoFixtures.duoID) {
            $0.partnerHasJoined = true
            $0.invite = nil
        }
        await jExpect("closed") { !presentation.isPresented }
        await jExpect("nothing left presented") { presenter.presented().isEmpty }
        kit.store.update(DuoFixtures.duoID) {
            $0.partnerHasJoined = false
            $0.invite = self.invite()
        }
        presentation.isPresented = true
        await jExpect("and it opens again") { presenter.hasElement("duo.invite.code") }
    }

    // MARK: - Covered while not in front

    /// Mutants M7, M8, M9, M10: covered while the app is not in front, with Copy and Share off.
    func testTheCodeAndTheQRAreCoveredWhileTheAppIsNotInFront() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let app = JAppState()
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID, lifecycle: app.lifecycle))
        await jExpect { sheet.element("duo.invite.code")?.accessibilityLabel == "H7K3-9QWX" }
        XCTAssertEqual(jQRMessages(in: sheet.snapshot()).count, 1)
        XCTAssertFalse(try XCTUnwrap(sheet.element("duo.invite.copy")).accessibilityTraits.contains(.notEnabled))

        app.inFront = false
        app.post(UIApplication.willResignActiveNotification)
        await jExpect("the code is covered") { sheet.element("duo.invite.code")?.accessibilityLabel != "H7K3-9QWX" }
        XCTAssertEqual(jQRMessages(in: sheet.snapshot()), [], "and so is the QR, so the app switcher's picture holds neither")
        XCTAssertFalse(sheet.labels().contains("H7K3-9QWX"))
        for id in ["duo.invite.copy", "duo.invite.share"] {
            XCTAssertTrue(try XCTUnwrap(sheet.element(id), id).accessibilityTraits.contains(.notEnabled), "\(id) is off while covered")
        }

        app.inFront = true
        app.post(UIApplication.didBecomeActiveNotification)
        await jExpect("back when the app is") { sheet.element("duo.invite.code")?.accessibilityLabel == "H7K3-9QWX" }
        await jExpect { jQRMessages(in: sheet.snapshot()).count == 1 }

        app.inFront = false
        app.post(UIApplication.didEnterBackgroundNotification)
        await jExpect("covered in the background too") { jQRMessages(in: sheet.snapshot()).isEmpty }
        app.inFront = true
        app.post(UIApplication.didBecomeActiveNotification)
        await jExpect { jQRMessages(in: sheet.snapshot()).count == 1 }

        // Recording or mirroring the screen covers it too.
        app.captured = true
        app.post(UIScreen.capturedDidChangeNotification)
        await jExpect("covered while the screen is captured") { jQRMessages(in: sheet.snapshot()).isEmpty }
        app.captured = false
        app.post(UIScreen.capturedDidChangeNotification)
        await jExpect { jQRMessages(in: sheet.snapshot()).count == 1 }
    }

    /// Secrets probe and L1, correctness L6, J5: a code that arrives after the person switched away
    /// (a reconnect answer landing while they are in Messages) is drawn covered from the start.
    func testACodeDrawnWhileTheAppIsNotInFrontStartsCovered() async throws {
        for (name, inFront, captured) in [("in the background", false, false), ("while the screen is captured", true, true)] {
            let kit = DuoTestKit()
            kit.store.upsert(silentDuo())
            kit.joining.reconnectCodeResult = invite("R3C0NN3C")
            let app = JAppState()
            app.inFront = inFront
            app.captured = captured
            let sheet = try host(DuoReconnectCodeSheet(duoStore: kit.store, duo: silentDuo(), lifecycle: app.lifecycle, memory: DuoReconnectCodeMemory()))
            // A covered code is drawn as a placeholder, which is no element at all; the answer has
            // come when Copy is there.
            await jExpect(name) { sheet.hasElement("duo.invite.copy") }
            await jSettle(0.3)
            XCTAssertNotEqual(sheet.element("duo.invite.code")?.accessibilityLabel, "R3C0-NN3C", "covered from the start \(name)")
            XCTAssertEqual(jQRMessages(in: sheet.snapshot()), [], name)

            app.inFront = true
            app.captured = false
            app.post(captured ? UIScreen.capturedDidChangeNotification : UIApplication.didBecomeActiveNotification)
            await jExpect(name) { sheet.element("duo.invite.code")?.accessibilityLabel == "R3C0-NN3C" }
            await jExpect(name) { jQRMessages(in: sheet.snapshot()) == ["https://hydrodrop.us/duo#R3C0NN3C"] }
            sheet.close()
        }
    }

    /// Mutants M11 and S22: the code is not selectable, so Copy, with its local and expiring copy,
    /// is the one way off the screen. A selectable text answers to touch for its edit menu; this
    /// one must not.
    func testTheCodeIsNotSelectable() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.code") }
        let code = try XCTUnwrap(sheet.element("duo.invite.code"))
        XCTAssertEqual(code.accessibilityLabel, "H7K3-9QWX")
        XCTAssertFalse(code.accessibilityRespondsToUserInteraction, "a selectable text would answer to touch")
    }

    func testNoIdentifierLabelOrValueCarriesTheLinkOrTheSecret() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID))
        await jExpect { sheet.hasElement("duo.invite.share") }
        for element in sheet.elements() {
            let said = [jIdentifier(of: element), element.accessibilityLabel, element.accessibilityValue, element.accessibilityHint].compactMap { $0 }
            for text in said {
                XCTAssertFalse(text.contains(k), "the secret is never spoken or named: \(text)")
                XCTAssertFalse(text.contains("hydrodrop.us"), "the link is shown only by the QR and the share sheet: \(text)")
            }
            if let identifier = jIdentifier(of: element) {
                XCTAssertFalse(identifier.contains("H7K3") || identifier.contains("9QWX"), "no code in an identifier: \(identifier)")
            }
        }
    }

    // MARK: - Drawn once, read once

    /// Correctness L8, J10: the QR is drawn once per code and the link, with its secret from the
    /// Keychain, read once per code, not on every redraw.
    func testTheLinkIsReadAndTheQRDrawnOncePerCode() async throws {
        let kit = DuoTestKit()
        kit.store.upsert(pendingDuo(invite()))
        try kit.dependencies.secrets.saveLinkSecret(k, forDuo: DuoFixtures.duoID)
        let app = JAppState()
        let board = try pasteboard()
        let sheet = try host(DuoInviteSheet(duoStore: kit.store, duoID: DuoFixtures.duoID, lifecycle: app.lifecycle, pasteboard: board))
        await jExpect { jQRMessages(in: sheet.snapshot()) == ["https://hydrodrop.us/duo#H7K39QWX.\(self.k)"] }
        await jSettle(0.3)
        let made = DuoQRCode.symbolsMade

        // The secret goes from the Keychain, and the sheet redraws several times.
        try kit.dependencies.secrets.deleteLinkSecret(forDuo: DuoFixtures.duoID)
        for round in 0..<4 {
            kit.store.isWorking = round % 2 == 0
            kit.store.notice = "round \(round)"
            await jSettle(0.15)
        }
        kit.store.isWorking = false
        // And the code display itself redraws: covered and back (mutant M33, which a store change
        // alone never reaches, since the display's own inputs stay the same), and a Copy.
        app.inFront = false
        app.post(UIApplication.willResignActiveNotification)
        await jExpect { jQRMessages(in: sheet.snapshot()).isEmpty }
        app.inFront = true
        app.post(UIApplication.didBecomeActiveNotification)
        await jExpect { jQRMessages(in: sheet.snapshot()).count == 1 }
        try sheet.activate("duo.invite.copy")
        await jSettle(0.3)
        XCTAssertEqual(DuoQRCode.symbolsMade, made, "no QR drawn again for the same code")
        XCTAssertEqual(jQRMessages(in: sheet.snapshot()), ["https://hydrodrop.us/duo#H7K39QWX.\(k)"],
                       "the link was read once, so the Keychain was not asked again on a redraw")

        // A new code is a new link and a new QR.
        kit.store.update(DuoFixtures.duoID) { $0.invite = self.invite("N3WC0DE2") }
        await jExpect { jQRMessages(in: sheet.snapshot()) == ["https://hydrodrop.us/duo#N3WC0DE2"] }
        XCTAssertGreaterThan(DuoQRCode.symbolsMade, made)
    }
}
#endif
