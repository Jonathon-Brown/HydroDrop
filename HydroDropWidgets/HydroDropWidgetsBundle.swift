import SwiftUI
import WidgetKit

@main
struct HydroDropWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HydrationWidget()
        HydrationAccessoryWidget()
    }
}

/// Feeds every HydroDrop widget from the snapshot the app publishes.
///
/// No store is opened here. A timeline render happens often and under a tight memory
/// budget, and the snapshot already holds everything these views draw.
struct HydrationProvider: TimelineProvider {
    func placeholder(in context: Context) -> HydrationTimelineEntry {
        HydrationTimelineEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (HydrationTimelineEntry) -> Void) {
        // The gallery preview gets something worth looking at rather than an empty day.
        let snapshot = context.isPreview ? HydrationSnapshot.placeholder : WidgetBridge.currentSnapshot()
        completion(HydrationTimelineEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HydrationTimelineEntry>) -> Void) {
        let now = Date()
        let entry = HydrationTimelineEntry(date: now, snapshot: WidgetBridge.currentSnapshot(now: now))
        // Progress only moves when a drink is logged, and every path that logs one
        // reloads the timeline itself. The only thing that changes on its own is the
        // date, so the next scheduled reload is the one that empties the day.
        let tomorrow = Calendar.current.startOfDay(for: now.addingTimeInterval(24 * 60 * 60))
        completion(Timeline(entries: [entry], policy: .after(tomorrow)))
    }
}

struct HydrationTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: HydrationSnapshot
}
