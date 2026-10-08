#if DUO_V2
import SwiftUI

// STUB (foundation). Stage I replaces this whole file: the Duo Streaks rules, shown again when
// the server answers `428 terms_required`, with one way to accept and one way out.

struct DuoTermsSheet: View {
    var onAccept: () -> Void
    var onCancel: () -> Void

    var body: some View { EmptyView() }
}
#endif
