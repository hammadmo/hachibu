import HachibuKit
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

/// The menu bar glyph, exactly as the menu bar draws it (`MenuBarGlyph`):
/// a small battery whose charge is a brush ring. One color, so the menu bar
/// can tint it.
struct EnsoGlyph: View {
    /// 0 to 100. nil draws the "no reading" glyph.
    var percent: Int?
    var isWarning = false

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(for: MenuBarMark.choose(percent: percent, warning: isWarning)))
            .renderingMode(.template)
            .accessibilityHidden(true)
    }
}
