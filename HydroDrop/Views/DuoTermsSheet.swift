#if DUO_V2
import SwiftUI

/// The Duo Streaks rules, with one way to accept them and one way out (final design §11.8,
/// section-compliance §1.8). Shown by `DuoConsentGate` in place of the form for someone who has
/// not accepted the current rules on this phone, which is before a name can be typed, and again
/// as a sheet over the form when the server answers `428 terms_required`.
///
/// It carries its own `NavigationStack`, because in both places it is the whole of what is on
/// screen. The line above the buttons says what the tap is, since the service records that the
/// person accepted, which version and when (P7a). It decides nothing and sends nothing: the
/// gate says what Accept and Cancel do.
struct DuoTermsSheet: View {
    var onAccept: () -> Void
    var onCancel: () -> Void
    /// A failure to say in place, such as the last Accept's (`DuoStore.sheetError`).
    var message: String?
    /// An Accept is under way: the button shows progress and takes no second tap.
    var isWorking: Bool

    init(onAccept: @escaping () -> Void, onCancel: @escaping () -> Void, message: String? = nil, isWorking: Bool = false) {
        self.onAccept = onAccept
        self.onCancel = onCancel
        self.message = message
        self.isWorking = isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DuoConsentFlow.termsRules, id: \.self) { rule in
                        Text(verbatim: rule)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Its own row: a link sharing a row with text would take every tap on that row.
                    Link(destination: DuoConsentFlow.termsURL) {
                        Text(verbatim: DuoConsentFlow.NewCopy.fullRulesLink)
                    }
                    .accessibilityIdentifier("duo.terms.link")
                }

                if let message {
                    Section {
                        Text(verbatim: message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("duo.terms.message")
                            .duoAnnounced(message)
                    }
                }

                Section {
                    Button(action: onAccept) {
                        if isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(verbatim: DuoConsentFlow.NewCopy.accept)
                                .bold()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    // A centred label would start the line under it mid-row.
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .disabled(isWorking)
                    .accessibilityLabel(Text(verbatim: DuoConsentFlow.NewCopy.accept))
                    .accessibilityValue(Text(verbatim: isWorking ? DuoConsentFlow.NewCopy.inProgress : ""))
                    .accessibilityIdentifier("duo.terms.accept")

                    Button(role: .cancel, action: onCancel) {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("duo.terms.cancel")
                } header: {
                    // What the tap is, read before either button.
                    Text(verbatim: DuoConsentFlow.NewCopy.acceptanceLine)
                        .textCase(nil)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("duo.terms.line")
                }
            }
            .navigationTitle(Text(verbatim: DuoConsentFlow.NewCopy.rulesTitle))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
