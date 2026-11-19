import Foundation
import Testing
@testable import HachibuKit

private func command(_ arguments: String...) -> LaunchCommand? {
    LaunchCommand(arguments: ["/Applications/Hachibu.app/Contents/MacOS/Hachibu"] + arguments)
}

@Test("Each command-line flag is read as its command")
func launchCommands() {
    #expect(command() == nil)
    #expect(command("-NSDocumentRevisionsDebugMode", "YES") == nil)
    #expect(command("--set-limit", "70") == .setLimit(70))
    #expect(command("--probe-limit", "15") == .probeLimit(15))
    #expect(command("--try", "heat", "420") == .tryMode("heat", seconds: 420))
    #expect(command("--helper-status") == .helperStatus)
    #expect(command("--helper-reinstall") == .helperReinstall)
    #expect(command("--restore-charger") == .restoreCharger)
    #expect(command("--selftest") == .selfTest)
    #expect(command("--show-settings", "helper") == .showSettings(tab: "helper"))
    #expect(command("--show-settings") == .showSettings(tab: nil))
}

@Test("A flag without a usable value prints how to use it and changes nothing")
func launchUsage() {
    for bad in [command("--set-limit"), command("--set-limit", "eighty"), command("--probe-limit"),
                command("--try", "topup"), command("--try", "topup", "soon"), command("--try", "topup", "-5")] {
        guard case .usage(let text)? = bad else {
            Issue.record("expected usage, got \(String(describing: bad))")
            continue
        }
        #expect(text.hasPrefix("usage: Hachibu --"))
    }
}

@Test("A flag Hachibu does not know prints a line and quits, so no second copy runs modes")
func launchUnknownFlag() {
    for bad in [command("--set-limt", "70"), command("--help"), command("-NSQuitAlwaysKeepsWindows", "NO", "--tryy")] {
        guard case .usage? = bad else {
            Issue.record("expected usage, got \(String(describing: bad))")
            continue
        }
        #expect(bad?.runsModes == false)
    }
    // The first flag that is known wins; a bad value never falls through to a plain launch.
    #expect(command("--set-limit", "70", "--try", "topup", "5") == .setLimit(70))
}

@Test("Only the menu bar copy, and a --try run, run modes; every one-shot run leaves recording alone")
func launchRoles() {
    #expect(LaunchCommand.setLimit(70).isOneShot && !LaunchCommand.setLimit(70).runsModes)
    #expect(LaunchCommand.helperStatus.isOneShot && !LaunchCommand.helperStatus.runsModes)
    #expect(LaunchCommand.selfTest.isOneShot)
    #expect(LaunchCommand.usage("x").isOneShot)
    // --try runs a mode on purpose, but is still not the copy that records.
    #expect(LaunchCommand.tryMode("topup", seconds: 5).isOneShot && LaunchCommand.tryMode("topup", seconds: 5).runsModes)
    // Restarted to show Settings: this is the menu bar copy.
    #expect(!LaunchCommand.showSettings(tab: "helper").isOneShot && LaunchCommand.showSettings(tab: nil).runsModes)
}
