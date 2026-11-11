import Foundation

// What a duo's card, the buttons under it, the cards that need the person first and Today's
// Duo rows say and show, decided without SwiftUI so `swift test` proves every line (final
// design §3.4, §3.5, §4.3, §7.5, §8.5, §11.8 and §14's DuoCard row; D83). The card on Today,
// the first row of each duo on the Duo screen and the notices above them only draw these
// answers.
//
// Every word here is approved except the lines marked NEW COPY, which are placeholders
// awaiting Jonathon: the iCloud card's own lines, unchanged ("You", "Not here yet", "Your duo
// ended", "<name> left this duo.", "<name> ended this duo.", "day together", "days together"
// and its spoken sentences), and `DuoCopy`'s. A name is never cleaned, cut or escaped here: the
// view draws every line that holds one with `Text(verbatim:)`, which reads nothing in it as
// markdown or a format (§11.5). Inside a sentence a name is wrapped in Unicode's first-strong
// isolate (U+2068 ... U+2069, D83), so an Arabic or Hebrew name, or one that carries a
// right-to-left override, cannot reorder the words around it; a name that stands alone (a
// droplet's label) is drawn as it is. A missing name reads "Your partner" where it starts a
// sentence and "your partner" inside one.

/// What one duo's card says right now.
public struct DuoCardModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The owner's invite has not been accepted yet.
        case waiting
        case running
        /// Over, or a leave or block still waiting for the network: an offline Leave shows the
        /// ended card at once (§10.1), with a line that says it has not gone yet.
        case ended
    }

    /// One droplet and the two lines under it.
    public struct Side: Equatable, Sendable {
        public var role: DuoRole
        /// Standing alone under the droplet, so not isolated: `displayName(of:)` exactly.
        public var name: String
        /// The skin's raw value as the server holds it. The view draws the classic droplet for
        /// one this build does not know, as the iCloud card did.
        public var skin: String
        public var progressBucket: Int
        public var goalMet: Bool
        public var line: String
        /// A partner who has not joined yet: the droplet is drawn faded (not the words, which
        /// would fall below a readable contrast in dark mode).
        public var isDimmed: Bool

        public init(role: DuoRole, name: String, skin: String, progressBucket: Int, goalMet: Bool, line: String, isDimmed: Bool) {
            self.role = role
            self.name = name
            self.skin = skin
            self.progressBucket = progressBucket
            self.goalMet = goalMet
            self.line = line
            self.isDimmed = isDimmed
        }
    }

    public var phase: Phase
    public var mine: Side
    public var partner: Side
    public var streakDays: Int
    /// The number, or "100+ days" once the streak reaches the edge of the kept window (§8.5).
    public var streakText: String
    /// "day together" or "days together" under a number. Nil under "100+ days", which already
    /// says "days", so the card does not say it twice.
    public var streakCaption: String?
    /// The flame is lit for a streak of a day or more, as before, and at the edge.
    public var streakIsLit: Bool
    /// The waiting card's line (§4.3).
    public var waitingLine: String?
    public var endedTitle: String?
    /// Who ended it, only where approved wording exists (see `endedLine(for:)`).
    public var endedLine: String?
    /// A leave or block that has not reached the server yet says so (D83, NEW COPY): stage E
    /// drops one the server refuses, so "Your duo ended" alone would claim more than is known.
    public var pendingLine: String?
    /// "Not seen since Sep 22" for a partner whose phone has not written for more than three
    /// days (§3.5, §14).
    public var notSeenLine: String?
    /// The App Review sample partner (§7.13) is badged "Sample" beside their name.
    public var showsSampleBadge: Bool
    /// What VoiceOver reads for the card, which is one element as the iCloud card was. The
    /// visible lines it would otherwise lose (not seen since, the badge, a pending exit) are
    /// read too.
    public var spokenSummary: String

    // MARK: The iCloud card's own words, unchanged

    public static let myName = "You"
    public static let notHereYet = "Not here yet"
    public static let endedTitleText = "Your duo ended"
    public static let dayTogether = "day together"
    public static let daysTogether = "days together"

    public static func partnerLeft(_ partner: String) -> String { "\(partner) left this duo." }
    public static func ownerEnded(_ owner: String) -> String { "\(owner) ended this duo." }

    // MARK: New copy

    /// NEW COPY (placeholder, awaiting approval, D83): under "Your duo ended" while the leave or
    /// block is still queued.
    public static let pendingExitLine = "Waiting for a connection to finish this."
    /// NEW COPY (placeholder, awaiting approval, G7): what VoiceOver says for the page dots.
    public static func pageValue(index: Int, count: Int) -> String { "Page \(index + 1) of \(count)" }

    // MARK: Names in sentences

    /// The name wrapped in a first-strong isolate (U+2068 ... U+2069), for use inside a sentence.
    public static func isolated(_ name: String) -> String { "\u{2068}\(name)\u{2069}" }

    /// The partner's name if there is one: the nickname this person gave (D29), else the
    /// server's. Nil where `displayName(of:)` would say "Your partner", so a sentence can
    /// choose its own capital.
    public static func partnerName(of duo: DuoState) -> String? {
        let role = duo.myRole.other
        if let nickname = duo.partnerNickname, !nickname.isEmpty { return nickname }
        let name = role == .owner ? duo.ownerDisplayName : duo.partnerDisplayName
        return name.isEmpty ? nil : name
    }

    /// `template` with the partner's isolated name, or with "Your partner" where the slot starts
    /// a sentence and "your partner" elsewhere. One template can hold the name in both places
    /// (the Block confirmation does), so the slot is filled with a marker first and each
    /// occurrence is decided where it stands.
    public static func sentence(_ template: (String) -> String, partner name: String?) -> String {
        if let name { return template(isolated(name)) }
        let marker = "\u{E000}"
        let text = template(marker)
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            let before = result + rest[..<range.lowerBound]
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            let startsSentence = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
            result = before + (startsSentence ? "Your partner" : "your partner")
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    // MARK: The answer

    /// - Parameters:
    ///   - myStatus: my side today, which the app reads from the log as it stands
    ///     (`DuoStore.status(of:in:)`), so my droplet never lags my drinks.
    ///   - partnerStatus: the partner's side as `DuoStreak.currentStatus` shows it.
    ///   - streak: `DuoStreak.current` for the duo.
    ///   - reachedEdge: `DuoStreak.reachedRetentionEdge` for the duo.
    ///   - myToday: today's day key on this phone.
    ///   - locale: the one the "Not seen since" day is written in.
    public static func make(duo: DuoState, myStatus: DuoDayStatus?, partnerStatus: DuoDayStatus?, streak: Int,
                            reachedEdge: Bool, myToday: String, locale: Locale) -> DuoCardModel {
        let phase: Phase
        if duo.hasEnded || duo.pendingOp != nil {
            phase = .ended
        } else if duo.isPending {
            phase = .waiting
        } else {
            phase = .running
        }
        let partnerRole = duo.myRole.other
        let partnerLabel = duo.displayName(of: partnerRole)
        // A shared streak needs two people: until someone joins there is none, whatever the
        // statuses say (my own rows alone can never make one, but a stray row could).
        let days = phase == .waiting ? 0 : max(0, streak)
        let atEdge = phase == .waiting ? false : reachedEdge

        let mine = Side(role: duo.myRole, name: myName, skin: duo.skinRawValue(of: duo.myRole),
                        progressBucket: myStatus?.progressBucket ?? 0, goalMet: myStatus?.goalMet ?? false,
                        line: DuoProgress.line(for: myStatus), isDimmed: false)
        // Nobody is on the other side of a waiting duo yet: the droplet is empty and faded and says
        // so, whatever a stray status might claim.
        let unjoined = phase == .waiting
        let partner = Side(role: partnerRole, name: partnerLabel, skin: duo.skinRawValue(of: partnerRole),
                           progressBucket: unjoined ? 0 : partnerStatus?.progressBucket ?? 0,
                           goalMet: unjoined ? false : partnerStatus?.goalMet ?? false,
                           line: unjoined ? notHereYet : DuoProgress.line(for: partnerStatus), isDimmed: unjoined)

        // `partnerSilentSince` already answers nil for a pending, ended or sample duo; a live duo
        // with a leave on its way is drawn ended and says nothing about the partner either.
        let notSeen = phase == .running
            ? duo.partnerSilentSince(myToday: myToday).flatMap { shortDay($0, locale: locale) }.map(DuoCopy.notSeenSince)
            : nil

        var model = DuoCardModel(
            phase: phase, mine: mine, partner: partner, streakDays: days,
            streakText: DuoCopy.streakText(days: days, reachedEdge: atEdge),
            streakCaption: atEdge ? nil : (days == 1 ? dayTogether : daysTogether),
            streakIsLit: days > 0 || atEdge,
            waitingLine: phase == .waiting ? DuoCopy.waitingForPartner : nil,
            endedTitle: phase == .ended ? endedTitleText : nil,
            endedLine: phase == .ended ? endedLine(for: duo) : nil,
            pendingLine: duo.pendingOp != nil ? pendingExitLine : nil,
            notSeenLine: notSeen,
            showsSampleBadge: duo.partnerIsDemo,
            spokenSummary: ""
        )
        model.spokenSummary = spoken(model, partner: partnerName(of: duo), reachedEdge: atEdge)
        return model
    }

    /// The ended card's second line. When the other person ended it, the iCloud card's own
    /// sentences stay: an owner reads "<partner> left this duo.", a partner "<owner> ended this
    /// duo.". Every other end (mine, either side deleting their Duo data, `inactive`,
    /// `demo_expired`, `unknown`, or none recorded) has no approved wording yet, so the card shows
    /// "Your duo ended" alone rather than a line nobody approved (listed as new copy for later).
    public static func endedLine(for duo: DuoState) -> String? {
        switch (duo.myRole, duo.endedBy) {
        case (.owner, .partner?): return sentence(partnerLeft, partner: partnerName(of: duo))
        case (.partner, .owner?): return sentence(ownerEnded, partner: partnerName(of: duo))
        default: return nil
        }
    }

    /// A day key written the way a person reads a short date in `locale` ("Sep 22" in English),
    /// never the raw key. The key is a calendar day, not an instant, so it is read and written at
    /// midnight in UTC, where no time zone can move it to the day before. Nil for anything that is
    /// not a day key.
    public static func shortDay(_ dayKey: String, locale: Locale) -> String? {
        guard DuoStreak.isDayKey(dayKey), let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let date = DayKey.date(from: dayKey, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let text = formatter.string(from: date)
        return text.isEmpty ? nil : text
    }

    /// The iCloud card's spoken sentences, with "100+ days" in place of the number at the edge and
    /// the lines a combined element would otherwise hide added after them. Spoken, so no isolates;
    /// a missing name is "your partner" inside a sentence and "Your partner" starting one.
    private static func spoken(_ model: DuoCardModel, partner: String?, reachedEdge: Bool) -> String {
        let inside = partner ?? "your partner"
        let starting = partner ?? "Your partner"
        var text: String
        switch model.phase {
        case .ended:
            text = "Your duo with \(inside) ended."
        case .waiting:
            text = "Duo streak. \(DuoCopy.waitingForPartner)"
        case .running:
            let count = reachedEdge ? model.streakText : "\(model.streakDays) \(model.streakDays == 1 ? "day" : "days")"
            text = "Duo streak with \(inside). \(count) together. You: \(model.mine.line). \(starting): \(model.partner.line)."
        }
        if let pending = model.pendingLine { text += " \(pending)" }
        if let notSeen = model.notSeenLine { text += " \(notSeen)." }
        if model.showsSampleBadge { text += " \(DuoCopy.sampleBadge)." }
        return text
    }

    /// The pager's order on Today: live duos first, then the one waiting for its partner, then
    /// the ended ones (a duo with a leave on its way counts as ended), each group as the store
    /// holds it. An ended card used to be able to take the first page from a live one.
    public static func pagerOrder(_ duos: [DuoState]) -> [DuoState] {
        func rank(_ duo: DuoState) -> Int {
            if duo.hasEnded || duo.pendingOp != nil { return 2 }
            return duo.isPending ? 1 : 0
        }
        return duos.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// The buttons that sit under a card, apart from it because on Today the card is itself a link to
/// the Duo screen (final design §3.5, §4.3, §11.8; D83).
public struct DuoCardActionsModel: Equatable, Sendable {
    /// "Not them? Leave & block", for the owner for 24 hours from the server's `joined_at`.
    public var offersNotThem: Bool
    /// "Reconnect <name>'s new phone", once the partner has been silent more than three days.
    public var offersReconnect: Bool

    public var isEmpty: Bool { !offersNotThem && !offersReconnect }

    /// Neither is offered on a duo that is over or has a leave or block on its way, which is drawn
    /// as ended. "Not them?" is offered only when it can work (D83): never to a banned member (the
    /// server answers a block from one `403 banned`), and only while the phone holds a credential
    /// that is not a Reconnect's throwaway (`canSendExits`), which is what stage E's exit service
    /// needs to queue a block at all; without one it says only "That did not work". The reconnect
    /// offer needs a phone that may write, since making the code is a write: on a phone that is
    /// disconnected, banned, out of date or waiting on the restore question the code sheet could
    /// only fail.
    public static func make(duo: DuoState, availability: DuoAvailability, now: Date, myToday: String,
                            canSendExits: Bool = true) -> DuoCardActionsModel {
        let over = duo.hasEnded || duo.pendingOp != nil
        return DuoCardActionsModel(
            offersNotThem: !over && canSendExits && availability != .banned && duo.showsNotThemCard(now: now),
            offersReconnect: !over && availability.allowsWrites && duo.offersReconnect(myToday: myToday)
        )
    }

    /// "Block <partner>?", with the partner's name isolated, or "your partner" without one.
    public static func blockTitle(for duo: DuoState) -> String {
        DuoCardModel.sentence(DuoCopy.blockTitle, partner: DuoCardModel.partnerName(of: duo))
    }

    /// The active card's Block message. Whether another live duo with the same person exists
    /// cannot be known on the phone (each duo's partner is a different member as far as it can
    /// tell), so it is the active card's, whose first sentence already says "and any other you
    /// share".
    public static func blockMessage(for duo: DuoState) -> String {
        DuoCardModel.sentence({ DuoCopy.blockMessage(partner: $0, onEndedCard: false, sharesAnotherDuo: false) },
                              partner: DuoCardModel.partnerName(of: duo))
    }

    /// "Reconnect <partner>'s new phone".
    public static func reconnectOffer(for duo: DuoState) -> String {
        DuoCardModel.sentence(DuoCopy.reconnectOffer, partner: DuoCardModel.partnerName(of: duo))
    }
}

/// Which of Duo's rows Today shows, and whether it may talk to the server (D83).
public struct DuoTodayRule: Equatable, Sendable {
    public var showsNotices: Bool
    public var showsCards: Bool
    public var showsSuggestion: Bool
    /// Pull to refresh, and the foreground's refresh and log hand-over.
    public var talksToTheServer: Bool
    public var refreshable: Bool

    /// - Parameters:
    ///   - wantsSuggestion: `DuoInviteMoment.shouldShow` (a few solo days, no duo, never dismissed).
    ///   - screenshotMode: the App Store capture run (`-UITestSeedHistory`). A capture simulator
    ///     that holds a cached duo would otherwise put a card in every capture of Today, and its
    ///     refresh and seeded log could reach the server; nothing of Duo shows or is sent then.
    ///
    /// The suggestion is not made to someone the birth-year screen refused, on a phone that may
    /// not write (disconnected, banned, out of date, the restore question), or while a notice card
    /// asks something first. Pull to refresh is only for someone with a duo or a Duo identity: for
    /// everyone else there is nothing to fetch, and a spinner that does nothing is worse than none.
    public static func make(hasDuos: Bool, hasIdentity: Bool, hasNoticeCards: Bool, wantsSuggestion: Bool,
                            ageRefused: Bool, availability: DuoAvailability, screenshotMode: Bool) -> DuoTodayRule {
        let live = !screenshotMode
        return DuoTodayRule(
            showsNotices: live && hasNoticeCards,
            showsCards: live,
            showsSuggestion: live && wantsSuggestion && !ageRefused && availability.allowsWrites && !hasNoticeCards,
            talksToTheServer: live,
            refreshable: live && (hasDuos || hasIdentity)
        )
    }
}

/// What a notice's button does. The view maps each to the one store call it names.
public enum DuoNoticeAction: Equatable, Sendable {
    case continueAsRestored
    case startFresh
    /// "I had a duo": the caller presents the reconnect sheet.
    case reconnect
    case dismissNewDevice
}

public struct DuoNoticeButton: Equatable, Sendable {
    public var action: DuoNoticeAction
    public var title: String
    /// The one the card leads with.
    public var isPrimary: Bool
}

/// One of the cards that need the person before anything else is sent.
public struct DuoNoticeCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// "This phone was connected to a duo with <partner>. Continue as <name>?" (§3.4).
        case restore
        /// "This phone was disconnected from the duo" (§3.4).
        case disconnected
        /// The service being away, the app being out of date, or a banned member (§6.7).
        case service
        /// A device was added to this person's Duo Streaks (D45).
        case newDevice
    }

    public var kind: Kind
    public var text: String
    public var buttons: [DuoNoticeButton]
    public var id: Kind { kind }
}

public enum DuoNoticeModel {
    /// NEW COPY (placeholder, awaiting approval): the partner in the restore question when the
    /// server gave no name. Lowercase, being inside the sentence (D83).
    public static let partnerFallback = "your partner"
    /// NEW COPY (placeholder, awaiting approval): the person in the restore question when the
    /// server has no name for them.
    public static let myNameFallback = "you"
    /// NEW COPY (placeholder, awaiting approval): the D45 notice.
    public static let newDeviceLine = "A device was added to your Duo Streaks."
    /// The spoken label of the notice's close button, the same as the suggestion card's.
    public static let dismiss = "Dismiss"

    /// The cards, in the order they are drawn, and only those that apply: the restore question or
    /// the disconnected question, else the line about the service (maintenance, an update needed,
    /// banned), and then the new-device notice. Disconnected is a question with two answers, so its
    /// banner line is not drawn a second time as a service line. Nothing here sends anything.
    public static func cards(availability: DuoAvailability, newDeviceNotice: Bool) -> [DuoNoticeCard] {
        var cards: [DuoNoticeCard] = []
        switch availability {
        case .needsRestoreChoice(let prompt):
            cards.append(DuoNoticeCard(kind: .restore, text: restoreText(prompt), buttons: [
                DuoNoticeButton(action: .continueAsRestored, title: DuoCopy.restoreContinue, isPrimary: true),
                DuoNoticeButton(action: .startFresh, title: DuoCopy.restoreStartFresh, isPrimary: false),
            ]))
        case .disconnected:
            cards.append(DuoNoticeCard(kind: .disconnected, text: DuoCopy.disconnectedTitle, buttons: [
                DuoNoticeButton(action: .reconnect, title: DuoCopy.disconnectedHadADuo, isPrimary: true),
                DuoNoticeButton(action: .startFresh, title: DuoCopy.disconnectedStartFresh, isPrimary: false),
            ]))
        case .maintenance, .upgradeRequired, .banned:
            if let line = availability.bannerMessage { cards.append(DuoNoticeCard(kind: .service, text: line, buttons: [])) }
        case .unknown, .available:
            break
        }
        if newDeviceNotice {
            cards.append(DuoNoticeCard(kind: .newDevice, text: newDeviceLine, buttons: [
                DuoNoticeButton(action: .dismissNewDevice, title: dismiss, isPrimary: false),
            ]))
        }
        return cards
    }

    /// The restore question, with both names from the prompt, which is what `GET /me` said about
    /// the identity in the Keychain. It used to fall back to the name this phone kept, which on a
    /// phone handed on with its defaults could be the person now holding it: "Continue as <your
    /// own name>?" invites the wrong answer. A name that is empty, or only spaces, is no name; any
    /// other is used exactly as it came, isolated.
    public static func restoreText(_ prompt: DuoRestorePrompt) -> String {
        func given(_ name: String?) -> String? {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DuoCardModel.isolated(name)
        }
        return DuoCopy.restorePrompt(partner: given(prompt.partnerName) ?? partnerFallback,
                                     name: given(prompt.myName) ?? myNameFallback)
    }
}
