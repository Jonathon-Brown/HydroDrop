import Foundation

/// The words Jonathon has approved for Duo v2's screens, in one place. A view takes its
/// wording from here and invents none: any other user-facing string a stage wants is new
/// copy, listed in its plan entry for his approval before it ships. Each constant is the
/// final design's text word for word, with the section it came from.
public enum DuoCopy {
    // MARK: What is shared, said before the consent tap (§12.7, PRIV §4)

    /// The explainer's lines, in order. The first three were in the iCloud version; the next
    /// two are the explainer's additions (§12.7). The last is the iCloud version's closing line
    /// as release/1.8 corrected it (2d2b7ef): the first draft ended "how much, or when", and the
    /// "when" was never true, since every day's row records when it last changed and the "hit
    /// their goal" notification arrives soon after the drink that did it. The fourth line above
    /// says as much, so the closing one may only promise what the code keeps to (§12.7: "Never
    /// what you drank or exactly how much stays true").
    public static let explainerLines = [
        "Your first name and your droplet",
        "Whether you met your goal each day",
        "Roughly how far along you are",
        "When your phone last updated each day",
        "Counts only what you log in HydroDrop",
        "Never what you drank or exactly how much",
    ]

    /// The footer under the Duo screen's add rows: the iCloud version's, with the same closing
    /// correction as the explainer. A constant here so the screen and the explainer cannot
    /// drift apart again, and so a test can hold every promise to the same words.
    public static let screenFooter = "One streak, two people. It grows on every day you both meet your own goal. Your partner sees your first name, your droplet, whether you met your goal, and roughly how far along you are. Never what you drank or exactly how much."

    /// The two honesty lines (§12.7; the first approved 2026-10-02, the second D §3.4).
    public static let honestyLineStored = "Our service stores what is listed here, plus the few things our privacy policy lists, and we can see it."
    public static let honestyLinePaired = "Our service also sees that your two phones are paired and when they sync."

    /// Under the name field in the setup and join sheets (§12.7: replaces "It stays between the two of you").
    public static let partnerSeesFooter = "This is what your partner will see. It is also stored on our Duo service; see the privacy policy."

    /// On the invite sheet (§12.7).
    public static let inviteSheetWarning = "Anyone who opens this before it is used can join and will see your first name. Send it only to your partner."

    /// The Duo notifications toggle's footer, approved 2026-10-02 (§9.6). It holds only while
    /// the app sends its time zone with the toggle off (§6.2).
    public static let notificationsFooter = "A nudge from your partner, the moment they meet their goal, and when a duo starts or moves to a new phone. Even with these off, you'll be told when a duo ends, between 8:00 and 22:00 your time."

    /// Shown once when the goal is raised with a duo running (§8.6, vector X5).
    public static let goalRaiseNotice = "Your last week is judged against the new goal. Days you no longer reach will count as missed for your duo too."

    // MARK: Dialogs approved 2026-10-02

    /// The Leave dialog (§12.2). `alsoEndsAnotherDuo` is true when another live duo with the same
    /// partner exists, which a leave ends too (§7.5).
    public static func leaveMessage(partner: String, alsoEndsAnotherDuo: Bool) -> String {
        var text = "This ends the duo for both of you and the shared streak is gone. Your days and name are removed from it. \(partner) will see that it ended. They can't pair with you again unless a new invite of yours reaches them. That holds only while you both keep the same Duo identities: once either of you deletes your Duo data, or they start again on a phone without theirs, our service can't tell it's the two of you."
        if alsoEndsAnotherDuo { text += "\n\nYour other duo with \(partner) ends too." }
        return text
    }

    /// An ended duo's Clear dialog (§12.2).
    public static let clearMessage = "It is already over. This only takes it off your screen."

    public static func blockTitle(partner: String) -> String { "Block \(partner)?" }

    /// The Block confirmation (§11.8). On an active card the first sentence is "This ends your
    /// duo with <Partner>, and any other you share."; on an ended card it is "This ends any other
    /// duo you share with <Partner>." or is left out when there is none.
    public static func blockMessage(partner: String, onEndedCard: Bool, sharesAnotherDuo: Bool) -> String {
        let rest = "For a year, no invite of yours will pair you again, even one you send them on purpose, and you can't join theirs. If either of you deletes your Duo data, or they start Duo Streaks again from scratch, we can't tell it's them. \(partner) will see that the duo ended, not that you blocked them."
        if !onEndedCard { return "This ends your duo with \(partner), and any other you share. \(rest)" }
        return sharesAnotherDuo ? "This ends any other duo you share with \(partner). \(rest)" : rest
    }

    /// The Delete my Duo data dialog (§12.3).
    public static let deleteMessage = "This deletes your name, droplet, days, nudges, notification token and Duo key, on this phone and any other device that shares your Duo Streaks, from HydroDrop's Duo service, and ends every duo you are in. Copies may remain in our backups for up to 30 days, and the privacy policy lists the few other traces that stay for a while. It cannot be undone."

    // MARK: Lines quoted in the final design

    /// "This phone was connected to a duo with <partner>. Continue as <name>?" (§3.4), with its
    /// two buttons.
    public static func restorePrompt(partner: String, name: String) -> String {
        "This phone was connected to a duo with \(partner). Continue as \(name)?"
    }
    public static let restoreContinue = "Continue"
    public static let restoreStartFresh = "Not me, start fresh"

    /// After a `device_revoked` (§3.4), with its two buttons.
    public static let disconnectedTitle = "This phone was disconnected from the duo"
    public static let disconnectedHadADuo = "I had a duo"
    public static let disconnectedStartFresh = "Start fresh"

    public static let createAndInvite = "Create and invite"
    public static let join = "Join"
    public static let makeANewCode = "Make a new code"
    public static let notThem = "Not them? Leave & block"
    public static let sampleBadge = "Sample"
    public static let showAs = "Show as:"
    public static let deleteMyDuoData = "Delete my Duo data"
    public static let diagnostics = "Diagnostics"
    public static let exportDiagnostics = "Export diagnostics"
    public static let reportAProblem = "Report a problem"

    /// "Alex invited you to keep a streak together." (§4.3).
    public static func inviteBanner(inviter: String) -> String { "\(inviter) invited you to keep a streak together." }
    /// "Waiting for your partner to accept the invite." (§4.3, the iCloud version's card line).
    public static let waitingForPartner = "Waiting for your partner to accept the invite."
    /// "Reconnect <name>'s new phone" (§3.5).
    public static func reconnectOffer(partner: String) -> String { "Reconnect \(partner)'s new phone" }
    /// "Not seen since <day>" (§14), with the day written by the view.
    public static func notSeenSince(_ day: String) -> String { "Not seen since \(day)" }
    /// The invite's countdown, "expires in 48 h" (§4.3), with the hours left.
    public static func expiresIn(hours: Int) -> String { "expires in \(hours) h" }
    /// What a card with a streak at the edge of the kept window says instead of a number (§8.5).
    public static func streakText(days: Int, reachedEdge: Bool) -> String { reachedEdge ? "\(DuoStreak.retentionDays)+ days" : "\(days)" }

    /// The reasons the report sheet offers: no free text (§11.8).
    public static let reportReasons = ["Offensive name", "Unwanted nudges", "Not the person I invited"]

    /// The first confirmation of an invite sent by typing: "That does not look like a duo code" (§4.1).
    public static let notACode = "That does not look like a duo code"
}
