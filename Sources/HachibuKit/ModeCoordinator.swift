import Foundation

/// What Hachibu wrote down about a limit a mode asked macOS for, so the next
/// launch can tell its own leftover from a limit set elsewhere.
public struct ModeRecord: Equatable, Sendable {
    /// The limit asked for on the mode's behalf.
    public var asked: Int
    /// The user's limit it stood in for.
    public var user: Int
    /// True for a sailing hold, which the next launch takes up again;
    /// false for a Top Up, a calibration, or a heat pause, which it undoes.
    public var isSailingHold: Bool

    public init(asked: Int, user: Int, isSailingHold: Bool) {
        self.asked = asked
        self.user = user
        self.isSailingHold = isSailingHold
    }
}

public enum ModeNotice: Equatable, Sendable {
    /// A Top Up reached 100%. `limit` is the user's, which returns on unplug.
    case topUpFinished(limit: Int)
    case calibrationFinished(limit: Int)
}

/// What the coordinator wants done. It does none of it itself.
public enum ModeEffect: Equatable, Sendable {
    /// Ask macOS for this limit on a mode's behalf. Never saved as the user's.
    case ask(Int)
    /// Write the record down, or erase it (nil).
    case write(ModeRecord?)
    case notify(ModeNotice)
    /// The helper did not answer: look at its state again.
    case refreshHelper
    /// Show this under the limit, or clear what is shown (nil).
    case limitProblem(String?)
}

/// Everything between "what a mode wants" (ChargeEngine) and "one request
/// to macOS" (LimitSetter): when to ask, what a failed request means, when
/// the user's limit counts as back, what to write down for the next launch,
/// and what a launch does with a leftover. It takes events and returns
/// effects; BatteryMonitor feeds it and carries the effects out.
public struct ModeCoordinator: Equatable, Sendable {
    /// After a failed attempt to put the user's limit back, ask again this often.
    public static let restoreRetry: TimeInterval = 60
    /// After a sailing hold failed to take, sailing waits this long.
    public static let sailingPause: TimeInterval = 600

    public private(set) var engine = ChargeEngine()
    public private(set) var override = LimitOverride.none
    // What the last plan said, for the views.
    public private(set) var mode = ChargeMode.normal
    public private(set) var isSailing = false
    public private(set) var isToppedUp = false
    public private(set) var isPausedForHeat = false
    public private(set) var calibrationStep: CalibrationStep?
    public private(set) var isWaitingForCharger = false
    /// Why a mode could not start or was cut short, in words for the user.
    public private(set) var problem: String?

    private var record: ModeRecord?
    private var restoreRetryAt: Date?
    private var sailingPausedUntil: Date?
    /// After a heat pause failed to take, heat protection waits this long too.
    private var heatPausedUntil: Date?
    /// Hachibu is quitting: the limit is being written back, so no mode asks for one.
    private var isQuitting = false
    /// A calibration finished; say so once the user's limit is really back.
    private var owesFinishedNotice = false
    /// "Top Up finished" was said for the Top Up that runs now.
    private var saidTopUpFinished = false
    /// `problem` is the notice from a launch that found a leftover limit.
    private var showsLaunchNotice = false

    public init() {}

    /// A fixed state for snapshots. Nothing can be asked of it.
    public init(fixedMode mode: ChargeMode, isSailing: Bool = false, calibration: CalibrationStep? = nil,
                isPausedForHeat: Bool = false, override: LimitOverride = .none) {
        self.mode = mode
        self.isSailing = isSailing
        calibrationStep = calibration
        self.isPausedForHeat = isPausedForHeat
        self.override = override
    }

    public var isOverriding: Bool { override != .none }

    /// The user's limit, given what macOS holds now.
    public func userLimit(system: Int) -> Int { override.userLimit(system: system) }

    /// What the engine looks at: the reading with the user's limit in it,
    /// and with sailing switched off where it must not steer. Sailing only
    /// steers a limit that is Hachibu's own (or one it is already holding
    /// for), and waits after a hold that did not take.
    public func inputs(_ reading: ChargeInputs, system: Int, limitIsOwn: Bool, now: Date) -> ChargeInputs {
        var inputs = reading
        inputs.limit = userLimit(system: system)
        if !(isOverriding || limitIsOwn) { inputs.sailingRange = 0 }
        if let until = sailingPausedUntil, now < until { inputs.sailingRange = 0 }
        if let until = heatPausedUntil, now < until { inputs.heatThreshold = nil }
        return inputs
    }

    // MARK: Launch

    /// At launch, with the first reading of the limit. A Top Up, a
    /// calibration, or a heat pause that Hachibu did not get to undo is
    /// undone: if macOS still holds exactly what was asked, it is Hachibu's
    /// own leftover and the user's limit is put back. A sailing hold that is
    /// still exactly in place is taken up again, or undone like the others
    /// when sailing is no longer on. Anything else was set outside Hachibu
    /// and is left alone, and the record is erased.
    public mutating func launched(record found: ModeRecord?, system: Int, saved: Int?, sailingRange: Int,
                                  now: Date) -> [ModeEffect] {
        var effects: [ModeEffect] = []
        record = found
        guard let found else { return effects }
        if found.isSailingHold {
            if sailingRange > 0, let saved, system == found.asked, found.asked < saved {
                isSailing = true
                override = .holding(limit: found.asked, user: saved)
                engine.adopt(hold: found.asked)
            } else if system == found.asked, let saved, saved != found.asked {
                // Sailing cannot go on (switched off, or no helper), and the
                // hold is still in place: it must not stay as the limit.
                restoreAtLaunch(user: saved, now: now)
            }
        } else if system == found.asked, found.user != found.asked {
            restoreAtLaunch(user: found.user, now: now)
        }
        sync(&effects)
        return effects
    }

    private mutating func restoreAtLaunch(user: Int, now: Date) {
        override = .restoring(user: user)
        restoreRetryAt = now
        problem = "Hachibu stopped while a limit of its own was in place. Your limit is being put back."
        showsLaunchNotice = true
    }

    // MARK: Each reading

    /// Asks the engine what should be true now. A limit is asked for only
    /// when the plan changes, and never while another request is under way
    /// (`canAsk` false).
    public mutating func reading(_ reading: ChargeInputs, system: Int, limitIsOwn: Bool, canAsk: Bool,
                                 now: Date) -> [ModeEffect] {
        var effects: [ModeEffect] = []
        let inputs = inputs(reading, system: system, limitIsOwn: limitIsOwn, now: now)
        let plan = engine.step(inputs, now: now)
        let wasCalibrating = calibrationStep != nil
        show(plan)
        if plan.mode != .toppingUp { saidTopUpFinished = false }
        if wasCalibrating, plan.calibration == nil {
            // Said only once the user's limit is really back.
            if engine.lastEnd == .finished { owesFinishedNotice = true }
            if engine.lastEnd == .timedOut {
                problem = "The calibration was stopped: a step took more than twelve hours."
            }
        }
        // A mode that is running again has nothing left to explain.
        if plan.mode != .normal || plan.isSailing || plan.isPausedForHeat { clearProblem() }
        guard canAsk, !isQuitting else { return effects }
        // Said once per Top Up, when the battery is seen at 100% (the level
        // can dip to 99 and return), and only with nothing under way and
        // "no limit" still standing: a Top Up whose request failed is over.
        if plan.isToppedUp, !saidTopUpFinished, override.asked == 100 {
            saidTopUpFinished = true
            effects.append(.notify(.topUpFinished(limit: inputs.limit)))
        }
        let wanted: Int? = plan.limit == inputs.limit ? nil : plan.limit
        let retryDue = restoreRetryAt.map { now >= $0 } ?? false
        if let limit = override.follow(wanted: wanted, userLimit: inputs.limit, retryDue: retryDue) {
            restoreRetryAt = nil
            effects.append(.ask(limit))
        }
        if override == .none { ended(user: inputs.limit, &effects) }
        sync(&effects)
        return effects
    }

    /// A fresh reading of what macOS holds, taken while nothing is under
    /// way. If macOS holds something other than what a mode asked for,
    /// someone changed it outside Hachibu: the mode ends and that limit is
    /// left as it is. During macOS's own full charge the reported limit is
    /// not to be trusted as a change someone made.
    public mutating func observed(system: Int, isMacOSFullCharge: Bool) -> [ModeEffect] {
        var effects: [ModeEffect] = []
        guard !isMacOSFullCharge else { return effects }
        let before = override
        let changedOutside = override.observe(system: system)
        if changedOutside {
            engine.stop()
            engine.resetSailing()
            show(ChargePlan(mode: .normal, limit: system))
            owesFinishedNotice = false
            showsLaunchNotice = false
            problem = nil
            restoreRetryAt = nil
        } else if override == .none, case .restoring(let user) = before {
            ended(user: user, &effects)
        }
        sync(&effects)
        return effects
    }

    // MARK: Requests

    /// The outcome of a limit asked for on a mode's behalf: a hold, a Top
    /// Up's "no limit", or the user's limit being put back.
    public mutating func modeRequestSettled(_ outcome: LimitSetter.Outcome, now: Date) -> [ModeEffect] {
        var effects: [ModeEffect] = []
        guard outcome != .superseded else { return effects }
        if outcome == .held {
            if case .restoring(let user) = override {
                effects.append(.limitProblem(nil))
                override.confirmed()
                ended(user: user, &effects)
            }
            sync(&effects)
            return effects
        }
        let reason: String
        switch outcome {
        case .notAccepted(viaHelper: true):
            reason = "the helper did not answer"
            effects.append(.refreshHelper)
        case .notAccepted: reason = "macOS refused the limit"
        case .notConfirmed: reason = "macOS did not report the new limit"
        default: reason = "macOS accepted the limit but has not enforced it"
        }
        switch override {
        case .restoring:
            // Never give up on the user's limit: ask again in a minute.
            restoreRetryAt = now.addingTimeInterval(Self.restoreRetry)
            effects.append(.limitProblem("Your limit is not back yet: \(reason). Hachibu will ask again."))
        case .holding(_, let user):
            // What the mode asked for did not take. Stop the mode, say why,
            // and put the user's limit back; the Mac may be in between.
            // A hold that failed is not asked for again on the next
            // reading: the rule that wanted it waits ten minutes.
            if isPausedForHeat { heatPausedUntil = now.addingTimeInterval(Self.sailingPause) }
            switch mode {
            case .toppingUp: problem = "The Top Up was stopped: \(reason)."
            case .calibrating: problem = "The calibration was stopped: \(reason)."
            case .normal where isPausedForHeat:
                problem = "Heat protection is paused for ten minutes: \(reason)."
            case .normal:
                sailingPausedUntil = now.addingTimeInterval(Self.sailingPause)
                problem = "Sailing is paused for ten minutes: \(reason)."
            }
            showsLaunchNotice = false
            engine.stop()
            engine.resetSailing()
            show(ChargePlan(mode: .normal, limit: user))
            // What was asked stays written down until the user's limit is back.
            override = .restoring(user: user)
            restoreRetryAt = now
        case .none:
            break
        }
        sync(&effects)
        return effects
    }

    /// The user asks for a limit of their own: every mode ends first. While
    /// a mode's limit is still in place the override stays as "putting the
    /// old limit back", so that if the new limit does not take, the old one
    /// returns instead of the mode's limit staying.
    public mutating func userAsked(system: Int) -> [ModeEffect] {
        var effects: [ModeEffect] = []
        let user = userLimit(system: system)
        engine.stop()
        show(ChargePlan(mode: .normal, limit: user))
        owesFinishedNotice = false
        showsLaunchNotice = false
        problem = nil
        restoreRetryAt = nil
        if override != .none { override = .restoring(user: user) }
        sync(&effects)
        return effects
    }

    /// The outcome of a limit the user asked for. `accepted` is true when
    /// macOS took it, even if it is not enforcing it yet: from then on the
    /// limit in place is the user's new one, and going back to the limit
    /// from before the mode would undo their choice.
    public mutating func userRequestSettled(accepted: Bool, now: Date) -> [ModeEffect] {
        var effects: [ModeEffect] = []
        if accepted {
            // Only now is whatever a mode left behind really gone.
            override = .none
            restoreRetryAt = nil
        } else if case .restoring = override {
            // The new limit did not take while a mode's limit was still in
            // place: go back to the limit from before the mode.
            restoreRetryAt = now.addingTimeInterval(Self.restoreRetry)
        }
        sync(&effects)
        return effects
    }

    // MARK: Starting and stopping

    /// The Top Up button: starts one, or stops the one that runs.
    public mutating func toggleTopUp(_ reading: ChargeInputs, system: Int, limitIsOwn: Bool) {
        if mode == .toppingUp || engine.mode == .toppingUp {
            engine.stop()
        } else {
            setProblem(engine.startTopUp(inputs(reading, system: system, limitIsOwn: limitIsOwn, now: .distantPast)))
        }
    }

    /// Why a calibration cannot start now. nil when it can.
    public func calibrationRefusal(_ reading: ChargeInputs, system: Int, limitIsOwn: Bool) -> String? {
        var trial = engine
        return trial.startCalibration(inputs(reading, system: system, limitIsOwn: limitIsOwn, now: .distantPast))
    }

    /// Starts a calibration. Returns why not, or nil.
    public mutating func startCalibration(_ reading: ChargeInputs, system: Int, limitIsOwn: Bool) -> String? {
        engine.startCalibration(inputs(reading, system: system, limitIsOwn: limitIsOwn, now: .distantPast))
    }

    /// Ends a Top Up or a calibration early.
    public mutating func stop() {
        engine.stop()
    }

    /// Before quitting: ends the mode and returns the limit to write back,
    /// or nil when macOS already holds the user's. The record is left as it
    /// is: that write is not confirmed, and if it fails the next launch
    /// finds the record and puts the limit back.
    public mutating func quitting(system: Int) -> Int? {
        guard isOverriding || mode != .normal else { return nil }
        let target = userLimit(system: system)
        engine.stop()
        mode = .normal
        isQuitting = true
        return isOverriding ? target : nil
    }

    /// Before the helper is removed: ends every mode and returns the user's
    /// limit, which is what must hold afterwards.
    public mutating func removingHelper(system: Int) -> (user: Int, effects: [ModeEffect]) {
        let user = userLimit(system: system)
        let effects = userAsked(system: system)
        engine.resetSailing()
        isSailing = false
        return (user, effects)
    }

    // MARK: Inside

    private mutating func show(_ plan: ChargePlan) {
        mode = plan.mode
        isSailing = plan.isSailing
        isToppedUp = plan.isToppedUp
        isPausedForHeat = plan.isPausedForHeat
        calibrationStep = plan.calibration
        isWaitingForCharger = plan.isWaitingForCharger
    }

    private mutating func setProblem(_ text: String?) {
        problem = text
        showsLaunchNotice = false
    }

    private mutating func clearProblem() {
        problem = nil
        showsLaunchNotice = false
    }

    /// The user's limit is confirmed back after a mode (or was never away).
    private mutating func ended(user: Int, _ effects: inout [ModeEffect]) {
        if showsLaunchNotice { clearProblem() }
        if owesFinishedNotice {
            owesFinishedNotice = false
            effects.append(.notify(.calibrationFinished(limit: user)))
        }
    }

    /// Keeps the written record in step with the override. It stays as it
    /// is while the user's limit is being put back, and is erased only once
    /// that is confirmed.
    private mutating func sync(_ effects: inout [ModeEffect]) {
        let wanted: ModeRecord?
        switch override {
        case .none: wanted = nil
        case .holding(let limit, let user): wanted = ModeRecord(asked: limit, user: user, isSailingHold: isSailing)
        case .restoring: wanted = record
        }
        guard wanted != record else { return }
        record = wanted
        effects.append(.write(wanted))
    }
}
