// PurchaseManager.swift
import Foundation
import StoreKit

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    enum Plan { case lifetime, yearly }

    // TODO: Replace with your real product IDs from App Store Connect
    private let lifetimeID = "com.memoir.pro.lifetime"
    private let yearlyID   = "com.memoir.pro.yearlySUB"

    @Published var isPro: Bool = false
    @Published var products: [Product] = []

    private init() {}

    // Call once on app launch (e.g., in MemoirApp.task)
    func configure() async {
        await loadProducts()
        await refreshEntitlementsFromReceipt()

        // Listen for entitlement changes: renewals, refunds, restores, etc.
        Task.detached { [weak self] in
            guard let self else { return }
            for await update in Transaction.updates {
                await self.handle(transactionUpdate: update)
            }
        }
    }

    // MARK: - Product Loading

    func loadProducts() async {
        do {
            let ids: Set<String> = [lifetimeID, yearlyID]
            let storeProducts = try await Product.products(for: Array(ids))
            self.products = storeProducts
        } catch {
            print("⚠️ Product load failed: \(error)")
        }
    }

    // MARK: - Purchasing

    func purchase(_ plan: Plan) async throws {
        let targetID = (plan == .lifetime) ? lifetimeID : yearlyID
        guard let product = products.first(where: { $0.id == targetID }) else {
            throw PurchaseError.productNotFound
        }

        // If a free trial is configured for the YEARLY product in App Store Connect,
        // StoreKit will show it automatically in the purchase sheet.
        let result = try await product.purchase()
        try await handle(purchaseResult: result)
    }

    // Optional: expose a restore for a Settings screen
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlementsFromReceipt()
        } catch {
            print("⚠️ Restore failed: \(error)")
        }
    }

    // MARK: - Result / Update Handling

    // Handle the result from `product.purchase()`
    private func handle(purchaseResult: Product.PurchaseResult) async throws {
        switch purchaseResult {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await applyEntitlement(for: transaction.productID)
            await transaction.finish()

        case .userCancelled, .pending:
            break

        @unknown default:
            break
        }
    }

    // Handle background updates from `Transaction.updates`
    private func handle(transactionUpdate: VerificationResult<Transaction>) async {
        switch transactionUpdate {
        case .verified(let transaction):
            await applyEntitlement(for: transaction.productID)
            await transaction.finish()

        case .unverified(_, let error):
            print("⚠️ Unverified transaction update: \(error)")
        }
    }

    // MARK: - Entitlements

    private func applyEntitlement(for productID: String) {
        // Simple rule: either product unlocks Pro
        if productID == lifetimeID || productID == yearlyID {
            isPro = true
        }
    }

    /// Reads the current receipt/entitlements and sets `isPro`.
    func refreshEntitlementsFromReceipt() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               tx.productID == lifetimeID || tx.productID == yearlyID {
                unlocked = true
                break
            }
        }
        isPro = unlocked
    }

    // MARK: - Helpers

    /// Verifies StoreKit data and returns the verified value or throws.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw PurchaseError.unverified(error)   // ← generic Error, no type clash
        case .verified(let safe):
            return safe
        }
    }

    enum PurchaseError: Error {
        case productNotFound
        case unverified(Error)  // ← generic payload so it works for any T
    }
}
