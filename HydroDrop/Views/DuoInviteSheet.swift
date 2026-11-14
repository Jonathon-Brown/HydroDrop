#if DUO_V2
import SwiftUI

/// The invite a person has made, ready to hand over (plan P2 item 6; final design §4.1, §4.3
/// step 3, §12.7): the code, the QR of its link and the share sheet, how long it has left, the
/// warning under it, and "Make a new code".
///
/// It looks the duo up in the store by id every time it draws, so it follows the duo: a new code
/// shows the moment the store has it, and once the partner joins or the duo ends (or a wipe takes
/// it away) there is nothing left to invite to and the sheet closes itself. It redraws once a
/// minute while it is up, for the countdown, and at the moment the code expires, so a dead code
/// leaves the screen when it dies (`DuoCodeTimeline`); no timer of its own runs.
///
/// It sends nothing by being opened or left open. The one request it can make is a new code, and
/// only on a tap: making one voids the code already out (§4.1), so it is never done for the person.
struct DuoInviteSheet: View {
    @ObservedObject var duoStore: DuoStore
    let duoID: UUID
    /// Passed to `DuoCodeDisplay`, which covers the code while the app is not in front.
    var lifecycle: DuoAppLifecycle = .system
    /// Passed to `DuoCodeDisplay` for Copy.
    var pasteboard: UIPasteboard = .general

    @Environment(\.dismiss) private var dismiss
    /// True from a tap on "Make a new code" until the store answers. The store refuses a second
    /// flow while one runs, but it raises `isWorking` only once the request is under way, and a
    /// second tap in between would still have asked.
    @State private var asking = false
    /// The last tap came back with no code. The service says why in `sheetError` when it sent
    /// something; when it refused before sending it says nothing, and the sheet says the general line.
    @State private var tapCameBackEmpty = false
    /// The link for the code on screen, made once per code: it reads the duo's secret from the
    /// Keychain, which a redraw every minute and on every store change has no reason to repeat.
    @State private var links = DuoInviteLinkCache()

    var body: some View {
        NavigationStack {
            TimelineView(DuoCodeTimeline(expiresAt: shownExpiry)) { context in
                content(DuoInviteCountdown.inviteSheet(for: duoStore.duo(duoID), now: context.date), now: context.date)
            }
            .navigationTitle("Invite your partner") // NEW COPY
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("duo.invite.done")
                }
            }
        }
        // A line some other sheet left behind is not this sheet's to show, and this sheet's own is
        // not the next one's: the join and setup sheets show a leftover line on appear. The
        // joining service clears it again when "Make a new code" starts.
        .onAppear { duoStore.sheetError = nil }
        .onDisappear { duoStore.sheetError = nil }
        .onChange(of: DuoInviteCountdown.inviteSheetCloses(for: duoStore.duo(duoID)), initial: true) { _, closes in
            if closes { dismiss() }
        }
    }

    /// When the code on screen expires, for the timeline's extra redraw.
    private var shownExpiry: Date? {
        if case .code(let invite) = DuoInviteCountdown.inviteSheet(for: duoStore.duo(duoID), now: Date()) { return invite.expiresAt }
        return nil
    }

    @ViewBuilder
    private func content(_ state: DuoInviteCountdown.InviteSheet, now: Date) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                switch state {
                case .code(let invite):
                    DuoCodeDisplay(invite: invite, link: links.link(for: duoStore.duo(duoID), in: duoStore), now: now, kind: .invite,
                                   lifecycle: lifecycle, pasteboard: pasteboard)
                    Text(verbatim: DuoCopy.inviteSheetWarning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    newCodeButton(prominent: false)
                case .noOpenCode:
                    Text("This invite is no longer open.") // NEW COPY
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                    newCodeButton(prominent: true)
                case .closed:
                    EmptyView()
                }
                if state != .closed { statusLines }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private var isBusy: Bool { asking || duoStore.isWorking }

    /// The store refuses a new code, without a word, while writes are off: the button is off too,
    /// and the line under it says why when there is a line for it.
    private var mayAsk: Bool { duoStore.availability.allowsWrites }

    @ViewBuilder
    private func newCodeButton(prominent: Bool) -> some View {
        let button = Button {
            makeANewCode()
        } label: {
            Text(verbatim: DuoCopy.makeANewCode)
                .frame(maxWidth: prominent ? .infinity : nil)
        }
        .disabled(isBusy || !mayAsk)
        .accessibilityIdentifier("duo.invite.newcode")
        if prominent {
            button.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            button.buttonStyle(.borderless)
        }
        if isBusy { ProgressView() }
    }

    @ViewBuilder
    private var statusLines: some View {
        if !mayAsk, let banner = duoStore.availability.bannerMessage {
            Text(verbatim: banner)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = DuoInviteCountdown.inviteSheetError(sheetError: duoStore.sheetError, availability: duoStore.availability,
                                                           tapCameBackEmpty: tapCameBackEmpty) {
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func makeANewCode() {
        guard !asking, let duo = duoStore.duo(duoID) else { return }
        asking = true
        tapCameBackEmpty = false
        Task {
            // The joining service stores the new code and its secret on the duo, which this sheet
            // then draws; what went wrong, if anything, is in `sheetError`.
            let made = await duoStore.newInvite(for: duo)
            tapCameBackEmpty = made == nil
            asking = false
        }
    }
}

/// The link for one duo's code, made once per code. `DuoStore.shareURL(for:)` reads the duo's
/// secret from the Keychain; a new code (or a new secret, which only comes with one) is a new key.
@MainActor
final class DuoInviteLinkCache {
    private var made: (duoID: UUID, code: String, link: URL?)?

    func link(for duo: DuoState?, in store: DuoStore) -> URL? {
        guard let duo, let code = duo.invite?.code else {
            made = nil
            return nil
        }
        if let made, made.duoID == duo.id, made.code == code { return made.link }
        let link = store.shareURL(for: duo)
        made = (duo.id, code, link)
        return link
    }
}
#endif
