#if DUO_V2
import SwiftUI

// STUB (foundation). Stage I replaces this whole file: what is shared, the two honesty lines
// and the processors, shown by the setup, join and reconnect sheets before the consent tap.

struct DuoExplainer: View {
    enum Context {
        case setup
        case join
        case reconnect
    }

    let context: Context

    var body: some View { EmptyView() }
}
#endif
