import Foundation

// What the two sheets that show a code decide without SwiftUI (plan P2 stage J; final design
// §3.5, §4.1, §4.3 step 3): how many hours a code has left, whether it is still open, and which
// of its states each sheet is in. The views only draw the answer, so `swift test` proves the
// rules and a view's test only has to show that every state draws and that the sheet asks the
// store for what it should and nothing else.

public enum DuoInviteCountdown {
    /// The most a countdown ever says: a code lasts 48 hours (§4.1).
    public static let longestHours = Int(DuoProtocolConstants.inviteLifetime / 3600)

    /// The whole hours a code has left, rounded up, so a code with 47 h 59 min to go says 48 and
    /// one with a minute to go says 1; zero at the moment it expires and after it.
    ///
    /// Never more than 48. `expires_at` is set by the server's clock, so on a phone whose clock is
    /// behind the server's the plain difference would promise more time than any code has (§4.1:
    /// 48 hours). The cap only bounds the number shown: it does not stop a code reading as open on
    /// such a phone after the server has let it go, which nothing on the phone can know. It also
    /// keeps a nonsensical date read back from a damaged cache from overflowing the conversion to
    /// `Int`, which would crash rather than draw.
    public static func hoursLeft(expiresAt: Date, now: Date) -> Int {
        let seconds = expiresAt.timeIntervalSince(now)
        // Written so that a NaN, which compares false with everything, reads as expired.
        guard seconds > 0 else { return 0 }
        let capped = min(seconds, DuoProtocolConstants.inviteLifetime)
        return Int((capped / 3600).rounded(.up))
    }

    /// Whether a code that expires at `expiresAt` can still be used: exactly `DuoInvite.isOpen`,
    /// so the sheet, the card and the service never disagree about the last second.
    public static func isOpen(expiresAt: Date, now: Date) -> Bool {
        expiresAt > now
    }

    /// The countdown line, in the approved words ("expires in 48 h", §4.3).
    public static func label(expiresAt: Date, now: Date) -> String {
        DuoCopy.expiresIn(hours: hoursLeft(expiresAt: expiresAt, now: now))
    }

    // MARK: - Redrawing and the pasteboard

    /// The next moment a code sheet redraws after `date`: the next whole minute counted from
    /// `start`, or the moment the code expires if that comes first. The countdown changes once an
    /// hour, so a minute is plenty for it; but a code that runs out must leave the screen when it
    /// does, not up to a minute later with a QR anyone could still scan, so its expiry is a redraw
    /// of its own. A date that is not a real moment (a damaged cache) adds nothing.
    public static func nextRedraw(after date: Date, start: Date, expiresAt: Date?, every interval: TimeInterval = 60) -> Date {
        let elapsed = date.timeIntervalSince(start)
        let tick: Date
        if elapsed.isFinite {
            tick = elapsed < 0 ? start : start.addingTimeInterval(((elapsed / interval).rounded(.down) + 1) * interval)
        } else {
            tick = date.addingTimeInterval(interval)
        }
        if let expiresAt, expiresAt.timeIntervalSinceReferenceDate.isFinite, expiresAt > date, expiresAt < tick { return expiresAt }
        return tick
    }

    /// How long a copied invite code stays on the pasteboard at most: as long as the code itself
    /// lasts (§4.1), so an absurd `expiresAt` can never keep it there for good (D79).
    public static let invitePasteboardLifetime: TimeInterval = DuoProtocolConstants.inviteLifetime
    /// How long a copied reconnect code stays on the pasteboard at most: ten minutes, long enough
    /// to paste it into a message, because whoever reads it from there can take the partner's place
    /// in every duo they are in (D79, §3.5).
    public static let reconnectPasteboardLifetime: TimeInterval = 10 * 60

    /// When a code copied now leaves the pasteboard: when the code expires, or `longest` from now,
    /// whichever is first. A code whose expiry is not a real moment leaves after `longest`.
    public static func pasteboardExpiry(codeExpiresAt: Date, now: Date, longest: TimeInterval) -> Date {
        let cap = now.addingTimeInterval(longest)
        guard codeExpiresAt.timeIntervalSinceReferenceDate.isFinite else { return cap }
        return min(codeExpiresAt, cap)
    }

    // MARK: - The invite sheet

    /// What the invite sheet shows for the duo it was opened for, as the store holds it now.
    public enum InviteSheet: Equatable, Sendable {
        /// The code this phone made and can still hand over. Its `expiresAt` is the one the
        /// countdown and the copied code keep to.
        case code(DuoInvite)
        /// A duo still waiting for its partner with no code this phone can show: the code expired,
        /// or this phone never had it (the owner reinstalled, and the server never gives a code
        /// back, §6.4). The sheet says so and offers "Make a new code".
        case noOpenCode
        /// The duo is no longer waiting for anyone: the partner joined, it ended, or it is gone
        /// (a wipe). The sheet closes itself.
        case closed
    }

    /// Whether the invite sheet should close: only a duo of mine that is still waiting for its
    /// partner has an invite to show. It does not depend on the time, so the sheet can act on it
    /// the moment the store changes rather than at the next tick.
    public static func inviteSheetCloses(for duo: DuoState?) -> Bool {
        guard let duo else { return true }
        return !duo.isPending
    }

    /// How far apart the server's `expires_at` for the open invite and this phone's copy of its
    /// code may be and still be the same code: the two answers carry the same instant, and a minute
    /// of slack keeps any difference in how each is rounded from voiding a good code.
    public static let sameCodeTolerance: TimeInterval = 60

    public static func inviteSheet(for duo: DuoState?, now: Date) -> InviteSheet {
        guard let duo, !inviteSheetCloses(for: duo) else { return .closed }
        guard var invite = duo.invite else { return .noOpenCode }
        if let serverExpiry = duo.openInviteExpiresAt {
            // The server keeps one open invite per person and voids the others when a new one is
            // made (§7.2), so an open invite that expires later than this phone's code is a newer
            // code: this one was voided (a "Make a new code" whose answer was lost, or a code made
            // for another duo). It used to be read as some other code's that changed nothing, which
            // left a dead code, its QR and its countdown on the screen.
            if serverExpiry.timeIntervalSince(invite.expiresAt) > sameCodeTolerance { return .noOpenCode }
            // An earlier one wins: the code cannot outlive the server's record of it, and the
            // countdown and the copied code must not promise that it does.
            if serverExpiry < invite.expiresAt { invite.expiresAt = serverExpiry }
        }
        return isOpen(expiresAt: invite.expiresAt, now: now) ? .code(invite) : .noOpenCode
    }

    /// The line under "Make a new code" when something went wrong: what the store said, or, when
    /// the person's tap came back with no code and no word while writes are allowed, the general
    /// line. The joining service refuses some taps before sending, without a word (no credential to
    /// send with, another flow still running, a refusal kept from the birth-year screen), and a tap
    /// must never be met with nothing at all. Nil when there is nothing to say. Why writes are off
    /// is said on a line of its own (`DuoAvailability.bannerMessage`).
    public static func inviteSheetError(sheetError: String?, availability: DuoAvailability, tapCameBackEmpty: Bool) -> String? {
        if let sheetError, !sheetError.isEmpty { return sheetError }
        return tapCameBackEmpty && availability.allowsWrites ? DuoUserMessage.generic : nil
    }

    // MARK: - The reconnect code sheet

    /// Whether a reconnect code the sheet was given earlier may be shown again instead of asking for
    /// another (D79): asking again would void the code already sent (§3.5, one open reconnect code
    /// per duo and partner) and spend the day's invite quota. It holds only while nothing was wiped
    /// since it was given (`wipeEpoch`), the code is still open and the duo still live.
    public static func heldReconnectCodeHolds(_ code: DuoInvite, heldAtWipeEpoch held: Int, wipeEpoch: Int, duo: DuoState?, now: Date) -> Bool {
        held == wipeEpoch && isOpen(expiresAt: code.expiresAt, now: now) && !reconnectSheetCloses(for: duo)
    }

    /// What the store answered when the reconnect sheet asked it for a code.
    public enum ReconnectAnswer: Equatable, Sendable {
        /// Not asked yet, or the answer has not come back.
        case notYet
        case code(DuoInvite)
        /// The store gave no code. Why is in `sheetError`, or in the availability, or nowhere.
        case noCode
    }

    /// What the reconnect code sheet shows.
    public enum ReconnectSheet: Equatable, Sendable {
        case waiting
        case code(DuoInvite)
        /// The code it was given has expired while the sheet stayed open. A new one takes a new
        /// tap on the card, which is the person's consent to another; the sheet never asks again
        /// by itself (asking again voids the code already sent, §3.5).
        case noOpenCode
        /// No code: the line to show in its place.
        case failed(String)
        /// The duo ended or is gone: the code would no longer work, and the sheet closes itself.
        case closed
    }

    /// Whether the reconnect sheet should close: a reconnect code is made for a live duo
    /// (§3.5: "either member of an active duo"), so one that ended, or that a wipe took away,
    /// leaves nothing worth handing over.
    public static func reconnectSheetCloses(for duo: DuoState?) -> Bool {
        guard let duo else { return true }
        return duo.hasEnded
    }

    /// The reconnect sheet's state. A failure says what the store said (`sheetError`, set by the
    /// joining service from `DuoUserMessage`); when the store said nothing, which it does when it
    /// refuses before sending (writes are off, the duo no longer offers a reconnect, another flow
    /// is running), it says why writes are off if they are, and otherwise the general line, so
    /// the sheet never sits empty.
    public static func reconnectSheet(for duo: DuoState?, answer: ReconnectAnswer, sheetError: String?,
                                      availability: DuoAvailability, now: Date) -> ReconnectSheet {
        if reconnectSheetCloses(for: duo) { return .closed }
        switch answer {
        case .notYet:
            return .waiting
        case .code(let code):
            return isOpen(expiresAt: code.expiresAt, now: now) ? .code(code) : .noOpenCode
        case .noCode:
            if let sheetError, !sheetError.isEmpty { return .failed(sheetError) }
            if !availability.allowsWrites, let banner = availability.bannerMessage { return .failed(banner) }
            return .failed(DuoUserMessage.generic)
        }
    }
}
