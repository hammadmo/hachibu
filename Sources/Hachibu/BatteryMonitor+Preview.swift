import Foundation
import HachibuKit

/// The fixed popover states that snapshot runs capture.
enum PopoverPreview: String, CaseIterable {
    case holding, charging, warning, outside, unavailable
    /// A limit below 80%, held with the helper; and the same with the helper gone.
    case lowLimit = "low", helperMissing = "helper"
    case topUp = "topup", sailing
    /// macOS charging past the limit on its own.
    case fullCharge = "fullcharge"

    static let windowID = "popover-preview"
    static let windowTitle = "Hachibu Popover"

    /// The snapshot's file name.
    var page: String { self == .holding ? "popover" : "popover-\(rawValue)" }
}

extension BatteryMonitor {
    /// The monitor a snapshot page shows. Every value here is made up.
    static func preview(_ preview: PopoverPreview, helper: HelperState? = nil) -> BatteryMonitor {
        let holding = BatteryReading(percent: 80, isPluggedIn: true, currentMA: 0, voltageMV: 12_094,
                                     temperatureC: 34.7, cycleCount: 274, rawMaxCapacityMAh: 3556,
                                     designCapacityMAh: 4382, chargerWatts: 9.2, systemWatts: 7.2)
        var fixture = Fixture(reading: holding, limit: LimitState(system: 80, saved: 80))
        fixture.dayLevels = [58, 61, 66, 72, 78, 80, 80, 80, 80, 77, 74, 72, 75, 79, 80, 80, 80, 80, 80, 80]
        switch preview {
        case .holding:
            break
        case .charging:
            fixture.reading?.percent = 46
            fixture.reading?.currentMA = 1_950
            fixture.reading?.chargerWatts = 30.6
            // A first hour: nothing to chart yet.
            fixture.dayLevels = []
        case .warning:
            fixture.reading?.percent = 86
            fixture.reading?.currentMA = 1_650
            fixture.reading?.chargerWatts = 28.4
            fixture.reading?.temperatureC = 37.9
            fixture.isWarning = true
        case .outside:
            fixture.limit = LimitState(system: 80, saved: 85)
        case .unavailable:
            fixture.reading = nil
            fixture.limit = LimitState(system: nil, saved: nil)
            fixture.limitKnown = false
            fixture.dayLevels = []
        case .topUp:
            fixture.reading?.percent = 88
            fixture.reading?.currentMA = 1_720
            fixture.reading?.chargerWatts = 29.8
            fixture.limit = LimitState(system: nil, saved: 80)
            fixture.mode = .toppingUp
            fixture.overrideLimit = 100
            fixture.limitBeforeOverride = 80
        case .sailing:
            fixture.reading?.percent = 77
            fixture.limit = LimitState(system: 77, saved: 80)
            fixture.isSailing = true
            fixture.overrideLimit = 77
            fixture.limitBeforeOverride = 80
            // The caption reads the range from the test run's own settings.
            if Store.isOverridden { Preferences.shared.sailingRange = 5 }
        case .fullCharge:
            fixture.reading?.percent = 91
            fixture.reading?.currentMA = 1_480
            fixture.reading?.chargerWatts = 27.6
            fixture.reading?.fullChargeOverride = true
        case .lowLimit, .helperMissing:
            fixture.reading?.percent = 70
            fixture.limit = LimitState(system: 70, saved: 70)
            fixture.dayLevels = fixture.dayLevels.map { $0 - 10 }
        }
        fixture.helper = helper ?? (preview == .lowLimit || preview == .sailing ? .running : .notInstalled)
        return BatteryMonitor(fixture: fixture)
    }
}
