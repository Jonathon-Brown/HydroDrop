import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    enum PlusProductID: String, CaseIterable {
        case monthly = "com.jonathonbrown.HydroDrop.plus.monthly"
        case yearly = "com.jonathonbrown.HydroDrop.plus.yearly"
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published private(set) var purchaseInProgress = false
    @Published var lastErrorMessage: String?

    private var transactionListener: Task<Void, Never>?

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

    func loadProducts() async {
        do {
            let ids = PlusProductID.allCases.map(\.rawValue)
            products = try await Product.products(for: ids).sorted { $0.price < $1.price }
        } catch {
            lastErrorMessage = error.localizedDescription
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

    private func refreshEntitlement() async {
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
        var errorDescription: String? { "Could not verify this purchase." }
    }
}
