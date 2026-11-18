import AppKit
import SwiftUI

// Hachibu: a menu bar app. No Dock icon and no main window.
//   Hachibu                      the app
//   Hachibu --selftest           check the real functions and quit with 0 or 1 (tools/selftest.sh)
//   Hachibu --set-limit <n>      set the charge limit (80, 85, 90, 95, or 100 for none; 20 to 100 with the helper), print the result, quit
//   Hachibu --helper-status      ask the helper for its state, print it, quit (read-only)
//   APP_STORE=<file> Hachibu     a test run: no real preferences, login items, notifications, or limit changes
//   APP_SNAPSHOT=<dir> Hachibu   save a PNG of the popover states, every Settings tab, and History, in light and dark, then quit
//   APP_KIT_GALLERY=1 Hachibu    show every design kit part in every state (DesignKit/KitGallery.swift)
//   APP_GRID=1 Hachibu           draw the 8 pt grid and the layout probes over the popover preview

@main
struct HachibuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var monitor = BatteryMonitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(monitor)
        } label: {
            MenuBarLabel()
                .environment(model)
                .environment(monitor)
        }
        .menuBarExtraStyle(.window)

        // A plain window, not a Settings scene: SwiftUI gives a Settings scene
        // a system title bar that cannot be hidden.
        Window("Hachibu Settings", id: SettingsView.windowID) {
            SettingsView()
                .environment(model)
                .environment(model.settingsPreview ?? monitor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
        }

        Window(HistoryView.windowTitle, id: HistoryView.windowID) {
            HistoryView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .keyboardShortcut("y")

        // The two windows below open only in snapshot and gallery runs.
        Window(PopoverPreview.windowTitle, id: PopoverPreview.windowID) {
            PopoverPreviewView()
                .environment(model)
                .overlay { if GridOverlay.enabled { GridOverlay() } }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window(KitGallery.windowTitle, id: KitGallery.windowID) {
            KitGallery()
        }
        .defaultSize(KitGallery.size)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// "Settings…" in the app menu, with Command-Comma.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsView.windowID) }
            .keyboardShortcut(",")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon. Info.plist says the same (LSUIElement),
        // but a copy started from a terminal needs it said here too.
        NSApp.setActivationPolicy(.accessory)
        Notifier.requestPermission()
    }

    /// Closing Settings or History must not quit the menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// What a special run does once the app is up: the self-test, the kit
/// gallery, or snapshots. A normal launch does nothing here.
enum Launch {
    private static var done = false

    static func run(model: AppModel, monitor: BatteryMonitor, open: @escaping (String) -> Void) {
        guard !done else { return }
        done = true
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--set-limit") {
            guard arguments.indices.contains(flag + 1), let value = Int(arguments[flag + 1]) else {
                print("usage: Hachibu --set-limit <percent>")
                NSApp.terminate(nil)
                return
            }
            Task {
                print(await monitor.setLimitFromCommandLine(value))
                NSApp.terminate(nil)
            }
        } else if arguments.contains("--helper-status") {
            Task {
                await monitor.helper.refresh()
                print("helper: \(monitor.helper.state)")
                NSApp.terminate(nil)
            }
        } else if SelfTest.requested {
            SelfTest.run()
        } else if KitGallery.enabled {
            open(KitGallery.windowID)
            NSApp.activate()
        } else {
            Snapshot.runIfRequested(model: model, open: open)
        }
    }
}
