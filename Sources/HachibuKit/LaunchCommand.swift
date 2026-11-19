import Foundation

/// What a launch of Hachibu was asked to do on the command line. Parsing is
/// here, where it can be tested; carrying a command out is in the app.
///
///   Hachibu                                  the app in the menu bar
///   Hachibu --set-limit <percent>            set the limit as the slider would, print the result, quit
///   Hachibu --probe-limit <percent>          ask macOS for any limit the helper accepts, print what it reports, put the old one back
///   Hachibu --try <mode> <seconds>           run a real Top Up, sailing, calibration, or heat pause for that long
///   Hachibu --helper-status                  print the helper's state
///   Hachibu --helper-reinstall               take the helper out of macOS and register it again
///   Hachibu --restore-charger                ask the helper to reconnect the charger
///   Hachibu --selftest                       check the real functions, quit with 0 or 1
///   Hachibu --show-settings <tab>            open Settings on a tab (used when Hachibu restarts itself)
public enum LaunchCommand: Equatable, Sendable {
    case setLimit(Int)
    case probeLimit(Int)
    case tryMode(String, seconds: Int)
    case helperStatus
    case helperReinstall
    case restoreCharger
    case selfTest
    case showSettings(tab: String?)
    /// A flag that needs a value and did not get a usable one, or a flag
    /// Hachibu does not know.
    case usage(String)

    public static let showSettingsFlag = "--show-settings"

    /// nil for a plain launch.
    public init?(arguments: [String]) {
        func value(after flag: String, offset: Int = 1) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + offset) else { return nil }
            return arguments[index + offset]
        }
        if arguments.contains("--set-limit") {
            guard let limit = value(after: "--set-limit").flatMap(Int.init) else {
                self = .usage("usage: Hachibu --set-limit <percent>")
                return
            }
            self = .setLimit(limit)
        } else if arguments.contains(Self.showSettingsFlag) {
            self = .showSettings(tab: value(after: Self.showSettingsFlag))
        } else if arguments.contains("--probe-limit") {
            guard let limit = value(after: "--probe-limit").flatMap(Int.init) else {
                self = .usage("usage: Hachibu --probe-limit <percent>")
                return
            }
            self = .probeLimit(limit)
        } else if arguments.contains("--try") {
            guard let mode = value(after: "--try"), let seconds = value(after: "--try", offset: 2).flatMap(Int.init), seconds > 0 else {
                self = .usage("usage: Hachibu --try topup|sailing|calibration|heat <seconds>")
                return
            }
            self = .tryMode(mode, seconds: seconds)
        } else if arguments.contains("--restore-charger") {
            self = .restoreCharger
        } else if arguments.contains("--helper-reinstall") {
            self = .helperReinstall
        } else if arguments.contains("--helper-status") {
            self = .helperStatus
        } else if arguments.contains("--selftest") {
            self = .selfTest
        } else if let unknown = arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
            // A misspelled flag must not start a second copy that runs modes
            // against the one in the menu bar. (macOS's own arguments start
            // with one dash.)
            self = .usage("Hachibu does not know \(unknown). The flags are listed in LaunchCommand.swift.")
        } else {
            return nil
        }
    }

    /// True for a run that does one thing and quits. Such a copy leaves
    /// recording, Top Up, and sailing to the copy in the menu bar.
    public var isOneShot: Bool {
        if case .showSettings = self { return false }
        return true
    }

    /// The one command-line run that exists to run a mode.
    public var runsModes: Bool {
        if case .tryMode = self { return true }
        return !isOneShot
    }
}
