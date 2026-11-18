import Foundation
import Observation

/// App-wide state that windows and menus share.
@Observable
final class AppModel {
    /// Settings reopens on the last tab. Test and snapshot runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    var historyRange: HistoryRange = .day
    /// Snapshot runs raise this to make the History window load again.
    var historyLoad = 0
    /// Snapshot runs switch this to sample data.
    var historyPreview: HistoryPreview = .recorded
    /// Which fixed state the popover preview window shows (snapshot runs).
    var popoverPreview: PopoverPreview = .holding
    /// The fixed battery and helper state Settings shows in snapshot runs.
    var settingsPreview: BatteryMonitor?
    /// The dialog that says how to allow the helper in Login Items.
    var showingHelperApproval = false
    /// The dialog that explains a calibration before it starts, or shows
    /// its steps while it runs.
    var showingCalibration = false
    /// The Helper tab is asking "Remove the helper?".
    var confirmingHelperRemoval = false
}

/// Test, snapshot, and self-test runs set APP_STORE to a file in /tmp. In
/// those runs Hachibu never writes real preferences, never registers login
/// items, never sends notifications, and never changes the real charge limit.
nonisolated enum Store {
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }
}
