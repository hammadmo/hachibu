import SwiftUI

/// Views name a KitIcon, never an SF Symbol, so the set changes in one place.
enum KitIcon {
    case charger, mac, battery, flow, warning, heat, history, settings

    var symbol: String {
        switch self {
        case .charger: "powerplug"
        case .mac: "laptopcomputer"
        case .battery: "minus.plus.batteryblock"
        case .flow: "arrow.right"
        case .warning: "exclamationmark.triangle"
        case .heat: "thermometer.medium"
        case .history: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

struct KitIconView: View {
    let icon: KitIcon
    var size: CGFloat = Metric.iconSize

    var body: some View {
        Image(systemName: icon.symbol)
            .font(.system(size: size, weight: .light))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The menu bar glyph: an open ring whose length follows the battery level.
/// One color, so the menu bar can tint it.
struct EnsoGlyph: View {
    /// 0 to 100. nil draws a faint full ring.
    var percent: Int?
    var size: CGFloat = Metric.glyphSize

    var body: some View {
        let inset = Metric.glyphStroke / 2
        Circle()
            .trim(from: 0, to: CGFloat(min(max(percent ?? 100, 4), 100)) / 100)
            .stroke(style: StrokeStyle(lineWidth: Metric.glyphStroke, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .opacity(percent == nil ? 0.4 : 1)
            .padding(inset)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
