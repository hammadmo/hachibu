import AppKit
import HachibuKit
import SwiftUI

// Hachibu: a menu bar app. No Dock icon and no main window.
// Command-line flags are listed in HachibuKit/LaunchCommand.swift and
// carried out in Launch.swift. Three kinds of run are chosen by the
// environment instead:
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

        // What the popover shows, in a window of its own. It opens when the
        // menu bar item is pressed through accessibility (StatusItemAccess).
        Window(StatusItemAccess.windowTitle, id: StatusItemAccess.windowID) {
            PopoverView()
                .environment(model)
                .environment(monitor)
                .padding(.top, Space.xxl)
                .background(Ink.surface)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

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
        DockIcon.watch()
        Updates.shared.start()
        if Preferences.shared.topUpShortcut { Preferences.shared.setTopUpShortcut(true) }
    }

    /// Closing Settings or History must not quit the menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting during a Top Up or while sailing puts the user's limit back first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor = BatteryMonitor.current, !monitor.hasRestoredForQuit,
              monitor.isOverriding || monitor.mode != .normal,
              !Store.isOverridden else { return .terminateNow }
        modeLog.notice("quit waits: override \(monitor.overrideLimit ?? -1, privacy: .public), mode \(monitor.mode.rawValue, privacy: .public)")
        Task {
            await monitor.restoreBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Shows Hachibu in the Dock while Settings or History is open, so the
/// window can be found again, and takes it out when both are closed.
/// Test runs leave the Dock alone.
enum DockIcon {
    private static let titles: Set<String> = ["Hachibu Settings", HistoryView.windowTitle, StatusItemAccess.windowTitle]

    static func watch() {
        guard !Store.isOverridden else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update(closing: nil) }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { update(closing: closing) }
        }
    }

    /// A window that is closing still counts as visible, so it is left out.
    private static func update(closing: ObjectIdentifier?) {
        let open = NSApp.windows.contains { $0.isVisible && titles.contains($0.title) && ObjectIdentifier($0) != closing }
        let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if open { NSApp.activate() }
    }
}

/// Quits Hachibu and starts it again with Settings open on a tab. Never in
/// test runs.
enum Relaunch {
    static func now(showing tab: SettingsTab) {
        guard !Store.isOverridden else { return }
        Task { @MainActor in
            // The user's limit goes back before the new copy starts. Started
            // first, it could find a Top Up's limit still in place and say
            // Hachibu had stopped in the middle of one.
            await BatteryMonitor.current?.restoreBeforeQuit()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // -n: a new copy, started while this one is still quitting.
            process.arguments = ["-n", Bundle.main.bundlePath, "--args", LaunchCommand.showSettingsFlag, tab.rawValue]
            guard (try? process.run()) != nil else { return }
            NSApp.terminate(nil)
        }
    }
}
