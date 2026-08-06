import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    enum PlusProductID: String, CaseIterable {
        case monthly = "com.jonathonbrown.HydroDrop.plus.monthly"
        case yearly = "com.jonathonbrown.HydroDrop.plus.yearly"
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
    @Published private(set) var isSubscribed = false
    @Published private(set) var purchaseInProgress = false
    @Published var lastErrorMessage: String?

    private static let productFetchTimeout: Duration = .seconds(15)

    private var transactionListener: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private init() {
        transactionListener = listenForTransactionUpdates()
        Task {
            await loadProducts()
            await refreshEntitlement()
        }
    }

    deinit {
        transactionListener?.cancel()
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
        do {
            let ids = PlusProductID.allCases.map(\.rawValue)
            let fetched = try await fetchProducts(ids: ids).sorted { $0.price < $1.price }
            products = fetched
            productLoadState = fetched.isEmpty ? .unavailable : .loaded
        } catch {
            products = []
            productLoadState = .failed(error.localizedDescription)
        }
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

    func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlement()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastErrorMessage = error.localizedDescription
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
            isSubscribed = true
            return
        }
        var subscribed = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               PlusProductID(rawValue: transaction.productID) != nil,
               transaction.revocationDate == nil {
                subscribed = true
            }
        }
        isSubscribed = subscribed
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
