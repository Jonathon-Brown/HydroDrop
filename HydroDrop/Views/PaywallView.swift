import SwiftUI
import StoreKit

private struct PlusFeature {
    let title: String
    let icon: String

    /// Only features that actually ship in this binary. Advertising anything
    /// else (streak freeze, iCloud sync, custom skins) is a 2.3.1 risk.
    static let all: [PlusFeature] = [
        .init(title: "30-day history & trends", icon: "chart.xyaxis.line"),
        .init(title: "Daily streak tracking", icon: "flame.fill"),
        .init(title: "Streak freeze — protect a missed day", icon: "shield.fill"),
        .init(title: "iCloud sync across devices", icon: "icloud.fill"),
        .init(title: "Support indie development", icon: "heart.fill"),
    ]
}

struct PaywallView: View {
    @ObservedObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProductID: String?

    // Apple's standard EULA. If you supply your own Terms of Use, replace this
    // URL here AND in the App Store Connect metadata field.
    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://jonathon-brown.github.io/HydroDrop/privacy.html")!

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
                    MascotView(progress: 1.15, size: 120)

                    VStack(spacing: 6) {
                        Text("HydroDrop+")
                            .font(.largeTitle.weight(.bold))
                        Text("Unlock deeper insights and more ways to stay on track.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    featureList

                    purchaseSection

                    Button("Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.footnote)

                    // Rendered unconditionally, outside every load-state branch,
                    // so App Review always sees the required links.
                    legalFooter
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if !store.loadState.isLoaded { await store.loadProducts() }
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

    @ViewBuilder
    private var purchaseSection: some View {
        switch store.loadState {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading subscription options…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)

        case .loaded:
            VStack(spacing: 24) {
                planPicker
                purchaseButton
            }

        case .failed(let message):
            unavailableState(message: message)
        }
    }

    private func unavailableState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Subscriptions unavailable")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await store.loadProducts() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var legalFooter: some View {
        VStack(spacing: 12) {
            Text("Payment charged to your Apple ID. Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Link("Terms of Use", destination: Self.termsURL)
                Text("·")
                    .foregroundStyle(.secondary)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.footnote)
        }
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
