import Foundation
import HachibuKit
import HachibuSystem
import IOKit

/// Reads the real battery: IOKit's AppleSmartBattery for state, the SMC for
/// power and temperature. Read-only; safe to call from any thread.
nonisolated enum SystemBattery {
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return reading(from: properties, chargerWatts: smcFloat("PDTR"), systemWatts: smcFloat("PSTR"),
                       smcTemperature: smcFloat("TB0T"), fullChargeOverride: hb_full_charge_override())
    }

    /// Builds a reading from AppleSmartBattery's properties. Separate from
    /// `read()` so the self-test can check it against a saved dictionary.
    static func reading(from properties: [String: Any], chargerWatts: Double?, systemWatts: Double?,
                        smcTemperature: Double?, fullChargeOverride: Bool) -> BatteryReading? {
        func int(_ key: String, in dictionary: [String: Any]) -> Int? {
            (dictionary[key] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        }
        guard let current = int("CurrentCapacity", in: properties) else { return nil }
        // On Apple silicon CurrentCapacity is already a percentage and
        // MaxCapacity is 100. Older hardware reports both in mAh.
        let maximum = int("MaxCapacity", in: properties) ?? 100
        let percent = maximum > 0 && maximum != 100
            ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        // macOS 27 keeps the mAh capacities inside BatteryData.
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        let rawMax = int("AppleRawMaxCapacity", in: data) ?? int("AppleRawMaxCapacity", in: properties)
        let design = int("DesignCapacity", in: data) ?? int("DesignCapacity", in: properties)
        // AppleSmartBattery reports temperature in hundredths of a degree Celsius.
        let temperature = smcTemperature ?? int("Temperature", in: properties).map { Double($0) / 100 }
        let pluggedIn = (properties["ExternalConnected"] as? Bool) ?? false
        return BatteryReading(
            percent: percent,
            isPluggedIn: pluggedIn,
            currentMA: int("Amperage", in: properties) ?? 0,
            voltageMV: int("Voltage", in: properties),
            temperatureC: temperature.flatMap { (0...100).contains($0) ? $0 : nil },
            cycleCount: int("CycleCount", in: properties),
            rawMaxCapacityMAh: rawMax.flatMap { $0 > 0 ? $0 : nil },
            designCapacityMAh: design.flatMap { $0 > 0 ? $0 : nil },
            chargerWatts: pluggedIn ? chargerWatts : 0,
            systemWatts: systemWatts,
            fullChargeOverride: fullChargeOverride)
    }

    /// Battery health as macOS itself reports it (System Settings > Battery).
    /// macOS smooths this figure, so it can differ by a point or two from raw
    /// capacity over design capacity. Slow (about a third of a second): call
    /// it rarely, off the main thread.
    static func systemHealthPercent() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for section in sections {
            if let health = section["sppower_battery_health_info"] as? [String: Any],
               let text = health["sppower_battery_health_maximum_capacity"] as? String,
               let value = Int(text.filter(\.isNumber)), (1...100).contains(value) {
                return value
            }
        }
        return nil
    }

    /// A four-byte float SMC key, for example "PDTR". nil when missing.
    static func smcFloat(_ key: String) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var type = [CChar](repeating: 0, count: 5)
        let count = hb_smc_read(key, &bytes, 32, &type)
        guard count == 4, type.prefix(4).map({ UInt8(bitPattern: $0) }) == Array("flt ".utf8) else { return nil }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        return value.isFinite ? Double(value) : nil
    }
}

/// macOS's own charge limit. Reads are always safe. Writes are refused in
/// test and snapshot runs, so they can never change real charging.
nonisolated enum ChargeLimit {
    struct State: Equatable, Sendable {
        var supported = false
        /// The limit macOS is holding. nil when it is off or could not be read.
        var limit: Int?
        /// The limits macOS offers without administrator rights.
        var available: [Int] = []
    }

    static func read() -> State {
        guard hb_limit_supported() else { return State() }
        var limit: Int32 = 0
        var enabled = false
        let known = hb_limit_get(&limit, &enabled)
        var offered = [Int32](repeating: 0, count: 16)
        let count = Int(hb_limit_available(&offered, 16))
        return State(supported: true,
                     limit: known && enabled && limit > 0 && limit < 100 ? Int(limit) : nil,
                     available: offered.prefix(count).map(Int.init))
    }

    /// Sets the limit; 100 turns it off. Returns nil on success, or why it failed.
    static func set(_ value: Int) -> String? {
        guard !Store.isOverridden else { return "Test runs never change the real limit." }
        var message = [CChar](repeating: 0, count: 256)
        let ok = value >= 100 ? hb_limit_disable(&message, 256) : hb_limit_set(Int32(value), &message, 256)
        return ok ? nil : message.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
