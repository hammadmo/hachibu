import Foundation

/// How power values read on screen: one decimal below 10 W, whole watts
/// above, and a dash for a missing value (never a false 0).
public enum Watts {
    public static func text(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        let tenths = (abs(value) * 10).rounded() / 10
        if tenths == 0 { return "0 W" }
        if tenths < 10 { return String(format: "%.1f W", tenths) }
        return "\(Int(abs(value).rounded())) W"
    }
}

/// A length of time in words: "35 min", "1 h 28 min", "2 h".
public enum TimeText {
    public static func text(minutes: Int) -> String {
        let minutes = max(minutes, 1)
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
