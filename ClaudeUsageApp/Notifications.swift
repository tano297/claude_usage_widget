import Foundation
import UserNotifications

/// Thin UNUserNotificationCenter wrapper — all crossing logic lives in ThresholdPlanner; this
/// just requests permission and posts. It must run in the agent app: the always-resident,
/// properly bundled process (UNUserNotificationCenter refuses unbundled binaries, which is why
/// notification testing needs the installed /Applications copy, not a bare debug executable).
@MainActor
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPoster()

    private var didRequestAuth = false

    /// Idempotent: installs the delegate and asks for permission once per process.
    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard !didRequestAuth else { return }
        didRequestAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("ClaudeUsage: notification authorization failed: \(error.localizedDescription)") }
        }
    }

    /// Whether the user has explicitly declined notifications (drives the settings hint in the menu).
    nonisolated func authorizationDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func post(_ alerts: [ThresholdAlert]) {
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.threadIdentifier = alert.key   // group each window's alerts together
            // Stable id per window+bucket: a re-fire of the same threshold replaces, not stacks.
            center.add(UNNotificationRequest(identifier: "\(alert.key)-\(alert.bucket)",
                                             content: content, trigger: nil))
        }
    }

    // Show banners even when the agent is the frontmost app (menu popover open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
