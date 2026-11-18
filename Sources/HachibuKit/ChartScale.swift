import Foundation

/// The vertical scale of a chart: bounds on round numbers that hold every
/// value, and never a span so small that noise looks like a cliff.
public enum ChartScale {
    public static func bounds(for values: [Double], including extra: [Double] = [],
                              step: Double, minimumSpan: Double) -> ClosedRange<Double> {
        let all = (values + extra).filter(\.isFinite)
        guard let low = all.min(), let high = all.max(), step > 0 else { return 0...max(minimumSpan, 1) }
        var lower = (low / step).rounded(.down) * step
        var upper = (high / step).rounded(.up) * step
        if upper - lower < minimumSpan {
            let middle = (lower + upper) / 2
            lower = ((middle - minimumSpan / 2) / step).rounded(.down) * step
            upper = lower + (minimumSpan / step).rounded(.up) * step
        }
        return lower...upper
    }
}
