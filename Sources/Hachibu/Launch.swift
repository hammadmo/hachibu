import AppKit
import HachibuKit
import HachibuSystem

/// What a special run does once the app is up: a command from the command
/// line (HachibuKit/LaunchCommand.swift), the kit gallery, or snapshots. A
/// plain launch does nothing here.
enum Launch {
    private static var done = false

    /// The command this copy was started with. nil for a plain launch.
    nonisolated static let command = LaunchCommand(arguments: CommandLine.arguments)

    /// True for a run that does one thing and quits. Such a copy leaves
    /// recording, Top Up, and sailing to the copy in the menu bar.
    nonisolated static let isOneShot = command?.isOneShot ?? false

    /// Ends a command-line run. The limit is put back here, before the quit
    /// starts: a quit begun from inside a task cannot wait for another task.
    private static func quit(_ monitor: BatteryMonitor) async {
        if !monitor.hasRestoredForQuit, monitor.isOverriding || monitor.mode != .normal {
            print("putting the limit back before quitting: Hachibu had asked macOS for "
                + "\(monitor.overrideLimit.map { "\($0)%" } ?? "nothing"), mode \(monitor.mode.rawValue), yours \(monitor.userLimit)%")
        }
        await monitor.restoreBeforeQuit()
        NSApp.terminate(nil)
    }

    static func run(model: AppModel, monitor: BatteryMonitor, open: @escaping (String) -> Void) {
        guard !done else { return }
        done = true
        guard let command else {
            if KitGallery.enabled {
                open(KitGallery.windowID)
                NSApp.activate()
            } else {
                Snapshot.runIfRequested(model: model, open: open)
            }
            return
        }
        switch command {
        case .usage(let text):
            print(text)
            NSApp.terminate(nil)
        case .showSettings(let tab):
            // Started again by itself: go back to where the person was.
            if let tab = tab.flatMap(SettingsTab.init(rawValue:)) { model.settingsTab = tab }
            open(SettingsView.windowID)
            NSApp.activate()
        case .selfTest:
            SelfTest.run()
        case .setLimit(let limit):
            Task {
                print(await monitor.setLimitFromCommandLine(limit))
                await quit(monitor)
            }
        case .probeLimit(let limit):
            Task {
                print(await monitor.probeLimit(limit))
                await quit(monitor)
            }
        case .tryMode(let mode, let seconds):
            Task {
                await monitor.tryMode(mode, seconds: seconds)
                await quit(monitor)
            }
        case .restoreCharger:
            Task {
                var cut = false
                let readable = hb_adapter_is_cut(&cut)
                print("before: CHIE readable \(readable), cut \(cut)")
                let reply = await HelperClient.send(.restoreAdapter)
                print("helper: \(reply.problem ?? "ok"), reports cut \(reply.adapterCut)")
                try? await Task.sleep(for: .seconds(3))
                print("after: CHIE readable \(hb_adapter_is_cut(&cut)), cut \(cut), plugged \(SystemBattery.read()?.isPluggedIn ?? false)")
                await quit(monitor)
            }
        case .helperReinstall:
            Task {
                let removal = await monitor.helper.unregister()
                print("removed: \(removal ?? "ok"), now \(monitor.helper.state)")
                await monitor.helper.install()
                print("installed: \(monitor.helper.installProblem ?? "ok"), now \(monitor.helper.state)")
                await quit(monitor)
            }
        case .helperStatus:
            Task {
                await monitor.helper.refresh()
                print("helper: \(monitor.helper.state)")
                await quit(monitor)
            }
        }
    }
}
