import SwiftUI
import StoreKit

private struct PlusFeature {
    let title: String
    let icon: String

    static let all: [PlusFeature] = [
        // Every entry here must name something Plus actually unlocks. Basic streak
        // tracking is free on Home and History, so only the freeze belongs here.
        .init(title: "30-day history & trends", icon: "chart.xyaxis.line"),
        .init(title: "Apple Watch app", icon: "applewatch"),
        .init(title: "Streak freeze — protect a missed day", icon: "snowflake"),
        .init(title: "Smart, pace-aware reminders", icon: "bell.badge.fill"),
        .init(title: "Four more mascots, each with its own charm", icon: "paintpalette.fill"),
        .init(title: "Support indie development", icon: "heart.fill"),
    ]
}

struct PaywallView: View {
    @ObservedObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProductID: String?

    private var yearlyProduct: Product? {
        store.products.first { $0.id == StoreManager.PlusProductID.yearly.rawValue }
    }

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID } ?? yearlyProduct ?? store.products.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    MascotView(progress: 1.15, size: 110)

                    VStack(spacing: 6) {
                        Text("HydroDrop+")
                            .font(.largeTitle.weight(.bold))
                        Text("Unlock deeper insights and more ways to stay on track.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    skinLineup

                    featureList

                    if store.products.isEmpty {
                        ProgressView()
                            .padding(.vertical, 20)
                    } else {
                        planPicker
                        purchaseButton
                    }

                    Button("Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.footnote)

                    Text("Payment charged to your Apple ID. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if store.products.isEmpty { await store.loadProducts() }
                if selectedProductID == nil { selectedProductID = yearlyProduct?.id }
            }
            .onChange(of: store.isSubscribed) { _, subscribed in
                if subscribed { dismiss() }
            }
            .alert("Something went wrong", isPresented: .constant(store.lastErrorMessage != nil)) {
                Button("OK") { store.lastErrorMessage = nil }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
        }
    }

    /// The four locked mascots, shown rather than described. Held still so a row of
    /// four doesn't turn the top of the paywall into a fidget.
    private var skinLineup: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(MascotSkin.allCases.filter(\.requiresPlus)) { skin in
                    VStack(spacing: 2) {
                        MascotView(progress: 1.1, size: 52, skin: skin, isAnimated: false)
                            .accessibilityHidden(true)
                        Text(skin.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        // Generous, because the charms reach past the mascot's own frame — Forest's
        // sprout in particular would otherwise graze the top of the card.
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(PlusFeature.all, id: \.title) { feature in
                Label(feature.title, systemImage: feature.icon)
                    .font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var planPicker: some View {
        HStack(spacing: 12) {
            ForEach(store.products, id: \.id) { product in
                planCard(for: product)
            }
        }
    }

    private func planCard(for product: Product) -> some View {
        let isYearly = product.id == StoreManager.PlusProductID.yearly.rawValue
        let isSelected = selectedProductID == product.id

        return Button {
            selectedProductID = product.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if isYearly {
                    Text("BEST VALUE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                }
                Text(isYearly ? "Yearly" : "Monthly")
                    .font(.headline)
                Text(product.displayPrice)
                    .font(.title2.weight(.bold))
                Text(isYearly ? "per year" : "per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.blue.opacity(0.12) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.blue : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var purchaseButton: some View {
        Button {
            guard let product = selectedProduct else { return }
            Task { await store.purchase(product) }
        } label: {
            if store.purchaseInProgress {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                Text(selectedProduct.map { "Subscribe — \($0.displayPrice)" } ?? "Subscribe")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedProduct == nil || store.purchaseInProgress)
    }
}

#Preview {
    PaywallView()
}
