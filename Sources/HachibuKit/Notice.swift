import Foundation

/// A notification Hachibu can send, with its words. Whether it is sent is
/// decided here too, from the kinds the user left switched on.
public enum Notice: Equatable, Sendable {
    case limitNotHolding(percent: Int, limit: Int)
    /// macOS started charging to 100% on its own.
    case fullChargeByMacOS(limit: Int)
    /// A Top Up reached 100%. `limit` is the user's limit, which returns later.
    case topUpFinished(limit: Int)
    /// A calibration is over and the user's limit is confirmed back.
    case calibrationFinished(limit: Int)

    /// The four switches in Settings > General.
    public enum Kind: String, CaseIterable, Sendable {
        case limitNotHolding, fullCharge, topUpFinished, calibrationFinished
    }

    public struct Message: Equatable, Sendable {
        /// One per kind, so a newer notice replaces the older one of its kind.
        public var identifier: String
        public var title: String
        public var body: String
    }

    public var kind: Kind {
        switch self {
        case .limitNotHolding: .limitNotHolding
        case .fullChargeByMacOS: .fullCharge
        case .topUpFinished: .topUpFinished
        case .calibrationFinished: .calibrationFinished
        }
    }

    /// What to send. nil when the user switched this kind off.
    public func message(allowed: Set<Kind>) -> Message? {
        guard allowed.contains(kind) else { return nil }
        switch self {
        case .limitNotHolding(let percent, let limit):
            return Message(identifier: "limit-not-holding", title: "Limit not holding",
                           body: "Battery is at \(percent)% and still charging. The limit is \(limit)%.")
        case .fullChargeByMacOS(let limit):
            // Said without a promise about the limit: a Top Up or a
            // calibration may be deciding that, not this full charge.
            return Message(identifier: "full-charge-by-macos", title: "Full charge by macOS",
                           body: limit < 100
                               ? "macOS is charging past your \(limit)% limit to keep its estimates accurate. Nothing is wrong with the limit."
                               : "macOS is charging to 100% to keep its estimates accurate.")
        case .topUpFinished(let limit):
            return Message(identifier: "top-up-finished", title: "Top Up finished",
                           body: limit < 100
                               ? "The battery is fully charged. It stays at 100% until you unplug the charger; then your limit of \(limit)% returns."
                               : "The battery is fully charged.")
        case .calibrationFinished(let limit):
            return Message(identifier: "calibration-finished", title: "Calibration finished",
                           body: limit < 100 ? "Your limit of \(limit)% is back. macOS drains the battery down to it."
                               : "The battery is fully charged and there is no limit.")
        }
    }
}
