import Foundation
import HachibuKit
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
        static let checksForUpdates = "updates.automatic"
        static let topUpShortcut = "shortcut.topUp"
        static let sailingRange = "charging.sailingRange"
        static let sailingHold = "charging.sailingHold"
        static let modeAsk = "charging.modeAsk"
        static let modeUser = "charging.modeUser"
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
    /// Control-Option-Command-T starts or stops a Top Up from any app.
    /// Change it with `setTopUpShortcut`, which asks macOS for the keys.
    private(set) var topUpShortcut: Bool { didSet { defaults.set(topUpShortcut, forKey: Key.topUpShortcut) } }
    /// Why the shortcut could not be switched on, in words for the user.
    private(set) var shortcutProblem: String?

    /// Switches the shortcut on or off. When macOS will not give Hachibu
    /// the keys, the switch stays off and the row says why, so it never
    /// looks on while doing nothing. Also called at launch for a shortcut
    /// that was on.
    func setTopUpShortcut(_ isOn: Bool) {
        let registered = TopUpShortcut.set(enabled: isOn)
        shortcutProblem = isOn && !registered ? "macOS did not give Hachibu \(TopUpShortcut.keys). Another app may be using it." : nil
        topUpShortcut = isOn && registered
    }
    /// Hachibu asks once a day whether there is a newer version.
    var checksForUpdates: Bool {
        didSet {
            defaults.set(checksForUpdates, forKey: Key.checksForUpdates)
            Updates.shared.setAutomatic(checksForUpdates)
        }
    }
    /// Percent the battery drifts below the limit before it charges again. 0 is off.
    var sailingRange: Int { didSet { defaults.set(sailingRange, forKey: Key.sailingRange) } }
    /// The level sailing last asked macOS to hold. nil when none. Kept so
    /// the next launch can tell its own hold from a limit set elsewhere.
    var sailingHold: Int? {
        didSet {
            if let sailingHold { defaults.set(sailingHold, forKey: Key.sailingHold) } else { defaults.removeObject(forKey: Key.sailingHold) }
        }
    }
    /// The limit a Top Up or a calibration last asked macOS for, and (in
    /// `modeUser`) the user's limit it stood in for. Both nil when the
    /// user's limit is confirmed back. If Hachibu stops before that, the
    /// next launch finds them and puts the limit back.
    var modeAsk: Int? {
        didSet {
            if let modeAsk { defaults.set(modeAsk, forKey: Key.modeAsk) } else { defaults.removeObject(forKey: Key.modeAsk) }
        }
    }
    var modeUser: Int? {
        didSet {
            if let modeUser { defaults.set(modeUser, forKey: Key.modeUser) } else { defaults.removeObject(forKey: Key.modeUser) }
        }
    }
    var heatProtection: Bool { didSet { defaults.set(heatProtection, forKey: Key.heatProtection) } }
    /// Degrees Celsius.
    var heatThreshold: Int { didSet { defaults.set(heatThreshold, forKey: Key.heatThreshold) } }

    /// The kinds of notification left switched on.
    var allowedNotices: Set<Notice.Kind> {
        var kinds = Set<Notice.Kind>()
        if notifyLimitNotHolding { kinds.insert(.limitNotHolding) }
        if notifyFullCharge { kinds.insert(.fullCharge) }
        if notifyTopUpFinished { kinds.insert(.topUpFinished) }
        if notifyCalibrationFinished { kinds.insert(.calibrationFinished) }
        return kinds
    }

    /// What a mode last asked macOS for, as one value. Kept in the three
    /// settings above, so a note written by an earlier build still reads.
    var modeRecord: ModeRecord? {
        get {
            if let modeAsk, let modeUser { return ModeRecord(asked: modeAsk, user: modeUser, isSailingHold: false) }
            if let sailingHold { return ModeRecord(asked: sailingHold, user: savedLimit ?? sailingHold, isSailingHold: true) }
            return nil
        }
        set {
            modeAsk = newValue.flatMap { $0.isSailingHold ? nil : $0.asked }
            modeUser = newValue.flatMap { $0.isSailingHold ? nil : $0.user }
            sailingHold = newValue.flatMap { $0.isSailingHold ? $0.asked : nil }
        }
    }

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
        checksForUpdates = bool(Key.checksForUpdates, true)
        topUpShortcut = bool(Key.topUpShortcut, false)
        sailingRange = int(Key.sailingRange, 0)
        sailingHold = store.object(forKey: Key.sailingHold) as? Int
        modeAsk = store.object(forKey: Key.modeAsk) as? Int
        modeUser = store.object(forKey: Key.modeUser) as? Int
        heatProtection = bool(Key.heatProtection, false)
        heatThreshold = min(max(int(Key.heatThreshold, ChargeEngine.heatDefault), ChargeEngine.heatRange.lowerBound),
                            ChargeEngine.heatRange.upperBound)
        opensAtLogin = !Store.isOverridden && SMAppService.mainApp.status == .enabled
    }

    /// Takes the saved limit from the store again, in case another copy of
    /// Hachibu (the command line) changed it.
    func reloadSavedLimit() {
        let stored = defaults.object(forKey: Key.savedLimit) as? Int
        if stored != savedLimit { savedLimit = stored }
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
    static let sailing = true
    /// Pausing charging when the battery is hot (story S-040).
    static let heatProtection = true
    /// Recording battery samples for the History window (story S-031).
    static let history = true
}
