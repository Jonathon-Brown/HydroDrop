#if DUO_V2
import MessageUI
import SwiftUI
import UIKit

/// Report a problem (final design §11.8), presented from a duo on the Duo screen: one of three
/// reasons, picked like a radio button, and Send, which opens a mail to support prefilled with
/// the reason, the duo's id and the Support ID (`DuoReportMail`). There is no text field, so the
/// mail the app writes carries nothing else, and no name appears on this sheet or in that mail.
///
/// Nothing is sent from here. Send opens the mail composer, or a `mailto:` link where Mail has no
/// account, as the bug report does; the mail leaves only if the person taps Send there, from
/// their own address, which the line above Send says.
struct DuoReportSheet: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState
    private let route: MMailRoute
    @Environment(\.dismiss) private var dismiss
    @State private var reason: DuoReportMail.Reason?
    /// The mail in the composer, made at the tap. The sheet is presented by this value
    /// (`sheet(item:)`), so the composer is always built from the mail of that tap: a
    /// `sheet(isPresented:)` whose content read a separate `@State` could show the first
    /// presentation's stale value.
    @State private var composing: MMail?
    @State private var showingNoMailAlert = false
    @State private var sent = false

    /// NEW COPY (`DuoReportMail.explanation`): what the mail will hold, said above the Send button.
    static let mExplanation = DuoReportMail.explanation
    static let mSendID = "duo.report.send"
    static func mReasonID(_ reason: DuoReportMail.Reason) -> String { "duo.report.reason.\(reason.rawValue)" }

    /// `reason` starts the sheet with one picked, for a test or a preview; the Duo screen leaves
    /// it out, so Send starts disabled. `route` is how a mail is handed over (the system's, but
    /// for a test, which can drive neither Mail nor `UIApplication.open` in the simulator).
    init(duoStore: DuoStore, duo: DuoState, reason: DuoReportMail.Reason? = nil, route: MMailRoute = .system) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        self.duo = duo
        self.route = route
        _reason = State(initialValue: reason)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DuoReportMail.Reason.allCases) { option in
                        Button {
                            reason = option
                        } label: {
                            HStack(spacing: 12) {
                                Text(verbatim: option.text)
                                    .foregroundStyle(Color.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                // Always laid out, shown only when picked, so a row does not
                                // change height as the choice moves. VoiceOver hears "Selected"
                                // from the trait below instead of the image.
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                                    .opacity(reason == option ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(reason == option ? .isSelected : [])
                        .accessibilityIdentifier(Self.mReasonID(option))
                    }
                } footer: {
                    Text(verbatim: Self.mExplanation)
                }

                Section {
                    Button("Send") { send() }
                        .disabled(Self.mSendDisabled(reason))
                        .accessibilityIdentifier(Self.mSendID)
                }
            }
            .navigationTitle(DuoCopy.reportAProblem)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // The composer is a sheet on this sheet. When a mail was sent this sheet closes too,
            // but only from `onDismiss`, once the composer has gone: dismissing both in the same
            // turn drops one of the two (repo CLAUDE.md). There is no "Thanks" alert: the person
            // has just watched their mail go.
            .sheet(item: $composing, onDismiss: {
                if sent { dismiss() }
            }) { mail in
                route.composer(mail) { result in
                    sent = Self.mClosesAfterComposing(result)
                    composing = nil
                }
            }
            // The bug report's own alert, word for word.
            .alert("No Mail Account Set Up", isPresented: $showingNoMailAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Set up Mail on this device, or email \(DuoReportMail.recipient) directly.")
            }
        }
    }

    /// `BugReportView`'s order: the composer if Mail has an account, else a `mailto:` link, else
    /// the alert. The sheet closes after the link only if a mail app took it (the person is now
    /// in it); if nothing could open it, they get the alert and the sheet stays, so the bug
    /// report's habit of closing regardless would have lost their pick.
    private func send() {
        guard let reason else { return }
        let mail = Self.mMail(reason: reason, duo: duo, store: duoStore)
        if route.canCompose() {
            composing = mail
        } else if let url = mail.mailtoURL {
            route.open(url) { opened in
                if opened { dismiss() } else { showingNoMailAlert = true }
            }
        } else {
            showingNoMailAlert = true
        }
    }

    /// Send waits for a reason: a report without one tells support nothing.
    static func mSendDisabled(_ reason: DuoReportMail.Reason?) -> Bool { reason == nil }

    /// The sheet closes after the composer only when the mail went; a cancel, a draft or a
    /// failure leaves the person where they were.
    static func mClosesAfterComposing(_ result: MFMailComposeResult) -> Bool { result == .sent }

    /// The mail Send opens, from the duo's id and the Support ID `GET /me` last gave (none while
    /// the restore question is up, D76), never from anything with a name in it.
    @MainActor
    static func mMail(reason: DuoReportMail.Reason, duo: DuoState, store: DuoStore) -> MMail {
        let supportID = DuoDiagnosticsExport.shownSupportID(store.memberInfo?.supportID, availability: store.availability)
        let made = DuoReportMail.make(reason: reason, duoID: duo.id, supportID: supportID)
        return MMail(recipient: made.recipient, subject: made.subject, body: made.body)
    }
}

// MARK: - Handing a mail over (shared with `DuoDiagnosticsView`)

/// A mail one of Duo's support screens hands over: to whom, the subject and the body. Its own id,
/// so the composer sheet is presented by the mail itself.
struct MMail: Identifiable {
    let id = UUID()
    let recipient: String
    let subject: String
    let body: String

    var mailtoURL: URL? { DuoReportMail.mailtoURL(recipient: recipient, subject: subject, body: body) }
}

/// How a screen hands a mail over: the system composer when Mail has an account, else a
/// `mailto:` link. A value, so a test can stand in for both: the simulator has no Mail account,
/// and neither the composer nor `UIApplication.open` can be driven there.
struct MMailRoute {
    var canCompose: () -> Bool
    /// Opens the link and says whether something took it.
    var open: (URL, @escaping (Bool) -> Void) -> Void
    var composer: (MMail, @escaping (MFMailComposeResult) -> Void) -> AnyView

    static let system = MMailRoute(
        canCompose: { MFMailComposeViewController.canSendMail() },
        open: { url, done in UIApplication.shared.open(url, options: [:], completionHandler: done) },
        composer: { mail, finish in
            AnyView(MailComposeView(recipient: mail.recipient, subject: mail.subject, body: mail.body, onFinish: finish))
        })
}
#endif
