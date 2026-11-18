import SwiftUI

/// The limit slider: a hairline track, an ink or gold fill, a gold thumb.
/// It snaps to `stops`. Arrow keys move one stop; VoiceOver sees a system slider.
struct LimitSlider: View {
    @Binding var value: Int
    /// Allowed values, ascending, for example [80, 85, 90, 95, 100].
    var stops: [Int]
    /// The scale the track shows. It stays the same whether or not the lower
    /// stops are available, so the thumb for 80% always sits in one place.
    /// The part below the first stop is drawn dashed: not available yet.
    var scale: ClosedRange<Int> = 20...100

    @Environment(\.forcedPartState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var dragging = false

    private var state: PartState {
        forced ?? (!isEnabled ? .disabled : dragging ? .pressed : hovering ? .hover : focused ? .focused : .rest)
    }

    private var low: Int { scale.lowerBound }
    private var high: Int { scale.upperBound }
    private var fraction: CGFloat { fraction(of: value) }

    private func fraction(of level: Int) -> CGFloat {
        high > low ? CGFloat(min(max(level, low), high) - low) / CGFloat(high - low) : 0
    }

    var body: some View {
        GeometryReader { proxy in
            let thumb = Metric.sliderThumb
            let travel = max(proxy.size.width - thumb, 1)
            ZStack(alignment: .leading) {
                let locked = fraction(of: stops.first ?? low) * travel + thumb / 2
                Capsule().fill(Ink.hairline)
                    .frame(height: Metric.sliderTrack)
                    .padding(.leading, locked)
                Line().stroke(Ink.tick, style: StrokeStyle(lineWidth: Metric.sliderTrack, dash: [2, 4]))
                    .frame(width: locked, height: Metric.sliderTrack)
                Capsule().fill(Ink.gauge)
                    .frame(width: max(fraction * travel + thumb / 2 - locked, 0), height: Metric.sliderTrack)
                    .padding(.leading, locked)
                Circle().fill(Ink.accent)
                    .frame(width: thumb, height: thumb)
                    .background {
                        if state == .hover || state == .pressed {
                            Circle().fill(Ink.wash).padding(-Space.xs)
                        }
                    }
                    .overlay {
                        if state == .focused {
                            Circle().inset(by: -Metric.focusRing * 2)
                                .strokeBorder(Ink.accent, lineWidth: Metric.focusRing)
                        }
                    }
                    .scaleEffect(state == .pressed ? 1.15 : 1)
                    .padding(.leading, fraction * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    snap(to: (drag.location.x - thumb / 2) / travel)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: Metric.sliderHeight)
        .opacity(state == .disabled ? 0.4 : 1)
        .animation(Motion.press, value: state)
        .animation(Motion.hover, value: value)
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: step(-1)
            case .right, .up: step(1)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(value) }, set: { snap(toValue: $0) }),
                   in: Double(low)...Double(max(high, low + 1))) { Text("Limit") }
                .accessibilityValue("\(value) percent")
        }
    }

    private func snap(to fraction: CGFloat) {
        snap(toValue: Double(low) + Double(min(max(fraction, 0), 1)) * Double(high - low))
    }

    private func snap(toValue target: Double) {
        guard let nearest = stops.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) else { return }
        if nearest != value { value = nearest }
    }

    private func step(_ delta: Int) {
        guard let index = stops.firstIndex(of: value) ?? stops.firstIndex(where: { $0 >= value }) else { return }
        value = stops[min(max(index + delta, 0), stops.count - 1)]
    }
}

/// A horizontal line through the middle of its frame.
nonisolated struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
