import UIKit
import UserNotifications

/// Tells the user when downloads finish or fail while the app isn't in front: a notification,
/// and a badge on the app icon that clears when the app is opened.
final class DownloadNotifier {
    private let isEnabled: () -> Bool
    private var askedForPermission = false
    private var badgeCount = 0

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    /// Asks once, when the first download starts, so the question comes with context. (Not in UI
    /// tests: the system alert would sit over the app.)
    func prepare() {
        guard isEnabled(), !askedForPermission, !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        askedForPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func stateChanged(_ item: DownloadItem) {
        guard isEnabled(), UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        switch item.record.state {
        case .finished:
            content.title = "Download Finished"
            content.body = item.record.fileName
        case .failed:
            content.title = "Download Didn't Finish"
            content.body = [item.record.fileName, item.record.failureReason].compactMap { $0 }.joined(separator: " — ")
        default:
            return
        }
        badgeCount += 1
        content.sound = .default
        content.threadIdentifier = "downloads"
        content.badge = NSNumber(value: badgeCount)
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// The app is in front again: the badge has done its job.
    func clearBadge() {
        guard badgeCount > 0 else { return }
        badgeCount = 0
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}
