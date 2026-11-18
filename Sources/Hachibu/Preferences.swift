import Foundation
import Observation
import ServiceManagement

/// What the user chose, saved in UserDefaults. Views that read a value
/// redraw when it changes. Test runs use a separate, throwaway domain.
@Observable
final class Preferences {
    static let shared = Preferences()
    static let testSuite = "app.hachibu.mac.test"

    enum Key {
        static let savedLimit = "limit.saved"
        static let showPercentage = "menuBar.showPercentage"
        static let notifyLimitNotHolding = "notify.limitNotHolding"
        static let notifyFullCharge = "notify.fullCharge"
        static let notifyTopUpFinished = "notify.topUpFinished"
        static let notifyCalibrationFinished = "notify.calibrationFinished"
        static let sailingRange = "charging.sailingRange"
        static let heatProtection = "charging.heatProtection"
        static let heatThreshold = "charging.heatThreshold"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The limit the user last chose in Hachibu. nil before the first choice.
    var savedLimit: Int? {
        didSet {
            if let savedLimit { defaults.set(savedLimit, forKey: Key.savedLimit) } else { defaults.removeObject(forKey: Key.savedLimit) }
        }
    }
    var showPercentage: Bool { didSet { defaults.set(showPercentage, forKey: Key.showPercentage) } }
    var notifyLimitNotHolding: Bool { didSet { defaults.set(notifyLimitNotHolding, forKey: Key.notifyLimitNotHolding) } }
    var notifyFullCharge: Bool { didSet { defaults.set(notifyFullCharge, forKey: Key.notifyFullCharge) } }
    var notifyTopUpFinished: Bool { didSet { defaults.set(notifyTopUpFinished, forKey: Key.notifyTopUpFinished) } }
    var notifyCalibrationFinished: Bool { didSet { defaults.set(notifyCalibrationFinished, forKey: Key.notifyCalibrationFinished) } }
    /// Percent the battery drifts below the limit before it charges again. 0 is off.
    var sailingRange: Int { didSet { defaults.set(sailingRange, forKey: Key.sailingRange) } }
    var heatProtection: Bool { didSet { defaults.set(heatProtection, forKey: Key.heatProtection) } }
    /// Degrees Celsius.
    var heatThreshold: Int { didSet { defaults.set(heatThreshold, forKey: Key.heatThreshold) } }

    /// Whether macOS opens Hachibu at login. macOS owns this; we only ask.
    private(set) var opensAtLogin = false
    /// Why the last change to "Open at login" failed, in words for the user.
    private(set) var loginItemProblem: String?

    private init() {
        if Store.isOverridden {
            // A fresh, separate domain for every test run.
            UserDefaults.standard.removePersistentDomain(forName: Self.testSuite)
            defaults = UserDefaults(suiteName: Self.testSuite) ?? .standard
        } else {
            defaults = .standard
        }
        let store = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { store.object(forKey: key) as? Int ?? fallback }
        savedLimit = store.object(forKey: Key.savedLimit) as? Int
        showPercentage = bool(Key.showPercentage, true)
        notifyLimitNotHolding = bool(Key.notifyLimitNotHolding, true)
        notifyFullCharge = bool(Key.notifyFullCharge, true)
        notifyTopUpFinished = bool(Key.notifyTopUpFinished, true)
        notifyCalibrationFinished = bool(Key.notifyCalibrationFinished, true)
        sailingRange = int(Key.sailingRange, 0)
        heatProtection = bool(Key.heatProtection, false)
        heatThreshold = int(Key.heatThreshold, 40)
        opensAtLogin = !Store.isOverridden && SMAppService.mainApp.status == .enabled
    }

    /// Reads a saved value straight from the store, for the self-test.
    func storedValue(_ key: String) -> Any? {
        defaults.synchronize()
        return defaults.object(forKey: key)
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
nonisolated enum Capability {
    /// Sailing between two levels (story S-022).
    static let sailing = false
    /// Pausing charging when the battery is hot (story S-040).
    static let heatProtection = false
    /// Recording battery samples for the History window (story S-031).
    static let history = false
}
