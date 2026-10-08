import Foundation

// Small questions the Duo screen and the card ask of a duo, answered in one place so the
// screen, the card and the tests agree (final design §3.5, §11.8, §14).

public extension DuoState {
    /// "Not them? Leave & block" is shown to the person who sent the invite for 24 hours
    /// from the second person's `joined_at`, which is the server's clock, so a wrong clock on
    /// this phone cannot hide it (§4.3, §11.8).
    func showsNotThemCard(now: Date) -> Bool {
        guard myRole == .owner, !hasEnded, let joinedAt else { return false }
        return now >= joinedAt && now.timeIntervalSince(joinedAt) < DuoProtocolConstants.notThemWindow
    }

    /// The day the partner's phone last wrote, when that was more than three days before
    /// `myToday`: what the card's "Not seen since <day>" line says, and the threshold at which
    /// "Reconnect <name>'s new phone" is offered (§3.5). Nil while the partner is recent, for
    /// a pending or ended duo, and for the App Review sample partner.
    func partnerSilentSince(myToday: String) -> String? {
        guard !hasEnded, partnerHasJoined, !partnerIsDemo, let last = partnerLastWriteDay,
              DuoStreak.isDayKey(last), DuoStreak.isDayKey(myToday) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let today = DayKey.date(from: myToday, calendar: calendar),
              let cutoff = calendar.date(byAdding: .day, value: -DuoProtocolConstants.reconnectSilentDays, to: today) else { return nil }
        return last < DayKey.key(for: cutoff, calendar: calendar) ? last : nil
    }

    /// Whether the card offers "Reconnect <name>'s new phone".
    func offersReconnect(myToday: String) -> Bool {
        partnerSilentSince(myToday: myToday) != nil
    }

    /// An ended duo can be cleared from the screen; a live one has to be left first.
    var canBeCleared: Bool { hasEnded }
}
