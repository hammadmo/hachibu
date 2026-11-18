import AppKit
import Foundation
import HachibuKit
import HachibuSystem

/// Checks the app's real functions on this Mac, read-only, and quits with
/// 0 (all passed) or 1. Run it with tools/selftest.sh, which sets APP_STORE
/// so nothing real is written and the charge limit cannot be changed.
enum SelfTest {
    static let requested = CommandLine.arguments.contains("--selftest")
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
        ]
        let built = SystemBattery.reading(from: saved, chargerWatts: 9.2, systemWatts: 7.2,
                                          smcTemperature: nil, fullChargeOverride: false)
        check("a saved battery dictionary builds the expected reading",
              built?.percent == 80 && built?.healthPercent == 81 && built?.cycleCount == 274
                  && built?.temperatureC == 30.4 && built?.isPluggedIn == true)
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
        if let held = limit.limit { check("power management enforces the limit macOS reports", ChargeLimit.enforced() == held) }

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
