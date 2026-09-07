import UIKit
import UserNotifications

final class MemoirNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MemoirNotificationDelegate()

    // Show a normal banner + sound even when the app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Handle actions (Open / Snooze)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case "memoir.snooze10":
            let content = (response.notification.request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10*60, repeats: false)
            let req = UNNotificationRequest(identifier: "memoir.reminder.snooze", content: content, trigger: trigger)
            center.add(req)
        default:
            break
        }
        completionHandler()
    }
}
