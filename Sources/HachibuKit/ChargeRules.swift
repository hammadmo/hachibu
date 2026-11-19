import Foundation

// The three rules ChargeEngine composes. Each keeps its own state and knows
// nothing of the others. Their numbers are constants on ChargeEngine.

/// Sailing: with a sailing range, the battery is not charged back to the
/// limit until it has drifted down by the whole range. Between the two
/// levels macOS is asked to hold the level the battery is at.
struct SailingRule: Equatable, Sendable {
    /// True while charging back up to the limit.
    private(set) var isRecharging = false
    /// The level macOS is asked to hold. nil when none.
    private(set) var hold: Int?
    private var started = false

    /// Takes up a hold that Hachibu left in place when it last ran.
    mutating func adopt(hold level: Int) {
        hold = level
        started = true
        isRecharging = false
    }

    mutating func reset() {
        started = false
        isRecharging = false
        hold = nil
    }

    mutating func plan(_ inputs: ChargeInputs) -> ChargePlan {
        let limit = inputs.limit
        let range = min(max(inputs.sailingRange, 0), limit - LimitStops.sliderRange.lowerBound)
        // Not with "no limit": there is nothing to sail under.
        guard range > 0, inputs.helperRunning, limit < 100 else {
            reset()
            return ChargePlan(mode: .normal, limit: limit)
        }
        let low = limit - range
        if !started {
            started = true
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
            if abs(inputs.percent - held) >= ChargeEngine.sailingStep { hold = inputs.percent }
        } else if inputs.percent <= limit - ChargeEngine.sailingStep {
            hold = inputs.percent
        }
        guard let hold else { return ChargePlan(mode: .normal, limit: limit) }
        return ChargePlan(mode: .normal, limit: hold, isSailing: true)
    }
}

/// Calibration: three limits in a row. 15% until the battery is there
/// (macOS drains to a limit below the level by itself, on AC power), none
/// until 100%, and none for two more hours on the charger. Then it ends and
/// the user's limit returns. Off the charger the step waits; nothing is
/// changed. A step that does not complete in twelve hours ends it.
struct CalibrationRule: Equatable, Sendable {
    enum Result: Equatable {
        case running(ChargePlan)
        case ended(ModeEnd)
    }

    private(set) var step: CalibrationStep?
    /// How long the battery has rested at 100% on the charger.
    private(set) var rested: TimeInterval = 0
    private var stepSince: Date?
    private var nearSince: Date?
    private var lastTick: Date?

    mutating func start(at percent: Int) {
        reset()
        step = percent <= ChargeEngine.calibrationFloor ? .charging : .draining
    }

    mutating func reset() {
        step = nil
        stepSince = nil
        nearSince = nil
        lastTick = nil
        rested = 0
    }

    mutating func plan(_ inputs: ChargeInputs, now: Date) -> Result {
        // Entered without a start (tests set the mode directly): charge.
        var current = step ?? .charging
        let sinceLastReading = max(now.timeIntervalSince(lastTick ?? now), 0)
        lastTick = now
        if stepSince == nil { stepSince = now }
        if inputs.chargerAttached {
            switch current {
            case .draining:
                let floor = ChargeEngine.calibrationFloor
                if reached(inputs.percent <= floor, near: inputs.percent <= floor + 1, now) {
                    current = .charging
                    startStep(now)
                }
            case .charging:
                if reached(inputs.percent >= 100, near: inputs.percent >= 99, now) {
                    current = .resting
                    startStep(now)
                }
            case .resting:
                if inputs.percent < 99 {
                    // Used on battery in the middle of the rest: fill it again.
                    current = .charging
                    startStep(now)
                } else {
                    // Only time on the charger at full counts as rest.
                    rested += sinceLastReading
                    if rested >= ChargeEngine.calibrationRest { return .ended(.finished) }
                }
            }
        }
        if current != .resting, let since = stepSince, now.timeIntervalSince(since) > ChargeEngine.calibrationStepLimit {
            return .ended(.timedOut)
        }
        step = current
        return .running(ChargePlan(mode: .calibrating, limit: current == .draining ? ChargeEngine.calibrationFloor : 100,
                                   calibration: current, isWaitingForCharger: !inputs.chargerAttached))
    }

    /// True when a step's target is met: exactly, or one percent short of
    /// it for half an hour.
    private mutating func reached(_ exactly: Bool, near: Bool, _ now: Date) -> Bool {
        if exactly { return true }
        guard near else {
            nearSince = nil
            return false
        }
        let since = nearSince ?? now
        nearSince = since
        return now.timeIntervalSince(since) >= ChargeEngine.calibrationNearGrace
    }

    private mutating func startStep(_ now: Date) {
        stepSince = now
        nearSince = nil
        rested = 0
    }
}

/// Heat protection: while the battery is hot and the plan would charge it,
/// macOS is asked to hold the level the battery is at instead, whatever the
/// mode. The mode itself goes on, and its own limit returns when the battery
/// has cooled. The same move as sailing, so it needs the helper too.
struct HeatRule: Equatable, Sendable {
    /// Over the threshold, with the margin on the way down.
    private(set) var isHot = false
    /// The level being held because of the heat. nil when none.
    private(set) var hold: Int?
    private var hotSince: Date?

    mutating func protect(_ plan: ChargePlan, _ inputs: ChargeInputs, now: Date) -> ChargePlan {
        guard let threshold = inputs.heatThreshold, let temperature = inputs.temperatureC, inputs.helperRunning else {
            isHot = false
            hotSince = nil
            hold = nil
            return plan
        }
        if isHot {
            if temperature <= Double(threshold) - ChargeEngine.heatMargin {
                isHot = false
                hotSince = nil
            }
        } else if temperature > Double(threshold) {
            // Hot only once it has stayed above the threshold for a while.
            let since = hotSince ?? now
            hotSince = since
            if now.timeIntervalSince(since) >= ChargeEngine.heatSustain { isHot = true }
        } else {
            hotSince = nil
        }
        // Nothing to pause when the plan would not charge anyway, off the
        // charger, during macOS's own full charge (it cannot be stopped), or
        // so low that holding the level is not a limit the helper sets.
        guard isHot, inputs.chargerAttached, !inputs.macOSFullCharge, inputs.percent < plan.limit,
              inputs.percent >= LimitStops.sliderRange.lowerBound else {
            hold = nil
            return plan
        }
        // macOS takes a minute or two to act while charging, and the level
        // climbs meanwhile. So the hold is one percent above the level: a
        // limit below the level would make macOS drain the battery, and
        // asking again for every percent would never let one take effect.
        let headroom = min(inputs.percent + 1, plan.limit)
        if let held = hold {
            if inputs.percent > held || inputs.percent <= held - 1 - ChargeEngine.sailingStep { hold = headroom }
        } else {
            hold = headroom
        }
        var paused = plan
        paused.limit = hold ?? inputs.percent
        paused.isSailing = false
        paused.isPausedForHeat = true
        return paused
    }
}
