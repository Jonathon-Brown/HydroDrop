#if DUO_V2
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import HydroDrop

/// Stage G's views: the card, the Today section, the suggestion, the notice cards, the card's
/// buttons and Today's wiring of them, against a real store over fakes or a preview store.
///
/// Most of these host the view in a window, turn the accessibility tree on, and find and press
/// each control by the identifier the integration pass's UI test uses, so a button that calls the
/// wrong thing, loses its identifier, or is not there at all fails a test (the review that found
/// 25 of 28 view mutants surviving the first version of this file, 2026-10-08). What each card says
/// line by line is `DuoCardModelTests`' job (HydroCore).
@MainActor
final class DuoCardViewTests: XCTestCase {
    /// The scenarios are built against this moment, and every model below is asked about it, so a
    /// run that crosses midnight cannot change an answer halfway.
    private let now = Date()
    private let english = Locale(identifier: "en_US")
    private var hosts: [GHost] = []

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(GAutomation.enable(), "the accessibility tree is needed to find the controls")
    }

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts = []
        GAutomation.restore()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func host<V: View>(_ view: V, width: CGFloat = 390, height: CGFloat = 900, size: DynamicTypeSize = .large) throws -> GHost {
        let made = try GHost(view.environment(\.dynamicTypeSize, size), width: width, height: height, size: size)
        hosts.append(made)
        return made
    }

    private func render(_ view: some View, file: StaticString = #filePath, line: UInt = #line) {
        let renderer = ImageRenderer(content: AnyView(view))
        renderer.proposedSize = ProposedViewSize(width: 390, height: 844)
        XCTAssertNotNil(renderer.uiImage, "the view drew nothing or failed to lay out", file: file, line: line)
    }

    /// The view's pixels, drawn at a fixed width and scale, for comparing two drawings.
    private func pixels(_ view: some View, width: CGFloat = 390) -> GBitmap? {
        let renderer = ImageRenderer(content: AnyView(view.frame(width: width).environment(\.colorScheme, .light)))
        renderer.scale = 2
        return renderer.cgImage.map(GBitmap.init)
    }

    /// How tall the view is at the width of a phone: 0 for a view that draws nothing.
    private func height(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: AnyView(view))
        return host.sizeThatFits(in: CGSize(width: 390, height: 10_000)).height
    }

    private func scenario(_ name: String) -> DuoStore { DuoStore.makePreview(scenario: name, now: now) }

    private func cardModel(_ duo: DuoState, _ store: DuoStore) -> DuoCardModel {
        DuoCard.model(for: duo, in: store, now: now, locale: english)
    }

    /// A preview store over a suite this test names and the test kit's janitor removes, for a
    /// test that writes.
    private func ownedPreviewStore(duos: [DuoState]) -> DuoStore {
        let suite = "DuoCardViewTests.\(UUID().uuidString)"
        DuoSuiteJanitor.shared.track(suite)
        return DuoStore.makePreview(duos: duos, cache: DuoCache(defaults: UserDefaults(suiteName: suite)!))
    }

    /// A duo whose partner joined an hour ago, so "Not them?" applies.
    private func justJoined(_ name: String, id: UUID = UUID()) -> DuoState {
        var duo = DuoFixtures.duo(id: id, partner: name, now: now)
        duo.joinedAt = now.addingTimeInterval(-3600)
        return duo
    }

    private func silent(_ name: String = "Sam") -> DuoState {
        var duo = DuoFixtures.duo(partner: name, now: now)
        duo.partnerLastWriteDay = DayKey.key(for: now.addingTimeInterval(-8 * 86_400))
        return duo
    }

    /// A text style's line height at a text size, for telling a wrapped label from a cut one.
    private func lineHeight(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).lineHeight
    }

    private func assertTappable(_ element: NSObject?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let frame = element?.accessibilityFrame else { return XCTFail("\(what) not found", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(what) is \(frame.width) wide", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(what) is \(frame.height) tall", file: file, line: line)
    }

    // MARK: - Every scenario draws

    func testEveryViewDrawsInEveryPreviewScenario() {
        XCTAssertEqual(DuoStore.previewScenarioNames.count, 16)
        for name in DuoStore.previewScenarioNames {
            let store = scenario(name)
            if !store.duos.isEmpty { render(DuoCardsSection(duoStore: store)) }
            if store.hasNoticeCards { render(DuoNoticeCards(duoStore: store, onReconnect: {})) }
            for duo in store.duos {
                render(DuoCard(duoStore: store, duo: duo))
                render(DuoCard(duoStore: store, duo: duo, showsBackground: false))
                if !DuoCardActions.actions(for: duo, in: store, now: now).isEmpty {
                    render(DuoCardActions(duoStore: store, duo: duo))
                }
            }
        }
        render(DuoInviteCard(onInvite: {}, onDismiss: {}))
    }

    func testTheCardsDrawAtTheLargestTextSizeAndInDarkMode() {
        for name in ["sample", "waiting", "silent", "streak100", "demo", "endedall", "restore", "disconnected", "banned", "newdevice"] {
            let store = scenario(name)
            for duo in store.duos {
                render(DuoCard(duoStore: store, duo: duo).environment(\.dynamicTypeSize, .accessibility5))
                render(DuoCard(duoStore: store, duo: duo).environment(\.colorScheme, .dark))
            }
            if store.hasNoticeCards {
                render(DuoNoticeCards(duoStore: store, onReconnect: {}).environment(\.dynamicTypeSize, .accessibility5))
            }
        }
        render(DuoInviteCard(onInvite: {}, onDismiss: {}).environment(\.dynamicTypeSize, .accessibility5))
    }

    // MARK: - What each scenario says

    func testEachScenariosCardSaysWhatItShould() throws {
        let waiting = scenario("waiting")
        let waitingModel = cardModel(try XCTUnwrap(waiting.duos.first), waiting)
        XCTAssertEqual(waitingModel.phase, .waiting)
        XCTAssertEqual(waitingModel.streakText, "0", "the sample's stray rows make no shared streak before anyone joins")
        XCTAssertEqual(waitingModel.partner.line, "Not here yet")

        let silentStore = scenario("silent")
        let silentModel = cardModel(try XCTUnwrap(silentStore.duos.first), silentStore)
        let fiveDaysAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -5, to: now))
        XCTAssertEqual(silentModel.notSeenLine, DuoCopy.notSeenSince(try XCTUnwrap(DuoCardModel.shortDay(DayKey.key(for: fiveDaysAgo), locale: english))))

        let hundred = scenario("streak100")
        XCTAssertEqual(cardModel(try XCTUnwrap(hundred.duos.first), hundred).streakText, "100+ days")

        let demo = scenario("demo")
        XCTAssertTrue(cardModel(try XCTUnwrap(demo.duos.first), demo).showsSampleBadge)

        let all = scenario("endedall")
        XCTAssertEqual(all.duos.map { cardModel($0, all).endedLine }, ["\u{2068}Alex\u{2069} left this duo.", nil, nil, nil, nil, nil, nil],
                       "only the partner's own end has approved wording")
    }

    func testMyOwnSideIsDrawnFromTheLogNotFromWhatWasLastSent() throws {
        let store = scenario("justjoined")
        let duo = try XCTUnwrap(store.duos.first)
        let today = DayKey.key(for: now)
        XCTAssertNil(duo.status(of: duo.myRole, on: today), "the duo holds nothing about my today")
        XCTAssertEqual(cardModel(duo, store).mine.line, "Nothing yet today")
        store.latest = DuoLogSummary(totalsByDay: [today: 2_000], goalML: 2_000, earliestEntryDay: today)
        XCTAssertEqual(cardModel(duo, store).mine.line, "Goal met", "the log as it stands, so my droplet never lags my drinks")
        store.latest = DuoLogSummary(totalsByDay: [today: 1_000], goalML: 2_000, earliestEntryDay: today)
        XCTAssertEqual(cardModel(duo, store).mine.line, "Halfway there")
    }

    // MARK: - Drawn, not just said

    func testOnlyTheDropletFadesForAPartnerWhoHasNotJoined() throws {
        let side = DuoCardModel.Side(role: .partner, name: "Your partner", skin: "forest", progressBucket: 0, goalMet: false,
                                     line: "Not here yet", isDimmed: false)
        var faded = side
        faded.isDimmed = true
        let plain = try XCTUnwrap(pixels(DuoCardSide(side: side), width: 120))
        let again = try XCTUnwrap(pixels(DuoCardSide(side: side), width: 120))
        let dimmed = try XCTUnwrap(pixels(DuoCardSide(side: faded), width: 120))
        XCTAssertEqual(plain.bytes, again.bytes, "the same side draws the same way twice, or this test proves nothing")
        // The droplet is 84 points tall (MascotView draws 1.5 times its size); the words are below it.
        let dropletRows = 0..<(80 * 2)
        let wordRows = (92 * 2)..<plain.height
        XCTAssertGreaterThan(plain.height, 100 * 2, "the words are there to compare")
        XCTAssertNotEqual(plain.rows(dropletRows), dimmed.rows(dropletRows), "the droplet is faded")
        XCTAssertEqual(plain.rows(wordRows), dimmed.rows(wordRows), "the words are not: faded, they fell to about 1.6:1 in dark mode")
    }

    func testTheSampleBadgeAndTheNotSeenLineAreDrawn() throws {
        let store = scenario("empty")
        var sample = DuoStore.previewDuo(partner: "Sam", joined: true, now: now, metDays: 2)
        sample.partnerIsDemo = true
        var real = sample
        real.partnerIsDemo = false
        XCTAssertNotEqual(try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: sample))).bytes,
                          try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: real))).bytes, "the Sample badge is drawn")
        XCTAssertEqual(try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: real))).bytes,
                       try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: real))).bytes)

        let quiet = DuoStore.previewDuo(partner: "Sam", joined: true, now: now, metDays: 0,
                                        partnerLastWriteDay: DayKey.key(for: now.addingTimeInterval(-6 * 86_400)))
        var recent = quiet
        recent.partnerLastWriteDay = DayKey.key(for: now)
        XCTAssertNotNil(cardModel(quiet, store).notSeenLine)
        XCTAssertNotEqual(try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: quiet))).bytes,
                          try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: recent))).bytes, "the not-seen line is drawn")
    }

    func testAQueuedLeaveSaysItHasNotGoneYetOnTheCard() async throws {
        let store = scenario("empty")
        var leaving = DuoStore.previewDuo(partner: "Sam", joined: true, now: now, metDays: 2, endedBy: .owner)
        leaving.pendingOp = .leave
        var gone = leaving
        gone.pendingOp = nil
        XCTAssertEqual(cardModel(leaving, store).pendingLine, "Waiting for a connection to finish this.")
        XCTAssertNotEqual(try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: leaving))).bytes,
                          try XCTUnwrap(pixels(DuoCard(duoStore: store, duo: gone))).bytes, "the line is drawn")
        let card = try host(DuoCard(duoStore: store, duo: leaving).padding(16))
        await gSettle()
        XCTAssertEqual(card.element("duo.card")?.accessibilityLabel, "Your duo with Sam ended. Waiting for a connection to finish this.")
    }

    func testNamesAreDrawnAsTheyCameNotAsMarkdown() async throws {
        let name = "**Sam** _it_ [x](https://e.x) `y`"
        let side = DuoCardModel.Side(role: .partner, name: name, skin: "forest", progressBucket: 50, goalMet: false,
                                     line: "Halfway there", isDimmed: false)
        let sideHost = try host(DuoCardSide(side: side).padding(16))
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: name, myName: "Jo"))
        let notice = try host(DuoNoticeCards(duoStore: kit.store) {})
        await gSettle()
        XCTAssertNotNil(sideHost.elements.first { $0.accessibilityLabel == name }, "drawn verbatim, asterisks and brackets and all")
        XCTAssertNotNil(notice.elements.first { ($0.accessibilityLabel ?? "").contains(name) }, "the restore question, verbatim")
    }

    func testNotThemIsRed() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let duo = justJoined("Sam")
        kit.store.upsert(duo)
        // Under the tint the app's root sets (RootTabView), which is what turned the destructive role blue.
        let actions = try host(DuoCardActions(duoStore: kit.store, duo: duo).padding(16).tint(Color(red: 0.18, green: 0.56, blue: 0.93)),
                               height: 300)
        await gSettle()
        let frame = try XCTUnwrap(actions.element("duo.notthem")?.accessibilityFrame)
        let image = try XCTUnwrap(actions.snapshot().cgImage)
        let bitmap = GBitmap(image)
        let red = bitmap.count(in: frame, scale: CGFloat(image.width) / actions.window.bounds.width) { r, g, b in
            r > 0.6 && g < 0.45 && b < 0.45
        }
        XCTAssertGreaterThan(red, 20, "the destructive button is drawn in red, not the app's tint")
    }

    // MARK: - The section

    func testTheSectionDrawsNothingForNoDuosOneCardForOneAndPagesForFive() throws {
        XCTAssertEqual(height(DuoCardsSection(duoStore: scenario("empty"))), 0, "no duo, no row")
        XCTAssertEqual(height(DuoCardsSection(duoStore: scenario("restore"))), 0, "the restore question has no cards")
        let one = scenario("ended")
        let card = height(DuoCard(duoStore: one, duo: try XCTUnwrap(one.duos.first)))
        XCTAssertGreaterThan(card, 0)
        XCTAssertEqual(height(DuoCardsSection(duoStore: one)), card, accuracy: 0.5,
                       "one duo is the card as it is, and its empty buttons take no room")
        let five = scenario("full")
        XCTAssertEqual(five.duos.count, 5)
        XCTAssertGreaterThan(height(DuoCardsSection(duoStore: five)), card, "the pages and their dots")
    }

    func testEveryPageIsDrawnLiveDuosFirstEachWithItsButtonsAfterIt() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        var ended = DuoFixtures.duo(id: UUID(), partner: "Alex", now: now)
        ended.endedAt = now
        ended.endedBy = .partner
        var waiting = DuoFixtures.duo(id: UUID(), joined: false, partner: "", now: now)
        waiting.partnerSkin = ""
        let sam = justJoined("Sam", id: UUID())
        kit.store.replaceAll(with: [ended, waiting, sam])
        let section = try host(NavigationStack { DuoCardsSection(duoStore: kit.store).padding(16) })
        await gSettle(0.8)
        let order = section.axOrder()
        let cards = order.enumerated().filter { gID($0.element) == "duo.card" }
        XCTAssertEqual(cards.count, 3, "every page is drawn, not only the first")
        guard cards.count == 3 else { return }
        let labels = cards.map { $0.element.accessibilityLabel ?? "" }
        XCTAssertTrue(labels[0].hasPrefix("Duo streak with Sam."), "the live duo is page 1: \(labels)")
        XCTAssertTrue(labels[1].hasPrefix("Duo streak. Waiting"), "then the waiting one: \(labels)")
        XCTAssertTrue(labels[2].hasPrefix("Your duo with Alex ended."), "then the ended one: \(labels)")
        XCTAssertTrue(cards.allSatisfy { $0.element.accessibilityTraits.contains(.button) }, "each card is a link to the Duo screen")
        XCTAssertEqual(cards[0].element.accessibilityLabel, cardModel(sam, kit.store).spokenSummary)
        let notThem = try XCTUnwrap(order.firstIndex { gID($0) == "duo.notthem" }, "the buttons are under the cards, outside the link")
        XCTAssertGreaterThan(notThem, cards[0].offset, "read after its own card")
        XCTAssertLessThan(notThem, cards[1].offset, "and before the next one")
        XCTAssertEqual(order.filter { gID($0) == "duo.notthem" }.count, 1, "only the duo it applies to")
        XCTAssertEqual(section.element("duo.pages")?.accessibilityValue, "Page 1 of 3")
    }

    func testTheDotsFollowThePage() async throws {
        let store = scenario("full")
        let third = store.duos[2].id
        let opened = try host(NavigationStack { DuoCardsSection(duoStore: store, startPage: third) })
        let gone = try host(NavigationStack { DuoCardsSection(duoStore: store, startPage: UUID()) })
        await gSettle(0.8)
        XCTAssertEqual(opened.element("duo.pages")?.accessibilityValue, "Page 3 of 5", "the dots say the page that is showing")
        let pager = try XCTUnwrap(gScrollViews(opened.window).first { $0.contentSize.width > $0.bounds.width + 1 })
        XCTAssertEqual(pager.contentOffset.x, pager.bounds.width * 2, accuracy: 1, "and it is the page the pager shows")
        XCTAssertEqual(gone.element("duo.pages")?.accessibilityValue, "Page 1 of 5", "a cleared page leaves the first one current")
        // A swipe sets the page; SwiftUI does not report a scroll made in code, so the rule is held here.
        let ordered = DuoCardModel.pagerOrder(store.duos)
        XCTAssertEqual(DuoCardsSection.currentIndex(of: ordered, page: nil), 0)
        XCTAssertEqual(DuoCardsSection.currentIndex(of: ordered, page: ordered[3].id), 3)
        XCTAssertEqual(DuoCardsSection.currentIndex(of: ordered, page: UUID()), 0)
    }

    func testTheCurrentDotIsTheOneFilled() throws {
        let first = try XCTUnwrap(pixels(DuoPageDots(count: 3, current: 0).padding(4), width: 60))
        let second = try XCTUnwrap(pixels(DuoPageDots(count: 3, current: 1).padding(4), width: 60))
        XCTAssertNotEqual(first.bytes, second.bytes, "a different page fills a different dot")
        // The dots sit side by side across the middle row: the filled one is the darkest.
        let row = first.height / 2
        func darkest(_ bitmap: GBitmap) -> Int {
            let ink = (0..<bitmap.width).map { x in (x, bitmap.alpha(x: x, y: row) * (1 - bitmap.brightness(x: x, y: row))) }
            return ink.max { $0.1 < $1.1 }?.0 ?? -1
        }
        XCTAssertLessThan(darkest(first), darkest(second), "page 1 fills the left dot, page 2 the next")
    }

    // MARK: - The buttons under a card

    func testNotThemOpensTheConfirmationAndBlocksTheDuoItIsUnder() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let recorder = GRecordingExiting()
        kit.dependencies.exiting = recorder
        let alex = justJoined("Alex", id: UUID())
        let sam = justJoined("Sam", id: UUID())
        kit.store.replaceAll(with: [alex, sam])
        let actions = try host(DuoCardActions(duoStore: kit.store, duo: sam).padding(16))
        await gSettle()
        let notThem = try XCTUnwrap(actions.element("duo.notthem"))
        XCTAssertEqual(notThem.accessibilityLabel, DuoCopy.notThem)
        XCTAssertTrue(notThem.accessibilityActivate())
        var alert: UIAlertController?
        let shown = await gWait { alert = actions.topAlert; return alert != nil }
        XCTAssertTrue(shown, "Not them? asks first")
        XCTAssertTrue(recorder.calls.isEmpty, "and sends nothing before the answer")
        XCTAssertEqual(alert?.title, "Block \u{2068}Sam\u{2069}?")
        XCTAssertEqual(alert?.message, DuoCopy.blockMessage(partner: "\u{2068}Sam\u{2069}", onEndedCard: false, sharesAnotherDuo: false),
                       "the active card's message")
        XCTAssertEqual(alert?.actions.map(\.title), ["Block", "Cancel"])
        XCTAssertEqual(alert?.actions.first?.style, .destructive)
        let block = try XCTUnwrap(alert?.actions.first { $0.title == "Block" })
        try gRun(block)
        let blocked = await gWait { recorder.calls == ["block:\(sam.id)"] }
        XCTAssertTrue(blocked, "Block blocks the duo the button is under, not another: \(recorder.calls)")
    }

    /// Finding 1: with the age gate closed neither card action is offered, since both would send.
    func testNoCardActionWhileTheAgeGateIsClosed() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let quiet = silent()
        let fresh = justJoined("Alex")
        XCTAssertTrue(DuoCardActions.actions(for: quiet, in: kit.store, now: now).offersReconnect)
        XCTAssertTrue(DuoCardActions.actions(for: fresh, in: kit.store, now: now).offersNotThem)
        kit.dependencies.cache.requireAgeRecheck()
        kit.store.recheckAge()
        XCTAssertFalse(kit.store.ageAllowsSharing)
        XCTAssertFalse(DuoCardActions.actions(for: quiet, in: kit.store, now: now).offersReconnect)
        XCTAssertFalse(DuoCardActions.actions(for: fresh, in: kit.store, now: now).offersNotThem)
    }

    func testNotThemOnlyWhenThePhoneCanSendTheBlock() async throws {
        let duo = justJoined("Sam")
        let none = DuoTestKit()
        none.store.upsert(duo)
        XCTAssertFalse(DuoCardActions.actions(for: duo, in: none.store, now: now).offersNotThem, "no credential: the exit service refuses")

        let throwaway = DuoTestKit(credential: DuoFixtures.credential())
        throwaway.store.upsert(duo)
        XCTAssertTrue(DuoCardActions.actions(for: duo, in: throwaway.store, now: now).offersNotThem)
        throwaway.dependencies.cache.throwawayDeviceID = DuoFixtures.credential().deviceID
        XCTAssertFalse(DuoCardActions.actions(for: duo, in: throwaway.store, now: now).offersNotThem,
                       "only a Reconnect's throwaway: the block would be for another member's duo")
        let drawn = try host(DuoCardActions(duoStore: throwaway.store, duo: duo).padding(16))
        await gSettle()
        XCTAssertNil(drawn.element("duo.notthem"))

        let disconnected = DuoTestKit(credential: DuoFixtures.credential())
        disconnected.store.upsert(duo)
        disconnected.store.availability = .disconnected
        XCTAssertTrue(DuoCardActions.actions(for: duo, in: disconnected.store, now: now).offersNotThem,
                      "a superseded phone keeps its leave and block for 30 days")
        disconnected.store.availability = .banned
        XCTAssertFalse(DuoCardActions.actions(for: duo, in: disconnected.store, now: now).offersNotThem)
    }

    func testTheReconnectOfferPresentsTheCodeSheetAndTheSheetOutlivesTheOffer() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let duo = silent()
        kit.store.upsert(duo)
        kit.store.availability = .available
        let section = try host(NavigationStack { DuoCardsSection(duoStore: kit.store) })
        await gSettle()
        XCTAssertNil(section.element("duo.notthem"), "joined four days ago, so only the reconnect offer")
        let offer = try XCTUnwrap(section.element("duo.reconnectoffer"))
        XCTAssertEqual(offer.accessibilityLabel, "Reconnect \u{2068}Sam\u{2069}'s new phone")
        XCTAssertTrue(offer.accessibilityActivate())
        let presented = await gWait { section.presented != nil }
        XCTAssertTrue(presented, "the reconnect code sheet is presented")
        // The partner's phone writes while the sheet is up: the offer goes, the sheet stays.
        var back = duo
        back.partnerLastWriteDay = DayKey.key(for: now)
        kit.store.upsert(back)
        await gSettle(1.2)
        XCTAssertNil(section.element("duo.reconnectoffer"))
        XCTAssertNotNil(section.presented, "the sheet outlives the offer, and its request's answer with it")
        // A failure in the sheet that turns writes off must not close it before its error shows.
        kit.store.availability = .upgradeRequired
        await gSettle(1.2)
        XCTAssertNotNil(section.presented)
    }

    func testTheConfirmationOutlivesTheOffer() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let duo = justJoined("Sam")
        kit.store.upsert(duo)
        let section = try host(NavigationStack { DuoCardsSection(duoStore: kit.store) })
        await gSettle()
        XCTAssertTrue(try XCTUnwrap(section.element("duo.notthem")).accessibilityActivate())
        let shown = await gWait { section.topAlert != nil }
        XCTAssertTrue(shown)
        kit.store.availability = .banned
        await gSettle(1.2)
        XCTAssertNil(section.element("duo.notthem"))
        XCTAssertNotNil(section.topAlert, "the dialog is not torn down under the person reading it")
    }

    // MARK: - The notice cards

    func testTheNoticeCardsHaveSomethingExactlyWhenTheStoreSaysSo() {
        let store = scenario("empty")
        let availabilities: [DuoAvailability] = [.unknown, .available, .maintenance, .upgradeRequired, .disconnected, .banned,
                                                 .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil))]
        for availability in availabilities {
            for added in [false, true] {
                store.availability = availability
                store.newDeviceNotice = added
                let cards = DuoNoticeCards.cards(for: store)
                XCTAssertEqual(cards.isEmpty, !store.hasNoticeCards, "\(availability), device added \(added)")
                let drawn = height(DuoNoticeCards(duoStore: store, onReconnect: {}))
                if cards.isEmpty {
                    XCTAssertEqual(drawn, 0, "nothing to say, no empty row: \(availability)")
                } else {
                    XCTAssertGreaterThan(drawn, 0, "\(availability), device added \(added)")
                }
            }
        }
    }

    func testTheRestoreQuestionNeverUsesTheNameThisPhoneKept() {
        let store = scenario("empty")
        store.myDisplayName = "Jonathon"
        store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil))
        XCTAssertEqual(DuoNoticeCards.cards(for: store).first?.text, "This phone was connected to a duo with your partner. Continue as you?",
                       "the kept name may be the person now holding the phone")
    }

    func testTheRestoreButtonsTappedThroughTheTree() async throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let kit = DuoTestKit(credential: DuoFixtures.credential())
            kit.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
            var reconnects = 0
            let notice = try host(DuoNoticeCards(duoStore: kit.store) { reconnects += 1 }, width: 320, height: 1600, size: size)
            await gSettle()
            let carry = try XCTUnwrap(notice.element("duo.notice.restore.continue"), "\(size)")
            let fresh = try XCTUnwrap(notice.element("duo.notice.restore.fresh"), "\(size)")
            XCTAssertEqual(carry.accessibilityLabel, "Continue")
            XCTAssertEqual(fresh.accessibilityLabel, "Not me, start fresh")
            assertTappable(carry, "Continue \(size)")
            assertTappable(fresh, "Not me, start fresh \(size)")
            XCTAssertTrue(carry.accessibilityActivate())
            let continued = await gWait { kit.identity.continued == 1 }
            XCTAssertTrue(continued, "Continue answers the question (\(size))")
            XCTAssertEqual(kit.exiting.calls, [], "and does not start fresh (\(size))")
            XCTAssertTrue(fresh.accessibilityActivate())
            // Decision f: it asks first, in H12's title, and its confirm repeats the button.
            try await confirmStartFresh(on: notice, label: "Not me, start fresh", kit: kit)
            XCTAssertEqual(kit.identity.continued, 1)
            XCTAssertEqual(reconnects, 0)
            XCTAssertTrue(kit.transport.calls.isEmpty, "the services send, not the card")
        }
    }

    func testTheDisconnectedButtonsTappedThroughTheTree() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.upsert(DuoFixtures.duo())
        kit.store.availability = .disconnected
        XCTAssertTrue(kit.store.availability.allowsReconnect, "the reconnect sheet's button is enabled for exactly this state")
        var reconnects = 0
        let notice = try host(DuoNoticeCards(duoStore: kit.store) { reconnects += 1 })
        await gSettle()
        let had = try XCTUnwrap(notice.element("duo.notice.disconnected.reconnect"))
        let fresh = try XCTUnwrap(notice.element("duo.notice.disconnected.fresh"))
        XCTAssertEqual(had.accessibilityLabel, "I had a duo")
        XCTAssertEqual(fresh.accessibilityLabel, "Start fresh")
        assertTappable(had, "I had a duo")
        assertTappable(fresh, "Start fresh")
        XCTAssertTrue(had.accessibilityActivate())
        let reconnected = await gWait { reconnects == 1 }
        XCTAssertTrue(reconnected, "I had a duo opens the reconnect sheet")
        XCTAssertEqual(kit.exiting.calls, [])
        XCTAssertTrue(fresh.accessibilityActivate())
        // Finding 6: it asks first, as the Duo screen's own Start fresh row does.
        try await confirmStartFresh(on: notice, label: "Start fresh", kit: kit)
        XCTAssertEqual(reconnects, 1)
        XCTAssertEqual(kit.identity.continued, 0)
    }

    /// Start fresh's question on a notice card: nothing is wiped until its confirm is pressed.
    private func confirmStartFresh(on notice: GHost, label: String, kit: DuoTestKit) async throws {
        var alert: UIAlertController?
        let shown = await gWait { alert = notice.topAlert; return alert != nil }
        XCTAssertTrue(shown, "\(label) asks first")
        XCTAssertEqual(kit.exiting.calls, [], "and wipes nothing before the answer")
        XCTAssertEqual(alert?.title, DuoScreenModel.startFreshTitle)
        XCTAssertEqual(alert?.message, DuoScreenModel.startFreshCardMessage)
        XCTAssertEqual(alert?.actions.map(\.title), [label, "Cancel"])
        try gRun(try XCTUnwrap(alert?.actions.first { $0.title == label }))
        let started = await gWait { kit.exiting.calls == ["startFresh"] }
        XCTAssertTrue(started, label)
    }

    /// Stage B's leftover: Continue on the card is no sheet, so its failure is said in the alert at
    /// once and not left for the next join sheet to open already showing it.
    func testAFailedContinueOnTheCardIsSaidNowAndNotLeftForTheJoinSheet() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        kit.identity.onContinue = { kit.store.sheetError = DuoUserMessage.generic }
        await DuoNoticeCards(duoStore: kit.store, onReconnect: {}).perform(.continueAsRestored)?.value
        XCTAssertEqual(kit.identity.continued, 1)
        XCTAssertNil(kit.store.sheetError)
        XCTAssertEqual(kit.store.notice, DuoUserMessage.generic)
    }

    func testTheNewDeviceNoticeIsDismissedThroughTheTree() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.newDeviceNotice = true
        let notice = try host(DuoNoticeCards(duoStore: kit.store, onReconnect: {}))
        await gSettle()
        XCTAssertNotNil(notice.elements.first { $0.accessibilityLabel == "A device was added to your Duo Streaks." })
        let dismiss = try XCTUnwrap(notice.element("duo.notice.newdevice.dismiss"))
        XCTAssertEqual(dismiss.accessibilityLabel, "Dismiss")
        assertTappable(dismiss, "the new-device notice's close button")
        XCTAssertTrue(dismiss.accessibilityActivate())
        let gone = await gWait { !kit.store.newDeviceNotice }
        XCTAssertTrue(gone)
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    func testOnlyTheListedButtonsHaveIdentifiers() {
        let actions: [DuoNoticeAction] = [.continueAsRestored, .startFresh, .reconnect, .dismissNewDevice]
        let kinds: [DuoNoticeCard.Kind] = [.restore, .disconnected, .service, .newDevice]
        var named: Set<String> = []
        for kind in kinds { for action in actions { if let id = DuoNoticeCards.identifier(for: action, in: kind) { named.insert(id) } } }
        XCTAssertEqual(named, ["duo.notice.restore.continue", "duo.notice.restore.fresh", "duo.notice.disconnected.reconnect",
                               "duo.notice.disconnected.fresh", "duo.notice.newdevice.dismiss"])
    }

    // MARK: - The suggestion

    func testTheSuggestionCardsButtonsTappedThroughTheTree() async throws {
        var invited = 0, dismissed = 0
        let card = try host(DuoInviteCard(onInvite: { invited += 1 }, onDismiss: { dismissed += 1 }).padding(16))
        await gSettle()
        XCTAssertNotNil(card.element("duo.invitecard"))
        let invite = try XCTUnwrap(card.element("duo.invitecard.invite"))
        let close = try XCTUnwrap(card.element("duo.invitecard.dismiss"))
        XCTAssertEqual(invite.accessibilityLabel, "Invite someone")
        XCTAssertEqual(close.accessibilityLabel, "Dismiss")
        assertTappable(invite, "Invite someone")
        assertTappable(close, "the suggestion's close button")
        XCTAssertTrue(invite.accessibilityActivate())
        _ = await gWait { invited == 1 }
        XCTAssertEqual(invited, 1)
        XCTAssertEqual(dismissed, 0, "Invite someone does not dismiss")
        XCTAssertTrue(close.accessibilityActivate())
        _ = await gWait { dismissed == 1 }
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(invited, 1)
    }

    func testTakingUpOrClosingTheSuggestionIsTheLastOfIt() {
        let store = ownedPreviewStore(duos: [])
        XCTAssertTrue(store.shouldSuggestDuo(soloStreak: DuoInviteMoment.streakNeeded))
        store.dismissSuggestion()
        XCTAssertFalse(store.shouldSuggestDuo(soloStreak: 30))
        XCTAssertFalse(scenario("sample").shouldSuggestDuo(soloStreak: 30), "not for someone who has a duo")
    }

    // MARK: - The largest text sizes

    func testButtonLabelsWrapInsteadOfBeingCutShortAtTheLargestSize() async throws {
        let size = DynamicTypeSize.accessibility5
        let twoLines = 1.8 * lineHeight(.subheadline, .accessibilityExtraExtraExtraLarge)
        func assertWraps(_ element: NSObject?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            guard let frame = element?.accessibilityFrame else { return XCTFail("\(what) not found", file: file, line: line) }
            XCTAssertGreaterThan(frame.height, twoLines, "\(what) is one line tall (\(frame.height)): cut short", file: file, line: line)
        }
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let fresh = justJoined("Sam")
        let quiet = silent("Samantha")
        kit.store.replaceAll(with: [fresh, quiet])
        let notThem = try host(DuoCardActions(duoStore: kit.store, duo: fresh).padding(16), width: 320, height: 1200, size: size)
        let offer = try host(DuoCardActions(duoStore: kit.store, duo: quiet).padding(16), width: 320, height: 1200, size: size)
        let restore = DuoTestKit(credential: DuoFixtures.credential())
        restore.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let question = try host(DuoNoticeCards(duoStore: restore.store, onReconnect: {}), width: 320, height: 2400, size: size)
        let suggestion = try host(DuoInviteCard(onInvite: {}, onDismiss: {}).padding(16), width: 320, height: 2400, size: size)
        await gSettle(0.8)
        assertWraps(notThem.element("duo.notthem"), "Not them? Leave & block")
        assertWraps(offer.element("duo.reconnectoffer"), "Reconnect Samantha's new phone")
        assertWraps(question.element("duo.notice.restore.fresh"), "Not me, start fresh")
        assertWraps(suggestion.element("duo.invitecard.invite"), "Invite someone")
        assertTappable(notThem.element("duo.notthem"), "Not them?")
        assertTappable(offer.element("duo.reconnectoffer"), "the reconnect offer")
    }

    func testTheIconsTakeARowOfTheirOwnAtTheLargestSize() async throws {
        let size = DynamicTypeSize.accessibility5
        let suggestion = try host(DuoInviteCard(onInvite: {}, onDismiss: {}).padding(16), width: 320, height: 2400, size: size)
        let restore = DuoTestKit(credential: DuoFixtures.credential())
        restore.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let question = try host(DuoNoticeCards(duoStore: restore.store, onReconnect: {}).padding(16), width: 320, height: 2400, size: size)
        let regular = try host(DuoInviteCard(onInvite: {}, onDismiss: {}).padding(16), width: 390, height: 600)
        await gSettle(0.8)
        let title = try XCTUnwrap(suggestion.elements.first { $0.accessibilityLabel == "Streaks are better with company" })
        let close = try XCTUnwrap(suggestion.element("duo.invitecard.dismiss"))
        XCTAssertLessThanOrEqual(close.accessibilityFrame.maxY, title.accessibilityFrame.minY + 2,
                                 "the close button sits above the words, not in a column beside them")
        let sentence = try XCTUnwrap(question.elements.first { ($0.accessibilityLabel ?? "").hasPrefix("This phone was connected") })
        XCTAssertLessThan(sentence.accessibilityFrame.minX, 48, "the sentence starts at the card's edge, not after an icon column")
        let regularTitle = try XCTUnwrap(regular.elements.first { $0.accessibilityLabel == "Streaks are better with company" })
        XCTAssertGreaterThan(regularTitle.accessibilityFrame.minX, 40, "side by side at the ordinary sizes, as the iCloud card was")
    }

    // MARK: - Drawing sends nothing

    func testDrawingEveryViewSendsNothingAndRefreshesNothing() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.replaceAll(with: [justJoined("Sam", id: UUID()), silent()])
        kit.store.newDeviceNotice = true
        let availabilities: [DuoAvailability] = [.available, .maintenance, .disconnected, .banned,
                                                 .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))]
        for availability in availabilities {
            kit.store.availability = availability
            let drawn = try host(NavigationStack {
                VStack {
                    DuoNoticeCards(duoStore: kit.store, onReconnect: {})
                    DuoCardsSection(duoStore: kit.store)
                }
            })
            await gSettle(0.3)
            drawn.close()
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(kit.transport.calls.isEmpty)
        XCTAssertEqual(kit.sync.calls, [], "no refresh, no flush: Today refreshes on foreground, not the card")
        XCTAssertEqual(kit.identity.prepared, 0, "drawing never asks the identity")
        XCTAssertEqual(kit.joining.calls, [])
        XCTAssertEqual(kit.exiting.calls, [])
        XCTAssertTrue(kit.store.newDeviceNotice, "drawing the notice does not dismiss it")
    }

    // MARK: - Today

    /// One isolated store per history, retained for the process: a hosted Today's queries can
    /// outlive their window. Keep its directory too, rather than deleting files a late query uses.
    /// TemporaryStore avoids iOS 27's in-memory save exception and explicitly disables CloudKit.
    private static var todayContainers: [Int: (container: ModelContainer, directory: URL)] = [:]

    private func todayContainer(streakDays: Int) throws -> ModelContainer {
        if let made = Self.todayContainers[streakDays] { return made.container }
        let made = try TemporaryStore.make(for: SharedModelContainer.schema)
        let container = made.container
        container.mainContext.autosaveEnabled = false
        Self.todayContainers[streakDays] = made
        let calendar = Calendar.current
        let now = Date()
        for day in 0..<streakDays {
            // Subtracting an hour crossed into the preceding date during midnight runs and
            // skipped yesterday. Calendar noon stays within each historical day across DST;
            // today's entry uses now so the fixture never inserts a future drink.
            let when: Date
            if day == 0 {
                when = now
            } else {
                let priorDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -day, to: now))
                when = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: priorDay))
            }
            container.mainContext.insert(WaterEntry(amountML: 6_000, timestamp: when))
        }
        try container.mainContext.save()
        return container
    }

    private func today(_ store: DuoStore, streakDays: Int = 0) throws -> GHost {
        try host(HomeView(duoStore: store).environmentObject(AppSettings.shared).modelContainer(try todayContainer(streakDays: streakDays)),
                 width: 402, height: 2400)
    }

    /// Today's own scroll view (the tallest one that scrolls up and down).
    private func todayScroll(_ host: GHost) -> UIScrollView? {
        gScrollViews(host.window).filter { $0.contentSize.width <= $0.bounds.width + 1 }.max { $0.contentSize.height < $1.contentSize.height }
    }

    func testTodayKeepsTheDuoScreenPushedWhenTheFirstDuoArrives() async throws {
        let store = ownedPreviewStore(duos: [])
        let page = try today(store, streakDays: 5)
        await gSettle(2.5)
        XCTAssertNil(todayScroll(page)?.refreshControl, "nothing to refresh for someone with no duo")
        let invite = try XCTUnwrap(page.element("duo.invitecard.invite"), "five solo days: the suggestion shows")
        XCTAssertTrue(invite.accessibilityActivate())
        let pushed = await gWait { gNavControllers(page.host).map(\.viewControllers.count) == [2] }
        XCTAssertTrue(pushed, "Invite someone pushes the Duo screen")
        // The create's answer: the first duo. Pull to refresh switches on.
        store.upsert(DuoStore.previewDuo(partner: "", joined: false, now: now, invite: true))
        await gSettle(2)
        XCTAssertEqual(gNavControllers(page.host).map(\.viewControllers.count), [2],
                       "the Duo screen is still there: the switch used to rebuild Today and pop it, with its sheet")
        XCTAssertTrue(store.cache.inviteMomentDismissed, "and the suggestion is not offered again")
    }

    func testTodayHoldsTheSuggestionBackWhileSomethingElseAsksFirst() async throws {
        let store = ownedPreviewStore(duos: [])
        store.availability = .banned
        XCTAssertTrue(store.shouldSuggestDuo(soloStreak: 5), "the suggestion would otherwise show")
        let page = try today(store, streakDays: 5)
        await gSettle(2.5)
        XCTAssertNotNil(page.elements.first { ($0.accessibilityLabel ?? "").hasPrefix("Duo Streaks are not available") },
                        "the banned line is on Today")
        XCTAssertNil(page.element("duo.invitecard"), "and no suggestion to start what cannot be started")
    }

    func testASheetFromTodayDoesNotGetDuosPullToRefresh() async throws {
        let store = ownedPreviewStore(duos: [DuoStore.previewDuo(partner: "Sam", joined: true, now: now, metDays: 3)])
        let page = try today(store)
        await gSettle(2.5)
        XCTAssertNotNil(todayScroll(page)?.refreshControl, "someone with a duo can pull Today to refresh it")
        let custom = try XCTUnwrap(page.elements.first {
            $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "").contains("Custom")
        }, "the Custom quick add opens the add sheet")
        XCTAssertTrue(custom.accessibilityActivate())
        let shown = await gWait { page.presented != nil }
        XCTAssertTrue(shown)
        await gSettle(0.8)
        let sheetScrolls = gScrollViews(try XCTUnwrap(page.presented).view)
        XCTAssertFalse(sheetScrolls.isEmpty)
        XCTAssertTrue(sheetScrolls.allSatisfy { $0.refreshControl == nil },
                      "the add sheet is not a Duo screen: it used to inherit Today's pull to refresh")
    }

    func testTodaysDuoRowsAreWired() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.upsert(DuoFixtures.duo())
        kit.store.availability = .disconnected
        let page = try today(kit.store)
        await gSettle(2.5)
        XCTAssertNotNil(page.element("duo.card"), "the cards are on Today")
        XCTAssertNotNil(todayScroll(page)?.refreshControl, "a duo can be pulled to refresh")
        // The foreground hands the log over and refreshes; it never asks the identity itself.
        let refreshed = await gWait { kit.sync.calls.contains("refresh") }
        XCTAssertTrue(refreshed, "Today refreshes on appearing: \(kit.sync.calls)")
        XCTAssertTrue(kit.sync.calls.contains("logChanged"))
        XCTAssertEqual(kit.identity.prepared, 0, "refresh(), never duoScreenOpened(): a foreground must not ask the identity")
        // "I had a duo" on Today presents the reconnect sheet.
        let had = try XCTUnwrap(page.element("duo.notice.disconnected.reconnect"))
        XCTAssertNil(page.presented)
        XCTAssertTrue(had.accessibilityActivate())
        let shown = await gWait { page.presented != nil }
        XCTAssertTrue(shown, "the reconnect sheet comes up")
    }

    func testTodayShowsNoDuoRowsAndNoPullToRefreshForSomeoneWithoutADuo() async throws {
        let store = ownedPreviewStore(duos: [])
        let page = try today(store)
        await gSettle(2.5)
        XCTAssertNil(page.element("duo.card"))
        XCTAssertNil(page.element("duo.invitecard"), "no solo streak, no suggestion")
        XCTAssertNil(todayScroll(page)?.refreshControl)
    }

    func testNoTodayOrCardCodeCallsDuoScreenOpened() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HydroDrop/Views")
        for file in ["HomeView.swift", "DuoCard.swift"] {
            let text = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            XCTAssertFalse(code.contains { $0.contains("duoScreenOpened") },
                           "\(file): only the Duo screen may ask the identity without a cached duo")
            XCTAssertTrue(text.contains("refresh()"), "\(file) is the file it should be")
        }
    }

    // MARK: - Names

    func testHostileNamesDrawAndArriveUnchanged() throws {
        let names = ["\u{202E}kcabrevO", String(repeating: "Bartholomew", count: 30), "💧🔥👩🏽‍🚀",
                     "**Sam** _it_ [link](https://x.example)", "%@ %d %n {0}", "\u{0633}\u{0627}\u{0631}\u{0629}"]
        for name in names {
            let store = scenario("empty")
            var duo = DuoStore.previewDuo(partner: name, joined: true, now: now, metDays: 2, endedBy: nil)
            store.replaceAll(with: [duo])
            XCTAssertEqual(cardModel(duo, store).partner.name, name)
            render(DuoCard(duoStore: store, duo: duo))
            duo.endedAt = now
            duo.endedBy = .partner
            store.replaceAll(with: [duo])
            XCTAssertEqual(cardModel(duo, store).endedLine, "\u{2068}\(name)\u{2069} left this duo.")
            render(DuoCard(duoStore: store, duo: duo))
            store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: name, myName: name))
            XCTAssertEqual(DuoNoticeCards.cards(for: store).first?.text,
                           "This phone was connected to a duo with \u{2068}\(name)\u{2069}. Continue as \u{2068}\(name)\u{2069}?")
            render(DuoNoticeCards(duoStore: store, onReconnect: {}))
        }
    }
}

// MARK: - The harness: a window, the accessibility tree, pixels

/// Records which duo each exit was for, so a test with two duos can tell them apart.
@MainActor
private final class GRecordingExiting: DuoExiting {
    private(set) var calls: [String] = []
    func leave(_ duo: DuoState) async { calls.append("leave:\(duo.id)") }
    func block(_ duo: DuoState) async { calls.append("block:\(duo.id)") }
    func clear(_ duo: DuoState) { calls.append("clear:\(duo.id)") }
    func deleteMyData() async -> Bool { calls.append("deleteMyData"); return true }
    func startFresh() { calls.append("startFresh") }
}

/// A view hosted in a window of its own, so its accessibility tree and its presentations are real.
@MainActor
private final class GHost {
    let window: UIWindow
    let host: UIViewController

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat, size: DynamicTypeSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(rootView: view)
        controller.traitOverrides.preferredContentSizeCategory = gCategory(size)
        controller.safeAreaRegions = []
        host = controller
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    var elements: [NSObject] { gAllElements(window) }
    func element(_ id: String) -> NSObject? { elements.first { gID($0) == id } }
    func axOrder() -> [NSObject] { gAXOrder(window) }

    /// The view controller presented on top, if any (a sheet, or the confirmation).
    var presented: UIViewController? {
        var top = window.rootViewController?.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    var topAlert: UIAlertController? { presented as? UIAlertController }

    func snapshot() -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

private func gCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
    switch size {
    case .accessibility5: return .accessibilityExtraExtraExtraLarge
    case .accessibility3: return .accessibilityExtraLarge
    default: return .large
    }
}

/// An alert action's handler, run as a tap on it would run it (UIKit offers no public way).
private func gRun(_ action: UIAlertAction) throws {
    typealias Handler = @convention(block) (UIAlertAction) -> Void
    let raw = try XCTUnwrap(action.value(forKey: "handler"))
    unsafeBitCast(raw as AnyObject, to: Handler.self)(action)
}

@MainActor
private func gAXOrder(_ root: NSObject) -> [NSObject] {
    var out: [NSObject] = []
    var seen = Set<ObjectIdentifier>()
    func visit(_ element: NSObject) {
        guard seen.insert(ObjectIdentifier(element)).inserted else { return }
        if element.isAccessibilityElement { out.append(element); return }
        if let children = element.accessibilityElements as? [NSObject] { children.forEach(visit); return }
        let count = element.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count { if let child = element.accessibilityElement(at: index) as? NSObject { visit(child) } }
            return
        }
        if let view = element as? UIView { view.subviews.forEach { visit($0) } }
    }
    visit(root)
    return out
}

@MainActor
private func gAllElements(_ root: NSObject) -> [NSObject] {
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

private func gID(_ element: NSObject) -> String? {
    if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
    let selector = NSSelectorFromString("accessibilityIdentifier")
    guard element.responds(to: selector) else { return nil }
    return element.perform(selector)?.takeUnretainedValue() as? String
}

private func gScrollViews(_ view: UIView) -> [UIScrollView] {
    var out: [UIScrollView] = []
    if let scroll = view as? UIScrollView { out.append(scroll) }
    for sub in view.subviews { out.append(contentsOf: gScrollViews(sub)) }
    return out
}

private func gNavControllers(_ controller: UIViewController) -> [UINavigationController] {
    var out: [UINavigationController] = []
    if let nav = controller as? UINavigationController { out.append(nav) }
    for child in controller.children { out.append(contentsOf: gNavControllers(child)) }
    return out
}

@MainActor
private func gSettle(_ seconds: Double = 0.6) async { try? await Task.sleep(for: .seconds(seconds)) }

@MainActor
private func gWait(_ seconds: Double = 6, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// SwiftUI builds its accessibility tree only while an assistive technology or automation asks
/// for it, so the tests switch automation on for the process and put it back afterwards.
private enum GAutomation {
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

/// A drawing's RGBA bytes, for comparing two drawings and reading a pixel's colour.
private struct GBitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = data
    }

    func rows(_ range: Range<Int>) -> ArraySlice<UInt8> {
        let lower = min(max(range.lowerBound, 0), height)
        let upper = min(max(range.upperBound, lower), height)
        return bytes[(lower * width * 4)..<(upper * width * 4)]
    }

    private func component(_ x: Int, _ y: Int, _ channel: Int) -> Double { Double(bytes[(y * width + x) * 4 + channel]) / 255 }

    func alpha(x: Int, y: Int) -> Double { component(x, y, 3) }

    func brightness(x: Int, y: Int) -> Double {
        let a = max(alpha(x: x, y: y), 0.0001)
        return (component(x, y, 0) + component(x, y, 1) + component(x, y, 2)) / (3 * a)
    }

    /// How many pixels inside `frame` (in points) pass `test` on their unpremultiplied colour.
    func count(in frame: CGRect, scale: CGFloat, _ test: (Double, Double, Double) -> Bool) -> Int {
        let x0 = min(max(Int(frame.minX * scale), 0), width), y0 = min(max(Int(frame.minY * scale), 0), height)
        let xs = x0..<max(min(Int(frame.maxX * scale), width), x0)
        let ys = y0..<max(min(Int(frame.maxY * scale), height), y0)
        var hits = 0
        for y in ys {
            for x in xs {
                let a = max(alpha(x: x, y: y), 0.0001)
                if test(component(x, y, 0) / a, component(x, y, 1) / a, component(x, y, 2) / a) { hits += 1 }
            }
        }
        return hits
    }
}
#endif
