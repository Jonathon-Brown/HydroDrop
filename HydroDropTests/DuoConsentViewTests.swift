#if DUO_V2
import SwiftUI
import Vision
import XCTest
@testable import HydroDrop

// MARK: - Helpers (stage I)

/// What a closure was called with, counted, for the gate's and the sheets' callbacks.
@MainActor
fileprivate final class ICounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

fileprivate enum IFixtures {
    static let createdID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000001c1")!

    static var createResponse: DuoWireCreateDuoResponse {
        DuoWireCreateDuoResponse(duo: DuoFixtures.wireHeader(id: createdID, role: .owner, state: .pending, seq: 1),
                                 invite: DuoWireInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: Date(timeIntervalSince1970: 1_790_172_800)),
                                 accepted: [], unchanged: [], rejected: [])
    }

    static var termsRequired: DuoTransportError {
        .termsRequired(DuoErrorContext(httpStatus: 428, requestID: "req-428", details: DuoWireErrorDetails(termsVersion: DuoProtocolConstants.termsVersion)))
    }

    static let member = DuoWireMember(id: "m", supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1)

    /// A year that is a child's whatever today is, and one that is an adult's.
    static var childYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) - 5 }
    static let adultYear = 1990
}

/// A box a transport handler (which runs off the main actor) can write to and a test can read.
fileprivate final class IBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// The shared joining double, with its first `acceptTerms` (or first `createDuo`) held open until
/// the test lets it go, so a test can look at a screen while that request is still out (the shared
/// one answers at once). Any later call goes straight through, so a bug that lets a second tap send
/// fails its test instead of waiting on the hold for ever.
@MainActor
fileprivate final class IHeldJoining: DuoJoining {
    enum Held { case acceptTerms, createDuo }
    let base = FakeJoining()
    let held: Held
    private(set) var entered = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    init(holding held: Held) { self.held = held }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }

    private func hold(_ which: Held) async {
        guard which == held else { return }
        entered += 1
        if entered == 1, !released { await withCheckedContinuation { waiting = $0 } }
    }

    func acceptTerms() async -> Bool {
        await hold(.acceptTerms)
        return await base.acceptTerms()
    }

    func createDuo(named: String?, skin: String) async -> DuoState? {
        await hold(.createDuo)
        return await base.createDuo(named: named, skin: skin)
    }

    func peek(code: String) async -> DuoPeek? { await base.peek(code: code) }
    func receive(_ invite: DuoParsedInvite, now: Date) { base.receive(invite, now: now) }
    func discardPendingInvite() { base.discardPendingInvite() }
    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState? { await base.join(invite, named: named, skin: skin) }
    func newInvite(for duo: DuoState) async -> DuoInvite? { await base.newInvite(for: duo) }
    func createReconnectCode(for duo: DuoState) async -> DuoInvite? { await base.createReconnectCode(for: duo) }
    func createLinkCode() async -> DuoInvite? { await base.createLinkCode() }
    func reconnect(code: String) async -> Bool { await base.reconnect(code: code) }
    func changeMyName(_ name: String?) async { await base.changeMyName(name) }
}

/// An identity whose first `prepare()` waits until the test lets it go, so a Create through the
/// real joining service can be held in flight while the sheet that sent it goes away (review 3's
/// late-428 probe).
fileprivate final class IHeldIdentity: DuoIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCredential: DuoCredential?
    private var waiting: CheckedContinuation<Void, Never>?
    private var holding = true
    private var entries = 0
    var installDay = "2026-09-01"
    init(credential: DuoCredential?) { storedCredential = credential }
    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }
    var credential: DuoCredential? { lock.lock(); defer { lock.unlock() }; return storedCredential }
    func store(_ credential: DuoCredential) throws { lock.lock(); storedCredential = credential; lock.unlock() }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { lock.lock(); storedCredential = nil; lock.unlock() }
    func prepare() async -> DuoIdentityLaunch {
        lock.lock(); entries += 1; let hold = holding; holding = false; lock.unlock()
        if hold { await withCheckedContinuation { continuation in lock.lock(); waiting = continuation; lock.unlock() } }
        return .ready
    }
    func release() { lock.lock(); let continuation = waiting; waiting = nil; holding = false; lock.unlock(); continuation?.resume() }
    func continueAsRestored() async {}
}

/// A kit whose person answered the age screen (and, if asked, accepted the rules) through the
/// store's own calls, so the store's published values are the ones a view reads. The rules are
/// accepted with no joining service attached, so the kit's `FakeJoining.calls` start empty and
/// hold only what the test itself caused.
@MainActor
fileprivate func iKit(age: DuoAgeStatus, termsAccepted: Bool, credential: DuoCredential? = nil,
                      secretStore: DuoMemorySecretStore = DuoMemorySecretStore()) async -> DuoTestKit {
    let kit = DuoTestKit(credential: credential, secretStore: secretStore)
    switch age {
    case .unknown: break
    case .allowed: kit.store.recordBirthYear(IFixtures.adultYear, month: 1)
    case .refused: kit.store.recordBirthYear(IFixtures.childYear, month: 1)
    }
    if termsAccepted {
        kit.dependencies.joining = nil
        _ = await kit.store.acceptTerms()
        kit.dependencies.joining = kit.joining
    }
    return kit
}

/// A kit over the real joining service with an identity that is ready, the transport answering a
/// first Create with `428` and every later one with a duo, and `PATCH /me` with the member.
@MainActor
fileprivate func i428Kit() async -> (DuoTestKit, IBox<Int>) {
    let kit = await iKit(age: .allowed, termsAccepted: true, credential: DuoFixtures.credential())
    kit.identity.launch = .ready
    kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
    let creates = IBox(0)
    kit.transport.onCreateDuo = { _, _ in
        creates.value += 1
        if creates.value == 1 { throw IFixtures.termsRequired }
        return IFixtures.createResponse
    }
    kit.transport.onUpdateMe = { _ in IFixtures.member }
    return (kit, creates)
}

@MainActor
fileprivate func iGate(_ store: DuoStore, closes: ICounter, resends: ICounter, builds: ICounter? = nil,
                       model: DuoConsentGateModel? = nil) -> DuoConsentGate<Text> {
    DuoConsentGate(duoStore: store, onClose: { closes.bump() }, onTermsAccepted: { resends.bump() }, model: model) {
        builds?.bump()
        return Text(verbatim: "form")
    }
}

/// The in-process accessibility runtime, switched on the way in-process UI test tools (KIF) do it,
/// so a hosted SwiftUI view exposes what VoiceOver would read: labels, values, traits (a disabled
/// button carries `.notEnabled`) and buttons that can be pressed with `accessibilityActivate()`.
/// Without it SwiftUI builds no accessibility nodes in a unit test. Test code only, never in the app.
@MainActor
fileprivate enum IAccessibility {
    private static var original: Int32?

    private static var library: UnsafeMutableRawPointer? {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        return dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_GLOBAL)
    }

    static func switchOn() -> Bool {
        typealias Getter = @convention(c) () -> Int32
        typealias Setter = @convention(c) (Int32) -> Void
        guard let handle = library, let setter = dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
        if original == nil, let getter = dlsym(handle, "_AXSAutomationEnabled") {
            original = unsafeBitCast(getter, to: Getter.self)()
        }
        unsafeBitCast(setter, to: Setter.self)(1)
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        for bundle in ["/System/Library/PrivateFrameworks/AXRuntime.framework", "/System/Library/PrivateFrameworks/UIAccessibility.framework",
                       "/System/Library/AccessibilityBundles/UIKit.axbundle", "/System/Library/AccessibilityBundles/SwiftUI.axbundle"] {
            _ = Bundle(path: root + bundle)?.load()
        }
        return true
    }

    static func restore() {
        typealias Setter = @convention(c) (Int32) -> Void
        guard let original, let handle = library, let setter = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(setter, to: Setter.self)(original)
    }
}

/// One thing VoiceOver can reach on screen.
fileprivate struct IElement {
    let object: NSObject
    var label: String { object.accessibilityLabel ?? "" }
    var identifier: String { object.value(forKey: "accessibilityIdentifier") as? String ?? "" }
    var value: String { object.accessibilityValue ?? "" }
    var traits: UIAccessibilityTraits { object.accessibilityTraits }
    var isEnabled: Bool { !traits.contains(.notEnabled) }
    var frame: CGRect { object.accessibilityFrame }
    /// The view that holds this element: for a row of a list, the row's cell.
    var row: UIView? {
        var node: Any? = object
        for _ in 0..<12 {
            if let view = node as? UIView { return view }
            guard let object = node as? NSObject, object.responds(to: NSSelectorFromString("accessibilityContainer")) else { return nil }
            node = object.value(forKey: "accessibilityContainer")
        }
        return nil
    }
}

/// A window of the test host's own scene, at a phone's width, for a view that has to be really on
/// screen: its `onAppear` and `.task` run, its sheets present, its `UITextField` exists and its
/// buttons can be pressed. Key status goes back to the app's own window when it closes.
@MainActor
fileprivate final class IWindow {
    let window: UIWindow
    private let previousKey: UIWindow?

    init(dark: Bool = false, height: CGFloat = 2000) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.keyWindow
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
    }

    func show<V: View>(_ view: V, typeSize: DynamicTypeSize = .large) async {
        window.rootViewController = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
        window.makeKeyAndVisible()
        _ = await until { !self.elements().isEmpty }
    }

    func close() {
        // A field left with the keyboard in a window that goes away left the text system in a state
        // where the next test's field no longer showed what SwiftUI wrote back to it.
        window.endEditing(true)
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }

    /// Waits until `condition` holds, up to a timeout, instead of a fixed pause.
    func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// `until`, as an assertion: fails the test, with `message`, if `condition` never holds.
    func expect(_ message: @autoclosure () -> String = "", timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () -> Bool) async {
        let held = await until(timeout, condition)
        XCTAssertTrue(held, message(), file: file, line: line)
    }

    /// Every accessibility element on screen, sheets presented over the root included, each once.
    func elements() -> [IElement] {
        var seen = Set<ObjectIdentifier>()
        var found: [IElement] = []
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 40 else { return }
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { return }
            if node.isAccessibilityElement, seen.insert(ObjectIdentifier(node)).inserted { found.append(IElement(object: node)) }
            if let children = node.accessibilityElements as? [NSObject], !children.isEmpty {
                children.forEach { walk($0, depth + 1) }
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count { if let child = node.accessibilityElement(at: index) as? NSObject { walk(child, depth + 1) } }
                }
            }
            if let view = node as? UIView { view.subviews.forEach { walk($0, depth + 1) } }
        }
        walk(window, 0)
        return found
    }

    func element(_ identifier: String) -> IElement? { elements().first { $0.identifier == identifier } }
    func labels() -> [String] { elements().map(\.label).filter { !$0.isEmpty } }
    func shows(_ text: String) -> Bool { labels().contains(text) }

    /// Presses a button the way VoiceOver does. Fails the test if it is missing or disabled.
    @discardableResult
    func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let target = element(identifier) else {
            XCTFail("no element \(identifier) on screen: \(labels())", file: file, line: line)
            return false
        }
        XCTAssertTrue(target.isEnabled, "\(identifier) is disabled", file: file, line: line)
        return target.object.accessibilityActivate()
    }

    /// The text fields on screen. SwiftUI hands a field its identifier only once the accessibility
    /// tree has been asked for, so it is asked first; a hidden view (a list keeps cells it is not
    /// showing, hidden, for reuse) is not on screen.
    func textFields(askingAccessibility: Bool = true) -> [UITextField] {
        if askingAccessibility { _ = elements() }
        func walk(_ view: UIView) -> [UITextField] {
            if view.isHidden || view.alpha == 0 { return [] }
            return (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(window)
    }

    func textField(_ identifier: String, askingAccessibility: Bool = true) -> UITextField? {
        textFields(askingAccessibility: askingAccessibility).first { $0.accessibilityIdentifier == identifier }
    }

    /// Types into a field the way the keyboard does, replacing what is there, once the field is on
    /// screen and has its identifier.
    func type(_ text: String, into identifier: String, file: StaticString = #filePath, line: UInt = #line) async {
        _ = await until { self.textField(identifier) != nil }
        guard let field = textField(identifier) else { return XCTFail("no field \(identifier)", file: file, line: line) }
        window.makeKey()
        field.becomeFirstResponder()
        let focused = await until { field.isFirstResponder }
        XCTAssertTrue(focused, "\(identifier) has the keyboard", file: file, line: line)
        // Key by key, as the keyboard does: clear what is there, then insert.
        while field.hasText { field.deleteBackward() }
        field.insertText(text)
    }

    var presented: UIViewController? { window.rootViewController?.presentedViewController }

    /// Scrolls every list on screen to its end, for a form taller than the window.
    func scrollToBottom() {
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        for list in scrollViews(window) where list.contentSize.height > list.bounds.height {
            let bottom = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
            list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }

    func image() -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }

    /// The text Vision reads off the screen, line by line.
    func readText() -> [String] {
        guard let cgImage = image().cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// For looking at a state by eye: written only when `DUO_STAGE_I_SNAPSHOTS` names a folder
    /// (`TEST_RUNNER_DUO_STAGE_I_SNAPSHOTS=<folder>` on the xcodebuild line); otherwise nothing.
    func snapshot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["DUO_STAGE_I_SNAPSHOTS"], !folder.isEmpty else { return }
        try? image().pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

/// Presents a sheet from a plain root, as the Duo screen does, so a sheet's own `dismiss()` can be
/// seen to work.
@MainActor
fileprivate final class IPresentation: ObservableObject {
    @Published var isPresented = true
}

fileprivate struct IPresenter<Sheet: View>: View {
    @ObservedObject var presentation: IPresentation
    let sheet: Sheet
    var body: some View {
        Color.clear.sheet(isPresented: $presentation.isPresented) { sheet }
    }
}

/// A store over the fully composed app (`DuoComposition.makeLiveStore`) with a session that records
/// every request, a Keychain that records every write, and counted attestation and DeviceCheck, on a
/// defaults suite of its own that the janitor removes when the test ends.
@MainActor
fileprivate struct IComposed {
    let store: DuoStore
    let session = RecordingSession()
    let keychain = DuoReviewSpySecretStore()
    let attester = FakeDuoAttester()
    let deviceCheck = DuoReviewCountingDeviceCheck()
    let defaults: UserDefaults
    let folder: URL

    init() throws {
        let suite = "DuoConsentViewTests.\(UUID().uuidString)"
        DuoSuiteJanitor.shared.track(suite)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DuoConsent-\(UUID().uuidString)", isDirectory: true)
        store = DuoComposition.makeLiveStore(session: session, secretStore: keychain, cache: DuoCache(defaults: defaults),
                                             attester: attester, deviceCheck: deviceCheck, identityDirectory: folder)
    }

    func removeFolder() { try? FileManager.default.removeItem(at: folder) }

    func nothingYet(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(session.requests.isEmpty, "\(when): no request before the tap (§3.1)", file: file, line: line)
        XCTAssertEqual(attester.attestedNewKeys, 0, when, file: file, line: line)
        XCTAssertTrue(attester.assertions.isEmpty, when, file: file, line: line)
        XCTAssertEqual(deviceCheck.calls, 0, when, file: file, line: line)
        XCTAssertTrue(keychain.writes.isEmpty, "\(when): \(keychain.writes)", file: file, line: line)
        XCTAssertTrue(keychain.deletes.isEmpty, "\(when): \(keychain.deletes)", file: file, line: line)
    }
}

// MARK: - The tests

/// Stage I's consent screens: the birth-year screen, the rules, the explainer and the Create and
/// invite sheet, and the gate that puts them in order (final design §3.1, §11.8, §12.6, §12.7).
/// Most run on a real screen and press the real buttons through the accessibility runtime, so a
/// button wired to the wrong action, or enabled when it should not be, fails a test.
@MainActor
final class DuoConsentViewTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(IAccessibility.switchOn(), "the accessibility runtime these tests press buttons through")
    }

    override class func tearDown() {
        MainActor.assumeIsolated { IAccessibility.restore() }
        super.tearDown()
    }

    // MARK: The age screen

    /// Neutral and empty: a title, the question spoken once (as the field's label), a field with no
    /// year in it and Continue off. No picker, no list, nothing about ages.
    func testTheAgeScreenStartsEmptyAndSaysNothingAboutAges() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        let title = window.elements().first { $0.label == "Before you start" }
        XCTAssertNotNil(title)
        XCTAssertTrue(title?.traits.contains(.header) ?? false, "the title is a heading")
        let field = window.element("duo.agegate.year")
        // Finding 15: the field is the year, as the month field is the month; the question is read
        // once, as itself, and no longer as the year field's label.
        XCTAssertEqual(field?.label, "Birth year")
        XCTAssertEqual(window.element("duo.agegate.month")?.label, "Birth month")
        XCTAssertEqual(window.labels().filter { $0 == "What month and year were you born?" }.count, 1, "and the question is spoken once")
        XCTAssertEqual(window.textField("duo.agegate.year")?.text, "", "no year is filled in")
        XCTAssertEqual(window.textField("duo.agegate.month")?.text, "", "no month is filled in")
        XCTAssertEqual(window.textField("duo.agegate.year")?.placeholder, "Year")
        XCTAssertEqual(window.textField("duo.agegate.year")?.keyboardType, .numberPad)
        XCTAssertEqual(window.element("duo.agegate.continue")?.isEnabled, false, "Continue is off until a year is typed")
        XCTAssertNotNil(window.element("duo.agegate.cancel"), "a way out without answering")
        XCTAssertFalse(window.elements().contains { $0.traits.contains(.adjustable) }, "no wheel")
        XCTAssertFalse(window.labels().contains { $0.hasPrefix("Born in") })
        XCTAssertTrue(window.textFields().count == 2, "only month and year: no name is asked before the age")
    }

    func testContinueDismissesTheMonthKeyboardBeforeConfirmation() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.type("1990", into: "duo.agegate.year")
        await window.type("10", into: "duo.agegate.month")
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect { window.shows("Born in October 1990?") }
        XCTAssertNil(window.textField("duo.agegate.month"))
        XCTAssertEqual(kit.store.ageStatus, .unknown)
    }

    func testContinueStaysOffUntilFourDigitsMakeAPlausibleYear() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        let nextYear = String(Calendar(identifier: .gregorian).component(.year, from: Date()) + 1)
        for text in ["1", "199", "abcd", "19a0", "    ", " 199", "1899", "0000", "9999", nextYear] {
            await window.type("1", into: "duo.agegate.month")
            await window.type(text, into: "duo.agegate.year")
            await window.expect(text) { window.textField("duo.agegate.year")?.text == DuoConsentFlow.limitedYearInput(text) }
            XCTAssertEqual(window.element("duo.agegate.continue")?.isEnabled, false, "\(text.debugDescription) keeps Continue off")
        }
        await window.type("1", into: "duo.agegate.month")
        await window.type("19905", into: "duo.agegate.year")
        await window.expect("the whole invalid paste stays visible") { window.textField("duo.agegate.year")?.text == "19905" }
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == false }
        for text in ["2019 ", "2019\n", "20199", "1990x"] {
            await window.type("1", into: "duo.agegate.month")
            await window.type(text, into: "duo.agegate.year")
            await window.expect { window.element("duo.agegate.continue")?.isEnabled == false }
            XCTAssertEqual(kit.store.ageStatus, .unknown)
            XCTAssertNil(kit.defaults.object(forKey: DuoCache.ageStatusKey))
        }
        XCTAssertEqual(kit.store.ageStatus, .unknown, "typing records nothing")
    }

    /// D80: every answer is asked about once more, and only the confirmation records it.
    func testATypedYearIsRecordedOnlyAfterItsConfirmationAndChangeGoesBack() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.type("1", into: "duo.agegate.month")
        await window.type("1990", into: "duo.agegate.year")
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect("the confirmation: \(window.labels())") { window.shows("Born in January 1990?") }
        XCTAssertTrue(window.element("duo.agegate.bornin")?.traits.contains(.header) ?? false)
        XCTAssertNotNil(window.element("duo.agegate.confirm"))
        XCTAssertEqual(window.element("duo.agegate.change")?.label, "Change")
        XCTAssertNil(window.textField("duo.agegate.year"), "the field is gone while the question is up")
        XCTAssertEqual(kit.store.ageStatus, .unknown, "nothing recorded yet")
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .unknown)
        XCTAssertNil(kit.defaults.object(forKey: DuoCache.ageStatusKey))

        window.tap("duo.agegate.change")
        await window.expect("Change goes back to the field, year kept") { window.textField("duo.agegate.year")?.text == "1990" }
        XCTAssertFalse(window.labels().contains { $0.hasPrefix("Born in") })
        XCTAssertEqual(kit.store.ageStatus, .unknown, "Change records nothing")

        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect { window.element("duo.agegate.confirm") != nil }
        window.tap("duo.agegate.confirm")
        await window.expect { kit.store.ageStatus == .allowed }
        await window.expect("the rules come next, before the form") { window.element("duo.terms.accept") != nil }
        XCTAssertTrue(kit.joining.calls.isEmpty, "nothing is sent for an age answer")
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    /// A child's year is asked about in the same words as anyone's, and the refusal that follows is
    /// final: the field never comes back, the bar has no Cancel, and Close closes the sheet.
    func testAChildYearIsConfirmedLikeAnyOtherThenRefusedForGood() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let presentation = IPresentation()
        let window = IWindow()
        defer { window.close() }
        await window.show(IPresenter(presentation: presentation, sheet: DuoSetupSheet(duoStore: kit.store) { _ in }))
        await window.expect { window.textField("duo.agegate.year") != nil }
        let year = IFixtures.childYear
        await window.type("1", into: "duo.agegate.month")
        await window.type(String(year), into: "duo.agegate.year")
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect { window.shows("Born in January \(year)?") }
        XCTAssertNotNil(window.element("duo.agegate.change"), "the same two buttons as for any year")
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        window.tap("duo.agegate.confirm")
        await window.expect("\(window.labels())") { window.shows("Duo Streaks is not available on this iPhone.") }
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertTrue(kit.dependencies.secrets.isAgeRefused(), "kept in the Keychain too, so deleting the app gives no second try")
        XCTAssertNil(window.textField("duo.agegate.year"), "the field never comes back")
        XCTAssertNil(window.element("duo.agegate.cancel"), "after a refusal Close is the one way out")
        XCTAssertEqual(kit.store.recordBirthYear(IFixtures.adultYear, month: 1), .refused, "no retry")

        window.tap("duo.agegate.close")
        await window.expect("Close closes the sheet") { !presentation.isPresented }
        XCTAssertTrue(kit.joining.calls.isEmpty)
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    /// Decision b: born in this very month thirteen years ago is "not yet": the screen says to try
    /// again next month, Close closes, and nothing is kept anywhere.
    func testTheThirteenthBirthdayMonthSaysNotYetAndKeepsNothing() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let presentation = IPresentation()
        let window = IWindow()
        defer { window.close() }
        await window.show(IPresenter(presentation: presentation, sheet: DuoSetupSheet(duoStore: kit.store) { _ in }))
        await window.expect { window.textField("duo.agegate.year") != nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let parts = gregorian.dateComponents([.year, .month], from: Date())
        await window.type(String(parts.month!), into: "duo.agegate.month")
        await window.type(String(parts.year! - 13), into: "duo.agegate.year")
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect { window.element("duo.agegate.confirm") != nil }
        window.tap("duo.agegate.confirm")
        await window.expect("\(window.labels())") { window.shows(DuoConsentFlow.NewCopy.ageNotYet) }
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .unknown)
        XCTAssertFalse(kit.dependencies.secrets.isAgeRefused())
        XCTAssertFalse(window.shows("Duo Streaks is not available on this iPhone."))
        window.tap("duo.agegate.close")
        await window.expect("Close closes the sheet") { !presentation.isPresented }
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    /// Finding 7: an error drawn in place is said to VoiceOver as it appears.
    func testAnErrorDrawnInPlaceIsSpoken() async {
        var spoken: [String] = []
        let post = DuoVoiceOver.post
        DuoVoiceOver.post = { spoken.append($0) }
        defer { DuoVoiceOver.post = post }
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoTermsSheet(onAccept: {}, onCancel: {}, message: DuoUserMessage.generic, isWorking: false))
        await window.expect { window.element("duo.terms.message") != nil }
        XCTAssertEqual(spoken, [DuoUserMessage.generic])
    }

    func testARefusalOnOneKitIsStillARefusalOnASecondOverTheSameKeychain() async {
        let keychain = DuoMemorySecretStore()
        _ = await iKit(age: .refused, termsAccepted: false, secretStore: keychain)
        // A second kit over the same Keychain and fresh defaults: the app deleted and installed again.
        let reinstalled = DuoTestKit(secretStore: keychain)
        XCTAssertEqual(reinstalled.store.ageStatus, .refused, "the store reads the Keychain at install")
        // Neither Delete my Duo data nor Start fresh takes it away.
        reinstalled.store.resetLocalState()
        reinstalled.store.forgetAnAllowedAge()
        XCTAssertEqual(reinstalled.store.ageStatus, .refused)
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: reinstalled.store) { _ in })
        await window.expect("straight on the refusal") { window.shows("Duo Streaks is not available on this iPhone.") }
        XCTAssertNil(window.textField("duo.agegate.year"))
        XCTAssertNotNil(window.element("duo.agegate.close"))
    }

    /// Review 1 L2: a process that started before the first unlock could not read the Keychain and
    /// said "unknown". The gate asks again when it appears.
    func testARefusalKeptOnlyInTheKeychainIsFoundWhenTheScreenAppears() async throws {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        try kit.dependencies.secrets.markAgeRefused()
        XCTAssertEqual(kit.store.ageStatus, .unknown, "memory has not heard")
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.expect("\(window.labels())") { window.shows("Duo Streaks is not available on this iPhone.") }
        XCTAssertNil(window.textField("duo.agegate.year"), "the field is not offered to someone already refused")
    }

    func testAnUnreadableYearKeepsAsking() async {
        let kit = await iKit(age: .unknown, termsAccepted: false)
        let allowed = ICounter()
        let screen = DuoAgeGateView(duoStore: kit.store, onAllowed: { allowed.bump() }, onRefused: {})
        XCTAssertEqual(screen.answer(1800, month: 1), .unknown)
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        XCTAssertFalse(screen.showsRefusal)
        XCTAssertEqual(allowed.count, 0)
    }

    // MARK: The gate

    /// The form, which holds the only Create, Join or Reconnect button, is never even built for a
    /// person whose age is unknown or refused, or who has not accepted the rules.
    func testTheGateNeverBuildsTheFormForAnUnknownOrRefusedPerson() async {
        let cases: [(DuoAgeStatus, Bool, DuoConsentFlow.Step)] = [
            (.unknown, false, .askAge), (.unknown, true, .askAge), (.refused, false, .refused), (.refused, true, .refused),
            (.allowed, false, .terms), (.allowed, true, .form),
        ]
        for (age, terms, step) in cases {
            let kit = await iKit(age: age, termsAccepted: terms)
            let builds = ICounter()
            let gate = iGate(kit.store, closes: ICounter(), resends: ICounter(), builds: builds)
            XCTAssertEqual(gate.step, step, "\(age), terms \(terms)")
            let window = IWindow()
            await window.show(gate)
            if step == .form {
                XCTAssertTrue(window.shows("form"), "the control: a form that may show is drawn")
                XCTAssertGreaterThan(builds.count, 0)
            } else {
                XCTAssertFalse(window.shows("form"), "\(age), terms \(terms): no form on screen")
                XCTAssertEqual(builds.count, 0, "\(age), terms \(terms): the form must not be built, not even for a frame")
            }
            window.close()
        }
    }

    func testCreateIsNotReachableWhileTheAgeIsUnknownOrRefused() async {
        for age: DuoAgeStatus in [.unknown, .refused] {
            let kit = await iKit(age: age, termsAccepted: true)
            kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
            let window = IWindow()
            await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
            XCTAssertNil(window.element("duo.setup.create"), "\(age): no Create button on screen")
            let created = ICounter()
            let duo = await DuoSetupSheet(duoStore: kit.store) { _ in created.bump() }.create(named: "Jo")
            XCTAssertNil(duo)
            XCTAssertEqual(created.count, 0)
            XCTAssertTrue(kit.transport.calls.isEmpty, "\(age): and the service sends nothing for them either")
            window.close()
        }
    }

    func testAcceptingTheRulesInPlaceRecordsThemOnceAndBringsTheFormUp() async {
        let kit = await iKit(age: .allowed, termsAccepted: false)
        let window = IWindow(height: 1400)
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        XCTAssertTrue(window.shows("Duo Streaks rules"), "the rules sheet's title")
        for rule in DuoConsentFlow.termsRules { XCTAssertTrue(window.shows(rule), rule) }
        XCTAssertEqual(window.element("duo.terms.line")?.label, "By tapping Accept you agree to the Duo Streaks rules.")
        XCTAssertEqual(window.element("duo.terms.link")?.label, "Read the full rules")
        XCTAssertTrue(window.element("duo.terms.link")?.traits.contains(.link) ?? false)
        XCTAssertNil(window.textField("duo.setup.name"), "no name is asked before the rules are accepted")

        window.tap("duo.terms.accept")
        _ = window.element("duo.terms.accept")?.object.accessibilityActivate()
        await window.expect("the form comes up") { window.textField("duo.setup.name") != nil }
        XCTAssertEqual(kit.joining.calls, ["acceptTerms"], "one Accept, however many taps, and nothing sent again")
        XCTAssertEqual(kit.store.acceptedTermsVersion, DuoProtocolConstants.termsVersion)
        XCTAssertEqual(kit.dependencies.cache.acceptedTermsVersion, DuoProtocolConstants.termsVersion, "what the mint sends as terms_version")
        XCTAssertFalse(kit.store.needsTerms)
    }

    /// The store records the rules the moment Accept is tapped, which makes the step `.form` while
    /// the service may still be telling the server; a Create tapped then would be refused without a
    /// word by the service's one-flow-at-a-time guard, so the rules stay up until it has finished.
    func testTheRulesStayUpAndSayTheyAreWorkingWhileAnAcceptInPlaceIsStillOut() async {
        let kit = await iKit(age: .allowed, termsAccepted: false)
        let held = IHeldJoining(holding: .acceptTerms)
        kit.dependencies.joining = held
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        window.tap("duo.terms.accept")
        await window.expect { held.entered == 1 }
        XCTAssertEqual(kit.store.acceptedTermsVersion, DuoProtocolConstants.termsVersion, "recorded at the tap")
        await window.expect("a busy value VoiceOver reads") { window.element("duo.terms.accept")?.value == "In progress" }
        XCTAssertEqual(window.element("duo.terms.accept")?.isEnabled, false, "and no second tap")
        XCTAssertNil(window.textField("duo.setup.name"), "the form waits for the Accept to finish")
        held.release()
        await window.expect { window.textField("duo.setup.name") != nil }
        XCTAssertEqual(held.entered, 1)
    }

    /// Review 1 A8: a Cancel that recorded acceptance in a Task passed, because the test looked
    /// before the Task ran. This one looks after the sheet has gone.
    func testCancellingTheRulesInPlaceClosesTheSheetAndRecordsNothing() async {
        let kit = await iKit(age: .allowed, termsAccepted: false)
        let presentation = IPresentation()
        let window = IWindow()
        defer { window.close() }
        await window.show(IPresenter(presentation: presentation, sheet: DuoSetupSheet(duoStore: kit.store) { _ in }))
        await window.expect { window.element("duo.terms.cancel") != nil }
        window.tap("duo.terms.cancel")
        await window.expect("Cancel closes the sheet") { !presentation.isPresented && window.presented == nil }
        XCTAssertEqual(kit.store.acceptedTermsVersion, 0)
        XCTAssertEqual(kit.dependencies.cache.acceptedTermsVersion, 0)
        XCTAssertTrue(kit.joining.calls.isEmpty)
    }

    func testARefusedPersonCannotAcceptTheRules() async {
        let kit = await iKit(age: .refused, termsAccepted: false)
        let model = DuoConsentGateModel()
        iGate(kit.store, closes: ICounter(), resends: ICounter(), model: model).inPlaceTerms(model).onAccept()
        await model.acceptance?.value
        XCTAssertEqual(kit.store.acceptedTermsVersion, 0)
        XCTAssertTrue(kit.joining.calls.isEmpty)
    }

    /// The whole 428 round trip on screen, through the sheet's own buttons and the real joining
    /// service: Create meets `428`, the rules come up over the form with the name kept, Accept
    /// tells the server, and Create goes once more, once the rules sheet has gone.
    func testA428BringsTheRulesBackAndAcceptSendsThisSheetsCreateAgain() async {
        let (kit, creates) = await i428Kit()
        var created: [DuoState] = []
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { created.append($0) })
        await window.type(" Jo", into: "duo.setup.name")
        window.tap("duo.setup.create")
        await window.expect("the rules over the form") { window.presented != nil && window.element("duo.terms.accept") != nil }
        XCTAssertNil(kit.store.sheetError, "the rules come up, not an error")
        XCTAssertEqual(window.presented?.isModalInPresentation, true, "the rules sheet cannot be swiped away")
        XCTAssertEqual(creates.value, 1)
        window.tap("duo.terms.accept")
        await window.expect("Create went again and its duo was handed on") { created.count == 1 }
        XCTAssertNil(window.presented)
        XCTAssertEqual(created.map(\.id), [IFixtures.createdID])
        let sent = kit.transport.calls.compactMap { call -> String? in
            switch call {
            case .createDuo(let request, _): return "createDuo:\(request.displayName ?? "nil")"
            case .updateMe(let request): return request.termsVersion == .value(1) ? "terms" : "updateMe"
            default: return nil
            }
        }
        XCTAssertEqual(sent, ["createDuo:Jo", "terms", "createDuo:Jo"], "the second Create carries the name typed before the rules came up")
    }

    /// Review 3 A19: the failed Accept's words reach the rules sheet, which stays up.
    func testAFailedAcceptOverTheFormKeepsTheRulesUpAndSaysWhy() async {
        let (kit, creates) = await i428Kit()
        kit.transport.onUpdateMe = { _ in throw DuoTransportError.offline }
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        window.tap("duo.setup.create")
        await window.expect { window.element("duo.terms.accept") != nil }
        window.tap("duo.terms.accept")
        let words = DuoUserMessage.text(for: DuoTransportError.offline, context: .general)
        await window.expect("\(window.labels())") { window.element("duo.terms.message")?.label == words }
        XCTAssertNotNil(window.presented, "the rules stay up")
        await window.expect("and take another tap") { window.element("duo.terms.accept")?.isEnabled == true }
        XCTAssertEqual(creates.value, 1, "nothing sent again")
    }

    /// Cancel on the rules over the form takes the rules away, then closes the sheet, one sheet at
    /// a time (review 3 A14).
    func testCancellingTheRulesAgainClosesTheSheetOnceTheyHaveGone() async {
        let (kit, creates) = await i428Kit()
        let presentation = IPresentation()
        let window = IWindow()
        defer { window.close() }
        await window.show(IPresenter(presentation: presentation, sheet: DuoSetupSheet(duoStore: kit.store) { _ in }))
        await window.expect { window.element("duo.setup.create") != nil }
        window.tap("duo.setup.create")
        await window.expect { window.element("duo.terms.cancel") != nil }
        window.tap("duo.terms.cancel")
        await window.expect("the consent sheet closes too") { !presentation.isPresented && window.presented == nil }
        XCTAssertEqual(creates.value, 1, "nothing sent again")
        XCTAssertFalse(kit.store.needsTerms)
    }

    func testACancelWhileAnAcceptIsOutNeverSendsTheRequestAgain() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        kit.store.needsTerms = true
        let closes = ICounter()
        let resends = ICounter()
        let model = DuoConsentGateModel()
        let gate = iGate(kit.store, closes: closes, resends: resends, model: model)
        model.gateAppeared()
        gate.termsAgain(model).onAccept()
        gate.termsAgain(model).onCancel()
        gate.termsAgainGone(model)
        await model.acceptance?.value
        gate.termsAgainGone(model)
        XCTAssertEqual(closes.count, 1)
        XCTAssertEqual(resends.count, 0, "the person cancelled; their Accept finishing later sends nothing")
    }

    /// Review 3 M1: Create is tapped, the sheet is closed while it is out, and the answer is a
    /// `428`. The next consent sheet must not open with the rules up, and nothing it shows may send
    /// a request nobody tapped there.
    func testALate428NeverMakesTheNextSheetSendARequestNobodyTapped() async {
        let kit = await iKit(age: .allowed, termsAccepted: true, credential: DuoFixtures.credential())
        let held = IHeldIdentity(credential: DuoFixtures.credential())
        kit.dependencies.identity = held
        kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
        let creates = IBox(0)
        kit.transport.onCreateDuo = { _, _ in
            creates.value += 1
            if creates.value == 1 { throw IFixtures.termsRequired }
            return IFixtures.createResponse
        }
        kit.transport.onUpdateMe = { _ in IFixtures.member }
        let created = ICounter()

        let first = IWindow()
        let firstModel = DuoConsentGateModel()
        await first.show(DuoSetupSheet(duoStore: kit.store, onCreated: { _ in created.bump() }, gateModel: firstModel))
        first.tap("duo.setup.create")
        await first.expect("the Create is out") { held.entered == 1 }
        first.close()                     // the person cancels while it is out
        await first.expect("the sheet has gone") { firstModel.hasGone }
        held.release()
        await first.expect("the 428 landed after the sheet had gone") { kit.store.needsTerms && !kit.store.isWorking }
        kit.store.sheetError = DuoUserMessage.generic       // and a stray failure from it, say

        let second = IWindow()
        defer { second.close() }
        let secondModel = DuoConsentGateModel()
        await second.show(DuoSetupSheet(duoStore: kit.store, onCreated: { _ in created.bump() }, gateModel: secondModel))
        await second.expect { second.textField("duo.setup.name") != nil }
        await second.expect("the stale flag is put down when the form appears") { !kit.store.needsTerms }
        XCTAssertNil(second.presented, "no rules over a form nobody has tapped")
        XCTAssertEqual(secondModel.termsAgainPresentations, 0, "not even for a moment")
        XCTAssertNil(kit.store.sheetError, "and no stale failure either")
        XCTAssertNil(second.element("duo.setup.error"))
        XCTAssertEqual(creates.value, 1)
        XCTAssertEqual(created.count, 0)
    }

    /// Even with the rules up over a live form for a flag this form did not raise, Accept sends no
    /// Create: only a Create this sheet sent and the server refused is sent again.
    func testAcceptSendsOnlyACreateThisSheetSentAndTheServerRefused() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.expect { window.textField("duo.setup.name") != nil }
        kit.store.needsTerms = true      // raised by something other than this sheet's Create
        await window.expect { window.element("duo.terms.accept") != nil }
        window.tap("duo.terms.accept")
        await window.expect { window.presented == nil }
        _ = await window.until(0.5) { kit.joining.calls.count > 1 }
        XCTAssertEqual(kit.joining.calls, ["acceptTerms"], "no Create nobody tapped")
    }

    /// Review 3 L4 (I5): the parent closes the sheet just after a successful Accept, while the rules
    /// sheet is still on its way out. Nothing is sent again after the sheet has gone.
    func testNothingIsSentAgainOnceTheSheetHasGone() async {
        let (kit, creates) = await i428Kit()
        let created = ICounter()
        let model = DuoConsentGateModel()
        let window = IWindow()
        await window.show(DuoSetupSheet(duoStore: kit.store, onCreated: { _ in created.bump() }, gateModel: model))
        window.tap("duo.setup.create")
        await window.expect { window.element("duo.terms.accept") != nil }
        model.acceptOverForm(kit.store)
        await model.acceptance?.value
        window.close()                   // the parent closes the consent sheet in the same moment
        _ = await window.until(1) { creates.value > 1 }
        XCTAssertEqual(creates.value, 1, "no Create after the sheet has gone")
        XCTAssertEqual(created.count, 0)
        XCTAssertTrue(model.hasGone)
    }

    /// I5, each guard on its own: a gate that has gone neither sends again nor closes anything, and a
    /// sheet that has gone sends no Create.
    func testAGoneGateSendsNothingAgainAndAGoneSheetSendsNoCreate() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        kit.store.needsTerms = true
        let closes = ICounter()
        let resends = ICounter()
        let model = DuoConsentGateModel()
        let gate = iGate(kit.store, closes: closes, resends: resends, model: model)
        model.gateAppeared()
        gate.termsAgain(model).onAccept()
        await model.acceptance?.value
        model.gateGone()
        gate.termsAgainGone(model)
        XCTAssertEqual(resends.count, 0, "the rules sheet torn down with its gate sends nothing again")
        kit.store.needsTerms = true
        model.gateAppeared()
        gate.termsAgain(model).onCancel()
        model.gateGone()
        gate.termsAgainGone(model)
        XCTAssertEqual(closes.count, 0, "nor closes a sheet that has already gone")
        model.gateAppeared()
        kit.store.needsTerms = true
        gate.termsAgain(model).onCancel()
        gate.termsAgainGone(model)
        XCTAssertEqual(closes.count, 1, "the control: while it is on screen, Cancel closes")

        let goneModel = DuoConsentGateModel()
        goneModel.gateAppeared()
        goneModel.gateGone()
        kit.joining.createResult = DuoFixtures.duo(joined: false)
        let made = await DuoSetupSheet(duoStore: kit.store, onCreated: { _ in resends.bump() }, gateModel: goneModel).create(named: "Jo")
        XCTAssertNil(made)
        XCTAssertFalse(kit.joining.calls.contains { $0.hasPrefix("createDuo") }, "a sheet that has gone sends no Create")
    }

    /// A Create still out when the sheet goes may finish (the duo is the person's, and the card
    /// shows it), but it is not handed on to a caller that has moved on.
    func testADuoMadeAfterTheSheetHasGoneIsNotHandedOn() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let held = IHeldJoining(holding: .createDuo)
        held.base.createResult = DuoFixtures.duo(joined: false)
        kit.dependencies.joining = held
        let created = ICounter()
        let model = DuoConsentGateModel()
        let window = IWindow()
        await window.show(DuoSetupSheet(duoStore: kit.store, onCreated: { _ in created.bump() }, gateModel: model))
        window.tap("duo.setup.create")
        await window.expect { held.entered == 1 }
        window.close()
        await window.expect { model.hasGone }
        held.release()
        _ = await window.until(1) { created.count > 0 }
        XCTAssertEqual(created.count, 0)
        XCTAssertEqual(held.base.calls.filter { $0.hasPrefix("createDuo") }.count, 1)
    }

    /// The join sheet shows the reconnect sheet, gate and all, for a reconnect code. Only the inner
    /// gate may bring the rules up again: its Accept sends its own form's request again, where the
    /// outer one's would send the join. Two sheets asked for at once would drop one.
    func testAGateInsideAnotherLeavesTheRulesSheetToTheInnerOne() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let outer = DuoConsentGateModel()
        let inner = DuoConsentGateModel()
        let innerGate = DuoConsentGate(duoStore: kit.store, onClose: {}, onTermsAccepted: {}, model: inner) {
            Text(verbatim: "inner form")
        }
        let outerGate = DuoConsentGate(duoStore: kit.store, onClose: {}, onTermsAccepted: {}, model: outer) {
            NavigationStack { innerGate }
        }
        let window = IWindow()
        defer { window.close() }
        await window.show(outerGate)
        await window.expect { outer.formIsLive && inner.formIsLive }
        kit.store.needsTerms = true
        XCTAssertFalse(outerGate.showsTermsAgain(outer), "the outer gate leaves the rules to the inner one")
        XCTAssertTrue(innerGate.showsTermsAgain(inner))
        await window.expect("brought up by the inner gate, whose Accept sends its own request again") { inner.termsAgainOnScreen }
        XCTAssertFalse(outer.termsAgainOnScreen)
        XCTAssertNil(window.presented?.presentedViewController, "once")
    }

    /// The registry on its own (I15): the deeper form is on top whatever order the two appear in
    /// (SwiftUI does not promise a parent's `onAppear` before its child's), and at equal depth the
    /// later one is; a form that has gone, or never appeared, is not on top.
    func testTheDeeperFormIsOnTopWhateverOrderTheyAppearIn() {
        let forms = DuoConsentForms()
        let outer = DuoConsentGateModel()
        let inner = DuoConsentGateModel()
        XCTAssertFalse(forms.isTopmost(outer), "nothing has appeared")
        forms.appeared(inner, depth: 1)
        forms.appeared(outer, depth: 0)
        XCTAssertTrue(forms.isTopmost(inner), "the inner form appeared first and is still on top")
        XCTAssertFalse(forms.isTopmost(outer))
        forms.gone(inner)
        XCTAssertTrue(forms.isTopmost(outer), "and once it has gone the outer one is")
        let pushed = DuoConsentGateModel()
        forms.appeared(pushed, depth: 0)
        XCTAssertTrue(forms.isTopmost(pushed), "at the same depth (a push the environment does not reach), the later one")
        XCTAssertFalse(forms.isTopmost(DuoConsentGateModel()), "a form that never appeared is not on top")
    }

    /// An Accept in place answers no refused request, so it never calls `onTermsAccepted`, whatever
    /// sheet the gate is in (a sheet without the setup sheet's own guard would send).
    func testAnAcceptInPlaceNeverAsksForARequestToBeSentAgain() async {
        let kit = await iKit(age: .allowed, termsAccepted: false)
        let resends = ICounter()
        let closes = ICounter()
        let window = IWindow()
        defer { window.close() }
        await window.show(iGate(kit.store, closes: closes, resends: resends))
        window.tap("duo.terms.accept")
        await window.expect("the form comes up") { window.shows("form") }
        _ = await window.until(0.5) { resends.count > 0 }
        XCTAssertEqual(resends.count, 0)
        XCTAssertEqual(closes.count, 0)
    }

    /// Nested the other way round (a gate inside a `NavigationStack` that pushes another gate, where
    /// the environment does not reach), the pushed one still owns the rules (I15).
    func testAGatePushedInsideANavigationStackStillOwnsTheRules() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let path = IPath()
        let outer = DuoConsentGateModel()
        let inner = DuoConsentGateModel()
        let window = IWindow()
        defer { window.close() }
        await window.show(IWrongNesting(path: path, store: kit.store, outer: outer, inner: inner))
        await window.expect { outer.formIsLive }
        path.path = [1]
        await window.expect { inner.formIsLive }
        kit.store.needsTerms = true
        await window.expect("the pushed gate, the one tapped, brings the rules up") { inner.termsAgainOnScreen }
        XCTAssertFalse(outer.termsAgainOnScreen)
        kit.store.needsTerms = false
        await window.expect { window.presented == nil }
        path.path = []
        await window.expect { !inner.formIsLive }
        kit.store.needsTerms = true
        await window.expect("popped: the outer gate takes the rules back") { outer.termsAgainOnScreen }
    }

    // MARK: The setup sheet

    func testCreateSendsTheTrimmedNameOnceAndHandsOnTheDuo() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let duo = DuoFixtures.duo(joined: false)
        kit.joining.createResult = duo
        var created: [DuoState] = []
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { created.append($0) })
        await window.type("   Jo  ", into: "duo.setup.name")
        // What the field shows is written back by SwiftUI as the person types ("Jo " here); in this
        // in-process harness that write-back is timing-dependent, so what is held is what is sent.
        _ = await window.until(0.3) { false }
        XCTAssertTrue(kit.joining.calls.isEmpty, "typing sends nothing")
        XCTAssertEqual(kit.store.myDisplayName, "", "and keeps nothing before the tap")
        window.tap("duo.setup.create")
        await window.expect { created.count == 1 }
        XCTAssertEqual(created.map(\.id), [duo.id])
        XCTAssertEqual(kit.joining.calls.filter { $0.hasPrefix("createDuo") }, ["createDuo:Jo:classic"])

        let empty = await DuoSetupSheet(duoStore: kit.store) { _ in }.create(named: "  \n ")
        XCTAssertEqual(empty?.id, duo.id)
        XCTAssertEqual(kit.joining.calls.filter { $0.hasPrefix("createDuo") }.last, "createDuo:nil:classic", "an empty name is no name")
    }

    func testAFailedCreateHandsOnNothingAndSaysWhy() async {
        let kit = await iKit(age: .allowed, termsAccepted: true, credential: DuoFixtures.credential())
        kit.identity.launch = .ready
        kit.dependencies.joining = DuoJoiningService(dependencies: kit.dependencies)
        kit.transport.onCreateDuo = { _, _ in throw DuoTransportError.offline }
        let created = ICounter()
        let window = IWindow(height: 1400)
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in created.bump() })
        window.tap("duo.setup.create")
        let words = DuoUserMessage.text(for: DuoTransportError.offline, context: .invite)
        await window.expect("\(window.labels())") { window.element("duo.setup.error")?.label == words }
        XCTAssertEqual(created.count, 0)
        window.close()
        await window.expect("the service's words go with the sheet that showed them") { kit.store.sheetError == nil }
    }

    /// Review 3 A16 / review 1 A15, I10, I11: Create is off while its request is out (and says so to
    /// VoiceOver) and while writes are off, and a disabled Create shows one line, the banner.
    func testCreateIsOffWhileWorkingOrWhenWritesAreOffAndSaysWhyOnce() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let window = IWindow(height: 1400)
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.expect("the control: Create works") { window.element("duo.setup.create")?.isEnabled == true }
        XCTAssertEqual(window.element("duo.setup.create")?.label, "Create and invite")

        kit.store.isWorking = true
        await window.expect { window.element("duo.setup.create")?.isEnabled == false }
        XCTAssertEqual(window.element("duo.setup.create")?.value, "In progress")
        XCTAssertEqual(window.element("duo.setup.create")?.label, "Create and invite", "the name is still spoken")
        kit.store.isWorking = false

        for state: DuoAvailability in [.disconnected, .banned, .upgradeRequired] {
            kit.store.availability = state
            kit.store.sheetError = DuoUserMessage.generic
            let banner = state.bannerMessage ?? ""
            await window.expect("\(state)") { window.element("duo.setup.unavailable")?.label == banner }
            XCTAssertEqual(window.element("duo.setup.create")?.isEnabled, false, "\(state)")
            XCTAssertNil(window.element("duo.setup.error"), "\(state): no 'Please try again.' beside a button that cannot be tapped")
            kit.store.sheetError = banner
            await window.expect("\(state): said once") { window.labels().filter { $0 == banner }.count == 1 }
        }
        kit.store.availability = .available
        kit.store.sheetError = nil
        await window.expect { window.element("duo.setup.create")?.isEnabled == true }
    }

    /// What is said before the tap, on screen: every line, in two sections, each link in a row of its
    /// own (review 1 A21, A32; I6 to I8).
    func testTheExplainerSaysEverythingAndEachLinkHasItsOwnRow() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        let window = IWindow(height: 2000)
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.expect { window.element("duo.explainer.privacy") != nil }
        XCTAssertTrue(window.shows("What your partner sees"))
        for case .shared(let line, _) in DuoConsentFlow.explainerShared(.setup) { XCTAssertTrue(window.shows(line), line) }
        for case .note(let line) in DuoConsentFlow.explainerNotes { XCTAssertTrue(window.shows(line), line) }
        XCTAssertTrue(window.shows(DuoCopy.partnerSeesFooter))
        let rules = window.element("duo.explainer.terms")
        let privacy = window.element("duo.explainer.privacy")
        XCTAssertEqual(rules?.label, "Duo Streaks rules")
        XCTAssertEqual(privacy?.label, "Privacy Policy")
        XCTAssertTrue(rules?.traits.contains(.link) ?? false)
        XCTAssertTrue(privacy?.traits.contains(.link) ?? false)
        // Each link is its own row: neither frame takes in the lines above it.
        let notes = window.elements().first { $0.label == DuoConsentFlow.NewCopy.processors }
        XCTAssertNotNil(notes)
        if let rules, let privacy, let notes {
            XCTAssertNotNil(rules.row)
            XCTAssertFalse(rules.row === notes.row, "the rules link is a row of its own, not part of the notes' row")
            XCTAssertFalse(privacy.row === rules.row, "and so is the privacy policy's")
            XCTAssertFalse(privacy.row === notes.row)
        }
        // The notes are in a section of their own, below the shared lines.
        let lastShared = window.elements().first { $0.label == "Never what you drank or exactly how much" }
        let honesty = window.elements().first { $0.label == DuoCopy.honestyLineStored }
        XCTAssertNotNil(lastShared)
        XCTAssertNotNil(honesty)
        if let lastShared, let honesty {
            XCTAssertGreaterThan(honesty.frame.minY - lastShared.frame.maxY, 20, "a gap between the two sections")
        }
    }

    func testTheNameFieldIsPrefilledAndNeitherCorrectedNorOddlyCapitalised() async {
        let kit = await iKit(age: .allowed, termsAccepted: true)
        kit.store.myDisplayName = "Jo"
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: kit.store) { _ in })
        await window.expect { window.textField("duo.setup.name") != nil }
        XCTAssertEqual(window.textField("duo.setup.name")?.text, "Jo", "prefilled from the name typed last time")
        XCTAssertEqual(window.textField("duo.setup.name")?.autocorrectionType, .no)
        XCTAssertEqual(window.textField("duo.setup.name")?.autocapitalizationType, .words)
    }

    /// Meant to fail the day any of these screens sends, attests, asks DeviceCheck or writes the
    /// Keychain on its own. The sheet is on screen over the fully composed app at every step, the
    /// age screen answered through its own field and buttons, the rules accepted through theirs,
    /// and nothing may happen until Create is tapped; then the tap must reach the server, which
    /// shows the harness would have seen anything sent earlier.
    func testTheSetupSheetSendsNothingUntilTheTapThroughTheComposedApp() async throws {
        let app = try IComposed()
        defer { app.removeFolder() }
        app.store.myDisplayName = "Jo"
        let created = ICounter()
        let window = IWindow()
        await window.show(DuoSetupSheet(duoStore: app.store) { _ in created.bump() })
        app.nothingYet("the age screen")
        await window.type("1", into: "duo.agegate.month")
        await window.type("1990", into: "duo.agegate.year")
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect { window.element("duo.agegate.confirm") != nil }
        app.nothingYet("the confirmation")
        XCTAssertEqual(app.store.ageStatus, .unknown, "nothing recorded before the confirmation")
        XCTAssertNil(app.defaults.object(forKey: DuoCache.ageStatusKey))
        window.tap("duo.agegate.confirm")
        await window.expect { window.element("duo.terms.accept") != nil }
        app.nothingYet("the rules")
        window.tap("duo.terms.accept")
        await window.expect { window.textField("duo.setup.name") != nil }
        app.nothingYet("the form")
        await window.type("Sam", into: "duo.setup.name")
        _ = await window.until(0.5) { !app.session.requests.isEmpty }
        app.nothingYet("a name typed")
        XCTAssertEqual(created.count, 0)

        // The same person opening the sheet another day: it opens straight on the form, so
        // whatever the sheet itself runs on appear would run now, past the age and the rules.
        window.close()
        let again = IWindow()
        defer { again.close() }
        await again.show(DuoSetupSheet(duoStore: app.store) { _ in created.bump() })
        await again.expect("the form is up") { again.textField("duo.setup.name") != nil }
        _ = await again.until(0.5) { !app.session.requests.isEmpty }
        app.nothingYet("a sheet opened on the form")

        // The tap. Nothing answers (the session is offline), but the request is seen.
        again.tap("duo.setup.create")
        await again.expect("the control: the tap's request reaches the session") { !app.session.requests.isEmpty }
    }

    func testARefusedPersonsSheetSendsNothingAndKeepsOnlyTheRefusal() async throws {
        let app = try IComposed()
        defer { app.removeFolder() }
        let window = IWindow()
        defer { window.close() }
        await window.show(DuoSetupSheet(duoStore: app.store) { _ in })
        await window.type("1", into: "duo.agegate.month")
        await window.type(String(IFixtures.childYear), into: "duo.agegate.year")
        await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
        window.tap("duo.agegate.continue")
        await window.expect { window.element("duo.agegate.confirm") != nil }
        XCTAssertTrue(app.keychain.writes.isEmpty, "nothing kept before the confirmation")
        window.tap("duo.agegate.confirm")
        await window.expect { window.element("duo.agegate.refusal") != nil }
        XCTAssertTrue(window.textFields().isEmpty, "no form, so no name field")
        _ = await DuoSetupSheet(duoStore: app.store) { _ in }.create(named: "Jo")
        _ = await app.store.acceptTerms()
        XCTAssertTrue(app.session.requests.isEmpty)
        XCTAssertEqual(app.deviceCheck.calls, 0)
        // The spy reads nothing back, so every refusal check writes the refusal again: one item, however often.
        XCTAssertEqual(Set(app.keychain.writes), ["\(DuoSecrets.ageService)/\(DuoSecrets.ageRefusedAccount)"], "the refusal, and nothing else")
    }

    // MARK: Layout

    /// Every state on a real screen, in light and dark and at the largest text size, checked so a
    /// layout that collapses fails: what the state must say is on screen, inside the window, no two
    /// pieces of text overlap, and nothing is cut short with an ellipsis. With
    /// `DUO_STAGE_I_SNAPSHOTS` set, each state is also saved to be looked at.
    func testEveryStateLaysOutWithoutOverlapOrTruncationInLightDarkAndTheLargestText() async {
        typealias State = (name: String, store: DuoStore, mustShow: [String])
        func states() async -> [State] {
            var all: [State] = []
            all.append(("1-age", await iKit(age: .unknown, termsAccepted: false).store, ["Before you start", "Continue"]))
            all.append(("1b-born-in", await iKit(age: .unknown, termsAccepted: false).store, ["Born in January 1990?", "Continue", "Change"]))
            all.append(("2-refused", await iKit(age: .refused, termsAccepted: false).store, ["Duo Streaks is not available on this iPhone.", "Close"]))
            all.append(("3-terms", await iKit(age: .allowed, termsAccepted: false).store, ["Duo Streaks rules", "Accept", "Cancel"]))
            let form = await iKit(age: .allowed, termsAccepted: true).store
            form.myDisplayName = "Jo"
            all.append(("4-form", form, ["Start a duo streak", "Create and invite", "What your partner sees"]))
            let blocked = await iKit(age: .allowed, termsAccepted: true).store
            blocked.availability = .disconnected
            all.append(("5-disconnected", blocked, ["This phone was disconnected from the duo", "Create and invite"]))
            let working = await iKit(age: .allowed, termsAccepted: true).store
            working.isWorking = true
            all.append(("6-working", working, ["Create and invite"]))
            return all
        }
        // Windows stay under 2,730 points tall: drawn at three times, a taller one is beyond what one
        // image can hold, and the capture comes out blank.
        let looks: [(String, Bool, DynamicTypeSize, CGFloat)] = [("light", false, .large, 2000), ("dark", true, .large, 2000), ("ax5", false, .accessibility5, 2700)]
        for (look, dark, size, height) in looks {
            for state in await states() {
                let window = IWindow(dark: dark, height: height)
                await window.show(DuoSetupSheet(duoStore: state.store) { _ in }, typeSize: size)
                if state.name == "1b-born-in" {
                    await window.type("1", into: "duo.agegate.month")
                    await window.type("1990", into: "duo.agegate.year")
                    await window.expect { window.element("duo.agegate.continue")?.isEnabled == true }
                    window.tap("duo.agegate.continue")
                }
                // What the state must say, at the top or, for a form taller than the window (the
                // largest text), once scrolled to its end.
                _ = await window.until { state.mustShow.allSatisfy(window.shows) }
                var seen = Set(window.labels())
                // A list sizes rows it has not built by estimate, so its end moves as it scrolls:
                // scroll until nothing new turns up.
                var scrolls = 0
                while !state.mustShow.allSatisfy(seen.contains), scrolls < 8 {
                    window.scrollToBottom()
                    _ = await window.until(0.5) { state.mustShow.allSatisfy { seen.contains($0) || window.shows($0) } }
                    let before = seen.count
                    seen.formUnion(window.labels())
                    scrolls += 1
                    if seen.count == before, scrolls > 2 { break }
                }
                for text in state.mustShow {
                    XCTAssertTrue(seen.contains(text), "\(look) \(state.name): \(text) on screen: \(seen.sorted())")
                }
                let texts = window.elements().filter { !$0.label.isEmpty && $0.frame.width > 0 }
                for element in texts {
                    // Nothing spills past the sides; anything below the window is a scroll away.
                    XCTAssertGreaterThanOrEqual(element.frame.minX, window.window.frame.minX - 1, "\(look) \(state.name): \(element.label)")
                    XCTAssertLessThanOrEqual(element.frame.maxX, window.window.frame.maxX + 1, "\(look) \(state.name): \(element.label) inside the window")
                    XCTAssertGreaterThan(element.frame.height, 4, "\(look) \(state.name): \(element.label) has a height")
                }
                let plain = texts.filter { !$0.traits.contains(.button) && !$0.traits.contains(.link) && !$0.traits.contains(.header) }
                for (index, a) in plain.enumerated() {
                    for b in plain.dropFirst(index + 1) where a.frame.insetBy(dx: 1, dy: 1).intersects(b.frame.insetBy(dx: 1, dy: 1)) {
                        if a.frame.contains(b.frame) || b.frame.contains(a.frame) { continue }   // a container and its own line
                        XCTFail("\(look) \(state.name): '\(a.label)' overlaps '\(b.label)'")
                    }
                }
                if look != "ax5" {
                    let read = window.readText()
                    XCTAssertFalse(read.isEmpty, "\(look) \(state.name): Vision reads the screen")
                    XCTAssertFalse(read.contains { $0.contains("…") }, "\(look) \(state.name): nothing cut short: \(read)")
                }
                window.snapshot("\(state.name)-\(look)")
                window.close()
            }
        }
    }
}

// MARK: - Nesting fixtures

@MainActor
fileprivate final class IPath: ObservableObject {
    @Published var path: [Int] = []
}

/// A gate put inside a `NavigationStack` whose destination is another gate: the reverse of the
/// nesting the consent sheets use, where the environment does not reach the pushed gate.
fileprivate struct IWrongNesting: View {
    @ObservedObject var path: IPath
    let store: DuoStore
    let outer: DuoConsentGateModel
    let inner: DuoConsentGateModel
    var body: some View {
        NavigationStack(path: $path.path) {
            DuoConsentGate(duoStore: store, onClose: {}, onTermsAccepted: {}, model: outer) {
                Text(verbatim: "outer form")
                    .navigationDestination(for: Int.self) { _ in
                        DuoConsentGate(duoStore: store, onClose: {}, onTermsAccepted: {}, model: inner) { Text(verbatim: "inner form") }
                    }
            }
        }
    }
}
#endif
