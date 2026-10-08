#if DUO_V2
import SwiftUI
import XCTest
@testable import HydroDrop

// MARK: - Test helpers (stage K)

/// Holds the redeem until the test lets it go, so a test can look at the sheet while a join is out.
fileprivate final class KGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var entries = 0

    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entries += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

/// `FakeDuoTransport` with every redeem held at a gate before it is sent (the fake's own handlers
/// cannot wait).
fileprivate final class KGatedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    let gate: KGate

    init(_ base: FakeDuoTransport, holdingRedeemsAt gate: KGate) {
        self.base = base
        self.gate = gate
    }

    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult {
        await gate.wait()
        return try await base.redeemInvite(request, key: key)
    }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await base.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await base.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse { try await base.me() }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await base.updateMe(request) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await base.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await base.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await base.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await base.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await base.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

fileprivate extension FakeDuoTransport {
    var kPeeks: [String] { calls.compactMap { if case .peekInvite(let code) = $0 { return code }; return nil } }
    var kRedeems: [DuoWireRedeemRequest] { calls.compactMap { if case .redeemInvite(let request, _) = $0 { return request }; return nil } }
}

fileprivate enum KFixtures {
    static let k = "ABCDEFGHJKMNPQRSTVWXYZ0123"
    static let expiry = Date(timeIntervalSince1970: 1_790_172_800)
    static let joinedID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c2")!
    static let prompt = DuoRestorePrompt(partnerName: "Sam", myName: "Jo")

    static var invite: DuoPendingInvite { DuoPendingInvite(code: "H7K39QWX", k: k, receivedAt: Date()) }

    static func peek(_ purpose: DuoPeek.Purpose, name: String? = "Alex", skin: String? = "forest", target: String? = nil) -> DuoPeek {
        DuoPeek(purpose: purpose, inviterName: name, inviterSkin: skin, targetName: target, expiresAt: expiry)
    }

    static let wirePeek = DuoWirePeekResponse(purpose: "invite", state: "open", expiresAt: expiry, inviterDisplayName: "Alex", inviterSkin: "forest")

    static let minted = DuoWireCreateDeviceResponse(memberId: "6d2a0000-0000-4000-8000-0000000000cc", deviceId: "6d2a0000-0000-4000-8000-0000000000dd",
                                                    deviceSecret: String(repeating: "t", count: 43), tier: .attested, supportId: "ABCD1234EFGH")

    static var redeemResult: DuoWireChangesWithResult {
        let changes = DuoWireChanges(duo: DuoFixtures.wireHeader(id: joinedID, role: .partner, state: .active, seq: 7), full: true,
                                     statuses: [], nudges: [], handled: [], cursor: 7)
        return DuoWireChangesWithResult(changes: changes, accepted: [], unchanged: [], rejected: [])
    }

    static func member(name: String?) -> DuoMemberInfo {
        DuoMemberInfo(memberID: DuoFixtures.credential().memberID, displayName: name, skin: "classic", supportID: "ABCD1234EFGH", tier: .attested,
                      termsVersion: 1, nudgesPerDay: 3, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: Date())
    }
}

/// Finds the first value under `value` (a view's body, say) whose type's name starts with `prefix`.
@MainActor
fileprivate func kFind(_ prefix: String, in value: Any, depth: Int = 0) -> Any? {
    if String(describing: type(of: value)).hasPrefix(prefix) { return value }
    guard depth < 40 else { return nil }
    for child in Mirror(reflecting: value).children {
        if let found = kFind(prefix, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// A closure stored under `label` in `value`.
@MainActor
fileprivate func kClosure(_ label: String, in value: Any) -> (() -> Void)? {
    Mirror(reflecting: value).children.first { $0.label == label }?.value as? () -> Void
}

/// Every text field in a view hierarchy.
@MainActor
fileprivate func kTextFields(in view: UIView) -> [UITextField] {
    var found: [UITextField] = []
    if let field = view as? UITextField { found.append(field) }
    for subview in view.subviews { found += kTextFields(in: subview) }
    return found
}

/// Holds whether the sheet in `KSheetHost` is presented.
@MainActor
fileprivate final class KPresented: ObservableObject {
    @Published var shown = false
}

/// Presents a join sheet the way the root does, as a sheet, so its dismissal and its
/// `interactiveDismissDisabled` can be read from UIKit.
fileprivate struct KSheetHost: View {
    @ObservedObject var presented: KPresented
    let sheet: DuoJoinSheet

    var body: some View {
        Color.clear.sheet(isPresented: $presented.shown) { sheet }
    }
}

/// The join sheet (stage K): what it draws for every plan, the one request it makes on its own (the
/// peek, once, and only for someone the birth-year screen let through), and the Join tap, which is
/// the consent and the first request that makes anything. Every decision is the model's, so these
/// drive the very methods the sheet calls and read the very rows it draws; a handful read the drawn
/// sheet itself (its body, its text field, its pixels) for what only the view does.
@MainActor
final class DuoJoinSheetTests: XCTestCase {
    private var kits: [DuoTestKit] = []
    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        windows = []
        // The kit's defaults suite is a throwaway; nothing of it is left behind.
        for kit in kits {
            for key in kit.defaults.dictionaryRepresentation().keys { kit.defaults.removeObject(forKey: key) }
        }
        kits = []
        super.tearDown()
    }

    /// A real store over fakes. `birthYear` nil leaves the age unknown; the rules are accepted on
    /// this phone unless `terms` is false, so the consent gate (stage I) shows the content.
    private func kKit(birthYear: Int? = 1990, terms: Bool = true, credential: DuoCredential? = nil) async -> DuoTestKit {
        let kit = DuoTestKit(credential: credential)
        kits.append(kit)
        if credential != nil { kit.identity.launch = .ready }
        if let birthYear { kit.store.recordBirthYear(birthYear) }
        if terms { _ = await kit.store.acceptTerms() }
        return kit
    }

    /// The same, with the real joining service in place of the fake, so a test sees the requests a
    /// tap really makes.
    private func kRealKit(credential: DuoCredential? = nil) async -> DuoTestKit {
        let kit = DuoTestKit(credential: credential)
        kits.append(kit)
        if credential != nil { kit.identity.launch = .ready }
        let service = DuoJoiningService(dependencies: kit.dependencies)
        service.holdInBackground = { _ in {} }
        kit.dependencies.joining = service
        kit.store.recordBirthYear(1990)
        _ = await kit.store.acceptTerms()
        kit.transport.onPeekInvite = { _ in KFixtures.wirePeek }
        kit.transport.onCreateDevice = { _ in KFixtures.minted }
        kit.transport.onRedeemInvite = { _, _ in KFixtures.redeemResult }
        return kit
    }

    /// The fake joining service's calls since `from`, to leave out what a kit's set-up asked.
    private func kCalls(_ kit: DuoTestKit, since from: Int) -> [String] { Array(kit.joining.calls.dropFirst(from)) }

    private func kWindow(_ controller: UIViewController) -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)
        return window
    }

    /// Puts the sheet in a window of its own, over the app this test bundle runs in, so its `.task`
    /// runs as it does on screen.
    private func kHost(_ sheet: DuoJoinSheet) -> UIWindow { kWindow(UIHostingController(rootView: sheet)) }

    /// Lets the run loop and the main actor turn until `condition` holds, for at most `seconds`.
    private func kSettle(_ seconds: Double = 3, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func kRender(_ view: some View) -> UIImage? {
        let renderer = ImageRenderer(content: AnyView(view))
        renderer.scale = 2
        return renderer.uiImage
    }

    // MARK: - Appearing

    func testAppearingPeeksOnceAndAsksNothingElse() async {
        let kit = await kKit()
        kit.joining.peekResult = KFixtures.peek(.invite)
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel()
        _ = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))

        let peeked = await kSettle { model.stage != .waiting }
        XCTAssertTrue(peeked, "the sheet's task never ran the peek")
        XCTAssertEqual(model.stage, .answered(KFixtures.peek(.invite)))
        // Redrawn, it does not ask again.
        kit.store.isWorking = true
        kit.store.sheetError = "x"
        _ = await kSettle(0.4) { false }
        XCTAssertEqual(kCalls(kit, since: before), ["peek:H7K39QWX"])
        // And nothing below the store was asked: no request, no identity.
        XCTAssertEqual(kit.transport.calls, [])
        XCTAssertEqual(kit.identity.prepared, 0)
    }

    func testThePeekIsAskedOnlyOnceForTheSheetsLife() async {
        let kit = await kKit()
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kCalls(kit, since: before), ["peek:H7K39QWX"])
    }

    func testASheetDrawnInAGivenStateNeverPeeks() async {
        // The drawn-state tests below hand the sheet a stage; it must not peek over it.
        let kit = await kKit()
        kit.joining.peekResult = KFixtures.peek(.invite)
        let before = kit.joining.calls.count
        for stage in [DuoJoinSheetModel.Stage.failed("x"), .answered(KFixtures.peek(.invite)), .reconnect] {
            let model = DuoJoinSheetModel(stage: stage)
            _ = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))
            await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        }
        _ = await kSettle(0.6) { false }
        XCTAssertEqual(kCalls(kit, since: before), [])
    }

    func testAnUnknownAgeNeverReachesThePeek() async {
        // The store's own peek refuses only a refusal, so here this sheet's rule is what holds.
        let kit = await kKit(birthYear: nil)
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kCalls(kit, since: before), [])
        XCTAssertEqual(model.stage, .waiting)

        _ = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))
        _ = await kSettle(0.6) { false }
        XCTAssertEqual(kCalls(kit, since: before), [])
        XCTAssertEqual(kit.transport.calls, [])

        // Once the birth-year screen says yes, the content that is up asks, once.
        kit.store.recordBirthYear(1990)
        let peeked = await kSettle { !kCalls(kit, since: before).isEmpty }
        XCTAssertTrue(peeked)
        XCTAssertEqual(kCalls(kit, since: before), ["peek:H7K39QWX"])
    }

    func testARefusedAgeNeverReachesThePeek() async {
        let kit = await kKit(birthYear: Calendar(identifier: .gregorian).component(.year, from: Date()) - 5)
        XCTAssertEqual(kit.store.ageStatus, .refused)
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        _ = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))
        _ = await kSettle(0.6) { false }
        XCTAssertEqual(kCalls(kit, since: before), [])
        XCTAssertEqual(kit.transport.calls, [])
        XCTAssertEqual(model.stage, .waiting)
    }

    func testACancelledPeekIsNotAFailureAndIsAskedAgain() async {
        let kit = await kKit()
        kit.joining.peekResult = nil
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel()
        let cancelled = Task { await model.peekIfNeeded(kit.store, invite: KFixtures.invite) }
        cancelled.cancel()
        await cancelled.value
        // Nothing went wrong that the person could act on: no words, no failure, no Close.
        XCTAssertEqual(model.stage, .waiting)
        XCTAssertNil(kit.store.sheetError)

        kit.joining.peekResult = KFixtures.peek(.invite)
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(model.stage, .answered(KFixtures.peek(.invite)))
        XCTAssertEqual(kCalls(kit, since: before), ["peek:H7K39QWX", "peek:H7K39QWX"])
    }

    // MARK: - A peek with no answer

    func testAFailedPeekShowsTheServicesWordsAndLeavesNoJoin() async {
        let kit = await kRealKit()
        kit.transport.onPeekInvite = { _ in throw DuoTransportError.inviteUnknown(DuoErrorContext(httpStatus: 404, requestID: "req-1")) }
        let model = DuoJoinSheetModel(name: "Ana")
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        let gone = "That invite is no longer open. Ask for a new one."
        XCTAssertEqual(model.stage, .failed(gone))
        XCTAssertFalse(model.offersJoin)
        // A code that is gone answers the same every time: Close only.
        XCTAssertEqual(model.rows(kit.store), [.failure(gone)])

        // The tap's method sends nothing after a failed peek: no identity, no redeem.
        await model.tapJoin(kit.store, invite: KFixtures.invite)
        XCTAssertFalse(model.wantsDismiss)
        XCTAssertEqual(kit.transport.kPeeks, ["H7K39QWX"])
        XCTAssertEqual(kit.transport.kRedeems.count, 0)
        XCTAssertFalse(kit.transport.calls.contains { if case .createDevice = $0 { return true }; return false })
    }

    func testABlockedPersonsPeekReadsAsAnyGoneCodeAndSendsNoRedeem() async {
        // D34: a phone with an identity peeks with its bearer, and a pair row the creator set answers
        // the same 404 as an expired code. The sheet says the 404's words and never who blocked whom.
        let kit = await kRealKit(credential: DuoFixtures.credential())
        kit.transport.onPeekInvite = { _ in throw DuoTransportError.inviteUnknown(DuoErrorContext(httpStatus: 404, requestID: "req-2")) }
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        guard case .failed(let text) = model.stage else { return XCTFail("\(model.stage)") }
        XCTAssertEqual(text, "That invite is no longer open. Ask for a new one.")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("block"))
        await model.tapJoin(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kit.transport.kRedeems.count, 0)
    }

    func testAFailureThatMayPassOffersTryAgainWhichAsksOnceMore() async {
        let kit = await kRealKit()
        kit.transport.onPeekInvite = { _ in throw DuoTransportError.offline }
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        let offline = "No connection right now. Try again in a bit."
        XCTAssertEqual(model.stage, .failed(offline))
        XCTAssertEqual(model.rows(kit.store), [.failure(offline), .tryAgain])
        XCTAssertFalse(model.closesWithNotNow)

        model.tryAgain()
        XCTAssertEqual(model.stage, .waiting)
        XCTAssertEqual(model.attempt, 1)
        kit.transport.onPeekInvite = { _ in KFixtures.wirePeek }
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kit.transport.kPeeks, ["H7K39QWX", "H7K39QWX"])
        XCTAssertTrue(model.offersJoin)
        // Only a failure is tried again.
        model.tryAgain()
        XCTAssertEqual(model.attempt, 1)
        XCTAssertTrue(model.offersJoin)
    }

    func testTryAgainOnTheDrawnSheetAsksTheServiceAgain() async {
        // The sheet's task is keyed on the attempt, so the button's model call reaches a new peek.
        let kit = await kKit()
        kit.joining.peekResult = nil
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel()
        _ = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))
        let failed = await kSettle { if case .failed = model.stage { return true }; return false }
        XCTAssertTrue(failed)
        kit.joining.peekResult = KFixtures.peek(.invite)
        model.tryAgain()
        let answered = await kSettle { model.stage == .answered(KFixtures.peek(.invite)) }
        XCTAssertTrue(answered, "Try again did not reach the peek: \(model.stage)")
        XCTAssertEqual(kCalls(kit, since: before), ["peek:H7K39QWX", "peek:H7K39QWX"])
    }

    func testOnlyADisconnectedFailureOffersIHadADuo() async {
        let kit = await kKit()
        let model = DuoJoinSheetModel(stage: .failed("That invite is no longer open. Ask for a new one."))
        for availability in [DuoAvailability.unknown, .available, .maintenance, .upgradeRequired, .banned] {
            kit.store.availability = availability
            XCTAssertFalse(model.rows(kit.store).contains(.hadADuo), "\(availability)")
        }
        kit.store.availability = .disconnected
        XCTAssertTrue(model.rows(kit.store).contains(.hadADuo))
    }

    func testADisconnectedPhoneIsNotPeekedAndIsOfferedTheReconnectSheet() async {
        // The amendments: the service returns nothing and says nothing for a disconnected phone, so
        // the sheet shows the banner's line itself, and the code can go to "I had a duo" unpeeked.
        let kit = await kRealKit(credential: DuoFixtures.credential())
        kit.store.availability = .disconnected
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kit.transport.kPeeks, [])
        XCTAssertEqual(model.stage, .failed("This phone was disconnected from the duo"))
        XCTAssertEqual(model.rows(kit.store), [.failure("This phone was disconnected from the duo"), .hadADuo])
        XCTAssertFalse(model.showsReconnectSheet)
        model.showReconnect()
        XCTAssertTrue(model.showsReconnectSheet)
        XCTAssertFalse(model.offersJoin)
        XCTAssertEqual(kit.transport.calls.filter { if case .reconnect = $0 { return true }; return false }.count, 0)
    }

    func testTheReconnectSheetIsOnlyReachedFromAFailure() {
        let answered = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        answered.showReconnect()
        XCTAssertEqual(answered.stage, .answered(KFixtures.peek(.invite)))
        let waiting = DuoJoinSheetModel()
        waiting.showReconnect()
        XCTAssertEqual(waiting.stage, .waiting)
    }

    // MARK: - The restore question (K3)

    func testTheRestoreQuestionIsAskedInTheSheet() async {
        // The service refuses the peek during the question and says nothing; the sheet asks it.
        let kit = await kRealKit(credential: DuoFixtures.credential())
        kit.identity.launch = .needsRestoreChoice(KFixtures.prompt)
        kit.store.availability = .needsRestoreChoice(KFixtures.prompt)
        let model = DuoJoinSheetModel()
        await model.peekIfNeeded(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kit.transport.kPeeks, [])
        let question = DuoJoinPlan.restoreQuestion(KFixtures.prompt)
        XCTAssertEqual(model.stage, .failed(question))
        XCTAssertEqual(model.rows(kit.store), [.restore(question)])
        XCTAssertNotEqual(question, DuoUserMessage.generic)
    }

    func testStartFreshKeepsTheInviteAndAsksAgainFromAFreshPhone() async {
        let kit = await kRealKit(credential: DuoFixtures.credential())
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.identity.launch = .needsRestoreChoice(KFixtures.prompt)
        kit.store.availability = .needsRestoreChoice(KFixtures.prompt)
        let invite = KFixtures.invite
        kit.store.pendingInvite = invite
        let model = DuoJoinSheetModel(stage: .failed(DuoJoinPlan.restoreQuestion(KFixtures.prompt)))

        model.startFresh(kit.store, invite: invite)
        // The wipe happened (the identity is gone, the question with it) and the invite is back,
        // its link secret with it, in the same turn.
        XCTAssertNil(kit.identity.credential)
        XCTAssertEqual(kit.store.availability, .unknown)
        XCTAssertEqual(kit.store.pendingInvite?.code, invite.code)
        XCTAssertEqual(kit.store.pendingInvite?.k, invite.k)
        XCTAssertEqual(model.stage, .waiting)
        XCTAssertEqual(model.attempt, 1)
        // Asked again, anonymously now.
        let prepared = kit.identity.prepared
        await model.peekIfNeeded(kit.store, invite: invite)
        XCTAssertEqual(kit.transport.kPeeks, ["H7K39QWX"])
        XCTAssertEqual(kit.identity.prepared, prepared)
        XCTAssertTrue(model.offersJoin)
    }

    func testContinueTakesTheRestoredIdentityAndAsksAgain() async {
        let kit = await kKit(credential: DuoFixtures.credential())
        kit.store.availability = .needsRestoreChoice(KFixtures.prompt)
        let model = DuoJoinSheetModel(stage: .failed(DuoJoinPlan.restoreQuestion(KFixtures.prompt)))
        await model.continueRestored(kit.store)
        XCTAssertEqual(kit.identity.continued, 1)
        XCTAssertEqual(model.stage, .waiting)
        XCTAssertEqual(model.attempt, 1)
    }

    func testTheFormDuringTheRestoreQuestionAsksItAndKeepsJoinOff() async {
        let kit = await kKit()
        kit.store.availability = .needsRestoreChoice(KFixtures.prompt)
        let rows = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite))).rows(kit.store)
        XCTAssertTrue(rows.contains(.restore(DuoJoinPlan.restoreQuestion(KFixtures.prompt))))
        XCTAssertEqual(rows.last, .join(enabled: false, working: false))
    }

    // MARK: - The plans and their rows

    func testTheInviteFormsRowsInOrder() async {
        let kit = await kKit()
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        XCTAssertEqual(model.rows(kit.store), [
            .banner(text: DuoJoinPlan.banner(inviterName: "Alex"), skin: "forest", isSample: false),
            .name, .explainer, .join(enabled: true, working: false),
        ])
        XCTAssertTrue(model.closesWithNotNow)
        kit.store.sheetError = "Too many tries. Wait a bit and try again."
        kit.store.isWorking = true
        XCTAssertEqual(model.rows(kit.store), [
            .banner(text: DuoJoinPlan.banner(inviterName: "Alex"), skin: "forest", isSample: false),
            .name, .explainer, .error("Too many tries. Wait a bit and try again."), .join(enabled: false, working: true),
        ])
        kit.store.sheetError = nil
        kit.store.isWorking = false
        kit.store.availability = .upgradeRequired
        XCTAssertEqual(model.rows(kit.store).suffix(2), [.blocked("Update HydroDrop to keep using Duo Streaks."), .join(enabled: false, working: false)])
        // A blocked line the service already said is not said twice.
        kit.store.sheetError = "Update HydroDrop to keep using Duo Streaks."
        XCTAssertFalse(model.rows(kit.store).contains(.blocked("Update HydroDrop to keep using Duo Streaks.")))
    }

    func testTheBannerHoldsTheNameAsTheServerSentIt() async {
        let kit = await kKit()
        for name in ["**Alex** [x](https://evil.example) %@", "alex", "  padded ", "مريم"] {
            let rows = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite, name: name))).rows(kit.store)
            XCTAssertEqual(rows.first, .banner(text: "\u{2068}\(name)\u{2069} invited you to keep a streak together.", skin: "forest", isSample: false), name)
        }
    }

    func testTheSamplePartnerIsMarked() async {
        let kit = await kKit()
        let rows = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.demo, name: nil, skin: nil))).rows(kit.store)
        XCTAssertEqual(rows.first, .banner(text: "Your partner invited you to keep a streak together.", skin: nil, isSample: true))
    }

    func testEachPlanOffersWhatItShould() async {
        let kit = await kKit()
        let invite = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        XCTAssertTrue(invite.offersJoin)
        XCTAssertFalse(invite.showsReconnectSheet)

        let reconnect = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.reconnect, target: "Sam")))
        XCTAssertFalse(reconnect.offersJoin)
        XCTAssertTrue(reconnect.showsReconnectSheet)
        XCTAssertEqual(reconnect.rows(kit.store), [])

        for purpose in [DuoPeek.Purpose.linkDevice, .unknown] {
            let unsupported = DuoJoinSheetModel(stage: .answered(KFixtures.peek(purpose)))
            XCTAssertEqual(unsupported.plan, .unsupported)
            XCTAssertFalse(unsupported.offersJoin)
            XCTAssertFalse(unsupported.showsReconnectSheet)
            XCTAssertEqual(unsupported.rows(kit.store), [.unsupported])
            XCTAssertFalse(unsupported.closesWithNotNow)
        }
        XCTAssertNil(DuoJoinSheetModel(stage: .failed("x")).plan)
        XCTAssertEqual(DuoJoinSheetModel().rows(kit.store), [.loading])
        XCTAssertTrue(DuoJoinSheetModel().closesWithNotNow)
    }

    func testACodeWithNoJoinSendsNothingOnTheTapOrAfterTheRules() async {
        for stage in [DuoJoinSheetModel.Stage.answered(KFixtures.peek(.reconnect)), .answered(KFixtures.peek(.linkDevice)),
                      .answered(KFixtures.peek(.unknown)), .failed("x"), .waiting, .reconnect] {
            let kit = await kKit()
            let before = kit.joining.calls.count
            let model = DuoJoinSheetModel(stage: stage)
            await model.tapJoin(kit.store, invite: KFixtures.invite)
            await model.termsAccepted(kit.store, invite: KFixtures.invite)
            XCTAssertEqual(kCalls(kit, since: before), [], "\(stage)")
            XCTAssertFalse(model.wantsDismiss, "\(stage)")
        }
    }

    // MARK: - Join

    func testTheTapJoinsOnceWithTheTypedNameAndClosesOnSuccess() async {
        let kit = await kRealKit()
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)), name: "Old")
        model.name = "Ana"
        await model.tapJoin(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kit.transport.kRedeems.count, 1)
        XCTAssertEqual(kit.transport.kRedeems.first?.displayName, "Ana")
        XCTAssertTrue(model.wantsDismiss)
    }

    func testAJoinThatDidNotHappenKeepsTheSheetOpen() async {
        let kit = await kKit()
        kit.joining.joinResult = nil
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        await model.tapJoin(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kCalls(kit, since: before), ["join:H7K39QWX"])
        XCTAssertFalse(model.wantsDismiss)
    }

    func testTheRulesAcceptedAfterA428TapJoinOnceMore() async {
        let kit = await kKit()
        kit.joining.joinResult = DuoFixtures.duo(id: KFixtures.joinedID, role: .partner)
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        await model.termsAccepted(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kCalls(kit, since: before), ["join:H7K39QWX"])
        XCTAssertTrue(model.wantsDismiss)
    }

    func testTheTapSendsTheTypedNameInOneRedeemAndTheServiceClearsTheInvite() async {
        let kit = await kRealKit()
        let invite = KFixtures.invite
        kit.store.pendingInvite = invite
        let model = DuoJoinSheetModel(name: "Ana")
        await model.peekIfNeeded(kit.store, invite: invite)
        XCTAssertTrue(model.offersJoin)
        XCTAssertEqual(kit.transport.kRedeems.count, 0, "nothing is redeemed before the tap")

        await model.tapJoin(kit.store, invite: invite)
        XCTAssertTrue(model.wantsDismiss)
        XCTAssertEqual(kit.transport.kRedeems.count, 1)
        XCTAssertEqual(kit.transport.kRedeems.first?.displayName, "Ana")
        XCTAssertEqual(kit.transport.kRedeems.first?.code, "H7K39QWX")
        // The link's secret came with it, so the duo says it can be paired for encryption later.
        XCTAssertEqual(kit.transport.kRedeems.first?.e2eeCapable, true)
        // The service, not the sheet, let go of the pending invite.
        XCTAssertNil(kit.store.pendingInvite)
        XCTAssertNotNil(kit.store.duo(KFixtures.joinedID))
    }

    func testAnEmptyNameIsSentAsNoName() async {
        let kit = await kRealKit()
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)), name: "   ")
        await model.tapJoin(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(kit.transport.kRedeems.count, 1)
        XCTAssertNil(kit.transport.kRedeems.first?.displayName)
    }

    func testASecondTapWhileTheFirstIsOutSendsNoSecondRedeem() async {
        let kit = await kRealKit()
        let gate = KGate()
        kit.dependencies.transport = KGatedTransport(kit.transport, holdingRedeemsAt: gate)
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)), name: "Ana")
        let first = Task { await model.tapJoin(kit.store, invite: KFixtures.invite) }
        let held = await kSettle { gate.entered == 1 }
        XCTAssertTrue(held, "the first tap never reached the redeem")
        // While it is out the button is off, and a tap that got in anyway is refused unsent.
        XCTAssertTrue(kit.store.isWorking)
        XCTAssertEqual(model.rows(kit.store).last, .join(enabled: false, working: true))
        await model.tapJoin(kit.store, invite: KFixtures.invite)
        XCTAssertEqual(gate.entered, 1)
        gate.release()
        await first.value
        XCTAssertTrue(model.wantsDismiss)
        XCTAssertEqual(kit.transport.kRedeems.count, 1)
    }

    func testCloseAndTheGatesCloseDismiss() {
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        XCTAssertFalse(model.wantsDismiss)
        model.close()
        XCTAssertTrue(model.wantsDismiss)
    }

    // MARK: - The name field (K6)

    func testTheNameStartsFromTheTypedNameElseTheServersAndIsCapped() async {
        let kit = await kKit()
        kit.store.memberInfo = KFixtures.member(name: "Server")
        kit.store.myDisplayName = ""
        XCTAssertEqual(DuoJoinSheetModel(store: kit.store).name, "Server")
        kit.store.myDisplayName = "Ana"
        XCTAssertEqual(DuoJoinSheetModel(store: kit.store).name, "Ana")
        kit.store.memberInfo = nil
        kit.store.myDisplayName = ""
        XCTAssertEqual(DuoJoinSheetModel(store: kit.store).name, "")

        let model = DuoJoinSheetModel(name: String(repeating: "a", count: 30))
        XCTAssertEqual(model.name, String(repeating: "a", count: 24))
        model.name = String(repeating: "b", count: 40)
        XCTAssertEqual(model.name, String(repeating: "b", count: 24))
        model.name = "  bé "
        XCTAssertEqual(model.name, "  bé ")
    }

    func testTheDrawnFieldShowsTheStartingName() async throws {
        // The sheet makes its own model from the store, as the root's does.
        let kit = await kKit()
        kit.joining.peekResult = KFixtures.peek(.invite)
        kit.store.myDisplayName = "Ana"
        let window = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite))
        let found = await kSettle(5) { !kTextFields(in: window).isEmpty }
        XCTAssertTrue(found, "no text field was drawn")
        let field = try XCTUnwrap(kTextFields(in: window).first)
        let shown = await kSettle { field.text == "Ana" }
        XCTAssertTrue(shown, "the field shows \(field.text ?? "nil")")
    }

    func testWhatIsTypedInTheDrawnFieldReachesTheModelCapped() async throws {
        let kit = await kKit()
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)), name: "Ana")
        let window = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))
        // Typing needs a key window; the app's own is given its key back afterwards.
        let appWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window.makeKey()
        defer { appWindow?.makeKey() }
        let found = await kSettle(5) { !kTextFields(in: window).isEmpty }
        XCTAssertTrue(found, "no text field was drawn")
        let field = try XCTUnwrap(kTextFields(in: window).first)
        field.becomeFirstResponder()
        // Typed, the way the keyboard does it, so the change goes through SwiftUI's binding.
        field.insertText(String(repeating: "z", count: 40))
        let capped = await kSettle { model.name.count == 24 }
        XCTAssertTrue(capped, "the model holds \(model.name.count) characters")
        XCTAssertEqual(model.name, "Ana" + String(repeating: "z", count: 21))
        field.resignFirstResponder()
    }

    // MARK: - What only the view does

    func testTheBodyIsTheReconnectSheetOrTheGatedForm() {
        // The reconnect sheet is drawn outside this sheet's gate (its own gate answers a 428), and the
        // form inside it.
        let shape = String(reflecting: DuoJoinSheet.Body.self)
        XCTAssertTrue(shape.contains("_ConditionalContent<HydroDrop.DuoReconnectSheet, HydroDrop.DuoConsentGate<"), shape)
        let gated = shape.components(separatedBy: "DuoConsentGate<").dropFirst().joined()
        XCTAssertFalse(gated.contains("DuoReconnectSheet"), shape)
    }

    func testTheDrawnGateCallsTheModelsCloseAndTapsJoinAfterTheRules() async throws {
        let kit = await kKit()
        kit.joining.joinResult = DuoFixtures.duo(id: KFixtures.joinedID, role: .partner)
        let before = kit.joining.calls.count
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        let sheet = DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model)
        let gate = try XCTUnwrap(kFind("DuoConsentGate<", in: sheet.body))
        XCTAssertNil(kFind("DuoReconnectSheet", in: sheet.body))
        let accepted = try XCTUnwrap(kClosure("onTermsAccepted", in: gate))
        accepted()
        let joined = await kSettle { self.kCalls(kit, since: before).contains("join:H7K39QWX") }
        XCTAssertTrue(joined)
        XCTAssertEqual(kCalls(kit, since: before), ["join:H7K39QWX"])

        let closer = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        let closingGate = try XCTUnwrap(kFind("DuoConsentGate<", in: DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: closer).body))
        try XCTUnwrap(kClosure("onClose", in: closingGate))()
        XCTAssertTrue(closer.wantsDismiss)
    }

    func testAReconnectCodeDrawsTheReconnectSheetAlone() throws {
        let kit = DuoTestKit()
        kits.append(kit)
        let sheet = DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: DuoJoinSheetModel(stage: .answered(KFixtures.peek(.reconnect))))
        let reconnect = try XCTUnwrap(kFind("DuoReconnectSheet", in: sheet.body))
        XCTAssertEqual(Mirror(reflecting: reconnect).children.first { $0.label == "prefilledCode" }?.value as? String, "H7K39QWX")
        XCTAssertNil(kFind("DuoConsentGate<", in: sheet.body))
    }

    func testTheBannerIsDrawnVerbatim() throws {
        // A name shaped like a markdown link, drawn as the characters it is, is many times wider than
        // the one word markdown would leave of it.
        let link = try XCTUnwrap(kRender(DuoJoinSheet.bannerText("[x](https://evil.example/aaaa)").font(.headline).fixedSize()))
        let word = try XCTUnwrap(kRender(DuoJoinSheet.bannerText("x").font(.headline).fixedSize()))
        XCTAssertGreaterThan(link.size.width, word.size.width * 5)
        let bold = try XCTUnwrap(kRender(DuoJoinSheet.bannerText("**xx**").font(.headline).fixedSize()))
        let plain = try XCTUnwrap(kRender(DuoJoinSheet.bannerText("xx").font(.headline).fixedSize()))
        XCTAssertGreaterThan(bold.size.width, plain.size.width * 1.5)
    }

    func testTheJoinButtonIsOffWhenItIsNotEnabled() throws {
        func png(_ enabled: Bool) throws -> Data {
            let image = try XCTUnwrap(kRender(DuoJoinSheet.joinButton(enabled: enabled, working: false) {}.frame(width: 240, height: 44)))
            return try XCTUnwrap(image.pngData())
        }
        XCTAssertEqual(try png(true), try png(true), "the same button draws the same")
        XCTAssertNotEqual(try png(true), try png(false), "a disabled Join draws exactly like a live one")
    }

    func testTheSheetsWordsGoWhenItLeavesTheScreen() async {
        let kit = await kKit()
        let window = kHost(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: DuoJoinSheetModel(stage: .failed("x"))))
        _ = await kSettle(0.5) { false }
        kit.store.sheetError = "That invite is no longer open. Ask for a new one."
        window.rootViewController = nil
        let cleared = await kSettle { kit.store.sheetError == nil }
        XCTAssertTrue(cleared)
    }

    func testTheDrawnSheetGoesWhenTheModelSaysSoAndCannotBeSwipedAwayWhileWorking() async throws {
        let kit = await kKit()
        let presented = KPresented()
        let model = DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite)))
        let window = kWindow(UIHostingController(rootView: KSheetHost(presented: presented,
                                                                       sheet: DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: model))))
        presented.shown = true
        let up = await kSettle(5) { window.rootViewController?.presentedViewController != nil }
        XCTAssertTrue(up)
        let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController)
        XCTAssertFalse(sheet.isModalInPresentation)
        kit.store.isWorking = true
        let locked = await kSettle { sheet.isModalInPresentation }
        XCTAssertTrue(locked, "a sheet with a Join out can be swiped away")
        kit.store.isWorking = false
        let unlocked = await kSettle { !sheet.isModalInPresentation }
        XCTAssertTrue(unlocked)

        model.close()
        let gone = await kSettle(5) { !presented.shown && window.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(gone, "the sheet stayed after the model asked to close")
    }

    func testTheSheetDrawsInEveryState() async {
        let kit = await kKit()
        let stages: [DuoJoinSheetModel.Stage] = [
            .waiting,
            .answered(KFixtures.peek(.invite)),
            .answered(KFixtures.peek(.invite, name: nil, skin: nil)),
            .answered(KFixtures.peek(.invite, name: "**Alex** [x](https://evil.example) %@", skin: "no-such-skin")),
            .answered(KFixtures.peek(.demo, name: nil, skin: nil)),
            .answered(KFixtures.peek(.reconnect, target: "Sam")),
            .answered(KFixtures.peek(.linkDevice)),
            .answered(KFixtures.peek(.unknown)),
            .failed("That invite is no longer open. Ask for a new one."),
            .failed(DuoUserMessage.generic),
            .reconnect,
        ]
        func draw(_ stage: DuoJoinSheetModel.Stage) {
            XCTAssertNotNil(kRender(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: DuoJoinSheetModel(stage: stage))
                .frame(width: 390, height: 844)), "\(stage)")
        }
        stages.forEach(draw)
        kit.store.isWorking = true
        kit.store.sheetError = "Too many tries. Wait a bit and try again."
        draw(.answered(KFixtures.peek(.invite)))
        kit.store.isWorking = false
        for availability in [DuoAvailability.disconnected, .upgradeRequired, .banned, .needsRestoreChoice(KFixtures.prompt)] {
            kit.store.availability = availability
            draw(.answered(KFixtures.peek(.invite)))
            draw(.failed("x"))
        }
        kit.store.availability = .available
        XCTAssertNotNil(kRender(DuoJoinSheet(duoStore: kit.store, invite: KFixtures.invite, model: DuoJoinSheetModel(stage: .answered(KFixtures.peek(.invite))))
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.colorScheme, .dark)
            .frame(width: 390, height: 844)))
        let unknown = await kKit(birthYear: nil)
        XCTAssertNotNil(kRender(DuoJoinSheet(duoStore: unknown.store, invite: KFixtures.invite).frame(width: 390, height: 844)))
    }
}
#endif
