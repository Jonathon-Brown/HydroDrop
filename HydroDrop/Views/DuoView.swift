#if DUO_V2
import SwiftUI

// STUB (foundation). Stage H replaces this whole file: the Duo Streaks screen, pushed from
// Settings and from a Today card. `init()` and the store it observes are the contract the
// Settings row and the card's link depend on.

struct DuoView: View {
    @ObservedObject private var duoStore = DuoStore.shared

    init() {}

    var body: some View { EmptyView() }
}
#endif
