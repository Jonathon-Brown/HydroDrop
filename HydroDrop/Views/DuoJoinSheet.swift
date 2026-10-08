#if DUO_V2
import SwiftUI

// STUB (foundation). Stage K replaces this whole file: the sheet an opened invite brings up,
// fed by a peek, whose "Join" button is the consent.

struct DuoJoinSheet: View {
    @ObservedObject var duoStore: DuoStore
    let invite: DuoPendingInvite

    var body: some View { EmptyView() }
}
#endif
