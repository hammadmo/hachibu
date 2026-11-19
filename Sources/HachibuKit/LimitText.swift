import Foundation

/// What the button beside the limit offers, when there is something to do.
public enum LimitAction: Equatable, Sendable {
    /// macOS holds another limit than the one saved in Hachibu: take it back.
    case useSaved(Int)
    /// Adopt the limit macOS already holds as Hachibu's own.
    case keepSystem

    public var title: String {
        switch self {
        case .useSaved: "Use Hachibu's Limit"
        case .keepSystem: "Keep This Limit"
        }
    }
}

/// Everything the limit block's words depend on.
public struct LimitFacts: Equatable, Sendable {
    /// The first reading has arrived.
    public var hasLoaded = true
    public var limitSupported = true
    /// macOS has told us the limit.
    public var limitKnown = true
    /// The slider may be used (the limit is known and nothing blocks it).
    public var canChange = true
    public var limit = LimitState(system: nil, saved: nil)
    /// Where the slider is.
    public var sliderValue = 100
    /// The user's limit, which a mode goes back to. 100 means none.
    public var userLimit = 100
    /// A limit request is waiting or under way.
    public var isBusy = false
    /// A helper limit is accepted and waiting for power management.
    public var isWaitingForMacOS = false
    /// The request under way is a limit the user set.
    public var userRequestPending = false
    public var override = LimitOverride.none
    public var mode = ChargeMode.normal
    public var isSailing = false
    public var isToppedUp = false
    public var isPausedForHeat = false
    public var isWaitingForCharger = false
    public var heatThreshold: Int?
    public var sailingRange = 0
    /// Why a mode could not start or was cut short.
    public var modeProblem: String?
    /// Why the last limit request did not take.
    public var applyProblem: String?

    public init() {}
}

/// The words in the limit block: the value beside "Limit", the line under
/// the slider, and the button beside that line. The order of the checks is
/// the meaning: what Hachibu is doing right now comes before what went
/// wrong, which comes before who set the limit.
public struct LimitText: Equatable, Sendable {
    public var value: String
    public var caption: String
    public var action: LimitAction?

    public init(_ facts: LimitFacts) {
        value = Self.value(facts)
        caption = Self.caption(facts)
        action = Self.action(facts)
    }

    /// While the slider is being dragged or the user's request is under way
    /// it shows where the slider is. While a mode stands in for the user's
    /// limit it shows the user's limit, not what macOS was asked to hold.
    static func value(_ facts: LimitFacts) -> String {
        guard facts.limitKnown else { return "–" }
        let target = LimitState(system: facts.sliderValue, saved: nil).valueText
        if facts.userRequestPending { return target }
        if facts.override != .none { return LimitState(system: facts.userLimit, saved: nil).valueText }
        return facts.isBusy ? target : facts.limit.valueText
    }

    static func caption(_ facts: LimitFacts) -> String {
        if !facts.hasLoaded { return "Reading the limit…" }
        if !facts.limitSupported { return "This version of macOS does not offer a charge limit." }
        if facts.isPausedForHeat, let threshold = facts.heatThreshold {
            return "Paused for heat. Charging resumes at \(threshold - Int(ChargeEngine.heatMargin)) °C."
        }
        if facts.mode == .calibrating {
            return facts.isWaitingForCharger ? "Calibrating. Connect the charger to go on."
                : "Calibrating. Your limit returns when it is done."
        }
        if facts.mode == .toppingUp {
            return facts.isToppedUp ? "Topped up. Your limit returns when you unplug."
                : "Charging to 100% once. Your limit returns when you unplug."
        }
        let applying = facts.isWaitingForMacOS ? "Applying… macOS can take two minutes." : "Applying…"
        let sailing = facts.isSailing && facts.override != .none
        var restoring = false
        if case .restoring = facts.override { restoring = true }
        if facts.isBusy {
            if facts.userRequestPending { return applying }
            if restoring { return "Putting your limit back…" }
            return sailing ? sailingCaption(facts) : applying
        }
        if let problem = facts.modeProblem { return problem }
        if let problem = facts.applyProblem { return problem }
        if sailing { return sailingCaption(facts) }
        if restoring { return "Putting your limit back…" }
        return facts.limitKnown ? facts.limit.sourceText : "The limit could not be read. Trying again…"
    }

    static func sailingCaption(_ facts: LimitFacts) -> String {
        let low = max(facts.userLimit - facts.sailingRange, LimitStops.sliderRange.lowerBound)
        return "Sailing between \(low)% and \(facts.userLimit)%."
    }

    /// A button only when the limit is at rest and it is not Hachibu's own.
    static func action(_ facts: LimitFacts) -> LimitAction? {
        guard facts.canChange, !facts.isBusy, facts.override == .none, facts.mode == .normal else { return nil }
        if let saved = facts.limit.savedToRestore { return .useSaved(saved) }
        return facts.limit.source == .outside ? .keepSystem : nil
    }
}
