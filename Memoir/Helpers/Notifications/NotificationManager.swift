import Foundation
import UserNotifications
import SwiftUI

public enum NotificationMode: String, CaseIterable, Identifiable {
    case off, standard, timeSensitive
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off:           return "Off"
        case .standard:      return "Standard"
        case .timeSensitive: return "Time-Sensitive"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "No reminders."
        case .standard:
            return "Delivered at your chosen time. May be silenced by Focus."
        case .timeSensitive:
            return "Delivered promptly and can bypass Focus."
        }
    }
}

public enum NotificationManager {
    static let dailyID = "snapsecond.daily.nudge"
    private static let dailyTitle = "Snap Second"
    private static let dailyBody = "Don't forget to capture your second of the day"
    private static let dailyIDPrefix = "snapsecond.daily.nudge.day"
    static let rewindID = "snapsecond.rewind.nudge"
    static let trialExpiryID = "snapsecond.trial.expiry.nudge"

    // Used for per-day Rewind notifications (e.g. "snapsecond.rewind.2025-11-19")
    private static let rewindIDPrefix = "snapsecond.rewind.day"

    private static func clearAllDailyNotifications() async {
        let center = UNUserNotificationCenter.current()
        let all = await center.pendingNotificationRequests()
        let idsToRemove = all
            .map(\.identifier)
            .filter { $0 == dailyID || $0.hasPrefix(dailyIDPrefix) }
        guard !idsToRemove.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: idsToRemove)
    }

    private static func rewindID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dayString = formatter.string(from: date)
        return "\(rewindIDPrefix).\(dayString)"
    }

    /// Register category + actions (Open / Snooze)
    public static func registerCategories() {
        let open   = UNNotificationAction(identifier: "snapsecond.open", title: "Open Snap Second", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snapsecond.snooze10", title: "Snooze 10 min", options: [])
        let cat = UNNotificationCategory(
            identifier: "snapsecond.reminder",
            actions: [open, snooze],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    /// Request authorization, covering Standard & Time-Sensitive on iOS 15+
    @discardableResult
    public static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                if #available(iOS 15.0, *) {
                    let ok = try await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
                    if ok { registerCategories() }
                    return ok
                } else {
                    let ok = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    if ok { registerCategories() }
                    return ok
                }
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Schedule (or remove) the daily reminder based on mode + time.
    public static func apply(mode: NotificationMode, hour: Int, minute: Int) async {
        let center = UNUserNotificationCenter.current()
        await clearAllDailyNotifications()

        guard mode != .off else { return }

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        let content = UNMutableNotificationContent()
        content.title = dailyTitle
        content.body = dailyBody
        content.sound = .default
        content.categoryIdentifier = "snapsecond.reminder"
        if #available(iOS 15.0, *), mode == .timeSensitive {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let req = UNNotificationRequest(identifier: dailyID, content: content, trigger: trigger)
        do { try await center.add(req) } catch { print("Notification add error:", error) }
    }

    /// Schedule a one-off "Rewind is ready" notification for a specific morning time.
       /// We'll call this from app lifecycle code once we know today's Rewind should exist.
       public static func scheduleRewindMorningNotification(
           atHour hour: Int = 9,
           minute: Int = 0
       ) async {
           let center = UNUserNotificationCenter.current()

           // Avoid stacking multiple Rewind notifications.
           await center.removePendingNotificationRequests(withIdentifiers: [rewindID])

           var comps = DateComponents()
           comps.hour = hour
           comps.minute = minute

           let content = UNMutableNotificationContent()
           content.title = "Your rewind for today is ready!"
           content.body  = "Look back on memories from this day in past years."
           content.sound = .default
           content.categoryIdentifier = "snapsecond.reminder" // reuse your existing category/actions

           // One-off fire at the next date matching these components.
           // (If we're already past that time today, iOS will schedule it for the next matching day.)
           let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

           let req = UNNotificationRequest(identifier: rewindID, content: content, trigger: trigger)
           do {
               try await center.add(req)
           } catch {
               print("Rewind morning notification add error:", error)
           }
       }

    /// Remove all pending day-based Rewind notifications (those using our prefix).
    public static func clearAllDayBasedRewindNotifications() async {
        let center = UNUserNotificationCenter.current()
        let all = await center.pendingNotificationRequests()

        let idsToRemove = all
            .map(\.identifier)
            .filter { $0.hasPrefix(rewindIDPrefix) }

        guard !idsToRemove.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: idsToRemove)
        print("🔔 Cleared day-based Rewind notifications:", idsToRemove)
    }

    public static func scheduleRewindNotification(
            for date: Date,
            clipCount: Int,
            atHour hour: Int = 9,
            minute: Int = 0
        ) async {
            let center = UNUserNotificationCenter.current()
            let calendar = Calendar.current

            var comps = calendar.dateComponents([.year, .month, .day], from: date)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0

            let content = UNMutableNotificationContent()

            // Pluralization for the body text
            let clipText = (clipCount == 1) ? "1 moment" : "\(clipCount) moments"

            content.title = "Look back on this day"
            content.body  = "Revisit your \(clipText) from this date in past years."
            content.sound = .default
            content.categoryIdentifier = "snapsecond.reminder" // reuse existing category/actions

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = rewindID(for: date)

            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            do {
                try await center.add(request)
                print("🔔 Scheduled Rewind notif:", id, "for components:", comps, "clipCount:", clipCount)
            } catch {
                print("⚠️ Failed to schedule Rewind notif for \(date):", error)
            }
        }



    /// iOS 15+: whether Time-Sensitive is allowed at the OS level (iOS 18 hides the per-app toggle).
    @available(iOS 15.0, *)
    public static func isTimeSensitiveAllowed() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.timeSensitiveSetting != .disabled
    }

    public static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Schedules a one-off reminder one day before trial expiration.
    /// This does not prompt for notification permission; it only schedules when already authorized.
    public static func scheduleTrialExpiryNotification(expirationDate: Date) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [trialExpiryID])

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }

        guard let triggerDate = Calendar.current.date(byAdding: .day, value: -1, to: expirationDate),
              triggerDate > Date() else {
            return
        }

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: triggerDate)
        comps.hour = 10
        comps.minute = 0
        comps.second = 0

        let content = UNMutableNotificationContent()
        content.title = "Your free trial ends tomorrow"
        content.body = "Keep Snap Second Pro to continue unlimited journals, HD export, and more."
        content.sound = .default
        content.categoryIdentifier = "snapsecond.reminder"

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: trialExpiryID, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            print("⚠️ Failed to schedule trial expiry notification:", error)
        }
    }

    public static func clearTrialExpiryNotification() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [trialExpiryID])
    }
}
