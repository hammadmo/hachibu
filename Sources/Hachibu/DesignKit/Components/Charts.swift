import SwiftUI

/// A line chart in the kit's hand: hairline grid, ink or gold lines, a
/// dashed guide, and a marker that follows the pointer.
struct KitChart: View {
    struct Series: Identifiable {
        enum Weight { case primary, secondary }
        var id: String
        var values: [Double]
        var weight: Weight = .primary
    }

    var series: [Series]
    var bounds: ClosedRange<Double>
    /// A level to mark with a dashed line, for example the limit.
    var guide: Double?
    /// Labels for the top and bottom of the scale.
    var scaleLabel: (Double) -> String
    /// Where the pointer is, 0 at the leading edge to 1 at the trailing edge.
    @Binding var hover: Double?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                KitDivider()
                Spacer(minLength: 0)
                KitDivider()
                Spacer(minLength: 0)
                KitDivider()
            }
            if let guide {
                ChartLine(values: [guide, guide], bounds: bounds)
                    .stroke(Ink.accent, style: StrokeStyle(lineWidth: Metric.hairline, dash: [3, 4]))
            }
            if let first = series.first(where: { $0.weight == .primary }) {
                ChartLine(values: first.values, bounds: bounds, closed: true)
                    .fill(Ink.wash)
            }
            ForEach(series) { line in
                ChartLine(values: line.values, bounds: bounds)
                    .stroke(line.weight == .primary ? Ink.gauge : Ink.textSoft,
                            style: StrokeStyle(lineWidth: line.weight == .primary ? Metric.sliderTrack : Metric.hairline,
                                               lineCap: .round, lineJoin: .round))
            }
            if let hover {
                ChartMarker(fraction: hover, values: series.map(\.values), bounds: bounds, kind: .rule)
                    .stroke(Ink.textSoft, lineWidth: Metric.hairline)
                ChartMarker(fraction: hover, values: series.map(\.values), bounds: bounds, kind: .dots, dot: Metric.chartDot)
                    .fill(Ink.accent)
            }
        }
        .overlay(alignment: .topTrailing) { scaleText(bounds.upperBound) }
        .overlay(alignment: .bottomTrailing) { scaleText(bounds.lowerBound) }
        .frame(height: Metric.chartHeight)
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hover = Snapshot.isRunning ? nil : min(max(point.x / max(chartWidth, 1), 0), 1)
            case .ended: hover = nil
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
        .accessibilityHidden(true)
    }

    @State private var chartWidth: CGFloat = 1

    private func scaleText(_ value: Double) -> some View {
        Text(scaleLabel(value)).kitType(.meta).foregroundStyle(Ink.textSoft)
            .padding(.horizontal, Space.xs)
            .background(Ink.raised)
            .padding(.vertical, Space.xs)
    }
}

/// A line through values on a fixed scale. Closed, it runs down to the
/// baseline so it can be filled.
nonisolated struct ChartLine: Shape {
    var values: [Double]
    var bounds: ClosedRange<Double>
    var closed = false

    static func point(_ index: Int, of values: [Double], bounds: ClosedRange<Double>, in rect: CGRect) -> CGPoint {
        let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
        let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
        let level = (min(max(values[index], bounds.lowerBound), bounds.upperBound) - bounds.lowerBound) / span
        return CGPoint(x: x, y: rect.maxY - rect.height * CGFloat(level))
    }

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var path = Path()
        // A value that is not a number was not measured: the line stops
        // there and starts again at the next measured point.
        for run in Self.runs(in: values) {
            let points = run.map { Self.point($0, of: values, bounds: bounds, in: rect) }
            path.move(to: points[0])
            // A single measured point between two gaps still shows, as a dot.
            if points.count == 1 { path.addLine(to: points[0]) }
            for point in points.dropFirst() { path.addLine(to: point) }
            if closed, let last = points.last {
                path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
                path.closeSubpath()
            }
        }
        return path
    }

    /// The stretches of indices whose values are numbers.
    static func runs(in values: [Double]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, value) in values.enumerated() {
            if value.isFinite {
                if start == nil { start = index }
            } else if let from = start {
                runs.append(from..<index)
                start = nil
            }
        }
        if let from = start { runs.append(from..<values.count) }
        return runs
    }
}

/// The pointer marker: a vertical rule, and a dot on each line.
nonisolated struct ChartMarker: Shape {
    enum Kind { case rule, dots }
    var fraction: Double
    var values: [[Double]]
    var bounds: ClosedRange<Double>
    var kind: Kind
    var dot: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + rect.width * CGFloat(fraction)
        switch kind {
        case .rule:
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        case .dots:
            for line in values where line.count > 1 {
                let index = Int((fraction * Double(line.count - 1)).rounded())
                guard line[index].isFinite else { continue }
                let point = ChartLine.point(index, of: line, bounds: bounds, in: rect)
                path.addEllipse(in: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2))
            }
        }
        return path
    }
}

/// One chart in a card: a title, the value now (or under the pointer), the
/// chart, and the ends of its time range.
struct ChartCard: View {
    var title: String
    var series: [KitChart.Series]
    var bounds: ClosedRange<Double>
    var guide: Double?
    /// Formats one value, for example "80%" or "9.2 W".
    var value: (Double) -> String
    /// Names for the lines, when there is more than one.
    var legend: [String] = []
    /// What the header says when the pointer is elsewhere. nil shows the latest value.
    var summary: String?
    /// The time under the pointer, from 0 (start of the range) to 1 (now).
    var time: (Double) -> String
    var startLabel: String
    var endLabel = "Now"

    @State private var hover: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(title).kitType(.section).foregroundStyle(Ink.accentText)
                Spacer(minLength: Space.sm)
                Text(reading).kitType(.numeral).foregroundStyle(Ink.text)
                    .lineLimit(1)
            }
            KitChart(series: series, bounds: bounds, guide: guide, scaleLabel: value, hover: $hover)
            HStack(spacing: Space.sm) {
                Text(hover.map(time) ?? startLabel)
                Spacer(minLength: 0)
                if hover == nil && !legend.isEmpty {
                    ForEach(Array(legend.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: Space.xs) {
                            Capsule().fill(index == 0 ? Ink.gauge : Ink.textSoft)
                                .frame(width: Space.md, height: Metric.sliderTrack)
                            Text(name)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(hover == nil ? endLabel : "")
            }
            .kitType(.meta)
            .foregroundStyle(Ink.textSoft)
        }
        .kitCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(reading)
    }

    private var reading: String {
        let position = hover ?? 1
        if hover == nil, let summary { return summary }
        let parts = series.enumerated().compactMap { index, line -> String? in
            guard line.values.count > 1 else { return nil }
            // Under the pointer: what was measured there, or a dash for a
            // gap. With no pointer: the latest measured value.
            let under = line.values[Int((position * Double(line.values.count - 1)).rounded())]
            let shown = hover == nil ? line.values.last(where: \.isFinite) ?? .nan : under
            let text = shown.isFinite ? value(shown) : "–"
            return legend.indices.contains(index) ? "\(legend[index]) \(text)" : text
        }
        return parts.joined(separator: " · ")
    }
}
