import Foundation

/// What the join sheet shows for an invite that was opened, and when the root may show it (final
/// design §4.2, §4.3 steps 4 to 9, §3.4, §3.5, §7.13). The sheet only draws these answers, so `swift
/// test` can hold every one of them without SwiftUI.
///
/// Names are passed through exactly as the server sent them. Cleaning a name is the server's job
/// (`cleanName`, §8.8), and a second, different cleaning here would draw a partner under one name on
/// this sheet and another on the card; the view draws them with `Text(verbatim:)`, so a name that
/// looks like markdown or a format string is shown as the characters it is.
public enum DuoJoinPlan {
    /// What a peek's answer asks the sheet to be.
    public enum Plan: Equatable, Sendable {
        /// A new duo with the inviter: the form, whose Join button is the consent. `isSample` is the
        /// App Review partner (§7.13): the server sends it with no name and no droplet, since a demo
        /// code has no creator to read them from, and the sheet marks the partner as the sample.
        case invite(inviterName: String?, inviterSkin: String?, expiresAt: Date?, isSample: Bool)
        /// A code someone made for this person's new phone (§3.5): not a new duo but their own back,
        /// which the reconnect sheet does with its own consent.
        case reconnect(targetName: String?)
        /// A `link_device` code ("Link this device" is phase 4) or a purpose this build does not
        /// know: one plain line, and nothing is sent.
        case unsupported
    }

    public static func make(peek: DuoPeek) -> Plan {
        switch peek.purpose {
        case .invite:
            return .invite(inviterName: peek.inviterName, inviterSkin: peek.inviterSkin, expiresAt: peek.expiresAt, isSample: false)
        case .demo:
            return .invite(inviterName: peek.inviterName, inviterSkin: peek.inviterSkin, expiresAt: peek.expiresAt, isSample: true)
        case .reconnect:
            return .reconnect(targetName: peek.targetName)
        case .linkDevice, .unknown:
            return .unsupported
        }
    }

    // MARK: - Words

    /// Who the banner says invited you when the server sent no name. The frozen contract and §8.8 say
    /// a null `inviter_display_name` is shown as "Your partner", the same words `DuoState.displayName`
    /// uses for a partner with no name (D82: approved, where "Someone" was not).
    public static let unnamedInviter = "Your partner"

    /// What the restore question calls the person when the server gave no name: stage G's placeholder
    /// for the same card, so the two say the same thing. // NEW COPY (stage G's)
    public static let unnamedSelf = "you"

    /// A `link_device` or unknown code. // NEW COPY
    public static let unsupportedLine = "This code can't be used in this version of HydroDrop."

    /// The button a failure that may pass offers beside Close. // NEW COPY
    public static let tryAgain = "Try again"

    /// A name from the server inside one of our sentences, isolated so a right-to-left name cannot
    /// reorder the English around it ("مريم invited you..." came out with the words scrambled):
    /// U+2068 FIRST STRONG ISOLATE before it and U+2069 POP DIRECTIONAL ISOLATE after. The characters
    /// draw nothing. The foundation is to grow one helper for every `DuoCopy` sentence (D82); until
    /// then this sheet wraps its own.
    public static func isolated(_ name: String) -> String { "\u{2068}\(name)\u{2069}" }

    /// "Alex invited you to keep a streak together." (§4.3), with the name exactly as the server
    /// sent it, isolated. An absent name and an empty one both read as "Your partner": an empty one
    /// would otherwise start the sentence with a space.
    public static func banner(inviterName: String?) -> String {
        guard let name = inviterName, !name.isEmpty else { return DuoCopy.inviteBanner(inviter: unnamedInviter) }
        return DuoCopy.inviteBanner(inviter: isolated(name))
    }

    /// "This phone was connected to a duo with <partner>. Continue as <name>?" (§3.4), the question a
    /// restored phone must answer before anything is sent, with the fallbacks stage G's card uses.
    public static func restoreQuestion(_ prompt: DuoRestorePrompt) -> String {
        let partner = prompt.partnerName.flatMap { $0.isEmpty ? nil : isolated($0) } ?? unnamedInviter
        let me = prompt.myName.flatMap { $0.isEmpty ? nil : isolated($0) } ?? unnamedSelf
        return DuoCopy.restorePrompt(partner: partner, name: me)
    }

    /// The restore question the availability holds, if it holds one.
    public static func restorePrompt(in availability: DuoAvailability) -> DuoRestorePrompt? {
        if case .needsRestoreChoice(let prompt) = availability { return prompt }
        return nil
    }

    /// What the sheet says when the peek brought no answer. The service writes the §4.4 words into
    /// `sheetError` for everything the server said (an expired or used code, the blocked person's
    /// 404, a rate limit, no connection). It says nothing when it refused to ask at all: a phone
    /// another phone took over (its bearer only earns `device_revoked`), a phone whose restore
    /// question is still open, or a store with no services (the Debug preview). The first gets the
    /// line the Duo screen's banner shows for it, the restore question is asked in place (and
    /// answered there, after which the sheet asks again), and anything else gets the general line,
    /// so the sheet is never blank.
    public static func failureText(sheetError: String?, availability: DuoAvailability) -> String {
        if let sheetError, !sheetError.isEmpty { return sheetError }
        if let prompt = restorePrompt(in: availability) { return restoreQuestion(prompt) }
        if let banner = availability.bannerMessage { return banner }
        return DuoUserMessage.generic
    }

    /// Whether a failure may pass on its own, so "Try again" is offered beside Close rather than
    /// leaving Close, which throws the invite away, as the only way on: no connection, a rate limit,
    /// the service paused, an attestation that did not go through, and the general line (with or
    /// without its reference). A code that is gone, taken, the person's own, blocked or for something
    /// else answers the same every time, so it offers nothing more.
    public static func failureMayPass(_ text: String) -> Bool {
        let context = DuoErrorContext(httpStatus: 0)
        let passing = [
            DuoUserMessage.text(for: DuoTransportError.offline, context: .invite),
            DuoUserMessage.text(for: DuoTransportError.rateLimited(context), context: .invite),
            DuoUserMessage.text(for: DuoTransportError.maintenance(context), context: .invite),
            DuoUserMessage.text(for: DuoTransportError.attestRequired(context), context: .invite),
        ]
        return passing.contains(text) || text.hasPrefix(DuoUserMessage.generic)
    }

    /// Whether the failure offers "I had a duo". A disconnected phone is the one a reconnect code is
    /// for, yet its peek is refused (the stored bearer would only earn `device_revoked`), so the code
    /// it opened goes straight to the reconnect sheet, without a peek, if the person says so.
    public static func offersReconnect(availability: DuoAvailability) -> Bool {
        availability == .disconnected
    }

    // MARK: - The form

    /// The peek is the one request the sheet makes before a tap, and it is made only for someone
    /// the birth-year screen has let through (§12.6): never while the answer is unknown or after a
    /// refusal. The consent gate already keeps the sheet's content off screen until then; this is
    /// the same rule held a second time, where the request is made.
    public static func mayPeek(ageStatus: DuoAgeStatus) -> Bool {
        ageStatus == .allowed
    }

    /// Join is offered while nothing else is under way and the app may write. The service refuses a
    /// join from a phone that may not write without a word, so the button is off rather than live.
    /// (Stage I's `canConfirm` is the same rule for the setup sheet; the two are unified at
    /// integration.)
    public static func joinIsEnabled(isWorking: Bool, availability: DuoAvailability) -> Bool {
        !isWorking && availability.allowsWrites
    }

    /// Why Join is off, so a dimmed button is never all the person sees: the line the Duo screen's
    /// banner uses, or the restore question itself, which has no banner of its own; `nil` while
    /// writes are allowed. (Stage I's `writesBlockedMessage` for the setup sheet.)
    public static func joinBlockedLine(availability: DuoAvailability) -> String? {
        guard !availability.allowsWrites else { return nil }
        if let prompt = restorePrompt(in: availability) { return restoreQuestion(prompt) }
        return availability.bannerMessage
    }

    /// The name field stops taking characters at `DuoState.maximumNameLength`, so what the person
    /// sees typed is never longer than what can be sent. The rest of the cleaning (spaces, joiners)
    /// is the service's, through `DuoState.cleanedName`, so the field never rewrites what was typed.
    /// (Stage I's `limitedInput`.)
    public static func cappedName(_ typed: String) -> String {
        typed.count > DuoState.maximumNameLength ? String(typed.prefix(DuoState.maximumNameLength)) : typed
    }

    /// What the name field starts from: the name this person last typed, or, when that is empty, the
    /// name the server holds for them. After a reinstall and "Continue" the typed name is gone while
    /// the server still has one, and an untouched empty field would send none and take it away from
    /// every partner they have.
    public static func prefilledName(typed: String, serverName: String?) -> String {
        cappedName(typed.isEmpty ? (serverName ?? "") : typed)
    }

    // MARK: - When the root shows it

    /// Whether the root holds a pending invite back instead of presenting it: while the intro is up
    /// (a sheet cannot sit on the cover), while Settings is on screen (an invite typed or scanned
    /// there, or a link that just asked Settings to close), and while the code-entry sheet is still
    /// on its way out. A sheet requested underneath another, or while one is dismissing, is dropped
    /// rather than queued (repo CLAUDE.md), so each of these is waited out, and the invite keeps.
    public static func shouldHold(onboardingDone: Bool, settingsIsOnScreen: Bool, entrySheetIsOnScreen: Bool) -> Bool {
        !onboardingDone || settingsIsOnScreen || entrySheetIsOnScreen
    }

    /// The invite the root's join sheet is bound to. `onScreen` is the one the sheet is showing, if
    /// it is up. A sheet that is up stays up for its own invite whatever else changes, since taking
    /// it down is what drops the invite. It also stays up after a refusal given on its own age
    /// screen: the refusal drops the pending invite, because nothing is kept for someone who was
    /// refused, but the sheet has to stay until the person has read the refusal and closed it.
    ///
    /// For someone already refused, the pending invite is always nil (`receive` keeps nothing), so a
    /// link they open is shown from `refusedLink`, which the root holds in memory only: the sheet's
    /// consent gate draws nothing but the refusal and Close, and no peek is made. Before anything
    /// comes up it waits for the intro, Settings, the code-entry sheet, the recap and the notice
    /// alert, as an invite does (D82: an alert and a sheet never share a turn).
    public static func invite(toShow pending: DuoPendingInvite?, refusedLink: DuoPendingInvite? = nil, onScreen: DuoPendingInvite?,
                              ageRefused: Bool, onboardingDone: Bool, settingsIsOnScreen: Bool, entrySheetIsOnScreen: Bool,
                              anotherSheetIsOnScreen: Bool, noticeIsUp: Bool = false) -> DuoPendingInvite? {
        if let onScreen {
            if ageRefused { return onScreen }
            if let pending, pending.id == onScreen.id { return pending }
        }
        guard let candidate = ageRefused ? refusedLink : pending else { return nil }
        if shouldHold(onboardingDone: onboardingDone, settingsIsOnScreen: settingsIsOnScreen, entrySheetIsOnScreen: entrySheetIsOnScreen) {
            return nil
        }
        return anotherSheetIsOnScreen || noticeIsUp ? nil : candidate
    }

    // MARK: - The root's presentations, one at a time

    /// What the root has on screen, or on its way on or off.
    public struct RootSheets: Equatable, Sendable {
        public var onboardingDone: Bool
        /// `showingSettings`: Settings is up or on its way up.
        public var settingsRequested: Bool
        /// From Settings' `onAppear` to its `onDismiss`, so it is still true while it slides away.
        public var settingsIsOnScreen: Bool
        /// The weekly recap a notification asked for, whether or not it has come up yet.
        public var recapRequested: Bool
        /// From the recap's appearance to its `onDismiss`.
        public var recapIsOnScreen: Bool
        /// The join sheet is up, or has an invite it is about to come up for.
        public var joinSheetIsUp: Bool
        /// The code-entry sheet, over Today here (over Settings, Settings is what counts).
        public var entrySheetIsOnScreen: Bool
        /// The root's "Duo Streaks" notice alert: from when it is asked for until it has finished
        /// leaving the screen.
        public var noticeIsUp: Bool

        public init(onboardingDone: Bool, settingsRequested: Bool, settingsIsOnScreen: Bool, recapRequested: Bool,
                    recapIsOnScreen: Bool, joinSheetIsUp: Bool, entrySheetIsOnScreen: Bool, noticeIsUp: Bool) {
            self.onboardingDone = onboardingDone
            self.settingsRequested = settingsRequested
            self.settingsIsOnScreen = settingsIsOnScreen
            self.recapRequested = recapRequested
            self.recapIsOnScreen = recapIsOnScreen
            self.joinSheetIsUp = joinSheetIsUp
            self.entrySheetIsOnScreen = entrySheetIsOnScreen
            self.noticeIsUp = noticeIsUp
        }
    }

    /// The root's next move toward the Duo screen, one at a time. The Duo screen is inside Settings,
    /// so the move that gets there is opening Settings; the Duo row reads the raised flag when it
    /// appears and opens the screen itself (stage H). Each other answer is something to wait out
    /// first, because a sheet asked for while another presentation is up or still leaving is
    /// dropped, and when that happens to the alert and a sheet together the root's presentations
    /// wedge until the app is killed (stage K's review, H1). Two stacked sheets are never dismissed
    /// in the same turn: the recap is closed alone, and Settings is opened only once the recap's
    /// `onDismiss` has run.
    public enum DuoScreenStep: Equatable, Sendable {
        /// The intro is up: nothing yet; asked again when it finishes.
        case waitForIntro
        /// Settings is up or coming up: the raised flag is all it takes.
        case settingsIsUp
        /// Close the weekly recap, then ask again once it has gone.
        case closeRecap
        /// A presentation is up or still leaving (Settings on its way out, the recap, the join sheet,
        /// the code-entry sheet, the notice alert): asked again when it has gone. The join sheet is
        /// waited out rather than closed, since closing it throws the person's invite away.
        case waitForSheet
        case openSettings
    }

    public static func duoScreenStep(_ sheets: RootSheets) -> DuoScreenStep {
        guard sheets.onboardingDone else { return .waitForIntro }
        if sheets.settingsRequested { return .settingsIsUp }
        if sheets.recapRequested { return .closeRecap }
        if sheets.settingsIsOnScreen || sheets.recapIsOnScreen || sheets.joinSheetIsUp || sheets.entrySheetIsOnScreen || sheets.noticeIsUp {
            return .waitForSheet
        }
        return .openSettings
    }

    /// Whether the root's notice alert may be asked for now: only with nothing else of the root's
    /// asked for, up or leaving (D82). An alert asked for in the same turn as a sheet wedged every
    /// root presentation in the review's probes; it waits instead, and the notice keeps.
    public static func noticeMayShow(hasNotice: Bool, _ sheets: RootSheets) -> Bool {
        hasNotice && sheets.onboardingDone && !sheets.settingsRequested && !sheets.settingsIsOnScreen && !sheets.recapRequested
            && !sheets.recapIsOnScreen && !sheets.joinSheetIsUp && !sheets.entrySheetIsOnScreen && !sheets.noticeIsUp
    }

    /// Whether the weekly recap a notification asked for may come up, beyond main's own rule (it waits
    /// for Settings to leave): not over the join sheet, which it would replace and take the typed
    /// name with it, and not while the notice alert is up or leaving.
    public static func recapMayShow(joinSheetIsUp: Bool, noticeIsUp: Bool) -> Bool {
        !joinSheetIsUp && !noticeIsUp
    }

    /// How long a tapped Duo notification keeps waiting for the sheets in its way. A join sheet can be
    /// up a long while; Settings opening long after the tap would come out of nowhere. Going to the
    /// background drops the wait as well.
    public static let duoScreenRouteLifetime: TimeInterval = 10 * 60

    public static func duoScreenRouteIsStale(askedAt: Date?, now: Date) -> Bool {
        guard let askedAt else { return true }
        return now.timeIntervalSince(askedAt) > duoScreenRouteLifetime || now < askedAt
    }
}
