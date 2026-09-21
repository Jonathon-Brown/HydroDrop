import SwiftUI
import WidgetKit

/// The duo widget: two droplets and the streak they are keeping together.
///
/// Drawn entirely from what the app has already put in the App Group: the duo cache and
/// the hydration snapshot. It opens no store and talks to no network. Follows the same
/// rule as every other HydroDrop widget: part of HydroDrop+, and says so when locked.
struct DuoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DuoCache.widgetKind, provider: DuoProvider()) { entry in
            DuoWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Duo Streak")
        .description("You, your partner, and the streak you keep together. Included with HydroDrop+.")
        .supportedFamilies([.systemSmall])
    }
}

struct DuoTimelineEntry: TimelineEntry {
    let date: Date
    /// The first duo that is under way, if there is one.
    let duo: DuoState?
    let snapshot: HydrationSnapshot
}

struct DuoProvider: TimelineProvider {
    func placeholder(in context: Context) -> DuoTimelineEntry {
        DuoTimelineEntry(date: Date(), duo: Self.sample, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DuoTimelineEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DuoTimelineEntry>) -> Void) {
        let now = Date()
        // The app reloads this whenever the cache changes. What moves with nobody
        // touching anything is the clock: a partner's day goes stale, and a day ends. An
        // hourly look is enough for both and well inside a widget's budget.
        completion(Timeline(entries: [current(at: now)], policy: .after(now.addingTimeInterval(60 * 60))))
    }

    private func current(at now: Date) -> DuoTimelineEntry {
        let duos = DuoCache.load().filter { !$0.hasEnded }
        // One that has a partner in it first; an invite still waiting is better than nothing.
        let duo = duos.first { !$0.isPending } ?? duos.first
        return DuoTimelineEntry(date: now, duo: duo, snapshot: WidgetBridge.currentSnapshot(now: now))
    }

    /// For the widget gallery, which should show what a duo looks like rather than the
    /// empty state.
    private static let sample: DuoState = {
        let now = Date()
        let id = UUID()
        let calendar = Calendar.current
        var statuses: [DuoDayStatus] = []
        for offset in 1...5 {
            let day = DayKey.key(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
            for role in DuoRole.allCases {
                statuses.append(DuoDayStatus(role: role, day: day, goalMet: true, progressBucket: 100, updatedAt: now))
            }
        }
        statuses.append(DuoDayStatus(role: .partner, day: DayKey.key(for: now), goalMet: false, progressBucket: 75, updatedAt: now))
        return DuoState(
            id: id,
            zoneName: DuoRecordName.zoneName(for: id),
            zoneOwnerName: "",
            myRole: .owner,
            createdAt: now,
            ownerDisplayName: "You",
            partnerDisplayName: "Sam",
            ownerSkin: MascotSkin.classic.rawValue,
            partnerSkin: MascotSkin.forest.rawValue,
            statuses: statuses,
            shareURL: nil,
            partnerHasJoined: true,
            endedAt: nil
        )
    }()
}

struct DuoWidgetView: View {
    let entry: DuoTimelineEntry

    var body: some View {
        if !entry.snapshot.isPlusActive {
            locked
        } else if let duo = entry.duo {
            card(for: duo)
        } else {
            empty
        }
    }

    // MARK: A duo

    private func card(for duo: DuoState) -> some View {
        let today = DayKey.key(for: entry.date)
        let streak = DuoStreak.current(statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: entry.date)
        let partner = duo.myRole.other
        let theirs = DuoStreak.currentStatus(of: partner, statuses: duo.statuses, myRole: duo.myRole, myToday: today, now: entry.date)

        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                droplet(bucket: myBucket(in: duo, today: today), skin: duo.skinRawValue(of: duo.myRole))
                droplet(bucket: theirs?.progressBucket ?? 0, skin: duo.skinRawValue(of: partner))
                    .opacity(duo.isPending ? 0.35 : 1)
            }
            .frame(height: 70)

            Label("\(streak)", systemImage: "flame.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(streak > 0 ? .orange : .secondary)

            Text(duo.isPending ? "Waiting for your partner" : "with \(duo.displayName(of: partner))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(duo.isPending
            ? "Duo streak. Waiting for your partner to accept the invite."
            : "Duo streak with \(duo.displayName(of: partner)). \(streak) \(streak == 1 ? "day" : "days") together. \(duo.displayName(of: partner)): \(DuoProgress.line(for: theirs)).")
    }

    /// My side comes from the hydration snapshot when it is about today, so a drink
    /// logged from another widget shows here at once. The snapshot measures against
    /// today's target, which on a day with accepted extra water is a little more than
    /// the saved goal a duo is judged by. Only the face can differ, and only by a mood.
    private func myBucket(in duo: DuoState, today: String) -> Int {
        if entry.snapshot.dayKey == today {
            return DuoProgress.bucket(totalML: entry.snapshot.todayTotalML, goalML: entry.snapshot.dailyGoalML)
        }
        return duo.status(of: duo.myRole, on: today)?.progressBucket ?? 0
    }

    private func droplet(bucket: Int, skin: String) -> some View {
        MascotView(
            progress: DuoProgress.fraction(forBucket: bucket),
            size: 44,
            skin: MascotSkin(rawValue: skin) ?? .classic,
            isAnimated: false
        )
        .frame(width: 62, height: 66)
    }

    // MARK: No duo yet

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("No duo yet")
                .font(.caption.weight(.bold))
            Text("Start one in HydroDrop, under Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Locked

    /// The same thing every HydroDrop widget shows a non-subscriber.
    private var locked: some View {
        VStack(spacing: 6) {
            MascotView(progress: 0.5, size: 46, skin: .classic, isAnimated: false)
                .frame(height: 62)
            Label("HydroDrop+", systemImage: "lock.fill")
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Text("Open the app to unlock widgets.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("HydroDrop widgets are part of HydroDrop+. Open the app to upgrade.")
    }
}
