import Foundation

/// What Hachibu is doing on top of plain "hold the limit".
public enum ChargeMode: String, Equatable, Sendable {
    case normal
    /// Charging to 100% once; the limit returns afterwards.
    case toppingUp
    /// A guided cycle that corrects the battery's reading: drain to 15%,
    /// charge to 100%, rest there, then back to the limit.
    case calibrating
}

/// Why a Top Up ended.
public enum ModeEnd: Equatable, Sendable {
    case unplugged, stopped
    /// A calibration ran through all its steps.
    case finished
}

/// Where a calibration is.
public enum CalibrationStep: String, Equatable, Sendable, CaseIterable {
    /// macOS drains the battery to 15% while it stays on the charger.
    case draining
    case charging
    /// Full, and staying there for two hours so the gauge can settle.
    case resting
}

/// What the engine looks at on every reading.
public struct ChargeInputs: Equatable, Sendable {
    public var percent: Int
    public var chargerAttached: Bool
    /// The user's limit. 100 means none.
    public var limit: Int
    /// Percent the battery drifts below the limit before charging again. 0 is off.
    public var sailingRange: Int
    public var helperRunning: Bool
    /// macOS is charging to 100% on its own, to keep its estimates accurate.
    public var macOSFullCharge: Bool
    /// The battery's temperature. nil when it cannot be read.
    public var temperatureC: Double?
    /// Charging pauses above this many degrees Celsius. nil is off.
    public var heatThreshold: Int?

    public init(percent: Int, chargerAttached: Bool, limit: Int, sailingRange: Int = 0, helperRunning: Bool = false,
                macOSFullCharge: Bool = false, temperatureC: Double? = nil, heatThreshold: Int? = nil) {
        self.percent = percent
        self.chargerAttached = chargerAttached
        self.limit = limit
        self.sailingRange = sailingRange
        self.helperRunning = helperRunning
        self.macOSFullCharge = macOSFullCharge
        self.temperatureC = temperatureC
        self.heatThreshold = heatThreshold
    }
}

/// What should be true right now.
public struct ChargePlan: Equatable, Sendable {
    public var mode: ChargeMode
    /// The limit macOS should hold. 100 means none.
    public var limit: Int
    /// Plugged in and drifting down inside the sailing range.
    public var isSailing: Bool
    /// A Top Up has reached 100% and is keeping it there until unplugged.
    public var isToppedUp: Bool
    /// The step a calibration is on. nil when none runs.
    public var calibration: CalibrationStep?
    /// A calibration is waiting for the charger to come back.
    public var isWaitingForCharger: Bool
    /// The battery is hot, so macOS is asked to hold the level it is at.
    public var isPausedForHeat: Bool

    public init(mode: ChargeMode, limit: Int, isSailing: Bool = false, isToppedUp: Bool = false,
                calibration: CalibrationStep? = nil, isWaitingForCharger: Bool = false, isPausedForHeat: Bool = false) {
        self.mode = mode
        self.limit = limit
        self.isSailing = isSailing
        self.isToppedUp = isToppedUp
        self.calibration = calibration
        self.isWaitingForCharger = isWaitingForCharger
        self.isPausedForHeat = isPausedForHeat
    }
}

/// Decides, from each reading, which limit macOS should hold. It changes
/// nothing itself: BatteryMonitor carries the plan out. It never cuts the
/// charger: on macOS 27 that left the Mac on battery after the cut was
/// released (docs/research/charge-control.md), and macOS already drains to
/// a limit below the level by itself.
public struct ChargeEngine: Equatable, Sendable {
    /// How low a calibration drains, and how long it rests at 100%.
    public static let calibrationFloor = 15
    public static let calibrationRest: TimeInterval = 2 * 3600

    /// Once paused for heat, charging resumes this many degrees below the threshold.
    public static let heatMargin = 2.0

    /// Sailing ignores a change of one percent: readings flicker by that
    /// much, and every new level is a write by the helper.
    public static let sailingStep = 2

    public internal(set) var mode = ChargeMode.normal
    /// Why the last Top Up ended. Cleared when one starts.
    public private(set) var lastEnd: ModeEnd?
    /// Sailing: true while charging back up to the limit.
    public private(set) var isRecharging = false
    /// Sailing: the level macOS is asked to hold. nil when none.
    public private(set) var hold: Int?
    private var sailingStarted = false
    /// The step a calibration is on, and when its rest at 100% began.
    public private(set) var calibrationStep: CalibrationStep?
    public private(set) var restingSince: Date?
    /// Heat protection: whether the battery is over the threshold (with the
    /// margin on the way down), and the level being held because of it.
    public private(set) var isHot = false
    public private(set) var heatHold: Int?

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

    /// Starts a calibration. Returns why not, in words for the user, or nil.
    public mutating func startCalibration(_ inputs: ChargeInputs) -> String? {
        guard mode == .normal else { return "Stop the current mode first." }
        guard inputs.helperRunning else { return "Calibration needs the helper." }
        guard inputs.chargerAttached else { return "Connect the charger to calibrate." }
        mode = .calibrating
        calibrationStep = inputs.percent <= Self.calibrationFloor ? .charging : .draining
        restingSince = nil
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
        calibrationStep = nil
        restingSince = nil
        // Whatever the mode did to the level, sailing starts over from it.
        resetSailing()
    }

    /// Takes up a hold that Hachibu left in place when it last ran.
    public mutating func adopt(hold level: Int) {
        hold = level
        sailingStarted = true
        isRecharging = false
    }

    /// Forgets where sailing was, for when it is switched off or paused.
    public mutating func resetSailing() {
        sailingStarted = false
        isRecharging = false
        hold = nil
    }

    // MARK: Each reading

    public mutating func step(_ inputs: ChargeInputs, now: Date = .now) -> ChargePlan {
        // A Top Up ends when the charger is unplugged, or on Stop. It does
        // not end at 100%: with the limit back, macOS would drain the
        // battery to it while still plugged in, and the top up would be gone
        // by the time the charger is pulled.
        if mode == .toppingUp, !inputs.chargerAttached { end(.unplugged) }
        let plan: ChargePlan
        switch mode {
        case .toppingUp:
            plan = ChargePlan(mode: mode, limit: 100, isToppedUp: inputs.percent >= 100)
        case .calibrating:
            plan = calibrate(inputs, now: now)
        case .normal:
            plan = sailing(inputs)
        }
        return protectFromHeat(plan, inputs)
    }

    // MARK: Heat protection

    /// While the battery is hot and the plan would charge it, macOS is asked
    /// to hold the level the battery is at instead, whatever the mode. The
    /// mode itself goes on, and its own limit returns when the battery has
    /// cooled. The same move as sailing, so it needs the helper too.
    private mutating func protectFromHeat(_ plan: ChargePlan, _ inputs: ChargeInputs) -> ChargePlan {
        guard let threshold = inputs.heatThreshold, let temperature = inputs.temperatureC, inputs.helperRunning else {
            isHot = false
            heatHold = nil
            return plan
        }
        if isHot {
            if temperature <= Double(threshold) - Self.heatMargin { isHot = false }
        } else if temperature > Double(threshold) {
            isHot = true
        }
        // Nothing to pause when the plan would not charge anyway, off the
        // charger, during macOS's own full charge (it cannot be stopped), or
        // so low that holding the level is not a limit the helper sets.
        guard isHot, inputs.chargerAttached, !inputs.macOSFullCharge, inputs.percent < plan.limit,
              inputs.percent >= LimitStops.sliderRange.lowerBound else {
            heatHold = nil
            return plan
        }
        if let held = heatHold {
            // Never below the battery's level: that would make macOS drain
            // it, and draining makes heat. Down only for a real move.
            if inputs.percent > held || inputs.percent <= held - Self.sailingStep { heatHold = inputs.percent }
        } else {
            heatHold = inputs.percent
        }
        var paused = plan
        paused.limit = heatHold ?? inputs.percent
        paused.isSailing = false
        paused.isPausedForHeat = true
        return paused
    }

    // MARK: Calibration

    /// Three limits in a row: 15% until the battery is there (macOS drains to
    /// a limit below the level by itself, on AC power), none until 100%, and
    /// none for two more hours. Then the mode ends and the user's limit
    /// returns. Off the charger the step waits; nothing is changed.
    private mutating func calibrate(_ inputs: ChargeInputs, now: Date) -> ChargePlan {
        // Entered without a start (tests set the mode directly): charge.
        var step = calibrationStep ?? .charging
        if inputs.chargerAttached {
            switch step {
            case .draining:
                if inputs.percent <= Self.calibrationFloor { step = .charging }
            case .charging:
                if inputs.percent >= 100 {
                    step = .resting
                    restingSince = now
                }
            case .resting:
                // Used on battery in the middle of the rest: fill it again.
                if inputs.percent < 99 {
                    step = .charging
                    restingSince = nil
                } else if let since = restingSince, now.timeIntervalSince(since) >= Self.calibrationRest {
                    end(.finished)
                    return sailing(inputs)
                }
            }
        }
        calibrationStep = step
        return ChargePlan(mode: .calibrating, limit: step == .draining ? Self.calibrationFloor : 100,
                          calibration: step, isWaitingForCharger: !inputs.chargerAttached)
    }

    // MARK: Sailing

    /// With a sailing range, the battery is not charged back to the limit
    /// until it has drifted down by the whole range. Between the two levels
    /// macOS is asked to hold the level the battery is at.
    private mutating func sailing(_ inputs: ChargeInputs) -> ChargePlan {
        let limit = inputs.limit
        let range = min(max(inputs.sailingRange, 0), limit - LimitStops.sliderRange.lowerBound)
        // Not with "no limit": there is nothing to sail under.
        guard range > 0, inputs.helperRunning, limit < 100 else {
            resetSailing()
            return ChargePlan(mode: .normal, limit: limit)
        }
        let low = limit - range
        if !sailingStarted {
            sailingStarted = true
            isRecharging = inputs.percent <= low
        } else if inputs.percent <= low {
            isRecharging = true
            hold = nil
        } else if isRecharging, inputs.percent >= limit - 1 {
            // macOS can stop a percent short of the limit; that is "back up".
            isRecharging = false
        }
        // Off the charger nothing changes: whatever was held stays asked
        // for, and the level decides again when the charger is back.
        guard inputs.chargerAttached else { return ChargePlan(mode: .normal, limit: hold ?? limit) }
        // At the limit, while recharging, and during macOS's own full
        // charge, the limit itself is asked for and nothing is held.
        guard !isRecharging, !inputs.macOSFullCharge, inputs.percent < limit else {
            hold = nil
            return ChargePlan(mode: .normal, limit: limit)
        }
        if let held = hold {
            // Follow the level only when it has really moved.
            if abs(inputs.percent - held) >= Self.sailingStep { hold = inputs.percent }
        } else if inputs.percent <= limit - Self.sailingStep {
            hold = inputs.percent
        }
        guard let hold else { return ChargePlan(mode: .normal, limit: limit) }
        return ChargePlan(mode: .normal, limit: hold, isSailing: true)
    }
}

/// What stands between the user's limit and what macOS was asked for, and
/// the rules for moving between the three states. It only decides what to
/// ask macOS for; BatteryMonitor does the asking.
public enum LimitOverride: Equatable, Sendable {
    case none
    /// A mode asked macOS for `limit` in place of the user's own: 100
    /// during a Top Up, the level being held while sailing.
    case holding(limit: Int, user: Int)
    /// The mode is over and the user's limit was asked for again, but
    /// macOS has not confirmed it yet. Still not "none": until it is
    /// confirmed, what macOS holds is not the user's limit.
    case restoring(user: Int)

    /// The limit a mode has macOS holding. nil when none.
    public var asked: Int? {
        if case .holding(let limit, _) = self { return limit }
        return nil
    }

    /// The user's limit: the one remembered while a mode stands in for it,
    /// otherwise whatever macOS holds.
    public func userLimit(system: Int) -> Int {
        switch self {
        case .none: system
        case .holding(_, let user), .restoring(let user): user
        }
    }

    /// Follows what the engine wants (`wanted` is nil for "the user's own
    /// limit"). Returns the limit to ask macOS for now, or nil for nothing.
    /// Call only while no request is under way.
    public mutating func follow(wanted: Int?, userLimit: Int, retryDue: Bool = false) -> Int? {
        switch (self, wanted) {
        case (.none, nil):
            return nil
        case (.none, let limit?):
            self = .holding(limit: limit, user: userLimit)
            return limit
        case (.holding(let asked, _), let limit?) where limit == asked:
            return nil
        case (.holding(_, let user), let limit?), (.restoring(let user), let limit?):
            self = .holding(limit: limit, user: user)
            return limit
        case (.holding(_, let user), nil):
            self = .restoring(user: user)
            return user
        case (.restoring(let user), nil):
            return retryDue ? user : nil
        }
    }

    /// macOS confirmed the last limit asked for.
    public mutating func confirmed() {
        if case .restoring = self { self = .none }
    }

    /// A fresh reading of what macOS holds, taken while nothing is under
    /// way. Returns true when a mode's limit was changed outside Hachibu:
    /// the override is dropped and that limit is left alone.
    public mutating func observe(system: Int) -> Bool {
        switch self {
        case .holding(let asked, _) where system != asked:
            self = .none
            return true
        case .restoring(let user) where system == user:
            self = .none
            return false
        default:
            return false
        }
    }
}
