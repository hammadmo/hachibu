import Foundation

/// What Hachibu is doing on top of plain "hold the limit".
public enum ChargeMode: String, Equatable, Sendable {
    case normal
    /// Charging to 100% once; the limit returns afterwards.
    case toppingUp
    /// A guided full cycle (story S-042). Nothing starts it yet.
    case calibrating
}

/// Why a Top Up ended.
public enum ModeEnd: Equatable, Sendable {
    case unplugged, stopped
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

    public init(percent: Int, chargerAttached: Bool, limit: Int, sailingRange: Int = 0, helperRunning: Bool = false,
                macOSFullCharge: Bool = false) {
        self.percent = percent
        self.chargerAttached = chargerAttached
        self.limit = limit
        self.sailingRange = sailingRange
        self.helperRunning = helperRunning
        self.macOSFullCharge = macOSFullCharge
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

    public init(mode: ChargeMode, limit: Int, isSailing: Bool = false, isToppedUp: Bool = false) {
        self.mode = mode
        self.limit = limit
        self.isSailing = isSailing
        self.isToppedUp = isToppedUp
    }
}

/// Decides, from each reading, which limit macOS should hold. It changes
/// nothing itself: BatteryMonitor carries the plan out. It never cuts the
/// charger: on macOS 27 that left the Mac on battery after the cut was
/// released (docs/research/charge-control.md), and macOS already drains to
/// a limit below the level by itself.
public struct ChargeEngine: Equatable, Sendable {
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

    public mutating func stop() {
        end(.stopped)
    }

    private mutating func end(_ reason: ModeEnd) {
        guard mode != .normal else { return }
        mode = .normal
        lastEnd = reason
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

    public mutating func step(_ inputs: ChargeInputs) -> ChargePlan {
        // A Top Up ends when the charger is unplugged, or on Stop. It does
        // not end at 100%: with the limit back, macOS would drain the
        // battery to it while still plugged in, and the top up would be gone
        // by the time the charger is pulled.
        if mode == .toppingUp, !inputs.chargerAttached { end(.unplugged) }
        switch mode {
        case .toppingUp:
            return ChargePlan(mode: mode, limit: 100, isToppedUp: inputs.percent >= 100)
        case .calibrating:
            return ChargePlan(mode: mode, limit: 100)
        case .normal:
            return sailing(inputs)
        }
    }

    // MARK: Sailing

    /// With a sailing range, the battery is not charged back to the limit
    /// until it has drifted down by the whole range. Between the two levels
    /// macOS is asked to hold the level the battery is at.
    private mutating func sailing(_ inputs: ChargeInputs) -> ChargePlan {
        let limit = inputs.limit
        let range = min(max(inputs.sailingRange, 0), limit - HelperRequest.limitRange.lowerBound)
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
