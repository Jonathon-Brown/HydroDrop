import SwiftUI

/// One duo: two droplets side by side, and the streak they are keeping together.
///
/// Each droplet wears its owner's skin and the mood of their progress, which is all a
/// partner ever learns about the day: a face, and whether the goal was met.
struct DuoCard: View {
    @ObservedObject var duoStore: DuoStore
    let duo: DuoState
    /// Off inside a list, where the row is already the card.
    var showsBackground = true

    private var streak: Int { duoStore.streak(of: duo) }

    var body: some View {
        VStack(spacing: 10) {
            if duo.hasEnded {
                ended
            } else {
                HStack(alignment: .top, spacing: 8) {
                    side(duo.myRole, name: "You")
                    flame
                    side(duo.myRole.other, name: duo.displayName(of: duo.myRole.other))
                        .opacity(duo.isPending ? 0.35 : 1)
                }
                if duo.isPending {
                    Text("Waiting for your partner to accept the invite.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(showsBackground ? 16 : 4)
        .frame(maxWidth: .infinity)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private func side(_ role: DuoRole, name: String) -> some View {
        let status = duoStore.status(of: role, in: duo)
        return VStack(spacing: 2) {
            MascotView(
                progress: DuoProgress.fraction(forBucket: status?.progressBucket ?? 0),
                size: 56,
                skin: MascotSkin(rawValue: duo.skinRawValue(of: role)) ?? .classic,
                isAnimated: false
            )
            Text(name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Text(statusLine(for: role, status))
                .font(.caption2)
                .foregroundStyle(status?.goalMet == true ? Color.green : .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusLine(for role: DuoRole, _ status: DuoDayStatus?) -> String {
        if duo.isPending, role != duo.myRole { return "Not here yet" }
        return DuoProgress.line(for: status)
    }

    private var flame: some View {
        VStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(streak > 0 ? .orange : .secondary)
            Text("\(streak)")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(streak == 1 ? "day together" : "days together")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 18)
        .frame(minWidth: 72)
    }

    private var ended: some View {
        VStack(spacing: 6) {
            Image(systemName: "flame")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Your duo ended")
                .font(.subheadline.weight(.semibold))
            Text(duo.myRole == .owner
                 ? "\(duo.displayName(of: .partner)) left this duo."
                 : "\(duo.displayName(of: .owner)) ended this duo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var spokenSummary: String {
        let partner = duo.displayName(of: duo.myRole.other)
        if duo.hasEnded { return "Your duo with \(partner) ended." }
        if duo.isPending { return "Duo streak. Waiting for your partner to accept the invite." }
        let mine = DuoProgress.line(for: duoStore.status(of: duo.myRole, in: duo))
        let theirs = DuoProgress.line(for: duoStore.status(of: duo.myRole.other, in: duo))
        return "Duo streak with \(partner). \(streak) \(streak == 1 ? "day" : "days") together. You: \(mine). \(partner): \(theirs)."
    }
}

/// The duo cards on Today. One card sits as it is. More than one page sideways, a
/// card to a page, with dots underneath to say so.
struct DuoCardsSection: View {
    @ObservedObject var duoStore: DuoStore
    @State private var page: UUID?

    var body: some View {
        let duos = duoStore.duos
        if duos.count == 1, let duo = duos.first {
            link(to: duo)
        } else if duos.count > 1 {
            VStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(duos) { duo in
                            link(to: duo)
                                .containerRelativeFrame(.horizontal)
                                .id(duo.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $page)

                HStack(spacing: 6) {
                    ForEach(duos) { duo in
                        Circle()
                            .fill(duo.id == (page ?? duos.first?.id) ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func link(to duo: DuoState) -> some View {
        NavigationLink {
            DuoView()
        } label: {
            DuoCard(duoStore: duoStore, duo: duo)
        }
        .buttonStyle(.plain)
    }
}
