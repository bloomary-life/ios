import CryptoKit
import Foundation
import StoreKit

enum StoreKitPurchaseError: LocalizedError {
    case missingAuth
    case noProduct
    case pending
    case unverified
    case noActivePurchase
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            return "Connect LinkedIn first."
        case .noProduct:
            return "Subscription is unavailable."
        case .pending:
            return "Purchase is pending."
        case .unverified:
            return "Purchase could not be verified."
        case .noActivePurchase:
            return "No active purchase found."
        case .server(let message):
            return message
        }
    }
}

enum PurchaseOutcome { case succeeded, pending, cancelled }

@MainActor
final class StoreKitPurchaseService: ObservableObject {
    @Published private(set) var monthlyProduct: Product?
    @Published private(set) var yearlyProduct: Product?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?

    var product: Product? { monthlyProduct }

    private let apiBaseURL: URL
    private let productIDs: [String]
    private var updatesTask: Task<Void, Never>?

    init(apiBaseURL: URL, productIDs: [String] = ["bloomary.pro.monthly", "bloomary.pro.yearly"]) {
        self.apiBaseURL = apiBaseURL
        self.productIDs = productIDs
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProduct() async {
        let loadedIDs = Set([monthlyProduct?.id, yearlyProduct?.id].compactMap { $0 })
        let missingIDs = productIDs.filter { !loadedIDs.contains($0) }
        guard !missingIDs.isEmpty else { return }
        do {
            let products = try await Product.products(for: missingIDs)
            for product in products {
                switch product.type {
                case .autoRenewable:
                    if product.id.contains("yearly") {
                        yearlyProduct = product
                    } else {
                        monthlyProduct = product
                    }
                default:
                    break
                }
            }
            if monthlyProduct != nil || yearlyProduct != nil {
                statusMessage = nil
                AppTelemetry.track(.purchaseProductLoaded)
            } else {
                statusMessage = StoreKitPurchaseError.noProduct.localizedDescription
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func purchase(credential: LinkedInPostCredential?, product: Product? = nil) async throws -> PurchaseOutcome {
        guard let credential else { throw StoreKitPurchaseError.missingAuth }
        guard !isWorking else { throw StoreKitPurchaseError.server("A purchase operation is already in progress.") }
        isWorking = true
        defer { isWorking = false }
        let selectedProduct: Product
        if let product {
            selectedProduct = product
        } else {
            selectedProduct = try await loadedProduct()
        }
        AppTelemetry.track(.purchaseStarted)
        let result = try await selectedProduct.purchase(options: [.appAccountToken(appAccountToken(memberID: credential.memberID))])
        switch result {
        case .success(let verification):
            let signedTransaction = try verified(verification)
            try await sync(signedTransaction: signedTransaction, credential: credential)
            await signedTransaction.transaction.finish()
            statusMessage = "Bloomary Pro is active."
            AppTelemetry.track(.purchaseSucceeded)
            return .succeeded
        case .pending:
            AppTelemetry.track(.purchaseFailed, parameters: ["reason": "pending"])
            statusMessage = "Purchase is pending approval."
            return .pending
        case .userCancelled:
            AppTelemetry.track(.purchaseFailed, parameters: ["reason": "cancelled"])
            statusMessage = "Purchase cancelled."
            return .cancelled
        @unknown default:
            AppTelemetry.track(.purchaseFailed, parameters: ["reason": "unknown"])
            throw StoreKitPurchaseError.unverified
        }
    }

    func restore(credential: LinkedInPostCredential?) async throws {
        guard let credential else { throw StoreKitPurchaseError.missingAuth }
        guard !isWorking else { throw StoreKitPurchaseError.server("A purchase operation is already in progress.") }
        isWorking = true
        defer { isWorking = false }

        AppTelemetry.track(.purchaseRestoreStarted)
        try await AppStore.sync()
        let didSync = try await syncCurrentEntitlements(credential: credential)
        guard didSync else {
            AppTelemetry.track(.purchaseRestoreFailed, parameters: ["reason": "no_active_purchase"])
            throw StoreKitPurchaseError.noActivePurchase
        }
        statusMessage = "Purchases restored."
        AppTelemetry.track(.purchaseRestoreSucceeded)
    }

    func startObservingTransactions(credential: @escaping @MainActor () -> LinkedInPostCredential?, onSynced: @escaping @MainActor (LinkedInPostCredential) async -> Void = { _ in }) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                do {
                    let signedTransaction = try self.verified(result)
                    guard self.productIDs.contains(signedTransaction.transaction.productID) else { continue }
                    try Task.checkCancellation()
                    guard let credential = credential() else {
                        statusMessage = "Sign in to complete your purchase."
                        continue
                    }
                    try await self.sync(signedTransaction: signedTransaction, credential: credential)
                    await signedTransaction.transaction.finish()
                    await onSynced(credential)
                } catch {
                    AppTelemetry.track(.purchaseSyncFailed, parameters: ["reason": "observer"])
                    statusMessage = "Purchase will be verified when you're online."
                }
            }
        }
    }

    func syncCurrentEntitlements(credential: LinkedInPostCredential) async throws -> Bool {
        var didSync = false
        for await result in Transaction.currentEntitlements {
            let signedTransaction = try verified(result)
            guard productIDs.contains(signedTransaction.transaction.productID) else { continue }
            try await sync(signedTransaction: signedTransaction, credential: credential)
            await signedTransaction.transaction.finish()
            didSync = true
        }
        return didSync
    }

    private func loadedProduct() async throws -> Product {
        if let monthlyProduct { return monthlyProduct }
        let products = try await Product.products(for: productIDs)
        guard let product = products.first(where: { !$0.id.contains("yearly") }) else {
            throw StoreKitPurchaseError.noProduct
        }
        self.monthlyProduct = product
        return product
    }

    private func verified(_ result: VerificationResult<Transaction>) throws -> SignedStoreKitTransaction {
        switch result {
        case .verified(let transaction):
            return SignedStoreKitTransaction(transaction: transaction, jwsRepresentation: result.jwsRepresentation)
        case .unverified:
            throw StoreKitPurchaseError.unverified
        }
    }

    private func sync(signedTransaction: SignedStoreKitTransaction, credential: LinkedInPostCredential) async throws {
        var request = URLRequest(url: apiBaseURL.appending(path: "/api/apple/transactions/sync"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.app.encode(
            AppleTransactionSyncRequest(memberId: credential.memberID, signedTransaction: signedTransaction.jwsRepresentation)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder.app.decode(AppleTransactionSyncAPIError.self, from: data) {
                throw StoreKitPurchaseError.server(apiError.errorDescription ?? apiError.error)
            }
            throw StoreKitPurchaseError.server("Purchase sync failed.")
        }
    }

    func appAccountToken(memberID: String) -> UUID {
        let namespaceURL: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        let name = Data("bloomary:linkedin:\(memberID.trimmingCharacters(in: .whitespacesAndNewlines))".utf8)
        var data = Data(namespaceURL)
        data.append(name)
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private struct SignedStoreKitTransaction {
    let transaction: Transaction
    let jwsRepresentation: String
}

private struct AppleTransactionSyncRequest: Encodable {
    let memberId: String
    let signedTransaction: String
}

private struct AppleTransactionSyncAPIError: Decodable {
    let error: String
    let errorDescription: String?
}
