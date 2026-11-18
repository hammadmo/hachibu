import AppKit
import HachibuKit
import SwiftUI

/// What sits in the menu bar: the open ring, and the percentage beside it.
struct MenuBarLabel: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private var preferences = Preferences.shared

    var body: some View {
        let mark = MenuBarMark.choose(percent: monitor.reading?.percent, warning: monitor.isWarning)
        HStack(spacing: Space.xs) {
            Image(nsImage: MenuBarGlyph.image(for: mark))
            if let title = mark.title(showPercentage: preferences.showPercentage) {
                Text(title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hachibu")
        .accessibilityValue(accessibilityText(mark))
        .task {
            monitor.start()
            Launch.run(model: model, monitor: monitor) { openWindow(id: $0) }
        }
    }

    private func accessibilityText(_ mark: MenuBarMark) -> String {
        guard let percent = mark.percent else { return "No battery reading" }
        return "Battery \(percent) percent, \(monitor.statusTitle)"
    }
}

/// Draws the menu bar glyph as a template image, so macOS colors it for a
/// light or dark menu bar: a small battery whose charge is an enso, a brush
/// ring that is thick where the brush lands and thin where it lifts, as long
/// as the battery is full. A warning adds an exclamation mark: never color alone.
nonisolated enum MenuBarGlyph {
    // All sizes are in points inside a 16 pt tall menu bar icon.
    private static let height: CGFloat = 16
    private static let body = NSRect(x: 0.7, y: 0.7, width: 17.6, height: 14.6) // grid: ok glyph strokes inside a 16 pt icon
    private static let bodyRadius: CGFloat = 5
    private static let bodyLine: CGFloat = 1.1
    private static let terminal = NSRect(x: 19.4, y: 5.7, width: 2, height: 4.6) // grid: ok glyph strokes inside a 16 pt icon
    private static let ringRadius: CGFloat = 4.5
    private static let brushThick: CGFloat = 2.9
    private static let brushThin: CGFloat = 0.9
    private static let batteryWidth: CGFloat = 22
    private static let warningWidth: CGFloat = 6

    static func image(for mark: MenuBarMark) -> NSImage {
        let warning = mark.isWarning
        let percent = mark.percent
        let size = NSSize(width: batteryWidth + (warning ? warningWidth : 0), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outline = NSBezierPath(roundedRect: body, xRadius: bodyRadius, yRadius: bodyRadius)
            outline.lineWidth = bodyLine
            outline.stroke()
            NSBezierPath(roundedRect: terminal, xRadius: terminal.width / 2, yRadius: terminal.width / 2).fill()
            let center = NSPoint(x: body.midX, y: body.midY)
            if let percent {
                brush(center: center, percent: CGFloat(percent)).fill()
            } else {
                // No reading: a dotted ring where the charge would be.
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                                       width: ringRadius * 2, height: ringRadius * 2))
                ring.lineWidth = 1.2
                ring.setLineDash([1.4, 2.4], count: 2, phase: 0)
                ring.stroke()
            }
            if warning {
                let x = batteryWidth + 1.6
                NSBezierPath(roundedRect: NSRect(x: x, y: 6, width: 2.4, height: 8), xRadius: 1.2, yRadius: 1.2).fill() // grid: ok glyph strokes inside a 16 pt icon
                NSBezierPath(ovalIn: NSRect(x: x - 0.2, y: 2, width: 2.8, height: 2.8)).fill() // grid: ok glyph strokes inside a 16 pt icon
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The brush ring: from 12 o'clock, clockwise, as far as the level,
    /// tapering from the thick start to the thin end.
    private static func brush(center: NSPoint, percent: CGFloat) -> NSBezierPath {
        let sweep = min(360 * max(percent / 100, 0.06), 356)
        let steps = 60
        var outer: [NSPoint] = []
        var inner: [NSPoint] = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let angle = (90 - sweep * t) * .pi / 180
            let width = brushThick - (brushThick - brushThin) * pow(t, 1.4)
            outer.append(NSPoint(x: center.x + (ringRadius + width / 2) * cos(angle),
                                 y: center.y + (ringRadius + width / 2) * sin(angle)))
            inner.append(NSPoint(x: center.x + (ringRadius - width / 2) * cos(angle),
                                 y: center.y + (ringRadius - width / 2) * sin(angle)))
        }
        let path = NSBezierPath()
        path.move(to: outer[0])
        outer.dropFirst().forEach(path.line(to:))
        inner.reversed().forEach(path.line(to:))
        path.close()
        return path
    }
}
