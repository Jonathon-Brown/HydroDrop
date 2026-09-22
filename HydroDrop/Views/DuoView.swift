import CloudKit
import SwiftUI

/// Duo streaks: start one, see how each is going, leave one.
struct DuoView: View {
    @ObservedObject private var duoStore = DuoStore.shared
    @ObservedObject private var store = StoreManager.shared

    @State private var showingSetup = false
    /// A share made by the setup sheet, held until that sheet has gone so the invite
    /// can come up in its place rather than on top of it.
    @State private var createdShare: CKShare?
    @State private var sharing: SharingItem?
    @State private var leaving: DuoState?
    @State private var paywallSource: PaywallSource?
    /// The duo a nudge is being picked for.
    @State private var nudging: DuoState?
    @State private var notificationsEnabled = DuoCache.notificationsEnabled()

    private struct SharingItem: Identifiable {
        let id = UUID()
        let share: CKShare
    }

    private var canAdd: Bool { duoStore.canAddDuo(isSubscribed: store.isSubscribed) }

    var body: some View {
        List {
            if let message = duoStore.accountMessage {
                Section {
                    Label(message, systemImage: "icloud.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(duoStore.duos) { duo in
                Section {
                    DuoCard(duoStore: duoStore, duo: duo, showsBackground: false)
                    if !duo.hasEnded, !duo.isPending {
                        nudgeRows(for: duo)
                    }
                    if duo.isPending {
                        Button {
                            Task {
                                if let share = await duoStore.shareForInvite(to: duo) {
                                    sharing = SharingItem(share: share)
                                }
                            }
                        } label: {
                            Label("Send the invite again", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        leaving = duo
                    } label: {
                        Label(duo.hasEnded ? "Clear this duo" : "Leave duo", systemImage: duo.hasEnded ? "xmark.circle" : "rectangle.portrait.and.arrow.right")
                    }
                }
            }

            Section {
                addRow
            } footer: {
                Text(footer)
            }

            if !duoStore.activeDuos.isEmpty {
                Section {
                    Toggle("Duo notifications", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, enabled in
                            DuoCache.setNotificationsEnabled(enabled)
                        }
                } footer: {
                    Text("A nudge from your partner, and the moment they meet their goal. Never outside your reminder hours: anything that arrives then waits until they start.")
                }
            }
        }
        .navigationTitle("Duo Streaks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await duoStore.refresh() }
        .task { await duoStore.refresh() }
        .disabled(duoStore.isWorking)
        .sheet(isPresented: $showingSetup, onDismiss: presentCreatedShare) {
            DuoSetupSheet { share in
                createdShare = share
                showingSetup = false
            }
        }
        .sheet(item: $sharing, onDismiss: { Task { await duoStore.refresh() } }) { item in
            CloudSharingSheet(share: item.share, container: duoStore.container)
                .ignoresSafeArea()
        }
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
        .confirmationDialog(
            "Send a nudge",
            isPresented: Binding(get: { nudging != nil }, set: { if !$0 { nudging = nil } }),
            titleVisibility: .visible,
            presenting: nudging
        ) { duo in
            ForEach(DuoNudgePreset.allCases) { preset in
                Button(preset.text) {
                    Task { await duoStore.sendNudge(preset, in: duo) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { duo in
            Text("\(duo.displayName(of: duo.myRole.other)) gets it as a notification.")
        }
        .confirmationDialog(
            leaving?.hasEnded == true ? "Clear this duo?" : "Leave this duo?",
            isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
            titleVisibility: .visible,
            presenting: leaving
        ) { duo in
            Button(duo.hasEnded ? "Clear" : "Leave duo", role: .destructive) {
                Task { await duoStore.leave(duo) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { duo in
            Text(leaveMessage(for: duo))
        }
    }

    /// The way to send a nudge, or the reason there is none to send, and the last thing
    /// the partner sent.
    @ViewBuilder
    private func nudgeRows(for duo: DuoState) -> some View {
        let partner = duo.displayName(of: duo.myRole.other)
        switch duoStore.nudgeVerdict(for: duo) {
        case .allowed(let remaining):
            Button {
                nudging = duo
            } label: {
                HStack {
                    Label("Send a nudge", systemImage: "hand.wave.fill")
                    Spacer()
                    Text("\(remaining) left today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .limitReached:
            Label("That is all three nudges for today.", systemImage: "hand.wave")
                .foregroundStyle(.secondary)
        case .partnerAlreadyMet:
            Label("\(partner) already met their goal. Nothing to nudge.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .nobodyToNudge:
            EmptyView()
        }

        if let last = duo.allNudges.filter({ $0.fromRole != duo.myRole }).max(by: { $0.createdAt < $1.createdAt }) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(partner): \(DuoNudgePreset.text(forID: last.presetID))")
                    .font(.subheadline)
                Text(last.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var addRow: some View {
        if canAdd {
            Button {
                showingSetup = true
            } label: {
                Label("Start a duo streak", systemImage: "person.2.fill")
            }
            .disabled(duoStore.accountMessage != nil && duoStore.account != .temporarilyUnavailable)
        } else if !store.isSubscribed {
            Button {
                paywallSource = .lockedDuo
            } label: {
                HStack {
                    Label("Start another duo streak", systemImage: "person.2.fill")
                    Spacer()
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Part of HydroDrop Plus")
        } else {
            Label("You are in \(DuoLimit.plusDuoCount) duos, which is as many as there can be.", systemImage: "person.2.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        "One streak, two people. It grows on every day you both meet your own goal. "
            + "Your partner sees your first name, your droplet, whether you met your goal, and roughly how far along you are. "
            + "Never what you drank, how much, or when."
    }

    private func leaveMessage(for duo: DuoState) -> String {
        if duo.hasEnded { return "It is already over. This only takes it off your screen." }
        let partner = duo.displayName(of: duo.myRole.other)
        return duo.myRole == .owner
            ? "This ends the duo for both of you and the shared streak is gone. \(partner) will see that it ended."
            : "You will leave the shared streak. \(partner) will see that the duo ended."
    }

    private func presentCreatedShare() {
        guard let share = createdShare else { return }
        createdShare = nil
        sharing = SharingItem(share: share)
    }
}

/// What both the setup and the join sheet say about what is shared. Said before the
/// name is asked for, because it is the thing worth knowing before saying yes.
private struct DuoSharingExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your first name and your droplet", systemImage: "drop.fill")
            Label("Whether you met your goal each day", systemImage: "checkmark.circle.fill")
            Label("Roughly how far along you are", systemImage: "chart.bar.fill")
            Label("Never what you drank, how much, or when", systemImage: "lock.fill")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// Asks for a first name, makes the duo, and hands back the share to send.
struct DuoSetupSheet: View {
    let onCreated: (CKShare) -> Void

    @ObservedObject private var duoStore = DuoStore.shared
    @ObservedObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = DuoCache.myDisplayName()

    private var cleanedName: String { DuoState.cleanedName(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your first name", text: $name)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                } footer: {
                    Text("This is what your partner will see. It stays between the two of you.")
                }

                Section("What your partner sees") {
                    DuoSharingExplainer()
                }

                if let error = duoStore.sheetError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if let created = await duoStore.createDuo(named: cleanedName, isSubscribed: store.isSubscribed) {
                                onCreated(created.share)
                            }
                        }
                    } label: {
                        if duoStore.isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Create and invite").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(cleanedName.isEmpty || duoStore.isWorking)
                } footer: {
                    Text("Next you pick who to invite. Send it to the number or email they use for iCloud.")
                }
            }
            .navigationTitle("Start a duo streak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onDisappear { duoStore.sheetError = nil }
        }
    }
}

/// Shown when an invite is opened. Nothing is accepted until Join is tapped.
struct DuoJoinSheet: View {
    let invite: DuoStore.PendingInvite

    @ObservedObject private var duoStore = DuoStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = DuoCache.myDisplayName()

    private var cleanedName: String { DuoState.cleanedName(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("You have been invited to keep a streak together. It grows on every day you both meet your own goal.")
                }

                Section {
                    TextField("Your first name", text: $name)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                } footer: {
                    Text("This is what your partner will see.")
                }

                Section("What your partner sees") {
                    DuoSharingExplainer()
                }

                if let error = duoStore.sheetError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await duoStore.join(invite, named: cleanedName) { dismiss() }
                        }
                    } label: {
                        if duoStore.isWorking {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Join").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(cleanedName.isEmpty || duoStore.isWorking)
                }
            }
            .navigationTitle("Join a duo streak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .onDisappear { duoStore.sheetError = nil }
        }
    }
}

/// Apple's own invite sheet, which is what lets the invite go out through Messages.
///
/// Invited people only, and they can write as well as read, because a partner has their
/// own days to record. Nothing about who is invited is read back here: no names, no
/// addresses.
struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Duo streak on HydroDrop"
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            Diagnostics.log("the invite sheet could not save the share: \(error)")
        }
    }
}
