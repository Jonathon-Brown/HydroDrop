import Foundation
import StoreKit
#if DEBUG
import os
#endif

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    enum PlusProductID: String, CaseIterable {
        case monthly = "com.jonathonbrown.HydroDrop.plus.monthly"
        case yearly = "com.jonathonbrown.HydroDrop.plus.yearly"
        case lifetime = "com.jonathonbrown.HydroDrop.plus.lifetime"
    }

    /// Outcome of the most recent product fetch. `unavailable` is distinct from `failed`:
    /// StoreKit returns an empty array *without* throwing when products aren't purchasable
    /// (still in review, agreements not in effect, storefront mismatch), and the paywall must
    /// surface that as a resolved state rather than spinning forever.
    enum ProductLoadState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
        case failed(String)
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var productLoadState: ProductLoadState = .idle
    /// True whenever any entitlement grants Plus: the lifetime purchase, an active
    /// subscription, or both. Every Plus gate reads this.
    ///
    /// Seeded from the last known entitlement so a paying user isn't shown the locked
    /// app during the launch-time round trip. Corrected by `refreshEntitlement()` moments
    /// later either way.
    @Published private(set) var isSubscribed = EntitlementCache.isPlusActive
    /// Tracked apart from `hasLifetimeAccess` because someone can hold both, and then
    /// needs Manage Subscription to stop paying for a subscription they no longer need.
    /// Both stay false until the first `refreshEntitlement()`, so `isSubscribed` with
    /// neither set means "entitled, details not read yet".
    @Published private(set) var hasActiveSubscription = false
    @Published private(set) var hasLifetimeAccess = false
    /// Whether a HydroDrop+ subscription is still set to charge again. Not the same as
    /// `hasActiveSubscription`: a cancelled subscription stays active until its period
    /// ends, and one in billing retry has already dropped out of the active list while
    /// it can still charge once the payment goes through.
    @Published private(set) var subscriptionWillRenew = false
    @Published private(set) var purchaseInProgress = false
    @Published var lastErrorMessage: String?

    #if DEBUG
    /// Why the most recent load produced no plans. Surfaced on the paywall in DEBUG builds.
    @Published private(set) var diagnostic: String?
    #endif

    private static let productFetchTimeout: Duration = .seconds(15)

    private var transactionListener: Task<Void, Never>?
    private var statusListener: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    /// False until the App Store has answered for the current subscription state. Until
    /// then `subscriptionWillRenew` follows `hasActiveSubscription`, which keeps the way
    /// out on screen rather than hiding it on a guess.
    private var hasReadRenewalState = false
    /// Bumped by every renewal read, so a slow read that started earlier can't overwrite
    /// the answer of one that started later.
    private var renewalReadGeneration = 0

    private init() {
        transactionListener = listenForTransactionUpdates()
        #if os(iOS)
        // The watch reads only `isSubscribed`, so it skips renewal tracking and the App
        // Store round trips that come with it.
        statusListener = listenForSubscriptionStatusUpdates()
        #endif
        Task {
            // Entitlement first. Behind the product fetch it inherited that fetch's
            // 15-second timeout, which is how long the Watch app used to show its
            // "subscribe on your iPhone" screen to people who already had.
            await refreshEntitlement()
            await loadProducts()
        }
    }

    deinit {
        transactionListener?.cancel()
        statusListener?.cancel()
        renewalTask?.cancel()
    }

    /// Coalesces concurrent callers onto a single in-flight fetch, so the paywall appearing
    /// while the launch-time load is still running waits for that result instead of racing it.
    func loadProducts() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        productLoadState = .loading
        let ids = PlusProductID.allCases.map(\.rawValue)
        do {
            let fetched = try await fetchProducts(ids: ids).sorted {
                (ids.firstIndex(of: $0.id) ?? 0) < (ids.firstIndex(of: $1.id) ?? 0)
            }
            products = fetched
            productLoadState = fetched.isEmpty ? .unavailable : .loaded
            await recordDiagnostic(requested: ids, fetched: fetched, error: nil)
        } catch {
            products = []
            productLoadState = .failed(error.localizedDescription)
            await recordDiagnostic(requested: ids, fetched: [], error: error)
        }
    }

    /// The paywall shows one message for both `.unavailable` and `.failed`, which is right
    /// for users and useless for debugging — an empty result and a thrown error look
    /// identical on screen. This records what actually happened. DEBUG only.
    private func recordDiagnostic(requested: [String], fetched: [Product], error: Error?) async {
        #if DEBUG
        var parts = ["got \(fetched.count)/\(requested.count)"]
        // Storefront tells you which country's catalog answered; a product priced only in
        // other regions comes back missing rather than as an error.
        parts.append("storefront=\(await Storefront.current?.countryCode ?? "nil")")
        parts.append("bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        if let error {
            let ns = error as NSError
            parts.append("threw \(type(of: error)) \(ns.domain)#\(ns.code): \(error.localizedDescription)")
        } else if fetched.isEmpty {
            parts.append("empty, nothing thrown — StoreKit resolved the request and considers these IDs not purchasable here")
        }
        let text = parts.joined(separator: " · ")
        diagnostic = text
        Logger(subsystem: "com.jonathonbrown.HydroDrop", category: "skdiag")
            .notice("[SKDIAG] \(text, privacy: .public)")
        #endif
    }

    /// StoreKit has no built-in deadline, so race the fetch against one to guarantee the
    /// paywall always leaves its loading state even on a stalled network.
    private func fetchProducts(ids: [String]) async throws -> [Product] {
        try await withThrowingTaskGroup(of: [Product].self) { group in
            group.addTask { try await Product.products(for: ids) }
            group.addTask {
                try await Task.sleep(for: Self.productFetchTimeout)
                throw StoreError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return [] }
            return first
        }
    }

    enum PurchaseOutcome {
        case succeeded
        case pending
        case cancelled
        case failed
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlement()
                return .succeeded
            case .pending:
                // Ask to Buy and other deferred approvals resolve later through
                // `Transaction.updates`. Without a word here the button simply stops.
                // Someone who already has Plus can only be buying lifetime here.
                lastErrorMessage = "This purchase needs approval before it can finish. "
                    + (isSubscribed
                       ? "Lifetime is added as soon as it's approved."
                       : "HydroDrop+ unlocks as soon as it's approved.")
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Debug-only hook so screenshot automation can show the unlocked UI without a real
    /// purchase. Compiled out of Release so shipping builds cannot be launched into an
    /// entitled state.
    private static var isScreenshotModeForcingSubscription: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestForceSubscribed")
        #else
        false
        #endif
    }

    private func refreshEntitlement() async {
        if Self.isScreenshotModeForcingSubscription {
            // Seed the cache too, or the forced entitlement disagrees with everything
            // that gates on `EntitlementCache` — skins, smart reminders, the app icon.
            // Lifetime and subscription stay unset, so Settings shows the plain
            // "HydroDrop+ is active" row it always has in screenshots.
            isSubscribed = true
            EntitlementCache.isPlusActive = true
            return
        }
        // Read every entitlement rather than stopping at lifetime: a subscription held
        // alongside it may still renew, and Settings has to know to offer the way out.
        var ownedProductIDs: [String] = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.revocationDate == nil {
                ownedProductIDs.append(transaction.productID)
            }
        }
        let entitlements = PlusEntitlements(productIDs: ownedProductIDs)
        // A subscription starting or ending makes the last renewal answer stale.
        if entitlements.hasActiveSubscription != hasActiveSubscription { hasReadRenewalState = false }
        hasLifetimeAccess = entitlements.hasLifetime
        hasActiveSubscription = entitlements.hasActiveSubscription
        isSubscribed = entitlements.grantsPlus
        EntitlementCache.isPlusActive = entitlements.grantsPlus
        if !hasReadRenewalState { subscriptionWillRenew = entitlements.hasActiveSubscription }
        #if os(iOS)
        // Not awaited: it may need the App Store, and nothing that waits on entitlements
        // (the launch-time product fetch, a purchase finishing) should wait on it too.
        renewalTask?.cancel()
        renewalTask = Task { await refreshRenewalState() }
        #endif
    }

    /// Re-reads whether a subscription will charge again. Runs after every entitlement
    /// refresh, when the App Store reports a status change, when Settings appears, and
    /// when Manage Subscription closes, since turning auto-renew off creates no
    /// transaction to hear about.
    func refreshRenewalState() async {
        renewalReadGeneration += 1
        let generation = renewalReadGeneration
        let willRenew = await readSubscriptionWillRenew()
        // A read started since this one owns the answer, whichever finishes first.
        guard generation == renewalReadGeneration, !Task.isCancelled else { return }
        if let willRenew {
            subscriptionWillRenew = willRenew
            hasReadRenewalState = true
        } else if !hasReadRenewalState {
            subscriptionWillRenew = hasActiveSubscription
        }
    }

    /// Nil when the App Store can't be asked. False when there's no subscription to ask
    /// about, which also keeps the network out of it for anyone who never subscribed.
    private func readSubscriptionWillRenew() async -> Bool? {
        // The group comes from the subscriber's own transaction, so the same code works
        // against the App Store and the local StoreKit configuration, whose ids differ.
        var groupID: String?
        for product in [PlusProductID.monthly, .yearly] {
            if let result = await Transaction.latest(for: product.rawValue),
               let transaction = try? checkVerified(result),
               let id = transaction.subscriptionGroupID {
                groupID = id
                break
            }
        }
        guard let groupID else { return false }
        guard let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else { return nil }
        return SubscriptionRenewal.willCharge(statuses.compactMap { status in
            guard let renewal = try? checkVerified(status.renewalInfo) else { return nil }
            return SubscriptionRenewal.Snapshot(state: status.state, willAutoRenew: renewal.willAutoRenew)
        })
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, let transaction = try? self.checkVerified(result) else { continue }
                await transaction.finish()
                await self.refreshEntitlement()
            }
        }
    }

    /// Renewal changes such as auto-renew being turned off, or billing retry starting or
    /// ending, arrive here rather than through `Transaction.updates`.
    private func listenForSubscriptionStatusUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in Product.SubscriptionInfo.Status.updates {
                guard let self else { return }
                await self.refreshRenewalState()
            }
        }
    }

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    enum StoreError: LocalizedError {
        case failedVerification
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failedVerification: return "Could not verify this purchase."
            case .timedOut: return "The App Store took too long to respond."
            }
        }
    }
}

/// What a set of verified, unrevoked entitlements adds up to.
///
/// Kept apart from StoreKit so the rules can be tested without a transaction: lifetime
/// and a subscription are counted independently, because a lifetime owner can still
/// have a subscription renewing, and products that aren't HydroDrop+ count for nothing.
struct PlusEntitlements: Equatable {
    private(set) var hasLifetime = false
    private(set) var hasActiveSubscription = false

    var grantsPlus: Bool { hasLifetime || hasActiveSubscription }

    init<IDs: Sequence>(productIDs: IDs) where IDs.Element == String {
        for id in productIDs {
            switch StoreManager.PlusProductID(rawValue: id) {
            case .lifetime: hasLifetime = true
            case .monthly, .yearly: hasActiveSubscription = true
            case nil: continue
            }
        }
    }
}

/// Whether a subscription group's statuses mean the subscriber can still be charged.
enum SubscriptionRenewal {
    struct Snapshot: Equatable {
        let state: Product.SubscriptionInfo.RenewalState
        let willAutoRenew: Bool
    }

    /// Renewing normally, in a grace period, or in billing retry, with auto-renew still
    /// on. Billing retry counts: the payment can still go through and charge.
    static func willCharge(_ snapshots: [Snapshot]) -> Bool {
        let chargeable: [Product.SubscriptionInfo.RenewalState] = [.subscribed, .inGracePeriod, .inBillingRetryPeriod]
        return snapshots.contains { $0.willAutoRenew && chargeable.contains($0.state) }
    }
}
