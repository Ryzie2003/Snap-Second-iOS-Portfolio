import Foundation
import FirebaseAuth
import FirebaseFirestore
import UIKit

struct FirebaseSurveyService {
    private let db = Firestore.firestore()

    /// Save an onboarding survey for the current user (anonymous or signed-in).
    /// - Parameters:
    ///   - version: survey schema version, e.g. "v1"
    ///   - answers: flat dictionary of answers (strings / bools / numbers / [String])
    ///   - overwrite: if true, writes to a fixed doc id per version (one doc per user per version)
    func saveSurvey(version: String, answers: [String: Any], overwrite: Bool = false) async throws {
        if Auth.auth().currentUser == nil {
            _ = try await Auth.auth().signInAnonymously()
        }
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let docId = overwrite ? "onboarding-\(version)" : "onboarding-\(version)-\(UUID().uuidString)"
        let docRef = db.collection("users").document(uid).collection("surveys").document(docId)

        let payload: [String: Any] = [
            "version": version,
            "answers": answers, // keep FLAT for simpler queries & cheaper reads
            "createdAt": FieldValue.serverTimestamp(),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build":      Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "device":     UIDevice.current.model,
            "ios":        UIDevice.current.systemVersion
        ]

        try await docRef.setData(payload, merge: false)
    }
}
