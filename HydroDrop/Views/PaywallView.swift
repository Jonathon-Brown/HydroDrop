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

                    switch store.productLoadState {
                    case .idle, .loading:
                        ProgressView()
                            .padding(.vertical, 20)
                    case .loaded:
                        planPicker
                        purchaseButton
                    case .unavailable, .failed:
                        unavailablePlans
                    }

                    Button("Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.footnote)

                    // Rendered unconditionally, outside every load-state branch, so App
                    // Review sees the Terms of Use and Privacy Policy links (3.1.2(c))
                    // even when the product fetch comes back empty.
                    legalFooter
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // The paywall draws its own large "HydroDrop+" title inside the scroll view, so
            // the navigation bar has no title and stays transparent — which lets that title
            // scroll up underneath the Close button and collide with it. Pinning the bar
            // background keeps Close legible against whatever is passing behind it.
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                if store.productLoadState != .loaded { await loadPlans() }
            }
            .onChange(of: store.isSubscribed) { _, subscribed in
                if subscribed { dismiss() }
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { store.lastErrorMessage != nil },
                    set: { if !$0 { store.lastErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { store.lastErrorMessage = nil }
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

    /// Shown when the fetch resolved but there's nothing purchasable to show. The sheet stays
    /// usable — Restore Purchases and Close are still right below — instead of trapping the
    /// user behind a spinner.
    private var unavailablePlans: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Subscription options unavailable")
                .font(.subheadline.weight(.semibold))
            Text("We couldn't load HydroDrop+ plans right now. Check your connection and try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if DEBUG
            if let diagnostic = store.diagnostic {
                Text(diagnostic)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall-diagnostic")
            }
            #endif
            Button("Try Again") {
                Task { await loadPlans() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func loadPlans() async {
        await store.loadProducts()
        if selectedProductID == nil { selectedProductID = yearlyProduct?.id }
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
