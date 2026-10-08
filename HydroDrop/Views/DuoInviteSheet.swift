#if DUO_V2
import SwiftUI

// STUB (foundation). Stage J replaces this whole file: the code, the QR, the share link, the
// countdown and "Make a new code". It looks the duo up in the store by id, so it follows the
// duo as it changes.

struct DuoInviteSheet: View {
    @ObservedObject var duoStore: DuoStore
    let duoID: UUID

    var body: some View { EmptyView() }
}
#endif
