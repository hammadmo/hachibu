import Foundation

/// One look at the battery. Everything on screen is derived from this, so
/// the app can never claim something the numbers contradict.
public struct BatteryReading: Equatable, Sendable {
    /// 0 to 100.
    public var percent: Int
    public var isPluggedIn: Bool
    /// Milliamps into the battery. Negative while it discharges.
    public var currentMA: Int
    public var voltageMV: Int?
    public var temperatureC: Double?
    public var cycleCount: Int?
    public var rawMaxCapacityMAh: Int?
    public var designCapacityMAh: Int?
    /// Watts coming in from the charger.
    public var chargerWatts: Double?
    /// Watts the Mac is using.
    public var systemWatts: Double?
    /// macOS is charging to 100% on its own to keep its estimates accurate.
    public var fullChargeOverride: Bool

    public init(percent: Int, isPluggedIn: Bool, currentMA: Int, voltageMV: Int? = nil,
                temperatureC: Double? = nil, cycleCount: Int? = nil, rawMaxCapacityMAh: Int? = nil,
                designCapacityMAh: Int? = nil, chargerWatts: Double? = nil, systemWatts: Double? = nil,
                fullChargeOverride: Bool = false) {
        self.percent = min(max(percent, 0), 100)
        self.isPluggedIn = isPluggedIn
        self.currentMA = currentMA
        self.voltageMV = voltageMV
        self.temperatureC = temperatureC
        self.cycleCount = cycleCount
        self.rawMaxCapacityMAh = rawMaxCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.chargerWatts = chargerWatts
        self.systemWatts = systemWatts
        self.fullChargeOverride = fullChargeOverride
    }

    /// Below this, current into the battery is treated as noise, not charging.
    public static let chargingThresholdMA = 50

    /// Current is really flowing into the battery.
    public var isCharging: Bool { isPluggedIn && currentMA > Self.chargingThresholdMA }

    /// Maximum capacity now, as a percent of the design capacity.
    public var healthPercent: Int? {
        guard let raw = rawMaxCapacityMAh, let design = designCapacityMAh, design > 0, raw > 0 else { return nil }
        return min(Int((Double(raw) / Double(design) * 100).rounded()), 100)
    }

    /// Watts into the battery. Negative while it discharges.
    public var batteryWatts: Double? {
        voltageMV.map { Double($0) * Double(currentMA) / 1_000_000 }
    }
}

/// What the battery is doing, in the glossary's words.
public enum BatteryStatus: Equatable, Sendable {
    case charging, holdingAtLimit, fullyCharged, notCharging, usingBattery, onBattery, fullChargeByMacOS
    /// The three things Hachibu does on request or by a setting.
    case toppingUp, discharging, sailing

    /// How close to the limit still counts as holding at it.
    public static let holdingMargin = 2

    /// The status while a mode is active. A mode names what Hachibu is
    /// doing; the watts beside it are still the measured ones.
    public static func derive(from reading: BatteryReading, limit: Int?, mode: ChargeMode,
                              isSailing: Bool) -> BatteryStatus {
        switch mode {
        case .toppingUp: return reading.fullChargeOverride ? .fullChargeByMacOS : .toppingUp
        case .discharging: return .discharging
        case .normal, .calibrating:
            let plain = derive(from: reading, limit: limit)
            // Sailing is only said while nothing flows into the battery.
            return isSailing && (plain == .holdingAtLimit || plain == .notCharging) ? .sailing : plain
        }
    }

    public static func derive(from reading: BatteryReading, limit: Int?) -> BatteryStatus {
        guard reading.isPluggedIn else { return .onBattery }
        if reading.isCharging { return reading.fullChargeOverride ? .fullChargeByMacOS : .charging }
        // Plugged in, yet power is coming out of the battery: macOS is
        // draining it toward the limit, or the charger cannot keep up.
        if reading.currentMA < -BatteryReading.chargingThresholdMA { return .usingBattery }
        if let limit, limit < 100, abs(reading.percent - limit) <= holdingMargin { return .holdingAtLimit }
        return reading.percent >= 99 ? .fullyCharged : .notCharging
    }

    public var title: String {
        switch self {
        case .charging: "Charging"
        case .holdingAtLimit: "Holding at limit"
        case .fullyCharged: "Fully charged"
        case .notCharging: "Not charging"
        case .usingBattery: "Using battery"
        case .onBattery: "On battery"
        case .fullChargeByMacOS: "Full charge by macOS"
        case .toppingUp: "Topping up"
        case .discharging: "Discharging"
        case .sailing: "Sailing"
        }
    }

    /// The measured power, next to the status. A missing value is a dash, never a false 0.
    public func detail(for reading: BatteryReading) -> String {
        switch self {
        case .onBattery, .discharging:
            let out = reading.systemWatts ?? reading.batteryWatts.map(abs)
            return "\(Watts.text(out)) out"
        case .usingBattery:
            return "\(Watts.text(reading.batteryWatts.map(abs))) from battery, charger connected"
        case .fullChargeByMacOS:
            return "macOS is charging past your limit to keep its estimates accurate"
        case .charging, .holdingAtLimit, .fullyCharged, .notCharging, .toppingUp, .sailing:
            return "\(Watts.text(reading.chargerWatts)) from charger"
        }
    }
}
