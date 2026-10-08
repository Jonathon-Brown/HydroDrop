#if DUO_V2
import SwiftUI

// STUB (foundation). Stage G replaces this whole file: the card, the Today section that
// holds one card or a page of them, the one-time suggestion card and the cards that need the
// person before anything else. The signatures are the contract the Duo screen (stage H) and
// Today (stage G's own HomeView edit) use.

/// One duo: two droplets side by side and the streak they keep together.
struct DuoCard: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState
    /// Off inside a list, where the row is already the card.
    var showsBackground = true

    var body: some View { EmptyView() }
}

/// What a card offers as buttons, kept apart from the card because on Today the card is itself a
/// link to the Duo screen: "Not them? Leave & block" for the first 24 hours after someone joined,
/// and "Reconnect <name>'s new phone" once the partner has been silent more than three days (final
/// design §3.5, §4.3, §11.8). It presents its own confirmation and its own sheet, and draws
/// nothing when neither applies. The Duo screen puts it under each card, only when
/// `duo.showsNotThemCard(now:)` or `duo.offersReconnect(myToday:)` holds.
struct DuoCardActions: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState

    var body: some View { EmptyView() }
}

/// The duo cards on Today: one card as it is, or a page each with dots underneath.
struct DuoCardsSection: View {
    @ObservedObject var duoStore: DuoStore

    var body: some View { EmptyView() }
}

/// Shown once, after a few days of a solo streak: the suggestion to keep one with someone else.
struct DuoInviteCard: View {
    let onInvite: () -> Void
    let onDismiss: () -> Void

    var body: some View { EmptyView() }
}

/// The cards that need the person before anything else is sent: the question after a
/// reinstall ("Continue as ...?"), the disconnected question, the line about the service
/// being away or the app being out of date, and the notice of a device that was added. The
/// same view heads the Duo screen and sits on Today when it has something to say, and draws
/// nothing when it does not. `onReconnect` is "I had a duo": the caller presents the
/// reconnect sheet.
struct DuoNoticeCards: View {
    @ObservedObject var duoStore: DuoStore
    var onReconnect: () -> Void

    var body: some View { EmptyView() }
}
#endif
