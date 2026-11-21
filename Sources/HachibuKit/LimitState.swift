import Foundation

/// Who set the limit that macOS is holding.
public enum LimitSource: Equatable, Sendable {
    case hachibu, outside, none
}

/// The limit macOS holds, next to the one Hachibu saved.
public struct LimitState: Equatable, Sendable {
    /// The limit macOS is holding. nil means charging goes to 100%.
    public var system: Int?
    /// The limit the user last chose in Hachibu. nil before the first choice.
    public var saved: Int?

    public init(system: Int?, saved: Int?) {
        self.system = system.flatMap { $0 >= 100 ? nil : $0 }
        self.saved = saved
    }

    /// Where charging stops: the system limit, or 100 with no limit.
    public var effective: Int { system ?? 100 }

    public var source: LimitSource {
        guard let system else { return .none }
        return saved == system ? .hachibu : .outside
    }

    /// A saved limit that differs from what macOS holds, so the user can take it back.
    public var savedToRestore: Int? {
        guard let saved, saved != effective else { return nil }
        return saved
    }

    public var valueText: String { system.map { "\($0)%" } ?? "No limit" }

    public var sourceText: String {
        switch source {
        case .hachibu: "Set by Hachibu"
        case .outside: "Set outside Hachibu"
        case .none: saved.map { $0 < 100 } == true ? "No limit. Turned off outside Hachibu" : "Charging goes to 100%"
        }
    }
}

/// The values the limit slider may land on.
public enum LimitStops {
    /// The stops macOS offers, cleaned up: sorted, unique, 20 to 100, always with 100.
    public static func normalized(_ available: [Int]) -> [Int] {
        let cleaned = Set(available.filter { (20...100).contains($0) }).union([100])
        return cleaned.sorted()
    }

    /// The lowest and highest limit a person can choose.
    public static let sliderRange = 20...100

    /// With the helper running, every whole percent from 20 to 100.
    public static func all(official: [Int], helperRunning: Bool) -> [Int] {
        helperRunning ? Array(sliderRange) : normalized(official)
    }

    public static func snap(_ value: Int, to stops: [Int]) -> Int {
        stops.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}

/// Decides when to say "Limit not holding": the battery is more than a
/// margin above the limit and still charging, for long enough that it is
/// not a blip.
public struct LimitWatch: Equatable, Sendable {
    public static let margin = 2
    public static let delay: TimeInterval = 120

    public private(set) var overSince: Date?
    public private(set) var isWarning = false

    public init() {}

    /// Feed every reading. Returns true at the moment the warning starts.
    /// `suppressed` is for charging past the limit on purpose (a top up).
    public mutating func update(reading: BatteryReading?, limit: Int?, suppressed: Bool = false, now: Date) -> Bool {
        guard let reading, let limit, limit < 100, !suppressed, !reading.fullChargeOverride,
              reading.isCharging, reading.percent > limit + Self.margin else {
            overSince = nil
            isWarning = false
            return false
        }
        let since = overSince ?? now
        overSince = since
        let was = isWarning
        isWarning = now.timeIntervalSince(since) >= Self.delay
        return isWarning && !was
    }
}

/// Notices the moment macOS begins a full charge of its own, so it can be
/// announced once. A full charge already under way when Hachibu starts is
/// not announced: Hachibu did not see it begin.
public struct FullChargeWatch: Equatable, Sendable {
    public private(set) var isActive = false
    private var hasSeenAReading = false

    public init() {}

    /// Feed every reading. Returns true at the moment a full charge starts.
    public mutating func update(isFullCharge: Bool) -> Bool {
        defer {
            isActive = isFullCharge
            hasSeenAReading = true
        }
        return isFullCharge && !isActive && hasSeenAReading
    }
}

/// Where the Mac's power comes from, as the menu bar icon shows it inside
/// the ring: nothing on battery, two plug pins on the charger without
/// charging, a bolt while charging.
public enum PowerMark: Equatable, Sendable {
    case battery, plugged, charging

    public static func choose(_ reading: BatteryReading?) -> PowerMark {
        guard let reading, reading.isPluggedIn else { return .battery }
        return reading.isCharging ? .charging : .plugged
    }
}

/// What the menu bar item shows.
public enum MenuBarMark: Equatable, Sendable {
    case level(Int), warning(Int), unknown

    public static func choose(percent: Int?, warning: Bool) -> MenuBarMark {
        guard let percent else { return .unknown }
        return warning ? .warning(percent) : .level(percent)
    }

    public var percent: Int? {
        switch self {
        case .level(let value), .warning(let value): value
        case .unknown: nil
        }
    }

    public var isWarning: Bool {
        if case .warning = self { return true }
        return false
    }

    /// The text beside the icon. nil when the user turned the percentage off.
    public func title(showPercentage: Bool) -> String? {
        guard showPercentage else { return nil }
        return percent.map { "\($0)%" } ?? "–"
    }
}
