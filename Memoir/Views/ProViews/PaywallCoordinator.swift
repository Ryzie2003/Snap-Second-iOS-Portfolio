import SwiftUI
import RevenueCat
#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

final class PaywallCoordinator: ObservableObject {
    static let shared = PaywallCoordinator()
    @Published var isPresented = false
    @Published var offering: Offering?
    @Published var analyticsContext: PaywallAnalyticsContext = .generic
    private var lastFetchAt: Date?
    fileprivate var pendingPackageID: String?

    func present(context: PaywallAnalyticsContext = .generic) {
      analyticsContext = context
      Task {
          // If we already have an offering (or fetched recently), just show it.
        if await MainActor.run(body: { self.offering }) != nil,
           let last = await MainActor.run(body: { self.lastFetchAt }),
           Date().timeIntervalSince(last) < 600 {
          await MainActor.run { self.isPresented = true }
          return
        }

        do {
          let offerings = try await Purchases.shared.offerings()
          await MainActor.run {
            self.offering   = offerings.current ?? offerings.all["default"]
            self.lastFetchAt = Date()
            self.isPresented = true
          }
        } catch {
          await MainActor.run { self.isPresented = true } // show placeholder UI
        }
      }
    }


    func dismiss() {
        isPresented = false
        offering = nil
        analyticsContext = .generic
        pendingPackageID = nil
    }
}

struct PaywallSheet: View {
    @ObservedObject var coordinator: PaywallCoordinator = .shared

    var body: some View {
        Group {
            #if canImport(RevenueCatUI)
            if let offering = coordinator.offering {
                PaywallView(offering: offering)
                    .onPurchaseStarted { package in
                        let context = coordinator.analyticsContext
                        coordinator.pendingPackageID = package.identifier
                        if context.isOnboarding {
                            OnboardingAnalytics.trackPaywallCTATapped(
                                context: context,
                                packageID: package.identifier
                            )
                            OnboardingAnalytics.trackSubscriptionPurchaseStarted(
                                context: context,
                                packageID: package.identifier
                            )
                        } else {
                            Analytics.shared.track(
                                event: Event.subscriptionPurchaseStarted,
                                properties: context.baseProperties.merging([
                                    "package_id": package.identifier
                                ]) { _, new in new }
                            )
                        }
                    }
                    .onPurchaseCompleted { customerInfo in
                        let context = coordinator.analyticsContext
                        let packageID = coordinator.pendingPackageID
                            ?? customerInfo.activeSubscriptions.first
                            ?? "unknown"
                        let entitlementIsActive = !customerInfo.entitlements.active.isEmpty

                        if context.isOnboarding {
                            OnboardingAnalytics.trackSubscriptionPurchaseCompleted(
                                context: context,
                                packageID: packageID,
                                entitlementIsActive: entitlementIsActive
                            )
                        } else {
                            Analytics.shared.track(
                                event: Event.subscriptionPurchaseCompleted,
                                properties: context.baseProperties.merging([
                                    "package_id": packageID,
                                    "entitlement_is_active": entitlementIsActive
                                ]) { _, new in new }
                            )
                        }
                    }
                    .onRequestedDismissal {
                        coordinator.dismiss()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .onReceive(Entitlements.shared.$isPro) { isPro in
                        if isPro { coordinator.dismiss() }
                    }
                    .onDisappear {
                        coordinator.dismiss()
                    }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground).ignoresSafeArea())
            }
            #else
            VStack(spacing: 12) {
                Text("Pro").font(.title2).bold()
                Text("Install RevenueCatUI to show a full paywall or wire your custom paywall here.")
                Button("Close") { coordinator.dismiss() }
            }.padding()
            #endif
        }
    }
}
