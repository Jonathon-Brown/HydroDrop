import SwiftUI

/// Every mascot skin, big enough to see the charms that set them apart.
struct MascotSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @State private var paywallSource: PaywallSource?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(MascotSkin.allCases) { skin in
                        Button {
                            select(skin)
                        } label: {
                            card(for: skin)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Mascot")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
    }

    private var footer: String {
        let icon = "Your Home Screen icon changes to match."
        return store.isSubscribed ? icon : "HydroDrop+ unlocks every mascot skin. \(icon)"
    }

    private func card(for skin: MascotSkin) -> some View {
        let isSelected = settings.activeMascotSkin == skin
        let isLocked = skin.requiresPlus && !store.isSubscribed

        return VStack(spacing: 10) {
            // Only the chosen one moves: five breathing droplets at once is a lot.
            // `MascotView` decides whether to animate once, as it appears, so the
            // identity follows the selection and a newly chosen skin comes in moving.
            MascotView(progress: 1.0, size: 60, skin: skin, isAnimated: isSelected)
                .id(isSelected)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(skin.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(skin.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.tint, lineWidth: isSelected ? 2 : 0)
        }
        .overlay(alignment: .topTrailing) {
            Group {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isLocked ? Text("Shows HydroDrop+") : Text(""))
    }

    /// Locked skins send the user to the paywall rather than silently doing nothing.
    private func select(_ skin: MascotSkin) {
        if skin.requiresPlus && !store.isSubscribed {
            paywallSource = .settingsLockedSkin
        } else {
            settings.mascotSkin = skin
        }
    }
}

#Preview {
    NavigationStack { MascotSettingsView() }
        .environmentObject(AppSettings.shared)
}
