import Foundation
import UserNotifications

/// Notifications. Never sent in test runs.
enum Notifier {
    static func requestPermission() {
        guard !Store.isOverridden else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static func limitNotHolding(percent: Int, limit: Int) {
        guard !Store.isOverridden, Preferences.shared.notifyLimitNotHolding else { return }
        let content = UNMutableNotificationContent()
        content.title = "Limit not holding"
        content.body = "Battery is at \(percent)% and still charging. The limit is \(limit)%."
        let request = UNNotificationRequest(identifier: "limit-not-holding", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// macOS started charging to 100% on its own. Said once, so it is not
    /// mistaken for a limit that failed.
    static func fullChargeByMacOS(limit: Int) {
        guard !Store.isOverridden, Preferences.shared.notifyFullCharge else { return }
        let content = UNMutableNotificationContent()
        content.title = "Full charge by macOS"
        content.body = limit < 100
            ? "macOS is charging to 100% to keep its estimates accurate. Your limit of \(limit)% returns afterwards."
            : "macOS is charging to 100% to keep its estimates accurate."
        let request = UNNotificationRequest(identifier: "full-charge-by-macos", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
