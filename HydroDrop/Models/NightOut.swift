import Foundation

/// The rules of Night Out, as pure functions.
///
/// Night Out exists to get water drunk on an evening when alcohol is. It never counts
/// drinks towards anything, never estimates what they did to anyone, and never rewards
/// a number. Everything it says is about the next glass of water.
enum NightOut {
    /// How long a Night Out lasts if nobody turns it off.
    static let duration: TimeInterval = 6 * 60 * 60
    /// How long after an alcoholic drink the water reminder arrives.
    static let waterRoundDelay: TimeInterval = 20 * 60

    /// Whether a Night Out started at `startedAt` is still running at `now`.
    ///
    /// Two limits, and the earlier one wins: six hours, and the end of the waking window
    /// of the day after it started. The second can only matter if the first is ever
    /// made longer, and it is here so that Night Out can never quietly become a setting
    /// that stays on for days.
    static func isActive(
        startedAt: Date,
        now: Date,
        wakingEndMinutes: Int,
        calendar: Calendar = .current
    ) -> Bool {
        guard now >= startedAt else { return false }
        guard now.timeIntervalSince(startedAt) < duration else { return false }
        return now < hardStop(startedAt: startedAt, wakingEndMinutes: wakingEndMinutes, calendar: calendar)
    }

    /// The end of the waking window on the day after `startedAt`.
    static func hardStop(startedAt: Date, wakingEndMinutes: Int, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: startedAt)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startedAt.addingTimeInterval(86_400)
        let minutes = min(max(wakingEndMinutes, 0), 24 * 60 - 1)
        return calendar.date(byAdding: .minute, value: minutes, to: nextDay) ?? nextDay
    }

    /// The next time the waking window opens after `date`: tomorrow morning for an
    /// evening out, this morning for one that ran past midnight.
    static func nextWakingStart(after date: Date, wakingStartMinutes: Int, calendar: Calendar = .current) -> Date {
        let minutes = min(max(wakingStartMinutes, 0), 24 * 60 - 1)
        let startOfDay = calendar.startOfDay(for: date)
        let today = calendar.date(byAdding: .minute, value: minutes, to: startOfDay) ?? date
        if today > date { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86_400)
        return calendar.date(byAdding: .minute, value: minutes, to: tomorrow) ?? tomorrow
    }

    // MARK: - Tally

    /// What has been logged since Night Out began.
    struct Tally: Equatable {
        var drinks: Int
        var waters: Int

        /// Waters still owed, one for each drink. Never negative: extra water is not a
        /// debt in the other direction.
        var watersToGo: Int { max(0, drinks - waters) }
    }

    static func tally(of entries: [WaterEntry], since startedAt: Date) -> Tally {
        var tally = Tally(drinks: 0, waters: 0)
        for entry in entries where entry.timestamp >= startedAt {
            if entry.drinkType.isAlcoholic {
                tally.drinks += 1
            } else if entry.drinkType.countsAsWaterRound {
                tally.waters += 1
            }
        }
        return tally
    }

    /// The one line shown on Today. States what happened and what water is left to
    /// drink. It never praises a drink count and never sets one as a target.
    static func line(for tally: Tally) -> String {
        if tally.drinks == 0 && tally.waters == 0 {
            return "Night Out is on. I will nudge you about water."
        }
        let counts = "\(count(tally.drinks, "drink")), \(count(tally.waters, "water"))."
        switch tally.watersToGo {
        case 0: return "\(counts) All caught up on water."
        case 1: return "\(counts) One water to go."
        default: return "\(counts) \(spelled(tally.watersToGo).capitalized) waters to go."
        }
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private static func spelled(_ number: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return words.indices.contains(number) ? words[number] : "\(number)"
    }
}

/// The extra that can be added to today's target, and today's only.
///
/// One mechanism for every reason: a hot day, the morning after a Night Out, and a
/// workout. Accepting any of them raises today's target and nothing else. The streak
/// is still measured against the saved goal, so saying yes can never break one.
enum TodayBump {
    /// However many reasons there are in one day, the extra never passes this.
    static let dailyCapML = 1_000
    /// What the morning after a Night Out suggests.
    static let nightOutML = 500

    enum Source: String, CaseIterable {
        case heat
        case nightOut
        case workout
    }

    /// One suggestion made from every reason that has one today.
    struct Suggestion: Equatable {
        /// How much would be added on top of what has already been accepted.
        var addML: Int
        var sources: [Source]
    }

    /// Combines today's reasons into a single offer, leaving room for what has already
    /// been accepted and never offering past the cap. Nil when there is nothing to add.
    static func suggestion(from parts: [Source: Int], alreadyAcceptedML: Int) -> Suggestion? {
        let asked = Source.allCases.filter { (parts[$0] ?? 0) > 0 }
        let wanted = asked.reduce(0) { $0 + (parts[$1] ?? 0) }
        let room = max(0, dailyCapML - max(0, alreadyAcceptedML))
        let add = min(wanted, room)
        guard add > 0 else { return nil }
        return Suggestion(addML: add, sources: asked)
    }

    /// What today's accepted extra becomes after adding `addML`, never past the cap.
    static func total(alreadyAcceptedML: Int, adding addML: Int) -> Int {
        min(dailyCapML, max(0, alreadyAcceptedML) + max(0, addML))
    }
}

/// When caffeine counts as late.
enum CaffeineCutoff {
    /// Two in the afternoon.
    static let defaultMinutes = 14 * 60

    /// Whether `date` falls after the cutoff.
    ///
    /// "After" runs from the cutoff until the waking window opens again, not until
    /// midnight: a coffee at one in the morning is later than one at nine at night, not
    /// the first of a new day.
    static func isLate(
        _ date: Date,
        cutoffMinutes: Int,
        wakingStartMinutes: Int,
        calendar: Calendar = .current
    ) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if cutoffMinutes >= wakingStartMinutes {
            return minute >= cutoffMinutes || minute < wakingStartMinutes
        }
        // A cutoff set before the waking window opens: late only between the two.
        return minute >= cutoffMinutes && minute < wakingStartMinutes
    }

    /// Today's caffeine, in milligrams, from whatever was logged on `day`.
    static func totalMg(of entries: [WaterEntry], on day: Date, calendar: Calendar = .current) -> Double {
        entries
            .filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
            .reduce(0) { $0 + $1.drinkType.caffeineMg(in: $1.amountML) }
    }

    /// The most recent caffeinated drink on `day`, if it was after the cutoff.
    static func lateDrink(
        in entries: [WaterEntry],
        on day: Date,
        cutoffMinutes: Int,
        wakingStartMinutes: Int,
        calendar: Calendar = .current
    ) -> WaterEntry? {
        let latest = entries
            .filter { calendar.isDate($0.timestamp, inSameDayAs: day) && $0.drinkType.hasCaffeine }
            .max { $0.timestamp < $1.timestamp }
        guard let latest,
              isLate(latest.timestamp, cutoffMinutes: cutoffMinutes, wakingStartMinutes: wakingStartMinutes, calendar: calendar)
        else { return nil }
        return latest
    }
}
