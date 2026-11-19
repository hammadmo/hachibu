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
    /// A calibration step did not complete in time, so it was ended.
    case timedOut
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
    /// One percent short of a step's target counts as reached after this
    /// long: macOS can stop at 16% or at 99%.
    public static let calibrationNearGrace: TimeInterval = 30 * 60
    /// A draining or charging step that takes longer than this ends the
    /// calibration, so 15% or "no limit" is never left in place for days.
    public static let calibrationStepLimit: TimeInterval = 12 * 3600
    /// The battery must stay above the heat threshold this long before
    /// charging is paused: a pause takes a minute or more to take effect,
    /// so a brief spike should not start one.
    public static let heatSustain: TimeInterval = 180

    /// The thresholds a person can choose, and the one Hachibu starts with.
    /// Below 36 °C this kind of Mac would hardly ever charge; at 44 °C macOS
    /// stops charging by itself (docs/research/charge-control.md).
    public static let heatRange = 36...43
    public static let heatDefault = 40

    /// Once paused for heat, charging resumes this many degrees below the threshold.
    public static let heatMargin = 2.0

    /// Sailing ignores a change of one percent: readings flicker by that
    /// much, and every new level is a write by the helper.
    public static let sailingStep = 2

    public internal(set) var mode = ChargeMode.normal
    /// Why the last Top Up or calibration ended. Cleared when one starts.
    public private(set) var lastEnd: ModeEnd?
    // One rule each, with its own state; see ChargeRules.swift.
    private var sailing = SailingRule()
    private var calibration = CalibrationRule()
    private var heat = HeatRule()

    /// Sailing: true while charging back up to the limit.
    public var isRecharging: Bool { sailing.isRecharging }
    /// Sailing: the level macOS is asked to hold. nil when none.
    public var hold: Int? { sailing.hold }
    /// The step a calibration is on.
    public var calibrationStep: CalibrationStep? { calibration.step }
    /// How long the battery has rested at 100% on the charger.
    public var rested: TimeInterval { calibration.rested }
    /// Heat protection: whether the battery is over the threshold (with the
    /// margin on the way down), and the level being held because of it.
    public var isHot: Bool { heat.isHot }
    public var heatHold: Int? { heat.hold }

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
        calibration.start(at: inputs.percent)
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
        calibration.reset()
        // Whatever the mode did to the level, sailing starts over from it.
        sailing.reset()
    }

    /// Takes up a hold that Hachibu left in place when it last ran.
    public mutating func adopt(hold level: Int) {
        sailing.adopt(hold: level)
    }

    /// Forgets where sailing was, for when it is switched off or paused.
    public mutating func resetSailing() {
        sailing.reset()
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
            switch calibration.plan(inputs, now: now) {
            case .running(let running):
                plan = running
            case .ended(let reason):
                end(reason)
                plan = sailing.plan(inputs)
            }
        case .normal:
            plan = sailing.plan(inputs)
        }
        return heat.protect(plan, inputs, now: now)
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
