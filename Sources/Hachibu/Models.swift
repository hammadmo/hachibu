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
    /// Snapshot runs switch this to sample data.
    var historyPreview: HistoryPreview = .recorded
    /// Which fixed state the popover preview window shows (snapshot runs).
    var popoverPreview: PopoverPreview = .holding
    /// The fixed battery and helper state Settings shows in snapshot runs.
    var settingsPreview: BatteryMonitor?
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
