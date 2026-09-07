import Foundation
import FirebaseAuth
import RevenueCat

enum UpgradeError: Error { case userCancelled, authFailed, rcLoginFailed }

enum UpgradeFlow {
    /// Ensure user is signed in (not anonymous). If anonymous, present your sign-in UI and LINK credentials.
    @MainActor
    static func ensureSignedIn() async throws -> User {
        if let u = Auth.auth().currentUser, !u.isAnonymous {
            return u
        }
        // TODO: Present your sign-in UI and LINK to the current anonymous user.
        // e.g., await AuthManager.shared.presentSignInAndLink()
        // For now, throw to indicate you need to call your real sign-in flow.
        throw UpgradeError.authFailed
    }

    /// Call after ensureSignedIn(): tell RevenueCat to log in with the Firebase UID (merges anonymous → identified)
    static func revenueCatLogin(uid: String) async throws {
        do {
            // Perform RC login (merges anon → identified if applicable)
            let result = try await Purchases.shared.logIn(uid)
            print("[RC] logIn: created=\(result.created)")
            Analytics.shared.updateCurrentUserProperties([
                "revenuecat_app_user_id": Purchases.shared.appUserID
            ])
        } catch {
            print("[RC] logIn failed:", error.localizedDescription)
            throw UpgradeError.rcLoginFailed
        }
    }


    /// Entry point to show the paywall (calls ensureSignedIn → RC logIn → present)
    @MainActor
    static func presentPaywall() async {
        do {
            let user = try await ensureSignedIn()
            try await revenueCatLogin(uid: user.uid)
            PaywallCoordinator.shared.present()
        } catch UpgradeError.userCancelled {
            // user dismissed sign-in; ignore
        } catch {
            // Show a gentle error toast if you want
            print("[Upgrade] failed:", error.localizedDescription)
        }
    }
}

extension UpgradeFlow {
    static func requireProAndRoute(reason: String, onProAllowed completion: @escaping () -> Void) {
        Purchases.shared.getCustomerInfo { info, _ in
            let isPro = info?.entitlements["pro"]?.isActive == true
            if isPro {
                completion()
                return
            }
            MP.track(LegacyEvent.paywallShown, ["reason": reason])
            presentPaywall(reason: reason, onPurchased: completion)
        }
    }

    private static func presentPaywall(reason: String, onPurchased: @escaping () -> Void) {
        Purchases.shared.getOfferings { offerings, _ in
            guard let current = offerings?.current else { return }
            // TODO: Present your paywall UI using current.availablePackages
            // When the user taps a package button, track and purchase:
            func purchase(_ package: Package) {
                let context = PaywallAnalyticsContext(
                    source: "upgrade_flow",
                    reason: reason,
                    isOnboarding: false
                )
                MP.track(LegacyEvent.paywallCtaTap, ["reason": reason, "package": package.identifier])
                Analytics.shared.track(
                    event: Event.subscriptionPurchaseStarted,
                    properties: context.baseProperties.merging(["package_id": package.identifier]) { _, new in new }
                )
                Purchases.shared.purchase(package: package) { _, info, error, userCancelled in
                    if let info, info.entitlements["pro"]?.isActive == true {
                        Analytics.shared.track(
                            event: Event.subscriptionPurchaseCompleted,
                            properties: context.baseProperties.merging([
                                "package_id": package.identifier,
                                "entitlement_is_active": true
                            ]) { _, new in new }
                        )
                        onPurchased()
                    }
                }
            }
            // Temporary default: pick by preference if you don't have a UI yet
            if let lifetime = current.availablePackages.first(where: { $0.packageType == .lifetime }) {
                purchase(lifetime)
            } else if let annual = current.availablePackages.first(where: { $0.packageType == .annual }) {
                purchase(annual)
            } else if let first = current.availablePackages.first {
                purchase(first)
            }
        }
    }
}
