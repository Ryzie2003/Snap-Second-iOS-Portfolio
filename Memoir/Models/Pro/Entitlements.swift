import Foundation
import RevenueCat

/// Central entitlement state for Snap Second
final class Entitlements: NSObject, ObservableObject, PurchasesDelegate {
    static let shared = Entitlements()

    @Published var isPro: Bool = false
    @Published var isFamilyShared: Bool = false          // NEW
    @Published var entitlementSource: String? = nil      // NEW: "Family", "Lifetime", "Annual", etc.

    private let proEntitlementId = "Memoir PRO Subscriptions"
    private var hasResolvedCustomerInfo = false

    override init() {
        super.init()
        // Listen for entitlement updates
        Purchases.shared.delegate = self

        // Kick off an initial refresh
        Task { await refreshEntitlements() }
    }

    private func update(from info: CustomerInfo) {
        let wasPro = isPro

        // Find the active entitlement object for your Pro entitlement
        let active = info.entitlements.active[proEntitlementId]
        let isActiveTrial = active?.periodType == .trial
        let trialExpirationDate = active?.expirationDate

        isPro = (active != nil)

        if let e = active {
            // Map StoreKit/RevenueCat ownership
            switch e.ownershipType {
            case .familyShared:
                isFamilyShared = true
                entitlementSource = "Family"
            case .purchased:
                isFamilyShared = false
                let pid = e.productIdentifier.lowercased()
                entitlementSource =
                    pid.contains("life")     ? "Lifetime" :
                    (pid.contains("year") ||
                     pid.contains("annual")) ? "Annual" :
                    (pid.contains("month") ||
                     pid.contains("monthly")) ? "Monthly" : "Pro"
            case .unknown:
                isFamilyShared = false
                entitlementSource = "Pro"
            @unknown default:
                isFamilyShared = false
                entitlementSource = "Pro"
            }
        } else {
            isFamilyShared = false
            entitlementSource = nil
        }

        Analytics.shared.updateCurrentUserProperties([
            "is_pro": isPro,
            "entitlement_source": entitlementSource ?? "none",
            "is_family_shared": isFamilyShared,
            "revenuecat_app_user_id": Purchases.shared.appUserID
        ])

        if hasResolvedCustomerInfo, !wasPro && isPro {
            OnboardingAnalytics.trackSubscriptionEntitlementActivated(
                source: "revenuecat_customer_info",
                entitlementSource: entitlementSource
            )
        }

        Task {
            if isActiveTrial, let trialExpirationDate {
                await NotificationManager.scheduleTrialExpiryNotification(
                    expirationDate: trialExpirationDate
                )
            } else {
                await NotificationManager.clearTrialExpiryNotification()
            }
        }

        hasResolvedCustomerInfo = true
    }

    // MARK: - PurchasesDelegate
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.update(from: customerInfo)
        }
    }

    @MainActor
    func refreshEntitlements() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            update(from: info)
        } catch {
            print("[Entitlements] refresh failed:", error.localizedDescription)
        }
    }
}
