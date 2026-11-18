import AppKit
import IOKit.pwr_mgt
import HachibuKit
import SwiftUI

/// Screenshot mode for agents.
///   APP_STORE=/tmp/test.store APP_SNAPSHOT=/tmp/shots ~/Applications/Hachibu.app/Contents/MacOS/Hachibu
/// writes, in light and dark:
///   popover, popover-charging, popover-warning, popover-outside, popover-unavailable   fixed states
///   popover-low, popover-helper                         a limit below 80% with the helper, and without it
///   settings-<tab>                                                                     every Settings tab
///   settings-charging-helper, settings-helper-<state>   the helper running, and every helper state
///   history-day, -week, -month (sample data), history-empty (what it shows today)
/// then quits. Each PNG gets a -layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=popover,settings,history limits the groups.
/// Nothing here reads or changes the real battery: every state is a fixture.
enum Snapshot {
    static func runIfRequested(model: AppModel, open: @escaping (String) -> Void) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        func wants(_ group: String) -> Bool { only?.contains(group) ?? true }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let modes = ["light", "dark"]

            @MainActor func each(_ window: String, title: String, pages: [String], set: (String) -> Void) async {
                open(window)
                try? await Task.sleep(for: .seconds(1.2))
                for mode in modes {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for page in pages {
                        set(page)
                        try? await Task.sleep(for: .seconds(0.8))
                        capture(to: "\(dir)/\(page)-\(mode).png", window: self.window(titled: title))
                    }
                }
                self.window(titled: title)?.close()
            }

            if wants("popover") {
                await each(PopoverPreview.windowID, title: PopoverPreview.windowTitle,
                           pages: PopoverPreview.allCases.map(\.page)) { page in
                    model.popoverPreview = PopoverPreview.allCases.first { $0.page == page } ?? .holding
                }
            }
            if wants("settings") {
                await each(SettingsView.windowID, title: "Hachibu Settings",
                           pages: SettingsTab.allCases.map { "settings-\($0.rawValue)" } + SettingsFixture.pages) { page in
                    let fixture = SettingsFixture(page: page)
                    model.settingsTab = fixture.tab
                    model.settingsPreview = BatteryMonitor.preview(fixture.battery, helper: fixture.helper)
                    model.confirmingHelperRemoval = fixture.confirmingRemoval
                    model.showingHelperApproval = fixture.showingApproval
                }
            }
            if wants("history") {
                await each(HistoryView.windowID, title: HistoryView.windowTitle,
                           pages: ["history-day", "history-week", "history-month", "history-empty"]) { page in
                    let name = String(page.dropFirst("history-".count))
                    model.historyPreview = name == "empty" ? .recorded : .sample
                    if let range = HistoryRange(rawValue: name) { model.historyRange = range }
                }
            }
            print("SNAPSHOT done \(dir)")
            NSApp.terminate(nil)
        }
    }

    static func window(titled title: String) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == title }
    }

    /// Captures the real window with screencapture, so materials look exactly
    /// as on screen. That needs Screen Recording permission for the app that
    /// started this one (your terminal, or Claude). Without it, falls back to
    /// drawing the view hierarchy.
    static func capture(to path: String, window: NSWindow?) {
        // Another app can hide this one while snapshots run. Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window else {
            print("SNAPSHOT no window for \(path)")
            return
        }
        // Active, like a window someone is using: real colors and focus rings.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission)")
        }
    }
}

/// What a Settings snapshot page shows: the tab, and a fixed battery and helper.
struct SettingsFixture {
    /// The pages beyond one per tab.
    static let pages = ["settings-charging-helper", "settings-helper-approval", "settings-helper-running",
                        "settings-helper-failed", "settings-helper-unavailable", "settings-helper-remove", "settings-helper-allow"]

    var tab: SettingsTab = .general
    var battery: PopoverPreview = .holding
    var helper: HelperState = .notInstalled
    var confirmingRemoval = false
    var showingApproval = false

    init(page: String) {
        let parts = page.split(separator: "-").dropFirst().map(String.init)
        tab = parts.first.flatMap(SettingsTab.init(rawValue:)) ?? .general
        switch parts.dropFirst().first {
        case "helper", "running": (battery, helper) = (.lowLimit, .running)
        case "remove": (battery, helper, confirmingRemoval) = (.lowLimit, .running, true)
        case "approval": helper = .needsApproval
        case "allow": (helper, showingApproval) = (.needsApproval, true)
        case "failed": helper = .failed("The helper did not answer.")
        case "unavailable": helper = .unavailable("This copy of Hachibu is not signed with an Apple certificate, which the helper needs.")
        default: break
        }
    }
}
