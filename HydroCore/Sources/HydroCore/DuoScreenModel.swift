import Foundation

/// What the Duo screen draws and what each of its rows does, decided without SwiftUI so a table
/// test can pin every state to its words (final design §14's DuoView row; §6.6 nudges; §7.5 and
/// §7.6 leave and block; §7.9 the free limit of one; §9.6 the toggle; §11.8 the block dialog;
/// §12.2 and §12.3 the leave, clear and delete dialogs; D29 the nickname; D34 the hard block; D87
/// the review's decisions). The view (`HydroDrop/Views/DuoView.swift`) asks this and draws the
/// answer, so nothing it shows or offers is decided in a place `swift test` cannot reach.
///
/// Every row that ends something, deletes something or sends something to the partner answers a
/// tap with a `Confirmation`, never with an `Action`: the only way to an action is the
/// confirmation's own `action(preset:)`, which the dialog's confirm button calls, and that action
/// is judged once more against the state at the moment of the tap (`confirm(_:verdict:in:)`).
public enum DuoScreenModel {
    // MARK: - Words
    //
    // Approved wording comes from `DuoCopy` and is used from there. The lines here are the iCloud
    // version's (`git show 0ac1327^:HydroDrop/Views/DuoView.swift`), unchanged, except the ones
    // marked NEW COPY, which stage H's report lists (the D87 and H12 ones approved as written).

    public static let title = "Duo Streaks"
    public static let sendNudge = "Send a nudge"
    public static func nudgesLeft(_ remaining: Int) -> String { "\(remaining) left today" }
    public static let allThreeNudgesSent = "That is all three nudges for today."
    // NEW COPY: the low tier allows one nudge a day (`GET /me`'s `nudges_per_day`), where "all
    // three" would be false. The same sentence is §6.6's answer to `nudge_limit`.
    public static let allNudgesSent = "That is all your nudges for today."
    // NEW COPY (H12): the iCloud line "<Partner> gets it as a notification." is untrue when the
    // partner has Duo notifications off or the server holds the nudge back.
    public static let nudgeDialogMessage = "Your partner will see it."
    public static let sendInviteAgain = "Send the invite again"
    public static let leaveRow = "Leave duo"
    public static let leaveTitle = "Leave this duo?"
    public static let leaveButton = "Leave duo"
    // NEW COPY (H12): the Leave dialog for a duo nobody has joined. The approved text tells a
    // partner who does not exist that the duo ended and that they cannot pair again.
    public static let pendingLeaveMessage = "This cancels the invite. Nobody is told."
    // NEW COPY (D87): replaces the name-matched "Your other duo with <Partner> ends too.", which
    // could name the wrong person (two partners with one first name) or miss a sibling (a
    // nickname). A leave ends every live duo of the pair (§7.5), so this is always true.
    public static let alsoEndsSentence = "If you share another duo with them, it ends too."
    // NEW COPY: the Block dialog's destructive button.
    public static let blockButton = "Block"
    // NEW COPY: the iCloud row said "Clear this duo".
    public static let clearRow = "Clear"
    public static let clearTitle = "Clear this duo?"
    public static let clearButton = "Clear"
    // NEW COPY (H12): Start fresh on a card whose queued exit can never be sent.
    public static let startFreshTitle = "Start fresh?"
    public static let startFreshMessage = "This removes the ended duo cards and anything waiting to be sent from this phone."
    // NEW COPY (finding 6, decision f): Start fresh on the restore and disconnected cards. H12's
    // message speaks of ended cards only, which these cards' duos may not be.
    public static let startFreshCardMessage = "This removes every duo card and anything waiting to be sent from this phone."
    // NEW COPY (finding 8): the recheck row, which used to reuse the age screen's title "Before you
    // start" and so said nothing of what it does.
    public static let recheckAgeRow = "Confirm your birth month and year"
    // NEW COPY (finding 5): the same row when only the rules are missing (a reinstall clears them).
    public static let recheckTermsRow = "Accept the Duo Streaks rules"
    // NEW COPY (finding 8): under that row. Sharing, not Duo Streaks: the partner's nudges still
    // arrive meanwhile.
    public static let recheckFooter = "Sharing with your partner is paused until then."
    public static let startADuoStreak = "Start a duo streak"
    public static let startAnotherDuoStreak = "Start another duo streak"
    public static let partOfPlus = "Part of HydroDrop Plus"
    public static let atTheLimit = "You are in \(DuoLimit.plusDuoCount) duos, which is as many as there can be."
    /// The final design's own words for the row (§7.13's review notes, design A's typed code).
    public static let haveAnInviteCode = "Have an invite code?"
    public static let notificationsToggle = "Duo notifications"
    /// The Reminders page's line for a switch that is on while iOS has notifications off.
    public static let notificationsDisabledInIOS = "Notifications are disabled in iOS Settings."
    // NEW COPY (D68): while the stored credential is a Reconnect's throwaway, Delete my Duo data
    // deletes only that empty member on the server and everything on this phone, not the person's
    // real member, which lives on the phone that took the identity over.
    public static let deleteFromThisPhone = "Delete my Duo data from this phone"
    // NEW COPY (D68): the same dialog's message; its last sentence is the approved dialog's.
    public static let deleteFromThisPhoneMessage = "This deletes the Duo data on this phone. It cannot be undone."
    // NEW COPY: the terms page's own title, as the explainer's link says it (§11.8).
    public static let rulesLink = "Duo Streaks rules"
    public static let rulesURL = URL(string: "https://hydrodrop.us/terms.html")!
    // NEW COPY: what a screen reader says for the spinner while something is under way.
    public static let workingLabel = "Please wait"
    /// The small `(ref ...)` line the screen ends with (§10.8's form, §14's request-id footer).
    public static func requestReference(_ id: String) -> String { "(ref \(id))" }
    // NEW COPY (D87): the approved footer (`DuoCopy.screenFooter`) with the explainer's "When your
    // phone last updated each day" in its list, so the two say the same; it still closes on
    // "Never what you drank or exactly how much." (release/1.8's correction, never "or when").
    public static let footer = "One streak, two people. It grows on every day you both meet your own goal. Your partner sees your first name, your droplet, whether you met your goal, roughly how far along you are, and when your phone last updated each day. Never what you drank or exactly how much."

    // MARK: - Names inside sentences

    /// U+2068 FIRST STRONG ISOLATE and U+2069 POP DIRECTIONAL ISOLATE: a name between them keeps its
    /// own direction and cannot reorder the words round it (an Arabic name, or one carrying U+202E).
    static let isolateStart = "\u{2068}"
    static let isolateEnd = "\u{2069}"
    /// Stands for the partner in a template built from `DuoCopy`, then replaced in place. A
    /// private-use character no approved sentence holds.
    static let partnerToken = "\u{E000}"

    /// The partner as a sentence names them: their name (the nickname, else the server's),
    /// isolated; or, with neither, the "Your partner" fallback, capitalised only where a sentence
    /// begins.
    public struct PartnerName: Equatable, Sendable {
        public let atStart: String
        public let inSentence: String
    }

    public static func partnerName(of duo: DuoState) -> PartnerName {
        let nickname = duo.partnerNickname ?? ""
        guard !nickname.isEmpty || !partnerServerName(of: duo).isEmpty else {
            return PartnerName(atStart: "Your partner", inSentence: "your partner")
        }
        let isolated = isolateStart + duo.displayName(of: duo.myRole.other) + isolateEnd
        return PartnerName(atStart: isolated, inSentence: isolated)
    }

    /// `template` with each `partnerToken` replaced by the partner: the capitalised form at the
    /// start of the text or of a sentence (after ". ", "? ", "! " or a line break), the
    /// sentence form elsewhere. Names are put in after the scan, so nothing in a name is read.
    static func fill(_ template: String, with name: PartnerName) -> String {
        var result = ""
        var rest = Substring(template)
        while let range = rest.range(of: partnerToken) {
            result += rest[..<range.lowerBound]
            let startsASentence = result.isEmpty || [". ", "? ", "! ", "\n"].contains { result.hasSuffix($0) }
            result += startsASentence ? name.atStart : name.inSentence
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    public static func partnerAlreadyMet(_ duo: DuoState) -> String {
        fill("\(partnerToken) already met their goal. Nothing to nudge.", with: partnerName(of: duo))
    }

    public static func lastNudgeLine(_ duo: DuoState, presetID: String) -> String {
        fill("\(partnerToken): \(DuoNudgePreset.text(forID: presetID))", with: partnerName(of: duo))
    }

    // NEW COPY: the iCloud screen had no Block row.
    public static func blockRow(_ duo: DuoState) -> String {
        fill("Block \(partnerToken)", with: partnerName(of: duo))
    }

    // MARK: - What the screen is drawn from

    /// Everything the screen's answers depend on, read from the store by the view.
    public struct Context: Equatable, Sendable {
        public var duos: [DuoState]
        public var availability: DuoAvailability
        /// `GET /me`'s nudge limit: 3, or 1 at the low tier.
        public var nudgesPerDay: Int
        /// This phone holds a credential (the store's `hasIdentity`).
        public var hasIdentity: Bool
        /// The stored credential is the throwaway a cut-short Reconnect left behind (D68).
        public var credentialIsAThrowaway: Bool
        public var isSubscribed: Bool
        /// Duos whose Block was proven done (D87: the confirmed call ended with nothing said and
        /// nothing left queued). Read through the screen's provider; at integration the store keeps
        /// it, and stage G's "Not them?" adds to it too.
        public var blocksSent: Set<UUID>
        public var now: Date
        public var myToday: String
        /// The age gate is closed (a refusal, the recheck, an unreadable answer): nothing can be sent
        /// to the partner or the server but `DELETE /me`, so the rows that would send are not offered
        /// (finding 1). They used to be, and a confirmed Leave or Block did nothing and said nothing.
        public var sharingPaused: Bool

        public init(duos: [DuoState], availability: DuoAvailability, nudgesPerDay: Int = DuoNudgeRules.dailyLimit,
                    hasIdentity: Bool, credentialIsAThrowaway: Bool = false, isSubscribed: Bool,
                    blocksSent: Set<UUID> = [], now: Date, myToday: String, sharingPaused: Bool = false) {
            self.sharingPaused = sharingPaused
            self.duos = duos
            self.availability = availability
            self.nudgesPerDay = nudgesPerDay
            self.hasIdentity = hasIdentity
            self.credentialIsAThrowaway = credentialIsAThrowaway
            self.isSubscribed = isSubscribed
            self.blocksSent = blocksSent
            self.now = now
            self.myToday = myToday
        }

        /// A duo that has not ended, one nobody has joined yet included.
        var hasLiveDuo: Bool { duos.contains { !$0.hasEnded } }

        /// Whether a leave or a block could ever be sent from this phone: a credential, and not the
        /// Reconnect throwaway, which is nobody's member (D83, D87). Without one the exit service
        /// answers "That did not work. Please try again." for ever.
        var exitsCanBeSent: Bool { hasIdentity && !credentialIsAThrowaway && availability != .banned && !sharingPaused }

        var restoreQuestionIsUp: Bool {
            if case .needsRestoreChoice = availability { return true }
            return false
        }
    }

    // MARK: - One duo's rows

    /// The rows under one duo's card, top to bottom. Stage G's `DuoCardActions` sits in the card's
    /// own row whatever these say: G decides what it offers.
    public struct DuoRows: Equatable, Sendable {
        public enum Nudge: Equatable, Sendable {
            /// "Send a nudge" with "N left today". Drawn but not tappable while the app may not
            /// write (`DuoAvailability.allowsWrites` covers nudging), so the banner explains it.
            case send(remaining: Int, enabled: Bool)
            /// Today's are used up.
            case allSent(String)
            /// The partner already met their goal: nothing to nudge them about.
            case partnerMet(String)
        }

        public struct LastNudge: Equatable, Sendable {
            public var line: String
            public var at: Date
        }

        public struct Nickname: Equatable, Sendable {
            /// The server's name for the partner, shown in the empty field.
            public var placeholder: String
            /// The nickname as saved, or empty.
            public var current: String
        }

        public var nudge: Nudge?
        /// The last nudge the partner sent, with when, for a live joined duo only.
        public var lastNudge: LastNudge?
        /// "Send the invite again", for a duo nobody has joined yet.
        public var showsInvite = false
        /// "Show as:", for a partner who joined and has a name from the server.
        public var nickname: Nickname?
        public var showsLeave = false
        /// The Block row's label, or nil when there is no Block row.
        public var block: String?
        public var showsClear = false
        public var showsReport = false
        /// "Start fresh", for the card a queued exit can never leave (see `rows`).
        public var showsStartFresh = false

        public init() {}
    }

    /// What to draw under `duo`'s card. `verdict` is the store's `nudgeVerdict(for:)`, which knows
    /// my partner's status today.
    public static func rows(for duo: DuoState, verdict: DuoNudgeRules.Verdict, in context: Context) -> DuoRows {
        var rows = DuoRows()
        let banned = context.availability == .banned

        if !duo.hasEnded, !duo.isPending, !context.sharingPaused {
            switch verdict {
            case .allowed(let remaining):
                rows.nudge = .send(remaining: remaining, enabled: context.availability.allowsWrites)
            case .limitReached:
                // "All three" only where the limit is three: a low-tier member's is one.
                rows.nudge = .allSent(context.nudgesPerDay == 3 ? allThreeNudgesSent : allNudgesSent)
            case .partnerAlreadyMet:
                rows.nudge = .partnerMet(partnerAlreadyMet(duo))
            case .nobodyToNudge:
                rows.nudge = nil
            }
            // A live duo past its invite has a joined partner, so this is the partner's last line.
            if let last = duo.allNudges.filter({ $0.fromRole != duo.myRole }).max(by: { $0.createdAt < $1.createdAt }) {
                rows.lastNudge = DuoRows.LastNudge(line: lastNudgeLine(duo, presetID: last.presetID), at: last.createdAt)
            }
        }

        // A banned member's codes are voided by the ban (§11.8), so there is no invite to send again.
        rows.showsInvite = duo.isPending && !banned && !context.sharingPaused

        let serverName = partnerServerName(of: duo)
        if duo.partnerHasJoined, !serverName.isEmpty {
            rows.nickname = DuoRows.Nickname(placeholder: serverName, current: duo.partnerNickname ?? "")
        }

        // Leave and Block only where they can be sent (D87): never for a banned member (D33: a
        // leave or a block is answered `403 banned`), and never without a credential or with a
        // Reconnect's throwaway, where the exit service could only say "Please try again".
        rows.showsLeave = !duo.hasEnded && context.exitsCanBeSent
        // Block needs someone to block (not a duo nobody joined, not a partner who deleted their
        // data), a server that still knows the duo (an ended duo is gone after 30 days, §12.1, and
        // the dialog's year-long promise would then be false), and no block already waiting or
        // proven done.
        let blockQueued = duo.pendingOp == .block
        let blockWent = duo.hasEnded && context.blocksSent.contains(duo.id)
        let purged = duo.endedAt.map { context.now.timeIntervalSince($0) >= DuoProtocolConstants.endedDuoLifetime } ?? false
        if duo.partnerHasJoined, context.exitsCanBeSent, !blockQueued, !blockWent, !partnerIsGone(from: duo), !purged {
            rows.block = blockRow(duo)
        }
        // Clear is local and never hidden behind the availability banner.
        rows.showsClear = duo.hasEnded
        rows.showsReport = duo.partnerHasJoined

        // A phone restored from a backup without its Keychain can hold a card whose leave or block
        // is queued with no credential to send it: the queue keeps it (a status-0 refusal is not a
        // judged one) and the card says it is on its way for ever, while Clear keeps the entry too
        // (D67). Once no live duo is left there is nothing Start fresh could lose that the person
        // can still use, so it is offered on that card, behind its own dialog.
        rows.showsStartFresh = !context.hasIdentity && duo.pendingOp != nil && duo.hasEnded && !context.hasLiveDuo

        return rows
    }

    /// Whether the duo ended because the other member no longer exists: they deleted their Duo data
    /// (`<role>_deleted`), or it was the App Review sample partner, a member of the service's own.
    /// Their seat is empty, so a block of the card is answered 204 with nothing written (§7.6), and
    /// the dialog's "For a year, no invite of yours will pair you again" would not be true.
    static func partnerIsGone(from duo: DuoState) -> Bool {
        switch duo.endedBy {
        case .partnerDeleted?: return duo.myRole == .owner
        case .ownerDeleted?: return duo.myRole == .partner
        case .demoExpired?: return true
        case .owner?, .partner?, .inactive?, .unknown?, nil: return false
        }
    }

    /// The partner's name as the server holds it: never the nickname, never the "Your partner"
    /// fallback, and empty when the server has none.
    public static func partnerServerName(of duo: DuoState) -> String {
        duo.myRole == .owner ? duo.partnerDisplayName : duo.ownerDisplayName
    }

    // MARK: - The other sections

    /// The add section's first row.
    public enum AddRow: Equatable, Sendable {
        /// "Start a duo streak".
        case start
        /// A free person at the limit of one: the iCloud lock row, which opens the paywall.
        case locked
        /// A subscriber at five: "You are in 5 duos, which is as many as there can be."
        case full
        /// The app may not start a duo now (an update needed, disconnected, banned, the restore
        /// question): the banner says why.
        case hidden
    }

    public static func addRow(in context: Context) -> AddRow {
        guard context.availability.allowsWrites else { return .hidden }
        // Ended duos take no place (`DuoLimit`); only the second duo is behind HydroDrop+.
        if DuoLimit.canAddDuo(existing: context.duos, isSubscribed: context.isSubscribed) { return .start }
        return context.isSubscribed ? .full : .locked
    }

    /// "Have an invite code?": whenever the app may write.
    public static func showsHaveCode(in context: Context) -> Bool { context.availability.allowsWrites }

    /// The Duo notifications toggle, while at least one duo is live (one nobody joined yet too).
    public static func showsNotificationsToggle(in context: Context) -> Bool { context.hasLiveDuo }

    /// Diagnostics, while this phone holds a credential.
    public static func showsDiagnostics(in context: Context) -> Bool { context.hasIdentity }

    /// Delete my Duo data, while this phone holds a credential, never behind the availability
    /// banner (a banned member and a superseded phone can still delete, D33), except during the
    /// restore question: the credential may be someone else's, the exit service sends nothing then
    /// and says nothing, and "Not me, start fresh" is the way out (D87).
    public static func showsDelete(in context: Context) -> Bool { context.hasIdentity && !context.restoreQuestionIsUp }

    /// The Delete row's label: what the approved one says is false while the credential is a
    /// Reconnect's throwaway (D68).
    public static func deleteRow(credentialIsAThrowaway: Bool) -> String {
        credentialIsAThrowaway ? deleteFromThisPhone : DuoCopy.deleteMyDuoData
    }

    /// The screen's last line, or nil when there is no usable request id to quote. The id goes
    /// through the filter Diagnostics keeps ids under, whatever the cache held.
    public static func requestIDLine(_ lastRequestID: String?) -> String? {
        DuoDiagnostics.usableRequestID(lastRequestID).map(requestReference)
    }

    /// The Settings row's value, in words like its neighbours' ("On", "2 on"): how many duos are
    /// live, an invite nobody has joined yet included. NEW COPY (D87).
    public static func settingsRowValue(liveDuos: Int) -> String {
        switch liveDuos {
        case ..<1: return "Off"
        case 1: return "1 duo"
        default: return "\(liveDuos) duos"
        }
    }

    /// Whether the code-entry sheet's `onDismiss` closes Settings: only when the sheet published a
    /// pending invite (a code typed or scanned), so the root's join sheet can come up once both
    /// sheets have gone. A sheet cancelled without a code leaves Settings open. `before` is the
    /// pending invite when the sheet was opened: an older one still waiting is not this sheet's.
    /// Settings is closed from that `onDismiss` and never in the turn the entry sheet closes,
    /// because two stacked sheets must never be dismissed together.
    public static func closesSettingsAfterEntry(pendingInvite: DuoPendingInvite?, before: DuoPendingInvite? = nil) -> Bool {
        guard let pendingInvite else { return false }
        return pendingInvite != before
    }

    /// The setup sheet hands its new duo to the invite sheet only once it has gone: the duo is held
    /// at `created(_:)`, the setup sheet closes itself, and its `onDismiss` takes it with
    /// `setupDidDismiss()`. Presenting the invite sheet from `created` would stack it on the setup
    /// sheet, and a sheet asked for while another is on screen or leaving is dropped.
    public struct SetupHandoff: Equatable, Sendable {
        public private(set) var created: UUID?

        public init() {}

        public mutating func created(_ id: UUID) { created = id }

        /// The duo whose invite sheet comes up now, once.
        public mutating func setupDidDismiss() -> UUID? {
            defer { created = nil }
            return created
        }
    }

    // MARK: - Taps, confirmations and actions

    /// What the screen asks a service to do. Only a `Confirmation` makes one.
    public enum Action: Equatable, Sendable {
        case leave(UUID)
        case block(UUID)
        case clear(UUID)
        /// With the wording the dialog showed: a dialog opened while the credential was a
        /// Reconnect's throwaway ("from this phone") must not delete everywhere if that has changed.
        case deleteMyData(throwaway: Bool)
        case sendNudge(DuoNudgePreset, UUID)
        case startFresh
    }

    /// A dialog the person must answer before anything happens, with its words.
    public struct Confirmation: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case nudge, leave, block, clear, delete, startFresh
        }

        public let kind: Kind
        public let duoID: UUID?
        public let title: String
        public let message: String
        /// The destructive button's label; nil for a nudge, whose buttons are the presets.
        public let confirmLabel: String?
        /// For a delete: whether it showed the throwaway's "from this phone" wording.
        public let deletesOnlyThisPhone: Bool

        init(kind: Kind, duoID: UUID?, title: String, message: String, confirmLabel: String?, deletesOnlyThisPhone: Bool = false) {
            self.kind = kind
            self.duoID = duoID
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
            self.deletesOnlyThisPhone = deletesOnlyThisPhone
        }

        public var id: String { Self.anchor(kind, duoID) }

        /// Which row's dialog this is: each row presents only its own, so the dialog is anchored to
        /// the row that asked (iOS 26 shows a confirmation dialog as a popover from its view).
        public static func anchor(_ kind: Kind, _ duoID: UUID?) -> String { "\(kind.rawValue).\(duoID?.uuidString ?? "me")" }

        /// The nudge dialog's buttons, one per ready-made line; none for any other dialog.
        public var presets: [DuoNudgePreset] { kind == .nudge ? DuoNudgePreset.allCases : [] }

        /// What the confirm button (or, for a nudge, the chosen line) asks for.
        public func action(preset: DuoNudgePreset? = nil) -> Action? {
            switch kind {
            case .nudge:
                guard let preset, let duoID else { return nil }
                return .sendNudge(preset, duoID)
            case .leave: return duoID.map(Action.leave)
            case .block: return duoID.map(Action.block)
            case .clear: return duoID.map(Action.clear)
            case .delete: return .deleteMyData(throwaway: deletesOnlyThisPhone)
            case .startFresh: return .startFresh
            }
        }
    }

    public static func nudgeConfirmation(for duo: DuoState) -> Confirmation {
        Confirmation(kind: .nudge, duoID: duo.id, title: sendNudge, message: nudgeDialogMessage, confirmLabel: nil)
    }

    /// The Leave dialog (§12.2), with D87's generic "also ends" sentence; for a duo nobody joined,
    /// H12's line of its own.
    public static func leaveConfirmation(for duo: DuoState) -> Confirmation {
        let message = duo.partnerHasJoined
            ? fill(DuoCopy.leaveMessage(partner: partnerToken, alsoEndsAnotherDuo: false), with: partnerName(of: duo)) + "\n\n" + alsoEndsSentence
            : pendingLeaveMessage
        return Confirmation(kind: .leave, duoID: duo.id, title: leaveTitle, message: message, confirmLabel: leaveButton)
    }

    /// The Block dialog (§11.8): the active card's text on a live duo; on an ended one the approved
    /// first sentence "This ends any other duo you share with <Partner>.", which is true whether or
    /// not one exists, where the name-matched guess could be wrong either way (D87). The same
    /// builder serves stage G's "Not them?" at integration.
    public static func blockConfirmation(for duo: DuoState) -> Confirmation {
        let name = partnerName(of: duo)
        return Confirmation(kind: .block, duoID: duo.id, title: fill(DuoCopy.blockTitle(partner: partnerToken), with: name),
                            message: fill(DuoCopy.blockMessage(partner: partnerToken, onEndedCard: duo.hasEnded,
                                                               sharesAnotherDuo: duo.hasEnded), with: name),
                            confirmLabel: blockButton)
    }

    public static func clearConfirmation(for duo: DuoState) -> Confirmation {
        Confirmation(kind: .clear, duoID: duo.id, title: clearTitle, message: DuoCopy.clearMessage, confirmLabel: clearButton)
    }

    public static func startFreshConfirmation(for duo: DuoState) -> Confirmation {
        Confirmation(kind: .startFresh, duoID: duo.id, title: startFreshTitle, message: startFreshMessage,
                     confirmLabel: DuoCopy.disconnectedStartFresh)
    }

    /// The Delete my Duo data dialog (§12.3), or its throwaway form (D68).
    public static func deleteConfirmation(credentialIsAThrowaway: Bool) -> Confirmation {
        let label = deleteRow(credentialIsAThrowaway: credentialIsAThrowaway)
        return Confirmation(kind: .delete, duoID: nil, title: label,
                            message: credentialIsAThrowaway ? deleteFromThisPhoneMessage : DuoCopy.deleteMessage,
                            confirmLabel: label, deletesOnlyThisPhone: credentialIsAThrowaway)
    }

    /// The rows a person can tap.
    public enum Row: Equatable, Sendable {
        case nudge, invite, leave, block, clear, report, startFresh
        case start, locked, haveCode, delete
    }

    /// The sheets the screen presents itself.
    public enum Sheet: Equatable, Sendable {
        case setup
        case invite(UUID)
        case codeEntry
        case report(UUID)
        case paywall
    }

    public enum TapResult: Equatable, Sendable {
        case confirm(Confirmation)
        case present(Sheet)
        case perform(Action)
        /// The row is not offered in this state (a stale tap on a row that has just gone).
        case nothing
    }

    /// What a tap on `row` does, judged against the state now, so a row that has gone since the
    /// screen was drawn does nothing. `duo` is the duo the row sits under, if any, and `verdict`
    /// the store's `nudgeVerdict(for:)` for it (only the nudge row reads it; a Send row exists only
    /// while it allows one).
    public static func tap(_ row: Row, on duo: DuoState?, verdict: DuoNudgeRules.Verdict = .nobodyToNudge,
                           in context: Context) -> TapResult {
        if let duo {
            // Judged on the duo as the store holds it now, not on the copy the row was drawn from,
            // and not at all once the duo has gone (cleared, or wiped).
            guard let current = context.duos.first(where: { $0.id == duo.id }) else { return .nothing }
            return tap(row, onDuo: current, verdict: verdict, in: context)
        }
        switch row {
        case .start:
            return addRow(in: context) == .start ? .present(.setup) : .nothing
        case .locked:
            return addRow(in: context) == .locked ? .present(.paywall) : .nothing
        case .haveCode:
            return showsHaveCode(in: context) ? .present(.codeEntry) : .nothing
        case .delete:
            return showsDelete(in: context)
                ? .confirm(deleteConfirmation(credentialIsAThrowaway: context.credentialIsAThrowaway)) : .nothing
        case .nudge, .invite, .leave, .block, .clear, .report, .startFresh:
            return .nothing
        }
    }

    private static func tap(_ row: Row, onDuo duo: DuoState, verdict: DuoNudgeRules.Verdict, in context: Context) -> TapResult {
        let rows = rows(for: duo, verdict: verdict, in: context)
        switch row {
        case .nudge:
            guard case .send(_, true)? = rows.nudge else { return .nothing }
            return .confirm(nudgeConfirmation(for: duo))
        case .invite:
            return rows.showsInvite ? .present(.invite(duo.id)) : .nothing
        case .leave:
            return rows.showsLeave ? .confirm(leaveConfirmation(for: duo)) : .nothing
        case .block:
            return rows.block != nil ? .confirm(blockConfirmation(for: duo)) : .nothing
        case .clear:
            return rows.showsClear ? .confirm(clearConfirmation(for: duo)) : .nothing
        case .report:
            return rows.showsReport ? .present(.report(duo.id)) : .nothing
        case .startFresh:
            return rows.showsStartFresh ? .confirm(startFreshConfirmation(for: duo)) : .nothing
        case .start, .locked, .haveCode, .delete:
            return tap(row, on: nil, verdict: verdict, in: context)
        }
    }

    /// The confirm button's action, judged once more against the state at the moment it is pressed:
    /// a dialog can sit open while things change. An action whose row has gone does nothing; a
    /// delete whose wording no longer holds (the throwaway marker came or went) asks again with the
    /// right words rather than deleting under the wrong ones (D68, D87).
    public static func confirm(_ action: Action, verdict: DuoNudgeRules.Verdict = .nobodyToNudge, in context: Context) -> TapResult {
        func stillOffered(_ row: Row, _ id: UUID, _ kind: Confirmation.Kind) -> Bool {
            guard let duo = context.duos.first(where: { $0.id == id }) else { return false }
            if case .confirm(let again) = tap(row, onDuo: duo, verdict: verdict, in: context) { return again.kind == kind }
            return false
        }
        switch action {
        case .leave(let id):
            return stillOffered(.leave, id, .leave) ? .perform(action) : .nothing
        case .block(let id):
            return stillOffered(.block, id, .block) ? .perform(action) : .nothing
        case .clear(let id):
            return stillOffered(.clear, id, .clear) ? .perform(action) : .nothing
        case .sendNudge(_, let id):
            return stillOffered(.nudge, id, .nudge) ? .perform(action) : .nothing
        case .startFresh:
            let offered = context.duos.contains { rows(for: $0, verdict: .nobodyToNudge, in: context).showsStartFresh }
            return offered ? .perform(action) : .nothing
        case .deleteMyData(let throwaway):
            guard showsDelete(in: context) else { return .nothing }
            guard throwaway == context.credentialIsAThrowaway else {
                return .confirm(deleteConfirmation(credentialIsAThrowaway: context.credentialIsAThrowaway))
            }
            return .perform(action)
        }
    }
}
