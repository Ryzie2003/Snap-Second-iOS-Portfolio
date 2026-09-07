import AuthenticationServices
import CryptoKit
import FirebaseAuth
import UIKit

enum AppleReauthError: LocalizedError {
    case noIdentityToken, canceled
    case invalidNonceLength
    case nonceGenerationFailed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .noIdentityToken: return "Apple did not return an identity token."
        case .canceled:        return "Sign in with Apple was canceled."
        case .invalidNonceLength: return "Invalid nonce length."
        case .nonceGenerationFailed(let status):
            return "Unable to generate nonce (OSStatus \(status))."
        }
    }
}

enum AppleReauthHelper {
    @MainActor
    static func reauthenticateAndGetFirebaseCredential() async throws -> AuthCredential {
        let nonce = try randomNonceString()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [] // reauth doesn’t need name/email
        request.nonce = sha256(nonce)

        let credential = try await performAppleRequest(request)
        guard
            let appleCred = credential as? ASAuthorizationAppleIDCredential,
            let tokenData  = appleCred.identityToken,
            let idToken    = String(data: tokenData, encoding: .utf8)
        else { throw AppleReauthError.noIdentityToken }

        return OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce, fullName: nil)

    }

    // MARK: - Private

    @MainActor
    private static func performAppleRequest(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { cont in
            let controller = ASAuthorizationController(authorizationRequests: [request])
            let proxy = Proxy(continuation: cont)
            controller.delegate = proxy
            controller.presentationContextProvider = proxy
            controller.performRequests()
            // retain proxy for the controller lifecycle
            objc_setAssociatedObject(controller, Unmanaged.passUnretained(controller).toOpaque(), proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    @MainActor
    private final class Proxy: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        let continuation: CheckedContinuation<ASAuthorizationCredential, Error>
        init(continuation: CheckedContinuation<ASAuthorizationCredential, Error>) { self.continuation = continuation }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                .keyWindow ?? UIWindow()
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            continuation.resume(returning: authorization.credential)
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            if let nsErr = error as NSError?, nsErr.code == ASAuthorizationError.canceled.rawValue {
                continuation.resume(throwing: AppleReauthError.canceled)
            } else {
                continuation.resume(throwing: error)
            }
        }
    }

    // Nonce helpers
    private static func sha256(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    private static func randomNonceString(length: Int = 32) throws -> String {
        guard length > 0 else { throw AppleReauthError.invalidNonceLength }
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""; result.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw AppleReauthError.nonceGenerationFailed(status) }
            bytes.forEach { b in
                if remaining == 0 { return }
                if b < charset.count {
                    result.append(charset[Int(b)])
                    remaining -= 1
                }
            }
        }
        return result
    }
}
