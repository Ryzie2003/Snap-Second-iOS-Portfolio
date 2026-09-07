import Foundation
import RevenueCat
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseAppCheck
// import Purchases // If you use RevenueCat, uncomment and logOut() below.

enum AccountDeletionError: LocalizedError {
    case notLoggedIn, appIntegrity, reauthFailed
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "You’re not signed in."
        case .appIntegrity: return "App integrity check failed. Please try again."
        case .reauthFailed: return "Couldn’t verify your identity with Apple."
        }
    }
}

final class AccountDeletionService {

    /// Full flow:
    /// 1) Preflight App Check (enforced projects)
    /// 2) Re-auth with Apple (required by Firebase to delete Auth user)
    /// 3) Delete Storage files + Firestore docs under /users/{uid}/backups/**
    /// 4) Delete /users/{uid} doc
    /// 5) Delete Firebase Auth user
    /// 6) Sign out (NO local file wipe)
    static func performFullAccountErasure() async throws {
        guard let user = Auth.auth().currentUser else { throw AccountDeletionError.notLoggedIn }

        // 1) App Check preflight (TestFlight/Release with enforce ON)
        do { _ = try await AppCheck.appCheck().token(forcingRefresh: true) }
        catch { throw AccountDeletionError.appIntegrity }

        // 2) Re-authenticate user with Apple now (so we abort cleanly if they cancel)
        let cred: AuthCredential
        do {
            cred = try await AppleReauthHelper.reauthenticateAndGetFirebaseCredential()
            try await user.reauthenticate(with: cred)
        } catch {
            throw AccountDeletionError.reauthFailed
        }

        let uid = user.uid
        let db = Firestore.firestore()
        let storage = Storage.storage()

        // 3) Delete backups cascade (clips -> journals -> backup doc)
        try await deleteAllBackups(uid: uid, db: db, storage: storage)

        // 4) Delete /users/{uid} doc (allowed by your loosened rules)
        try await db.collection("users").document(uid).delete()

        // 5) Delete Firebase Auth user
        try await user.delete()

        // 6) Sign out of SDKs (no local wipe; your on-device Memoir files remain)
        try? await Purchases.shared.logOut()  // If using RevenueCat and appUserID
        try? Auth.auth().signOut()
    }

    // MARK: - Backups cascade helpers

    private static func deleteAllBackups(uid: String, db: Firestore, storage: Storage) async throws {
        let backupsCol = db.collection("users").document(uid).collection("backups")
        let backupsSnap = try await backupsCol.getDocuments()

        for backup in backupsSnap.documents {
            try await deleteAllClips(uid: uid, backupId: backup.documentID, db: db, storage: storage)
            try await deleteAllJournals(uid: uid, backupId: backup.documentID, db: db)
            try await backup.reference.delete() // now allowed by rules
        }
    }

    private static func deleteAllClips(uid: String, backupId: String, db: Firestore, storage: Storage) async throws {
        let clipsCol = db.collection("users").document(uid)
            .collection("backups").document(backupId)
            .collection("clips")

        var last: DocumentSnapshot?
        while true {
            var q: Query = clipsCol.limit(to: 200)
            if let l = last { q = q.start(afterDocument: l) }
            let page = try await q.getDocuments()
            if page.documents.isEmpty { break }

            for clip in page.documents {
                if let path = clip.data()["path"] as? String {
                    // Best-effort storage delete; don't fail the whole cascade on a single object
                    do { try await storage.reference(withPath: path).delete() }
                    catch { print("⚠️ Storage delete failed for \(path): \(error.localizedDescription)") }
                }
                try await clip.reference.delete()
            }
            last = page.documents.last
        }
    }

    private static func deleteAllJournals(uid: String, backupId: String, db: Firestore) async throws {
        let journalsCol = db.collection("users").document(uid)
            .collection("backups").document(backupId)
            .collection("journals")

        var last: DocumentSnapshot?
        while true {
            var q: Query = journalsCol.limit(to: 200)
            if let l = last { q = q.start(afterDocument: l) }
            let page = try await q.getDocuments()
            if page.documents.isEmpty { break }
            for doc in page.documents {
                try await doc.reference.delete()
            }
            last = page.documents.last
        }
    }
}
