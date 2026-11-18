import AppKit
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
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            if !Capability.helper {
                HStack(spacing: Space.md) {
                    Text("Sailing and heat protection need the helper.")
                        .kitType(.body).foregroundStyle(Ink.textSoft)
                    Spacer(minLength: 0)
                    Button("Show Helper") { model.settingsTab = .helper }.buttonStyle(.kit(.ghost))
                }
                .padding(.leading, Space.lg)
            }
            SettingsSection(title: "Sailing") {
                SettingsRow(title: "Sailing range",
                            detail: "How far the battery drifts below the limit before charging again. 0 is off.") {
                    valueSlider($preferences.sailingRange, stops: Array(0...10), scale: 0...10,
                                label: "Sailing range", text: "\(preferences.sailingRange)%")
                }
            }
            .disabled(!Capability.helper)
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
            .disabled(!Capability.helper)
        }
    }

    private func valueSlider(_ value: Binding<Int>, stops: [Int], scale: ClosedRange<Int>,
                             label: String, unit: String = "percent", text: String) -> some View {
        HStack(spacing: Space.md) {
            LimitSlider(value: value, stops: stops, scale: scale, label: label, unit: unit)
                .frame(width: 160)
            Text(text).kitType(.numeral).foregroundStyle(Ink.text)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

struct HelperSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            SettingsSection(title: "Advanced charging control") {
                SettingsRow(title: "Helper") {
                    StatusPill(text: "Not installed")
                }
                SettingsRow(title: "What it does",
                            detail: "Lets Hachibu set limits below 80%, discharge while plugged in, and sail. It runs in the background with administrator rights, and macOS asks for your approval once.") {
                    EmptyView()
                }
                SettingsRow(title: "Install the helper",
                            detail: Capability.helper ? nil : "The helper is not part of this build yet.") {
                    Button("Install Helper…") {}.buttonStyle(.kit())
                        .fixedSize()
                        .disabled(!Capability.helper)
                }
            }
        }
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
