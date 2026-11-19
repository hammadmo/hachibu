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
        case "heat":
            // The battery cannot be heated on request. Instead the threshold
            // is put one degree under what the battery is at now, so heat
            // protection sees it as hot. The battery must be charging.
            guard let temperature = reading?.temperatureC else { print("refused: no temperature"); return }
            heatThresholdForTrial = Int(temperature.rounded(.down)) - 1
            defer { heatThresholdForTrial = nil }
            print("threshold for this run: \(heatThresholdForTrial ?? 0) °C, battery at \(String(format: "%.1f", temperature)) °C")
            let begun = Date.now
            var stoppedAfter: Int?
            for second in 1...max(seconds, 1) {
                try? await Task.sleep(for: .seconds(1))
                let charging = reading?.isCharging ?? false
                if isPausedForHeat, !charging, stoppedAfter == nil {
                    stoppedAfter = Int(Date.now.timeIntervalSince(begun))
                    line("t=\(second)s charging stopped")
                }
                if second % 20 == 0 || second == seconds {
                    line("t=\(second)s \(String(format: "%.1f", reading?.temperatureC ?? 0)) °C, paused \(isPausedForHeat), asked macOS for \(overrideLimit.map(String.init) ?? "nothing")")
                }
            }
            print("charging seen stopped after: \(stoppedAfter.map { "\($0)s" } ?? "not in this run")")
            heatThresholdForTrial = nil
            refresh()
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<400 where isBusy || isOverriding { try? await Task.sleep(for: .milliseconds(500)) }
            line("after")
            return
        case "calibration":
            if let refusal = startCalibration() { print("refused: \(refusal)"); return }
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
        if mode == .calibrating { stopCalibration() }
        for _ in 0..<120 where isBusy || isOverriding {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))
        line("after")
    }

    /// For `Hachibu --probe-limit <n>`: asks macOS for any limit the helper
    /// accepts, without saving it as the user's, prints what the charging
    /// service and power management then report, and asks for the limit
    /// from before again.
    func probeLimit(_ value: Int) async -> String {
        runsModes = false
        guard HelperRequest.limitRange.contains(value) else { return "refused: \(value) is outside what the helper accepts" }
        await helper.refresh()
        let system = MacLimitSystem()
        // Whatever macOS holds now is put back before this returns.
        let before = await system.read()
        guard before.known else { return "refused: the current limit could not be read, so it could not be put back" }
        let started = Date.now
        let accepted = value >= 100 ? await system.setOfficial(100) : await system.setThroughHelper(value)
        guard accepted else { return "not accepted (helper: \(helper.state.title))" }
        var reported: Int?, enforced: Int?
        var reportedAfter: Int?, enforcedAfter: Int?
        for _ in 0..<60 where enforcedAfter == nil {
            reported = await system.read().limit
            enforced = await system.enforced()
            let seconds = Int(Date.now.timeIntervalSince(started).rounded())
            if reportedAfter == nil, reported == value { reportedAfter = seconds }
            if enforced == value { enforcedAfter = seconds } else { try? await Task.sleep(for: .seconds(3)) }
        }
        let previous = before.limit ?? 100
        let restored = previous >= 100 || officialStops.contains(previous)
            ? await system.setOfficial(previous) : await system.setThroughHelper(previous)
        let back = previous >= 100 ? "no limit" : "\(previous)%"
        let ending = restored ? "; \(back) was asked for again" : "; PUTTING \(back) BACK FAILED, set it yourself"
        return "asked for \(value)%: the charging service reports \(reported.map { "\($0)%" } ?? "no limit")"
            + " (after \(reportedAfter.map { "\($0)s" } ?? "never")), power management enforces \(enforced.map { "\($0)%" } ?? "none")"
            + " (after \(enforcedAfter.map { "\($0)s" } ?? "never in 180s"))" + ending
    }
}
