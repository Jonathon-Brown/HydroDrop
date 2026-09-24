import SwiftUI
import StoreKit

private struct PlusFeature {
    let title: String
    let icon: String

    static let all: [PlusFeature] = [
        // Every entry here must name something Plus actually unlocks. Basic streak
        // tracking is free on Home and History, so only the freeze belongs here.
        .init(title: "No ads, ever", icon: "nosign"),
        .init(title: "30-day history & trends", icon: "chart.xyaxis.line"),
        .init(title: "Apple Watch app", icon: "applewatch"),
        .init(title: "Streak freeze — protect a missed day", icon: "snowflake"),
        .init(title: "Smart, pace-aware reminders", icon: "bell.badge.fill"),
        .init(title: "Weekly recap of your hydration", icon: "calendar.badge.clock"),
        .init(title: "Hot-day nudges from the weather", icon: "thermometer.sun.fill"),
        .init(title: "Live Activity while you drink toward your goal", icon: "timer"),
        .init(title: "Lock Screen widgets at a glance", icon: "lock.fill"),
        .init(title: "Home Screen widgets at a glance", icon: "square.grid.2x2.fill"),
        .init(title: "Four more mascots, each with a matching app icon", icon: "paintpalette.fill"),
        .init(title: "Support indie development", icon: "heart.fill"),
    ]
}

/// Where the paywall was opened from. The raw values are the names `EventCounter` files
/// impressions under, so renaming a case resets its count.
enum PaywallSource: String, CaseIterable, Identifiable {
    case settingsRow = "settings-row"
    case settingsLockedReminder = "settings-locked-reminder"
    case settingsLockedSkin = "settings-locked-skin"
    case settingsLockedSmartFeature = "settings-locked-smart-feature"
    case settingsLockedBottle = "settings-locked-bottle"
    case lockedWorldDecoration = "locked-world-decoration"
    case lockedInsights = "locked-insights"
    case historyBanner = "history-banner"
    case todayEntryPoint = "today-entry-point"
    case streakBreakMessage = "streak-break-message"
    /// A subscriber's way to lifetime, from Settings. The paywall offers only that.
    case switchToLifetime = "switch-to-lifetime"

    var id: String { rawValue }
}

struct PaywallView: View {
    let source: PaywallSource

    @ObservedObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProductID: String?

    // Apple's standard EULA. If you supply your own Terms of Use, replace this
    // URL here AND in the App Store Connect metadata field.
    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://hydrodrop.us/privacy.html")!

    private var yearlyProduct: Product? {
        store.products.first { $0.id == StoreManager.PlusProductID.yearly.rawValue }
    }

    private var lifetimeProduct: Product? {
        store.products.first { $0.id == StoreManager.PlusProductID.lifetime.rawValue }
    }

    /// A subscriber who tapped Switch to Lifetime. They already have Plus, so the sheet
    /// sells only the lifetime purchase and closes once that lands.
    private var isSwitchingToLifetime: Bool { source == .switchToLifetime }

    /// The plans this sheet sells.
    private var offeredProducts: [Product] {
        guard isSwitchingToLifetime else { return store.products }
        return store.products.filter { $0.id == StoreManager.PlusProductID.lifetime.rawValue }
    }

    /// The plan picked before anyone taps a card.
    private var defaultProduct: Product? {
        isSwitchingToLifetime ? lifetimeProduct : yearlyProduct
    }

    private var selectedProduct: Product? {
        offeredProducts.first { $0.id == selectedProductID } ?? defaultProduct ?? offeredProducts.first
    }

    /// What this sheet is waiting for. For a subscriber, Plus is already on, so only
    /// lifetime arriving counts.
    private var purchaseCompleted: Bool {
        isSwitchingToLifetime ? store.hasLifetimeAccess : store.isSubscribed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    MascotView(progress: 1.15, size: 110)

                    VStack(spacing: 6) {
                        Text(isSwitchingToLifetime ? "HydroDrop+ Lifetime" : "HydroDrop+")
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(isSwitchingToLifetime
                             ? "Pay once and keep everything in HydroDrop+ for good."
                             : "Unlock deeper insights and more ways to stay on track.")
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
                        // Loaded can still leave nothing to sell here: lifetime missing
                        // from the catalog while the subscriptions came back.
                        if offeredProducts.isEmpty {
                            unavailablePlans
                        } else {
                            planPicker
                            if showsSubscriptionNote {
                                subscriptionNote
                            }
                            purchaseButton
                        }
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
            .onChange(of: purchaseCompleted) { _, completed in
                if completed { dismiss() }
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
        .onAppear {
            EventCounter.record(.paywallShown(source))
        }
        // A successful purchase or restore dismisses the sheet by flipping the entitlement,
        // so reaching here without it means the user closed it (Close or swipe).
        .onDisappear {
            if !purchaseCompleted {
                EventCounter.record(.paywallDismissedWithoutPurchase)
            }
            // Whatever this sheet was saying goes with it. Left set, an old purchase
            // error would open over Settings, or the approval notice over the next
            // paywall, long after the moment it was about.
            store.lastErrorMessage = nil
            store.pendingApprovalMessage = nil
        }
        // Ask to Buy is not a failure: the purchase is with a parent. It gets its own
        // alert, on a different view from the error alert so the two never compete,
        // rather than a title that flips while the error alert is on screen.
        .alert(
            "Waiting for approval",
            isPresented: Binding(
                get: { store.pendingApprovalMessage != nil },
                set: { if !$0 { store.pendingApprovalMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.pendingApprovalMessage = nil }
        } message: {
            Text(store.pendingApprovalMessage ?? "")
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
            ForEach(offeredProducts, id: \.id) { product in
                planCard(for: product)
            }
        }
    }

    /// Lifetime is about to be bought by someone who also has a subscription: an active
    /// one, or one in billing retry that has dropped out of the active list but can
    /// still charge.
    private var showsSubscriptionNote: Bool {
        selectedProduct?.id == StoreManager.PlusProductID.lifetime.rawValue
            && (store.hasActiveSubscription || store.subscriptionWillRenew)
    }

    /// Buying lifetime can't cancel a subscription; only the subscriber can, in their
    /// Apple Account. Nor does it refund one. Both are said before they pay, not
    /// discovered on the next bill.
    private var subscriptionNote: some View {
        Label {
            Text(store.subscriptionWillRenew
                 ? "Lifetime doesn't cancel your subscription. After you buy it, go to Settings in HydroDrop and tap Manage Subscription to cancel, so you aren't charged again. Buying Lifetime doesn't refund time you've already paid for."
                 : "Your subscription is already set to end, so there's nothing to cancel. Buying Lifetime doesn't refund time you've already paid for.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func planCard(for product: Product) -> some View {
        let isYearly = product.id == StoreManager.PlusProductID.yearly.rawValue
        let isLifetime = product.id == StoreManager.PlusProductID.lifetime.rawValue
        // Matches what the button will buy, including the default before any tap.
        let isSelected = selectedProduct?.id == product.id

        return Button {
            selectedProductID = product.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if isYearly {
                    planBadge("BEST VALUE", color: .orange)
                } else if isLifetime {
                    planBadge("PAY ONCE", color: .blue)
                }
                // Three cards share a 375pt-wide screen, so text shrinks rather than wraps.
                Text(isLifetime ? "Lifetime" : (isYearly ? "Yearly" : "Monthly"))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(product.displayPrice)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(isLifetime ? "once" : (isYearly ? "per year" : "per month"))
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

    private func planBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
    }

    /// Shown when the fetch resolved but there's nothing purchasable to show. The sheet stays
    /// usable — Restore Purchases and Close are still right below — instead of trapping the
    /// user behind a spinner.
    private var unavailablePlans: some View {
        VStack(spacing: 10) {
            Image(systemName: store.productLoadState == .loaded ? "exclamationmark.circle" : "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(isSwitchingToLifetime ? "Lifetime isn't available right now" : "Subscription options unavailable")
                .font(.subheadline.weight(.semibold))
            // The catalog loaded but left lifetime out: not a connection problem, so
            // don't send them to check one.
            Text(store.productLoadState == .loaded
                 ? "It can't be bought at the moment. Your subscription isn't affected."
                 : "We couldn't load HydroDrop+ plans right now. Check your connection and try again.")
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
        if selectedProductID == nil { selectedProductID = defaultProduct?.id }
    }

    private var purchaseButtonLabel: String {
        guard let selectedProduct else { return "Subscribe" }
        let verb = selectedProduct.id == StoreManager.PlusProductID.lifetime.rawValue
            ? "Get Lifetime Access" : "Subscribe"
        return "\(verb) — \(selectedProduct.displayPrice)"
    }

    private var purchaseButton: some View {
        Button {
            guard let product = selectedProduct else { return }
            EventCounter.record(.purchaseAttempted)
            Task {
                switch await store.purchase(product) {
                case .succeeded: EventCounter.record(.purchaseSucceeded)
                case .pending: EventCounter.record(.purchasePending)
                case .cancelled: EventCounter.record(.purchaseCancelled)
                case .failed: EventCounter.record(.purchaseFailed)
                }
            }
        } label: {
            if store.purchaseInProgress {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                Text(purchaseButtonLabel)
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
    PaywallView(source: .settingsRow)
}
