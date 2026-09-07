import Foundation
import UserNotifications

@MainActor
final class RewindNotificationCoordinator {

    static let shared = RewindNotificationCoordinator()

    private init() {}

    func evaluateAndScheduleIfNeeded() {
        Task {
            // 1) Only proceed if we ALREADY have notification permission.
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break   // OK to schedule
            default:
                print("[RewindNotif] No notification permission yet — skipping Rewind scheduling.")
                return
            }

            // 2) Build the next 7 calendar dates (today + 6 more)
            let calendar = Calendar.current
            let now = Date()
            var upcomingDates: [Date] = []
            for offset in 0..<7 {
                if let date = calendar.date(byAdding: .day, value: offset, to: now) {
                    upcomingDates.append(date)
                }
            }

            // 3) Compute clip counts per day
            var datesWithCounts: [(date: Date, count: Int)] = []
            for date in upcomingDates {
                let count = clipCount(on: date)
                if count > 0 {
                    datesWithCounts.append((date, count))
                }
            }
            print("[RewindNotif] upcoming dates with Rewind =", datesWithCounts)

            // 4) Clear previous day-based Rewind notifications
            await NotificationManager.clearAllDayBasedRewindNotifications()

            // 5) Schedule notifs for qualifying days
            for (date, count) in datesWithCounts {
                await NotificationManager.scheduleRewindNotification(
                    for: date,
                    clipCount: count,
                    atHour: 9,
                    minute: 0
                )
            }
        }
    }


    /// Total number of clips across all past years for this date's month/day.
    private func clipCount(on date: Date) -> Int {
        let calendar = Calendar.current
        let targetYear = calendar.component(.year, from: date)

        // Reuse the same summary logic RewindView uses:
        // buildEntriesFromPhotos creates one entry per year with clipCount.
        let entries = RewindEngine.buildEntriesFromPhotos(today: date, calendar: calendar)

        return entries
            .filter { $0.year < targetYear }     // only past years
            .map { $0.clipCount }
            .reduce(0, +)
    }

    /// Simple wrapper if you still need a boolean anywhere else.
    private func hasRewind(on date: Date) -> Bool {
        clipCount(on: date) > 0
    }
}
