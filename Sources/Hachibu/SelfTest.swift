import AppKit
import Foundation
import HachibuKit
import HachibuSystem

/// Checks the app's real functions on this Mac, read-only, and quits with
/// 0 (all passed) or 1. Run it with tools/selftest.sh, which sets APP_STORE
/// so nothing real is written and the charge limit cannot be changed.
enum SelfTest {
    static let requested = Launch.command == .selfTest
    private(set) static var exitCode: Int32 = 1

    static func run() {
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL") \(name)")
            if !passed { failures += 1 }
        }

        // S-002: a real reading from this Mac parses without missing fields.
        let reading = SystemBattery.read()
        check("the battery can be read", reading != nil)
        check("the level is a percentage", reading.map { (0...100).contains($0.percent) } ?? false)
        check("cycle count is present", reading?.cycleCount != nil)
        check("health is present (capacities read from BatteryData)", reading?.healthPercent != nil)
        check("temperature is present and plausible", reading?.temperatureC.map { (5...60).contains($0) } ?? false)
        check("voltage is present", reading?.voltageMV != nil)

        // S-003: power comes from the battery controller.
        check("system power can be read (PSTR)", SystemBattery.smcFloat("PSTR") != nil)
        check("charger power can be read (PDTR)", SystemBattery.smcFloat("PDTR") != nil)
        check("a missing power key reads as missing, not 0", SystemBattery.smcFloat("ZZZZ") == nil)
        if let reading {
            let status = BatteryStatus.derive(from: reading, limit: ChargeLimit.read().limit)
            check("the status never says holding while current flows in",
                  !(reading.isCharging && status == .holdingAtLimit))
        }

        // The reading is built the same way from a saved dictionary (macOS 27 layout).
        let saved: [String: Any] = [
            "CurrentCapacity": 80, "MaxCapacity": 100, "ExternalConnected": true, "Amperage": 0,
            "Voltage": 12_094, "CycleCount": 274, "Temperature": 3_040,
            "BatteryData": ["AppleRawMaxCapacity": 3_556, "DesignCapacity": 4_382],
            "AdapterDetails": ["Watts": 30, "Description": "pd charger"],
        ]
        let built = SystemBattery.reading(from: saved, chargerWatts: 9.2, systemWatts: 7.2,
                                          smcTemperature: nil, fullChargeOverride: false)
        check("a saved battery dictionary builds the expected reading",
              built?.percent == 80 && built?.healthPercent == 81 && built?.cycleCount == 274
                  && built?.temperatureC == 30.4 && built?.isPluggedIn == true)
        check("the charger's rating is read from what the charger reports", built?.chargerRatingWatts == 30)
        if reading?.isPluggedIn == false {
            check("no charger rating is shown off the charger", reading?.chargerRatingWatts == nil)
        } else {
            // Not a check: a charger is free not to say what it can supply.
            print("INFO the connected charger reports \(reading?.chargerRatingWatts.map { "\($0) W" } ?? "no rating")")
        }
        let draining = SystemBattery.reading(from: ["CurrentCapacity": 50, "ExternalConnected": false,
                                                    "Amperage": NSNumber(value: UInt64(bitPattern: -850))],
                                             chargerWatts: 12, systemWatts: 7, smcTemperature: 31,
                                             fullChargeOverride: false)
        check("a discharging current reads as negative, with no charger power",
              draining?.currentMA == -850 && draining?.chargerWatts == 0)

        // S-004, S-005: macOS's limit.
        let limit = ChargeLimit.read()
        check("the macOS charge limit is supported", limit.supported)
        check("the current limit can be read", limit.known)
        check("macOS offers limits, and the stops include 100",
              !limit.available.isEmpty && LimitStops.normalized(limit.available).last == 100)
        check("a test run refuses to change the real limit", ChargeLimit.set(85) != nil)
        check("the real limit is unchanged after the refusal", ChargeLimit.read().limit == limit.limit)
        check("a test run never checks for updates", !Updates.canUpdate)
        check("the helper is offered once, and only where it is missing",
              HelperOffer.shouldShow(offered: false, state: .notInstalled)
                  && !HelperOffer.shouldShow(offered: true, state: .notInstalled)
                  && !HelperOffer.shouldShow(offered: false, state: .running))
        check("a test run never takes a keyboard shortcut", !TopUpShortcut.canRegister)
        let hotBefore = [90.0, 30].map {
            HistorySample(time: Date.now.addingTimeInterval(-$0), percent: 60, isPluggedIn: true, isCharging: true, temperatureC: 42, limit: 80)
        }
        check("heat protection counts the time the battery was hot before a restart",
              ChargeEngine.hotSince(in: hotBefore, threshold: 40, now: .now).map { Date.now.timeIntervalSince($0) >= ChargeEngine.heatSustain } == true
                  && ChargeEngine.hotSince(in: hotBefore, threshold: 43, now: .now) == nil)
        check("the menu bar icon tells battery, plugged, and charging apart",
              PowerMark.choose(BatteryReading(percent: 60, isPluggedIn: false, currentMA: -900)) == .battery
                  && PowerMark.choose(BatteryReading(percent: 80, isPluggedIn: true, currentMA: 0)) == .plugged
                  && PowerMark.choose(BatteryReading(percent: 60, isPluggedIn: true, currentMA: 1500)) == .charging)

        // S-005: the chosen limit is saved and read back.
        Preferences.shared.savedLimit = 85
        check("the chosen limit is saved and read back",
              Preferences.shared.storedValue(Preferences.Key.savedLimit) as? Int == 85)
        Preferences.shared.savedLimit = nil
        check("clearing the limit removes it", Preferences.shared.storedValue(Preferences.Key.savedLimit) == nil)

        // S-010, S-011: the helper. A test run never reaches it.
        check("this build carries the helper and its launchd file",
              ["Contents/MacOS/HachibuHelper", "Contents/Library/LaunchDaemons/\(HelperID.plist)"].allSatisfy {
                  FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path)
              })
        check("the charger reads as connected or cut (CHIE)", { var cut = false; return hb_adapter_is_cut(&cut) }())
        // Never as root: there the write and the helper would be real.
        if geteuid() != 0 {
            check("root-only writes are refused without root", !hb_root_limit_set(70))
            check("the helper started by hand refuses to run", helperExitCode() == 1)
        } else {
            check("the self-test is not run as root", false)
        }
        check("the real limit is unchanged after the refused write", ChargeLimit.read().limit == limit.limit)

        check("the enforced limit is read from pmset's report",
              ChargeLimit.enforcedLimit(inPmsetOutput: "{ chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 70; }") == 70
                  && ChargeLimit.enforcedLimit(inPmsetOutput: "Battery level limits:\n(\n)") == nil)
        // On battery macOS withdraws the limit from power management and
        // puts it back on plug-in, so there is nothing to compare then.
        if let held = limit.limit, reading?.isPluggedIn == true {
            check("power management enforces the limit macOS reports", ChargeLimit.enforced() == held)
        }

        // S-031: samples go to a /tmp store and come back in time order.
        let historyFile = URL(fileURLWithPath: HistoryCenter.file.path + "-selftest")
        try? FileManager.default.removeItem(at: historyFile)
        let history = HistoryStore(file: historyFile)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for minute in [3, 1, 2, 0] {
            history.append(HistorySample(time: base.addingTimeInterval(Double(minute) * 60), percent: 70 + minute,
                                         isPluggedIn: true, isCharging: false, temperatureC: 31.5, limit: 80))
        }
        check("history samples come back from a /tmp store in time order",
              history.samples().map(\.percent) == [70, 71, 72, 73] && historyFile.path.hasPrefix("/tmp/"))
        if let reading {
            let now = HistorySample(time: .now, percent: reading.percent, isPluggedIn: reading.isPluggedIn,
                                    isCharging: reading.isCharging, temperatureC: reading.temperatureC,
                                    chargerWatts: reading.chargerWatts, macWatts: reading.systemWatts, limit: 80)
            check("a real reading fits a history record", HistorySample(encoded: now.encoded()).map {
                $0.percent == reading.percent && abs(($0.temperatureC ?? 0) - (reading.temperatureC ?? 0)) < 0.06
            } ?? false)
        }
        if let reading {
            HistoryCenter.shared.note(reading, limit: 80, health: 82)
            Thread.sleep(forTimeInterval: 0.3)
        }
        check("a test run records nothing, even when handed a reading",
              !FileManager.default.fileExists(atPath: HistoryCenter.file.path))
        try? FileManager.default.removeItem(at: historyFile)

        // S-001: the template's sample window is gone; this is a menu bar app.
        check("the app has no Dock icon", NSApp.activationPolicy() == .accessory)
        check("no window is open at launch", NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.isEmpty)

        print(failures == 0 ? "SELFTEST PASS" : "SELFTEST FAIL \(failures)")
        exitCode = failures == 0 ? 0 : 1
        NSApp.terminate(nil)
    }

    /// Runs the bundled helper as the current user. It must quit with 1.
    private static func helperExitCode() -> Int32 {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/HachibuHelper")
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
