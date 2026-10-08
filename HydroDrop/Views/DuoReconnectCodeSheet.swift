#if DUO_V2
import SwiftUI

/// The code a partner types on their new phone to take their place in the duo back (final design
/// §3.5), opened from "Reconnect <name>'s new phone" on a card whose partner has been silent for
/// more than three days.
///
/// Unlike an invite it belongs to no stored duo. The sheet asks the store for it when it first
/// appears: that is the follow-up of the tap that opened it, which is the person's consent. Asking
/// again voids the code already made (one open reconnect code per duo and partner, §3.5) and
/// spends the day's invite quota, so the code is held in memory once it is given
/// (`DuoReconnectCodeMemory`, D79): closing the sheet and opening it again shows the same code and
/// sends nothing, until the code expires, a wipe, or the duo ends. It is never written to the duo,
/// the cache, the Keychain or anywhere else, so a relaunch forgets it and the next open makes a new
/// one, which the sheet says. A refusal (the partner was seen again, `target_active`; not a
/// partner, `not_partner`; a rate limit; no connection) is the line the joining service left in
/// `sheetError`.
///
/// The warning matters more here than anywhere else in Duo: whoever uses this code before it
/// expires is moved into the partner's place, in this duo and in every other duo the partner is in
/// (one reconnect recovers every duo of the member, §3.5), with their name and their days, and the
/// partner's own phone stops working.
struct DuoReconnectCodeSheet: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState
    /// Passed to `DuoCodeDisplay`, which covers the code while the app is not in front.
    var lifecycle: DuoAppLifecycle = .system
    /// Passed to `DuoCodeDisplay` for Copy.
    var pasteboard: UIPasteboard = .general
    /// Where an answered code is held between one opening of the sheet and the next.
    var memory: DuoReconnectCodeMemory = .shared

    @Environment(\.dismiss) private var dismiss
    /// Set before the one request goes out, so a second run of the task (the sheet disappearing
    /// and appearing again while it stays presented) cannot ask for a second code.
    @State private var asked = false
    @State private var answer: DuoInviteCountdown.ReconnectAnswer = .notYet

    var body: some View {
        NavigationStack {
            TimelineView(DuoCodeTimeline(expiresAt: shownExpiry)) { context in
                content(DuoInviteCountdown.reconnectSheet(for: duoStore.duo(duo.id), answer: answer, sheetError: duoStore.sheetError,
                                                          availability: duoStore.availability, now: context.date),
                        now: context.date)
            }
            .navigationTitle("Reconnect your partner") // NEW COPY
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("duo.invite.done")
                }
            }
        }
        .task { await askOnce() }
        // This sheet's failure line is not the next sheet's to show (the join and setup sheets show
        // a leftover line on appear).
        .onDisappear { duoStore.sheetError = nil }
        .onChange(of: DuoInviteCountdown.reconnectSheetCloses(for: duoStore.duo(duo.id)), initial: true) { _, closes in
            guard closes else { return }
            memory.forget(duo.id)
            dismiss()
        }
    }

    /// When the code on screen expires, for the timeline's extra redraw.
    private var shownExpiry: Date? {
        if case .code(let code) = answer { return code.expiresAt }
        return nil
    }

    @ViewBuilder
    private func content(_ state: DuoInviteCountdown.ReconnectSheet, now: Date) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                switch state {
                case .waiting:
                    ProgressView()
                        .controlSize(.large)
                        .padding(.top, 48)
                case .code(let code):
                    // Above the code, so it is read before the code is handed to anyone.
                    warning
                    DuoCodeDisplay(invite: code, link: DuoLink.url(code: code.code, k: nil), now: now, kind: .reconnect,
                                   lifecycle: lifecycle, pasteboard: pasteboard)
                    // NEW COPY, for Jonathon's approval: opening the card's reconnect again after a
                    // relaunch, or once this code expires, makes a new code, which voids this one.
                    Text("Making a new code stops the last one from working.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                case .noOpenCode:
                    Text("This code is no longer open. Open the card again for a new one.") // NEW COPY
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                case .failed(let line):
                    Text(verbatim: line)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                case .closed:
                    EmptyView()
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private var warning: some View {
        Label {
            // NEW COPY, for Jonathon's approval before anything ships: it is the one line that
            // stands between a reconnect code and a takeover of the partner's place in every duo.
            Text("Send this only to your partner's new phone. Anyone who uses it before it expires takes over your partner's place in all their duos, and their old phone stops working.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
        .font(.callout.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func askOnce() async {
        // Nothing is asked for a duo that has ended or gone: the sheet is closing.
        guard !asked, !DuoInviteCountdown.reconnectSheetCloses(for: duoStore.duo(duo.id)) else { return }
        // A code this phone was already given, still open and still this identity's, is shown
        // again with nothing sent: another request would void it.
        if let held = memory.code(for: duo.id, in: duoStore, now: Date()) {
            asked = true
            answer = .code(held)
            return
        }
        asked = true
        // A line another sheet left behind would otherwise stand in for this answer: the service
        // clears it when its flow starts, but not when it refuses to start one.
        duoStore.sheetError = nil
        let code = await duoStore.createReconnectCode(for: duo)
        if let code { memory.remember(code, for: duo.id, in: duoStore, now: Date()) }
        // A request the sheet's going away cancelled is not an answer: the next appearance asks
        // again, and the journal sends it under the same key, so the server answers with the same
        // code rather than making a second one. A code that came back all the same is kept.
        if code == nil, Task.isCancelled {
            asked = false
            return
        }
        answer = code.map { .code($0) } ?? .noCode
    }
}

/// The reconnect codes this phone was given, in memory only, so the sheet can be closed and opened
/// again without making a new code (D79). Keyed by duo, and each kept only for the store that was
/// given it and while `DuoInviteCountdown.heldReconnectCodeHolds` says so: nothing was wiped since
/// (`wipeEpoch`), the code is still open, the duo still live. Whatever no longer holds is dropped at
/// the next look, and a relaunch forgets everything.
@MainActor
final class DuoReconnectCodeMemory {
    static let shared = DuoReconnectCodeMemory()

    private struct Held {
        weak var store: DuoStore?
        let wipeEpoch: Int
        let code: DuoInvite
    }

    private var held: [UUID: Held] = [:]

    init() {}

    /// Whether anything is held at all, for a test.
    var isEmpty: Bool { held.isEmpty }

    func code(for duoID: UUID, in store: DuoStore, now: Date) -> DuoInvite? {
        dropWhatNoLongerHolds(now: now)
        guard let entry = held[duoID], entry.store === store else { return nil }
        return entry.code
    }

    func remember(_ code: DuoInvite, for duoID: UUID, in store: DuoStore, now: Date) {
        held[duoID] = Held(store: store, wipeEpoch: store.wipeEpoch, code: code)
        dropWhatNoLongerHolds(now: now)
    }

    func forget(_ duoID: UUID) {
        held[duoID] = nil
    }

    private func dropWhatNoLongerHolds(now: Date) {
        held = held.filter { duoID, entry in
            guard let store = entry.store else { return false }
            return DuoInviteCountdown.heldReconnectCodeHolds(entry.code, heldAtWipeEpoch: entry.wipeEpoch, wipeEpoch: store.wipeEpoch,
                                                             duo: store.duo(duoID), now: now)
        }
    }
}
#endif
