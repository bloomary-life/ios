import StoreKit
import SwiftUI

struct PurchaseView: View {
    @ObservedObject var purchaseService: StoreKitPurchaseService
    let credential: LinkedInPostCredential?
    let isPro: Bool
    var subscriptionSource: String? = nil
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var showsManageSubscriptions = false
    @State private var selectedPlan: Plan = .monthly

    enum Plan: String, CaseIterable {
        case monthly, yearly
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bloomary Pro")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppStyle.ink)

                if isPro {
                    proActiveView
                } else {
                    purchaseContent
                }

                VStack(alignment: .leading, spacing: 8) {
                    Link("Terms of Use", destination: URL(string: "https://bloomary.life/terms.html")!)
                    Link("Privacy Policy", destination: URL(string: "https://bloomary.life/privacy.html")!)
                }
                .font(.footnote)

            }
            .padding()
            }
            .background(AppStyle.paper)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await purchaseService.loadProduct()
            }
            .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
        }
    }

    @ViewBuilder
    private var proActiveView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're Pro", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppStyle.green)

            Text("Schedule posts. Keep up to 50 drafts.")
                .font(.body)
                .foregroundStyle(AppStyle.muted)

            if subscriptionSource == "apple" {
                Button("Manage in App Store") { showsManageSubscriptions = true }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Text("Your subscription is managed on the web.")
                Link("Manage subscription on web", destination: URL(string: "https://platform.bloomary.life/settings")!)
            }

            Button("Restore Purchases") {
                runRestore()
            }
            .font(.subheadline)
            .foregroundStyle(AppStyle.coral)
            .disabled(purchaseService.isWorking || credential == nil)
        }
    }

    private var purchaseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish, schedule, and edit up to 50 drafts. Without an active plan, your drafts stay readable and exportable.")
                .font(.body)
                .foregroundStyle(AppStyle.muted)

            planPicker

            if let message = message ?? purchaseService.statusMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppStyle.muted)
            }

            featuresList

            VStack(spacing: 10) {
                Button(purchaseService.isWorking ? "Working..." : "Subscribe") {
                    runPurchase()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(purchaseService.isWorking || selectedProduct == nil || credential == nil)

                Button("Restore Purchases") {
                    runRestore()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(purchaseService.isWorking || credential == nil)

                Button("Manage Subscriptions") {
                    showsManageSubscriptions = true
                }
                .font(.subheadline)
                .foregroundStyle(AppStyle.coral)
            }
        }
    }

    private var selectedProduct: Product? {
        switch selectedPlan {
        case .monthly:
            return purchaseService.monthlyProduct
        case .yearly:
            return purchaseService.yearlyProduct
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            planCard(
                plan: .yearly,
                title: "Yearly",
                product: purchaseService.yearlyProduct,
                badge: "Best Value",
                perMonth: perMonthText(purchaseService.yearlyProduct)
            )
            planCard(
                plan: .monthly,
                title: "Monthly",
                product: purchaseService.monthlyProduct,
                badge: nil,
                perMonth: nil
            )
            if purchaseService.monthlyProduct == nil || purchaseService.yearlyProduct == nil {
                Button("Retry loading plans") { Task { await purchaseService.loadProduct() } }
            }
        }
    }

    private func planCard(plan: Plan, title: String, product: Product?, badge: String?, perMonth: String?) -> some View {
        Button {
            selectedPlan = plan
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(AppStyle.ink)
                        if let badge {
                            Text(badge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(AppStyle.coral)
                                .clipShape(Capsule())
                        }
                    }
                    if let product {
                        HStack(spacing: 4) {
                            Text(product.displayPrice)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppStyle.ink)
                            Text(subscriptionPeriodText(product))
                                .font(.subheadline)
                                .foregroundStyle(AppStyle.muted)
                        }
                        if let perMonth {
                            Text(perMonth)
                                .font(.caption)
                                .foregroundStyle(AppStyle.muted)
                        }
                    } else {
                        Text("Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(AppStyle.muted)
                    }
                }
                Spacer()
                Image(systemName: selectedPlan == plan ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selectedPlan == plan ? AppStyle.coral : AppStyle.muted.opacity(0.4))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedPlan == plan ? AppStyle.lime.opacity(0.15) : AppStyle.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selectedPlan == plan ? AppStyle.coral.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(product == nil)
    }

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 6) {
            featureRow("Schedule posts")
            featureRow("50 drafts")
        }
    }

    private func featureRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppStyle.coral)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppStyle.ink)
        }
    }

    private func perMonthText(_ product: Product?) -> String? {
        guard let product else { return nil }
        let yearlyPrice = product.price
        let monthly = yearlyPrice / 12
        return monthly.formatted(.currency(code: product.priceFormatStyle.currencyCode)) + "/mo"
    }

    private func subscriptionPeriodText(_ product: Product) -> String {
        guard let subscription = product.subscription else { return "" }
        let period = subscription.subscriptionPeriod
        switch period.unit {
        case .day:
            return "/ " + (period.value == 1 ? "day" : "\(period.value) days")
        case .week:
            return "/ " + (period.value == 1 ? "week" : "\(period.value) weeks")
        case .month:
            return "/ " + (period.value == 1 ? "month" : "\(period.value) months")
        case .year:
            return "/ " + (period.value == 1 ? "year" : "\(period.value) years")
        @unknown default:
            return ""
        }
    }

    private func runPurchase() {
        Task {
            do {
                guard let selectedProduct else { throw StoreKitPurchaseError.noProduct }
                switch try await purchaseService.purchase(credential: credential, product: selectedProduct) {
                case .succeeded:
                    onFinished()
                    dismiss()
                case .pending:
                    message = "Purchase is pending approval. Your plan will update after it completes."
                case .cancelled:
                    message = "Purchase cancelled."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func runRestore() {
        Task {
            do {
                try await purchaseService.restore(credential: credential)
                onFinished()
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
