import Foundation

/// The Home Screen's view of the cache. It carries only what is drawn: never drink amounts,
/// credentials or purchase state. Selection happens here so an ended duo cannot leak into a
/// widget merely because it precedes a live one in the saved array.
public struct DuoWidgetModel: Equatable, Sendable {
    /// `unavailable` (finding 8): a refusal, or duos this phone may not show yet (the age recheck,
    /// an unreadable age answer). The empty state's "No duo yet. Start one in HydroDrop" used to
    /// stand in for both, which told a tester in a running duo they had none and invited a refused
    /// child to start one.
    public enum State: Equatable, Sendable { case empty, unavailable, pending, running }
    // NEW COPY (finding 8): the neutral state's only words, drawn and spoken.
    public static let openHydroDrop = "Open HydroDrop"
    public let state: State
    public let partnerName: String
    public let partnerLine: String
    public let mySkin: String
    public let partnerSkin: String
    public let myBucket: Int
    public let partnerBucket: Int
    public let streakDays: Int
    public let streakText: String
    public let sampleBadge: String?
    public let accessibilityLabel: String

    public static func make(duos: [DuoState], ageStatus: DuoAgeStatus, ageCheckUnavailable: Bool, now: Date, snapshotDay: String,
                            snapshotTotalML: Int, snapshotGoalML: Int,
                            calendar: Calendar = .current) -> Self {
        // A widget cannot consult the private Keychain. Only the app's explicit allowed
        // cache state permits display; a refusal or unreadable/missing state draws no duo.
        let shown = duos.filter { !$0.hasEnded && $0.pendingOp == nil }
        let mayShow = ageStatus == .allowed && !ageCheckUnavailable
        let live = mayShow ? shown : []
        guard let duo = live.first(where: { !$0.isPending }) ?? live.first else {
            let unavailable = ageStatus == .refused || (!mayShow && !shown.isEmpty)
            return Self(state: unavailable ? .unavailable : .empty, partnerName: "", partnerLine: "", mySkin: "classic", partnerSkin: "classic",
                        myBucket: 0, partnerBucket: 0, streakDays: 0, streakText: "0", sampleBadge: nil,
                        accessibilityLabel: unavailable ? openHydroDrop : "No duo yet. Start one in HydroDrop, under Settings.")
        }
        let today = DayKey.key(for: now, calendar: calendar)
        let partner = duo.myRole.other
        let theirs = duo.isPending ? nil : DuoStreak.currentStatus(of: partner, statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
        let mine = DuoStreak.currentStatus(of: duo.myRole, statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
        let bucket = snapshotDay == today ? DuoProgress.bucket(totalML: snapshotTotalML, goalML: snapshotGoalML) : mine?.progressBucket ?? 0
        let days = duo.isPending ? 0 : DuoStreak.current(statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
        let edge = !duo.isPending && DuoStreak.reachedRetentionEdge(statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: now)
        let name = duo.displayName(of: partner)
        let isolatedName = "\u{2068}\(name)\u{2069}"
        let count = edge ? "100+ days" : "\(days) \(days == 1 ? "day" : "days")"
        // Finding 14: the Today card's sentence, "You: …" included (my droplet is drawn too), and "your
        // partner" in mid-sentence where the partner has no name, never "with Your partner".
        let spokenName = DuoCardModel.partnerName(of: duo).map(DuoCardModel.isolated)
        let myStatus = snapshotDay == today
            ? DuoProgress.status(role: duo.myRole, day: today, totalML: snapshotTotalML, goalML: snapshotGoalML, now: now) : mine
        let label = duo.isPending ? "Duo streak. Waiting for your partner to accept the invite."
            : "Duo streak with \(spokenName ?? "your partner"). \(count) together. You: \(DuoProgress.line(for: myStatus)). \(spokenName ?? "Your partner"): \(DuoProgress.line(for: theirs))."
        return Self(state: duo.isPending ? .pending : .running, partnerName: name,
                    partnerLine: duo.isPending ? "Waiting for your partner" : "with \(isolatedName)",
                    mySkin: duo.skinRawValue(of: duo.myRole), partnerSkin: duo.skinRawValue(of: partner),
                    myBucket: bucket, partnerBucket: theirs?.progressBucket ?? 0, streakDays: days,
                    streakText: DuoCopy.streakText(days: days, reachedEdge: edge),
                    sampleBadge: duo.partnerIsDemo ? DuoCopy.sampleBadge : nil,
                    accessibilityLabel: label + (duo.partnerIsDemo ? " \(DuoCopy.sampleBadge)." : ""))
    }
}
