import Foundation
import HachibuKit

extension BatteryMonitor {
    /// For `Hachibu --try`: runs a real mode for a while through the same
    /// path as the buttons, printing what is measured, then stops it and
    /// waits until the user's limit is back.
    func tryMode(_ name: String, seconds: Int) async {
        func line(_ label: String) {
            let r = reading
            print("\(label): \(statusTitle), \(r?.percent ?? -1)%, \(r?.currentMA ?? 0) mA, plugged \(r?.isPluggedIn ?? false), "
                + "macOS limit \(limit.valueText), yours \(userLimit)%, mode \(mode.rawValue)\(modeProblem.map { ", " + $0 } ?? "")")
        }
        popoverIsOpen = true
        await helper.refresh()
        for _ in 0..<20 where !(hasLoaded && limitKnown) { try? await Task.sleep(for: .milliseconds(250)) }
        line("before")
        switch name {
        case "topup": toggleTopUp()
        case "sailing":
            // Sailing is a setting, not a mode: turn it on, watch, turn it off.
            let before = Preferences.shared.sailingRange
            Preferences.shared.sailingRange = 10
            defer { Preferences.shared.sailingRange = before }
            for second in 1...max(seconds, 1) {
                try? await Task.sleep(for: .seconds(1))
                if second % 10 == 0 || second == seconds { line("t=\(second)s sailing \(isSailing), asked macOS for \(overrideLimit.map(String.init) ?? "nothing")") }
            }
            Preferences.shared.sailingRange = before
            refresh()
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<400 where isBusy || isOverriding {
                try? await Task.sleep(for: .milliseconds(500))
            }
            line("after")
            return
        default: print("unknown mode \(name)"); return
        }
        guard mode != .normal else { line("refused"); return }
        for second in 1...max(seconds, 1) {
            try? await Task.sleep(for: .seconds(1))
            if second % 4 == 0 || second == seconds { line("t=\(second)s") }
            if mode == .normal { break }
        }
        if mode == .toppingUp { toggleTopUp() }
        for _ in 0..<120 where isBusy || isOverriding {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))
        line("after")
    }
}
