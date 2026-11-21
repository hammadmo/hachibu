import Foundation
import HachibuKit
import UserNotifications

/// Notifications. Never sent in test runs. The words, and whether a kind
/// is switched on, are in `Notice`.
enum Notifier {
    /// Not in a command-line run that does one thing and quits: it has
    /// nothing to announce, and must not put macOS's prompt on screen.
    static func requestPermission() {
        guard !Store.isOverridden, !Launch.isOneShot else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static func send(_ notice: Notice) {
        guard !Store.isOverridden, let message = notice.message(allowed: Preferences.shared.allowedNotices) else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        let request = UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
