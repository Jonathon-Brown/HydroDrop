#if DUO_V2
import SwiftUI

/// What a person is told before saying yes to Duo Streaks (final design §3.1, §12.7): what their
/// partner sees, the two honesty lines, who runs the service, the rules and the privacy policy. The
/// setup, join and reconnect sheets each show it above their consent button, because a tap on that
/// button is the first request this phone makes.
///
/// Two `Form` sections, so put it straight into the sheet's `Form`, not inside a `Section`: the
/// first, headed "What your partner sees", lists what is shared, each line with its own symbol (a
/// tick used to sit beside "Never what you drank or exactly how much"); the second, with no
/// header, holds the honesty lines and the processors, which are about the service and not the
/// partner, then the rules link and the privacy policy's, each in a row of its own, so a tap
/// anywhere else on the explainer opens nothing. The words and their order come from
/// `DuoConsentFlow.explainerShared` and `explainerNotes`, which `swift test` holds: every approved
/// line word for word, and the rules link straight after the processors.
struct DuoExplainer: View {
    enum Context {
        case setup
        case join
        case reconnect
    }

    let context: Context

    init(context: Context) {
        self.context = context
    }

    /// The heading above the first section. The same for all three: a reconnect brings back a duo
    /// whose partner sees exactly what they saw before.
    static func heading(for context: Context) -> String {
        switch context {
        case .setup, .join, .reconnect: return DuoConsentFlow.explainerHeading
        }
    }

    var heading: String { Self.heading(for: context) }

    private var flowContext: DuoConsentFlow.ExplainerContext {
        switch context {
        case .setup: return .setup
        case .join: return .join
        case .reconnect: return .reconnect
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(DuoConsentFlow.explainerShared(flowContext).enumerated()), id: \.offset) { _, item in
                    if case .shared(let line, let symbol) = item {
                        Label {
                            Text(verbatim: line)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: symbol)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("duo.explainer")
        } header: {
            Text(verbatim: heading)
        }

        Section {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(DuoConsentFlow.explainerNotes.enumerated()), id: \.offset) { _, item in
                    if case .note(let line) = item {
                        Text(verbatim: line)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("duo.explainer.notes")

            ForEach(Array(DuoConsentFlow.explainerNotes.enumerated()), id: \.offset) { _, item in
                if case .rulesLink(let text, let url) = item {
                    Link(destination: url) {
                        Text(verbatim: text)
                    }
                    .accessibilityIdentifier("duo.explainer.terms")
                }
            }
            // The app's existing link, the one Settings and the paywall show: the footer under the
            // name field and the first honesty line both send the reader to it.
            Link("Privacy Policy", destination: PaywallView.privacyURL)
                .accessibilityIdentifier("duo.explainer.privacy")
        }
    }
}
#endif
