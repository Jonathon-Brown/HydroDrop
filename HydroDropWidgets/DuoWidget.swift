#if DUO_V2
import SwiftUI
import WidgetKit

/// Reads only the snapshots already shared by the app; adding this widget never starts a
/// network request, opens a store or checks a subscription.
struct DuoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DuoCache.widgetKind, provider: DuoProvider()) { entry in
            DuoWidgetCard(model: entry.model)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Duo Streak")
        .description("You, your partner, and the streak you keep together.")
        .supportedFamilies([.systemSmall])
    }
}

struct DuoTimelineEntry: TimelineEntry {
    let date: Date
    let model: DuoWidgetModel
}

struct DuoProvider: TimelineProvider {
    func placeholder(in context: Context) -> DuoTimelineEntry {
        let now = Date()
        var statuses: [DuoDayStatus] = []
        for offset in 1...5 {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) ?? now
            for role in DuoRole.allCases {
                statuses.append(.init(role: role, day: DayKey.key(for: date), goalMet: true,
                                      progressBucket: 100, updatedAt: now))
            }
        }
        statuses.append(.init(role: .partner, day: DayKey.key(for: now), goalMet: false,
                              progressBucket: 75, updatedAt: now))
        let duo = DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "You",
                           partnerDisplayName: "Sam", ownerSkin: "classic", partnerSkin: "forest",
                           statuses: statuses, partnerHasJoined: true)
        return DuoTimelineEntry(date: now, model: .make(duos: [duo], ageStatus: .allowed, ageCheckUnavailable: false, now: now,
            snapshotDay: DayKey.key(for: now), snapshotTotalML: 1500, snapshotGoalML: 2000))
    }

    func getSnapshot(in context: Context, completion: @escaping (DuoTimelineEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DuoTimelineEntry>) -> Void) {
        let now = Date()
        // A partner's day can become stale even without another save from the app.
        completion(Timeline(entries: [current(at: now)], policy: .after(now.addingTimeInterval(3600))))
    }

    private func current(at now: Date) -> DuoTimelineEntry {
        let cache = DuoCache.live
        let duos = cache.loadDuos()
        let snapshot = WidgetBridge.currentSnapshot(now: now)
        return DuoTimelineEntry(date: now, model: .make(duos: duos, ageStatus: cache.ageStatus, ageCheckUnavailable: cache.ageCheckUnavailable, now: now,
            snapshotDay: snapshot.dayKey, snapshotTotalML: snapshot.todayTotalML,
            snapshotGoalML: snapshot.dailyGoalML))
    }
}
#endif
