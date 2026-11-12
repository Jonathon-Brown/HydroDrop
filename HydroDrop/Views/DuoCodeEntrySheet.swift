#if DUO_V2
import SwiftUI

// "Have an invite code?" (plan P2 item 6; final design §4.1): a code that arrives by typing,
// pasting or scanning rather than by a tapped link. The sheet reads it with
// `DuoCodeEntryModel` and hands a good one to `DuoStore.receive(_:)`, which only keeps it as the
// pending invite, and then closes itself. It sends nothing at all: the join sheet the root
// brings up once this sheet and Settings have gone does the peek, and its Join button is the
// consent. Closing Settings is the Duo screen's job, from this sheet's `onDismiss`, because two
// stacked sheets are never dismissed in the same turn (CLAUDE.md), so nothing here touches the
// router.
//
// The scanner replaces the form in place, by a state flag, rather than coming up as a second
// sheet on top of this one, and the camera is asked for only when the person taps Scan. What the
// sheet draws in each state is `DuoCodeEntryModel.entryLayout`'s answer, drawn as it is.

/// The state behind the sheet, kept apart from the view so a test can drive every path with a
/// real store over fakes and a fake camera.
@MainActor
final class DuoCodeEntryController: ObservableObject {
    enum Mode: Equatable {
        case typing
        case scanning
    }

    /// What is in the field, as typed or pasted. Editing it takes "not a code" away again.
    @Published var text = "" {
        didSet { if text != oldValue, showsNotACode { showsNotACode = false } }
    }
    /// Continue found no code in the field: `DuoCopy.notACode` is shown under it.
    @Published private(set) var showsNotACode = false
    /// The person's last choice: the scanner (they tapped Scan and the camera was allowed) or the
    /// field. The scanner is drawn only while a code may still be taken (`entryLayout`).
    @Published private(set) var mode: Mode = .typing
    /// What the last Scan tap, or a camera that stopped, left to say under the Scan button.
    @Published private(set) var cameraLine: DuoCodeEntryModel.CameraLine = .none
    /// The system's camera question is up; a second tap must not ask it again.
    @Published private(set) var isAskingForTheCamera = false

    /// A permission answer belongs to the scan tap that asked it, not a later appearance of
    /// this sheet. Backgrounding or closing invalidates it even while the form is still shown.
    private var scanRequestID = UUID()

    let camera: DuoCameraAuthorizing
    /// Whether this phone has a camera, read once when the sheet is made. Reading it asks the
    /// person nothing; without one (the simulator) the Scan button is not drawn.
    let hasCamera: Bool

    // Nonisolated so a view's initialiser, which SwiftUI does not run on the main actor, can make one.
    nonisolated init(camera: DuoCameraAuthorizing = DuoLiveCameraAuthorization()) {
        self.camera = camera
        hasCamera = camera.hasCamera
    }

    /// What the sheet draws now.
    func layout(in store: DuoStore) -> DuoCodeEntryModel.EntryLayout {
        DuoCodeEntryModel.entryLayout(text: text, ageStatus: store.ageStatus, availability: store.availability, hasCamera: hasCamera,
                                      wantsScanner: mode == .scanning, isAskingForTheCamera: isAskingForTheCamera,
                                      cameraLine: cameraLine, showsNotACode: showsNotACode)
    }

    /// Continue (the button, or the keyboard's Continue key: storing a code is not a consent).
    /// True when the sheet should close: the code went to the store.
    func continueTapped(in store: DuoStore) -> Bool {
        switch DuoCodeEntryModel.entryAction(text: text, ageStatus: store.ageStatus, availability: store.availability) {
        case .receive(let invite):
            return hand(invite, to: store)
        case .notACode:
            showsNotACode = true
            return false
        case .nothing:
            return false
        }
    }

    /// A code the scanner read. True when the sheet should close.
    func scanned(_ invite: DuoParsedInvite, in store: DuoStore) -> Bool {
        mode = .typing
        guard DuoCodeEntryModel.mayTakeACode(ageStatus: store.ageStatus, availability: store.availability) else { return false }
        return hand(invite, to: store)
    }

    /// The store keeps the code as the pending invite, with a pasted or scanned link's secret in
    /// memory only. A refusal that only the Keychain remembered is found by `receive` itself
    /// (`refusedNow`), which then keeps nothing and publishes the refusal; the sheet stays and
    /// shows it rather than closing on nothing.
    private func hand(_ invite: DuoParsedInvite, to store: DuoStore) -> Bool {
        store.receive(invite)
        return store.ageStatus != .refused
    }

    /// Scan. The camera permission is asked for here and nowhere else, and only while it has
    /// never been answered; a denied or restricted camera is said in place.
    func scanTapped(in store: DuoStore) async {
        guard hasCamera, mode == .typing, !isAskingForTheCamera,
              DuoCodeEntryModel.mayTakeACode(ageStatus: store.ageStatus, availability: store.availability) else { return }
        let access = DuoCameraAccess.from(rawStatus: camera.rawStatus, hasCamera: hasCamera)
        switch access {
        case .allowed:
            openScanner()
        case .ask:
            let requestID = scanRequestID
            isAskingForTheCamera = true
            let granted = await camera.requestAccess()
            isAskingForTheCamera = false
            // The question can stay up for as long as the person likes, and the phone may stop
            // taking codes meanwhile (a refusal found, an update needed). A yes then must not leave
            // the scanner chosen, or it would come on by itself once the reason went away.
            guard requestID == scanRequestID,
                  DuoCodeEntryModel.mayTakeACode(ageStatus: store.ageStatus, availability: store.availability) else { return }
            let answer = DuoCameraAccess.afterRequest(granted: granted)
            if answer == .allowed { openScanner() } else { cameraLine = answer.line }
        case .denied, .restricted:
            cameraLine = access.line
        case .unavailable:
            break
        }
    }

    private func openScanner() {
        cameraLine = .none
        mode = .scanning
    }

    /// Back to the field: the person cancelled the scanner, or the phone can no longer take a
    /// code. The scanner leaving the screen is what stops the camera.
    func backToTyping() {
        scanRequestID = UUID()
        if mode != .typing { mode = .typing }
    }

    /// The camera stopped on its own (it could not start, the system took it, the app went to the
    /// background): back to the field, saying so when there is something to say.
    func scannerClosed(_ line: DuoCodeEntryModel.CameraLine) {
        backToTyping()
        cameraLine = line
    }
}

struct DuoCodeEntrySheet: View {
    @ObservedObject var duoStore: DuoStore
    @StateObject private var controller: DuoCodeEntryController
    private let makeCapture: @MainActor () -> DuoQRCapturing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Where Open Settings goes: this app's page in the Settings app, where the camera switch is.
    static let settingsURL = URL(string: UIApplication.openSettingsURLString)

    init(duoStore: DuoStore) {
        self.duoStore = duoStore
        _controller = StateObject(wrappedValue: DuoCodeEntryController())
        makeCapture = { DuoLiveQRCapture() }
    }

    /// For tests: a controller over a fake camera, and a fake capture session.
    init(duoStore: DuoStore, controller: @autoclosure @escaping () -> DuoCodeEntryController,
         makeCapture: @escaping @MainActor () -> DuoQRCapturing = { DuoLiveQRCapture() }) {
        self.duoStore = duoStore
        _controller = StateObject(wrappedValue: controller())
        self.makeCapture = makeCapture
    }

    private var mayTakeACode: Bool {
        DuoCodeEntryModel.mayTakeACode(ageStatus: duoStore.ageStatus, availability: duoStore.availability)
    }

    var body: some View {
        let layout = controller.layout(in: duoStore)
        Group {
            if layout.showsRefusal {
                // A person the birth-year screen refused is shown that, by the age gate's own view,
                // rather than a field whose Continue would keep nothing and say nothing (the store
                // keeps no invite for them).
                DuoAgeGateView(duoStore: duoStore, onAllowed: {}, onRefused: { dismiss() })
            } else {
                NavigationStack {
                    content(layout)
                        .navigationTitle("Have an invite code?")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                // While scanning, Cancel puts the camera away and keeps the sheet;
                                // while typing, it closes the sheet.
                                Button("Cancel") { cancel(layout.cancel) }
                                    .accessibilityIdentifier("duo.code.cancel")
                            }
                        }
                }
            }
        }
        // A refusal kept only in the Keychain (a process that started before the first unlock read
        // "unknown") is found before the person types or the camera is asked for.
        .onAppear { duoStore.recheckAge() }
        .onDisappear { controller.backToTyping() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.backToTyping() }
        }
        // A phone that may no longer take a code while it scans goes back to the form for good,
        // so the camera never comes back on by itself if the reason later goes away.
        .onChange(of: mayTakeACode) { _, may in
            if !may { controller.backToTyping() }
        }
    }

    private func cancel(_ action: DuoCodeEntryModel.CancelAction) {
        switch action {
        case .backToTyping: controller.backToTyping()
        case .closeSheet:
            controller.backToTyping()
            dismiss()
        }
    }

    @ViewBuilder private func content(_ layout: DuoCodeEntryModel.EntryLayout) -> some View {
        if layout.showsScanner {
            DuoQRScannerView(
                onInvite: { invite in
                    let taken = controller.scanned(invite, in: duoStore)
                    if taken { dismiss() }
                    return taken
                },
                onClosed: { line in controller.scannerClosed(line) },
                makeCapture: makeCapture
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea(edges: .bottom)
            .accessibilityElement()
            .accessibilityLabel(Text("Scan a QR code")) // NEW COPY (the Scan button's own words)
            .accessibilityIdentifier("duo.code.scanner")
        } else {
            form(layout)
        }
    }

    private func form(_ layout: DuoCodeEntryModel.EntryLayout) -> some View {
        Form {
            DuoEntryNoticeSection(duoStore: duoStore, notice: layout.notice)
            Section {
                // The prompt is the final design's own example code (§4.1), a shape rather than words.
                TextField(text: $controller.text, prompt: Text(verbatim: DuoInviteCode.display("H7K39QWX"))) {
                    Text("Have an invite code?")
                }
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.continue)
                .font(.body.monospaced())
                .onSubmit(submit)
                .disabled(!layout.fieldIsEnabled)
                .accessibilityIdentifier("duo.code.field")
            } footer: {
                if layout.showsNotACode {
                    Text(verbatim: DuoCopy.notACode)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("duo.code.error")
                        .duoAnnounced(DuoCopy.notACode)
                }
            }
            Section {
                Button(action: submit) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .disabled(!layout.continueIsEnabled)
                .accessibilityIdentifier("duo.code.continue")
            }
            if layout.showsScanButton {
                Section {
                    Button {
                        Task { await controller.scanTapped(in: duoStore) }
                    } label: {
                        Label("Scan a QR code", systemImage: "qrcode.viewfinder") // NEW COPY
                    }
                    .disabled(!layout.scanButtonIsEnabled)
                    .accessibilityIdentifier("duo.code.scan")
                    cameraLine(layout)
                }
            }
        }
    }

    @ViewBuilder private func cameraLine(_ layout: DuoCodeEntryModel.EntryLayout) -> some View {
        switch layout.cameraLine {
        case .none:
            EmptyView()
        case .off:
            Text("Camera access is off. Turn it on in Settings, or type the code instead.") // NEW COPY
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("duo.code.cameraOff")
        case .restricted:
            Text("Camera access is restricted on this iPhone. Type the code instead.") // NEW COPY
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("duo.code.cameraRestricted")
        case .unavailableNow:
            Text("The camera can't be used right now. Type the code instead.") // NEW COPY
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("duo.code.cameraUnavailable")
        }
        if layout.showsOpenSettings {
            Button("Open Settings") { openSettings() } // NEW COPY
                .accessibilityIdentifier("duo.code.openSettings")
        }
    }

    private func submit() {
        if controller.continueTapped(in: duoStore) { dismiss() }
    }

    private func openSettings() {
        guard let url = Self.settingsURL else { return }
        openURL(url)
    }
}

/// The line the code-entry and reconnect sheets show above their form while the phone may not
/// do what the sheet is for (`DuoCodeEntryModel.Notice`). The services refuse such a tap without
/// a word, because the Duo screen already says why, and a sheet over that screen hides it. The
/// restore question has buttons, so it is drawn by the view the Duo screen asks it with.
struct DuoEntryNoticeSection: View {
    @ObservedObject var duoStore: DuoStore
    let notice: DuoCodeEntryModel.Notice

    var body: some View {
        switch notice {
        case .none:
            EmptyView()
        case .line(let line):
            Section {
                // The mark tells it apart from the field below, which it otherwise resembles.
                Label {
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("duo.entry.notice")
            }
        case .restoreQuestion:
            Section {
                DuoNoticeCards(duoStore: duoStore, onReconnect: {})
                    .accessibilityIdentifier("duo.entry.restore")
            }
        }
    }
}
#endif
