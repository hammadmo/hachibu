import HachibuKit
import SwiftUI

extension View {
    /// A raised card: paper or lacquer one step up, with a hairline border.
    func kitCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
        return padding(Space.md)
            .frame(maxWidth: .infinity)
            .background(shape.fill(Ink.raised))
            .overlay(shape.strokeBorder(Ink.hairline, lineWidth: Metric.hairline))
    }
}

/// Watts from the charger, used by the Mac, and into or out of the battery.
/// A missing value shows a dash.
struct PowerFlowCard: View {
    var charger: Double?
    var mac: Double?
    /// Positive while the battery charges, negative while it discharges.
    var battery: Double?
    /// "Charger", or the charger's rating: "30 W charger".
    var chargerLabel = "Charger"

    /// From a reading: off the charger it reads 0 W, and the arrow beside
    /// the battery points to the Mac while the battery feeds it.
    init(flow: PowerFlow) {
        self.init(charger: flow.charger, mac: flow.mac, battery: flow.battery, chargerLabel: flow.chargerLabel)
    }

    init(charger: Double?, mac: Double?, battery: Double?, chargerLabel: String = "Charger") {
        self.charger = charger
        self.mac = mac
        self.battery = battery
        self.chargerLabel = chargerLabel
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            column(chargerLabel, charger, emphasized: (charger ?? 0) >= 0.05)
            KitIconView(icon: .flow).foregroundStyle(Ink.textSoft)
            column("Mac", mac)
            KitIconView(icon: .flow).foregroundStyle(Ink.textSoft)
                .rotationEffect(.degrees((battery ?? 0) < 0 ? 180 : 0))
            column("Battery", battery)
        }
        .kitCard()
        .accessibilityElement(children: .combine)
    }

    private func column(_ label: String, _ value: Double?, emphasized: Bool = false) -> some View {
        VStack(spacing: Space.xs) {
            Text(label).kitType(.meta).foregroundStyle(Ink.textSoft)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(Watts.text(value)).kitType(.numeral)
                .foregroundStyle(emphasized ? Ink.accentText : Ink.text)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The status and the line under it.
struct StatusLine: View {
    var title: String
    var detail: String?
    var isWarning = false

    var body: some View {
        VStack(spacing: Space.xs) {
            Text(title).kitType(.status).foregroundStyle(isWarning ? Ink.warning : Ink.text)
            if let detail {
                Text(detail).kitType(.meta).foregroundStyle(Ink.textSoft)
            }
        }
        .multilineTextAlignment(.center)
        // A fixed height for the usual two lines keeps what follows on the grid.
        .frame(minHeight: Metric.statusHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Up to three "label value" pairs across the width.
struct StatRow: View {
    struct Stat: Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    var stats: [Stat]

    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 { Spacer(minLength: 0) }
                HStack(spacing: Space.xs) {
                    Text(stat.label).foregroundStyle(Ink.textSoft)
                    Text(stat.value).foregroundStyle(Ink.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .kitType(.meta)
    }
}

/// Battery level over the last 24 hours, with the limit as a dashed line.
struct LevelSparkline: View {
    /// Levels from 0 to 100, oldest first.
    var levels: [Double]
    var limit: Int?

    /// The bottom of the scale: a little under the lowest level, in tens, so
    /// a day spent near the limit does not draw as a flat line at the top.
    private var floor: Double {
        let lowest = min(levels.filter(\.isFinite).min() ?? 0, Double(limit ?? 100))
        return max((lowest / 10).rounded(.down) * 10 - 10, 0)
    }

    var body: some View {
        ZStack {
            if levels.count < 2 {
                Text("Collecting data").kitType(.meta).foregroundStyle(Ink.textSoft)
            } else {
                if let limit, limit < 100 {
                    SparkPath(levels: [Double(limit), Double(limit)], floor: floor)
                        .stroke(Ink.accent, style: StrokeStyle(lineWidth: Metric.hairline, dash: [3, 4]))
                }
                SparkPath(levels: levels, floor: floor)
                    .stroke(Ink.gauge, style: StrokeStyle(lineWidth: Metric.sliderTrack,
                                                           lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: Metric.sparkHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery level, last 24 hours")
    }
}

/// A line through levels on a scale from `floor` to 100, so the limit line
/// and the level line share one axis.
nonisolated struct SparkPath: Shape {
    var levels: [Double]
    var floor: Double = 0

    func path(in rect: CGRect) -> Path {
        guard levels.count > 1 else { return Path() }
        var path = Path()
        // The line breaks where nothing was recorded.
        for run in ChartLine.runs(in: levels) {
            for index in run {
                let x = rect.minX + rect.width * CGFloat(index) / CGFloat(levels.count - 1)
                let y = rect.maxY - rect.height * CGFloat((min(max(levels[index], floor), 100) - floor) / max(100 - floor, 1))
                if index == run.lowerBound { path.move(to: CGPoint(x: x, y: y)) }
                if index != run.lowerBound || run.count == 1 { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        return path
    }
}

/// A problem shown where the status is, with one way to fix it.
struct KitBanner: View {
    var title: String
    var message: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                KitIconView(icon: .warning)
                Text(title).kitType(.labelStrong)
            }
            .foregroundStyle(Ink.warning)
            Text(message).kitType(.meta).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(.kit(.secondary))
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Ink.warningWash))
        .overlay(shape.strokeBorder(Ink.warning, lineWidth: Metric.hairline))
    }
}

/// A hairline between groups.
struct KitDivider: View {
    var body: some View {
        Rectangle().fill(Ink.hairline).frame(height: Metric.hairline)
    }
}

/// A dialog over a window: a short title, what to do as numbered steps, and
/// up to two buttons. The window behind it is dimmed and cannot be clicked.
/// Use it only when the person must do something outside Hachibu.
struct KitDialog: View {
    var title: String
    var message: String?
    var steps: [String] = []
    /// The step under way, counted from 0: it is drawn stronger and the
    /// others softer. nil draws all steps alike.
    var currentStep: Int?
    /// Small print under the steps.
    var note: String?
    /// Shown instead of the buttons while Hachibu is busy.
    var progress: String?
    var primaryTitle: String
    var primary: () -> Void = {}
    var secondaryTitle: String?
    var secondary: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).kitType(.title).foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message).kitType(.body).foregroundStyle(Ink.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            let dimmed = currentStep != nil && currentStep != index
                            Text("\(index + 1)").kitType(.numeral).foregroundStyle(dimmed ? Ink.textSoft : Ink.accentText)
                            Text(step).kitType(currentStep == index ? .labelStrong : .body)
                                .foregroundStyle(dimmed ? Ink.textSoft : Ink.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let note {
                Text(note).kitType(.meta).foregroundStyle(Ink.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.sm) {
                if let progress {
                    Text(progress).kitType(.body).foregroundStyle(Ink.textSoft)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    if let secondaryTitle {
                        Button(secondaryTitle, action: secondary).buttonStyle(.kit(.ghost)).fixedSize()
                    }
                    Button(primaryTitle, action: primary).buttonStyle(.kit()).fixedSize()
                }
            }
            .frame(minHeight: Metric.buttonHeight)
        }
        .padding(Space.xl)
        .frame(width: Metric.dialogWidth, alignment: .leading)
        .background(shape.fill(Ink.surface))
        .overlay(shape.strokeBorder(Ink.outline, lineWidth: Metric.hairline))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.scrim)
        .contentShape(.rect)
        .accessibilityAddTraits(.isModal)
    }
}
