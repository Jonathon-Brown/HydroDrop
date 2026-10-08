#if DUO_V2
import MessageUI
import SwiftUI
import UIKit
import XCTest
@testable import HydroDrop

/// Stage M: Diagnostics and Report a problem. Both draw in every state they have, neither sends
/// anything when it appears or when Copy is tapped, and what each puts in a mail holds ids,
/// numbers, error codes and times, never a name, a code, a key or a token, even from a store
/// that holds all of those.
///
/// The views' own rules (which control has which id, when Send is enabled, what Cancel and a sent
/// mail do, what Copy copies) are tested on the real views, through their accessibility tree: the
/// class switches on accessibility automation, as an XCUITest run does, so SwiftUI builds the
/// tree a unit test can read and activate; it is switched back when the class is done. Controls are
/// found by the literal ids the integration pass's UI test uses, never through the views' own
/// constants, which would follow a changed id instead of catching it. Mail and
/// `UIApplication.open` cannot be driven in a simulator, so the views are handed an `MMailRoute`
/// that records what they hand over and answers as the test says.
@MainActor
final class DuoSupportViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let partner = "Samantha Quill"
    private let me = "Jonathon Brownstone"
    private let waitingID = UUID(uuidString: "0B1C2D3E-2222-4000-8000-000000000002")!

    override class func setUp() {
        super.setUp()
        MAutomation.enable()
    }

    override class func tearDown() {
        MAutomation.restore()
        super.tearDown()
    }

    /// A store holding everything a person could have: a member with a name, a live duo with the
    /// partner's name and a nickname, a waiting duo with its invite code, a received invite with
    /// its link secret, the typed name, five errors, ten responses, a push upload and a queued op.
    private func mRichKit(availability: DuoAvailability = .available) -> DuoTestKit {
        let credential = DuoFixtures.credential()
        let kit = DuoTestKit(now: now, credential: credential)
        let store = kit.store
        store.memberInfo = DuoMemberInfo(memberID: credential.memberID, displayName: me, skin: "classic", supportID: "ABCD1234EFGH",
                                         tier: .attested, termsVersion: 1, nudgesPerDay: 3, maxActiveDuos: 5,
                                         devices: [DuoDeviceInfo(id: credential.deviceID, platform: "ios", createdAt: now, thisDevice: true, superseded: false)],
                                         minClientIOS: "2.0", updatedAt: now)
        var live = DuoFixtures.duo(partner: partner, now: now)
        live.ownerDisplayName = me
        live.partnerNickname = "Sammy"
        var waiting = DuoFixtures.duo(id: waitingID, joined: false, partner: "", now: now)
        waiting.ownerDisplayName = me
        waiting.invite = DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: now.addingTimeInterval(3600))
        store.replaceAll(with: [live, waiting])
        store.myDisplayName = me
        store.pendingInvite = DuoPendingInvite(code: "K8M2PQRS", k: "bGlua1NlY3JldA", receivedAt: now)

        var diagnostics = DuoDiagnostics()
        diagnostics.recordPushUpload(zone: "Europe/London", windowStart: 480, windowEnd: 1320, enabled: true, at: now)
        diagnostics.recordFetch(duoID: live.id, seq: 12, cursor: 12, at: now)
        diagnostics.recordWrite(duoID: live.id, at: now)
        for minute in stride(from: 12, through: 1, by: -1) {
            let id = String(format: "%016x", minute)
            diagnostics.record(DuoTransportError.conflict(DuoErrorContext(httpStatus: 409, requestID: id)), duoID: live.id,
                               now: now.addingTimeInterval(-Double(minute) * 60))
            diagnostics.recordRequest(status: 409, requestID: id, at: now.addingTimeInterval(-Double(minute) * 60))
        }
        store.diagnostics = diagnostics
        store.availability = availability
        kit.ops.enqueue(mOp("op-1", duo: live))
        return kit
    }

    private func mOp(_ key: String, duo: DuoState) -> DuoQueuedOp {
        DuoQueuedOp(key: key, kind: .leave, method: "POST", path: "/duos/\(duo.wireID)/leave", body: Data(), createdAt: now, duoID: duo.wireID)
    }

    /// Every personal thing `mRichKit` holds, none of which may reach a screen or a mail.
    private var mForbidden: [String] {
        let credential = DuoFixtures.credential()
        return [partner, "Samantha", "Quill", me, "Jonathon", "Brownstone", "Sammy", "H7K39QWX", "H7K3-9QWX", "K8M2PQRS",
                "bGlua1NlY3JldA", credential.memberID, credential.deviceID, credential.deviceSecret, "Bearer",
                DuoFixtures.duoID.uuidString.lowercased(), waitingID.uuidString.lowercased(), "/duos/", "@example"]
    }

    private var mRestore: DuoAvailability { .needsRestoreChoice(DuoRestorePrompt(partnerName: partner, myName: me)) }

    // MARK: - Drawing

    /// `ImageRenderer` at 390 x 844, as every view stage's smoke test does, so a state that
    /// crashes or lays out as nothing fails. It cannot draw a `List`'s cells (they are UIKit),
    /// so each state is also laid out for real in a window and drawn from there.
    private func mAssertDraws(_ view: some View, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let renderer = ImageRenderer(content: AnyView(view).frame(width: 390, height: 844))
        XCTAssertNotNil(renderer.uiImage, "\(name) did not render", file: file, line: line)
        let hosted = mHost(view)
        XCTAssertNotNil(mSnapshot(hosted.window), "\(name) did not draw in a window", file: file, line: line)
        XCTAssertGreaterThan(hosted.controller.view.subviews.count, 0, "\(name) laid out as nothing", file: file, line: line)
        hosted.window.isHidden = true
    }

    func testDiagnosticsDrawsInEveryState() {
        let states: [(String, DuoStore)] = [
            ("no identity, no member, no duos", DuoTestKit(now: now).store),
            ("a member, two duos, five errors and ten requests", mRichKit().store),
            ("the restore question", mRichKit(availability: mRestore).store),
            ("banned", mRichKit(availability: .banned).store),
        ] + ["sample", "justjoined", "empty", "restore", "maintenance", "endedall"].map { ("preview \($0)", DuoStore.makePreview(scenario: $0, now: now)) }
        for (name, store) in states {
            mAssertDraws(NavigationStack { DuoDiagnosticsView(duoStore: store) }, name)
        }
        let rich = mRichKit().store
        mAssertDraws(NavigationStack { DuoDiagnosticsView(duoStore: rich) }.environment(\.dynamicTypeSize, .accessibility5), "largest text")
        mAssertDraws(NavigationStack { DuoDiagnosticsView(duoStore: rich) }.environment(\.colorScheme, .dark), "dark")
    }

    func testReportSheetDrawsInEveryState() {
        let rich = mRichKit()
        let live = rich.store.duos[0]
        let bare = DuoTestKit(now: now)
        let preview = DuoStore.makePreview(scenario: "justjoined", now: now)
        mAssertDraws(DuoReportSheet(duoStore: rich.store, duo: live), "no reason picked")
        for reason in DuoReportMail.Reason.allCases {
            mAssertDraws(DuoReportSheet(duoStore: rich.store, duo: live, reason: reason), "reason \(reason.rawValue) picked")
        }
        mAssertDraws(DuoReportSheet(duoStore: bare.store, duo: DuoFixtures.duo(now: now), reason: .offensiveName), "no member")
        mAssertDraws(DuoReportSheet(duoStore: preview, duo: preview.duos[0]), "preview justjoined")
        mAssertDraws(DuoReportSheet(duoStore: rich.store, duo: live, reason: .notThePersonIInvited).environment(\.dynamicTypeSize, .accessibility5),
                     "largest text")
    }

    // MARK: - Nothing is sent

    func testAppearingAndCopyingCallNoService() async {
        let kit = mRichKit()
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let diagnostics = mHost(NavigationStack { DuoDiagnosticsView(duoStore: kit.store, route: MFakeMail().route, pasteboard: pasteboard) })
        let report = mHost(DuoReportSheet(duoStore: kit.store, duo: kit.store.duos[0], route: MFakeMail().route))
        for _ in 0..<5 { await Task.yield() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        for _ in 0..<5 { await Task.yield() }
        mAssertNothingWasAsked(of: kit, "appearing")

        // Copy, through the button itself.
        let copy = try? XCTUnwrap(mNode("duo.diagnostics.supportid.copy", in: diagnostics.window))
        XCTAssertEqual(copy?.label, "Copy")
        XCTAssertTrue(copy?.object.accessibilityActivate() ?? false)
        XCTAssertTrue(mWait { pasteboard.string == "ABCD-1234-EFGH" }, "Copy puts the Support ID as it is shown")
        for _ in 0..<5 { await Task.yield() }
        mAssertNothingWasAsked(of: kit, "Copy")

        let bare = DuoTestKit(now: now)
        pasteboard.string = "untouched"
        DuoDiagnosticsView.mCopySupportID(from: bare.store, to: pasteboard)
        XCTAssertEqual(pasteboard.string, "untouched", "with no Support ID there is nothing to copy")
        DuoDiagnosticsView.mCopySupportID(from: mRichKit(availability: mRestore).store, to: pasteboard)
        XCTAssertEqual(pasteboard.string, "untouched", "nor while the restore question is up")
        mAssertNothingWasAsked(of: bare, "Copy with no member")
        diagnostics.window.isHidden = true
        report.window.isHidden = true
    }

    private func mAssertNothingWasAsked(of kit: DuoTestKit, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(kit.transport.calls, [], "\(when) sent a request", file: file, line: line)
        XCTAssertEqual(kit.sync.calls, [], "\(when) asked the sync engine", file: file, line: line)
        XCTAssertEqual(kit.joining.calls, [], "\(when) asked the joining service", file: file, line: line)
        XCTAssertEqual(kit.exiting.calls, [], "\(when) asked the exit service", file: file, line: line)
        XCTAssertEqual(kit.ops.drains + kit.ops.discards + kit.ops.identityBoundDiscards, 0, "\(when) touched the op queue", file: file, line: line)
        XCTAssertTrue(kit.push.reasons.isEmpty && kit.push.tokens.isEmpty && kit.push.clearedLast == 0, "\(when) asked the push service", file: file, line: line)
        XCTAssertTrue(kit.announcer.delivered.isEmpty && kit.announcer.removedFor.isEmpty && kit.announcer.removedAll == 0
                      && kit.announcer.removedPending == 0, "\(when) asked the notifier", file: file, line: line)
        XCTAssertEqual(kit.background.scheduled, 0, "\(when) scheduled a background refresh", file: file, line: line)
        XCTAssertEqual(kit.identity.prepared, 0, "\(when) asked the identity", file: file, line: line)
        XCTAssertTrue(kit.identity.stored.isEmpty && kit.identity.discardCount == 0 && kit.identity.continued == 0, file: file, line: line)
        XCTAssertTrue(kit.attester.attestedNewKeys == 0 && kit.attester.assertions.isEmpty, "\(when) attested", file: file, line: line)
        XCTAssertTrue(kit.sleeper.delays.isEmpty, file: file, line: line)
    }

    // MARK: - What leaves the phone

    func testTheExportMailIsTheBugReportHeaderAndTheDuoFactsAndNothingPersonal() {
        for availability in [DuoAvailability.available, mRestore] {
            let kit = mRichKit(availability: availability)
            let body = DuoDiagnosticsView.mExportBody(for: kit.store, now: now)
            XCTAssertTrue(body.hasPrefix(Diagnostics.summary + "\n\nDuo Streaks\n"), "the app's existing header comes first")
            let lines = body.components(separatedBy: "\n")
            let restore = availability != .available
            for expected in [restore ? "Support ID: —" : "Support ID: ABCD-1234-EFGH", "Tier: attested",
                             "Queued requests: 1", "Enabled: on", "Time zone: Europe/London", "Window: 08:00-22:00",
                             "Duo 6d2a0000", "Seq: 12", "Duo 0b1c2d3e", "Exported: 2026-09-21T14:13:20Z",
                             "Availability: \(restore ? "restore question" : "available")"] {
                XCTAssertTrue(lines.contains(expected), "\(expected) is missing:\n\(body)")
            }
            XCTAssertEqual(lines.filter { $0 == "App version: \(DuoConfig.client.appVersion)" }.count, 1,
                           "the version is said once, by the header, when the Duo server is told the same")
            XCTAssertEqual(lines.filter { $0.hasPrefix("iOS version: ") }.count, 1)
            XCTAssertEqual(lines.filter { $0.hasPrefix("conflict 409 ") }.count, 5, "five recent errors")
            XCTAssertTrue(lines.contains("Last error: conflict 409 0000000000000001 2026-09-21T14:12:20Z"), "the duo's own last error")
            XCTAssertEqual(lines.filter { $0.hasPrefix("409 ") }.count, 10, "ten recent requests")
            XCTAssertTrue(lines.contains("409 0000000000000001 2026-09-21T14:12:20Z"), "the newest request first, in UTC")
            for word in mForbidden {
                XCTAssertFalse(body.localizedCaseInsensitiveContains(word), "\(word) reached the export")
            }
            if restore { XCTAssertFalse(body.contains("ABCD"), "no Support ID while the restore question is up") }
        }
    }

    func testTheScreenDrawsTheReportTheExportPrints() {
        let kit = mRichKit()
        let report = DuoDiagnosticsView.mReport(for: kit.store, systemVersion: "26.5")
        XCTAssertEqual(report.supportID, "ABCD-1234-EFGH")
        XCTAssertEqual(report.summary.map(\.value), ["ABCD-1234-EFGH", "attested", DuoConfig.client.appVersion, "26.5", "available", "1"])
        XCTAssertEqual(report.duos.map(\.title), ["Duo 6d2a0000", "Duo 0b1c2d3e"], "one section per duo, by the start of its id")
        XCTAssertEqual(report.errors.count, 5)
        XCTAssertEqual(report.requests.count, 10)
        let header = Diagnostics.summary
        XCTAssertEqual(DuoDiagnosticsView.mExportBody(for: kit.store, now: now),
                       header + "\n\n" + DuoDiagnosticsExport.text(DuoDiagnosticsView.mReport(for: kit.store), now: now,
                                                                   alreadySaid: header.components(separatedBy: "\n")),
                       "the mail is printed from the very report the screen draws")
        let mail = DuoDiagnosticsView.mExportMail(for: kit.store, now: now)
        XCTAssertEqual([mail.recipient, mail.subject], ["support@hydrodrop.us", "HydroDrop bug report: Diagnostics"])
        XCTAssertEqual(mail.body, DuoDiagnosticsView.mExportBody(for: kit.store, now: now))

        let bare = DuoDiagnosticsView.mReport(for: DuoTestKit(now: now).store)
        XCTAssertNil(bare.supportID, "no Copy button before GET /me has answered")
        XCTAssertEqual(bare.summary.first?.value, "—", "the Support ID reads as a dash")
        XCTAssertEqual(bare.summary.last?.value, "0")
        XCTAssertTrue(bare.duos.isEmpty && bare.errors.isEmpty && bare.requests.isEmpty)
        XCTAssertNil(DuoDiagnosticsView.mReport(for: mRichKit(availability: mRestore).store).supportID, "none while the restore question is up")
    }

    func testTheReportMailIsTheReasonTheDuoAndTheSupportIDOnly() {
        let kit = mRichKit()
        let live = kit.store.duos[0]
        for reason in DuoReportMail.Reason.allCases {
            let mail = DuoReportSheet.mMail(reason: reason, duo: live, store: kit.store)
            XCTAssertEqual(mail.recipient, "support@hydrodrop.us")
            XCTAssertEqual(mail.subject, "Duo report")
            XCTAssertEqual(mail.body, "Reason: \(DuoCopy.reportReasons[reason.rawValue])\nDuo: \(live.wireID)\nSupport ID: ABCD-1234-EFGH")
            for word in mForbidden where word != live.wireID {
                XCTAssertFalse(mail.body.localizedCaseInsensitiveContains(word) || mail.subject.localizedCaseInsensitiveContains(word),
                               "\(word) reached the report")
            }
        }
        let bare = DuoTestKit(now: now)
        XCTAssertTrue(DuoReportSheet.mMail(reason: .offensiveName, duo: live, store: bare.store).body.hasSuffix("\nSupport ID: unknown"))
        let restore = mRichKit(availability: mRestore)
        XCTAssertTrue(DuoReportSheet.mMail(reason: .offensiveName, duo: live, store: restore.store).body.hasSuffix("\nSupport ID: unknown"),
                      "no Support ID while the restore question is up (D76)")
    }

    // MARK: - The report sheet's own rules, on the real sheet

    func testTheReportSheetsControlsCarryTheirIDsAndSendWaitsForAReason() throws {
        XCTAssertTrue(DuoReportSheet.mSendDisabled(nil))
        for reason in DuoReportMail.Reason.allCases { XCTAssertFalse(DuoReportSheet.mSendDisabled(reason)) }
        XCTAssertEqual(DuoReportSheet.mExplanation, "This opens an email to support, from your own email address, with the reason you picked, this duo's id and your Support ID. You can read it before you send it.")

        let kit = mRichKit()
        let shown = mPresentReportSheet(kit: kit, fake: MFakeMail())
        let window = shown.hosted.window
        for reason in DuoReportMail.Reason.allCases {
            let node = try XCTUnwrap(mNode("duo.report.reason.\(reason.rawValue)", in: window), "reason \(reason.rawValue) has its id")
            XCTAssertEqual(node.label, DuoCopy.reportReasons[reason.rawValue])
            XCTAssertFalse(node.traits.contains(.selected))
        }
        let send = try XCTUnwrap(mNode("duo.report.send", in: window))
        XCTAssertEqual(send.label, "Send")
        XCTAssertTrue(send.traits.contains(.notEnabled), "Send waits for a reason")
        XCTAssertTrue(mNodes(in: window).contains { $0.label == DuoReportSheet.mExplanation }, "the line above Send says what the mail holds")
        XCTAssertFalse(mNodes(in: window).contains { $0.label.contains("Nothing else is sent") })

        XCTAssertTrue(try XCTUnwrap(mNode("duo.report.reason.1", in: window)).object.accessibilityActivate())
        XCTAssertTrue(mWait { self.mNode("duo.report.send", in: window).map { !$0.traits.contains(.notEnabled) } ?? false }, "a reason enables Send")
        XCTAssertTrue(mWait { self.mNode("duo.report.reason.1", in: window)?.traits.contains(.selected) ?? false }, "the pick is marked selected")
        XCTAssertFalse(try XCTUnwrap(mNode("duo.report.reason.0", in: window)).traits.contains(.selected))
        for node in mNodes(in: window) {
            for word in mForbidden { XCTAssertFalse(node.label.localizedCaseInsensitiveContains(word), "\(word) is on the sheet") }
        }
        window.isHidden = true
    }

    func testCancelClosesTheReportSheetAndHandsNothingOver() throws {
        let kit = mRichKit()
        let fake = MFakeMail()
        let shown = mPresentReportSheet(kit: kit, fake: fake)
        XCTAssertTrue(try XCTUnwrap(mNodes(in: shown.hosted.window).first { $0.label == "Cancel" }).object.accessibilityActivate())
        XCTAssertTrue(mWait { !shown.presenter.isPresented }, "Cancel closes the sheet")
        XCTAssertTrue(fake.composed.isEmpty && fake.opened.isEmpty)
        mAssertNothingWasAsked(of: kit, "Cancel")
        shown.hosted.window.isHidden = true
    }

    func testASentMailClosesTheSheetOnceTheComposerHasGoneAndACancelledOneDoesNot() throws {
        for (result, closes) in [(MFMailComposeResult.sent, true), (.cancelled, false), (.saved, false), (.failed, false)] {
            let kit = mRichKit()
            let fake = MFakeMail()
            fake.canCompose = true
            fake.composerResult = result
            let shown = mPresentReportSheet(kit: kit, fake: fake, reason: .notThePersonIInvited)
            let window = shown.hosted.window
            XCTAssertTrue(try XCTUnwrap(mNode("duo.report.send", in: window)).object.accessibilityActivate())
            XCTAssertTrue(mWait { fake.composed.count == 1 }, "Send opens the composer (result \(result.rawValue), \(fake.composed.count) mails)")
            let mail = try XCTUnwrap(fake.composed.first)
            XCTAssertEqual([mail.recipient, mail.subject], ["support@hydrodrop.us", "Duo report"])
            XCTAssertEqual(mail.body, "Reason: Not the person I invited\nDuo: \(DuoFixtures.duoID.uuidString.lowercased())\nSupport ID: ABCD-1234-EFGH")
            XCTAssertTrue(mWait(timeout: 4) { fake.finished }, "the composer reported \(result.rawValue)")
            if closes {
                XCTAssertTrue(mWait(timeout: 4) { !shown.presenter.isPresented }, "a sent mail closes the sheet")
            } else {
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                XCTAssertTrue(shown.presenter.isPresented, "result \(result.rawValue) leaves the sheet open")
            }
            XCTAssertFalse(mAlertIsUp(in: window), "no alert after the composer (no \"Thanks\")")
            XCTAssertTrue(fake.opened.isEmpty)
            window.isHidden = true
        }
    }

    func testTheMailtoLinkClosesTheSheetOnlyWhenSomethingTookIt() throws {
        for opens in [true, false] {
            let kit = mRichKit()
            let fake = MFakeMail()
            fake.openResult = opens
            let shown = mPresentReportSheet(kit: kit, fake: fake, reason: .offensiveName)
            let window = shown.hosted.window
            XCTAssertTrue(try XCTUnwrap(mNode("duo.report.send", in: window)).object.accessibilityActivate())
            XCTAssertTrue(mWait { fake.opened.count == 1 })
            let link = try XCTUnwrap(fake.opened.first)
            let items = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first?.value, "Duo report")
            XCTAssertEqual(items.last?.value, "Reason: Offensive name\r\nDuo: \(DuoFixtures.duoID.uuidString.lowercased())\r\nSupport ID: ABCD-1234-EFGH")
            if opens {
                XCTAssertTrue(mWait { !shown.presenter.isPresented }, "the mail app took the link: the sheet closes")
                XCTAssertFalse(mAlertIsUp(in: window))
            } else {
                XCTAssertTrue(mWait { self.mAlertIsUp(in: window) }, "nothing took the link: the person is told")
                XCTAssertTrue(shown.presenter.isPresented, "and the sheet, with their pick, stays")
            }
            XCTAssertTrue(fake.composed.isEmpty)
            window.isHidden = true
        }
    }

    // MARK: - The Diagnostics screen's own rules, on the real screen

    func testTheDiagnosticsControlsCarryTheirIDsAndExportHandsTheMailOver() throws {
        let kit = mRichKit()
        let fake = MFakeMail()
        fake.canCompose = true
        fake.composerResult = nil
        let hosted = mHost(NavigationStack { DuoDiagnosticsView(duoStore: kit.store, route: fake.route, pasteboard: UIPasteboard.withUniqueName()) })
        let window = hosted.window
        XCTAssertNotNil(mNode("duo.diagnostics.supportid", in: window), "the Support ID row keeps its id")
        XCTAssertTrue(mNodes(in: window).contains { $0.label == "Support ID, ABCD-1234-EFGH" }, "the id and its label read as one")
        XCTAssertEqual(mNode("duo.diagnostics.supportid.copy", in: window)?.label, "Copy", "Copy is a control of its own")
        let export = try XCTUnwrap(mNode("duo.diagnostics.export", in: window))
        XCTAssertEqual(export.label, "Export diagnostics")
        XCTAssertTrue(export.object.accessibilityActivate())
        XCTAssertTrue(mWait { fake.composed.count == 1 })
        let mail = try XCTUnwrap(fake.composed.first)
        XCTAssertEqual([mail.recipient, mail.subject], ["support@hydrodrop.us", "HydroDrop bug report: Diagnostics"])
        XCTAssertTrue(mail.body.hasPrefix(Diagnostics.summary + "\n\nDuo Streaks\nExported: "))
        XCTAssertTrue(mail.body.contains("\nSupport ID: ABCD-1234-EFGH\n"))
        XCTAssertTrue(fake.opened.isEmpty)
        mAssertNothingWasAsked(of: kit, "Export")
        window.isHidden = true

        let restore = mRichKit(availability: mRestore)
        let quiet = mHost(NavigationStack { DuoDiagnosticsView(duoStore: restore.store, route: MFakeMail().route) })
        XCTAssertNil(mNode("duo.diagnostics.supportid.copy", in: quiet.window), "no Copy while the restore question is up")
        XCTAssertTrue(mNodes(in: quiet.window).contains { $0.label == "Support ID, —" })
        quiet.window.isHidden = true
    }

    func testExportsLinkSaysSoWhenNothingCouldOpenIt() throws {
        for opens in [true, false] {
            let kit = mRichKit()
            let fake = MFakeMail()
            fake.openResult = opens
            let hosted = mHost(NavigationStack { DuoDiagnosticsView(duoStore: kit.store, route: fake.route) })
            XCTAssertTrue(try XCTUnwrap(mNode("duo.diagnostics.export", in: hosted.window)).object.accessibilityActivate())
            XCTAssertTrue(mWait { fake.opened.count == 1 })
            let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(fake.opened.first), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first?.value, "HydroDrop bug report: Diagnostics")
            XCTAssertTrue(items.last?.value?.hasPrefix(Diagnostics.summary.replacingOccurrences(of: "\n", with: "\r\n")) ?? false)
            if opens {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                XCTAssertFalse(mAlertIsUp(in: hosted.window))
            } else {
                XCTAssertTrue(mWait { self.mAlertIsUp(in: hosted.window) }, "a link nothing could open says so")
            }
            hosted.window.isHidden = true
        }
    }

    /// The whole screen, every row laid out: a duo is named by the start of its id, and no name,
    /// code, key or full id is anywhere on it.
    func testTheScreenNamesADuoByTheStartOfItsIDAndShowsNothingPersonal() {
        let kit = mRichKit()
        let hosted = mHost(NavigationStack { DuoDiagnosticsView(duoStore: kit.store, route: MFakeMail().route) }, height: 4000)
        let labels = mNodes(in: hosted.window).map(\.label)
        XCTAssertTrue(labels.contains("Duo 6d2a0000") && labels.contains("Duo 0b1c2d3e"), "\(labels)")
        XCTAssertTrue(labels.contains("Recent requests") && labels.contains("Recent errors"))
        XCTAssertTrue(labels.contains { $0.contains("0000000000000001") }, "the request ids are on screen")
        for label in labels {
            for word in mForbidden { XCTAssertFalse(label.localizedCaseInsensitiveContains(word), "\(word) is on screen: \(label)") }
        }
        hosted.window.isHidden = true
    }

    /// The op queue publishes nothing; the row reads it again while the screen is open.
    func testTheQueueLengthFollowsTheQueueWhileTheScreenIsOpen() {
        let kit = mRichKit()
        let hosted = mHost(NavigationStack { DuoDiagnosticsView(duoStore: kit.store, route: MFakeMail().route) })
        XCTAssertTrue(mWait { self.mNodes(in: hosted.window).contains { $0.label == "Queued requests, 1" } })
        kit.ops.enqueue(mOp("op-2", duo: kit.store.duos[0]))
        XCTAssertTrue(mWait(timeout: 4) { self.mNodes(in: hosted.window).contains { $0.label == "Queued requests, 2" } },
                      "a request queued while the screen is open shows within a second or so")
        mAssertNothingWasAsked(of: kit, "the queue row")
        hosted.window.isHidden = true
    }

    // MARK: - Helpers

    private func mPresentReportSheet(kit: DuoTestKit, fake: MFakeMail, reason: DuoReportMail.Reason? = nil)
        -> (hosted: (window: UIWindow, controller: UIHostingController<AnyView>), presenter: MPresenter) {
        let presenter = MPresenter()
        let duo = kit.store.duos[0]
        let route = fake.route
        let hosted = mHost(MSheetHost(presenter: presenter) {
            AnyView(DuoReportSheet(duoStore: kit.store, duo: duo, reason: reason, route: route))
        })
        XCTAssertTrue(mWait(timeout: 4) { self.mNode("duo.report.send", in: hosted.window) != nil }, "the sheet is up")
        // Its controls are in the tree while it is still sliding in, and a sheet asked for during
        // a presentation is dropped (repo CLAUDE.md), so wait for the presentation to finish.
        XCTAssertTrue(mWait(timeout: 4) {
            guard let sheet = hosted.window.rootViewController?.presentedViewController else { return false }
            return !sheet.isBeingPresented && sheet.transitionCoordinator == nil
        }, "the sheet has finished appearing")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (hosted, presenter)
    }

    private func mHost(_ view: some View, height: CGFloat = 844) -> (window: UIWindow, controller: UIHostingController<AnyView>) {
        let controller = UIHostingController(rootView: AnyView(view))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, controller)
    }

    private func mSnapshot(_ window: UIWindow) -> UIImage? {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.size == .zero ? nil : image
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes.
    private func mWait(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Every accessibility element in the window, and every container that carries an id.
    private func mNodes(in window: UIWindow) -> [MNode] {
        var found: [MNode] = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 60 else { return }
            let id = object.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                ? (object.value(forKey: "accessibilityIdentifier") as? String ?? "") : ""
            if object.isAccessibilityElement || !id.isEmpty {
                found.append(MNode(object: object, label: object.accessibilityLabel ?? "", id: id, traits: object.accessibilityTraits))
            }
            if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
                elements.forEach { walk($0, depth: depth + 1) }
            } else if let view = object as? UIView {
                view.subviews.forEach { walk($0, depth: depth + 1) }
            }
        }
        walk(window, depth: 0)
        return found
    }

    private func mNode(_ id: String, in window: UIWindow) -> MNode? { mNodes(in: window).first { $0.id == id } }

    /// Whether an alert is presented anywhere above the window's root.
    private func mAlertIsUp(in window: UIWindow) -> Bool {
        var controller = window.rootViewController?.presentedViewController
        while let current = controller {
            if current is UIAlertController { return true }
            controller = current.presentedViewController
        }
        return false
    }
}

// MARK: - Test doubles of this file

private struct MNode {
    let object: NSObject
    let label: String
    let id: String
    let traits: UIAccessibilityTraits
}

/// Switches on accessibility automation for the test process, as an XCUITest run does, so SwiftUI
/// builds its accessibility tree and a unit test can read and activate it. `_AXSSetAutomationEnabled`
/// in `libAccessibility` is private API, used here in the test bundle only (it is how Cash App's
/// AccessibilitySnapshot reaches SwiftUI); the value found is put back when the class is done.
private enum MAutomation {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    private static var initial: Int32?

    private static func functions() -> (get: Getter, set: Setter)? {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let get = dlsym(handle, "_AXSAutomationEnabled"), let set = dlsym(handle, "_AXSSetAutomationEnabled") else { return nil }
        return (unsafeBitCast(get, to: Getter.self), unsafeBitCast(set, to: Setter.self))
    }

    static func enable() {
        guard let functions = functions() else { return }
        initial = functions.get()
        functions.set(1)
    }

    static func restore() {
        guard let functions = functions(), let initial else { return }
        functions.set(initial)
    }
}

/// Presents the sheet for real, so Cancel and a sent mail can be seen to close it.
@MainActor
private final class MPresenter: ObservableObject {
    @Published var isPresented = true
}

private struct MSheetHost: View {
    @ObservedObject var presenter: MPresenter
    let sheet: () -> AnyView

    var body: some View {
        Color.clear.sheet(isPresented: $presenter.isPresented) { sheet() }
    }
}

/// Stands in for Mail and for `UIApplication.open`, records what a view hands over, and answers
/// as the test says. Its composer reports `composerResult` a moment after it appears.
private final class MFakeMail {
    var canCompose = false
    var openResult = true
    var composerResult: MFMailComposeResult? = .sent
    private(set) var opened: [URL] = []
    private(set) var composed: [MMail] = []
    private(set) var finished = false

    var route: MMailRoute {
        MMailRoute(
            canCompose: { [unowned self] in canCompose },
            open: { [unowned self] url, done in
                opened.append(url)
                done(openResult)
            },
            composer: { [unowned self] mail, finish in
                // SwiftUI may build a sheet's content more than once; it is one mail handed over.
                if !composed.contains(where: { $0.id == mail.id }) { composed.append(mail) }
                return AnyView(MFakeComposer(result: composerResult) { result in
                    self.finished = true
                    finish(result)
                })
            })
    }
}

private struct MFakeComposer: View {
    let result: MFMailComposeResult?
    let finish: (MFMailComposeResult) -> Void

    var body: some View {
        Text(verbatim: "composer")
            .onAppear {
                guard let result else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish(result) }
            }
    }
}
#endif
