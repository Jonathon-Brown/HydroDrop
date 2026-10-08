#if DUO_V2
import SwiftUI

// STUB (foundation). Stage L replaces this whole file: "I had a duo". It shows the same
// explainer as the setup sheet, and its "Reconnect" button is the consent.

struct DuoReconnectSheet: View {
    @ObservedObject var duoStore: DuoStore
    /// A code that arrived as a link or a scanned QR code, shown filled in so the person only
    /// confirms. Nil when they will type it.
    var prefilledCode: String? = nil

    var body: some View { EmptyView() }
}
#endif
