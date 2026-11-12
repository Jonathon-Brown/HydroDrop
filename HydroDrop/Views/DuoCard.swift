#if DUO_V2
import SwiftUI

// The duo as it appears on Today and as the first thing of every duo on the Duo screen, the
// buttons that go under it, the one-time suggestion to start one, and the cards that need the
// person before anything else (final design §3.4, §3.5, §4.3, §7.5, §8.5, §11.8, §14's DuoCard
// row; D29, D45, D83).
//
// What each of them says and shows is decided in HydroCore (`DuoCardModel`, `DuoCardActionsModel`,
// `DuoNoticeModel`, `DuoTodayRule`), where `swift test` proves every line; these views only draw
// the answer. Every line that can hold a name, the person's or a partner's, is drawn with
// `Text(verbatim:)`, so nothing in a name is read as markdown or a format (§11.5). None of them
// sends anything by being drawn, and none calls `refresh()`: Today does, on foreground.
//
// Every button is at least 44 points each way, and every button label wraps instead of being cut
// short at the largest text sizes, where the cards also stack what sits side by side.

/// One duo: two droplets side by side, and the streak they are keeping together.
///
/// Each droplet wears its owner's skin and the mood of their progress, which is all a
/// partner ever learns about the day: a face, and whether the goal was met.
struct DuoCard: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState
    /// Off inside a list, where the row is already the card.
    var showsBackground = true

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let model = Self.model(for: duo, in: duoStore, now: Date(), locale: locale)
        // Three columns side by side, as the iCloud card had; at the accessibility text sizes a
        // third of the card is too narrow for a line like "Just getting started" without breaking
        // it into syllables, so the three stack instead.
        let columns = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        VStack(spacing: 10) {
            if model.phase == .ended {
                ended(model)
            } else {
                columns {
                    DuoCardSide(side: model.mine)
                    flame(model)
                    DuoCardSide(side: model.partner, badged: model.showsSampleBadge)
                }
                if let waiting = model.waitingLine { DuoCardCaption(text: waiting) }
                if let notSeen = model.notSeenLine { DuoCardCaption(text: notSeen) }
            }
        }
        .padding(showsBackground ? 16 : 4)
        .frame(maxWidth: .infinity)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground))
            }
        }
        // One element, as the iCloud card was, read as the model's sentences.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: model.spokenSummary))
        .accessibilityIdentifier("duo.card")
    }

    /// What the card says for `duo` at `now`. My own side is the store's reading of the log as it
    /// stands (`status(of:in:)`), not what was last sent, so my droplet never lags my drinks; the
    /// partner's, the streak and the edge of the kept window come from the duo's statuses. Static
    /// so a test can ask for the very moment it built its scenario at.
    ///
    /// So my droplet can say "Goal met" a little before the shared streak counts the day: the
    /// streak is the duo's statuses, which hold my side once the sync engine has written it (at
    /// most about 30 seconds later, or when the phone is back online). Accepted: the droplet
    /// tells the truth about my day, and the number catches up on its own.
    static func model(for duo: DuoState, in store: DuoStore, now: Date, locale: Locale) -> DuoCardModel {
        DuoCardModel.make(
            duo: duo,
            myStatus: store.status(of: duo.myRole, in: duo, now: now),
            partnerStatus: store.status(of: duo.myRole.other, in: duo, now: now),
            streak: store.streak(of: duo, now: now),
            reachedEdge: store.reachedRetentionEdge(of: duo, now: now),
            myToday: DayKey.key(for: now),
            locale: locale
        )
    }

    private func flame(_ model: DuoCardModel) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(model.streakIsLit ? .orange : .secondary)
            Text(verbatim: model.streakText)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let caption = model.streakCaption {
                Text(verbatim: caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Level with the droplets' middles beside them; nothing to line up with when stacked.
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 0 : 18)
        .frame(minWidth: 72)
    }

    private func ended(_ model: DuoCardModel) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "flame")
                .font(.title2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(verbatim: model.endedTitle ?? DuoCardModel.endedTitleText)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.showsSampleBadge { DuoSampleBadge() }
            }
            if let line = model.endedLine { DuoCardCaption(text: line) }
            if let pending = model.pendingLine { DuoCardCaption(text: pending) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One droplet with its name and line under it. Only the droplet is faded for a partner who
/// has not joined: faded words fell to about 1.6:1 against the card in dark mode.
struct DuoCardSide: View {
    let side: DuoCardModel.Side
    var badged = false

    var body: some View {
        VStack(spacing: 2) {
            MascotView(
                progress: DuoProgress.fraction(forBucket: side.progressBucket),
                size: 56,
                skin: MascotSkin(rawValue: side.skin) ?? .classic,
                isAnimated: false
            )
            .opacity(side.isDimmed ? 0.35 : 1)
            HStack(spacing: 4) {
                Text(verbatim: side.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if badged { DuoSampleBadge() }
            }
            // Green text was about 2:1 on the light card, under the 4.5:1 small text needs, so the
            // words stay secondary and the green goes on a checkmark (finding 16).
            HStack(spacing: 3) {
                if side.goalMet {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
                Text(verbatim: side.line)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A secondary line under a card's droplets or title.
struct DuoCardCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The App Review sample partner's badge, beside their name (§7.13).
struct DuoSampleBadge: View {
    var body: some View {
        Text(verbatim: DuoCopy.sampleBadge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .fixedSize()
    }
}

/// What a card offers as buttons, kept apart from the card because on Today the card is itself a
/// link to the Duo screen: "Not them? Leave & block" for the first 24 hours after someone joined,
/// and "Reconnect <name>'s new phone" once the partner has been silent more than three days (final
/// design §3.5, §4.3, §11.8). It presents its own confirmation and its own sheet. It draws nothing,
/// and takes no room, when neither applies, but its confirmation and sheet stay attached either
/// way: they used to hang off the buttons, so the code sheet closed itself the moment the partner's
/// phone wrote (the offer went away under it, and an answer to its request with it), and a failure
/// that turned writes off closed it before its error showed. Place it under every card, not only
/// when something applies, so that what it presented outlives the offer.
struct DuoCardActions: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState

    @State private var confirmingBlock = false
    @State private var showingReconnectCode = false

    var body: some View {
        let actions = Self.actions(for: duo, in: duoStore, now: Date())
        VStack(spacing: 8) {
            if actions.offersNotThem {
                Button(role: .destructive) {
                    confirmingBlock = true
                } label: {
                    Self.label(DuoCopy.notThem)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                // The bordered style draws a destructive role in the app's tint on iOS 26, so the
                // red that says "this ends something" is asked for outright.
                .tint(.red)
                .accessibilityIdentifier("duo.notthem")
            }
            if actions.offersReconnect {
                Button {
                    showingReconnectCode = true
                } label: {
                    Self.label(DuoCardActionsModel.reconnectOffer(for: duo))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("duo.reconnectoffer")
            }
        }
        .confirmationDialog(Text(verbatim: DuoCardActionsModel.blockTitle(for: duo)), isPresented: $confirmingBlock,
                            titleVisibility: .visible) {
            Button("Block", role: .destructive) { confirmBlock() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: DuoCardActionsModel.blockMessage(for: duo))
        }
        .sheet(isPresented: $showingReconnectCode) {
            DuoReconnectCodeSheet(duoStore: duoStore, duo: duo)
        }
    }

    /// Which buttons apply right now (HydroCore decides, with the store's availability and whether
    /// this phone could send a block at all: no "Not them?" for a banned member, or on a phone
    /// with no credential or only a Reconnect's throwaway, which stage E's exit service refuses;
    /// no reconnect offer on a phone that may not write).
    static func actions(for duo: DuoState, in store: DuoStore, now: Date) -> DuoCardActionsModel {
        let canSendExits = store.hasIdentity && !(store.dependencies?.credentialIsAThrowaway ?? false) && store.ageAllowsSharing
        var actions = DuoCardActionsModel.make(duo: duo, availability: store.availability, now: now, myToday: DayKey.key(for: now),
                                               canSendExits: canSendExits)
        // A reconnect code is a request too, which the closed age gate would drop without a word.
        if !store.ageAllowsSharing { actions.offersReconnect = false }
        return actions
    }

    /// A full-width label that wraps rather than being cut short at a large text size.
    private static func label(_ text: String) -> some View {
        Text(verbatim: text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    /// The confirmation's Block. The exit service reads the duo as the store holds it when it
    /// runs, so the copy this view was drawn from being a moment old does not matter.
    @discardableResult
    func confirmBlock() -> Task<Void, Never> {
        let store = duoStore
        let duo = duo
        return Task { await store.block(duo) }
    }
}

/// The duo cards on Today. One card sits as it is. More than one page sideways, a card to a
/// page, live duos first, with dots underneath to say so. Each card is a link to the Duo screen,
/// with its buttons under it and outside the link, so a tap on one of them is never a tap on the
/// card; each page is one container for VoiceOver, so a card's buttons are read after it and not
/// after the last card. The notice cards are not drawn here: Today places them above this section.
struct DuoCardsSection: View {
    @ObservedObject var duoStore: DuoStore
    @State private var page: UUID?
    private let startPage: UUID?

    /// `startPage` opens the pager on that duo's card (the first page when it is nil or gone).
    init(duoStore: DuoStore, startPage: UUID? = nil) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        self.startPage = startPage
    }

    var body: some View {
        let duos = DuoCardModel.pagerOrder(duoStore.duos)
        if duos.count == 1, let duo = duos.first {
            entry(for: duo)
        } else if duos.count > 1 {
            let current = Self.currentIndex(of: duos, page: page)
            VStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(duos) { duo in
                            entry(for: duo)
                                .containerRelativeFrame(.horizontal)
                                .id(duo.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $page)
                // Set once it is on screen: an initial value is not scrolled to, a change is.
                .onAppear { if page == nil, let startPage { page = startPage } }

                DuoPageDots(count: duos.count, current: current)
            }
        }
    }

    /// Which page is showing. A page that was cleared leaves `page` naming a duo that is gone: the
    /// first one is current then, rather than no dot at all.
    static func currentIndex(of duos: [DuoState], page: UUID?) -> Int {
        duos.firstIndex { $0.id == page } ?? 0
    }

    private func entry(for duo: DuoState) -> some View {
        let hasActions = !DuoCardActions.actions(for: duo, in: duoStore, now: Date()).isEmpty
        return VStack(spacing: 0) {
            NavigationLink {
                DuoView()
            } label: {
                DuoCard(duoStore: duoStore, duo: duo)
            }
            .buttonStyle(.plain)
            // Always there, so what it presented outlives the offer; it takes no room when empty.
            DuoCardActions(duoStore: duoStore, duo: duo)
                .padding(.top, hasActions ? 8 : 0)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The dots under a page of cards, and what VoiceOver says for them ("Page 2 of 3").
struct DuoPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(verbatim: DuoCardModel.pageValue(index: current, count: count)))
        .accessibilityIdentifier("duo.pages")
    }
}

/// Shown once, after a few days of a solo streak: the suggestion to keep one with
/// someone else. Closing it, or taking it up, is the last anyone sees of it.
struct DuoInviteCard: View {
    let onInvite: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The icon and the close button take a row of their own above the words, which
                // otherwise broke "Streaks" in two in the column left between them.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        icon
                        Spacer(minLength: 4)
                        dismissButton
                    }
                    words
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    words
                    Spacer(minLength: 4)
                    dismissButton
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        // A container of its own, so its id names the card and the two buttons keep theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo.invitecard")
    }

    private var icon: some View {
        Image(systemName: "person.2.fill")
            .font(.title3)
            .foregroundStyle(.blue)
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Streaks are better with company")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep one streak with one other person. It grows on the days you both meet your goal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onInvite) {
                Text("Invite someone")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("duo.invitecard.invite")
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        // The glyph stays near the corner it always sat in; the larger target reaches into the
        // card's own padding.
        .padding(.top, -12)
        .padding(.trailing, -12)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("duo.invitecard.dismiss")
    }
}

extension DuoTodayRule {
    /// Today's answer for `store`: which of Duo's rows show, and whether Today may talk to the
    /// server (nothing of Duo shows or is sent during an App Store capture run).
    @MainActor
    static func today(_ store: DuoStore, soloStreak: Int, screenshotMode: Bool = AppSettings.isScreenshotMode) -> DuoTodayRule {
        make(hasDuos: !store.duos.isEmpty, hasIdentity: store.hasIdentity, hasNoticeCards: store.hasNoticeCards,
             wantsSuggestion: store.shouldSuggestDuo(soloStreak: soloStreak), ageRefused: store.ageStatus == .refused,
             availability: store.availability, screenshotMode: screenshotMode)
    }
}

/// The cards that need the person before anything else is sent: the question after a
/// reinstall ("Continue as ...?"), the disconnected question, the line about the service
/// being away or the app being out of date, and the notice of a device that was added. The
/// same view heads the Duo screen and sits on Today when it has something to say, and draws
/// nothing when it does not. `onReconnect` is "I had a duo": the caller presents the
/// reconnect sheet.
///
/// The disconnected card is the one way back for a phone another phone took the identity from:
/// the reconnect sheet's button is enabled for exactly that state (`allowsReconnect`), and its
/// service lets go of the revoked credential first. Nothing here sends anything by being drawn;
/// only a tap does, through the store.
struct DuoNoticeCards: View {
    @ObservedObject var duoStore: DuoStore
    var onReconnect: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The Start fresh button whose question is up, with the label its confirm repeats.
    @State private var confirmingStartFresh: String?

    var body: some View {
        let cards = Self.cards(for: duoStore)
        if !cards.isEmpty {
            VStack(spacing: 12) {
                ForEach(cards) { card in
                    switch card.kind {
                    case .restore, .disconnected: question(card)
                    case .service: serviceLine(card)
                    case .newDevice: newDevice(card)
                    }
                }
            }
        }
    }

    /// What there is to say, in the order it is drawn. Empty exactly when `hasNoticeCards` is false.
    static func cards(for store: DuoStore) -> [DuoNoticeCard] {
        DuoNoticeModel.cards(availability: store.availability, newDeviceNotice: store.newDeviceNotice)
    }

    /// The one store call each button makes, and the only place a button's tap goes. Continue
    /// returns its task so a test can wait for it.
    @discardableResult
    func perform(_ action: DuoNoticeAction) -> Task<Void, Never>? {
        switch action {
        case .continueAsRestored:
            let store = duoStore
            return Task {
                await store.continueAsRestored()
                // The card is not a sheet: a failure is said now, in the alert, and not left in
                // `sheetError` for the next join sheet to open already showing it (stage B's leftover).
                if let failure = store.sheetError {
                    store.sheetError = nil
                    store.notice = failure
                }
            }
        case .startFresh:
            duoStore.startFresh()
        case .reconnect:
            onReconnect()
        case .dismissNewDevice:
            withAnimation { duoStore.dismissNewDeviceNotice() }
        }
        return nil
    }

    /// The id the integration pass's UI test finds each button by.
    static func identifier(for action: DuoNoticeAction, in kind: DuoNoticeCard.Kind) -> String? {
        switch (kind, action) {
        case (.restore, .continueAsRestored): return "duo.notice.restore.continue"
        case (.restore, .startFresh): return "duo.notice.restore.fresh"
        case (.disconnected, .reconnect): return "duo.notice.disconnected.reconnect"
        case (.disconnected, .startFresh): return "duo.notice.disconnected.fresh"
        case (.newDevice, .dismissNewDevice): return "duo.notice.newdevice.dismiss"
        default: return nil
        }
    }

    /// The restore and disconnected questions: the sentence, then its two answers side by side,
    /// or one above the other when they do not fit. At the accessibility sizes the icon takes a
    /// row of its own, which used to squeeze the sentence into a column too narrow for its words.
    private func question(_ card: DuoNoticeCard) -> some View {
        let icon = Image(systemName: card.kind == .restore ? "person.2.fill" : "iphone.slash")
            .font(.title3)
            .foregroundStyle(.blue)
            .accessibilityHidden(true)
        let sentence = Text(verbatim: card.text)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                icon
                sentence
            } else {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    sentence
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(card) }
                VStack(alignment: .leading, spacing: 8) { buttons(card) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .contain)
        // H12's title; the message is new copy (`startFreshCardMessage`).
        .confirmationDialog(Text(verbatim: DuoScreenModel.startFreshTitle),
                            isPresented: Binding(get: { confirmingStartFresh != nil }, set: { if !$0 { confirmingStartFresh = nil } }),
                            titleVisibility: .visible) {
            Button(confirmingStartFresh ?? DuoCopy.disconnectedStartFresh, role: .destructive) { perform(.startFresh) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: DuoScreenModel.startFreshCardMessage)
        }
    }

    @ViewBuilder
    private func buttons(_ card: DuoNoticeCard) -> some View {
        ForEach(card.buttons, id: \.title) { button in
            let tap = Button {
                if button.action.asksFirst { confirmingStartFresh = button.title } else { perform(button.action) }
            } label: {
                Text(verbatim: button.title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if button.isPrimary {
                    tap.buttonStyle(.borderedProminent)
                } else {
                    tap.buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .accessibilityIdentifier(Self.identifier(for: button.action, in: card.kind) ?? "")
        }
    }

    /// The service being away, the app out of date, or a banned member: the approved line as a
    /// plain secondary row (it carries the support address itself).
    private func serviceLine(_ card: DuoNoticeCard) -> some View {
        Label {
            Text(verbatim: card.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// D45: a device this phone had not been told about appeared in `GET /me`. One line, and a
    /// close button that remembers the list as seen.
    private func newDevice(_ card: DuoNoticeCard) -> some View {
        let icon = Image(systemName: "iphone")
            .font(.title3)
            .foregroundStyle(.blue)
            .accessibilityHidden(true)
        let line = Text(verbatim: card.text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        icon
                        Spacer(minLength: 4)
                        closeButtons(card)
                    }
                    line
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    line
                    closeButtons(card)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .contain)
    }

    private func closeButtons(_ card: DuoNoticeCard) -> some View {
        ForEach(card.buttons, id: \.title) { button in
            Button { perform(button.action) } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.top, -12)
            .padding(.trailing, -12)
            .accessibilityLabel(Text(verbatim: button.title))
            .accessibilityIdentifier(Self.identifier(for: button.action, in: card.kind) ?? "")
        }
    }
}
#endif
