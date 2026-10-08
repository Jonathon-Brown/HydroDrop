#if DUO_V2
import SwiftUI

// STUB (foundation). Stage J replaces this whole file: the code a partner types on their new
// phone to reconnect (final design §3.5), made on the Duo screen from "Reconnect <name>'s
// new phone". Unlike an invite it belongs to no stored duo: it asks the store for the code
// when it appears, shows it with the countdown, and forgets it when it goes.

struct DuoReconnectCodeSheet: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState

    var body: some View { EmptyView() }
}
#endif
