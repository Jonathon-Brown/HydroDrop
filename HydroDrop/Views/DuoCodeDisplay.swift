#if DUO_V2
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A code ready to be handed to another phone, as both the invite sheet and the reconnect code
/// sheet draw it (final design §4.1, §4.3 step 3, §3.5): the code as a person reads it out or
/// types it, `H7K3-9QWX`; how long it has left; the QR of its link; Copy; and Share.
///
/// The code and the link are secrets for as long as the code is open: whoever has the link of an
/// invite can join, and whoever has a reconnect code can take the partner's place. So this view
/// never logs them and never puts them in an accessibility identifier; Copy puts only the code on
/// the pasteboard, never the link with its `k`, only on this device, and only until the code
/// expires (a reconnect code for ten minutes at most, D79); Share hands the link alone to the
/// system's share sheet with its own Copy, Reading List and the like taken out (D79), since those
/// would put the link back where Copy deliberately does not; and while the app is not in front,
/// or the screen is being recorded or mirrored, the code and the QR are covered, so the picture
/// iOS keeps of the screen for the app switcher, which it writes to disk, holds neither.
struct DuoCodeDisplay: View {
    /// Which code this is, which decides how long a copy of it may stay on the pasteboard.
    enum Kind {
        case invite
        case reconnect

        var pasteboardLifetime: TimeInterval {
            switch self {
            case .invite: return DuoInviteCountdown.invitePasteboardLifetime
            case .reconnect: return DuoInviteCountdown.reconnectPasteboardLifetime
            }
        }
    }

    /// The code to show. Its `expiresAt` is the one the countdown and the copied code keep to.
    let invite: DuoInvite
    /// What the QR and the share sheet carry: the invite link with its secret, or a reconnect
    /// code's link without one. Nil leaves the QR to carry the bare code and offers no share.
    let link: URL?
    /// The time the countdown is measured from, the sheet's timeline tick.
    let now: Date
    var kind: Kind = .invite
    /// Whether the app is in front and whether the screen is captured, and where it says so when
    /// that changes. A test hands in one of its own so it never has to fake the app's state.
    var lifecycle: DuoAppLifecycle = .system
    /// Where Copy writes. The general pasteboard; a test hands in a named one of its own.
    var pasteboard: UIPasteboard = .general

    @Environment(\.displayScale) private var displayScale
    /// True whenever the app is not in front or the screen is captured. It starts from how things
    /// stand when the view is made, not from "uncovered": a code that arrives after the person
    /// switched to Messages must not be drawn into the app switcher's picture.
    @State private var covered: Bool
    /// Bumped on each Copy, for the tick and the haptic.
    @State private var copies = 0
    @State private var showsCopied = false
    /// The QR, drawn once per link and screen scale rather than on every redraw.
    @State private var qrCache = DuoQRCache()
    /// The view the share sheet is presented from.
    @State private var shareAnchor = DuoShareAnchor()

    init(invite: DuoInvite, link: URL?, now: Date, kind: Kind = .invite, lifecycle: DuoAppLifecycle = .system, pasteboard: UIPasteboard = .general) {
        self.invite = invite
        self.link = link
        self.now = now
        self.kind = kind
        self.lifecycle = lifecycle
        self.pasteboard = pasteboard
        _covered = State(initialValue: lifecycle.coversNow())
    }

    /// About how wide the QR is drawn, in points: big enough for a camera across a table, small
    /// enough to leave the code and the buttons on screen on the smallest phone.
    static let qrPoints: CGFloat = 240

    var body: some View {
        VStack(spacing: 16) {
            codeLine
            Text(verbatim: DuoInviteCountdown.label(expiresAt: invite.expiresAt, now: now))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            qrCode
            buttons
        }
        .frame(maxWidth: .infinity)
        .onAppear { covered = lifecycle.coversNow() }
        .onReceive(lifecycle.center.publisher(for: UIApplication.willResignActiveNotification)) { _ in covered = true }
        .onReceive(lifecycle.center.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in covered = true }
        .onReceive(lifecycle.center.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in covered = lifecycle.coversNow() }
        .onReceive(lifecycle.center.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in covered = lifecycle.coversNow() }
        .task(id: copies) {
            // The Copy button shows a tick for a moment after each copy, then its icon again.
            guard copies > 0 else { return }
            showsCopied = true
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { showsCopied = false }
        }
        .sensoryFeedback(.success, trigger: copies)
    }

    // MARK: - The parts

    /// The code in the form people read and type, large and monospaced, so its two groups of four
    /// line up and no character crowds the next. VoiceOver spells it out character by character
    /// rather than trying to read "H7K3" as a word. One line, shrinking at the largest text sizes
    /// rather than breaking a code in two. Not selectable: Copy is the one way off the screen, so
    /// the pasteboard always gets the local copy that expires.
    private var codeLine: some View {
        Text(verbatim: covered ? Self.coverText : Self.displayCode(for: invite))
            .speechSpellsOutCharacters()
            .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .textSelection(.disabled)
            .redacted(reason: covered ? .placeholder : [])
            .accessibilityIdentifier("duo.invite.code")
    }

    @ViewBuilder
    private var qrCode: some View {
        if let picture = qrCache.picture(for: qrText, displayScale: displayScale) {
            Group {
                if covered {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemFill))
                } else {
                    Image(uiImage: picture.image)
                        .interpolation(.none)
                        .resizable()
                        // A code inverted by Smart Invert is white on black, which some scanners refuse.
                        .accessibilityIgnoresInvertColors()
                }
            }
            .frame(width: picture.side, height: picture.side)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("QR code")) // NEW COPY
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("duo.invite.qr")
        }
    }

    /// Copy and Share side by side, or one above the other when the text is too large for both.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { copyButton; shareButton }
            VStack(spacing: 12) { copyButton; shareButton }
        }
        .disabled(covered)
    }

    private var copyButton: some View {
        Button {
            Self.copy(code: Self.displayCode(for: invite),
                      expiresAt: DuoInviteCountdown.pasteboardExpiry(codeExpiresAt: invite.expiresAt, now: Date(), longest: kind.pasteboardLifetime),
                      to: pasteboard)
            copies += 1
        } label: {
            Label("Copy", systemImage: showsCopied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("duo.invite.copy")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let link {
            Button {
                Self.presentShareSheet(for: link, from: shareAnchor.view)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("duo.invite.share")
            .background(DuoShareAnchorView(anchor: shareAnchor).accessibilityHidden(true))
        }
    }

    // MARK: - What is shown, copied and encoded

    /// Drawn instead of the code while it is covered, under a placeholder, so the real code is not
    /// even laid out in the picture the app switcher keeps.
    static let coverText = "0000-0000"

    /// `H7K3-9QWX`, made from the canonical code rather than taken from the server's `display`,
    /// so what is shown and copied is always the code the link carries.
    static func displayCode(for invite: DuoInvite) -> String {
        DuoInviteCode.normalize(invite.code).map(DuoInviteCode.display) ?? invite.display
    }

    /// The link, or the bare canonical code when there is no link.
    private var qrText: String {
        link?.absoluteString ?? DuoInviteCode.normalize(invite.code) ?? invite.code
    }

    // MARK: - The pasteboard

    /// What Copy puts on the pasteboard: the code as shown, as plain text, and nothing else. Never
    /// the link: it carries `k`, and a pasteboard is read by every app the person pastes into.
    static func pasteboardItems(code: String) -> [[String: Any]] {
        [[UTType.utf8PlainText.identifier: code]]
    }

    /// Kept on this device only, so Universal Clipboard never carries the code to the person's
    /// other devices, and gone at `expiresAt` (`DuoInviteCountdown.pasteboardExpiry`).
    static func pasteboardOptions(expiresAt: Date) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: expiresAt]
    }

    static func copy(code: String, expiresAt: Date, to pasteboard: UIPasteboard) {
        pasteboard.setItems(pasteboardItems(code: code), options: pasteboardOptions(expiresAt: expiresAt))
    }

    // MARK: - The share sheet

    /// What the share sheet may not do with the link (D79). Its own Copy would put the link, `k`
    /// and all, on the general pasteboard with no expiry and through Universal Clipboard onto the
    /// person's Mac; Reading List would keep it in Safari and iCloud; print, contacts, photos,
    /// Books and a PDF would each keep a copy that outlives the code. What is left sends the link
    /// to a person: Messages, Mail, AirDrop and other apps.
    static let excludedShareActivities: [UIActivity.ActivityType] = [
        .copyToPasteboard, .addToReadingList, .print, .assignToContact, .saveToCameraRoll, .openInIBooks, .markupAsPDF,
    ]

    /// What is shared: the link alone, with no subject, no message and no preview of ours, so no
    /// words are invented and nothing but the link goes with it.
    static func shareItems(for link: URL) -> [Any] {
        [link]
    }

    static func makeShareSheet(for link: URL) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: shareItems(for: link), applicationActivities: nil)
        sheet.excludedActivityTypes = excludedShareActivities
        return sheet
    }

    /// Presents the share sheet over whatever is on top in the anchor's window: the code sheet is
    /// itself presented, and UIKit presents from the top of that chain or not at all. A second
    /// tap while one is up does nothing.
    static func presentShareSheet(for link: URL, from anchor: UIView?) {
        guard let anchor, let root = anchor.window?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        guard !(top is UIActivityViewController) else { return }
        let sheet = makeShareSheet(for: link)
        // On an iPad the share sheet is a popover and needs something to point at.
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor.bounds
        top.present(sheet, animated: true)
    }
}

// MARK: - The app's state

/// Whether the app is in front and whether its screen is being recorded or mirrored, and where
/// the app says so when either changes. `system` reads the real app; a test builds its own, so the
/// cover can be driven without faking UIKit's state.
struct DuoAppLifecycle {
    var center: NotificationCenter
    var isInFront: @MainActor () -> Bool
    var isCaptured: @MainActor () -> Bool

    static let system = DuoAppLifecycle(
        center: .default,
        isInFront: { UIApplication.shared.applicationState == .active },
        isCaptured: {
            UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.screen.isCaptured == true }
        }
    )

    /// Whether a code drawn now should be covered.
    @MainActor
    func coversNow() -> Bool { !isInFront() || isCaptured() }
}

// MARK: - The QR, drawn once

/// The QR of one text at one screen scale, kept while the display shows that text. A redraw
/// (every tick, every store change) used to run Core Image and draw two bitmaps again.
@MainActor
final class DuoQRCache {
    private var text: String?
    private var scale: CGFloat = 0
    private var made: (image: UIImage, side: CGFloat)?

    /// The picture of `text` and its side in points, drawn one to one on a screen of `displayScale`.
    func picture(for text: String, displayScale: CGFloat) -> (image: UIImage, side: CGFloat)? {
        if text == self.text, displayScale == scale { return made }
        self.text = text
        scale = displayScale
        made = nil
        guard let modules = DuoQRCode.modules(for: text) else { return nil }
        let perModule = DuoQRCode.pixelsPerModule(for: modules, points: DuoCodeDisplay.qrPoints, displayScale: displayScale)
        guard let image = DuoQRCode.image(of: modules, scale: perModule) else { return nil }
        made = (image, CGFloat(modules.sideWithQuietZone * perModule) / max(displayScale, 1))
        return made
    }
}

// MARK: - Where the share sheet comes from

/// The view the Share button sits on, remembered so the share sheet can be presented from its
/// window and, on an iPad, point at it.
@MainActor
final class DuoShareAnchor {
    weak var view: UIView?
}

private struct DuoShareAnchorView: UIViewRepresentable {
    let anchor: DuoShareAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

// MARK: - The timeline

/// When a code sheet redraws: every minute from when it appeared, and at the moment the code
/// expires (`DuoInviteCountdown.nextRedraw`), so a code that runs out leaves the screen when it
/// does rather than at the next minute.
struct DuoCodeTimeline: TimelineSchedule {
    let expiresAt: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        let expiresAt = expiresAt
        return AnySequence(sequence(first: startDate) { DuoInviteCountdown.nextRedraw(after: $0, start: startDate, expiresAt: expiresAt) })
    }
}
#endif
