import Foundation

/// Cross-process "refresh now" signal. The widget's refresh button (an AppIntent running in the
/// widget extension) posts it; the always-running menu-bar agent observes it and does a live fetch,
/// then rewrites the snapshot and reloads the widget. Uses a Darwin notification so it crosses the
/// app/extension process boundary without any shared entitlement. Strictly a "please refresh"
/// ping — it carries no data and touches no credentials.
public enum RefreshSignal {
    private static let darwinName = "com.claudeusage.refresh" as CFString

    /// A local (in-process) notification the agent listens for, bridged from the Darwin signal.
    public static let didRequestRefresh = Notification.Name("ClaudeUsageDidRequestRefresh")

    /// Post from the widget/extension to ask the running agent to refresh.
    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName), nil, nil, true)
    }

    /// Call once in the agent to start bridging the Darwin signal to `didRequestRefresh`.
    public static func startObserving() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                // No captures here (required for a C callback): post a plain in-process notification.
                NotificationCenter.default.post(
                    name: Notification.Name("ClaudeUsageDidRequestRefresh"), object: nil)
            },
            darwinName, nil, .deliverImmediately)
    }
}
