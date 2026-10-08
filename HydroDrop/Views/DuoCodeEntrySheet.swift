#if DUO_V2
import SwiftUI

// STUB (foundation). Stage L replaces this whole file: "Have an invite code?", a typed code
// or a scanned QR code. A good code goes to `duoStore.receive(_:)`, which publishes it as
// `pendingInvite`, and the sheet dismisses itself; the join sheet comes up from the root.

struct DuoCodeEntrySheet: View {
    @ObservedObject var duoStore: DuoStore

    var body: some View { EmptyView() }
}
#endif
