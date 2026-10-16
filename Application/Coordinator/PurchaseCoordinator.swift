import Foundation
import OSLog

/// Owns the iOS-side purchase and entitlement lifecycle so that views only
/// observe state and delegate user actions.
@MainActor
final class PurchaseCoordinator {
    let purchaseService: StoreKitPurchaseService
    private let entitlementService: EntitlementService

    init(purchaseService: StoreKitPurchaseService, entitlementService: EntitlementService) {
        self.purchaseService = purchaseService
        self.entitlementService = entitlementService
    }

    /// Begin listening for StoreKit transaction updates. Passes the current
    /// credential on each update so the service can sync with the backend.
    func startObservingTransactions(credentialProvider: @escaping @MainActor () -> LinkedInPostCredential?, onSynced: @escaping @MainActor (LinkedInPostCredential) async -> Void = { _ in }) {
        purchaseService.startObservingTransactions(credential: credentialProvider, onSynced: onSynced)
    }

    /// Sync local StoreKit entitlements with the backend. Returns `true` if at
    /// least one Bloomary entitlement was found and synced.
    @discardableResult
    func syncCurrentEntitlements(credential: LinkedInPostCredential) async throws -> Bool {
        try await purchaseService.syncCurrentEntitlements(credential: credential)
    }

    /// Fetch the latest entitlement from the backend.
    func refreshEntitlement(credential: LinkedInPostCredential) async -> Entitlement? {
        do { return try await entitlementService.entitlement(credential: credential, forceRefresh: true) }
        catch {
            Logger(subsystem: "com.dailymind.bloomary", category: "Entitlement").error("GET /api/entitlement failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }
}
