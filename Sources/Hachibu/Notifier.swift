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
        // Said without a promise about the limit: a Top Up or a calibration
        // may be deciding that, not this full charge.
        content.body = limit < 100
            ? "macOS is charging past your \(limit)% limit to keep its estimates accurate. Nothing is wrong with the limit."
            : "macOS is charging to 100% to keep its estimates accurate."
        let request = UNNotificationRequest(identifier: "full-charge-by-macos", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    static func calibrationFinished(limit: Int) {
        guard !Store.isOverridden, Preferences.shared.notifyCalibrationFinished else { return }
        let content = UNMutableNotificationContent()
        content.title = "Calibration finished"
        content.body = limit < 100 ? "Your limit of \(limit)% is back. macOS drains the battery down to it."
            : "The battery is full and there is no limit."
        let request = UNNotificationRequest(identifier: "calibration-finished", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
