#if DUO_V2
import SwiftUI
import UIKit
import XCTest
@testable import HydroDrop

// Stage L: "I had a duo", the reconnect sheet. Its Reconnect button (the controller's `tap`,
// which the button and the terms sheet's Accept both call) reaches `DuoStore.reconnect` once with
// the code as it was typed, never before the birth-year screen has said yes, never while
// availability rules a reconnect out, never twice for one tap and never again once it has landed;
// the keyboard's return key never sends; a refusal leaves the service's words on the sheet and not
// in the store once the sheet has gone; and nothing is sent when the sheet appears. The sheet is
// put on screen and driven through accessibility as a person would (helpers in
// DuoCodeEntryViewTests.swift).

// MARK: - Helpers (stage L)

/// The shared joining double with its reconnect held at the door: the first call waits until the
/// test lets it go, and any later call goes straight through, so a bug that lets a second tap send
/// fails its assertion instead of hanging the test. A refusal it is told to give leaves words in
/// `sheetError`, as the real service does.
@MainActor
fileprivate final class LHeldJoining: DuoJoining {
    let base: FakeJoining
    weak var host: DuoStore?
    var refusalWords: String?
    private(set) var entered = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    init(base: FakeJoining) { self.base = base }

    func reconnect(code: String) async -> Bool {
        entered += 1
        if entered == 1, !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in waiting = continuation }
        }
        let landed = await base.reconnect(code: code)
        if !landed, let refusalWords { host?.sheetError = refusalWords }
        return landed
    }

    func release() {
        released = true
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }

    func createDuo(named: String?, skin: String) async -> DuoState? { await base.createDuo(named: named, skin: skin) }
    func peek(code: String) async -> DuoPeek? { await base.peek(code: code) }
    func receive(_ invite: DuoParsedInvite, now: Date) { base.receive(invite, now: now) }
    func discardPendingInvite() { base.discardPendingInvite() }
    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState? { await base.join(invite, named: named, skin: skin) }
    func newInvite(for duo: DuoState) async -> DuoInvite? { await base.newInvite(for: duo) }
    func createReconnectCode(for duo: DuoState) async -> DuoInvite? { await base.createReconnectCode(for: duo) }
    func createLinkCode() async -> DuoInvite? { await base.createLinkCode() }
    func changeMyName(_ name: String?) async { await base.changeMyName(name) }
    func acceptTerms() async -> Bool { await base.acceptTerms() }
}

/// The transport's calls by name, for a test that says what was sent and in which order.
fileprivate func lNames(_ calls: [FakeDuoTransport.Call]) -> [String] {
    calls.map { call in
        switch call {
        case .createDevice: return "createDevice"
        case .attestChallenge: return "attestChallenge"
        case .rotate: return "rotate"
        case .me: return "me"
        case .updateMe: return "updateMe"
        case .deleteMe: return "deleteMe"
        case .registerPush: return "registerPush"
        case .unregisterPush: return "unregisterPush"
        case .createDuo: return "createDuo"
        case .createInvite: return "createInvite"
        case .peekInvite: return "peekInvite"
        case .redeemInvite: return "redeemInvite"
        case .reconnect(let request, _): return "reconnect:\(request.code)"
        case .fetchDuo: return "fetchDuo"
        case .fetchChanges: return "fetchChanges"
        case .pushDayStatuses: return "pushDayStatuses"
        case .sendNudge: return "sendNudge"
        case .leave: return "leave"
        case .block: return "block"
        }
    }
}

/// Finds the consent gate a view's body builds, wherever it sits among the modifiers.
fileprivate func lGate(in value: Any, depth: Int = 0) -> Mirror? {
    guard depth < 16 else { return nil }
    if String(describing: type(of: value)).hasPrefix("DuoConsentGate<") { return Mirror(reflecting: value) }
    for child in Mirror(reflecting: value).children {
        if let found = lGate(in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

@MainActor
final class DuoReconnectSheetTests: XCTestCase {

    /// The real joining service in the kit, as stage D built it.
    private func useTheRealService(_ kit: DuoTestKit) {
        let service = DuoJoiningService(dependencies: kit.dependencies)
        service.holdInBackground = { _ in {} }
        kit.dependencies.joining = service
    }

    private func typed(_ code: String) -> DuoReconnectController {
        let controller = DuoReconnectController(prefilledCode: nil)
        controller.typed = code
        return controller
    }

    /// Form tests complete consent before presentation. Keep lKit unaccepted for service-path
    /// tests, and opt out here when testing the real outer gate instead of its former stub.
    private func present(_ kit: DuoTestKit, prefilledCode: String? = nil, onReconnected: (() -> Void)? = nil,
                         acceptedTerms: Bool = true) throws -> (LScreen, LPresenter) {
        if acceptedTerms {
            let accepted = LBox<Bool?>(nil)
            let task = Task { accepted.value = await kit.store.acceptTerms() }
            defer { task.cancel() }
            guard lWait(5, { accepted.value != nil }) else {
                XCTFail("fixture terms acceptance did not finish")
                throw NSError(domain: "DuoReconnectSheetTests", code: 1)
            }
            // A Keychain refusal fixture must still refuse acceptance and draw the age gate.
            XCTAssertTrue(accepted.value == true || kit.store.ageStatus == .refused)
            kit.joining.resetCalls()
        }
        let presenter = LPresenter()
        let screen = try LScreen(LSheetHost(presenter: presenter) {
            DuoReconnectSheet(duoStore: kit.store, prefilledCode: prefilledCode, onReconnected: onReconnected)
        }, test: self)
        screen.scrollsToFindElements = true
        XCTAssertTrue(lWait { screen.sheet != nil }, "the sheet came up")
        lSpin(0.5)
        if acceptedTerms, kit.store.ageStatus == .allowed {
            XCTAssertEqual(kit.store.acceptedTermsVersion, DuoProtocolConstants.termsVersion)
            XCTAssertTrue(lWait { screen.has("duo.explainer") }, "the real consent gate drew the reconnect form")
        }
        return (screen, presenter)
    }

    // MARK: - The tap

    func testReconnectReachesTheStoreOnceWithTheCodeAsTyped() async {
        let kit = lKit()
        let controller = typed("h7k3 9qwx\n")
        XCTAssertTrue(controller.canReconnect(in: kit.store))
        let landed = LBox(0)
        await controller.tap(in: kit.store) { landed.value += 1 }.value
        XCTAssertEqual(kit.joining.calls, ["reconnect:h7k3 9qwx"], "once, as typed but for the line break a paste brought")
        XCTAssertEqual(landed.value, 1, "the sheet closes once it has landed")
        XCTAssertEqual(kit.transport.calls, [])
        XCTAssertFalse(controller.isSending)
    }

    /// With `onReconnected:` the sheet stays on screen after landing (the join sheet closes it a
    /// moment later); a second tap then must not send a second reconnect (review probe P4).
    func testOnceItHasLandedNothingMoreIsSent() async {
        let kit = lKit()
        let controller = typed("H7K39QWX")
        let first = await controller.reconnect(in: kit.store)
        XCTAssertTrue(first)
        XCTAssertTrue(controller.hasLanded)
        XCTAssertFalse(controller.canReconnect(in: kit.store))
        let second = await controller.reconnect(in: kit.store)
        XCTAssertFalse(second)
        XCTAssertEqual(kit.joining.calls, ["reconnect:H7K39QWX"])
    }

    func testARefusedReconnectKeepsTheSheetOpen() async {
        let kit = lKit()
        kit.joining.reconnectResult = false
        let controller = typed("H7K39QWX")
        let landed = LBox(0)
        await controller.tap(in: kit.store) { landed.value += 1 }.value
        XCTAssertEqual(kit.joining.calls, ["reconnect:H7K39QWX"])
        XCTAssertEqual(landed.value, 0)
        XCTAssertFalse(controller.hasLanded)
        XCTAssertTrue(controller.canReconnect(in: kit.store), "the person can try again")
    }

    func testNothingIsSentBeforeTheBirthYearScreenHasSaidYes() async {
        let unknown = lKit(age: nil)
        XCTAssertEqual(unknown.store.ageStatus, .unknown)
        let controller = typed("H7K39QWX")
        XCTAssertFalse(controller.canReconnect(in: unknown.store))
        let unknownResult = await controller.reconnect(in: unknown.store)
        XCTAssertFalse(unknownResult)
        XCTAssertEqual(unknown.joining.calls, [], "the gate asks the birth year first")

        let refused = lKit(age: nil)
        XCTAssertEqual(refused.store.recordBirthYear(2024, month: 1, now: refused.clock.now), .refused)
        let refusedResult = await controller.reconnect(in: refused.store)
        XCTAssertFalse(refusedResult)
        XCTAssertEqual(refused.joining.calls, [])

        unknown.store.recordBirthYear(1990, month: 1, now: unknown.clock.now)
        let allowedResult = await controller.reconnect(in: unknown.store)
        XCTAssertTrue(allowedResult)
        XCTAssertEqual(unknown.joining.calls, ["reconnect:H7K39QWX"])
    }

    /// A refusal only the Keychain remembers: the store finds it at the tap, sends nothing and
    /// publishes it, and the consent gate then draws the refusal.
    func testARefusalOnlyTheKeychainRemembersSendsNothing() async throws {
        let kit = lKit()
        try kit.dependencies.secrets.markAgeRefused()
        let result = await typed("H7K39QWX").reconnect(in: kit.store)
        XCTAssertFalse(result)
        XCTAssertEqual(kit.joining.calls, [])
        XCTAssertEqual(kit.store.ageStatus, .refused)
    }

    func testTheButtonFollowsAllowsReconnect() async {
        let table: [(DuoAvailability, Bool)] = [
            (.available, true), (.disconnected, true), (.unknown, true), (.maintenance, true),
            (.upgradeRequired, false), (.banned, false), (lRestore, false),
        ]
        for (availability, sends) in table {
            let kit = lKit()
            kit.store.availability = availability
            let controller = typed("H7K39QWX")
            XCTAssertEqual(controller.canReconnect(in: kit.store), sends, "\(availability)")
            let result = await controller.reconnect(in: kit.store)
            XCTAssertEqual(result, sends, "\(availability)")
            XCTAssertEqual(kit.joining.calls, sends ? ["reconnect:H7K39QWX"] : [], "\(availability)")
        }
    }

    func testNothingIsSentWhileWorkingOrForSomethingThatIsNotACode() async {
        let kit = lKit()
        kit.store.isWorking = true
        let working = typed("H7K39QWX")
        XCTAssertFalse(working.canReconnect(in: kit.store))
        let workingResult = await working.reconnect(in: kit.store)
        XCTAssertFalse(workingResult)
        kit.store.isWorking = false
        for bad in ["", "H7K39QW", "H7K39QWU", "https://hydrodrop.us/duo#H7K39QWX", "\u{1F4A7}", "H7K3\n9QWX"] {
            let controller = typed(bad)
            XCTAssertFalse(controller.canReconnect(in: kit.store), bad.debugDescription)
            let result = await controller.reconnect(in: kit.store)
            XCTAssertFalse(result, bad.debugDescription)
        }
        XCTAssertEqual(kit.joining.calls, [])
    }

    func testASecondTapWhileTheFirstIsOutSendsNothing() async {
        let kit = lKit()
        let held = LHeldJoining(base: kit.joining)
        kit.dependencies.joining = held
        let controller = DuoReconnectController(prefilledCode: "H7K39QWX")
        let first = controller.tap(in: kit.store) {}
        defer { held.release() }
        for _ in 0..<1000 {
            if held.entered != 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard held.entered == 1 else { return XCTFail("the reconnect reached the held service") }
        XCTAssertTrue(controller.isSending)
        XCTAssertTrue(controller.isWorking(in: kit.store), "the progress indicator shows from the tap on")
        XCTAssertFalse(controller.canReconnect(in: kit.store))
        let second = await controller.reconnect(in: kit.store)
        XCTAssertFalse(second)
        XCTAssertEqual(held.entered, 1, "the second tap never reached the store")
        held.release()
        await first.value
        XCTAssertEqual(kit.joining.calls, ["reconnect:H7K39QWX"])
        XCTAssertFalse(controller.isSending)
    }

    func testAPrefilledCodeIsTheOneSentAsItCame() async {
        let kit = lKit()
        let prefilled = DuoReconnectController(prefilledCode: "h7k39qwx")
        prefilled.typed = "ZZZZZZZZ"
        XCTAssertEqual(prefilled.code, "h7k39qwx")
        let result = await prefilled.reconnect(in: kit.store)
        XCTAssertTrue(result)
        XCTAssertEqual(kit.joining.calls, ["reconnect:h7k39qwx"])

        let empty = DuoReconnectController(prefilledCode: "")
        XCTAssertNil(empty.prefilledCode, "an empty code is no code: the person types one")
        XCTAssertEqual(empty.code, "")
    }

    // MARK: - With the real joining service

    /// The rules not yet accepted: the first tap sends nothing and asks for them (`needsTerms`,
    /// which the consent gate shows as a sheet); Accept records them, and the gate's
    /// `onTermsAccepted` taps Reconnect once more, which now mints this phone's identity (the tap
    /// is the consent) and reconnects. One mint, one reconnect.
    func testTheTermsPathSendsTheSameTapOnceMore() async {
        let kit = lKit()
        useTheRealService(kit)
        XCTAssertLessThan(kit.store.acceptedTermsVersion, DuoProtocolConstants.termsVersion)
        kit.transport.onCreateDevice = { _ in
            DuoWireCreateDeviceResponse(memberId: "6d2a0000-0000-4000-8000-0000000000cc", deviceId: "6d2a0000-0000-4000-8000-0000000000dd",
                                        deviceSecret: String(repeating: "t", count: 43), tier: .attested, supportId: "ABCD1234EFGH")
        }
        kit.transport.onReconnect = { _, _ in
            DuoWireReconnectResponse(memberId: "6d2a0000-0000-4000-8000-0000000000ee", supportId: "WXYZ5678ABCD", duos: [], supersededDevices: 1)
        }
        let controller = typed("h7k3 9qwx")
        let landed = LBox(0)
        await controller.tap(in: kit.store) { landed.value += 1 }.value
        XCTAssertEqual(landed.value, 0)
        XCTAssertTrue(kit.store.needsTerms, "the rules are asked for")
        XCTAssertEqual(kit.transport.calls, [], "and nothing is sent before they are accepted")

        let accepted = await kit.store.acceptTerms()
        XCTAssertTrue(accepted)
        XCTAssertFalse(kit.store.needsTerms)
        // What `onTermsAccepted` does: the same tap, once.
        await controller.tap(in: kit.store) { landed.value += 1 }.value
        XCTAssertEqual(landed.value, 1)
        XCTAssertEqual(lNames(kit.transport.calls), ["createDevice", "reconnect:H7K39QWX", "me"])
        XCTAssertNil(kit.store.sheetError)
    }

    func testARefusalShowsTheServicesWordsAndTheSheetStays() async {
        let table: [(DuoTransportError, String)] = [
            (.memberNotFresh(DuoErrorContext(httpStatus: 409, requestID: "req-1")), "Finish or leave the duo you started on this phone first."),
            (.offline, "No connection right now. Try again in a bit."),
            (.rateLimited(DuoErrorContext(httpStatus: 429, requestID: "req-1")), "Too many tries. Wait a bit and try again."),
        ]
        for (error, words) in table {
            let kit = lKit(credential: DuoFixtures.credential())
            kit.dependencies.cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
            useTheRealService(kit)
            kit.transport.onReconnect = { _, _ in throw error }
            let controller = typed("H7K39QWX")
            let landed = LBox(0)
            await controller.tap(in: kit.store) { landed.value += 1 }.value
            XCTAssertEqual(landed.value, 0, "\(error)")
            XCTAssertEqual(kit.store.sheetError, words, "\(error)")
            XCTAssertEqual(controller.layout(in: kit.store).error, words, "what the sheet draws: \(error)")
            XCTAssertEqual(lNames(kit.transport.calls), ["reconnect:H7K39QWX"], "\(error)")
            XCTAssertTrue(controller.canReconnect(in: kit.store), "the person can try again: \(error)")
        }
    }

    // MARK: - The gate's two closures

    /// What the sheet hands its consent gate: `onClose` closes the sheet and `onTermsAccepted` sends
    /// the same tap again. Read off the body the sheet builds, because the gate is stage I's and the
    /// stub here never calls either.
    func testTheGatesOnCloseClosesTheSheetAndOnTermsAcceptedSendsAgain() throws {
        let kit = lKit()
        let closes = LBox(0)
        let sheet = DuoReconnectSheet(duoStore: kit.store, prefilledCode: "H7K39QWX", closeForTests: { closes.value += 1 })
        let gate = try XCTUnwrap(lGate(in: sheet.body), "the sheet sits inside a DuoConsentGate")
        let onClose = try XCTUnwrap(gate.children.first { $0.label == "onClose" }?.value as? () -> Void)
        let onTermsAccepted = try XCTUnwrap(gate.children.first { $0.label == "onTermsAccepted" }?.value as? () -> Void)
        onClose()
        XCTAssertEqual(closes.value, 1, "the gate's way out closes the sheet")
        XCTAssertEqual(kit.joining.calls, [])
        onTermsAccepted()
        XCTAssertTrue(lWait { kit.joining.calls == ["reconnect:H7K39QWX"] }, "Accept sends the reconnect again, once")
        XCTAssertTrue(lWait { closes.value == 2 }, "and the sheet closes once it has landed")
        lSpin(0.3)
        XCTAssertEqual(kit.joining.calls.count, 1)
    }

    // MARK: - On screen

    func testUnacceptedTermsKeepTheReconnectFormHiddenAndSendNothing() throws {
        let kit = lKit()
        let (screen, _) = try present(kit, prefilledCode: "H7K39QWX", acceptedTerms: false)
        XCTAssertTrue(lWait { screen.has("duo.terms.accept") })
        XCTAssertFalse(screen.has("duo.reconnect.field"))
        XCTAssertFalse(screen.has("duo.reconnect.confirm"))
        XCTAssertEqual(kit.joining.calls, [])
        XCTAssertEqual(kit.transport.calls, [])
        XCTAssertEqual(kit.identity.prepared, 0)
    }

    func testTheSheetSendsNothingWhenItAppears() throws {
        for prefilled in [nil, "H7K39QWX"] as [String?] {
            let kit = lKit()
            _ = try present(kit, prefilledCode: prefilled)
            XCTAssertEqual(kit.joining.calls, [])
            XCTAssertEqual(kit.transport.calls, [])
            XCTAssertEqual(kit.identity.prepared, 0, "not even the identity is asked")
            XCTAssertEqual(kit.sync.calls, [])
        }
        let disconnected = lKit(credential: DuoFixtures.credential())
        disconnected.store.availability = .disconnected
        _ = try present(disconnected)
        XCTAssertEqual(disconnected.transport.calls, [])
        XCTAssertEqual(disconnected.identity.prepared, 0)
        XCTAssertEqual(disconnected.joining.calls, [])
    }

    /// The Reconnect button is the consent, and only it (D88): the keyboard's return key puts the
    /// keyboard away and sends nothing (review probes: the Go key used to mint an identity and take
    /// a duo over with no button tap and the explainer off screen).
    func testTheReturnKeyNeverSendsOnlyTheButtonDoes() throws {
        let kit = lKit()
        let (screen, _) = try present(kit)
        let field = try XCTUnwrap(screen.textField("duo.reconnect.field"))
        XCTAssertEqual(field.returnKeyType, .done)
        field.becomeFirstResponder()
        field.text = "H7K39QWX"
        field.sendActions(for: .editingChanged)
        lSpin(0.3)
        _ = field.delegate?.textFieldShouldReturn?(field)
        field.sendActions(for: .editingDidEndOnExit)
        lSpin(0.6)
        XCTAssertEqual(kit.joining.calls, [], "the return key sent nothing")
        XCTAssertEqual(screen.isEnabled("duo.reconnect.confirm"), true, "the typed code reached the sheet")
        screen.tap("duo.reconnect.confirm")
        XCTAssertTrue(lWait { kit.joining.calls == ["reconnect:H7K39QWX"] }, "the button sends")
    }

    /// The explainer sits above the field and the button, so it is on screen with them.
    func testTheExplainerComesBeforeTheField() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HydroDrop/Views/DuoReconnectSheet.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "the source checkout is not on this machine")
        let text = try String(contentsOf: file, encoding: .utf8)
        let form = try XCTUnwrap(text.range(of: "private func form("))
        let explainer = try XCTUnwrap(text.range(of: "DuoExplainer(context: .reconnect)", range: form.upperBound..<text.endIndex))
        let field = try XCTUnwrap(text.range(of: "codeField(layout)", range: form.upperBound..<text.endIndex))
        let button = try XCTUnwrap(text.range(of: "duo.reconnect.confirm", range: form.upperBound..<text.endIndex))
        XCTAssertLessThan(explainer.lowerBound, field.lowerBound)
        XCTAssertLessThan(field.lowerBound, button.lowerBound)
    }

    func testTheButtonClosesTheSheetOnceItHasLanded() throws {
        let kit = lKit()
        let (screen, presenter) = try present(kit, prefilledCode: "H7K39QWX")
        screen.tap("duo.reconnect.confirm")
        XCTAssertTrue(lWait { presenter.dismissals == 1 })
        XCTAssertEqual(kit.joining.calls, ["reconnect:H7K39QWX"])
    }

    /// With `onReconnected:` the sheet hands back instead of closing, and a second tap after landing
    /// sends nothing.
    func testWithOnReconnectedTheSheetHandsBackAndSendsOnce() throws {
        let kit = lKit()
        let landed = LBox(0)
        let (screen, presenter) = try present(kit, prefilledCode: "H7K39QWX", onReconnected: { landed.value += 1 })
        screen.tap("duo.reconnect.confirm")
        XCTAssertTrue(lWait { landed.value == 1 })
        XCTAssertTrue(lWait { screen.isEnabled("duo.reconnect.confirm") == false }, "the button is off once landed")
        XCTAssertFalse(screen.tryTap("duo.reconnect.confirm"), "a second tap does nothing")
        lSpin(0.4)
        XCTAssertEqual(kit.joining.calls, ["reconnect:H7K39QWX"])
        XCTAssertEqual(landed.value, 1)
        XCTAssertEqual(presenter.dismissals, 0, "the caller closes it")
    }

    func testTheButtonAndFieldAreOffWhileWorkingAndTheButtonWithoutACode() throws {
        let kit = lKit()
        let (screen, _) = try present(kit)
        XCTAssertEqual(screen.isEnabled("duo.reconnect.confirm"), false, "nothing typed")
        let field = try XCTUnwrap(screen.textField("duo.reconnect.field"))
        field.text = "H7K39QW"
        field.sendActions(for: .editingChanged)
        lSpin(0.3)
        XCTAssertEqual(screen.isEnabled("duo.reconnect.confirm"), false, "not a code")
        field.text = "H7K39QWX"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(lWait { screen.isEnabled("duo.reconnect.confirm") == true })
        kit.store.isWorking = true
        XCTAssertTrue(lWait { screen.isEnabled("duo.reconnect.confirm") == false }, "off while working")
        XCTAssertEqual(screen.textField("duo.reconnect.field")?.isEnabled, false, "the field is off too")
        kit.store.isWorking = false
        XCTAssertTrue(lWait { screen.isEnabled("duo.reconnect.confirm") == true })
    }

    func testTheServicesWordsAreDrawn() throws {
        let kit = lKit()
        let (screen, _) = try present(kit, prefilledCode: "H7K39QWX")
        XCTAssertFalse(screen.has("duo.reconnect.error"))
        kit.store.sheetError = "Finish or leave the duo you started on this phone first."
        XCTAssertTrue(lWait { screen.has("duo.reconnect.error") })
        XCTAssertEqual(screen.label("duo.reconnect.error"), "Finish or leave the duo you started on this phone first.")
    }

    func testADisconnectedPhoneIsNotToldItWasDisconnectedButAnOutOfDateOneIsToldWhy() throws {
        let kit = lKit()
        kit.store.availability = .disconnected
        let (screen, _) = try present(kit, prefilledCode: "H7K39QWX")
        XCTAssertFalse(screen.has("duo.entry.notice"), "the sheet for a disconnected phone does not say it again")
        XCTAssertEqual(screen.isEnabled("duo.reconnect.confirm"), true)
        kit.store.availability = .upgradeRequired
        XCTAssertTrue(lWait { screen.has("duo.entry.notice") })
        XCTAssertEqual(screen.label("duo.entry.notice")?.contains("Update HydroDrop to keep using Duo Streaks."), true)
        XCTAssertEqual(screen.isEnabled("duo.reconnect.confirm"), false)
    }

    /// A swipe cannot close the sheet while a reconnect is out (as stage K's join sheet does).
    func testASwipeCannotCloseTheSheetWhileAReconnectIsOut() throws {
        let kit = lKit()
        let (screen, _) = try present(kit, prefilledCode: "H7K39QWX")
        XCTAssertEqual(screen.sheet?.isModalInPresentation, false)
        kit.store.isWorking = true
        XCTAssertTrue(lWait { screen.sheet?.isModalInPresentation == true })
        kit.store.isWorking = false
        XCTAssertTrue(lWait { screen.sheet?.isModalInPresentation == false })
    }

    /// The sheet closed while its reconnect was out, and the answer was a refusal: its words are
    /// said to nobody and must not wait in the store for the next sheet (review probe P5).
    func testARefusalThatArrivesAfterTheSheetWentIsNotKept() throws {
        let kit = lKit()
        let held = LHeldJoining(base: kit.joining)
        held.host = kit.store
        held.refusalWords = "Finish or leave the duo you started on this phone first."
        kit.joining.reconnectResult = false
        kit.dependencies.joining = held
        let (screen, presenter) = try present(kit, prefilledCode: "H7K39QWX")
        screen.tap("duo.reconnect.confirm")
        XCTAssertTrue(lWait { held.entered == 1 })
        presenter.showing = false
        XCTAssertTrue(lWait { presenter.dismissals == 1 })
        held.release()
        XCTAssertTrue(lWait { kit.joining.calls == ["reconnect:H7K39QWX"] })
        lSpin(0.3)
        XCTAssertNil(kit.store.sheetError, "the words went with the sheet")
    }

    func testSuccessAfterClosingDoesNotCallTheFormerSheetsCompletion() async {
        let kit = lKit()
        let held = LHeldJoining(base: kit.joining)
        kit.dependencies.joining = held
        let controller = typed("H7K39QWX")
        let callbacks = LBox(0)
        let task = controller.tap(in: kit.store) { callbacks.value += 1 }
        defer { held.release() }
        for _ in 0..<1000 {
            if held.entered != 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard held.entered == 1 else { return XCTFail("the reconnect reached the held service") }
        controller.disappeared(in: kit.store)
        held.release()
        await task.value
        XCTAssertTrue(controller.hasLanded, "the service result is still recorded")
        XCTAssertEqual(callbacks.value, 0, "a closed sheet must not dismiss or route its former parent")
    }

    func testClosingTheSheetTakesItsWordsAway() throws {
        let kit = lKit()
        let (screen, presenter) = try present(kit)
        // The real consent gate discards stale errors on form appearance; this failure belongs
        // to the request made while the form is already visible.
        kit.store.sheetError = "Finish or leave the duo you started on this phone first."
        XCTAssertTrue(lWait { screen.has("duo.reconnect.error") }, "the active error was rendered before dismissing")
        presenter.showing = false
        // Parent onDismiss and child onDisappear are separate callbacks; wait for both rather
        // than assuming the parent's callback runs after the child's cleanup.
        XCTAssertTrue(lWait { presenter.dismissals == 1 && kit.store.sheetError == nil },
                      "parent dismissal and child disappearance cleanup both finished")
        XCTAssertNil(kit.store.sheetError, "the next sheet starts clean")
    }

    /// A refusal kept only in the Keychain is found when the sheet appears (`recheckAge`), so the
    /// gate shows it before anything else, and a tap sends nothing.
    func testTheSheetFindsARefusalOnlyTheKeychainKept() throws {
        let kit = lKit()
        try kit.dependencies.secrets.markAgeRefused()
        XCTAssertEqual(kit.store.ageStatus, .allowed)
        let (screen, _) = try present(kit, prefilledCode: "H7K39QWX", acceptedTerms: false)
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertNotEqual(screen.isEnabled("duo.reconnect.confirm"), true)
        lSpin(0.2)
        XCTAssertEqual(kit.joining.calls, [])
    }
}
#endif
