import Foundation

/// What Hachibu is doing on top of plain "hold the limit".
public enum ChargeMode: String, Equatable, Sendable {
    case normal
    /// Charging to 100% once; the limit returns afterwards.
    case toppingUp
    /// Running on the battery while plugged in, down to the limit.
    case discharging
    /// A guided full cycle (story S-042). Nothing starts it yet.
    case calibrating
}

/// Why a Top Up or a Discharge ended.
public enum ModeEnd: Equatable, Sendable {
    case reachedFull, reachedLimit, reachedFloor, unplugged, stopped, helperLost
}

/// What the engine looks at on every reading.
public struct ChargeInputs: Equatable, Sendable {
    public var percent: Int
    /// A charger is attached, even while Hachibu holds it disconnected.
    public var chargerAttached: Bool
    /// The user's limit. 100 means none.
    public var limit: Int
    /// Percent the battery drifts below the limit before charging again. 0 is off.
    public var sailingRange: Int
    public var helperRunning: Bool

    public init(percent: Int, chargerAttached: Bool, limit: Int, sailingRange: Int = 0, helperRunning: Bool = false) {
        self.percent = percent
        self.chargerAttached = chargerAttached
        self.limit = limit
        self.sailingRange = sailingRange
        self.helperRunning = helperRunning
    }
}

/// What should be true right now.
public struct ChargePlan: Equatable, Sendable {
    public var mode: ChargeMode
    /// The limit macOS should hold. 100 means none.
    public var limit: Int
    /// The charger should be held disconnected.
    public var adapterCut: Bool
    /// Plugged in and drifting down inside the sailing range.
    public var isSailing: Bool

    public init(mode: ChargeMode, limit: Int, adapterCut: Bool = false, isSailing: Bool = false) {
        self.mode = mode
        self.limit = limit
        self.adapterCut = adapterCut
        self.isSailing = isSailing
    }
}

/// Decides, from each reading, which limit macOS should hold and whether
/// the charger should be cut. It changes nothing itself: BatteryMonitor
/// carries the plan out.
public struct ChargeEngine: Equatable, Sendable {
    /// Discharge never goes below this, whatever the limit.
    public static let dischargeFloor = 20

    public internal(set) var mode = ChargeMode.normal
    /// Why the last Top Up or Discharge ended. Cleared when one starts.
    public private(set) var lastEnd: ModeEnd?
    /// Sailing: true while charging back up to the limit.
    public private(set) var isRecharging = false
    private var sailingStarted = false

    public init() {}

    // MARK: Starting and stopping

    /// Starts a Top Up. Returns why not, in words for the user, or nil.
    public mutating func startTopUp(_ inputs: ChargeInputs) -> String? {
        guard mode == .normal else { return "Stop the current mode first." }
        guard inputs.chargerAttached else { return "Connect the charger to top up." }
        guard inputs.percent < 100 else { return "The battery is already full." }
        mode = .toppingUp
        lastEnd = nil
        return nil
    }

    /// Starts a Discharge. Returns why not, in words for the user, or nil.
    public mutating func startDischarge(_ inputs: ChargeInputs) -> String? {
        guard mode == .normal else { return "Stop the current mode first." }
        guard inputs.helperRunning else { return "Discharge needs the helper." }
        guard inputs.chargerAttached else { return "The Mac is already running on the battery." }
        guard inputs.percent > inputs.limit else { return "The battery is already at or below the limit." }
        guard inputs.percent > Self.dischargeFloor else { return "The battery is too low to discharge." }
        mode = .discharging
        lastEnd = nil
        return nil
    }

    public mutating func stop() {
        end(.stopped)
    }

    private mutating func end(_ reason: ModeEnd) {
        guard mode != .normal else { return }
        mode = .normal
        lastEnd = reason
        // Whatever the mode did to the level, sailing starts over from it.
        sailingStarted = false
    }

    // MARK: Each reading

    public mutating func step(_ inputs: ChargeInputs) -> ChargePlan {
        switch mode {
        case .toppingUp:
            if !inputs.chargerAttached { end(.unplugged) } else if inputs.percent >= 100 { end(.reachedFull) }
        case .discharging:
            if !inputs.helperRunning { end(.helperLost) }
            else if !inputs.chargerAttached { end(.unplugged) }
            else if inputs.percent <= inputs.limit { end(.reachedLimit) }
            else if inputs.percent <= Self.dischargeFloor { end(.reachedFloor) }
        case .normal, .calibrating:
            break
        }
        switch mode {
        case .toppingUp, .calibrating:
            return ChargePlan(mode: mode, limit: 100)
        case .discharging:
            return ChargePlan(mode: mode, limit: inputs.limit, adapterCut: true)
        case .normal:
            return sailing(inputs)
        }
    }

    /// The charger must be reconnected before the Mac sleeps, in every mode.
    public func planForSleep(_ inputs: ChargeInputs) -> ChargePlan {
        var copy = self
        var plan = copy.step(inputs)
        plan.adapterCut = false
        return plan
    }

    // MARK: Sailing

    /// With a sailing range, the battery is not charged back to the limit
    /// until it has drifted down by the whole range. Between the two levels
    /// macOS is asked to hold the level the battery is at.
    private mutating func sailing(_ inputs: ChargeInputs) -> ChargePlan {
        let limit = inputs.limit
        let range = min(max(inputs.sailingRange, 0), limit - HelperRequest.limitRange.lowerBound)
        guard range > 0, inputs.helperRunning else {
            sailingStarted = false
            return ChargePlan(mode: .normal, limit: limit)
        }
        let low = limit - range
        if !sailingStarted {
            sailingStarted = true
            isRecharging = inputs.percent <= low
        } else if inputs.percent <= low {
            isRecharging = true
        } else if inputs.percent >= limit {
            isRecharging = false
        }
        // Off the charger nothing is held; the level decides again on return.
        guard inputs.chargerAttached, !isRecharging, inputs.percent < limit else {
            return ChargePlan(mode: .normal, limit: limit)
        }
        return ChargePlan(mode: .normal, limit: inputs.percent, isSailing: true)
    }
}

/// Decides when the helper reconnects the charger on its own: its caller
/// has been silent for too long, so it may have crashed or hung.
public enum AdapterWatchdog {
    public static let silenceLimit: TimeInterval = 30
    /// How often a caller that holds the charger cut says it is still there.
    public static let heartbeat: TimeInterval = 10

    public static func shouldRestore(adapterCut: Bool, lastHeard: Date, now: Date) -> Bool {
        adapterCut && now.timeIntervalSince(lastHeard) >= silenceLimit
    }
}
