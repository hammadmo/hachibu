import SwiftUI

/// The hero gauge: an ink brush circle left open. The arc runs clockwise
/// from 12 o'clock to the battery level; the gap is the charge left unused.
struct EnsoGauge: View {
    enum Tone { case normal, warning }

    /// 0 to 100. nil means no reading.
    var percent: Int?
    /// The limit, marked with a dot on the tick ring. nil or 100 hides it.
    var limit: Int?
    var tone: Tone = .normal
    var size: CGFloat = Metric.gaugeSize
    var showsSeal = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat { size / Metric.gaugeSize }
    private var isSmall: Bool { size < Metric.gaugeSize }
    private var ringColor: Color { tone == .warning ? Ink.warning : Ink.gauge }

    var body: some View {
        let tick = Metric.tickLength * scale
        let stroke = Metric.gaugeStroke * scale
        ZStack {
            TickRing(count: Metric.tickCount, length: tick)
                .stroke(Ink.tick, lineWidth: Metric.hairline)
            if let limit, limit < 100, percent != nil {
                RingDot(progress: Double(limit) / 100, inset: tick / 2, radius: Metric.limitDot * scale)
                    .fill(Ink.seal)
            }
            BrushArc(progress: Double(percent ?? 0) / 100, thickness: stroke)
                .fill(ringColor)
                .padding(tick + stroke / 2)
                .animation(reduceMotion ? nil : Motion.gauge, value: percent)
            Text(percent.map(String.init) ?? "–")
                .kitType(isSmall ? .gaugeNumeralSmall : .gaugeNumeral)
                .foregroundStyle(percent == nil ? Ink.textSoft : tone == .warning ? Ink.warning : Ink.text)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if showsSeal {
                SealMark(size: isSmall ? Metric.sealSmall : Metric.sealSize)
                    .padding(tick + stroke)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let percent else { return "No reading" }
        if let limit, limit < 100 { return "\(percent) percent, limit \(limit) percent" }
        return "\(percent) percent"
    }
}

/// The seal: a carved stamp with the character for eight. Decorative.
struct SealMark: View {
    var size: CGFloat = Metric.sealSize

    var body: some View {
        RoundedRectangle(cornerRadius: Metric.sealRadius, style: .continuous)
            .fill(Ink.seal)
            .frame(width: size, height: size)
            .overlay {
                Text("八")
                    .kitType(size < Metric.sealSize ? .sealSmall : .seal)
                    .foregroundStyle(Ink.onSeal)
            }
            .accessibilityHidden(true)
    }
}

/// A brush stroke along a circle: it swells just after the start and tapers
/// over the last 30%, with round ends. Filled, not stroked.
nonisolated struct BrushArc: Shape {
    /// 0 to 1 of the full circle.
    var progress: Double
    /// The band's width at its fullest.
    var thickness: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        guard p > 0.004 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let steps = max(Int(p * 240), 12)
        let start = -Double.pi / 2
        let sweep = p * 2 * Double.pi

        func half(_ t: Double) -> CGFloat {
            let attack = min(t / 0.05, 1)
            let taper = t > 0.7 ? 1 - (t - 0.7) / 0.3 * 0.6 : 1
            return thickness / 2 * CGFloat((0.7 + 0.3 * attack) * taper)
        }
        func point(_ t: Double, _ r: CGFloat) -> CGPoint {
            let angle = start + t * sweep
            return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
        }

        var path = Path()
        path.move(to: point(0, radius + half(0)))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            path.addLine(to: point(t, radius + half(t)))
        }
        // Round tip: from the outer edge, around the front, to the inner edge.
        let end = start + sweep
        path.addArc(center: point(1, radius), radius: half(1),
                    startAngle: .radians(end), endAngle: .radians(end + .pi), clockwise: false)
        for step in stride(from: steps - 1, through: 0, by: -1) {
            let t = Double(step) / Double(steps)
            path.addLine(to: point(t, radius - half(t)))
        }
        // Round heel: from the inner edge, around the back, to the outer edge.
        path.addArc(center: point(0, radius), radius: half(0),
                    startAngle: .radians(start + .pi), endAngle: .radians(start + 2 * .pi), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Short radial ticks around the edge, like a dial.
nonisolated struct TickRing: Shape {
    var count: Int
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * Double.pi
            let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
            path.move(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
            path.addLine(to: CGPoint(x: center.x + dx * (outer - length), y: center.y + dy * (outer - length)))
        }
        return path
    }
}

/// A dot on the edge of a circle, at `progress` clockwise from 12 o'clock.
nonisolated struct RingDot: Shape {
    var progress: Double
    var inset: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = -Double.pi / 2 + progress * 2 * Double.pi
        let r = min(rect.width, rect.height) / 2 - inset
        let center = CGPoint(x: rect.midX + r * CGFloat(cos(angle)), y: rect.midY + r * CGFloat(sin(angle)))
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2))
    }
}
