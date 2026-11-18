import Foundation
import Observation
import ServiceManagement

/// What the user chose in Settings, saved in UserDefaults. Views that read a
/// value redraw when it changes.
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let showPercentage = "menuBar.showPercentage"
        static let notifyLimitNotHolding = "notify.limitNotHolding"
        static let notifyFullCharge = "notify.fullCharge"
        static let notifyTopUpFinished = "notify.topUpFinished"
        static let notifyCalibrationFinished = "notify.calibrationFinished"
        static let sailingRange = "charging.sailingRange"
        static let heatProtection = "charging.heatProtection"
        static let heatThreshold = "charging.heatThreshold"
    }

    var showPercentage: Bool { didSet { save(showPercentage, Key.showPercentage) } }
    var notifyLimitNotHolding: Bool { didSet { save(notifyLimitNotHolding, Key.notifyLimitNotHolding) } }
    var notifyFullCharge: Bool { didSet { save(notifyFullCharge, Key.notifyFullCharge) } }
    var notifyTopUpFinished: Bool { didSet { save(notifyTopUpFinished, Key.notifyTopUpFinished) } }
    var notifyCalibrationFinished: Bool { didSet { save(notifyCalibrationFinished, Key.notifyCalibrationFinished) } }
    /// Percent the battery drifts below the limit before it charges again. 0 is off.
    var sailingRange: Int { didSet { save(sailingRange, Key.sailingRange) } }
    var heatProtection: Bool { didSet { save(heatProtection, Key.heatProtection) } }
    /// Degrees Celsius.
    var heatThreshold: Int { didSet { save(heatThreshold, Key.heatThreshold) } }

    /// Whether macOS opens Hachibu at login. macOS owns this; we only ask.
    private(set) var opensAtLogin = false
    /// Why the last change to "Open at login" failed, in words for the user.
    private(set) var loginItemProblem: String?

    private init() {
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        showPercentage = bool(Key.showPercentage, true)
        notifyLimitNotHolding = bool(Key.notifyLimitNotHolding, true)
        notifyFullCharge = bool(Key.notifyFullCharge, true)
        notifyTopUpFinished = bool(Key.notifyTopUpFinished, true)
        notifyCalibrationFinished = bool(Key.notifyCalibrationFinished, true)
        sailingRange = int(Key.sailingRange, 0)
        heatProtection = bool(Key.heatProtection, false)
        heatThreshold = int(Key.heatThreshold, 40)
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Test and snapshot runs never write preferences or touch login items.
    private func save(_ value: Any, _ key: String) {
        guard !Store.isOverridden else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func setOpensAtLogin(_ on: Bool) {
        guard !Store.isOverridden else { opensAtLogin = on; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemProblem = nil
        } catch {
            loginItemProblem = on ? "macOS did not add Hachibu to your login items. Try again from System Settings > General > Login Items."
                : "macOS did not remove Hachibu from your login items. Remove it in System Settings > General > Login Items."
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// What this build can do. Rows for features that are not built yet are
/// shown disabled and say so, never as controls that silently do nothing.
enum Capability {
    static let helper = false
}
