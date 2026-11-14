import Foundation

// How the two sheets that take a code by hand read it, and what they draw (final design §3.4,
// §3.5, §4.1): the code-entry sheet ("Have an invite code?"), where a code arrives typed, pasted
// or scanned, and the reconnect sheet ("I had a duo"), where a code the partner made brings a duo
// back to a new phone. Everything here can be decided without SwiftUI or a camera, so `swift test`
// proves it and the sheets only draw the answer: which lines and controls they show, which are
// enabled, and what Cancel does. The first version decided those in the views, where its own
// tests could not reach them, and its reviewers' mutants of the views (Continue never disabled,
// the Scan button shown with no camera, Cancel closing the sheet mid-scan) all survived.
//
// It reads codes only through the foundation's parsers (`DuoInviteCode.parse(pasted:)`,
// `DuoInviteCode.normalize`, and `DuoLink.parse` beneath them), never a reader of its own: two
// readers of one code can disagree, and with one, a code the vectors (KV1) call good is good
// typed or pasted alike, and a link with the wrong host or path is refused on every path.

public enum DuoCodeEntryModel {
    /// What Continue makes of the field.
    public enum Result: Equatable, Sendable {
        /// A code, with the link's secret if a whole link was pasted.
        case invite(DuoParsedInvite)
        /// Anything else: the sheet says `DuoCopy.notACode` under the field and sends nothing.
        case notACode
    }

    /// The one trim both fields use: surrounding spaces, tabs and line breaks go, as a paste
    /// often brings them. Continue and Reconnect agree on what is "the same code" because they
    /// both start here; the reconnect field used to keep a trailing line break that Continue
    /// dropped, so a pasted code was good in one sheet and refused in the other.
    public static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Continue: a bare code in any form a person types it (any case, with dashes or spaces,
    /// with `O`, `I` and `L` for `0`, `1` and `1`), or a whole pasted link with or without its
    /// secret. A link to any other host or path, a code of the wrong length, and anything else
    /// is not a code.
    public static func submit(_ text: String) -> Result {
        DuoInviteCode.parse(pasted: trimmed(text)).map(Result.invite) ?? .notACode
    }

    /// A QR code the in-app scanner read: only an `https` Duo link, which is all HydroDrop's own
    /// QR codes ever hold (§4.1: "the same URL"). Nil for anything else, which the scanner
    /// ignores without a word. A bare code is not taken from a QR code (D88): the first version
    /// read a scanned payload as a pasted one, so a QR code that said "PASSWORD" became the code
    /// `PASSW0RD`, was kept as a pending invite and was peeked at the server. Typing and pasting
    /// still take a bare code; a person types what they meant to.
    public static func scan(_ payload: String) -> DuoParsedInvite? {
        let text = trimmed(payload)
        guard text.lowercased().hasPrefix("https://"), let url = URL(string: text) else { return nil }
        return DuoLink.parse(url)
    }

    /// Whether the reconnect sheet's code can be sent: once trimmed, it normalises to a code.
    /// Only a code: the reconnect field takes what the partner's sheet shows, and its secret-free
    /// request has no use for a link.
    public static func canReconnect(code: String) -> Bool {
        DuoInviteCode.normalize(trimmed(code)) != nil
    }

    /// An empty field, or one holding only spaces and line breaks: Continue stays disabled
    /// rather than saying "That does not look like a duo code" to someone who typed nothing.
    public static func isBlank(_ text: String) -> Bool {
        trimmed(text).isEmpty
    }

    // MARK: - What the sheet says about the phone

    /// A line a sheet shows above its form when the phone may not do what the sheet is for.
    /// The services refuse such a tap silently (they return nil or false with no `sheetError`),
    /// because the Duo screen already says why; a sheet over it hides that, so it says the same
    /// itself (amendments of 2026-10-08: "the sheets show the availability banner themselves").
    public enum Notice: Equatable, Sendable {
        case none
        /// `DuoAvailability.bannerMessage`, the approved line.
        case line(String)
        /// The restore question ("Continue as <name>?"), which has buttons and so is drawn by the
        /// same view the Duo screen asks it with, never retyped here.
        case restoreQuestion
    }

    /// For the code-entry sheet, whose code leads to a join: what is said while writes are off.
    public static func entryNotice(for availability: DuoAvailability) -> Notice {
        notice(for: availability, allowed: availability.allowsWrites)
    }

    /// For the reconnect sheet: what is said while a reconnect may not be sent. A disconnected
    /// phone is the one this sheet is for, so it says nothing there: "This phone was disconnected"
    /// on the very sheet that reconnects it would only read as a second failure.
    public static func reconnectNotice(for availability: DuoAvailability) -> Notice {
        notice(for: availability, allowed: availability.allowsReconnect)
    }

    private static func notice(for availability: DuoAvailability, allowed: Bool) -> Notice {
        guard !allowed else { return .none }
        if case .needsRestoreChoice = availability { return .restoreQuestion }
        return availability.bannerMessage.map(Notice.line) ?? .none
    }

    // MARK: - The code-entry sheet

    /// Whether the code-entry sheet may take a code at all, by typing or by the camera. Not for
    /// someone the birth-year screen refused (the store keeps nothing for them, so the sheet
    /// shows the refusal instead), and not while writes are off: a disconnected phone, one in the
    /// restore question, one that needs an update and a banned one cannot join, and the join
    /// sheet that a stored code brings up would be refused without a word. The camera is not
    /// even asked for in those states.
    public static func mayTakeACode(ageStatus: DuoAgeStatus, availability: DuoAvailability) -> Bool {
        ageStatus != .refused && availability.allowsWrites
    }

    /// What a tap on Continue does.
    public enum EntryAction: Equatable, Sendable {
        /// Hand the code to `DuoStore.receive(_:)`, which stores it as the pending invite; the
        /// sheet then closes, and the join sheet comes up once it and Settings have gone.
        case receive(DuoParsedInvite)
        /// Say `DuoCopy.notACode` under the field.
        case notACode
        /// Nothing: the field is empty, or the sheet is showing why it cannot take a code.
        case nothing
    }

    public static func entryAction(text: String, ageStatus: DuoAgeStatus, availability: DuoAvailability) -> EntryAction {
        guard mayTakeACode(ageStatus: ageStatus, availability: availability), !isBlank(text) else { return .nothing }
        switch submit(text) {
        case .invite(let invite): return .receive(invite)
        case .notACode: return .notACode
        }
    }

    /// Whether Continue is enabled: there is something in the field and a code may be taken.
    public static func canContinue(text: String, ageStatus: DuoAgeStatus, availability: DuoAvailability) -> Bool {
        !isBlank(text) && mayTakeACode(ageStatus: ageStatus, availability: availability)
    }

    /// The line under the Scan button about the camera, when there is one to say.
    public enum CameraLine: Equatable, Sendable {
        case none
        /// Denied in Settings: "Camera access is off...", with an Open Settings button.
        case off
        /// Restricted by Screen Time or a device profile: its own line, and no Open Settings
        /// button, since the Settings app cannot lift a restriction someone else set.
        case restricted
        /// The camera could not start, or stopped (another app holds it, iPad Split View, a call):
        /// the sheet is back on the field and says so, rather than bouncing back with no word.
        case unavailableNow
    }

    /// What Cancel in the toolbar does.
    public enum CancelAction: Equatable, Sendable {
        /// Close the sheet.
        case closeSheet
        /// Put the camera away and keep the sheet, on the field.
        case backToTyping
    }

    /// Everything the code-entry sheet draws, from the state it is in.
    public struct EntryLayout: Equatable, Sendable {
        /// The birth-year screen's refusal instead of the form.
        public var showsRefusal: Bool
        /// The camera's preview instead of the form.
        public var showsScanner: Bool
        public var notice: Notice
        public var fieldIsEnabled: Bool
        public var continueIsEnabled: Bool
        public var showsNotACode: Bool
        public var showsScanButton: Bool
        public var scanButtonIsEnabled: Bool
        public var cameraLine: CameraLine
        public var showsOpenSettings: Bool
        public var cancel: CancelAction
    }

    /// The code-entry sheet's layout. `wantsScanner` is the person's last choice (they tapped
    /// Scan and the camera was allowed); the scanner shows only while a code may still be taken,
    /// so a phone that is disconnected or refused mid-scan gets the form and its reason.
    public static func entryLayout(text: String, ageStatus: DuoAgeStatus, availability: DuoAvailability, hasCamera: Bool,
                                   wantsScanner: Bool, isAskingForTheCamera: Bool, cameraLine: CameraLine,
                                   showsNotACode: Bool) -> EntryLayout {
        let may = mayTakeACode(ageStatus: ageStatus, availability: availability)
        let refused = ageStatus == .refused
        let scanning = !refused && may && wantsScanner && hasCamera
        let scanButton = !refused && may && hasCamera && !scanning
        let line: CameraLine = scanButton ? cameraLine : .none
        return EntryLayout(showsRefusal: refused, showsScanner: scanning, notice: refused ? .none : entryNotice(for: availability),
                           fieldIsEnabled: may, continueIsEnabled: canContinue(text: text, ageStatus: ageStatus, availability: availability),
                           showsNotACode: showsNotACode && !refused && !scanning, showsScanButton: scanButton,
                           scanButtonIsEnabled: scanButton && !isAskingForTheCamera, cameraLine: line, showsOpenSettings: line == .off,
                           cancel: scanning ? .backToTyping : .closeSheet)
    }

    // MARK: - The reconnect sheet

    /// The code a tap on Reconnect sends, or nil when the tap sends nothing: until the
    /// birth-year screen has said yes (the consent gate asks first, and this holds even if a
    /// frame of the form were ever drawn before it), while availability rules a reconnect out
    /// (an update needed, a ban, the restore question), while something is already being sent,
    /// once a reconnect has landed (the sheet is on its way out, and a second tap would send a
    /// second reconnect), and while the field does not hold a code. The code goes as the person
    /// typed it apart from the surrounding spaces and line breaks: the service normalises it.
    public static func reconnectRequest(code: String, ageStatus: DuoAgeStatus, availability: DuoAvailability,
                                        isWorking: Bool, hasLanded: Bool = false) -> String? {
        guard ageStatus == .allowed, availability.allowsReconnect, !isWorking, !hasLanded, canReconnect(code: code) else { return nil }
        return trimmed(code)
    }

    /// Everything the reconnect sheet draws, from the state it is in.
    public struct ReconnectLayout: Equatable, Sendable {
        public var notice: Notice
        /// The field takes typing (not when a code came with the sheet, and not while sending).
        public var fieldIsEditable: Bool
        public var buttonIsEnabled: Bool
        public var showsProgress: Bool
        /// The service's words for the last refusal, drawn as they are.
        public var error: String?
        /// A swipe may close the sheet; not while a reconnect is out, whose answer would then
        /// arrive for a sheet nobody sees.
        public var mayBeSwipedAway: Bool
    }

    public static func reconnectLayout(code: String, isPrefilled: Bool, ageStatus: DuoAgeStatus, availability: DuoAvailability,
                                       isWorking: Bool, hasLanded: Bool, sheetError: String?) -> ReconnectLayout {
        let request = reconnectRequest(code: code, ageStatus: ageStatus, availability: availability, isWorking: isWorking, hasLanded: hasLanded)
        return ReconnectLayout(notice: reconnectNotice(for: availability), fieldIsEditable: !isPrefilled && !isWorking && !hasLanded,
                               buttonIsEnabled: request != nil, showsProgress: isWorking, error: sheetError,
                               mayBeSwipedAway: !isWorking)
    }
}

/// Whether the in-app scanner may use the camera, read from the system's answer at the moment
/// the person taps Scan and never before (final design §4.1; the privacy review of stage O:
/// the permission is asked for only by that tap). HydroCore imports Foundation alone, so the
/// status arrives as `AVAuthorizationStatus.rawValue`: 0 not determined, 1 restricted, 2 denied,
/// 3 authorized.
public enum DuoCameraAccess: Equatable, Sendable {
    /// Not asked yet: ask, then start the scanner if the answer is yes.
    case ask
    case allowed
    /// Denied in Settings: the sheet says the camera is off, offers the Settings app, and keeps
    /// the field.
    case denied
    /// Restricted by Screen Time or a device profile: said in its own words, with no Settings
    /// button, since the person may not be the one who can lift it.
    case restricted
    /// No camera at all (the simulator, some iPads): the Scan button is not drawn.
    case unavailable

    public static func from(rawStatus: Int, hasCamera: Bool) -> DuoCameraAccess {
        guard hasCamera else { return .unavailable }
        switch rawStatus {
        case 0: return .ask
        case 1: return .restricted
        case 3: return .allowed
        // 2 denied, and any status a later iOS adds: a status this build cannot read is not a
        // yes, so the camera stays off and the field stays.
        default: return .denied
        }
    }

    /// The system's answer to the one request a Scan tap makes.
    public static func afterRequest(granted: Bool) -> DuoCameraAccess {
        granted ? .allowed : .denied
    }

    /// The line a tap on Scan leaves under the button when the camera will not open.
    public var line: DuoCodeEntryModel.CameraLine {
        switch self {
        case .ask, .allowed, .unavailable: return .none
        case .denied: return .off
        case .restricted: return .restricted
        }
    }
}
