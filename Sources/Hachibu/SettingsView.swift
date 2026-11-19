import AppKit
import HachibuKit
import SwiftUI

/// The Settings window (Command-Comma), drawn with the design kit: a hidden
/// title bar, text tabs with a gold underline, and cards of rows. The window
/// fits the tab it shows.
struct SettingsView: View {
    static let windowID = "settings"
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            KitTabBar(tabs: SettingsTab.allCases.map { (id: $0, title: $0.title) }, selection: $model.settingsTab,
                      label: "Settings sections")
                .padding(.top, Metric.titleBarInset)
                .padding(.bottom, Space.sm)
            KitDivider()
            Group {
                switch model.settingsTab {
                case .general: GeneralSettings()
                case .charging: ChargingSettings()
                case .helper: HelperSettings()
                case .about: AboutSettings()
                }
            }
            .padding(Space.xxl)
        }
        .kitWindow(width: Metric.settingsWidth)
        .overlay {
            if model.showingHelperApproval { HelperApprovalDialog() }
            if model.showingCalibration { CalibrationDialog() }
        }
    }
}

/// Before a calibration: what it does, what it costs, and what it needs.
/// While one runs: its three steps, with the current one marked.
struct CalibrationDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(BatteryMonitor.self) private var monitor
    @State private var refusal: String?

    private static let steps = ["macOS drains the battery to \(ChargeEngine.calibrationFloor)%, staying on the charger.",
                                "The battery charges to 100%.",
                                "It rests at 100% for two hours. Then your limit returns."]

    var body: some View {
        if let step = monitor.calibrationStep {
            KitDialog(title: "Calibrating",
                      message: monitor.isWaitingForCharger ? "Waiting for the charger. Connect it to go on."
                          : "The battery is at \(monitor.reading?.percent ?? 0)%.",
                      steps: Self.steps, currentStep: CalibrationStep.allCases.firstIndex(of: step),
                      note: "Keep the charger connected. Quitting Hachibu ends the calibration and puts your limit back. The drain waits while the Mac sleeps.",
                      primaryTitle: "Close", primary: { model.showingCalibration = false },
                      secondaryTitle: "Stop", secondary: {
                          monitor.stopCalibration()
                          model.showingCalibration = false
                      })
        } else {
            KitDialog(title: "Calibrate the battery",
                      message: "Corrects the percentage and the health reading. It does not improve the battery, and it uses one full charge cycle.",
                      steps: Self.steps,
                      note: refusal ?? "Takes several hours. Keep the charger connected. Quitting Hachibu ends it. The drain waits while the Mac sleeps; Hachibu does not keep the Mac awake.",
                      primaryTitle: "Calibrate", primary: { refusal = monitor.startCalibration() },
                      secondaryTitle: "Not Now", secondary: { model.showingCalibration = false })
        }
    }
}

/// Shown after Install Helper…: how to allow the helper, and then a restart,
/// because Hachibu only reaches a newly allowed helper after it starts again.
struct HelperApprovalDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let allowed = monitor.helper.state != .needsApproval
        KitDialog(title: "Allow the helper",
                  message: "macOS asks for your approval once.",
                  steps: ["Click Open Login Items.",
                          "Turn on Hachibu under “Allow in the Background”.",
                          "Hachibu restarts by itself and the helper starts."],
                  progress: allowed ? "Allowed. Restarting Hachibu…" : nil,
                  primaryTitle: "Open Login Items…", primary: { HelperManager.openLoginItems() },
                  secondaryTitle: "Not Now", secondary: { model.showingHelperApproval = false })
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, charging, helper, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .charging: "Charging"
        case .helper: "Helper"
        case .about: "About"
        }
    }
}

struct GeneralSettings: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            SettingsSection(title: "Startup and menu bar") {
                SettingsRow(title: "Open at login",
                            detail: preferences.loginItemProblem ?? "Hachibu starts when you log in to your Mac.") {
                    Toggle("Open at login", isOn: Binding(get: { preferences.opensAtLogin },
                                                          set: { preferences.setOpensAtLogin($0) }))
                        .toggleStyle(.kit)
                }
                SettingsRow(title: "Show percentage", detail: "The battery level next to the menu bar icon.") {
                    Toggle("Show percentage", isOn: $preferences.showPercentage).toggleStyle(.kit)
                }
            }
            SettingsSection(title: "Notifications") {
                SettingsRow(title: "Limit not holding", detail: "The battery is charging above your limit.") {
                    Toggle("Limit not holding", isOn: $preferences.notifyLimitNotHolding).toggleStyle(.kit)
                }
                SettingsRow(title: "Full charge by macOS", detail: "macOS charges past your limit to keep its estimates accurate.") {
                    Toggle("Full charge by macOS", isOn: $preferences.notifyFullCharge).toggleStyle(.kit)
                }
                SettingsRow(title: "Top Up finished") {
                    Toggle("Top Up finished", isOn: $preferences.notifyTopUpFinished).toggleStyle(.kit)
                }
                SettingsRow(title: "Calibration finished") {
                    Toggle("Calibration finished", isOn: $preferences.notifyCalibrationFinished).toggleStyle(.kit)
                }
            }
        }
    }
}

struct ChargingSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(BatteryMonitor.self) private var monitor
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        @Bindable var monitor = monitor
        VStack(alignment: .leading, spacing: Space.xxl) {
            SettingsSection(title: "Limit") {
                SettingsRow(title: "Limit",
                            detail: monitor.helper.isRunning ? "Any level from 20% to 100%."
                                : "From 80% to 100%. Lower limits need the helper.") {
                    valueSlider($monitor.sliderValue, stops: monitor.stops, scale: 20...100,
                                label: "Limit", text: monitor.limitValueText)
                }
                .disabled(!monitor.canChangeLimit)
            }
            if !Capability.heatProtection {
                Text("Heat protection is not part of this build yet.")
                    .kitType(.body).foregroundStyle(Ink.textSoft)
                    .padding(.leading, Space.lg)
            }
            SettingsSection(title: "Sailing") {
                SettingsRow(title: "Sailing range",
                            detail: monitor.helper.isRunning
                                ? "How far the battery drifts below the limit before charging again. 0 is off."
                                : "Sailing needs the helper.") {
                    valueSlider($preferences.sailingRange, stops: Array(0...10), scale: 0...10,
                                label: "Sailing range", text: "\(preferences.sailingRange)%")
                }
            }
            .disabled(!Capability.sailing || !monitor.helper.isRunning)
            SettingsSection(title: "Calibration") {
                if let step = monitor.calibrationStep {
                    SettingsRow(title: "Calibrating",
                                detail: BatteryStatus.calibrating(step).detail(for: monitor.reading ?? .placeholder)) {
                        Button("Show Steps…") { model.showingCalibration = true }
                            .buttonStyle(.kit(.secondary)).fixedSize()
                    }
                } else {
                    SettingsRow(title: "Calibrate the battery",
                                detail: monitor.helper.isRunning
                                    ? "Corrects the battery reading when the percentage or health looks wrong."
                                    : "Calibration needs the helper.") {
                        Button("Calibrate…") { model.showingCalibration = true }
                            .buttonStyle(.kit(.secondary)).fixedSize()
                            .disabled(!monitor.helper.isRunning)
                    }
                }
            }
            SettingsSection(title: "Heat protection") {
                SettingsRow(title: "Pause charging when hot", detail: "Charging resumes when the battery cools by 2 °C.") {
                    Toggle("Pause charging when hot", isOn: $preferences.heatProtection).toggleStyle(.kit)
                }
                SettingsRow(title: "Pause above") {
                    valueSlider($preferences.heatThreshold, stops: Array(30...45), scale: 30...45,
                                label: "Pause above", unit: "degrees Celsius", text: "\(preferences.heatThreshold) °C")
                }
                .disabled(!preferences.heatProtection)
            }
            .disabled(!Capability.heatProtection)
        }
    }

    private func valueSlider(_ value: Binding<Int>, stops: [Int], scale: ClosedRange<Int>,
                             label: String, unit: String = "percent", text: String) -> some View {
        HStack(spacing: Space.md) {
            LimitSlider(value: value, stops: stops, scale: scale, label: label, unit: unit)
                .frame(width: 160)
            Text(text).kitType(.numeral).foregroundStyle(Ink.text)
                .fixedSize()
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}

struct HelperSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(BatteryMonitor.self) private var monitor
    /// Why the last install or removal failed.
    @State private var problem: String?

    private var helper: HelperManager { monitor.helper }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            SettingsSection(title: "Advanced charging control") {
                SettingsRow(title: "Helper", detail: stateDetail) {
                    StatusPill(text: helper.state.title, tone: tone)
                }
                SettingsRow(title: "What it does",
                            detail: "Lets Hachibu set limits below 80%. It runs with administrator rights, only while Hachibu needs it, and macOS asks for your approval once.") {
                    EmptyView()
                }
                action
            }
        }
        .task { await helper.refresh() }
        // While macOS waits for the approval, look again every two seconds.
        .task(id: helper.state) {
            guard helper.state == .needsApproval else { return }
            while helper.state == .needsApproval, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await helper.refresh()
            }
            // Just allowed. Hachibu reaches the helper reliably only after
            // it starts again, so it does that by itself.
            guard !Task.isCancelled, helper.state == .running || helper.state.isFailure else { return }
            try? await Task.sleep(for: .seconds(1))
            Relaunch.now(showing: .helper)
        }
        .onDisappear { model.confirmingHelperRemoval = false }
    }

    private var tone: StatusPill.Tone {
        switch helper.state {
        case .running: .good
        case .needsApproval, .failed: .warning
        case .checking, .notInstalled, .unavailable: .idle
        }
    }

    private var stateDetail: String? {
        switch helper.state {
        case .failed(let reason), .unavailable(let reason): reason
        case .needsApproval: "Allow Hachibu in System Settings > General > Login Items."
        case .running: "Limits from 20% to 100% are available."
        case .checking, .notInstalled: nil
        }
    }

    @ViewBuilder private var action: some View {
        switch helper.state {
        case .checking:
            EmptyView()
        case .notInstalled, .unavailable:
            SettingsRow(title: "Install the helper",
                        detail: helper.state == .notInstalled ? problem ?? "macOS will ask you to allow it in Login Items." : nil) {
                Button("Install Helper…") {
                    Task {
                        await helper.install()
                        problem = helper.installProblem
                        model.showingHelperApproval = helper.state == .needsApproval
                    }
                }
                .buttonStyle(.kit())
                .fixedSize()
                .disabled(helper.state != .notInstalled || helper.isWorking)
            }
        case .needsApproval:
            SettingsRow(title: "Approve the helper", detail: "Turn on Hachibu under \"Allow in the Background\".") {
                HStack(spacing: Space.sm) {
                    Button("Remove Helper") {
                        Task { problem = await monitor.removeHelper() }
                    }
                    .buttonStyle(.kit(.ghost))
                    .disabled(helper.isWorking || monitor.isRemovingHelper)
                    Button("Open Login Items…") { HelperManager.openLoginItems() }
                        .buttonStyle(.kit())
                }
                .fixedSize()
            }
        case .running, .failed:
            if model.confirmingHelperRemoval {
                SettingsRow(title: "Remove the helper?", detail: removalDetail) {
                    HStack(spacing: Space.sm) {
                        Button("Cancel") { model.confirmingHelperRemoval = false }
                            .buttonStyle(.kit(.ghost))
                        Button("Remove Helper") {
                            Task {
                                problem = await monitor.removeHelper()
                                model.confirmingHelperRemoval = false
                            }
                        }
                        .buttonStyle(.kit())
                        .disabled(helper.isWorking || monitor.isRemovingHelper)
                    }
                    .fixedSize()
                }
            } else {
                SettingsRow(title: "Remove the helper",
                            detail: problem ?? "Takes the helper out of macOS. You can install it again at any time.") {
                    Button("Remove Helper…") {
                        problem = nil
                        model.confirmingHelperRemoval = true
                    }
                    .buttonStyle(.kit(.secondary))
                    .fixedSize()
                }
            }
        }
    }

    /// What removal changes, in the user's numbers.
    private var removalDetail: String {
        var changes = "The helper leaves macOS and Login Items."
        if let held = monitor.limit.system, held < HelperNeed.lowestWithoutHelper {
            let target = HelperNeed.limitAfterRemoval(current: held, official: monitor.officialStops)
            changes += " Your limit goes from \(held)% to \(target)%, the lowest macOS holds by itself."
        } else {
            changes += " Your limit stays as it is. Limits below 80% will not be available."
        }
        return changes
    }
}

struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Metric.appIconSize, height: Metric.appIconSize)
                .accessibilityHidden(true)
            VStack(spacing: Space.xs) {
                Text("Hachibu").kitType(.title).foregroundStyle(Ink.text)
                Text(version).kitType(.meta).foregroundStyle(Ink.textSoft)
            }
            Text("Hara hachi bu: eat until you are eight parts full.\nHachibu stops charging before the battery is full, so it lasts longer.")
                .kitType(.body).foregroundStyle(Ink.text)
                .multilineTextAlignment(.center)
            HStack(spacing: Space.md) {
                KitDivider()
                UmeBlossom(size: Metric.blossom)
                KitDivider()
            }
            Text("The way to control charging on macOS 27 was documented by the open-source batt project.")
                .kitType(.meta).foregroundStyle(Ink.textSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
