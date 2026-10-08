#if DUO_V2
import SwiftUI

// STUB (foundation). Stage I replaces this whole file: the consent sheet whose "Create and
// invite" button is the first request this phone makes (final design §3.1). `onCreated` is
// called with the new duo once it exists, so the caller can bring up the invite sheet.

struct DuoSetupSheet: View {
    @ObservedObject var duoStore: DuoStore
    var onCreated: (DuoState) -> Void

    var body: some View { EmptyView() }
}
#endif
