import AppKit
import SwiftUI

/// Every kit part in every state. Shown instead of the app when
/// APP_KIT_GALLERY=1. With APP_SNAPSHOT=<dir> it writes
/// kit-gallery-light.png and kit-gallery-dark.png, then quits.
struct KitGallery: View {
    static let enabled = ProcessInfo.processInfo.environment["APP_KIT_GALLERY"] == "1"
    static let size = CGSize(width: 1240, height: 880)

    @State private var limit = 80
    @State private var on = true
    @State private var off = false
    private let stops = [80, 85, 90, 95, 100]

    var body: some View {
        HStack(alignment: .top, spacing: Space.section) {
            VStack(alignment: .leading, spacing: Space.sm) {
                heading("Popover")
                PopoverSample()
            }
            VStack(alignment: .leading, spacing: Space.xl) {
                gauges
                buttons
                sliders
                cards
                marks
            }
        }
        .padding(Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.surface)
        .focusEffectDisabled()
        .task {
            // The gallery needs more room than the app's window.
            NSApp.windows.first { $0.canBecomeMain }?.setContentSize(Self.size)
            await snapshotIfRequested()
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).kitType(.meta).foregroundStyle(Ink.textSoft)
    }

    private var gauges: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            heading("Ensō gauge: holding, charging, no limit, limit not holding, no reading")
            HStack(spacing: Space.lg) {
                EnsoGauge(percent: 80, limit: 80, size: Metric.gaugeSmall)
                EnsoGauge(percent: 46, limit: 80, size: Metric.gaugeSmall)
                EnsoGauge(percent: 100, limit: 100, size: Metric.gaugeSmall)
                EnsoGauge(percent: 86, limit: 80, tone: .warning, size: Metric.gaugeSmall)
                EnsoGauge(percent: nil, limit: 80, size: Metric.gaugeSmall)
            }
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            heading("Buttons")
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                GridRow {
                    Text("")
                    ForEach(PartState.allCases, id: \.self) { heading($0.rawValue) }
                }
                stateRow("Primary") { Button("Top Up") {}.buttonStyle(.kit()) }
                stateRow("Secondary") { Button("Discharge") {}.buttonStyle(.kit(.secondary)) }
                stateRow("Ghost") { Button("Settings…") {}.buttonStyle(.kit(.ghost)) }
            }
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            heading("Slider, toggle, tab")
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
                stateRow("Slider") { LimitSlider(value: $limit, stops: stops) }
                stateRow("Toggle on") { Toggle("Sample", isOn: $on).toggleStyle(.kit) }
                stateRow("Toggle off") { Toggle("Sample", isOn: $off).toggleStyle(.kit) }
                stateRow("Tab") { Button("Charging") {}.buttonStyle(KitTabStyle(isSelected: false)) }
            }
        }
    }

    private func stateRow(_ name: String, @ViewBuilder part: @escaping () -> some View) -> some View {
        GridRow {
            Text(name).kitType(.label).foregroundStyle(Ink.text)
            ForEach(PartState.allCases, id: \.self) { state in
                part()
                    .environment(\.forcedPartState, state)
                    .disabled(state == .disabled)
                    .frame(width: 96)
            }
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                heading("Power flow: charging, on battery, no reading")
                PowerFlowCard(charger: 28.4, mac: 7.2, battery: 21.2)
                PowerFlowCard(charger: 0, mac: 6.8, battery: -6.8)
                PowerFlowCard(charger: nil, mac: nil, battery: nil)
            }
            .frame(width: 280)
            VStack(alignment: .leading, spacing: Space.sm) {
                heading("Banner")
                KitBanner(title: "Limit not holding",
                          message: "Battery is at 86% and still charging. The limit is 80%.",
                          actionTitle: "Apply Limit Again")
            }
            .frame(width: 280)
            VStack(alignment: .leading, spacing: Space.sm) {
                heading("Sparkline: data, collecting")
                LevelSparkline(levels: PopoverSample.day, limit: 80).kitCard()
                LevelSparkline(levels: [], limit: 80).kitCard()
            }
            .frame(width: 200)
        }
    }

    private var marks: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            heading("Seal, menu bar glyph, icons, status line, stat row")
            HStack(spacing: Space.xl) {
                SealMark()
                SealMark(size: Metric.sealSmall)
                UmeBlossom(size: Metric.blossom)
                UmeBlossom(size: Metric.blossom, arrangement: .sprig)
                HStack(spacing: Space.sm) {
                    ForEach([100, 80, 50, 20], id: \.self) { EnsoGlyph(percent: $0) }
                    EnsoGlyph(percent: nil)
                }
                .foregroundStyle(Ink.text)
                HStack(spacing: Space.sm) {
                    ForEach([KitIcon.charger, .mac, .battery, .flow, .warning, .heat, .history, .settings],
                            id: \.symbol) { KitIconView(icon: $0) }
                }
                .foregroundStyle(Ink.text)
                StatusLine(title: "Limit not holding", detail: "86% and still charging", isWarning: true)
                StatRow(stats: PopoverSample.stats).frame(width: 240)
            }
        }
    }

    private func snapshotIfRequested() async {
        guard let dir = ProcessInfo.processInfo.environment["APP_SNAPSHOT"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            try? await Task.sleep(for: .seconds(0.8))
            Snapshot.capture(to: "\(dir)/kit-gallery-\(mode).png")
        }
        print("SNAPSHOT done \(dir)")
        NSApp.terminate(nil)
    }
}

/// The parts composed the way the popover will use them, with sample values.
struct PopoverSample: View {
    static let day: [Double] = [58, 61, 66, 72, 78, 80, 80, 80, 80, 77, 74, 72, 75, 79, 80, 80, 80, 80, 80, 80]
    static let stats = [StatRow.Stat(label: "Health", value: "82%"),
                        StatRow.Stat(label: "Cycles", value: "274"),
                        StatRow.Stat(label: "Temp", value: "34.7 °C")]

    @State private var limit = 80

    var body: some View {
        VStack(spacing: Space.lg) {
            EnsoGauge(percent: 80, limit: limit)
            StatusLine(title: "Holding at limit", detail: "Set by Hachibu")
            PowerFlowCard(charger: 9.2, mac: 7.2, battery: 0)
            VStack(spacing: Space.xs) {
                HStack {
                    Text("Limit").foregroundStyle(Ink.textSoft)
                    Spacer()
                    Text("\(limit)%").foregroundStyle(Ink.text)
                }
                .kitType(.label)
                LimitSlider(value: $limit, stops: [80, 85, 90, 95, 100])
            }
            HStack(spacing: Space.sm) {
                Button("Top Up") {}.buttonStyle(.kit())
                Button("Discharge") {}.buttonStyle(.kit(.secondary))
            }
            LevelSparkline(levels: Self.day, limit: limit).kitCard()
            StatRow(stats: Self.stats)
            KitDivider()
            HStack(spacing: Space.xs) {
                Button("History…") {}.buttonStyle(.kit(.ghost))
                Button("Settings…") {}.buttonStyle(.kit(.ghost))
                Spacer()
                Button("Quit Hachibu") {}.buttonStyle(.kit(.ghost))
            }
        }
        .padding(Space.lg)
        .frame(width: Metric.popoverWidth)
        .background(Ink.surface)
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
            .strokeBorder(Ink.hairline, lineWidth: Metric.hairline))
    }
}
