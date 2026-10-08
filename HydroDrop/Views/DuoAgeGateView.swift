#if DUO_V2
import SwiftUI

// STUB (foundation). Stage I replaces this whole file: the neutral birth-year screen, shown
// before the first Create, Join or Reconnect sheet, and the gate that wraps those sheets.
// The answer is kept as a bare status on this phone and never sent anywhere.

struct DuoAgeGateView: View {
    @ObservedObject var duoStore: DuoStore
    var onAllowed: () -> Void
    var onRefused: () -> Void

    var body: some View { EmptyView() }
}

/// Wraps the body of the three consent sheets (setup, join, reconnect), so the age screen and
/// the terms are handled in one place and not three: it shows `content` once the person is
/// old enough, the birth-year screen first when that is not known yet, and nothing but a way
/// out after a refusal. While the server wants the terms again (`duoStore.needsTerms`) it
/// presents the terms sheet, and calls `onTermsAccepted` once they are accepted so the sheet
/// can send the request that was refused.
struct DuoConsentGate<Content: View>: View {
    @ObservedObject var duoStore: DuoStore
    /// The person was refused or backed out of the terms: the sheet dismisses itself.
    var onClose: () -> Void
    var onTermsAccepted: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}
#endif
