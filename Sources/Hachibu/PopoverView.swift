import AppKit
import HachibuKit
import SwiftUI

/// The popover under the menu bar item: the gauge, the status with measured
/// watts, the power flow, the limit and who set it, and the battery's numbers.
struct PopoverView: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Space.lg) {
            if monitor.isWarning, let reading = monitor.reading {
                KitBanner(title: "Limit not holding",
                          message: "Battery is at \(reading.percent)% and still charging. The limit is \(monitor.limit.valueText).",
                          actionTitle: "Apply Limit Again") { monitor.applyLimitAgain() }
                    .gridProbe("banner", area: "popover")
            } else if monitor.helperMissing {
                KitBanner(title: "Helper not running",
                          message: "A limit of \(monitor.limit.saved ?? 0)% needs the helper. Without it, macOS may charge higher.",
                          actionTitle: "Fix…") {
                    model.settingsTab = .helper
                    open(SettingsView.windowID)
                }
                .gridProbe("banner", area: "popover")
            }
            EnsoGauge(percent: monitor.reading?.percent, limit: monitor.shownLimit,
                      tone: monitor.isWarning ? .warning : .normal)
            StatusLine(title: monitor.statusTitle, detail: monitor.statusDetail, isWarning: monitor.isWarning)
            PowerFlowCard(charger: monitor.reading?.chargerWatts, mac: monitor.reading?.systemWatts,
                          battery: monitor.reading?.batteryWatts)
                .gridProbe("power", area: "popover")
            limitBlock
                .gridProbe("limit", area: "popover")
            StatRow(stats: stats)
                .gridProbe("stats", area: "popover")
            KitDivider()
            footer
        }
        .padding(Space.lg)
        .frame(width: Metric.popoverWidth)
        .background(Ink.surface)
        .gridArea("popover", inset: Space.lg)
        .focusEffectDisabled()
        .noInitialFocus()
        .onAppear { monitor.popoverIsOpen = true }
        .onDisappear { monitor.popoverIsOpen = false }
    }

    private var limitBlock: some View {
        @Bindable var monitor = monitor
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Limit").foregroundStyle(Ink.textSoft)
                Spacer()
                Text(monitor.limitValueText).foregroundStyle(Ink.text)
            }
            .kitType(.label)
            LimitSlider(value: $monitor.sliderValue, stops: monitor.stops)
                .disabled(!monitor.canChangeLimit)
            HStack(spacing: Space.sm) {
                Text(monitor.limitCaption)
                    .kitType(.meta)
                    .foregroundStyle(monitor.applyProblem == nil ? Ink.textSoft : Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let action = monitor.limitAction {
                    Button(action.title) { monitor.perform(action) }
                        .buttonStyle(.kit(.secondary))
                        .fixedSize()
                }
            }
            .frame(minHeight: Metric.buttonHeight)
            modeButtons
        }
    }

    /// Top Up, and beside it Discharge. The one that runs reads "Stop".
    private var modeButtons: some View {
        HStack(spacing: Space.sm) {
            Button(monitor.mode == .toppingUp ? "Stop" : "Top Up") { monitor.toggleTopUp() }
                .buttonStyle(.kit(.secondary, selected: monitor.mode == .toppingUp))
                .disabled(monitor.mode != .toppingUp && !monitor.canTopUp)
                .help(monitor.mode == .toppingUp ? "End the Top Up and go back to your limit"
                    : "Charge to 100% once, then go back to your limit")
                .accessibilityLabel(monitor.mode == .toppingUp ? "Stop Top Up" : "Top Up")
        }
        .padding(.top, Space.xs)
    }

    private var stats: [StatRow.Stat] {
        let reading = monitor.reading
        return [
            .init(label: "Health", value: monitor.healthPercent.map { "\($0)%" } ?? "–"),
            .init(label: "Cycles", value: reading?.cycleCount.map(String.init) ?? "–"),
            .init(label: "Temp", value: reading?.temperatureC.map { String(format: "%.1f °C", $0) } ?? "–"),
        ]
    }

    private var footer: some View {
        HStack(spacing: Space.xs) {
            Button("History…") { open(HistoryView.windowID) }
                .buttonStyle(.kit(.ghost))
            Button("Settings…") { open(SettingsView.windowID) }
                .buttonStyle(.kit(.ghost))
                .keyboardShortcut(",")
            Spacer(minLength: 0)
            Button("Quit Hachibu") { NSApp.terminate(nil) }
                .buttonStyle(.kit(.ghost))
                .keyboardShortcut("q")
        }
    }

    /// Opens Settings or History and closes the popover, so the new window
    /// is not left behind it.
    private func open(_ window: String) {
        // The popover is the key window while a button in it is clicked.
        let popover = NSApp.keyWindow
        openWindow(id: window)
        NSApp.activate()
        dismiss()
        // In case dismiss leaves it open on some macOS version.
        Task {
            if let popover, popover.isVisible, popover.title != "Hachibu Settings", popover.title != HistoryView.windowTitle {
                popover.close()
            }
        }
    }
}

/// The popover with a fixed state, in a window of its own, for snapshots.
struct PopoverPreviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PopoverView()
            .environment(BatteryMonitor.preview(model.popoverPreview))
            .padding(.top, Space.xxl)
            .background(Ink.surface)
            .ignoresSafeArea()
    }
}
