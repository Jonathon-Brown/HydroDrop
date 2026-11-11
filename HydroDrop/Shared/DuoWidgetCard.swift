#if DUO_V2
import SwiftUI

/// Shared with the app test host so all widget states can be inspected at the actual small
/// widget size. The model decides what may be shown; the card only lays it out.
struct DuoWidgetCard: View {
    let model: DuoWidgetModel

    var body: some View {
        Group {
            if model.state == .empty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.title2).foregroundStyle(.blue)
                    Text("No duo yet").font(.caption.weight(.bold))
                    Text("Start one in HydroDrop, under Settings.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            } else {
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 2) {
                        droplet(bucket: model.myBucket, skin: model.mySkin)
                        droplet(bucket: model.partnerBucket, skin: model.partnerSkin)
                            .opacity(model.state == .pending ? 0.35 : 1)
                    }.frame(height: 70)
                    Label(model.streakText, systemImage: "flame.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(model.streakDays > 0 ? .orange : .secondary)
                    Text(verbatim: model.partnerLine)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    if let badge = model.sampleBadge {
                        Text(verbatim: badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        // A small widget has a fixed canvas. Keep the standard text size so a
        // larger accessibility setting cannot push the Sample badge or streak off-screen;
        // VoiceOver still receives the complete label below, including an untruncated name.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.accessibilityLabel))
    }

    private func droplet(bucket: Int, skin: String) -> some View {
        MascotView(progress: DuoProgress.fraction(forBucket: bucket), size: 44,
                   skin: MascotSkin(rawValue: skin) ?? .classic, isAnimated: false)
            .frame(width: 62, height: 66)
    }
}
#endif
