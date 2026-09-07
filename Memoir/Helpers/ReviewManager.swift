//
//  ReviewManager.swift
//  Memoir
//
//  Created on 1/1/26.
//
//  LOWERED REQUIREMENTS (Optimized for faster review collection):
//  ✅ 1st montage export → Review prompt
//  ✅ 1st project created (+ 3 days) → Review prompt
//  ✅ 3 montage views → Review prompt
//  ✅ 20 clips added → Review prompt
//  ✅ 10 app opens (+ 14 days + engagement) → Review prompt
//
//  Safety: 120-day cooldown, max 3 requests/year
//

import Foundation
import StoreKit

/// Manages intelligent review prompting based on user engagement and milestones
final class ReviewManager {

    // MARK: - Singleton
    static let shared = ReviewManager()
    private init() {}

    // MARK: - UserDefaults Keys
    private enum Keys {
        static let lastRequestDate = "reviewManager_lastRequestDate"
        static let totalRequestCount = "reviewManager_totalRequestCount"
        static let montageExportCount = "reviewManager_montageExportCount"
        static let projectCreationCount = "reviewManager_projectCreationCount"
        static let appOpenCount = "reviewManager_appOpenCount"
        static let installDate = "reviewManager_installDate"
        static let montageViewCount = "reviewManager_montageViewCount"
        static let clipAddedCount = "reviewManager_clipAddedCount"
    }

    // MARK: - Configuration
    private let daysBetweenRequests: Int = 120  // Apple's recommended minimum
    private let maxLifetimeRequests: Int = 3    // Apple's yearly limit

    // Milestone thresholds (lowered for more frequent reviews)
    private let montageExportThreshold = 1       // After 1st export (down from 3)
    private let projectCreationThreshold = 1     // After 1st project (down from 2)
    private let minDaysSinceInstall = 3          // 3 days min (down from 7)
    private let fallbackOpenCountThreshold = 10  // 10 opens (down from 20)
    private let fallbackDaysSinceInstall = 14    // 14 days (down from 30)
    private let montageViewThreshold = 3         // 3 views (down from 5)
    private let clipAddedThreshold = 20          // 20 clips (down from 50)

    // MARK: - Review Context
    enum ReviewContext {
        case montageExported
        case projectCreated
        case appLaunch
        case montageViewed
        case clipsAdded
        case onboardingCompleted
    }

    // MARK: - Public API

    /// Record app open event
    func recordAppOpen() {
        incrementCount(for: .appOpenCount)
        ensureInstallDateRecorded()
    }

    /// Record montage export event and consider review request
    func recordMontageExport() {
        incrementCount(for: .montageExportCount)
        considerRequestingReview(context: .montageExported)
    }

    /// Record project creation event and consider review request
    func recordProjectCreation() {
        incrementCount(for: .projectCreationCount)
        considerRequestingReview(context: .projectCreated)
    }

    /// Record montage view event and consider review request
    func recordMontageView() {
        incrementCount(for: .montageViewCount)
        considerRequestingReview(context: .montageViewed)
    }

    /// Record clip added event and consider review request
    func recordClipAdded() {
        incrementCount(for: .clipAddedCount)
        considerRequestingReview(context: .clipsAdded)
    }

    /// Request review after onboarding completion (if eligible)
    @discardableResult
    func requestOnboardingReview() -> Bool {
        considerRequestingReview(context: .onboardingCompleted)
    }

    /// Evaluate on app launch if conditions are met
    func evaluateOnLaunch() {
        considerRequestingReview(context: .appLaunch)
    }

    // MARK: - Core Logic

    @discardableResult
    private func considerRequestingReview(context: ReviewContext) -> Bool {
        // Gate 1: Don't ask if shown recently
        guard daysSinceLastRequest() > daysBetweenRequests else {
            log("⏸️ Review skipped: Last request was \(daysSinceLastRequest()) days ago (need \(daysBetweenRequests))")
            return false
        }

        // Gate 2: Don't ask if already shown max times
        guard totalRequestCount() < maxLifetimeRequests else {
            log("⏸️ Review skipped: Already requested \(totalRequestCount()) times (max \(maxLifetimeRequests))")
            return false
        }

        // Gate 3: Check context-specific criteria
        guard meetsContextCriteria(context) else {
            log("⏸️ Review skipped: Context criteria not met for \(context)")
            return false
        }

        // All gates passed - schedule the review!
        log("✅ Review scheduled for context: \(context)")
        scheduleReviewRequest(context: context)
        return true
    }

    private func meetsContextCriteria(_ context: ReviewContext) -> Bool {
        switch context {
        case .montageExported:
            // Primary trigger: After 3rd montage export
            let count = getCount(for: .montageExportCount)
            let meets = count >= montageExportThreshold
            if meets {
                log("🎬 Montage export milestone reached: \(count)/\(montageExportThreshold)")
            }
            return meets

        case .projectCreated:
            // Secondary trigger: After 2nd project + at least 7 days since install
            let projectCount = getCount(for: .projectCreationCount)
            let daysSinceInstall = self.daysSinceInstall()
            let meets = projectCount >= projectCreationThreshold && daysSinceInstall >= minDaysSinceInstall
            if meets {
                log("📁 Project creation milestone reached: \(projectCount) projects, \(daysSinceInstall) days since install")
            }
            return meets

        case .appLaunch:
            // Fallback trigger: After 20 opens + 30 days + some engagement
            let openCount = getCount(for: .appOpenCount)
            let daysSinceInstall = self.daysSinceInstall()
            let hasEngagement = self.hasMinimalEngagement()
            let meets = openCount >= fallbackOpenCountThreshold &&
                       daysSinceInstall >= fallbackDaysSinceInstall &&
                       hasEngagement
            if meets {
                log("🚀 App launch milestone reached: \(openCount) opens, \(daysSinceInstall) days, engagement: \(hasEngagement)")
            }
            return meets

        case .montageViewed:
            // Bonus trigger: After viewing montages multiple times (shows value)
            let count = getCount(for: .montageViewCount)
            let meets = count >= montageViewThreshold
            if meets {
                log("👀 Montage view milestone reached: \(count)/\(montageViewThreshold)")
            }
            return meets

        case .clipsAdded:
            // Bonus trigger: After adding many clips (power user)
            let count = getCount(for: .clipAddedCount)
            let meets = count >= clipAddedThreshold
            if meets {
                log("🎥 Clips added milestone reached: \(count)/\(clipAddedThreshold)")
            }
            return meets

        case .onboardingCompleted:
            log("🎉 Onboarding completed")
            return true
        }
    }

    private func hasMinimalEngagement() -> Bool {
        // User has created at least 1 project AND exported at least 1 montage
        let projectCount = getCount(for: .projectCreationCount)
        let exportCount = getCount(for: .montageExportCount)
        return projectCount >= 1 && exportCount >= 1
    }

    private func scheduleReviewRequest(context: ReviewContext) {
        // Track the request
        recordRequestAttempt()

       // Log analytics
        MP.track(Event.reviewPromptTriggered, ["context": "\(context)"])

        // Use your existing ReviewTrigger mechanism
        ReviewTrigger.schedule()

        log("📝 Review request scheduled via ReviewTrigger")
    }

    // MARK: - Data Management

    private func incrementCount(for key: StatKey) {
        let current = getCount(for: key)
        UserDefaults.standard.set(current + 1, forKey: key.rawValue)
    }

    private func getCount(for key: StatKey) -> Int {
        return UserDefaults.standard.integer(forKey: key.rawValue)
    }

    private func ensureInstallDateRecorded() {
        if UserDefaults.standard.object(forKey: Keys.installDate) == nil {
            UserDefaults.standard.set(Date(), forKey: Keys.installDate)
        }
    }

    private func recordRequestAttempt() {
        UserDefaults.standard.set(Date(), forKey: Keys.lastRequestDate)
        let count = totalRequestCount() + 1
        UserDefaults.standard.set(count, forKey: Keys.totalRequestCount)
    }

    // MARK: - Getters

    private func daysSinceLastRequest() -> Int {
        guard let lastDate = UserDefaults.standard.object(forKey: Keys.lastRequestDate) as? Date else {
            return Int.max // Never requested before
        }
        return Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
    }

    private func totalRequestCount() -> Int {
        return UserDefaults.standard.integer(forKey: Keys.totalRequestCount)
    }

    private func daysSinceInstall() -> Int {
        guard let installDate = UserDefaults.standard.object(forKey: Keys.installDate) as? Date else {
            return 0
        }
        return Calendar.current.dateComponents([.day], from: installDate, to: Date()).day ?? 0
    }

    // MARK: - Stat Keys
    private enum StatKey: String {
        case montageExportCount = "reviewManager_montageExportCount"
        case projectCreationCount = "reviewManager_projectCreationCount"
        case appOpenCount = "reviewManager_appOpenCount"
        case montageViewCount = "reviewManager_montageViewCount"
        case clipAddedCount = "reviewManager_clipAddedCount"
    }

    // MARK: - Debug Helpers

    private func log(_ message: String) {
        #if DEBUG
        print("[ReviewManager] \(message)")
        #endif
    }

    /// Debug method to see current state
    func printDebugInfo() {
        print("""

        === ReviewManager Debug Info ===
        Days since install: \(daysSinceInstall())
        Days since last request: \(daysSinceLastRequest())
        Total requests made: \(totalRequestCount())/\(maxLifetimeRequests)

        Milestones:
        - App opens: \(getCount(for: .appOpenCount))
        - Montage exports: \(getCount(for: .montageExportCount))/\(montageExportThreshold)
        - Projects created: \(getCount(for: .projectCreationCount))/\(projectCreationThreshold)
        - Montages viewed: \(getCount(for: .montageViewCount))/\(montageViewThreshold)
        - Clips added: \(getCount(for: .clipAddedCount))/\(clipAddedThreshold)

        Has minimal engagement: \(hasMinimalEngagement())
        ================================

        """)
    }

    /// Debug method to reset all tracking (for testing only)
    func resetAllTracking() {
        #if DEBUG
        let keys = [
            Keys.lastRequestDate,
            Keys.totalRequestCount,
            Keys.montageExportCount,
            Keys.projectCreationCount,
            Keys.appOpenCount,
            Keys.installDate,
            Keys.montageViewCount,
            Keys.clipAddedCount
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        print("[ReviewManager] All tracking data reset")
        #endif
    }
}
