import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import Combine
import RevenueCat

@MainActor
final class AuthManager: NSObject, ObservableObject {
    static let shared = AuthManager()

    @Published var currentUser: User?
    private var handle: AuthStateDidChangeListenerHandle?

    // Hold strong refs during the Apple flow
    private var appleController: ASAuthorizationController?
    private var appleDelegateRef: AppleAuthDelegate?

    // Near other private vars
    var appleAuthInFlight = false



    // Nonce storage for Apple flow
    private var currentNonce: String?

    private override init() {
        super.init()
        handle = Auth.auth().addStateDidChangeListener { _, user in
            let previousUser = self.currentUser
            self.currentUser = user
            print("Auth state:", user?.uid ?? "nil", "anon:", user?.isAnonymous ?? true)
            Analytics.shared.syncFirebaseAuth(from: previousUser, to: user)
            Task {
                if let u = user {
                    // Keep RC identity aligned to the Firebase UID from anonymous onboarding onward.
                    do { _ = try await Purchases.shared.logIn(u.uid) } catch {
                        print("[RevenueCat] logIn failed:", error.localizedDescription)
                    }
                    Analytics.shared.updateCurrentUserProperties([
                        "revenuecat_app_user_id": Purchases.shared.appUserID
                    ])

                    if !u.isAnonymous {
                    // Only (re)enable backup automatically if:
                    // - user previously had the toggle ON, and
                    // - user currently has Pro.
                        let wantsBackup = UserDefaults.standard.bool(forKey: "cloudBackup.enabled")
                        if wantsBackup {
                            do {
                                // Check Pro entitlement before enabling
                                let info = try await Purchases.shared.customerInfo()
                                let isPro = info.entitlements.active.values.contains { $0.productIdentifier.contains("pro") } // or your exact check
                                if isPro {
                                    try await CloudBackupService.shared.enableBackup(for: u.uid)
                                } else {
                                    // If they no longer have Pro, keep the toggle but ensure service is off
                                    await CloudBackupService.shared.disableBackup()
                                }
                            } catch {
                                print("[Backup] gated re-enable failed:", error.localizedDescription)
                            }
                        }
                    } else {
                        await CloudBackupService.shared.disableBackup()
                    }
                } else {
                    do { _ = try await Purchases.shared.logOut() } catch {
                        print("[RevenueCat] logOut failed:", error.localizedDescription)
                    }
                    Analytics.shared.updateCurrentUserProperties([
                        "revenuecat_app_user_id": Purchases.shared.appUserID
                    ])
                    await CloudBackupService.shared.disableBackup()
                }

            }
        }



        // Start anonymous if no user (so app works pre-login)
        if Auth.auth().currentUser == nil {
            Auth.auth().signInAnonymously { _, error in
                if let error { print("Anon sign-in error:", error) }
            }
        } else {
            self.currentUser = Auth.auth().currentUser
        }
    }

    private func handleFirebaseSignIn(user: User) {
        // Log into RevenueCat with Firebase UID
        Task {
            do {
                _ = try await Purchases.shared.logIn(user.uid)
                print("[RevenueCat] logged in as \(user.uid)")
            } catch {
                print("[RevenueCat] logIn failed:", error.localizedDescription)
            }
        }
    }

    private func handleFirebaseSignOut() {
        // Log out to return to anonymous RevenueCat ID
        Task {
            do {
                _ = try await Purchases.shared.logOut()
                print("[RevenueCat] logged out")
            } catch {
                print("[RevenueCat] logOut failed:", error.localizedDescription)
            }
        }
    }

    // MARK: - Public API

    func signInWithApple(linkIfAnonymous: Bool = true, presentingWindow: UIWindow?) async throws {
        guard !appleAuthInFlight else {
                print("ℹ️ Apple sign-in already in progress; ignoring duplicate tap")
                return
            }
            appleAuthInFlight = true

        let nonce: String
        do {
            nonce = try randomNonceString()
        } catch {
            appleAuthInFlight = false
            throw error
        }
        currentNonce = nonce

        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])

        // Keep strong references
        let delegate = AppleAuthDelegate(
            nonce: nonce,
            completion: { [weak self] credential in
                guard let self = self else { return }
                Task {
                    do {
                        try await self.finishFirebaseSignIn(credential: credential, linkIfAnonymous: linkIfAnonymous, allowRetry: false)
                    } catch {
                        print("🔥 Firebase sign-in failed:", error.localizedDescription)
                    }
                    // release after callback completes
                    self.appleController = nil
                    self.appleDelegateRef = nil
                    self.appleAuthInFlight = false
                }
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                print("Apple auth error:", error.localizedDescription)
                self.appleController = nil
                self.appleDelegateRef = nil
                self.appleAuthInFlight = false
            }
        )
        controller.delegate = delegate
        controller.presentationContextProvider = delegate

        // Retain
        self.appleController = controller
        self.appleDelegateRef = delegate


        // Present
        if presentingWindow != nil {
            controller.performRequests()   // using your extension is fine; this is sufficient
        } else {
            controller.performRequests()
        }
    }


    func signOut() {
        Task {
            // 0) Turn OFF cloud backup immediately (separate function requested)
            await CloudBackupService.shared.stopAndDisableBackup()
            UserDefaults.standard.set(false, forKey: "cloudBackup.enabled")

            do {
                // 1) Sign out of Firebase (auth listener will handle RC.logOut)
                try Auth.auth().signOut()
                self.currentUser = nil

                // 2) Keep app usable in anon mode
                Auth.auth().signInAnonymously { _, err in
                    if let err { print("Anon sign-in error:", err) }
                }

                // 3) Refresh entitlements for anon user (optional but nice)
                await Entitlements.shared.refreshEntitlements()
            } catch {
                print("Sign out error:", error)
            }
        }
    }



    // MARK: - Private helpers

    // AuthManager.swift
    private func finishFirebaseSignIn(
        credential: AuthCredential,
        linkIfAnonymous: Bool,
        allowRetry: Bool = true                    // ← add this
    ) async throws {
        let auth = Auth.auth()

        do {
            if linkIfAnonymous, let anon = auth.currentUser, anon.isAnonymous {
                _ = try await anon.link(with: credential)
                self.currentUser = auth.currentUser
            } else {
                _ = try await auth.signIn(with: credential)
                self.currentUser = auth.currentUser
            }
            return
        } catch {
            let ns = error as NSError

                // 1) If Firebase returns an updated credential, use it.
                if let updated = ns.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential {
                    let auth = Auth.auth()
                    if linkIfAnonymous, let anon = auth.currentUser, anon.isAnonymous {
                        do {
                            // Try to LINK first (preserve UID/data)
                            _ = try await anon.link(with: updated)
                            self.currentUser = auth.currentUser
                            return
                        } catch let e as NSError where e.domain == AuthErrorDomain &&
                                                      e.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                            // Already linked to another account → SIGN IN to that account
                            let result = try await auth.signIn(with: updated)
                            self.currentUser = result.user
                            return
                        }
                    } else {
                        // Not anonymous → just sign in with the updated cred
                        let result = try await auth.signIn(with: updated)
                        self.currentUser = result.user
                        return
                    }
                }

                // 2) No updated credential: handle common cases
                if ns.domain == AuthErrorDomain {
                    switch AuthErrorCode(rawValue: ns.code) {
                    case .credentialAlreadyInUse:
                        // Try signing in with the ORIGINAL credential
                        let result = try await Auth.auth().signIn(with: credential)
                        self.currentUser = result.user
                        return
                    case .providerAlreadyLinked:
                        self.currentUser = Auth.auth().currentUser
                        return
                    default:
                        break
                    }
                }

                // (optional) log for diagnostics
                print("🔥 Firebase sign-in error: code=\(ns.code) domain=\(ns.domain) msg=\(ns.localizedDescription)")
                throw ns
        }
    }


    // MARK: - Nonce utilities

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private enum NonceError: LocalizedError {
        case invalidLength
        case generationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidLength:
                return "Invalid nonce length."
            case .generationFailed(let status):
                return "Unable to generate nonce (OSStatus \(status))."
            }
        }
    }

    private func randomNonceString(length: Int = 32) throws -> String {
        guard length > 0 else { throw NonceError.invalidLength }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if status != errSecSuccess { throw NonceError.generationFailed(status) }
            randoms.forEach { random in
                if remaining == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }
}

// MARK: - Apple Auth Delegate
private final class AppleAuthDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let nonce: String
    let completion: (AuthCredential) -> Void
    let onError: (Error) -> Void

    init(nonce: String, completion: @escaping (AuthCredential) -> Void, onError: @escaping (Error) -> Void) {
        self.nonce = nonce
        self.completion = completion
        self.onError = onError
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let idTokenData = credential.identityToken,
            let idTokenString = String(data: idTokenData, encoding: .utf8)
        else {
            print("Apple auth: missing token")
            return
        }

        // idTokenString is already non-optional from your guard above
        let authCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: (authorization.credential as? ASAuthorizationAppleIDCredential)?.fullName // ok to pass nil
        )
        completion(authCredential)

    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onError(error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow ?? ASPresentationAnchor()
    }
}

private extension ASAuthorizationController {
    func performRequests(from window: UIWindow) {
        self.performRequests()
    }
}
