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
/// light or dark menu bar. A warning adds an exclamation mark: never color alone.
nonisolated enum MenuBarGlyph {
    static func image(for mark: MenuBarMark) -> NSImage {
        let side: CGFloat = 16
        let stroke: CGFloat = 2
        let warning = mark.isWarning
        let percent = mark.percent
        let size = NSSize(width: warning ? side + 7 : side, height: side)
        let image = NSImage(size: size, flipped: false) { _ in
            let radius = (side - stroke) / 2 - 0.5
            let center = NSPoint(x: side / 2, y: side / 2)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath()
            ring.lineWidth = stroke
            ring.lineCapStyle = .round
            if let percent {
                // From 12 o'clock, clockwise, to the battery level.
                let sweep = 360 * max(CGFloat(percent) / 100, 0.04)
                ring.appendArc(withCenter: center, radius: radius, startAngle: 90,
                               endAngle: 90 - min(sweep, 359.9), clockwise: true)
                ring.stroke()
            } else {
                ring.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
                ring.setLineDash([2, 3], count: 2, phase: 0)
                ring.stroke()
            }
            if warning {
                NSBezierPath(roundedRect: NSRect(x: side + 3, y: 6, width: 2.4, height: 8), xRadius: 1.2, yRadius: 1.2).fill() // grid: ok glyph strokes inside a 16 pt icon
                NSBezierPath(ovalIn: NSRect(x: side + 2.8, y: 2, width: 2.8, height: 2.8)).fill() // grid: ok glyph strokes inside a 16 pt icon
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
